import { strict as assert } from "node:assert";
import { access, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import type { MutableModels, ProviderAuthInteraction } from "@earendil-works/pi-ai";
import { createDefaultConfig } from "../src/config.ts";
import type { AgentEvent } from "../src/events.ts";
import { ModelCommandHandler } from "../src/model-commands.ts";
import { hasExternalConfigurationValue, ModelConfiguration } from "../src/model-configuration.ts";
import { PiSdkBackend } from "../src/pi-adapter.ts";
import { writePiFixture } from "./pi-fixture.ts";

async function setup(t: TestContext, configure?: (models: MutableModels) => void) {
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-model-account-"));
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const directory = await writePiFixture(dataDir, "http://127.0.0.1:1/v1");
  const configuration = new ModelConfiguration(dataDir, configure);
  const backend = new PiSdkBackend(createDefaultConfig(dataDir), undefined, configuration);
  const events: AgentEvent[] = [];
  const handler = new ModelCommandHandler(backend, event => events.push(event));
  t.after(async () => { await handler.close(); await backend.close(); });
  await backend.initialize();
  return { dataDir, directory, configuration, backend, handler, events };
}

async function eventMatching(events: AgentEvent[], match: (event: AgentEvent) => boolean): Promise<AgentEvent> {
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    const result = events.find(match);
    if (result) return result;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  assert.fail("等待模型协议事件超时");
}

async function completed(events: AgentEvent[], requestId: string, state = "succeeded") {
  return eventMatching(events, event => event.kind === "model.operation" && event.payload.requestId === requestId && event.payload.state === state);
}

test("目录列出未认证的内置模型，选择和思考深度持久化且不伪称网络成功", async t => {
  const f = await setup(t);
  assert.ok(f.configuration.snapshot.models.length > 100);
  assert.ok(f.configuration.snapshot.models.some(model => model.provider === "openai" && !model.configured));
  assert.ok(f.configuration.snapshot.models.find(model => model.provider === "fixture-provider")?.configured);
  f.handler.handle({ op: "modelSelect", requestId: "select", provider: "fixture-provider", model: "fixture", thinkingLevel: "high" });
  await completed(f.events, "select");
  const settings = JSON.parse(await readFile(join(f.directory, "settings.json"), "utf8"));
  assert.equal(settings.modelThinkingLevels["fixture-provider/fixture"], "high");
  assert.equal(f.backend.status().available, null);
  await f.configuration.load();
  assert.equal(f.configuration.snapshot.selected?.thinkingLevel, "high");
  await assert.rejects(f.configuration.select("fixture-provider", "missing"), /目录/);
  await assert.rejects(f.configuration.select("fixture-provider", "fixture", "max"), /思考深度/);
  for (const name of ["auth.json", "settings.json", "models.json"]) assert.equal((await stat(join(f.directory, name))).mode & 0o777, 0o600);
});

test("离线读取拒绝环境与命令凭据，不执行认证命令，也不继承 Pi 全局目录", async t => {
  assert.equal(hasExternalConfigurationValue("$$literal"), false);
  assert.equal(hasExternalConfigurationValue("$$$ENV_KEY"), true);
  const f = await setup(t);
  const marker = join(f.dataDir, "credential-command-ran");
  await writeFile(join(f.directory, "auth.json"), JSON.stringify({ openai: { type: "api_key", key: `!touch '${marker}'; printf fixture` } }));
  const originalDirectory = process.env.PI_CODING_AGENT_DIR;
  const originalKey = process.env.OPENAI_API_KEY;
  process.env.PI_CODING_AGENT_DIR = join(f.dataDir, "unrelated-pi");
  process.env.OPENAI_API_KEY = "ambient-key-must-not-be-used";
  try {
    await f.configuration.load();
    assert.equal(f.configuration.directory, f.directory);
    const provider = f.configuration.snapshot.providers.find(item => item.id === "openai");
    assert.equal(provider?.configured, false);
    assert.match(provider?.configurationIssue ?? "", /环境变量或命令/);
    await assert.rejects(access(marker));
    await writeFile(join(f.directory, "auth.json"), "{}");
    await f.configuration.load();
    assert.equal(f.configuration.snapshot.providers.find(item => item.id === "openai")?.configured, false);
    await assert.rejects(access(join(f.dataDir, "unrelated-pi")));
  } finally {
    if (originalDirectory === undefined) delete process.env.PI_CODING_AGENT_DIR; else process.env.PI_CODING_AGENT_DIR = originalDirectory;
    if (originalKey === undefined) delete process.env.OPENAI_API_KEY; else process.env.OPENAI_API_KEY = originalKey;
  }
});

test("API key 交互拒绝错误 prompt，保存后注销，认证内容不进入协议目录和历史事件", async t => {
  const f = await setup(t);
  f.handler.handle({ op: "modelLogin", requestId: "key", provider: "fixture-provider", authType: "api_key" });
  const prompt = await eventMatching(f.events, event => event.kind === "model.auth" && event.payload.stage === "prompt");
  const promptId = (prompt.payload.prompt as { id: string }).id;
  f.handler.handle({ op: "modelAuthReply", requestId: "key", promptId: "old-prompt", value: "should-not-save" });
  assert.equal(f.backend.isBusy, true);
  f.handler.handle({ op: "modelAuthReply", requestId: "key", promptId, value: "$ENV_KEY" });
  assert.equal(f.backend.isBusy, true);
  f.handler.handle({ op: "modelAuthReply", requestId: "key", promptId, value: "only-in-auth-file-key" });
  await completed(f.events, "key");
  assert.equal(JSON.parse(await readFile(join(f.directory, "auth.json"), "utf8"))["fixture-provider"].key, "only-in-auth-file-key");
  assert.equal(JSON.stringify(f.events).includes("only-in-auth-file-key"), false);
  assert.ok(f.events.every(event => event.kind.startsWith("model.")));
  f.handler.handle({ op: "modelLogout", requestId: "logout", provider: "fixture-provider" });
  await completed(f.events, "logout");
  assert.equal(f.configuration.snapshot.providers.find(provider => provider.id === "fixture-provider")?.configured, false);
  assert.equal(JSON.parse(await readFile(join(f.directory, "auth.json"), "utf8"))["fixture-provider"], undefined);
});

test("OAuth 取消结束等待、保留旧账户并解除配置互斥", async t => {
  let loginSignal: AbortSignal | undefined;
  const f = await setup(t, models => {
    const provider = models.getProvider("fixture-provider")!;
    models.setProvider({ ...provider, auth: { ...provider.auth, oauth: {
      name: "Fixture OAuth", login: async (interaction: ProviderAuthInteraction) => {
        loginSignal = interaction.signal;
        interaction.notify({ type: "auth_url", url: "https://example.invalid/login", instructions: "Fixture only" });
        const access = await interaction.prompt({ type: "manual_code", message: "Fixture authorization code" });
        return { type: "oauth", access, refresh: "fixture-refresh", expires: Date.now() + 60_000 };
      }, refresh: async credential => credential, toAuth: async credential => ({ apiKey: credential.access }),
    } } });
  });
  const before = await readFile(join(f.directory, "auth.json"), "utf8");
  f.handler.handle({ op: "modelLogin", requestId: "oauth", provider: "fixture-provider", authType: "oauth" });
  await eventMatching(f.events, event => event.kind === "model.auth" && event.payload.stage === "prompt");
  f.handler.handle({ op: "modelSelect", requestId: "busy", provider: "fixture-provider", model: "fixture" });
  await completed(f.events, "busy", "failed");
  f.handler.handle({ op: "modelAuthCancel", requestId: "oauth" });
  await completed(f.events, "oauth", "cancelled");
  assert.equal(loginSignal?.aborted, true);
  assert.equal(f.backend.isBusy, false);
  assert.equal(await readFile(join(f.directory, "auth.json"), "utf8"), before);
  f.handler.handle({ op: "modelSelect", requestId: "after-cancel", provider: "fixture-provider", model: "fixture" });
  await completed(f.events, "after-cancel");
});

test("目录刷新使用 SDK 发布结果；部分失败仍向客户端发布最新目录", async t => {
  let refreshes = 0;
  const f = await setup(t, models => {
    const provider = models.getProvider("fixture-provider")!;
    let discovered = false;
    models.setProvider({ ...provider, getModels: () => [...provider.getModels(), ...(discovered ? [{ ...provider.getModels()[0], id: "discovered" }] : [])],
      refreshModels: async context => {
        if (!context.allowNetwork) return;
        refreshes++;
        await context.publish({ update: () => { discovered = true; } });
        throw new Error("fixture catalog unavailable");
      } });
  });
  assert.equal(refreshes, 0);
  f.handler.handle({ op: "modelCatalog", requestId: "refresh", refresh: true });
  await completed(f.events, "refresh", "failed");
  const catalog = await eventMatching(f.events, event => event.kind === "model.catalog" && event.payload.requestId === "refresh");
  assert.equal(refreshes, 1);
  assert.ok((catalog.payload.models as { id: string }[]).some(model => model.id === "discovered"));
});

test("OAuth 成功凭据持久化，离线重读不刷新令牌，实际认证解析由 Pi 刷新并回写", async t => {
  let currentModels: MutableModels | undefined;
  let refreshes = 0;
  const f = await setup(t, models => {
    currentModels = models;
    const provider = models.getProvider("fixture-provider")!;
    models.setProvider({ ...provider, auth: { ...provider.auth, oauth: {
      name: "Fixture OAuth",
      login: async interaction => ({ type: "oauth", access: await interaction.prompt({ type: "manual_code", message: "Fixture code" }), refresh: "fixture-refresh", expires: 0 }),
      refresh: async credential => { refreshes++; return { ...credential, access: "fixture-refreshed-access", expires: Date.now() + 60_000 }; },
      toAuth: async credential => ({ apiKey: credential.access }),
    } } });
  });
  f.handler.handle({ op: "modelLogin", requestId: "oauth-success", provider: "fixture-provider", authType: "oauth" });
  const prompt = await eventMatching(f.events, event => event.kind === "model.auth" && event.payload.stage === "prompt");
  f.handler.handle({ op: "modelAuthReply", requestId: "oauth-success", promptId: (prompt.payload.prompt as { id: string }).id, value: "fixture-access-code" });
  await completed(f.events, "oauth-success");
  await f.configuration.load();
  assert.equal(refreshes, 0);
  assert.equal(f.configuration.snapshot.providers.find(item => item.id === "fixture-provider")?.credentialType, "oauth");
  const auth = await currentModels!.getAuth("fixture-provider");
  assert.equal(auth?.auth.apiKey, "fixture-refreshed-access");
  assert.equal(refreshes, 1);
  assert.equal(JSON.parse(await readFile(join(f.directory, "auth.json"), "utf8"))["fixture-provider"].access, "fixture-refreshed-access");
  assert.equal(JSON.stringify(f.events).includes("fixture-access-code"), false);
});

test("导入只复制模型定义与默认选择，保留独立账户，拒绝无效文件", async t => {
  const f = await setup(t);
  const source = await mkdtemp(join(tmpdir(), "another-you-model-import-"));
  t.after(() => rm(source, { recursive: true, force: true }));
  await writePiFixture(source, "http://127.0.0.1:1/v1", "high");
  const sourceDirectory = join(source, "pi");
  const models = JSON.parse(await readFile(join(sourceDirectory, "models.json"), "utf8"));
  models.providers["fixture-provider"].apiKey = "imported-secret";
  models.providers["fixture-provider"].headers = { Authorization: "Bearer imported-secret" };
  models.providers["fixture-provider"].models[0].headers = { "x-api-key": "imported-secret" };
  await writeFile(join(sourceDirectory, "models.json"), JSON.stringify(models));
  const authBefore = await readFile(join(f.directory, "auth.json"), "utf8");
  await f.configuration.importConfiguration(sourceDirectory);
  assert.equal((await readFile(join(f.directory, "models.json"), "utf8")).includes("imported-secret"), false);
  assert.equal(await readFile(join(f.directory, "auth.json"), "utf8"), authBefore);
  assert.equal(f.configuration.snapshot.selected?.thinkingLevel, "high");
  const before = await readFile(join(f.directory, "models.json"), "utf8");
  await writeFile(join(sourceDirectory, "models.json"), '{"providers":[]}');
  await assert.rejects(f.configuration.importConfiguration(sourceDirectory), /providers/);
  assert.equal(await readFile(join(f.directory, "models.json"), "utf8"), before);
});
