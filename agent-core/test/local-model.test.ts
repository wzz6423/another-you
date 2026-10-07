import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { LocalModelBackend, localModelRecommendation, parseLocalModelConfig } from "../src/local-model.ts";
import { AgentCore, createDefaultConfig, type PiAgentBackend, type PiRequest } from "../src/index.ts";
import { LocalModelCommandHandler } from "../src/local-model-commands.ts";
import { EventBus, type AgentEvent } from "../src/events.ts";
import { ProactiveCoordinator } from "../src/proactive.ts";
import { DEFAULT_PROACTIVE, parseProactiveConfig } from "../src/proactive-config.ts";
import type { PiRunUsage } from "../src/pi-adapter.ts";

async function server(t: TestContext, handler: (request: IncomingMessage, response: ServerResponse) => void) {
  const http = createServer(handler);
  await new Promise<void>(resolve => http.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise<void>(resolve => { http.close(() => resolve()); http.closeAllConnections(); }));
  return `http://127.0.0.1:${(http.address() as { port: number }).port}`;
}
async function body(request: IncomingMessage) {
  let data = "";
  for await (const chunk of request) data += chunk;
  return JSON.parse(data);
}

test("本地地址归一化、私网限制与不同硬件的推荐", () => {
  assert.equal(parseLocalModelConfig({ provider: "ollama", baseUrl: "http://localhost:11434/v1/" }).baseUrl, "http://localhost:11434");
  assert.equal(parseLocalModelConfig({ provider: "lmstudio", baseUrl: "http://192.168.1.8:1234" }).baseUrl, "http://192.168.1.8:1234/v1");
  assert.equal(parseLocalModelConfig({ baseUrl: "http://[::1]:11434" }).baseUrl, "http://[::1]:11434");
  for (const baseUrl of ["https://example.com", "http://8.8.8.8", "http://user:secret@localhost:11434", "http://localhost:11434?key=secret", "file:///etc/passwd"]) {
    assert.throws(() => parseLocalModelConfig({ baseUrl }));
  }
  assert.equal(localModelRecommendation(8 * 1024 ** 3, "arm64").model, "qwen3:1.7b");
  assert.equal(localModelRecommendation(16 * 1024 ** 3, "arm64").model, "qwen3:4b");
  assert.equal(localModelRecommendation(32 * 1024 ** 3, "arm64").model, "qwen3:8b");
  assert.equal(localModelRecommendation(64 * 1024 ** 3, "x64").model, "qwen3:4b");
});

test("Ollama 模型目录与本地 JSON 请求使用实际用量且关闭思考", async t => {
  let sent: Record<string, unknown> | undefined;
  const endpoint = await server(t, (request, response) => {
    if (request.url === "/api/tags") { response.end(JSON.stringify({ models: [{ name: "qwen3:4b" }] })); return; }
    assert.equal(request.url, "/api/chat");
    void body(request).then(value => {
      sent = value;
      response.setHeader("x-request-id", "ollama-trace");
      response.end(JSON.stringify({ model: "qwen3:4b", message: { content: '{"ok":true}' }, prompt_eval_count: 42, eval_count: 8 }));
    });
  });
  const backend = new LocalModelBackend({ provider: "ollama", baseUrl: endpoint, model: "qwen3:4b" });
  assert.deepEqual(await backend.models(), ["qwen3:4b"]);
  const result = await backend.run({ agentRole: "context-analyst", prompt: "测试" });
  assert.equal(sent?.think, false);
  assert.equal(sent?.stream, false);
  assert.equal(sent?.format, "json");
  assert.equal(result.usage?.totalTokens, 50);
  assert.equal(result.reasoningEffort, "off");
  assert.equal(result.upstreamRequestId, "ollama-trace");
  assert.equal(result.requestPath, "/api/chat");
});

test("LM Studio 复用 OpenAI 用量语义，缓存不双计且显式关闭思考", async t => {
  const endpoint = await server(t, (request, response) => {
    assert.equal(request.headers.authorization, "Bearer fixture-secret");
    if (request.url === "/v1/models") { response.end(JSON.stringify({ data: [{ id: "qwen3-local" }] })); return; }
    response.end(JSON.stringify({ id: "lm-request", model: "qwen3-local", choices: [{ message: { content: "done" }, finish_reason: "stop" }],
      usage: { prompt_tokens: 100, completion_tokens: 20, prompt_tokens_details: { cached_tokens: 60 }, total_tokens: 120 } }));
  });
  const backend = new LocalModelBackend(parseLocalModelConfig({ provider: "lmstudio", baseUrl: endpoint, model: "qwen3-local", apiKey: "fixture-secret" }));
  assert.deepEqual(await backend.models(), ["qwen3-local"]);
  const result = await backend.run({ prompt: "test" });
  assert.deepEqual(result.usage, { inputTokens: 40, outputTokens: 20, cacheReadTokens: 60, cacheWriteTokens: 0, totalTokens: 120 });
  assert.equal(result.reasoningEffort, "off");
  assert.equal(result.upstreamRequestId, "lm-request");
});

test("LM Studio 后台请求使用字段级 JSON Schema，避免无效格式和思考占用最终回答", async t => {
  const schema = { type: "object", properties: { ok: { type: "boolean" } }, required: ["ok"], additionalProperties: false };
  const endpoint = await server(t, (request, response) => {
    void body(request).then(value => {
      if (value.response_format?.type !== "json_schema") {
        response.writeHead(400); response.end("'response_format.type' must be 'json_schema' or 'text'"); return;
      }
      assert.deepEqual(value.response_format.json_schema.schema, schema);
      assert.equal(value.response_format.json_schema.strict, true);
      assert.equal(value.reasoning_effort, "none");
      response.end(JSON.stringify({ choices: [{ message: { content: '{"ok":true}', reasoning_content: "" }, finish_reason: "stop" }] }));
    });
  });
  const backend = new LocalModelBackend(parseLocalModelConfig({ provider: "lmstudio", baseUrl: endpoint, model: "qwen-local" }));
  const result = await backend.run({ agentRole: "context-analyst", prompt: '只返回 JSON：{"ok":true}', responseSchema: schema });
  assert.deepEqual(JSON.parse(result.text), { ok: true });
  assert.equal(backend.status().available, true);
});

test("LM Studio 只有思考而无最终回答时不能冒充连接成功", async t => {
  const endpoint = await server(t, (_request, response) => {
    response.end(JSON.stringify({ choices: [{ message: { content: "", reasoning_content: '{"ok":true}' }, finish_reason: "stop" }] }));
  });
  const backend = new LocalModelBackend(parseLocalModelConfig({ provider: "lmstudio", baseUrl: endpoint, model: "qwen-local" }));
  await assert.rejects(backend.run({ agentRole: "context-analyst", prompt: "测试" }), /没有返回有效文本/);
  assert.equal(backend.status().available, false);
});

for (const provider of ["ollama", "lmstudio"] as const) {
  test(`${provider} 输出截断时保留实际 Token 用量并记录失败`, async t => {
    const endpoint = await server(t, (_request, response) => {
      response.setHeader("x-request-id", "truncated-request");
      response.end(JSON.stringify(provider === "ollama"
        ? { message: { content: '{"draft":"unfinished' }, done_reason: "length", prompt_eval_count: 42, eval_count: 8 }
        : { choices: [{ message: { content: '{"draft":"unfinished' }, finish_reason: "length" }], usage: { prompt_tokens: 42, completion_tokens: 8, total_tokens: 50 } }));
    });
    const backend = new LocalModelBackend(parseLocalModelConfig({ provider, baseUrl: endpoint, model: "fixture" }));
    let report: PiRunUsage | undefined;
    await assert.rejects(backend.run({ prompt: "test", onUsage: value => { report = value; } }), /长度限制/);
    assert.equal(report?.outcome, "failed");
    assert.equal(report?.usage?.totalTokens, 50);
    assert.equal(report?.upstreamRequestId, "truncated-request");
    assert.equal(backend.status().available, false);
  });
}

test("本地服务重定向和取消不会泄漏响应正文或被当作成功", async t => {
  const endpoint = await server(t, (_request, response) => {
    response.writeHead(302, { Location: "http://127.0.0.1:1/private-secret" }); response.end("private-secret");
  });
  const backend = new LocalModelBackend({ provider: "ollama", baseUrl: endpoint, model: "fixture" });
  await assert.rejects(backend.run({ prompt: "test" }), error => error instanceof Error && !error.message.includes("private-secret"));
  const controller = new AbortController(); controller.abort();
  await assert.rejects(backend.run({ prompt: "test", signal: controller.signal }), /取消|超时/);
});

test("旧配置中的远端协助和自动草稿开关不再保留", () => {
  const config = parseProactiveConfig({ allowRemoteEscalation: false, autoDraft: false });
  assert.deepEqual(config, DEFAULT_PROACTIVE);
  assert.equal(Object.hasOwn(config, "allowRemoteEscalation"), false);
  assert.equal(Object.hasOwn(config, "autoDraft"), false);
});

const fast = { ...parseProactiveConfig({ allowRemoteEscalation: false, autoDraft: false }), workIntervalMs: 10, notificationsIntervalMs: 1000, synthesisIntervalMs: 10000, taskSpacingMs: 1, suggestionCooldownMs: 100 };
const analysis = { summary: "构建失败需要定位原因", actionable: true, evidence: ["终端提示构建失败"] };
const suggestion = { suggest: true, title: "处理构建失败", message: "先核对错误位置", reason: "构建被阻塞", sources: ["work"], draft: "处理方案：检查报错文件；修复类型不匹配后重新运行构建。" };

function routingFixture(remoteNeeded: boolean, remoteConfigured = true, failRemote = false) {
  let now = 0, localCalls = 0, remoteCalls = 0;
  const events = new EventBus();
  const received: AgentEvent[] = [];
  const coordinator = new ProactiveCoordinator({ config: { ...fast }, events, now: () => new Date(now),
    run: async request => {
      localCalls++;
      return { text: JSON.stringify(request.agentRole === "proactive-parent" ? remoteNeeded ? { needsRemote: true, reason: "需要分析多处构建依赖", sources: ["work"] } : suggestion : analysis) };
    },
    runRemote: async () => { remoteCalls++; if (failRemote) throw new Error("fixture failed"); return { text: JSON.stringify(suggestion) }; },
    remoteConfigured: () => remoteConfigured, canSuggest: () => true, recentSuggestions: () => [],
  });
  coordinator.registerSources(["work"]);
  events.subscribe(event => {
    received.push(event);
    if (event.kind === "context.request") coordinator.receive({ requestId: String(event.payload.requestId), source: "work", status: "ok", content: { appName: "Terminal", text: "构建失败" } });
  });
  return { coordinator, received, counts: () => ({ localCalls, remoteCalls }), tick: async (at: number) => { now = at; coordinator.tick(true); await coordinator.settle(); } };
}

test("本地能完成的任务直接生成带草稿的建议，远端零调用", async () => {
  const f = routingFixture(false);
  await f.tick(10); await f.tick(11);
  assert.deepEqual(f.counts(), { localCalls: 2, remoteCalls: 0 });
  const produced = f.received.find(event => event.kind === "proactive.suggestion");
  assert.equal(produced?.payload.draft, suggestion.draft);
  assert.equal(produced?.payload.route, "local");
  assert.ok(f.received.some(event => event.payload.appName === "Terminal" && event.payload.category === "context" && event.payload.phase === "completed"));
});

test("旧配置关闭选项不影响有依据的远端升级，未配置远端仍不调用", async () => {
  const allowed = routingFixture(true);
  await allowed.tick(10); await allowed.tick(11);
  assert.equal(allowed.counts().remoteCalls, 1);
  assert.equal(allowed.received.find(event => event.kind === "proactive.suggestion")?.payload.route, "remote");
  assert.equal(allowed.received.find(event => event.kind === "proactive.suggestion")?.payload.draft, suggestion.draft);
  assert.ok(allowed.received.some(event => event.payload.action === "升级远端"));
  const denied = routingFixture(true, false);
  await denied.tick(10); await denied.tick(11);
  assert.equal(denied.counts().remoteCalls, 0);
  assert.equal(denied.coordinator.snapshot().tasks.synthesis.state, "unavailable");
  assert.ok(denied.received.some(event => event.payload.action === "需要远端协助"));
});

test("远端失败后同一批事实不会反复升级计费", async () => {
  const f = routingFixture(true, true, true);
  for (const at of [10, 11, 100, 101, 10000, 30000, 50000]) await f.tick(at);
  assert.equal(f.counts().remoteCalls, 1);
  assert.ok(f.received.some(event => event.payload.action === "分析未完成"));
});

test("未配置本地模型时即使远端已配置也不后台调用", async t => {
  const dir = await mkdtemp(join(tmpdir(), "another-you-local-gate-")); t.after(() => rm(dir, { recursive: true, force: true }));
  let calls = 0, now = 0;
  const backend: PiAgentBackend = { source: { repository: "test", ref: "test", commit: "test" }, run: async () => { calls++; return { text: "remote" }; } };
  const config = createDefaultConfig(dir); config.proactive = { ...fast };
  const core = new AgentCore({ config, backend, rules: [], now: () => new Date(now) });
  t.after(() => core.stop());
  core.registerContextSources(["work"]); core.start(); now = 10000; core.tick(); await core.settleBackground();
  assert.equal(calls, 0);
  assert.equal((core.status().localModel as { configured: boolean }).configured, false);
});

test("自动草稿创建可继续的真实会话，保留来源和用量，内容开关仍生效", async t => {
  const dir = await mkdtemp(join(tmpdir(), "another-you-local-draft-")); t.after(() => rm(dir, { recursive: true, force: true }));
  const config = createDefaultConfig(dir); config.proactive = { ...fast };
  let now = 0, remoteCalls = 0;
  const local: PiAgentBackend = { source: { repository: "local", ref: "test", commit: "test" }, run: async request => ({
    text: JSON.stringify(request.agentRole === "proactive-parent" ? suggestion : analysis), model: "local-fixture",
    usage: { inputTokens: 10, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 15 }, reasoningEffort: "off",
  }) };
  const remote: PiAgentBackend = { source: local.source, run: async () => { remoteCalls++; return { text: "continued" }; } };
  const core = new AgentCore({ config, backend: remote, localBackend: local, rules: [], now: () => new Date(now) });
  t.after(() => core.stop());
  core.events.subscribe(event => {
    if (event.kind === "context.request") core.receiveContext({ requestId: String(event.payload.requestId), source: "work", status: "ok", content: { appName: "Terminal", text: "构建失败" } });
  });
  core.registerContextSources(["work"]); core.start();
  for (const at of [10, 11]) { now = at; core.tick(); await core.settleBackground(); }
  const status = core.status();
  const sessions = status.conversations as { id: string; appName: string; messages: { response: string }[] }[];
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].messages[0].response, suggestion.draft);
  assert.equal(sessions[0].appName, "Terminal");
  assert.equal((status.proposals as unknown[]).length, 0);
  assert.equal(remoteCalls, 0);
  const records = status.usageRecords as { runId: string; route: string; appName: string }[];
  assert.equal(records.length, 2); assert.ok(records.every(record => record.runId && record.route === "local" && record.appName === "Terminal"));
  await core.prompt("followup", "继续", undefined, false, sessions[0].id);
  assert.equal(remoteCalls, 1);
  config.privacy.storePrompts = false; core.setPaused(true);
  const disk = await readFile(join(dir, "state.json"), "utf8");
  assert.equal(disk.includes(suggestion.draft), false);
  assert.equal(disk.includes("Terminal"), false);
});

test("本地配置回执保存、模型目录、真实测试、取消均不向界面泄漏令牌", async t => {
  const dir = await mkdtemp(join(tmpdir(), "another-you-local-config-")); t.after(() => rm(dir, { recursive: true, force: true }));
  const endpoint = await server(t, (request, response) => {
    if (request.url === "/api/tags") { response.end(JSON.stringify({ models: [{ name: "fixture" }] })); return; }
    response.end(JSON.stringify({ message: { content: '{"ok":true}' }, prompt_eval_count: 4, eval_count: 1 }));
  });
  const core = new AgentCore({ config: createDefaultConfig(dir), rules: [] });
  const received: AgentEvent[] = [];
  const handler = new LocalModelCommandHandler(core, join(dir, "config.json"), event => received.push(event), () => {});
  const run = async (op: string, extra: Record<string, unknown> = {}) => {
    const requestId = String(received.length);
    handler.handle({ op, requestId, ...extra });
    for (let attempt = 0; attempt < 200 && !received.some(event => event.payload.requestId === requestId && ["succeeded", "failed"].includes(String(event.payload.state))); attempt++) await new Promise(resolve => setTimeout(resolve, 5));
    await new Promise(resolve => setTimeout(resolve, 0));
    return [...received].reverse().find(event => event.payload.requestId === requestId)!;
  };
  const config = await run("localModelConfigure", { localModel: { provider: "ollama", baseUrl: endpoint, model: "fixture", apiKey: "do-not-echo" } });
  assert.equal(config.payload.state, "succeeded");
  assert.equal((await run("localModelTest")).payload.state, "succeeded");
  assert.equal(JSON.stringify(core.status()).includes("do-not-echo"), false);
  assert.equal(JSON.stringify(received).includes("do-not-echo"), false);
  const legacy = await run("localModelConfigure", { localModel: { provider: "ollama", baseUrl: endpoint, model: "fixture" }, allowRemoteEscalation: false, autoDraft: false });
  assert.equal(legacy.payload.state, "succeeded");
  const saved = JSON.parse(await readFile(join(dir, "config.json"), "utf8"));
  assert.equal(saved.proactive.localModel.apiKey, "do-not-echo");
  for (const key of ["allowRemoteEscalation", "autoDraft"]) {
    assert.equal(Object.hasOwn(saved.proactive, key), false);
    assert.equal(Object.hasOwn(core.status().localModel as object, key), false);
  }
  await handler.close();
});
