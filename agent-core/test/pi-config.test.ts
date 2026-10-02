import { strict as assert } from "node:assert";
import { once } from "node:events";
import { createServer } from "node:http";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { createDefaultConfig } from "../src/config.ts";
import { PiSdkBackend } from "../src/pi-adapter.ts";
import { usePiFixture } from "./pi-fixture.ts";

async function fixture(t: TestContext, hang = false) {
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-pi-config-"));
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const requests: { body: Record<string, unknown>; authorization?: string }[] = [];
  let received!: () => void;
  const requested = new Promise<void>((done) => { received = done; });
  const server = createServer(async (req, res) => {
    let raw = "";
    for await (const part of req) raw += part;
    requests.push({ body: JSON.parse(raw), authorization: req.headers.authorization });
    received();
    if (hang) return;
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
  return { backend, directory, requests, requested };
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
