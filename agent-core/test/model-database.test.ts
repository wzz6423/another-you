import { strict as assert } from "node:assert";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { ModelDatabase, type ModelAccount } from "../src/model-database.ts";

async function fixture(t: TestContext) {
  const directory = await mkdtemp(join(tmpdir(), "another-you-account-db-"));
  const database = new ModelDatabase(directory);
  t.after(async () => { database.close(); await rm(directory, { recursive: true, force: true }); });
  const account: ModelAccount = { id: "account-a", name: "A", provider: "fixture", configuration: { baseUrl: "https://a.invalid" },
    model: "model-a", thinkingLevel: "high", credential: { type: "api_key", key: "key-a" } };
  database.saveAccount(account);
  database.activate(account);
  return { directory, database, account };
}

test("SQLite 持久化同提供方多账户、选择和目录缓存，数据库文件仅本人可读写", async t => {
  const f = await fixture(t);
  const second = { ...f.account, id: "account-b", name: "B", credential: { type: "api_key" as const, key: "key-b" } };
  f.database.saveAccount(second);
  f.database.activate(second);
  f.database.write("settings.json", { defaultProvider: "fixture", defaultModel: "model-b" });
  await f.database.modelsStore().write("fixture", { models: [], etag: "cache-b" });
  assert.equal((await readFile(f.database.path)).subarray(0, 16).toString(), "SQLite format 3\0");
  assert.equal((await stat(f.database.path)).mode & 0o777, 0o600);
  f.database.close();
  const reopened = new ModelDatabase(f.directory);
  t.after(() => reopened.close());
  assert.equal(reopened.accounts().length, 2);
  assert.equal(reopened.activeAccount("fixture")?.id, "account-b");
  assert.equal(reopened.read("settings.json").defaultModel, "model-b");
  assert.equal((await reopened.modelsStore().read("fixture"))?.etag, "cache-b");
  reopened.activate(f.account);
  assert.equal(await reopened.modelsStore().read("fixture"), undefined);
});

test("凭据修改跨连接串行化，切换后旧运行时仅刷新原账户", async t => {
  const f = await fixture(t);
  f.database.saveAccount({ ...f.account, credential: { type: "oauth", access: "initial", refresh: "refresh", expires: 0 } });
  const other = new ModelDatabase(f.directory);
  t.after(() => other.close());
  const originalStore = f.database.credentials(), otherStore = other.credentials();
  let enter!: () => void, release!: () => void;
  const entered = new Promise<void>(resolve => { enter = resolve; });
  const released = new Promise<void>(resolve => { release = resolve; });
  const first = originalStore.modify("fixture", async current => {
    enter(); await released;
    assert.equal(current?.type, "oauth");
    return { type: "oauth", access: "rotated-1", refresh: "refresh-1", expires: 1 };
  });
  await entered;
  const second = otherStore.modify("fixture", async current => {
    assert.equal(current?.type === "oauth" && current.refresh, "refresh-1");
    return { type: "oauth", access: "rotated-2", refresh: "refresh-2", expires: 2 };
  });
  release();
  await Promise.all([first, second]);
  const secondAccount = { ...f.account, id: "account-b", credential: { type: "api_key" as const, key: "key-b" } };
  f.database.saveAccount(secondAccount);
  f.database.activate(secondAccount);
  await originalStore.modify("fixture", async () => ({ type: "api_key", key: "updated-a" }));
  assert.equal(f.database.account("account-a")?.credential?.type, "api_key");
  assert.deepEqual(await f.database.credentials().read("fixture"), secondAccount.credential);
});

test("事务失败或认证取消均不写入部分账户配置，删除只影响目标账户", async t => {
  const f = await fixture(t);
  await assert.rejects(f.database.transactionAsync(async () => {
    f.database.write("settings.json", { defaultModel: "wrong" });
    f.database.saveAccount({ ...f.account, credential: { type: "api_key", key: "wrong" } });
    throw new Error("fixture failure");
  }), /fixture failure/);
  assert.deepEqual(f.database.read("settings.json"), {});
  assert.deepEqual(f.database.account(f.account.id)?.credential, f.account.credential);
  const abort = new AbortController();
  await assert.rejects(f.database.credentials().modify("fixture", async () => {
    abort.abort(); return { type: "api_key", key: "cancelled" };
  }, { signal: abort.signal }), { name: "AbortError" });
  assert.deepEqual(f.database.account(f.account.id)?.credential, f.account.credential);
  f.database.saveAccount({ ...f.account, id: "account-b" });
  f.database.deleteAccount("account-b");
  assert.equal(f.database.activeAccount("fixture")?.id, f.account.id);
});
