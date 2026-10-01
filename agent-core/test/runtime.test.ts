import { strict as assert } from "node:assert";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import test, { type TestContext } from "node:test";
import { AgentCore, type AgentEvent, type AgentConfig, type Proposal, type TriggerRule, createDefaultConfig, parseAgentConfig, saveConfig, PiSdkBackend, modelEndpoint, assertNetworkAllowed } from "../src/index.ts";

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
  config.model.model = "fixture";
  if (endpoint) config.model.endpoint = endpoint;
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

test("官方 Pi SDK 调用本地 HTTP 模型并明确禁用工具", async (t) => {
  const server = await modelServer(t);
  const config = await configFor(t, server.endpoint);
  const backend = new PiSdkBackend(config);
  assert.equal(backend.status().available, null);
  const response = await backend.run({ prompt: "帮我整理一个空白计划" });
  assert.equal(response.text, "这是可审阅的本地草稿。");
  assert.equal(server.requests.length, 1);
  assert.equal(server.requests[0].url, "/v1/chat/completions");
  assert.equal(server.requests[0].body.model, "fixture");
  assert.equal(server.requests[0].headers.authorization, "Bearer another-you-local");
  assert.equal(server.requests[0].body.tools, undefined);
  assert.equal(backend.status().available, true);
});

test("新安装的占位模型和空模型明确未配置且不发送 HTTP 请求", async (t) => {
  const server = await modelServer(t);
  const fixtureConfig = await configFor(t, server.endpoint);
  const config = createDefaultConfig(fixtureConfig.dataDir);
  config.model.endpoint = server.endpoint;
  const backend = new PiSdkBackend(config);
  assert.equal(backend.status().configured, false);
  assert.equal(backend.status().available, false);
  assert.match(backend.status().message, /尚未选择模型/);
  await assert.rejects(backend.run({ prompt: "你好" }), /尚未选择模型/);
  config.model.model = " ";
  assert.equal(backend.status().configured, false);
  await assert.rejects(backend.run({ prompt: "你好" }), /尚未选择模型/);
  assert.equal(server.requests.length, 0);
});

test("strict-local 和精确主机允许列表在发送请求前阻止外网", async (t) => {
  const config = await configFor(t);
  config.model.provider = "openai-compatible";
  config.model.endpoint = "https://models.example/v1";
  await assert.rejects(new PiSdkBackend(config).run({ prompt: "private" }), /隐私策略/);
  config.privacy.mode = "custom";
  config.privacy.allowNetwork = true;
  assert.throws(() => modelEndpoint(config), /allowedNetworkHosts/);
  config.privacy.allowedNetworkHosts = ["models.example"];
  assert.equal(modelEndpoint(config).host, "models.example");
  assert.throws(() => assertNetworkAllowed(config, new URL("https://models.example.evil/v1")), /allowedNetworkHosts/);
  assert.throws(() => assertNetworkAllowed(config, new URL("http://models.example/v1")), /HTTPS/);
  config.model.provider = "local";
  assert.throws(() => modelEndpoint(config), /本机回环/);
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

test("模型挂起时仍能暂停、查询、拒绝并发并及时关闭", async (t) => {
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

test("strict-local 配置覆盖外部网络授权，拒绝持久化明文 API 密钥", () => {
  const config = parseAgentConfig({ privacy: { mode: "strict-local", allowNetwork: true }, model: { endpoint: "https://external.example/v1" } });
  assert.equal(config.privacy.allowNetwork, false);
  assert.throws(() => modelEndpoint(config), /回环/);
  assert.throws(() => parseAgentConfig({ model: { apiKey: "never-store-this" } }), /API 密钥/);
});
