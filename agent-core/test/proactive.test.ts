import { strict as assert } from "node:assert";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { AgentCore, createDefaultConfig, parseAgentConfig, type PiAgentBackend, type PiRequest, type PiResponse } from "../src/index.ts";
import { EventBus, type AgentEvent } from "../src/events.ts";
import { DEFAULT_PROACTIVE, type ProactiveConfig } from "../src/proactive-config.ts";
import { ProactiveCoordinator, type ContextResult, type ContextSource } from "../src/proactive.ts";

const base = Date.parse("2026-10-01T04:00:00Z");
const fast = { ...DEFAULT_PROACTIVE, workIntervalMs: 100, notificationsIntervalMs: 150, synthesisIntervalMs: 200, taskSpacingMs: 10, suggestionCooldownMs: 400 };
const analysis = { summary: "测试工作遇到明确阻塞", actionable: true, evidence: ["测试任务尚未完成"] };
const suggestion = { suggest: true, title: "先处理测试阻塞", message: "测试任务尚未完成，可以先查看失败原因。", reason: "工作内容出现阻塞", sources: ["work"] };
const responseFor = (request: PiRequest): PiResponse => ({ text: JSON.stringify(request.agentRole === "proactive-parent" ? suggestion : analysis) });

function fixture(options: { run?: (request: PiRequest) => Promise<PiResponse>; config?: Partial<ProactiveConfig>; reply?: boolean } = {}) {
  let time = base;
  const events = new EventBus();
  const received: AgentEvent[] = [];
  const requests: PiRequest[] = [];
  const content: Record<ContextSource, Record<string, unknown>> = { work: { text: "测试任务尚未完成" }, notifications: { items: ["测试提醒"] } };
  const coordinator = new ProactiveCoordinator({
    config: { ...fast, ...options.config }, events, now: () => new Date(time),
    run: async (request) => { requests.push(request); return options.run ? options.run(request) : responseFor(request); },
    canSuggest: () => true, recentSuggestions: () => [],
  });
  coordinator.registerSources(["work", "notifications"]);
  events.subscribe((event) => {
    received.push(event);
    if (event.kind === "context.request" && options.reply !== false) {
      const source = event.payload.source as ContextSource;
      coordinator.receive({ requestId: String(event.payload.requestId), source, status: "ok", content: content[source] });
    }
  });
  const tick = async (at: number, enabled = true) => { time = base + at; coordinator.tick(enabled); await coordinator.settle(); };
  return { coordinator, requests, received, content, tick, setTime: (at: number) => { time = base + at; } };
}

test("旧配置迁移到低频默认值并拒绝过密、无界或无效周期", () => {
  const config = parseAgentConfig({});
  assert.deepEqual(config.proactive, DEFAULT_PROACTIVE);
  assert.equal(createDefaultConfig().proactive.enabled, true);
  assert.equal(config.scheduler.enabled, true);
  assert.equal(config.proactive.enabled, true);
  const disabled = parseAgentConfig({ scheduler: { enabled: false }, proactive: { enabled: false } });
  assert.equal(disabled.scheduler.enabled, false);
  assert.equal(disabled.proactive.enabled, false);
  for (const value of [0, -1, 59999, Infinity, "300000"]) assert.throws(() => parseAgentConfig({ proactive: { workIntervalMs: value } }));
  assert.throws(() => parseAgentConfig({ proactive: { collectionTimeoutMs: 15000, taskTimeoutMs: 10000 } }));
  assert.equal(parseAgentConfig({ proactive: { enabled: false, workIntervalMs: 600000 } }).proactive.workIntervalMs, 600000);
});

test("不同任务按各自周期错峰，子 agent 只返回分析，由父 agent 发建议", async () => {
  const f = fixture();
  await f.tick(99);
  assert.equal(f.requests.length, 0);
  await f.tick(100);
  await f.tick(105);
  await f.tick(150);
  assert.deepEqual(f.requests.map((request) => request.agentRole), ["context-analyst", "notification-analyst"]);
  assert.equal(f.received.filter((event) => event.kind === "proactive.suggestion").length, 0);
  await f.tick(200);
  assert.equal(f.requests.length, 2);
  await f.tick(210);
  assert.equal(f.requests[2].agentRole, "proactive-parent");
  assert.equal((f.requests[2].context?.findings as unknown[]).length, 2);
  assert.equal(f.received.filter((event) => event.kind === "proactive.suggestion").length, 1);
  assert.equal(f.coordinator.snapshot().lastSuggestionAt, base + 210);
});

test("相同工作内容与重排后的旧通知不重复分析，只有新增通知进入子 agent", async () => {
  const f = fixture({ config: { synthesisIntervalMs: 10000 } });
  f.content.notifications.items = ["A", "B"];
  await f.tick(100);
  await f.tick(150);
  await f.tick(200);
  f.content.notifications.items = ["B", "A"];
  await f.tick(300);
  await f.tick(310);
  assert.equal(f.requests.length, 2);
  f.content.notifications.items = ["A", "B", "C"];
  await f.tick(460);
  await f.tick(470);
  const last = f.requests.at(-1)!;
  assert.equal(last.agentRole, "notification-analyst");
  assert.deepEqual((last.context?.content as { items: string[] }).items, ["C"]);
});

test("冷却期内继续采集但不发建议，恢复后也不会重复相同建议", async () => {
  const f = fixture();
  for (const at of [100, 150, 200, 210]) await f.tick(at);
  f.content.work.text = "另一个阻塞";
  for (const at of [300, 310, 410, 460, 500, 610, 620, 630]) await f.tick(at);
  assert.ok(f.requests.filter((request) => request.agentRole === "context-analyst").length >= 2);
  assert.equal(f.received.filter((event) => event.kind === "proactive.suggestion").length, 1);
});

test("无行动价值的变化不调用父 agent，无采集宿主时不会运行", async () => {
  const f = fixture({ run: async () => ({ text: JSON.stringify({ ...analysis, actionable: false }) }) });
  for (const at of [100, 150, 200, 210]) await f.tick(at);
  assert.equal(f.requests.some((request) => request.agentRole === "proactive-parent"), false);
  const g = fixture();
  g.coordinator.registerSources([]);
  await g.tick(10000);
  assert.equal(g.received.length, 0);
  assert.throws(() => g.coordinator.registerSources(["mail"]));
});

test("采集期间保持非阻塞且同任务不重入，取消后丢弃晚到结果", async () => {
  const f = fixture({ reply: false });
  f.setTime(100);
  f.coordinator.tick(true);
  await Promise.resolve();
  f.setTime(1000);
  f.coordinator.tick(true);
  assert.equal(f.received.filter((event) => event.kind === "context.request").length, 1);
  const event = f.received.find((event) => event.kind === "context.request")!;
  await f.coordinator.interrupt();
  f.coordinator.receive({ requestId: String(event.payload.requestId), source: "work", status: "ok", content: { text: "迟到的结果" } });
  assert.equal(f.requests.length, 0);
  assert.equal(f.coordinator.status().running, false);
  assert.equal(f.received.filter((event) => event.kind === "context.cancel").length, 1);
});

test("格式错误与超时退避，后台错误不保存原始私人内容", async () => {
  const f = fixture({ run: async () => { throw new Error("私人输入回显"); } });
  f.coordinator.registerSources(["work"]);
  await f.tick(100);
  assert.equal(f.coordinator.snapshot().tasks.work.nextRunAt, base + 300);
  await f.tick(299);
  assert.equal(f.requests.length, 1);
  await f.tick(300);
  assert.equal(f.coordinator.snapshot().tasks.work.nextRunAt, base + 700);
  assert.equal(JSON.stringify(f.coordinator.snapshot()).includes("私人输入回显"), false);
  const timeout = fixture({ config: { taskTimeoutMs: 20 }, run: (request) => new Promise((_, reject) => request.signal?.addEventListener("abort", () => reject(new Error("取消")), { once: true })) });
  await timeout.tick(100);
  assert.equal(timeout.coordinator.snapshot().tasks.work.state, "failed");
  assert.match(timeout.coordinator.snapshot().tasks.work.message!, /超时/);
});

test("缺权限来源与错误来源回包不会伪造分析", async () => {
  const f = fixture({ reply: false });
  f.setTime(100);
  f.coordinator.tick(true);
  await Promise.resolve();
  const event = f.received.find((event) => event.kind === "context.request")!;
  const requestId = String(event.payload.requestId);
  f.coordinator.receive({ requestId, source: "notifications", status: "ok", content: {} });
  assert.equal(f.coordinator.status().running, true);
  f.coordinator.receive({ requestId, source: "work", status: "permission-required", message: "请授权" });
  await f.coordinator.settle();
  assert.equal(f.coordinator.snapshot().tasks.work.state, "permission-required");
  assert.equal(f.requests.length, 0);
});

test("恢复保留冷却和指纹，休眠积压不突发补跑", async () => {
  const f = fixture();
  for (const at of [100, 150, 200, 210]) await f.tick(at);
  const saved = f.coordinator.snapshot();
  const restored = new ProactiveCoordinator({ config: fast, events: new EventBus(), now: () => new Date(base + 220), saved,
    run: async () => { throw new Error("不应调用"); }, canSuggest: () => true, recentSuggestions: () => [] });
  assert.equal(restored.canSuggest(base + 300), false);
  assert.ok(restored.snapshot().tasks.work.nextRunAt >= base + 320);
  assert.equal(restored.snapshot().fingerprints.work, saved.fingerprints.work);
  f.setTime(100000);
  f.coordinator.tick(true);
  f.coordinator.tick(true);
  await f.coordinator.settle();
  const count = f.received.filter((event) => event.kind === "context.request").length;
  f.coordinator.tick(true);
  await f.coordinator.settle();
  assert.equal(f.received.filter((event) => event.kind === "context.request").length, count);
});

test("AgentCore 前台提问抢占后台分析，暂停与停止保持可控", async (t) => {
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-proactive-test-"));
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const config = createDefaultConfig(dataDir);
  config.proactive = { ...fast };
  let now = base;
  let backgroundStarted = false;
  const backend: PiAgentBackend = { source: { repository: "fixture", ref: "test", commit: "test" }, run: async (request) => {
    if (!request.agentRole) return { text: "前台回复" };
    backgroundStarted = true;
    return new Promise((_, reject) => request.signal?.addEventListener("abort", () => reject(new Error("后台取消")), { once: true }));
  } };
  const core = new AgentCore({ config, rules: [], backend, now: () => new Date(now) });
  t.after(async () => { core.stop(); await core.settleBackground(); });
  const events: AgentEvent[] = [];
  core.events.subscribe((event) => {
    events.push(event);
    if (event.kind === "context.request") core.receiveContext({ requestId: String(event.payload.requestId), source: event.payload.source as ContextSource, status: "ok", content: { text: "fixture" } });
  });
  core.registerContextSources(["work"]);
  core.start();
  now += 100;
  core.tick();
  await Promise.resolve(); await Promise.resolve();
  assert.equal(backgroundStarted, true);
  await core.prompt("foreground", "现在回答我");
  assert.ok(events.some((event) => event.kind === "agent.response" && event.payload.text === "前台回复"));
  assert.equal(core.proactive.status().running, false);
  core.setPaused(true);
  now += 10000;
  core.tick();
  assert.equal(core.proactive.status().running, false);
  core.stop();
});

test("主动建议遵守内容不落盘配置，后台摘要不进入聊天历史", async (t) => {
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-proactive-private-"));
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const config = createDefaultConfig(dataDir);
  config.proactive = { ...fast };
  config.privacy.storePrompts = false;
  const backend: PiAgentBackend = { source: { repository: "fixture", ref: "test", commit: "test" }, run: async (request) => responseFor(request) };
  let now = base;
  const core = new AgentCore({ config, rules: [], backend, now: () => new Date(now) });
  t.after(async () => { core.stop(); await core.settleBackground(); });
  core.registerContextSources(["work"]);
  core.events.subscribe((event) => {
    if (event.kind === "context.request") core.receiveContext({ requestId: String(event.payload.requestId), source: event.payload.source as ContextSource, status: "ok", content: { text: "私人工作原文" } });
  });
  core.start();
  for (const at of [100, 200, 210]) { now = base + at; core.tick(); await core.settleBackground(); }
  const status = core.status();
  assert.equal((status.proposals as unknown[]).length, 1);
  assert.equal((status.history as AgentEvent[]).some((event) => event.kind === "agent.response"), false);
  const disk = await readFile(join(dataDir, "state.json"), "utf8");
  for (const privateText of ["私人工作原文", analysis.summary, suggestion.title, suggestion.message, suggestion.reason]) assert.equal(disk.includes(privateText), false, privateText);
  assert.ok((status.usageRecords as unknown[]).length >= 2);
  core.stop();
});
