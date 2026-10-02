import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { AgentCore, createDefaultConfig, DEFAULT_RULES, type PersistedState, type PiAgentBackend, type Proposal, type TriggerRule } from "../src/index.ts";

const welcome: TriggerRule = {
  id: "welcome", type: "event", eventName: "app-launched", title: "给今天留一个起点",
  message: "可以一起梳理今天的优先事项。当前未连接日历或任务来源，你可以先告诉我最想推进的一件事。", cooldownMs: 24 * 60 * 60_000,
};
const backend: PiAgentBackend = { source: { repository: "test", ref: "test", commit: "test" }, async run() { return { text: "User-approved reply" }; } };

async function fixture(t: TestContext) {
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-startup-"));
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const config = createDefaultConfig(dataDir);
  let now = new Date(2026, 9, 2, 12);
  const create = (rules?: TriggerRule[]) => {
    const core = new AgentCore({ config, backend, rules, now: () => now });
    t.after(() => core.stop());
    return core;
  };
  return { create, statePath: join(dataDir, "state.json"), advance: (ms: number) => { now = new Date(now.getTime() + ms); } };
}

test("首次启动和保存后重启都不会默认创建欢迎会话", async (t) => {
  const f = await fixture(t);
  const first = f.create();
  first.start();
  assert.deepEqual(first.status().proposals, []);
  assert.deepEqual(first.status().conversations, []);
  first.setPaused(false);
  first.stop();
  f.advance(2 * 86400_000);
  const restored = f.create();
  restored.start();
  assert.deepEqual(restored.status().proposals, []);
  assert.deepEqual(restored.status().conversations, []);
  assert.equal(restored.scheduler.listRules().some(rule => rule.id === "welcome"), false);
});

test("升级只清理未经操作的内置欢迎样例并持久化，真实同名会话保留", async (t) => {
  const f = await fixture(t);
  const legacy = f.create([welcome, ...DEFAULT_RULES]);
  legacy.signal({ type: "event", name: "app-launched" });
  await legacy.prompt("user-message", welcome.title, undefined, false, "user-conversation");
  assert.equal((legacy.status().proposals as Proposal[]).length, 1);
  legacy.stop();
  const migrated = f.create();
  assert.deepEqual(migrated.status().proposals, []);
  assert.equal((migrated.status().conversations as unknown[]).length, 1);
  const saved = JSON.parse(await readFile(f.statePath, "utf8")) as PersistedState;
  assert.deepEqual(saved.proposals, []);
  assert.equal(saved.rules!.some(rule => rule.id === "welcome"), false);
  assert.equal(saved.conversations![0].messages[0].prompt, welcome.title);
  f.advance(2 * 86400_000);
  const restarted = f.create();
  restarted.start();
  assert.deepEqual(restarted.status().proposals, []);
  assert.equal((restarted.status().conversations as unknown[]).length, 1);
});

test("用户修改过的欢迎规则和自定义启动规则不迁移", async (t) => {
  for (const changes of [{ title: "我的启动计划" }, { cooldownMs: 5 }, { context: { project: "personal" } }, { id: "user-rule" }, { enabled: false }]) {
    await t.test(JSON.stringify(changes), async (t) => {
      const f = await fixture(t);
      const custom = { ...welcome, ...changes } as TriggerRule;
      const legacy = f.create([custom]);
      legacy.setPaused(false);
      const restored = f.create();
      assert.deepEqual(restored.scheduler.listRules(), [{ ...custom, enabled: custom.enabled ?? true }]);
    });
  }
});

test("用户处理过的欢迎建议保留，包括稍后恢复与归档恢复", async (t) => {
  for (const action of ["execute", "ignore", "later", "archive", "archive-unarchive"] as const) {
    await t.test(action, async (t) => {
      const f = await fixture(t);
      const legacy = f.create([welcome]);
      const [event] = legacy.signal({ type: "event", name: "app-launched" });
      const id = String(event.payload.suggestionId);
      if (action === "archive" || action === "archive-unarchive") {
        legacy.manageConversation(id, "archive");
        if (action === "archive-unarchive") legacy.manageConversation(id, "unarchive");
      } else {
        await legacy.decide(id, action);
        if (action === "later") { f.advance(20 * 60_000); legacy.tick(); }
      }
      const expected = legacy.status().proposals;
      assert.deepEqual(f.create().status().proposals, expected);
    });
  }
});

test("缺少原始触发历史时保留旧卡片，只退役未修改的内置规则", async (t) => {
  const f = await fixture(t);
  const legacy = f.create([welcome]);
  legacy.signal({ type: "event", name: "app-launched" });
  const saved = JSON.parse(await readFile(f.statePath, "utf8")) as PersistedState;
  saved.history = [];
  await writeFile(f.statePath, JSON.stringify(saved));
  const restored = f.create();
  assert.deepEqual(restored.status().proposals, legacy.status().proposals);
  assert.deepEqual(restored.scheduler.listRules(), []);
});

test("显式传入的启动规则仍可由调用方启用", async (t) => {
  const f = await fixture(t);
  const core = f.create([welcome]);
  core.start();
  assert.equal((core.status().proposals as Proposal[]).length, 1);
  assert.equal(core.scheduler.listRules()[0].id, "welcome");
});
