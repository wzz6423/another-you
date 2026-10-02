import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { AgentCore, createDefaultConfig, retainedUsage, type PiAgentBackend, type UsageRecord } from "../src/index.ts";

const usage = { inputTokens: 10, outputTokens: 20, cacheReadTokens: 3, cacheWriteTokens: 4, totalTokens: 37 };
const source = { repository: "test", ref: "test", commit: "test" };

test("用量与活动历史独立持久化，精确保留30天并记录两轮上下文", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-usage-"));
  try {
    const now = new Date("2026-10-01T12:00:00Z");
    const contexts: unknown[] = [];
    const backend: PiAgentBackend = { source, async run(request) {
      contexts.push(structuredClone(request.context));
      return { text: "reply", model: "model-a", usage, reasoningEffort: "high", toolCalls: [{ name: "read", kind: "tool" }] };
    } };
    const config = createDefaultConfig(dataDir);
    const core = new AgentCore({ config, backend, now: () => now, rules: [] });
    for (let i = 0; i < 105; i++) await core.prompt(String(i), `question ${i}`);
    assert.deepEqual(contexts[1], { conversation: [{ role: "user", content: "question 0" }, { role: "assistant", content: "reply" }] });
    const restored = new AgentCore({ config, backend, now: () => now, rules: [] });
    const records = restored.status().usageRecords as UsageRecord[];
    assert.equal(records.length, 105);
    assert.equal(records.reduce((sum, record) => sum + record.usage!.totalTokens, 0), 3885);
    assert.equal((restored.status().history as unknown[]).length, 420);
    assert.equal(retainedUsage(records, new Date(now.getTime() + 30 * 86400_000)).length, 105);
    assert.equal(retainedUsage(records, new Date(now.getTime() + 30 * 86400_000 + 1)).length, 0);
  } finally { await rm(dataDir, { recursive: true, force: true }); }
});

test("失败保留部分用量，callback与返回值不双计；未知与零区分", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-usage-"));
  try {
    let run = 0;
    const backend: PiAgentBackend = { source, async run(request) {
      run++;
      if (run === 1) {
        request.onUsage?.({ model: "partial", outcome: "failed", usage, reasoningEffort: "high", toolCalls: [{ name: "mcp__search", kind: "mcp" }] });
        throw new Error("interrupted");
      }
      if (run === 2) return { text: "unknown" };
      const zero = { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 0 };
      request.onUsage?.({ model: "zero", outcome: "completed", usage: zero, reasoningEffort: "off", toolCalls: [] });
      return { text: "zero", usage: zero };
    } };
    const core = new AgentCore({ config: createDefaultConfig(dataDir), backend, rules: [] });
    for (let i = 0; i < 3; i++) await core.prompt(String(i), "test");
    const records = core.status().usageRecords as UsageRecord[];
    assert.equal(records.length, 3);
    assert.equal(records[0]!.outcome, "failed");
    assert.equal(records[0]!.usage!.totalTokens, 37);
    assert.equal(records[0]!.model, "partial");
    assert.equal(records[1]!.usage, undefined);
    assert.equal(records[2]!.usage!.totalTokens, 0);
  } finally { await rm(dataDir, { recursive: true, force: true }); }
});

test("建议执行计入用量且隔离主会话上下文", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-usage-"));
  try {
    const contexts: unknown[] = [];
    const backend: PiAgentBackend = { source, async run(request) { contexts.push(request.context); return { text: "draft", usage }; } };
    const core = new AgentCore({ config: createDefaultConfig(dataDir), backend, rules: [
      { id: "usage-fixture", type: "event", eventName: "usage-test", title: "Usage fixture", message: "Draft a test proposal" },
    ] });
    await core.prompt("chat", "private chat");
    const [event] = core.signal({ type: "event", name: "usage-test" });
    await core.decide(String(event!.payload.suggestionId), "execute");
    const records = core.status().usageRecords as UsageRecord[];
    assert.deepEqual(records.map((record) => record.source), ["prompt", "proposal"]);
    assert.equal(JSON.stringify(contexts[1]).includes("private chat"), false);
  } finally { await rm(dataDir, { recursive: true, force: true }); }
});
