import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { retainedHistory } from "../src/activity-history.ts";
import { AgentCore, createAgentEvent, createDefaultConfig, type AgentEvent, type PiAgentBackend } from "../src/index.ts";

const day = 86400_000;
const now = new Date("2026-10-02T12:00:00Z");
const backend: PiAgentBackend = {
  source: { repository: "fixture", ref: "fixture", commit: "fixture" },
  async run(request) {
    request.onActivity?.({ category: "thinking", phase: "started" });
    request.onActivity?.({ category: "thinking", phase: "completed" });
    return { text: "private response sk-1234567890abcdef" };
  },
};

async function fixture(t: TestContext) {
  const directory = await mkdtemp(join(tmpdir(), "another-you-activity-history-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return { directory, config: createDefaultConfig(directory) };
}

function event(id: string, offset = 0): AgentEvent {
  return createAgentEvent({ id, occurredAt: new Date(now.getTime() + offset), kind: "agent.activity", source: "agent",
    payload: { category: "command", phase: "completed", toolName: "shell" } });
}

test("活动历史按事件时间保留30天，不以200条截断；无效时间丢弃，未来记录等待界面时间范围", () => {
  const recent = Array.from({ length: 250 }, (_, index) => event(`recent-${index}`, -index * 1000));
  const edge = event("edge", -30 * day);
  const expired = event("expired", -30 * day - 1);
  const future = event("future", 1000);
  const invalid = { ...event("invalid"), occurredAt: "invalid" };
  const retained = retainedHistory([...recent, expired, edge, future, invalid], now);
  assert.equal(retained.length, 252);
  assert.deepEqual(retained.slice(-2).map(value => value.id), ["edge", "future"]);
  assert.equal(retainedHistory([edge], new Date(now.getTime() + 1)).length, 0);
});

test("超过200条活动跨重启保存，status和后续持久化按30天边界清理", async t => {
  const { directory, config } = await fixture(t);
  let clock = now;
  const core = new AgentCore({ config, backend, rules: [], now: () => clock });
  for (let index = 0; index < 250; index++) core.events.emit(event(`recent-${index}`, -index * 1000));
  core.events.emit(event("edge", -30 * day));
  core.events.emit(event("expired", -30 * day - 1));
  assert.equal((core.status().history as AgentEvent[]).length, 251);
  const path = join(directory, "state.json");
  const persisted = JSON.parse(await readFile(path, "utf8"));
  assert.equal(persisted.history.length, 251);
  persisted.history.push({ ...event("invalid"), occurredAt: "invalid" });
  await writeFile(path, JSON.stringify(persisted));
  const restored = new AgentCore({ config, backend, rules: [], now: () => clock });
  assert.equal((restored.status().history as AgentEvent[]).length, 251);
  clock = new Date(now.getTime() + 1);
  assert.equal((restored.status().history as AgentEvent[]).length, 250);
  restored.setPaused(true);
  assert.equal(JSON.parse(await readFile(path, "utf8")).history.length, 250);
});

test("延长历史保留仍遵守内容保存、密钥遮盖与思考阶段元数据规则", async t => {
  const { directory, config } = await fixture(t);
  const core = new AgentCore({ config, backend, rules: [] });
  for (let index = 0; index < 250; index++) core.events.emit({ ...event(`recent-${index}`), occurredAt: new Date() });
  await core.prompt("private", "private prompt sk-1234567890abcdef");
  const path = join(directory, "state.json");
  let disk = await readFile(path, "utf8");
  assert.equal(disk.includes("sk-1234567890abcdef"), false);
  assert.ok(disk.includes("[已隐藏密钥]"));
  const thinking = (JSON.parse(disk).history as AgentEvent[]).filter(value => value.payload.category === "thinking");
  assert.equal(thinking.length, 2);
  assert.ok(thinking.every(value => value.payload.text === undefined && value.payload.arguments === undefined));
  config.privacy.storePrompts = false;
  config.privacy.storeResponses = false;
  const restored = new AgentCore({ config, backend, rules: [] });
  restored.setPaused(true);
  disk = await readFile(path, "utf8");
  assert.equal(disk.includes("private prompt"), false);
  assert.equal(disk.includes("private response"), false);
  assert.ok((JSON.parse(disk).history as AgentEvent[]).length > 200);
});
