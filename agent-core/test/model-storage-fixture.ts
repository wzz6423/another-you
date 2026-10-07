import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import type { Credential } from "@earendil-works/pi-ai";
import { ModelDatabase } from "../src/model-database.ts";

function migratedDatabase(path: string): ModelDatabase | undefined {
  if (!existsSync(join(dirname(path), "models.sqlite"))) return undefined;
  const database = new ModelDatabase(dirname(path));
  if (database.read("migration").version === 1) return database;
  database.close();
  return undefined;
}

export async function readModelData(path: string, _encoding: "utf8" = "utf8"): Promise<string> {
  const database = migratedDatabase(path);
  if (!database) return readFile(path, "utf8");
  try {
    const name = basename(path);
    if (name === "auth.json") return JSON.stringify(database.authData());
    const value = database.readRaw(name);
    if (value === undefined || name === "pi-discovery.json" && !database.read(name).version) {
      throw Object.assign(new Error("Missing model fixture document"), { code: "ENOENT" });
    }
    return value;
  } finally { database.close(); }
}

export async function writeModelData(path: string, value: string): Promise<void> {
  const database = migratedDatabase(path);
  if (!database) return writeFile(path, value);
  try {
    const name = basename(path);
    database.transaction(() => {
      if (name === "auth.json") {
        const auth = JSON.parse(value) as Record<string, Credential>;
        const models = database.read("models.json").providers as Record<string, Record<string, unknown>>;
        for (const [provider, id] of database.activeAccountIDs()) {
          database.saveAccount({ ...database.account(id)!, credential: auth[provider] });
        }
        for (const [provider, credential] of Object.entries(auth)) {
          if (database.activeAccount(provider)) continue;
          const account = { id: randomUUID(), provider, name: provider, configuration: models[provider] ?? {}, credential };
          database.saveAccount(account);
          database.activate(account);
        }
      } else {
        database.writeRaw(name, value);
        if (name === "models.json") {
          let parsed: Record<string, Record<string, unknown>> | undefined;
          try { parsed = JSON.parse(value).providers; } catch { /* 损坏数据用于验证重新读取不会沿用旧配置。 */ }
          if (parsed) for (const [provider, id] of database.activeAccountIDs()) {
            database.saveAccount({ ...database.account(id)!, configuration: parsed[provider] ?? {} });
          }
        }
      }
    });
  } finally { database.close(); }
}
