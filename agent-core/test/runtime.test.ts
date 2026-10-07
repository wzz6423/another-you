import { strict as assert } from "node:assert";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import test, { type TestContext } from "node:test";
import { AgentCore, type AgentEvent, type AgentConfig, type Proposal, type TriggerRule, createDefaultConfig, parseAgentConfig, saveConfig, PiSdkBackend } from "../src/index.ts";

import { usePiFixture } from "./pi-fixture.ts";
import { writeModelData } from "./model-storage-fixture.ts";

type Body = Record<string, unknown>;
interface ModelRequest { url: string; headers: IncomingMessage["headers"]; body: Body }

async function modelServer(t: TestContext, respond?: (res: ServerResponse, request: ModelRequest) => void) {
  const requests: ModelRequest[] = [];
  const server = createServer(async (req, res) => {
    let body = "";
    for await (const part of req) body += part;
    const request = { url: req.url ?? "", headers: req.headers, body: body ? JSON.parse(body) as Body : {} };
    requests.push(request);
    if (respond) respond(res, request);
    else {
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.end(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", model: "fixture", choices: [{ index: 0, delta: { role: "assistant", content: "这是可审阅的本地草稿。" }, finish_reason: null }] })}\n\ndata: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", model: "fixture", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\ndata: [DONE]\n\n`);
    }
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(async () => { server.closeAllConnections(); await new Promise<void>((done) => server.close(() => done())); });
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  return { endpoint: `http://127.0.0.1:${address.port}/v1`, requests };
}

async function configFor(t: TestContext, endpoint?: string): Promise<AgentConfig> {
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-runtime-"));
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const config = createDefaultConfig(dataDir);
  await usePiFixture(t, dataDir, endpoint);
  return config;
}

const eventRule: TriggerRule = { id: "test", type: "event", eventName: "test", title: "整理想法", message: "生成待确认草稿", cooldownMs: 60_000 };
function proposalList(core: AgentCore): Proposal[] { return core.status().proposals as Proposal[]; }

async function childCore(t: TestContext, config: AgentConfig) {
  const configPath = join(config.dataDir, "config.json");
  await saveConfig(config, configPath);
  const child: ChildProcessWithoutNullStreams = spawn(process.execPath, ["--experimental-strip-types", resolve("src/cli.ts"), "--stdio", "--config", configPath], { stdio: "pipe" });
  const events: AgentEvent[] = [];
  let stderr = "";
  child.stderr.on("data", (part) => { stderr += String(part); });
  const lines = createInterface({ input: child.stdout });
  lines.on("line", (line) => events.push(JSON.parse(line) as AgentEvent));
  const exit = once(child, "exit");
  t.after(async () => { if (child.exitCode === null) { child.kill("SIGTERM"); await exit; } lines.close(); });
  const send = (command: Body): void => { child.stdin.write(`${JSON.stringify(command)}\n`); };
  const wait = async (predicate: (event: AgentEvent) => boolean, after = 0, timeoutMs = 8000): Promise<AgentEvent> => {
    const existing = events.slice(after).find(predicate);
    if (existing) return existing;
    return new Promise((resolveEvent, reject) => {
      const timer = setTimeout(() => { lines.removeListener("line", onLine); reject(new Error(`未收到预期事件：${stderr}`)); }, timeoutMs);
      const onLine = (line: string) => {
        const event = JSON.parse(line) as AgentEvent;
        if (predicate(event)) { clearTimeout(timer); lines.removeListener("line", onLine); resolveEvent(event); }
      };
      lines.on("line", onLine);
    });
  };
  await wait((event) => event.kind === "agent.status");
  return { child, events, send, wait, exit, stderr: () => stderr };
}

test("官方 Pi SDK 调用本地 HTTP 模型并提供真实工具", async (t) => {
  const server = await modelServer(t);
  const config = await configFor(t, server.endpoint);
  const backend = new PiSdkBackend(config);
  await backend.initialize();
  assert.equal(backend.status().available, null);
  const response = await backend.run({ prompt: "帮我整理一个空白计划" });
  assert.equal(response.text, "这是可审阅的本地草稿。");
  assert.equal(server.requests.length, 1);
  assert.equal(server.requests[0].url, "/v1/chat/completions");
  assert.equal(server.requests[0].body.model, "fixture");
  assert.equal(server.requests[0].headers.authorization, "Bearer another-you-fixture");
  const toolNames = (server.requests[0].body.tools as { function: { name: string } }[]).map((tool) => tool.function.name);
  for (const name of ["filesystem", "network", "shell"]) assert.ok(toolNames.includes(name));
  assert.equal(backend.status().available, true);
});

test("后台子 agent 与父 agent 使用独立角色且没有执行工具", async (t) => {
  const server = await modelServer(t);
  const config = await configFor(t, server.endpoint);
  const backend = new PiSdkBackend(config);
  t.after(() => backend.close());
  for (const agentRole of ["context-analyst", "notification-analyst", "proactive-parent"] as const) {
    const response = await backend.run({ agentRole, prompt: "分析 fixture 数据" });
    assert.equal(response.metadata?.toolsEnabled, false);
    assert.equal(response.metadata?.agentRole, agentRole);
    const request = server.requests.at(-1)!;
    assert.equal((request.body.tools as unknown[] | undefined)?.length ?? 0, 0);
    assert.match(JSON.stringify(request.body.messages), agentRole === "proactive-parent" ? /汇总父 agent/ : /分析子 agent/);
  }
});

test("Pi 未设置默认模型时明确未配置且忽略旧应用模型配置", async (t) => {
  const server = await modelServer(t);
  const config = await configFor(t, server.endpoint);
  await writeModelData(join(config.dataDir, "pi", "settings.json"), "{}");
  const legacy = parseAgentConfig({ ...config, model: { provider: "local", model: "fixture", endpoint: server.endpoint } });
  const backend = new PiSdkBackend(legacy);
  await backend.initialize();
  assert.equal(backend.status().configured, false);
  assert.match(backend.status().message, /设置中选择模型/);
  await assert.rejects(backend.run({ prompt: "你好" }), /设置中选择模型/);
  assert.equal(server.requests.length, 0);
  assert.equal("model" in legacy, false);
});


test("模型重定向不能带走私有内容或密钥", async (t) => {
  const target = await modelServer(t);
  const redirect = await modelServer(t, (res) => { res.writeHead(307, { location: `${target.endpoint}/chat/completions` }); res.end(); });
  const config = await configFor(t, redirect.endpoint);
  const backend = new PiSdkBackend(config);
  await assert.rejects(backend.run({ prompt: "不能被重定向的内容" }));
  assert.equal(redirect.requests.length, 1);
  assert.equal(target.requests.length, 0);
  assert.equal(backend.status().available, false);
});

test("模型错误真实上报且不重试或伪造回复", async (t) => {
  const server = await modelServer(t, (res) => { res.writeHead(503, { "content-type": "application/json" }); res.end(JSON.stringify({ error: { message: "model unavailable", type: "unavailable" } })); });
  const config = await configFor(t, server.endpoint);
  const backend = new PiSdkBackend(config);
  await assert.rejects(backend.run({ prompt: "hello" }), /503|unavailable/);
  assert.equal(server.requests.length, 1);
  assert.equal(backend.status().available, false);
});

test("建议批准只生成草稿，完成后和重启后都拒绝重复执行", async (t) => {
  const server = await modelServer(t);
  const config = await configFor(t, server.endpoint);
  const core = new AgentCore({ config, rules: [eventRule] });
  const suggestion = core.signal({ type: "event", name: "test" })[0];
  await core.decide(suggestion.id, "execute");
  assert.equal(proposalList(core)[0].state, "completed");
  await assert.rejects(core.decide(suggestion.id, "execute"), /已处理/);
  const restored = new AgentCore({ config });
  await assert.rejects(restored.decide(suggestion.id, "execute"), /已处理/);
  assert.equal(server.requests.length, 1);
  assert.equal(restored.signal({ type: "event", name: "test" }).length, 0);
});

test("稍后真正延迟并在重启后到时恢复，暂停保持状态", async (t) => {
  const config = await configFor(t);
  let now = new Date("2026-10-01T04:00:00Z");
  const core = new AgentCore({ config, rules: [eventRule], now: () => now });
  const suggestion = core.signal({ type: "event", name: "test" })[0];
  await core.decide(suggestion.id, "later", 15);
  now = new Date(now.getTime() + 14 * 60_000);
  const restored = new AgentCore({ config, now: () => now });
  assert.equal(restored.tick(now).length, 0);
  assert.equal(restored.signal({ type: "event", name: "test" }).length, 0);
  restored.setPaused(true);
  now = new Date(now.getTime() + 2 * 60_000);
  assert.equal(restored.tick(now).length, 0);
  const paused = new AgentCore({ config, now: () => now });
  assert.equal(paused.status().paused, true);
  paused.setPaused(false);
  assert.equal(proposalList(paused)[0].state, "pending");
  assert.equal(paused.tick(now).length, 0);
  await paused.decide(suggestion.id, "ignore");
  await assert.rejects(paused.decide(suggestion.id, "execute"), /已处理/);
});

test("禁用内容保存时，提示、回复、事件私文和上下文不写入状态", async (t) => {
  const server = await modelServer(t);
  const config = await configFor(t, server.endpoint);
  config.privacy.storePrompts = false;
  config.privacy.storeResponses = false;
  const secret = "我的私人项目资料无需匹配密钥正则";
  const core = new AgentCore({ config, rules: [{ ...eventRule, context: { private: secret } }] });
  core.signal({ type: "event", name: "test", payload: { personal: secret }, dedupeKey: secret });
  await core.prompt("privacy", secret);
  const disk = await readFile(join(config.dataDir, "state.json"), "utf8");
  assert.equal(disk.includes(secret), false);
  assert.equal(disk.includes("这是可审阅的本地草稿"), false);
  assert.equal((JSON.parse(disk).history as AgentEvent[]).some((event) => event.kind === "agent.response"), true);
});

test("开启保存仍会隐藏常见凭据及嵌套 token 字段", async (t) => {
  const config = await configFor(t);
  const secret = "sk-testprivatecredential123456789";
  const core = new AgentCore({ config, rules: [{ ...eventRule, context: { token: "nested-private-value" } }] });
  core.signal({ type: "event", name: "test", payload: { note: secret } });
  const disk = await readFile(join(config.dataDir, "state.json"), "utf8");
  assert.equal(disk.includes(secret), false);
  assert.equal(disk.includes("nested-private-value"), false);
  assert.equal(disk.includes("已隐藏密钥"), true);
});

test("禁用内容保存也隐藏模型错误里回显的私人请求", async (t) => {
  const secret = "这是服务端回显的私人输入";
  const server = await modelServer(t, (res) => {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: secret, type: "invalid_request_error" } }));
  });
  const config = await configFor(t, server.endpoint);
  config.privacy.storePrompts = false;
  config.privacy.storeResponses = false;
  const core = new AgentCore({ config, rules: [] });
  const received: AgentEvent[] = [];
  core.events.subscribe((event) => received.push(event));
  await core.prompt("private-error", secret);
  assert.equal(received.some((event) => event.kind === "agent.error" && String(event.payload.message).includes(secret)), true);
  const disk = await readFile(join(config.dataDir, "state.json"), "utf8");
  assert.equal(disk.includes(secret), false);
});

test("进程中断的运行中建议恢复为失败，避免自动重复模型执行", async (t) => {
  const config = await configFor(t);
  const core = new AgentCore({ config, rules: [eventRule] });
  core.signal({ type: "event", name: "test" });
  const path = join(config.dataDir, "state.json");
  const state = JSON.parse(await readFile(path, "utf8"));
  state.proposals[0].state = "running";
  await writeFile(path, JSON.stringify(state));
  const restored = new AgentCore({ config });
  assert.equal(proposalList(restored)[0].state, "failed");
});

test("JSONL 子进程完成建议、prompt、错误和重启恢复闭环", async (t) => {
  const server = await modelServer(t);
  const config = await configFor(t, server.endpoint);
  const proc = await childCore(t, config);
  proc.send({ op: "addRule", rule: eventRule });
  proc.send({ op: "signal", signal: { type: "event", name: "test" } });
  const suggestion = await proc.wait((event) => event.kind === "proactive.suggestion");
  const id = suggestion.payload.suggestionId;
  proc.send({ op: "decide", suggestionId: id, decision: "execute" });
  const completed = await proc.wait((event) => event.kind === "proposal.updated" && event.payload.state === "completed");
  assert.equal(completed.payload.text, "这是可审阅的本地草稿。");
  await proc.wait((event) => event.kind === "agent.status" && (event.payload.model as Body).available === true);
  proc.send({ op: "prompt", requestId: "chat-1", prompt: "整理空白计划" });
  await proc.wait((event) => event.kind === "agent.response" && event.payload.requestId === "chat-1");
  proc.send({ op: "decide", suggestionId: id, decision: "execute" });
  await proc.wait((event) => event.kind === "agent.error" && String(event.payload.message).includes("已处理"));
  const marker = proc.events.length;
  proc.child.stdin.write("not json\n");
  await proc.wait((event) => event.kind === "agent.error", marker);
  assert.equal(proc.events.slice(marker).filter((event) => event.kind === "agent.error").length, 1);
  proc.send({ op: "shutdown" });
  assert.equal((await proc.exit)[0], 0, proc.stderr());
  const restored = await childCore(t, config);
  const status = await restored.wait((event) => event.kind === "agent.status");
  assert.equal((status.payload.proposals as Proposal[]).find((proposal) => proposal.id === id)?.state, "completed");
  assert.equal(restored.events.filter((event) => event.kind === "proactive.suggestion").length, 0);
  restored.send({ op: "shutdown" });
  assert.equal((await restored.exit)[0], 0, restored.stderr());
  assert.equal(server.requests.length, 2);
});

test("模型挂起时仍能暂停、查询、拒绝同会话重复发送并及时关闭", async (t) => {
  const server = await modelServer(t, () => {});
  const config = await configFor(t, server.endpoint);
  const proc = await childCore(t, config);
  proc.send({ op: "prompt", requestId: "slow", prompt: "等模型回复" });
  await proc.wait((event) => event.kind === "agent.request");
  const marker = proc.events.length;
  proc.send({ op: "pause" });
  await proc.wait((event) => event.kind === "agent.status" && event.payload.paused === true, marker, 1500);
  proc.send({ op: "status" });
  await proc.wait((event) => event.kind === "agent.status" && event.payload.paused === true, marker, 1500);
  proc.send({ op: "prompt", requestId: "busy", prompt: "不要并发" });
  await proc.wait((event) => event.kind === "agent.error" && event.payload.requestId === "busy", marker, 1500);
  const before = Date.now();
  proc.send({ op: "shutdown" });
  const result = await Promise.race([proc.exit, new Promise<never>((_, reject) => { const timer = setTimeout(() => reject(new Error("关闭超时")), 3000); timer.unref(); })]);
  assert.equal(result[0], 0, proc.stderr());
  assert.ok(Date.now() - before < 3000);
  assert.equal(proc.events.some((event) => event.kind === "agent.response"), false);
});

test("JSONL 并行会话分别生成，取消新会话不影响旧会话且全部历史可恢复", async (t) => {
  const held = new Map<string, ServerResponse>();
  const server = await modelServer(t, (res, request) => {
    const input = JSON.stringify(request.body.messages);
    for (const name of ["older", "newer", "cancelled"]) if (input.includes(`CONCURRENT_${name}`)) held.set(name, res);
  });
  const config = await configFor(t, server.endpoint);
  config.scheduler.enabled = false;
  config.proactive.enabled = false;
  const proc = await childCore(t, config);
  const waitForRequest = async (name: string) => {
    for (let attempt = 0; attempt < 500 && !held.has(name); attempt++) await new Promise(resolve => setTimeout(resolve, 10));
    assert.ok(held.has(name), `${name} must reach the model before the older request finishes`);
  };
  const reply = (name: string) => {
    const response = held.get(name)!;
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(`data: ${JSON.stringify({ id: name, choices: [{ index: 0, delta: { role: "assistant", content: `RESULT_${name}` }, finish_reason: "stop" }] })}\n\ndata: [DONE]\n\n`);
  };
  for (const name of ["older", "newer", "cancelled"]) {
    proc.send({ op: "prompt", requestId: `request-${name}`, conversationId: name, prompt: `CONCURRENT_${name}` });
    await waitForRequest(name);
  }
  assert.equal(server.requests.length, 3);
  for (const request of server.requests) {
    assert.equal((JSON.stringify(request.body.messages).match(/CONCURRENT_/g) ?? []).length, 1);
  }
  proc.send({ op: "prompt", requestId: "duplicate-older", conversationId: "older", prompt: "不能重复发送" });
  const duplicate = await proc.wait(event => event.kind === "agent.error" && event.payload.requestId === "duplicate-older");
  assert.match(String(duplicate.payload.message), /当前会话正在处理请求/);
  assert.equal(server.requests.length, 3);
  reply("newer");
  await proc.wait(event => event.kind === "agent.response" && event.payload.conversationId === "newer");
  assert.equal(proc.events.some(event => event.kind === "agent.response" && event.payload.conversationId === "older"), false);
  proc.send({ op: "cancel", conversationId: "cancelled" });
  await proc.wait(event => event.kind === "agent.error" && event.payload.requestId === "request-cancelled");
  const marker = proc.events.length;
  proc.send({ op: "status" });
  const status = await proc.wait(event => event.kind === "agent.status", marker);
  const summaries = status.payload.conversations as { id: string; state: string }[];
  assert.equal(summaries.find(session => session.id === "older")?.state, "running");
  assert.equal(summaries.find(session => session.id === "newer")?.state, "completed");
  assert.equal(summaries.find(session => session.id === "cancelled")?.state, "failed");
  reply("older");
  await proc.wait(event => event.kind === "agent.response" && event.payload.conversationId === "older");
  proc.send({ op: "shutdown" });
  assert.equal((await proc.exit)[0], 0, proc.stderr());
  const restored = await childCore(t, config);
  for (const name of ["older", "newer", "cancelled"]) {
    restored.send({ op: "conversationRead", conversationId: name, readId: name });
    const event = await restored.wait(event => event.kind === "conversation.messages" && event.payload.readId === name);
    const session = event.payload.conversation as { state: string; messages: { prompt: string; response?: string; error?: string }[] };
    assert.equal(session.messages.length, 1);
    assert.equal(session.messages[0].prompt, `CONCURRENT_${name}`);
    if (name === "cancelled") { assert.equal(session.state, "failed"); assert.ok(session.messages[0].error); }
    else { assert.equal(session.state, "completed"); assert.equal(session.messages[0].response, `RESULT_${name}`); }
  }
  restored.send({ op: "shutdown" });
  assert.equal((await restored.exit)[0], 0, restored.stderr());
});

test("JSONL 关闭会取消并等待全部并行请求，完整保存各自失败历史", async (t) => {
  const server = await modelServer(t, () => {});
  const config = await configFor(t, server.endpoint);
  config.scheduler.enabled = false;
  config.proactive.enabled = false;
  const proc = await childCore(t, config);
  const names = ["shutdown-older", "shutdown-newer", "shutdown-third"];
  for (const name of names) proc.send({ op: "prompt", requestId: name, conversationId: name, prompt: `等待 ${name}` });
  for (let attempt = 0; attempt < 500 && server.requests.length < names.length; attempt++) await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(server.requests.length, names.length);
  proc.send({ op: "shutdown" });
  const result = await Promise.race([proc.exit, new Promise<never>((_, reject) => {
    const timer = setTimeout(() => reject(new Error("并行请求关闭超时")), 3000);
    timer.unref();
  })]);
  assert.equal(result[0], 0, proc.stderr());
  assert.equal(proc.events.some(event => event.kind === "agent.response"), false);
  for (const name of names) {
    assert.equal(proc.events.filter(event => event.kind === "agent.error" && event.payload.requestId === name).length, 1);
    assert.equal(proc.events.filter(event => event.kind === "agent.usage" && event.payload.requestId === name && event.payload.outcome === "failed").length, 1);
  }
  const saved = JSON.parse(await readFile(join(config.dataDir, "state.json"), "utf8")) as {
    conversations: { id: string; state: string; messages: { id: string; prompt: string; response?: string; error?: string }[] }[];
  };
  assert.equal(saved.conversations.length, names.length);
  for (const name of names) {
    const session = saved.conversations.find(session => session.id === name)!;
    assert.equal(session.state, "failed");
    assert.equal(session.messages.length, 1);
    assert.equal(session.messages[0].id, name);
    assert.equal(session.messages[0].prompt, `等待 ${name}`);
    assert.equal(session.messages[0].response, undefined);
    assert.ok(session.messages[0].error);
  }
});

test("旧 strict-local 配置迁移完全权限，拒绝持久化明文 API 密钥", () => {
  const config = parseAgentConfig({ privacy: { mode: "strict-local", allowNetwork: true }, model: { endpoint: "https://external.example/v1" } });
  assert.equal(config.privacy.allowNetwork, true);
  assert.equal("model" in config, false);
  assert.equal(JSON.stringify(parseAgentConfig({ model: { apiKey: "never-store-this" } })).includes("never-store-this"), false);
});


test("Pi 工具循环实际执行命令并累计每轮 token 和失败前用量", async (t) => {
  let turn = 0;
  const server = await modelServer(t, (res, request) => {
    turn += 1;
    const first = turn === 1;
    if (!first) {
      const messages = request.body.messages as { role: string; content: string }[];
      assert.ok(messages.some((message) => message.role === "tool" && message.content.includes("tool-integration-ok")));
    }
    res.writeHead(200, { "content-type": "text/event-stream" });
    const delta = first
      ? { role: "assistant", tool_calls: [{ index: 0, id: "tool-1", type: "function", function: { name: "shell", arguments: JSON.stringify({ command: "printf tool-integration-ok" }) } }] }
      : { role: "assistant", content: "命令已完成" };
    const chunks = [
      { id: `turn-${turn}`, choices: [{ index: 0, delta, finish_reason: null }] },
      { id: `turn-${turn}`, choices: [{ index: 0, delta: {}, finish_reason: first ? "tool_calls" : "stop" }], usage: { prompt_tokens: 20, completion_tokens: 5, total_tokens: 25 } },
    ];
    res.end(chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n");
  });
  const backend = new PiSdkBackend(await configFor(t, server.endpoint));
  let summary: unknown;
  const response = await backend.run({ prompt: "执行测试命令", onUsage: (value) => { summary = value; } });
  assert.equal(response.text, "命令已完成");
  assert.equal(server.requests.length, 2);
  assert.deepEqual(response.toolCalls, [{ name: "shell", kind: "tool" }]);
  assert.deepEqual(response.usage, { inputTokens: 40, outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 50 });
  assert.equal(response.reasoningEffort, "off");
  assert.deepEqual(summary, { model: "fixture", outcome: "completed", usage: response.usage, reasoningEffort: "off", toolCalls: response.toolCalls, requestPath: "/v1/chat/completions" });
});

test("工具执行后模型失败仍报告已消耗 token，未报告用量保持未知", async (t) => {
  let turn = 0;
  const server = await modelServer(t, (res) => {
    if (++turn > 1) { res.writeHead(503); res.end("unavailable"); return; }
    res.writeHead(200, { "content-type": "text/event-stream" });
    const chunk = { id: "failed-turn", choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: "tool-failed", type: "function", function: { name: "shell", arguments: JSON.stringify({ command: "printf done" }) } }] }, finish_reason: "tool_calls" }], usage: { prompt_tokens: 12, completion_tokens: 3, total_tokens: 15 } };
    res.end(`data: ${JSON.stringify(chunk)}\n\ndata: [DONE]\n\n`);
  });
  const backend = new PiSdkBackend(await configFor(t, server.endpoint));
  let summary: import("../src/pi-adapter.ts").PiRunUsage | undefined;
  await assert.rejects(backend.run({ prompt: "失败用量", onUsage: (value) => { summary = value; } }));
  assert.equal(summary?.outcome, "failed");
  assert.equal(summary?.usage?.totalTokens, 15);
  assert.deepEqual(summary?.toolCalls, [{ name: "shell", kind: "tool" }]);
  const unknownServer = await modelServer(t);
  const unknown = await new PiSdkBackend(await configFor(t, unknownServer.endpoint)).run({ prompt: "未知用量" });
  assert.equal(unknown.usage, undefined);
});

test("JSONL 首次状态已加载 Pi，status 命令刷新 Pi 配置且不发送模型请求", async (t) => {
  const server = await modelServer(t);
  const config = await configFor(t, server.endpoint);
  const proc = await childCore(t, config);
  const initial = await proc.wait((event) => event.kind === "agent.status");
  assert.equal((initial.payload.model as Body).configured, true);
  assert.equal((initial.payload.model as Body).provider, "fixture-provider");
  assert.equal((initial.payload.model as Body).configDirectory, join(config.dataDir, "pi"));
  await writeModelData(join(config.dataDir, "pi", "settings.json"), "{}");
  const marker = proc.events.length;
  proc.send({ op: "status" });
  const refreshed = await proc.wait((event) => event.kind === "agent.status", marker);
  assert.equal((refreshed.payload.model as Body).configured, false);
  assert.equal((refreshed.payload.model as Body).model, "");
  assert.equal(server.requests.length, 0);
  proc.send({ op: "shutdown" });
  assert.equal((await proc.exit)[0], 0, proc.stderr());
});
