import { chmodSync, closeSync, openSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { setTimeout as delay } from "node:timers/promises";
import type { AuthOperationOptions, Credential, CredentialStore, ModelsStore, ModelsStoreEntry } from "@earendil-works/pi-ai";

export interface ModelAccount {
  id: string;
  provider: string;
  name: string;
  configuration: Record<string, unknown>;
  model?: string;
  thinkingLevel?: string;
  credential?: Credential;
}

function accountFromRow(row: Record<string, unknown>): ModelAccount {
  return { id: String(row.id), provider: String(row.provider), name: String(row.name),
    configuration: JSON.parse(String(row.configuration)),
    ...(typeof row.model === "string" ? { model: row.model } : {}),
    ...(typeof row.thinking_level === "string" ? { thinkingLevel: row.thinking_level } : {}),
    ...(typeof row.credential === "string" ? { credential: JSON.parse(row.credential) } : {}) };
}

async function acquireWrite(database: DatabaseSync, signal?: AbortSignal): Promise<void> {
  const deadline = Date.now() + 60_000;
  for (;;) {
    signal?.throwIfAborted();
    try { database.exec("BEGIN IMMEDIATE"); return; }
    catch (error) {
      if (![5, 6].includes((error as { errcode?: number }).errcode ?? -1)) throw error;
      if (Date.now() >= deadline) throw new Error("本地模型数据库正忙，请稍后重试");
      await delay(20, undefined, { signal });
    }
  }
}

export class ModelDatabase {
  readonly path: string;
  private readonly database: DatabaseSync;
  private transactionOpen = false;
  private closed = false;

  constructor(directory: string) {
    this.path = join(directory, "models.sqlite");
    closeSync(openSync(this.path, "a", 0o600));
    chmodSync(this.path, 0o600);
    this.database = new DatabaseSync(this.path);
    this.database.exec(`
      PRAGMA foreign_keys = ON;
      PRAGMA secure_delete = ON;
      CREATE TABLE IF NOT EXISTS documents (name TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS accounts (
        id TEXT PRIMARY KEY, provider TEXT NOT NULL, name TEXT NOT NULL,
        configuration TEXT NOT NULL, model TEXT, thinking_level TEXT, credential TEXT
      );
      CREATE TABLE IF NOT EXISTS active_accounts (
        provider TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE
      );
      CREATE TABLE IF NOT EXISTS model_catalogs (
        scope TEXT NOT NULL, provider TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (scope, provider)
      );
    `);
  }

  close(): void { if (!this.closed) { this.database.close(); this.closed = true; } }

  readRaw(name: string): string | undefined {
    return this.database.prepare("SELECT value FROM documents WHERE name = ?").get(name)?.value as string | undefined;
  }

  read(name: string, missing: Record<string, unknown> = {}): Record<string, unknown> {
    const raw = this.readRaw(name);
    if (raw === undefined) return missing;
    try {
      const value: unknown = JSON.parse(raw);
      if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
      return value as Record<string, unknown>;
    } catch { throw new Error(`${name} 无法读取，请检查本地模型数据库`); }
  }

  writeRaw(name: string, value: string): void {
    this.database.prepare("INSERT INTO documents VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value").run(name, value);
  }

  write(name: string, value: unknown): void { this.writeRaw(name, JSON.stringify(value)); }

  transaction<T>(work: () => T): T {
    if (this.transactionOpen) return work();
    this.database.exec("BEGIN IMMEDIATE");
    this.transactionOpen = true;
    try { const result = work(); this.database.exec("COMMIT"); return result; }
    catch (error) { this.database.exec("ROLLBACK"); throw error; }
    finally { this.transactionOpen = false; }
  }

  async transactionAsync<T>(work: () => Promise<T>, signal?: AbortSignal): Promise<T> {
    if (this.transactionOpen) return work();
    await acquireWrite(this.database, signal);
    this.transactionOpen = true;
    try {
      const result = await work();
      signal?.throwIfAborted();
      this.database.exec("COMMIT");
      return result;
    } catch (error) { this.database.exec("ROLLBACK"); throw error; }
    finally { this.transactionOpen = false; }
  }

  accounts(): ModelAccount[] {
    return this.database.prepare("SELECT * FROM accounts ORDER BY rowid").all().map(accountFromRow);
  }

  account(id: string): ModelAccount | undefined {
    const row = this.database.prepare("SELECT * FROM accounts WHERE id = ?").get(id);
    return row && accountFromRow(row);
  }

  activeAccountIDs(): Map<string, string> {
    return new Map(this.database.prepare("SELECT provider, account_id FROM active_accounts").all()
      .map(row => [String(row.provider), String(row.account_id)]));
  }

  activeAccount(provider: string): ModelAccount | undefined {
    const id = this.activeAccountIDs().get(provider);
    return id ? this.account(id) : undefined;
  }

  saveAccount(account: ModelAccount): void {
    this.database.prepare(`INSERT INTO accounts VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET name = excluded.name, configuration = excluded.configuration,
      model = excluded.model, thinking_level = excluded.thinking_level, credential = excluded.credential`)
      .run(account.id, account.provider, account.name, JSON.stringify(account.configuration), account.model ?? null,
        account.thinkingLevel ?? null, account.credential ? JSON.stringify(account.credential) : null);
  }

  activate(account: ModelAccount): void {
    this.database.prepare("INSERT INTO active_accounts VALUES (?, ?) ON CONFLICT(provider) DO UPDATE SET account_id = excluded.account_id")
      .run(account.provider, account.id);
  }

  deleteAccount(id: string): void {
    this.database.prepare("DELETE FROM accounts WHERE id = ?").run(id);
    this.database.prepare("DELETE FROM model_catalogs WHERE scope = ?").run(id);
  }

  authData(): Record<string, Credential> {
    return Object.fromEntries([...this.activeAccountIDs()].flatMap(([provider, id]) => {
      const credential = this.account(id)?.credential;
      return credential ? [[provider, credential]] : [];
    }));
  }

  readonly settingsStorage = {
    withLock: (scope: "global" | "project", work: (current: string | undefined) => string | undefined): void => {
      if (scope === "project") { work(undefined); return; }
      this.transaction(() => {
        const next = work(this.readRaw("settings.json"));
        if (next !== undefined) this.writeRaw("settings.json", next);
      });
    },
  };

  credentials(): CredentialStore {
    // 每个运行时绑定账户 UUID，旧请求的 OAuth 刷新不能写进切换后的账户。
    const ids = this.activeAccountIDs();
    const read = (provider: string): Credential | undefined => {
      const id = ids.get(provider);
      return id ? this.account(id)?.credential : undefined;
    };
    const change = async (provider: string, work: (current: Credential | undefined) => Promise<Credential | undefined | null>,
      options?: AuthOperationOptions): Promise<Credential | undefined> => {
      options?.signal?.throwIfAborted();
      const id = ids.get(provider);
      if (!id) throw new Error("账户不存在，请重新选择账户");
      // 网络刷新持有独立连接的写锁，既串行刷新令牌，也允许主连接继续只读。
      const database = new DatabaseSync(this.path);
      database.exec("PRAGMA secure_delete = ON");
      let locked = false;
      try {
        await acquireWrite(database, options?.signal);
        locked = true;
        const row = database.prepare("SELECT credential FROM accounts WHERE id = ?").get(id);
        if (!row) throw new Error("账户不存在，请重新选择账户");
        const current: Credential | undefined = typeof row.credential === "string" ? JSON.parse(row.credential) : undefined;
        const next = await work(current);
        options?.signal?.throwIfAborted();
        if (next !== undefined) database.prepare("UPDATE accounts SET credential = ? WHERE id = ?").run(next === null ? null : JSON.stringify(next), id);
        database.exec("COMMIT");
        locked = false;
        return next === null ? undefined : next ?? current;
      } catch (error) { if (locked) database.exec("ROLLBACK"); throw error; }
      finally { database.close(); }
    };
    return {
      read: async (provider, options) => { options?.signal?.throwIfAborted(); return read(provider); },
      list: async options => {
        options?.signal?.throwIfAborted();
        return [...ids.keys()].flatMap(providerId => {
          const credential = read(providerId);
          return credential ? [{ providerId, type: credential.type }] : [];
        });
      },
      modify: (provider, work, options) => change(provider, work, options),
      delete: async (provider, options) => { await change(provider, async () => null, options); },
    };
  }

  modelsStore(): ModelsStore {
    const ids = this.activeAccountIDs();
    return {
      read: async (provider, options) => {
        options?.signal?.throwIfAborted();
        const row = this.database.prepare("SELECT value FROM model_catalogs WHERE scope = ? AND provider = ?").get(ids.get(provider) ?? "", provider);
        return row ? JSON.parse(String(row.value)) as ModelsStoreEntry : undefined;
      },
      write: async (provider, entry, options) => {
        options?.signal?.throwIfAborted();
        this.database.prepare("INSERT INTO model_catalogs VALUES (?, ?, ?) ON CONFLICT(scope, provider) DO UPDATE SET value = excluded.value")
          .run(ids.get(provider) ?? "", provider, JSON.stringify(entry));
      },
      delete: async (provider, options) => {
        options?.signal?.throwIfAborted();
        this.database.prepare("DELETE FROM model_catalogs WHERE scope = ? AND provider = ?").run(ids.get(provider) ?? "", provider);
      },
    };
  }
}
