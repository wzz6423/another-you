import { strict as assert } from "node:assert";
import { once } from "node:events";
import { createServer } from "node:http";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { createDefaultConfig } from "../src/config.ts";
import { PiSdkBackend } from "../src/pi-adapter.ts";
import { ModelCommandHandler } from "../src/model-commands.ts";
import type { AgentEvent } from "../src/events.ts";
import { usePiFixture } from "./pi-fixture.ts";

async function fixture(t: TestContext, hang = false, acceptedKey?: string) {
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-pi-config-"));
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const requests: { body: Record<string, unknown>; authorization?: string; path?: string }[] = [];
  let received!: () => void;
  const requested = new Promise<void>((done) => { received = done; });
  let disconnected!: () => void;
  const closed = new Promise<void>((done) => { disconnected = done; });
  const server = createServer(async (req, res) => {
    res.once("close", disconnected);
    let raw = "";
    for await (const part of req) raw += part;
    requests.push({ body: JSON.parse(raw), authorization: req.headers.authorization, path: req.url });
    received();
    if (hang) return;
    if (acceptedKey && req.headers.authorization !== `Bearer ${acceptedKey}`) {
      res.writeHead(401, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: "Fixture rejected credentials", type: "authentication_error" } }));
      return;
    }
    res.writeHead(200, { "content-type": "text/event-stream" });
    const chunk = { id: "fixture", choices: [{ index: 0, delta: { role: "assistant", content: "Pi 配置请求完成" }, finish_reason: "stop" }], usage: { prompt_tokens: 10, completion_tokens: 4, total_tokens: 14 } };
    res.end(`data: ${JSON.stringify(chunk)}\n\ndata: [DONE]\n\n`);
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(async () => { server.closeAllConnections(); await new Promise<void>((done) => server.close(() => done())); });
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const directory = await usePiFixture(t, dataDir, `http://127.0.0.1:${address.port}/v1`);
  const backend = new PiSdkBackend(createDefaultConfig(dataDir));
  t.after(() => backend.close());
  return { backend, directory, requests, requested, closed, endpoint: `http://127.0.0.1:${address.port}/v1` };
}

test("Pi 原生默认模型、认证和每模型思考深度用于实际请求且不改配置", async (t) => {
  const f = await fixture(t);
  await writeFile(join(f.directory, "settings.json"), JSON.stringify({ defaultProvider: "fixture-provider", defaultModel: "fixture", defaultThinkingLevel: "low", modelThinkingLevels: { "fixture-provider/fixture": "high" } }));
  const paths = ["settings.json", "models.json", "auth.json"].map((name) => join(f.directory, name));
  const before = await Promise.all(paths.map((path) => readFile(path, "utf8")));
  await f.backend.initialize();
  assert.equal(f.backend.status().configured, true);
  assert.equal(f.backend.status().available, null);
  assert.equal(f.backend.status().configDirectory, f.directory);
  assert.equal(f.backend.status().provider, "fixture-provider");
  assert.equal(JSON.stringify(f.backend.status()).includes("another-you-fixture"), false);
  assert.equal(f.backend.status().reasoningEffort, "high");
  const response = await f.backend.run({ prompt: "验证 Pi 配置" });
  assert.equal(response.reasoningEffort, "high");
  assert.equal(response.usage?.totalTokens, 14);
  assert.equal(f.requests[0].body.model, "fixture");
  assert.equal(f.requests[0].body.reasoning_effort, "high");
  assert.equal(f.requests[0].authorization, "Bearer another-you-fixture");
  assert.deepEqual(await Promise.all(paths.map((path) => readFile(path, "utf8"))), before);
});

test("Pi 配置刷新清除无效或缺失默认模型，不沿用上次成功缓存", async (t) => {
  const f = await fixture(t);
  await f.backend.initialize();
  const settingsPath = join(f.directory, "settings.json");
  const settings = await readFile(settingsPath, "utf8");
  await writeFile(settingsPath, "{ broken");
  await f.backend.reloadModelConfiguration();
  assert.equal(f.backend.status().configured, false);
  assert.equal(f.backend.status().model, "");
  await assert.rejects(f.backend.run({ prompt: "不能沿用旧模型" }), /settings/);
  await writeFile(settingsPath, "{}");
  await f.backend.reloadModelConfiguration();
  assert.match(f.backend.status().message, /设置中选择模型/);
  await writeFile(settingsPath, JSON.stringify({ defaultProvider: "fixture-provider", defaultModel: "missing-model" }));
  await f.backend.reloadModelConfiguration();
  assert.equal(f.backend.status().configured, false);
  assert.equal(f.backend.status().model, "");
  assert.match(f.backend.status().message, /missing-model/);
  await writeFile(settingsPath, settings);
  await writeFile(join(f.directory, "models.json"), "{ broken");
  await f.backend.reloadModelConfiguration();
  assert.equal(f.backend.status().configured, false);
  assert.equal(f.backend.status().model, "");
  assert.equal(f.requests.length, 0);
});

test("Pi auth 与模型思考能力刷新生效，缺少认证不会伪称可用", async (t) => {
  const f = await fixture(t);
  await f.backend.initialize();
  const authPath = join(f.directory, "auth.json");
  await writeFile(authPath, "{}");
  await f.backend.reloadModelConfiguration();
  assert.equal(f.backend.status().configured, false);
  assert.match(f.backend.status().message, /认证/);
  await assert.rejects(f.backend.run({ prompt: "缺少认证" }), /认证/);
  await writeFile(authPath, JSON.stringify({ "fixture-provider": { type: "api_key", key: "fixture-refreshed-key" } }));
  const modelsPath = join(f.directory, "models.json");
  const models = JSON.parse(await readFile(modelsPath, "utf8"));
  models.providers["fixture-provider"].models[0].reasoning = false;
  await writeFile(modelsPath, JSON.stringify(models));
  await writeFile(join(f.directory, "settings.json"), JSON.stringify({ defaultProvider: "fixture-provider", defaultModel: "fixture", defaultThinkingLevel: "high" }));
  await f.backend.reloadModelConfiguration();
  assert.equal(f.backend.status().configured, true);
  assert.equal(f.backend.status().available, null);
  assert.equal(f.backend.status().reasoningEffort, "off");
  await f.backend.run({ prompt: "已刷新" });
  assert.equal(f.requests[0].authorization, "Bearer fixture-refreshed-key");
});

test("运行中的 Pi 请求保持模型快照，刷新立即返回并可取消", async (t) => {
  const f = await fixture(t, true);
  await f.backend.initialize();
  const running = f.backend.run({ prompt: "等待" });
  const rejected = assert.rejects(running, /abort|取消/i);
  await f.requested;
  await writeFile(join(f.directory, "settings.json"), "{}");
  const before = Date.now();
  await f.backend.reloadModelConfiguration();
  assert.ok(Date.now() - before < 500);
  assert.equal(f.backend.status().model, "fixture");
  await assert.rejects(f.backend.run({ prompt: "不能并发" }), /另一条请求/);
  f.backend.abort();
  await rejected;
  await f.backend.reloadModelConfiguration();
  assert.equal(f.backend.status().configured, false);
  assert.equal(f.backend.status().model, "");
});

test("账户配置到模型选择和连接测试经过实际HTTP，失败后重新配置恢复且不提供工具或写聊天", async t => {
  const f = await fixture(t, false, "working-fixture-key");
  await writeFile(join(f.directory, "auth.json"), "{}");
  await writeFile(join(f.directory, "settings.json"), "{}");
  await f.backend.initialize();
  const events: AgentEvent[] = [];
  const statuses: ReturnType<PiSdkBackend["status"]>[] = [];
  const commands = new ModelCommandHandler(f.backend, event => events.push(event), () => statuses.push(f.backend.status()));
  t.after(() => commands.close());
  async function waitFor(match: (event: AgentEvent) => boolean): Promise<AgentEvent> {
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      const found = events.find(match);
      if (found) return found;
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    assert.fail("等待模型配置回执超时");
  }
  const finished = (id: string, state: string) => waitFor(event => event.kind === "model.operation" && event.payload.requestId === id && event.payload.state === state);
  async function login(id: string, key: string) {
    commands.handle({ op: "modelLogin", requestId: id, provider: "fixture-provider", authType: "api_key" });
    const prompt = await waitFor(event => event.kind === "model.auth" && event.payload.requestId === id && event.payload.stage === "prompt");
    commands.handle({ op: "modelAuthReply", requestId: id, promptId: (prompt.payload.prompt as { id: string }).id, value: key });
    return finished(id, "succeeded");
  }

  commands.handle({ op: "modelTest", requestId: "missing" });
  await finished("missing", "failed");
  assert.equal(f.requests.length, 0);
  const saved = await login("bad-account", "invalid-fixture-key");
  assert.equal(saved.payload.message, "账户已保存，请选择模型");
  assert.equal(f.backend.status().configured, false);
  commands.handle({ op: "modelSelect", requestId: "select", provider: "fixture-provider", model: "fixture", thinkingLevel: "off" });
  await finished("select", "succeeded");
  assert.equal(f.backend.status().configured, true);
  assert.equal(f.backend.status().available, null);
  assert.equal(f.requests.length, 0);

  commands.handle({ op: "modelTest", requestId: "reject" });
  await finished("reject", "failed");
  assert.equal(statuses.at(-1)?.available, false);
  await login("good-account", "working-fixture-key");
  assert.equal(f.backend.status().available, null);
  commands.handle({ op: "modelTest", requestId: "connect" });
  await finished("connect", "succeeded");
  assert.equal(statuses.at(-1)?.available, true);
  assert.equal(f.requests.length, 2);
  for (const request of f.requests) {
    assert.equal(request.body.model, "fixture");
    assert.ok(request.body.tools === undefined || (Array.isArray(request.body.tools) && request.body.tools.length === 0));
    const messages = request.body.messages as { role: string; content: unknown }[];
    assert.equal(messages.filter(message => message.role === "user").length, 1);
    assert.ok(JSON.stringify(messages).includes('Return only'));
  }
  await assert.rejects(readFile(join(f.directory, "..", "state.json")));
  assert.ok(events.every(event => event.kind.startsWith("model.")));
});

test("完整 API 表单从空配置保存并经实际 HTTP 验证，错误密钥修复后恢复连接", async t => {
  const f = await fixture(t, false, "working-gateway-key");
  for (const name of ["models.json", "settings.json", "auth.json"]) {
    await writeFile(join(f.directory, name), name === "models.json" ? '{"providers":{}}' : "{}");
  }
  await f.backend.initialize();
  const events: AgentEvent[] = [];
  const commands = new ModelCommandHandler(f.backend, event => events.push(event));
  t.after(() => commands.close());
  async function finished(id: string, state: string) {
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      if (events.some(event => event.kind === "model.operation" && event.payload.requestId === id && event.payload.state === state)) return;
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    assert.fail(`等待 ${id} ${state} 回执超时`);
  }
  const input = { op: "modelConfigure", provider: "custom-gateway", model: "gateway-model", baseUrl: f.endpoint, api: "openai-completions", thinkingLevel: "off" };
  commands.handle({ ...input, requestId: "bad-key", apiKey: "wrong-gateway-key" });
  await finished("bad-key", "succeeded");
  assert.equal(f.backend.status().available, null);
  assert.equal(f.requests.length, 0);
  commands.handle({ op: "modelTest", requestId: "rejected" });
  await finished("rejected", "failed");
  assert.equal(f.backend.status().available, false);
  commands.handle({ ...input, requestId: "fix-key", apiKey: "working-gateway-key" });
  await finished("fix-key", "succeeded");
  await f.backend.reloadModelConfiguration();
  commands.handle({ op: "modelTest", requestId: "connected" });
  await finished("connected", "succeeded");
  assert.equal(f.backend.status().available, true);
  assert.equal(f.requests.length, 2);
  assert.equal(f.requests[1].path, "/v1/chat/completions");
  assert.equal(f.requests[1].body.model, "gateway-model");
  assert.equal(f.requests[1].authorization, "Bearer working-gateway-key");
  assert.ok(!f.requests[1].body.tools || (f.requests[1].body.tools as unknown[]).length === 0);
  assert.equal(JSON.stringify(events).includes("working-gateway-key"), false);
  assert.equal(JSON.stringify(events).includes("wrong-gateway-key"), false);
  await assert.rejects(readFile(join(f.directory, "..", "state.json")));
});

test("连接测试取消终止实际 HTTP 请求并解除配置互斥", { timeout: 5000 }, async t => {
  const f = await fixture(t, true);
  await f.backend.initialize();
  const events: AgentEvent[] = [];
  let finish!: () => void;
  const finished = new Promise<void>(resolve => { finish = resolve; });
  const commands = new ModelCommandHandler(f.backend, event => events.push(event), finish);
  t.after(() => commands.close());
  commands.handle({ op: "modelTest", requestId: "test" });
  await f.requested;
  commands.handle({ op: "modelSelect", requestId: "busy", provider: "fixture-provider", model: "fixture" });
  assert.ok(events.some(event => event.payload.requestId === "busy" && event.payload.state === "failed"));
  commands.handle({ op: "modelAuthCancel", requestId: "stale" });
  assert.equal(f.backend.isBusy, true);
  commands.handle({ op: "modelAuthCancel", requestId: "test" });
  await finished;
  await f.closed;
  assert.equal(f.backend.isBusy, false);
  assert.ok(events.some(event => event.payload.requestId === "test" && event.payload.state === "cancelled"));
  assert.ok(!events.some(event => event.payload.requestId === "test" && event.payload.state === "succeeded"));
  assert.equal(f.requests.length, 1);
  await f.backend.changeModelConfiguration(() => f.backend.modelConfiguration.select("fixture-provider", "fixture", "off"));
  assert.equal(f.backend.status().available, null);
});
