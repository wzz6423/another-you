import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { ACTIVITY_RETENTION_MS, AgentCore, createAgentEvent, createDefaultConfig, retainedActivity,
  type ActivityRecord, type AgentEvent, type PiAgentBackend, type TriggerRule } from "../src/index.ts";

async function fixture(t: TestContext, rules: TriggerRule[] = [], fail = false) {
  const directory = await mkdtemp(join(tmpdir(), "another-you-activity-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  let now = new Date("2026-10-03T10:00:00Z");
  const clock = () => now;
  const config = createDefaultConfig(directory);
  const backend: PiAgentBackend = { source: { repository: "fixture", ref: "fixture", commit: "fixture" },
    async run() { if (fail) throw new Error("fixture failure"); return { text: "reply" }; } };
  const core = new AgentCore({ config, backend, now: clock, rules });
  return { directory, config, backend, core, clock, advance: (ms: number) => { now = new Date(now.getTime() + ms); } };
}
const records = (core: AgentCore) => core.status().activityRecords as ActivityRecord[];
const attachment = (appName: string) => [{ mimeType: "image/jpeg", data: "/9j/", context: { appName } }];

test("使用统计接受会话即计数，按本次应用归因并跨重启保留", async t => {
  const f = await fixture(t);
  const live: AgentEvent[] = [];
  f.core.events.subscribe(event => { if (event.kind === "activity.recorded") live.push(event); });
  await f.core.prompt("one", "first", attachment("Safari"));
  await f.core.prompt("two", "second", attachment("Xcode"));
  await f.core.prompt("three", "third");
  assert.deepEqual(records(f.core).map(record => record.appName), ["Safari", "Xcode", "Safari"]);
  assert.equal(live.length, 3);
  assert.equal(live[0].occurredAt, f.clock().toISOString());
  const restored = new AgentCore({ config: f.config, backend: f.backend, now: f.clock, rules: [] });
  assert.deepEqual(records(restored), records(f.core));
  assert.equal((restored.status().usageRecords as unknown[]).length, 3);
});

test("失败请求计一次，拒绝和重复请求不增加次数", async t => {
  const { core } = await fixture(t, [], true);
  await core.prompt("failed", "request");
  assert.equal(records(core).length, 1);
  await assert.rejects(core.prompt("failed", "duplicate"));
  await assert.rejects(core.prompt("empty", ""));
  assert.equal(records(core).length, 1);
});

test("建议首次触发计一次，稍后提醒和执行不重复计数", async t => {
  const rule: TriggerRule = { id: "test", type: "event", eventName: "fixture", title: "Test", message: "test", context: { appName: "Calendar" } };
  const f = await fixture(t, [rule]);
  const [event] = f.core.signal({ type: "event", name: "fixture" }, f.clock());
  assert.equal(records(f.core).length, 1);
  assert.equal(records(f.core)[0].kind, "suggestion");
  assert.equal(records(f.core)[0].appName, "Calendar");
  const id = String(event.payload.suggestionId);
  await f.core.decide(id, "later", 1);
  f.advance(16 * 60_000);
  f.core.tick();
  await f.core.decide(id, "execute");
  assert.equal(records(f.core).length, 1);
  assert.equal((f.core.status().usageRecords as unknown[]).length, 1);
});

test("归档、分支和删除不复制或删除已发生的统计", async t => {
  const f = await fixture(t);
  await f.core.prompt("first", "test", undefined, false, "session");
  f.core.forkConversation("session", "fork");
  f.core.manageConversation("session", "archive");
  f.core.manageConversation("session", "delete");
  assert.equal(records(f.core).length, 1);
  const restored = new AgentCore({ config: f.config, backend: f.backend, now: f.clock, rules: [] });
  assert.equal(records(restored).length, 1);
});

test("用量与次数统计保留186天边界，活动历史只保留30天", async t => {
  const f = await fixture(t);
  await f.core.prompt("first", "test");
  const original = records(f.core)[0];
  const historyIDs = (f.core.status().history as AgentEvent[])
    .filter(event => event.occurredAt === original.occurredAt).map(event => event.id);
  assert.ok(historyIDs.length > 0);
  f.advance(30 * 86400_000);
  assert.ok((f.core.status().history as AgentEvent[]).some(event => historyIDs.includes(event.id)));
  f.advance(1);
  assert.equal((f.core.status().history as AgentEvent[]).some(event => historyIDs.includes(event.id)), false);
  f.advance(60 * 86400_000 - 1);
  const restored = new AgentCore({ config: f.config, backend: f.backend, now: f.clock, rules: [] });
  assert.equal(records(restored).length, 1);
  assert.equal((restored.status().usageRecords as unknown[]).length, 1);
  assert.equal((restored.status().history as AgentEvent[]).some(event => historyIDs.includes(event.id)), false);
  const boundary = new Date(Date.parse(original.occurredAt) + ACTIVITY_RETENTION_MS);
  const invalid = { ...original, id: "bad", occurredAt: "invalid" };
  const future = { ...original, id: "future", occurredAt: new Date(boundary.getTime() + 1).toISOString() };
  assert.deepEqual(retainedActivity([original, original, invalid, future], boundary), [original]);
  assert.equal(retainedActivity([original], new Date(boundary.getTime() + 1)).length, 0);
  f.advance(96 * 86400_000);
  assert.equal(records(restored).length, 1);
  assert.equal((restored.status().usageRecords as unknown[]).length, 1);
  f.advance(1);
  assert.equal(records(restored).length, 0);
  assert.equal((restored.status().usageRecords as unknown[]).length, 0);
});

test("旧状态只从真实历史事件迁移，去重并跳过再次提醒与未来日期", async t => {
  const f = await fixture(t);
  await f.core.prompt("first", "test", attachment("Safari"));
  const path = join(f.directory, "state.json");
  const state = JSON.parse(await readFile(path, "utf8"));
  delete state.activityRecords;
  const suggestion = createAgentEvent({ id: "suggestion", occurredAt: f.clock(), kind: "proactive.suggestion", source: "scheduler",
    payload: { suggestionId: "suggestion", context: { appName: "Calendar" }, trigger: "event" } });
  state.history.push(suggestion, suggestion, { ...suggestion, id: "reminder", payload: { ...suggestion.payload, trigger: "snooze" } },
    { ...suggestion, id: "future", occurredAt: "2099-01-01T00:00:00Z", payload: { suggestionId: "future" } });
  await writeFile(path, JSON.stringify(state));
  const restored = new AgentCore({ config: f.config, backend: f.backend, now: f.clock, rules: [] });
  assert.deepEqual(records(restored).map(record => record.appName), ["Safari", "Calendar"]);
  restored.setPaused(true);
  const restarted = new AgentCore({ config: f.config, backend: f.backend, now: f.clock, rules: [] });
  assert.equal(records(restarted).length, 2);
});

test("已保存的统计为准，不从历史重复回填；关闭内容保存时移除应用名称", async t => {
  const f = await fixture(t);
  f.config.privacy.storePrompts = false;
  await f.core.prompt("first", "private text", attachment("Private App"));
  const path = join(f.directory, "state.json");
  const disk = await readFile(path, "utf8");
  assert.equal(disk.includes("Private App"), false);
  assert.equal(disk.includes("private text"), false);
  const state = JSON.parse(disk);
  assert.equal(state.activityRecords.length, 1);
  assert.equal(state.activityRecords[0].appName, undefined);
  state.activityRecords = [];
  await writeFile(path, JSON.stringify(state));
  const restored = new AgentCore({ config: f.config, backend: f.backend, now: f.clock, rules: [] });
  assert.deepEqual(records(restored), []);
});
