import { strict as assert } from "node:assert";
import { once } from "node:events";
import { access, mkdir, mkdtemp, rm, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after, type TestContext } from "node:test";
import type { AuthPrompt, MutableModels, ProviderAuthInteraction } from "@earendil-works/pi-ai";
import { createDefaultConfig } from "../src/config.ts";
import type { AgentEvent } from "../src/events.ts";
import { ModelCommandHandler } from "../src/model-commands.ts";
import { hasExternalConfigurationValue, ModelConfiguration } from "../src/model-configuration.ts";
import { readModelData, writeModelData } from "./model-storage-fixture.ts";
import { PiSdkBackend } from "../src/pi-adapter.ts";
import { writePiFixture } from "./pi-fixture.ts";

const isolatedPiRoot = await mkdtemp(join(tmpdir(), "another-you-pi-discovery-"));
const originalPiDirectory = process.env.PI_CODING_AGENT_DIR;
process.env.PI_CODING_AGENT_DIR = join(isolatedPiRoot, "absent");
after(async () => {
  if (originalPiDirectory === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = originalPiDirectory;
  await rm(isolatedPiRoot, { recursive: true, force: true });
});

async function discoveryFixture(t: TestContext) {
  const root = await mkdtemp(join(isolatedPiRoot, "case-"));
  const source = join(root, "source", "pi");
  const previous = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = source;
  t.after(() => { process.env.PI_CODING_AGENT_DIR = previous; });
  const dataDir = join(root, "app");
  return { root, source, dataDir, configuration: new ModelConfiguration(dataDir) };
}

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
  const settings = JSON.parse(await readModelData(join(f.directory, "settings.json"), "utf8"));
  assert.equal(settings.modelThinkingLevels["fixture-provider/fixture"], "high");
  assert.equal(f.backend.status().available, null);
  await f.configuration.load();
  assert.equal(f.configuration.snapshot.selected?.thinkingLevel, "high");
  await assert.rejects(f.configuration.select("fixture-provider", "missing"), /目录/);
  await assert.rejects(f.configuration.select("fixture-provider", "fixture", "max"), /思考深度/);
  assert.equal((await stat(join(f.directory, "models.sqlite"))).mode & 0o777, 0o600);
});

test("API 配置目录提供地址和协议，完整表单保存后重载并保留其他模型及账户", async t => {
  const f = await setup(t);
  assert.equal(f.configuration.snapshot.providers.find(provider => provider.id === "openai")?.apiConfiguration?.api, "openai-responses");
  assert.equal(f.configuration.snapshot.providers.find(provider => provider.id === "amazon-bedrock")?.apiConfiguration, undefined);
  const previousModels = JSON.parse(await readModelData(join(f.directory, "models.json"), "utf8"));
  const previousAuth = JSON.parse(await readModelData(join(f.directory, "auth.json"), "utf8"));
  f.handler.handle({ op: "modelConfigure", requestId: "configure", provider: " custom-gateway ", baseUrl: " https://api.example.invalid/v1 ",
    api: "openai-completions", model: " custom-model ", apiKey: " only-in-auth-file-key ", thinkingLevel: "off" });
  await completed(f.events, "configure");
  assert.equal(f.backend.status().configured, true);
  assert.equal(f.backend.status().available, null);
  assert.equal(f.backend.status().model, "custom-model");
  const auth = JSON.parse(await readModelData(join(f.directory, "auth.json"), "utf8"));
  const models = JSON.parse(await readModelData(join(f.directory, "models.json"), "utf8"));
  assert.deepEqual(auth["custom-gateway"], { type: "api_key", key: "only-in-auth-file-key" });
  assert.deepEqual(auth["fixture-provider"], previousAuth["fixture-provider"]);
  assert.deepEqual(models.providers["fixture-provider"], previousModels.providers["fixture-provider"]);
  assert.equal(JSON.stringify(models).includes("only-in-auth-file-key"), false);
  assert.equal(JSON.stringify(f.events).includes("only-in-auth-file-key"), false);
  await f.backend.reloadModelConfiguration();
  assert.equal(f.configuration.snapshot.selected?.provider, "custom-gateway");
  assert.equal(f.configuration.snapshot.providers.find(provider => provider.id === "custom-gateway")?.apiConfiguration?.baseUrl, "https://api.example.invalid/v1");
  assert.equal((await stat(join(f.directory, "models.sqlite"))).mode & 0o777, 0o600);
});

test("API 配置保留已有密钥和模型能力，覆盖模型自身的地址和协议", async t => {
  const f = await setup(t);
  const path = join(f.directory, "models.json");
  const models = JSON.parse(await readModelData(path, "utf8"));
  models.providers["fixture-provider"].models[0].baseUrl = "https://old.example.invalid/v1";
  models.providers["fixture-provider"].models[0].api = "openai-completions";
  models.providers["fixture-provider"].models.push({ id: "other-model", reasoning: false });
  await writeModelData(path, JSON.stringify(models));
  await f.backend.reloadModelConfiguration();
  await f.configuration.configureAPI({ provider: "fixture-provider", baseUrl: "https://new.example.invalid/v1", api: "openai-responses", model: "fixture", apiKey: "", thinkingLevel: "high" });
  assert.equal(f.configuration.selection?.model.baseUrl, "https://new.example.invalid/v1");
  assert.equal(f.configuration.selection?.model.api, "openai-responses");
  assert.equal(f.configuration.selection?.model.reasoning, true);
  assert.deepEqual(f.configuration.selection?.model.input, ["text", "image"]);
  assert.equal(f.configuration.selection?.model.contextWindow, 32768);
  const saved = JSON.parse(await readModelData(path, "utf8"));
  assert.deepEqual(saved.providers["fixture-provider"].models.find((model: { id: string }) => model.id === "other-model"), models.providers["fixture-provider"].models[1]);
  assert.equal(JSON.parse(await readModelData(join(f.directory, "auth.json"), "utf8"))["fixture-provider"].key, "another-you-fixture");
});

test("API 配置拒绝无效字段、外部密钥和 OAuth 留空，坏输入及取消不改变已存配置", async t => {
  const f = await setup(t);
  const paths = ["models.json", "settings.json", "auth.json"].map(name => join(f.directory, name));
  const before = await Promise.all(paths.map(path => readModelData(path, "utf8")));
  const input = { provider: "custom", baseUrl: "https://api.example.invalid/v1", api: "openai-completions", model: "fixture", apiKey: "fixture-key" };
  for (const invalid of [
    { baseUrl: "file:///tmp/fixture" }, { baseUrl: "ftp://example.invalid/v1" }, { baseUrl: "https://user:password@example.invalid/v1" },
    { baseUrl: "https://example.invalid/v1?key=secret" }, { baseUrl: "https://example.invalid/v1#key" }, { baseUrl: "https://example.invalid/a b" },
    { api: "unknown-protocol" }, { apiKey: "$ENV_KEY" }, { apiKey: "!touch /tmp/must-not-run" }, { apiKey: " " },
    { provider: "__proto__" }, { model: " " }, { thinkingLevel: "high" },
  ]) await assert.rejects(f.configuration.configureAPI({ ...input, ...invalid }));
  const abort = new AbortController();
  abort.abort();
  await assert.rejects(f.configuration.configureAPI(input, abort.signal), { name: "AbortError" });
  assert.deepEqual(await Promise.all(paths.map(path => readModelData(path, "utf8"))), before);
  await writeModelData(join(f.directory, "auth.json"), JSON.stringify({ openai: { type: "oauth", access: "oauth-access", refresh: "oauth-refresh", expires: Date.now() + 60_000 } }));
  await f.backend.reloadModelConfiguration();
  await assert.rejects(f.configuration.configureAPI({ ...input, provider: "openai", apiKey: "" }), /API Key/);
});

test("API 保存后选择失败恢复原配置和凭据，失败回执不泄露新密钥", async t => {
  const f = await setup(t);
  const paths = ["models.json", "settings.json", "auth.json"].map(name => join(f.directory, name));
  const before = await Promise.all(paths.map(async path => JSON.parse(await readModelData(path, "utf8"))));
  f.configuration.select = async () => { throw new Error("保存 failed-private-key 失败"); };
  f.handler.handle({ op: "modelConfigure", requestId: "rollback", provider: "fixture-provider", baseUrl: "https://api.example.invalid/v1",
    api: "openai-completions", model: "fixture", apiKey: "failed-private-key", thinkingLevel: "off" });
  const result = await completed(f.events, "rollback", "failed");
  assert.match(String(result.payload.message), /已隐藏/);
  assert.equal(JSON.stringify(f.events).includes("failed-private-key"), false);
  assert.deepEqual(await Promise.all(paths.map(async path => JSON.parse(await readModelData(path, "utf8")))), before);
  assert.equal(f.backend.status().endpoint, "http://127.0.0.1:1/v1");
});

test("离线读取拒绝环境与命令凭据，不执行认证命令，也不创建不存在的 Pi 全局目录", async t => {
  assert.equal(hasExternalConfigurationValue("$$literal"), false);
  assert.equal(hasExternalConfigurationValue("$$$ENV_KEY"), true);
  const f = await setup(t);
  const marker = join(f.dataDir, "credential-command-ran");
  await writeModelData(join(f.directory, "auth.json"), JSON.stringify({ openai: { type: "api_key", key: `!touch '${marker}'; printf fixture` } }));
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
    await writeModelData(join(f.directory, "auth.json"), "{}");
    await f.configuration.load();
    assert.equal(f.configuration.snapshot.providers.find(item => item.id === "openai")?.configured, false);
    await assert.rejects(access(join(f.dataDir, "unrelated-pi")));
  } finally {
    if (originalDirectory === undefined) delete process.env.PI_CODING_AGENT_DIR; else process.env.PI_CODING_AGENT_DIR = originalDirectory;
    if (originalKey === undefined) delete process.env.OPENAI_API_KEY; else process.env.OPENAI_API_KEY = originalKey;
  }
});

test("无本机 Pi 时保持空配置，之后安装 Pi 可自动发现", async t => {
  const f = await discoveryFixture(t);
  await f.configuration.load();
  assert.equal(f.configuration.snapshot.selected, undefined);
  assert.equal(f.configuration.snapshot.message, undefined);
  await assert.rejects(access(f.source));
  await assert.rejects(readModelData(join(f.configuration.directory, "pi-discovery.json")));
  await writePiFixture(join(f.root, "source"), "http://127.0.0.1:1/v1", "high");
  await f.configuration.load();
  assert.equal(f.configuration.selection?.configured, true);
  assert.equal(f.configuration.selection?.thinkingLevel, "high");
});

test("自动读取 Pi 模型、默认选择、每模型思考与账户，兼容官方 JSONC/BOM 且不改源文件", async t => {
  const f = await discoveryFixture(t);
  await writePiFixture(join(f.root, "source"), "http://127.0.0.1:1/v1", "low");
  await writeModelData(join(f.source, "settings.json"), '\uFEFF' + JSON.stringify({ defaultProvider: "fixture-provider", defaultModel: "fixture",
    defaultThinkingLevel: "low", modelThinkingLevels: { "fixture-provider/fixture": "high" }, extensions: ["should-not-import"] }));
  const models = await readModelData(join(f.source, "models.json"), "utf8");
  await writeModelData(join(f.source, "models.json"), '\uFEFF// Pi supports JSON comments\n' + models);
  await writeModelData(join(f.source, "auth.json"), '\uFEFF' + JSON.stringify({ "fixture-provider": { type: "api_key", key: "fixture-pi-key" },
    "openai-codex": { type: "oauth", access: "fixture-access", refresh: "fixture-refresh", expires: Date.now() + 60_000 } }));
  const names = ["settings.json", "models.json", "auth.json"];
  const before = await Promise.all(names.map(name => readModelData(join(f.source, name), "utf8")));
  await f.configuration.load();
  assert.equal(f.configuration.snapshot.message, undefined);
  assert.deepEqual(f.configuration.snapshot.selected, { provider: "fixture-provider", model: "fixture", thinkingLevel: "high" });
  assert.equal(f.configuration.selection?.configured, true);
  assert.equal(f.configuration.snapshot.providers.find(provider => provider.id === "openai-codex")?.credentialType, "oauth");
  assert.equal(JSON.stringify(f.configuration.snapshot).includes("fixture-pi-key"), false);
  assert.equal(JSON.parse(await readModelData(join(f.configuration.directory, "settings.json"), "utf8")).extensions, undefined);
  assert.deepEqual(await Promise.all(names.map(name => readModelData(join(f.source, name), "utf8"))), before);
  assert.equal((await stat(join(f.configuration.directory, "models.sqlite"))).mode & 0o777, 0o600);
});

test("自动发现的 Pi 配置直接用于真实本地 HTTP 请求，无需手动选择或登录", async t => {
  const f = await discoveryFixture(t);
  const requests: { model?: string; reasoning_effort?: string; authorization?: string }[] = [];
  const server = createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    requests.push({ ...JSON.parse(body), authorization: request.headers.authorization });
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(`data: ${JSON.stringify({ id: "fixture", choices: [{ index: 0,
      delta: { role: "assistant", content: "自动配置请求成功" }, finish_reason: "stop" }] })}\n\ndata: [DONE]\n\n`);
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(async () => { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); });
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  await writePiFixture(join(f.root, "source"), `http://127.0.0.1:${address.port}/v1`, "high");
  const backend = new PiSdkBackend(createDefaultConfig(f.dataDir), undefined, f.configuration);
  t.after(() => backend.close());
  await backend.initialize();
  assert.equal(backend.status().available, null);
  assert.equal(requests.length, 0);
  const response = await backend.run({ prompt: "验证自动发现" });
  assert.equal(response.text, "自动配置请求成功");
  assert.equal(requests[0].model, "fixture");
  assert.equal(requests[0].reasoning_effort, "high");
  assert.equal(requests[0].authorization, "Bearer another-you-fixture");
});

test("已有应用 provider、账户和选择优先，补全缺失账户不覆盖明确思考深度", async t => {
  const f = await discoveryFixture(t);
  await writePiFixture(join(f.root, "source"), "http://127.0.0.1:2/v1", "high");
  await writeModelData(join(f.source, "auth.json"), JSON.stringify({ "fixture-provider": { type: "api_key", key: "source-key" },
    openai: { type: "api_key", key: "source-openai-key" } }));
  await writePiFixture(f.dataDir, "http://127.0.0.1:1/v1", "off");
  await writeModelData(join(f.configuration.directory, "settings.json"), JSON.stringify({ defaultProvider: "openai", defaultModel: "gpt-4.4.1",
    defaultThinkingLevel: "low", modelThinkingLevels: { "fixture-provider/fixture": "off" } }));
  await f.configuration.load();
  const settings = JSON.parse(await readModelData(join(f.configuration.directory, "settings.json"), "utf8"));
  const auth = JSON.parse(await readModelData(join(f.configuration.directory, "auth.json"), "utf8"));
  const models = JSON.parse(await readModelData(join(f.configuration.directory, "models.json"), "utf8"));
  assert.equal(settings.defaultProvider, "openai");
  assert.equal(settings.defaultModel, "gpt-4.4.1");
  assert.equal(settings.defaultThinkingLevel, "low");
  assert.equal(settings.modelThinkingLevels["fixture-provider/fixture"], "off");
  assert.equal(auth["fixture-provider"].key, "another-you-fixture");
  assert.equal(auth.openai.key, "source-openai-key");
  assert.equal(models.providers["fixture-provider"].baseUrl, "http://127.0.0.1:1/v1");
});

test("自动复用后源变更、删除或重启不覆盖应用选择，也不会恢复已注销账户", async t => {
  const f = await discoveryFixture(t);
  await writePiFixture(join(f.root, "source"), "http://127.0.0.1:1/v1", "high");
  await f.configuration.load();
  await f.configuration.select("fixture-provider", "fixture", "low");
  await f.configuration.logout("fixture-provider");
  await writePiFixture(join(f.root, "source"), "http://127.0.0.1:2/v1", "off");
  const reopened = new ModelConfiguration(f.dataDir);
  await reopened.load();
  assert.equal(reopened.selection?.configured, false);
  assert.equal(reopened.snapshot.selected?.thinkingLevel, "low");
  assert.equal(JSON.parse(await readModelData(join(reopened.directory, "models.json"), "utf8")).providers["fixture-provider"].baseUrl, "http://127.0.0.1:1/v1");
  await rm(f.source, { recursive: true });
  await reopened.load();
  assert.equal(reopened.snapshot.message, undefined);
  assert.equal(reopened.snapshot.selected?.thinkingLevel, "low");
});

test("损坏的 Pi 配置不会污染应用，修复后重新读取自动恢复", async t => {
  const f = await discoveryFixture(t);
  await writePiFixture(join(f.root, "source"), "http://127.0.0.1:1/v1");
  for (const name of ["models.json", "settings.json", "auth.json"]) {
    const before = await readModelData(join(f.source, name), "utf8");
    await writeModelData(join(f.source, name), "{ broken");
    await f.configuration.load();
    assert.match(f.configuration.snapshot.message ?? "", /本机 Pi 配置/);
    assert.equal(f.configuration.snapshot.selected, undefined);
    assert.deepEqual(JSON.parse(await readModelData(join(f.configuration.directory, "auth.json"), "utf8")), {});
    await assert.rejects(readModelData(join(f.configuration.directory, "pi-discovery.json")));
    await writeModelData(join(f.source, name), before);
  }
  await f.configuration.load();
  assert.equal(f.configuration.selection?.configured, true);
  assert.equal(f.configuration.snapshot.message, undefined);
});

test("本机 Pi 损坏不禁用应用现有配置，源凭据命令不会执行", async t => {
  const f = await discoveryFixture(t);
  await writePiFixture(f.dataDir, "http://127.0.0.1:1/v1");
  await mkdir(f.source, { recursive: true });
  await writeModelData(join(f.source, "auth.json"), "[]");
  await f.configuration.load();
  assert.equal(f.configuration.selection?.configured, true);
  const marker = join(f.root, "must-not-execute");
  await writeModelData(join(f.source, "auth.json"), JSON.stringify({ openai: { type: "api_key", key: `!touch '${marker}'` } }));
  await f.configuration.load();
  assert.equal(f.configuration.snapshot.message, undefined);
  assert.equal(f.configuration.snapshot.providers.find(provider => provider.id === "openai")?.configured, false);
  assert.match(f.configuration.snapshot.providers.find(provider => provider.id === "openai")?.configurationIssue ?? "", /命令/);
  await assert.rejects(access(marker));
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
  assert.equal(JSON.parse(await readModelData(join(f.directory, "auth.json"), "utf8"))["fixture-provider"].key, "only-in-auth-file-key");
  assert.equal(JSON.stringify(f.events).includes("only-in-auth-file-key"), false);
  assert.ok(f.events.every(event => event.kind.startsWith("model.")));
  f.handler.handle({ op: "modelLogout", requestId: "logout", provider: "fixture-provider" });
  await completed(f.events, "logout");
  assert.equal(f.configuration.snapshot.providers.find(provider => provider.id === "fixture-provider")?.configured, false);
  assert.equal(JSON.parse(await readModelData(join(f.directory, "auth.json"), "utf8"))["fixture-provider"], undefined);
});

test("OAuth 企业域名允许留空，过期 prompt 不影响下一步授权码提交", async t => {
  let domain: string | undefined;
  const f = await setup(t, models => {
    const provider = models.getProvider("fixture-provider")!;
    models.setProvider({ ...provider, auth: { ...provider.auth, oauth: {
      name: "Fixture OAuth", login: async (interaction: ProviderAuthInteraction) => {
        domain = await interaction.prompt({ type: "text", message: "GitHub Enterprise URL/domain (blank for github.com)" });
        interaction.notify({ type: "device_code", userCode: "ABCD-EFGH", verificationUri: "https://example.invalid/device" });
        const access = await interaction.prompt({ type: "manual_code", message: "Fixture authorization code" });
        return { type: "oauth", access, refresh: "fixture-refresh", expires: Date.now() + 60_000 };
      }, refresh: async credential => credential, toAuth: async credential => ({ apiKey: credential.access }),
    } } });
  });
  f.handler.handle({ op: "modelLogin", requestId: "empty-domain", provider: "fixture-provider", authType: "oauth" });
  const domainPrompt = await eventMatching(f.events, event => event.kind === "model.auth" && event.payload.stage === "prompt");
  const domainPromptId = (domainPrompt.payload.prompt as { id: string }).id;
  f.handler.handle({ op: "modelAuthReply", requestId: "empty-domain", promptId: domainPromptId, value: "" });
  const codePrompt = await eventMatching(f.events, event => event.kind === "model.auth" && event.payload.stage === "prompt"
    && (event.payload.prompt as { type: string }).type === "manual_code");
  assert.equal(domain, "");
  assert.ok(f.events.some(event => (event.payload.notice as { type?: string } | undefined)?.type === "device_code"));
  f.handler.handle({ op: "modelAuthReply", requestId: "empty-domain", promptId: domainPromptId, value: "stale-value" });
  assert.equal(f.events.at(-1)?.payload.state, "failed");
  assert.equal(f.backend.isBusy, true);
  f.handler.handle({ op: "modelAuthReply", requestId: "empty-domain", promptId: (codePrompt.payload.prompt as { id: string }).id, value: "fixture-access-code" });
  await completed(f.events, "empty-domain");
  assert.equal(f.configuration.snapshot.providers.find(provider => provider.id === "fixture-provider")?.credentialType, "oauth");
  assert.equal(JSON.stringify(f.events).includes("fixture-access-code"), false);
});

for (const prompt of [
  { type: "text", message: "Domain" },
  { type: "secret", message: "Key" },
  { type: "manual_code", message: "Code" },
  { type: "select", message: "Choose", options: [{ id: "valid", label: "Valid" }] },
] satisfies AuthPrompt[]) {
  test(`认证 ${prompt.type} 拒绝无效输入并保留原步骤供重试`, async t => {
    const f = await setup(t, models => {
      const provider = models.getProvider("fixture-provider")!;
      models.setProvider({ ...provider, auth: { ...provider.auth, oauth: {
        name: "Fixture OAuth", login: async (interaction: ProviderAuthInteraction) => {
          const access = await interaction.prompt(prompt);
          return { type: "oauth", access, refresh: "fixture-refresh", expires: Date.now() + 60_000 };
        }, refresh: async credential => credential, toAuth: async credential => ({ apiKey: credential.access }),
      } } });
    });
    f.handler.handle({ op: "modelLogin", requestId: "retry", provider: "fixture-provider", authType: "oauth" });
    const event = await eventMatching(f.events, event => event.kind === "model.auth" && event.payload.stage === "prompt");
    const promptId = (event.payload.prompt as { id: string }).id;
    const invalid = [undefined, 123 as unknown as string, "a".repeat(8193), "😀".repeat(4097),
      ...(prompt.type === "text" ? [] : ["", " \n\t"]), ...(prompt.type === "select" ? ["missing-option"] : [])];
    for (const value of invalid) {
      f.handler.handle({ op: "modelAuthReply", requestId: "retry", promptId, value });
      assert.equal(f.events.at(-1)?.payload.operation, "modelAuthReply");
      assert.equal(f.events.at(-1)?.payload.state, "failed");
      assert.equal(f.backend.isBusy, true);
      assert.equal(f.events.some(event => event.payload.stage === "promptResolved"), false);
    }
    f.handler.handle({ op: "modelAuthReply", requestId: "retry", promptId, value: "valid" });
    await completed(f.events, "retry");
  });
}

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
  const before = await readModelData(join(f.directory, "auth.json"), "utf8");
  f.handler.handle({ op: "modelLogin", requestId: "oauth", provider: "fixture-provider", authType: "oauth" });
  await eventMatching(f.events, event => event.kind === "model.auth" && event.payload.stage === "prompt");
  f.handler.handle({ op: "modelSelect", requestId: "busy", provider: "fixture-provider", model: "fixture" });
  await completed(f.events, "busy", "failed");
  f.handler.handle({ op: "modelAuthCancel", requestId: "oauth" });
  await completed(f.events, "oauth", "cancelled");
  assert.equal(loginSignal?.aborted, true);
  assert.equal(f.backend.isBusy, false);
  assert.equal(await readModelData(join(f.directory, "auth.json"), "utf8"), before);
  f.handler.handle({ op: "modelSelect", requestId: "after-cancel", provider: "fixture-provider", model: "fixture" });
  await completed(f.events, "after-cancel");
});

test("所有内置渠道的 API 凭据流程均可逐步配置并保存", async t => {
  const f = await setup(t);
  const providers = f.configuration.snapshot.providers.filter(provider => provider.id !== "fixture-provider"
    && provider.authMethods.some(method => method.type === "api_key"));
  assert.equal(providers.length, 41);
  for (const provider of providers) await t.test(provider.id, async () => {
    const requestId = `builtin-key-${provider.id}`;
    const answered = new Set<string>();
    f.handler.handle({ op: "modelLogin", requestId, provider: provider.id, authType: "api_key" });
    for (let step = 0; step < 6; step++) {
      const event = await eventMatching(f.events, event => event.payload.requestId === requestId
        && (event.payload.operation === "modelLogin" && ["succeeded", "failed"].includes(String(event.payload.state))
          || event.payload.stage === "prompt" && !answered.has((event.payload.prompt as { id: string }).id)));
      if (event.kind === "model.operation") {
        assert.equal(event.payload.state, "succeeded", String(event.payload.message));
        assert.equal(f.configuration.snapshot.providers.find(item => item.id === provider.id)?.configured, true);
        const credentials = JSON.parse(await readModelData(join(f.directory, "auth.json"), "utf8"));
        assert.equal(credentials[provider.id].key, `fixture-${provider.id}`);
        return;
      }
      const prompt = event.payload.prompt as AuthPrompt & { id: string; required: boolean };
      answered.add(prompt.id);
      if (prompt.required) {
        f.handler.handle({ op: "modelAuthReply", requestId, promptId: prompt.id, value: "" });
        assert.equal(f.events.at(-1)?.payload.state, "failed");
      }
      const value = prompt.type === "select" ? prompt.options[0].id : ` \nfixture-${provider.id}\t `;
      f.handler.handle({ op: "modelAuthReply", requestId, promptId: prompt.id, value });
    }
    assert.fail(`${provider.id} 的登录流程未完成`);
  });
});

test("所有内置 OAuth 渠道进入授权流程后均可取消且不写入凭据", async t => {
  const requests: string[] = [];
  t.mock.method(globalThis, "fetch", async (input: string | URL | Request) => {
    const url = new URL(input instanceof Request ? input.url : input);
    requests.push(url.href);
    if (url.pathname === "/v1/oauth") return Response.json({ authorizationEndpoint: "https://example.invalid/authorize" });
    if (/device/.test(url.pathname) && !/token/.test(url.pathname)) return Response.json({
      device_code: "fixture-device", device_auth_id: "fixture-device-auth", user_code: "ABCD-EFGH", verification_uri: "https://example.invalid/device",
      verification_uri_complete: "https://example.invalid/device?code=ABCD-EFGH", interval: 30, expires_in: 600,
    });
    if (/token/.test(url.pathname)) return Response.json({ error: "authorization_pending" }, { status: url.pathname.includes("deviceauth") ? 403 : 400 });
    throw new Error(`未预期的 OAuth fixture 请求：${url.origin}${url.pathname}`);
  });
  const f = await setup(t);
  const providers = f.configuration.snapshot.providers.filter(provider => provider.authMethods.some(method => method.type === "oauth"));
  assert.equal(providers.length, 9);
  const cases = [...providers.map(provider => ({ provider: provider.id, device: false })),
    { provider: "openai-codex", device: true }, { provider: "radius", device: true }];
  for (const scenario of cases) await t.test(`${scenario.provider}${scenario.device ? "/device-code" : ""}`, async () => {
    const requestId = `builtin-oauth-${scenario.provider}-${scenario.device}`;
    const before = await readModelData(join(f.directory, "auth.json"), "utf8");
    const answered = new Set<string>();
    f.handler.handle({ op: "modelLogin", requestId, provider: scenario.provider, authType: "oauth" });
    for (let step = 0; step < 4; step++) {
      const event = await eventMatching(f.events, event => event.payload.requestId === requestId
        && (event.payload.operation === "modelLogin" && event.payload.state === "failed"
          || event.payload.stage === "prompt" && !answered.has((event.payload.prompt as { id: string }).id)
          || event.payload.stage === "notify" && ["auth_url", "device_code"].includes((event.payload.notice as { type: string }).type)));
      assert.notEqual(event.payload.state, "failed", String(event.payload.message));
      if (event.payload.stage === "notify") {
        const notice = event.payload.notice as { type: string; url?: string; verificationUri?: string; userCode?: string };
        assert.match(notice.url ?? notice.verificationUri ?? "", /^https?:\/\//);
        if (notice.type === "device_code") assert.equal(notice.userCode, "ABCD-EFGH");
        f.handler.handle({ op: "modelAuthCancel", requestId });
        await completed(f.events, requestId, "cancelled");
        assert.equal(f.backend.isBusy, false);
        assert.equal(await readModelData(join(f.directory, "auth.json"), "utf8"), before);
        return;
      }
      const prompt = event.payload.prompt as AuthPrompt & { id: string; required: boolean };
      answered.add(prompt.id);
      const value = prompt.type === "select" ? prompt.options[scenario.device ? 1 : 0].id : "";
      assert.equal(prompt.type === "text" && prompt.required, false);
      f.handler.handle({ op: "modelAuthReply", requestId, promptId: prompt.id, value });
    }
    assert.fail(`${scenario.provider} 没有提供授权入口`);
  });
  assert.ok(requests.some(url => url.includes("github.com/login/device/code")));
  assert.equal(JSON.stringify(f.events).includes('"device_code":"fixture-device"'), false);
});

test("缺少应用可用凭据的渠道不提示已经可以选择模型", async t => {
  const f = await setup(t);
  const requestId = "bedrock-ambient";
  f.handler.handle({ op: "modelLogin", requestId, provider: "amazon-bedrock", authType: "api_key" });
  const selection = await eventMatching(f.events, event => event.payload.requestId === requestId && event.payload.stage === "prompt");
  f.handler.handle({ op: "modelAuthReply", requestId, promptId: (selection.payload.prompt as { id: string }).id, value: "credential-chain" });
  const confirmation = await eventMatching(f.events, event => event.payload.requestId === requestId && event.payload.stage === "prompt"
    && (event.payload.prompt as { type: string }).type === "text");
  assert.equal((confirmation.payload.prompt as { required: boolean }).required, false);
  f.handler.handle({ op: "modelAuthReply", requestId, promptId: (confirmation.payload.prompt as { id: string }).id, value: "" });
  const result = await completed(f.events, requestId);
  assert.equal(f.configuration.snapshot.providers.find(provider => provider.id === "amazon-bedrock")?.configured, false);
  assert.equal(result.payload.message, "账户信息已保存，但凭据尚不可用，请检查配置或更换登录方式");
});

test("AWS 和 Google Cloud 的附加账户字段必须填写，未解析的本机凭据会明确提示", async t => {
  const f = await setup(t);
  for (const scenario of [
    { provider: "amazon-bedrock", method: "aws-profile", fields: ["work-profile"], configured: true },
    { provider: "google-vertex", method: "adc", fields: ["project-id", "us-central1"], configured: false },
    { provider: "google-vertex", method: "service-account", fields: ["project-id", "us-central1", "/nonexistent/service-account.json"], configured: false },
  ]) await t.test(`${scenario.provider}/${scenario.method}`, async () => {
    const requestId = `cloud-${scenario.method}`;
    const answered = new Set<string>();
    f.handler.handle({ op: "modelLogin", requestId, provider: scenario.provider, authType: "api_key" });
    for (const value of [scenario.method, ...scenario.fields]) {
      const event = await eventMatching(f.events, event => event.payload.requestId === requestId && event.payload.stage === "prompt"
        && !answered.has((event.payload.prompt as { id: string }).id));
      const prompt = event.payload.prompt as AuthPrompt & { id: string; required: boolean };
      answered.add(prompt.id);
      assert.equal(prompt.required, true);
      f.handler.handle({ op: "modelAuthReply", requestId, promptId: prompt.id, value: " \t" });
      assert.equal(f.events.at(-1)?.payload.state, "failed");
      f.handler.handle({ op: "modelAuthReply", requestId, promptId: prompt.id, value });
    }
    const result = await completed(f.events, requestId);
    assert.equal(f.configuration.snapshot.providers.find(provider => provider.id === scenario.provider)?.configured, scenario.configured);
    assert.equal(result.payload.message, scenario.configured ? "账户已保存，请选择模型" : "账户信息已保存，但凭据尚不可用，请检查配置或更换登录方式");
  });
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
  assert.equal(JSON.parse(await readModelData(join(f.directory, "auth.json"), "utf8"))["fixture-provider"].access, "fixture-refreshed-access");
  assert.equal(JSON.stringify(f.events).includes("fixture-access-code"), false);
});

test("导入只复制模型定义与默认选择，保留独立账户，拒绝无效文件", async t => {
  const f = await setup(t);
  const source = await mkdtemp(join(tmpdir(), "another-you-model-import-"));
  t.after(() => rm(source, { recursive: true, force: true }));
  await writePiFixture(source, "http://127.0.0.1:1/v1", "high");
  const sourceDirectory = join(source, "pi");
  await writeModelData(join(sourceDirectory, "settings.json"), JSON.stringify({ defaultProvider: "fixture-provider", defaultModel: "fixture",
    defaultThinkingLevel: "high", modelThinkingLevels: {} }));
  const models = JSON.parse(await readModelData(join(sourceDirectory, "models.json"), "utf8"));
  models.providers["fixture-provider"].apiKey = "imported-secret";
  models.providers["fixture-provider"].headers = { Authorization: "Bearer imported-secret" };
  models.providers["fixture-provider"].models[0].headers = { "x-api-key": "imported-secret" };
  await writeModelData(join(sourceDirectory, "models.json"), JSON.stringify(models));
  const authBefore = await readModelData(join(f.directory, "auth.json"), "utf8");
  await f.configuration.importConfiguration(sourceDirectory);
  assert.equal((await readModelData(join(f.directory, "models.json"), "utf8")).includes("imported-secret"), false);
  assert.equal(await readModelData(join(f.directory, "auth.json"), "utf8"), authBefore);
  assert.equal(f.configuration.snapshot.selected?.thinkingLevel, "high");
  await f.configuration.importConfiguration(join(sourceDirectory, "models.json"));
  assert.equal(f.configuration.snapshot.selected?.thinkingLevel, "high");
  const before = await readModelData(join(f.directory, "models.json"), "utf8");
  await writeModelData(join(sourceDirectory, "models.json"), '{"providers":[]}');
  await assert.rejects(f.configuration.importConfiguration(sourceDirectory), /导入的 models.json 无效/);
  assert.equal(await readModelData(join(f.directory, "models.json"), "utf8"), before);
});

test("无路径导入自动读取 Pi，合并新增模型并保留本地配置和账户，源文件只读", async t => {
  const f = await setup(t);
  const source = await mkdtemp(join(isolatedPiRoot, "manual-import-"));
  const sourceDirectory = await writePiFixture(source, "https://imported.example.invalid/v1", "low");
  const previous = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = sourceDirectory;
  t.after(() => { process.env.PI_CODING_AGENT_DIR = previous; });
  const modelsPath = join(sourceDirectory, "models.json");
  const models = JSON.parse(await readModelData(modelsPath, "utf8"));
  const provider = models.providers["fixture-provider"];
  provider.models[0].name = "Imported duplicate";
  provider.models.push({ ...provider.models[0], id: "new-model" });
  models.providers["new-provider"] = { ...provider, apiKey: "inline-import-secret",
    headers: { Authorization: "Bearer imported-header-secret" }, models: [{ ...provider.models[0], id: "imported" }] };
  await writeModelData(modelsPath, '\uFEFF// Pi model configuration\n' + JSON.stringify(models));
  await writeModelData(join(sourceDirectory, "settings.json"), JSON.stringify({ defaultProvider: "new-provider", defaultModel: "imported",
    defaultThinkingLevel: "low", modelThinkingLevels: { "new-provider/imported": "high" } }));
  await writeModelData(join(sourceDirectory, "auth.json"), JSON.stringify({ "new-provider": { type: "api_key", key: "source-auth-secret" } }));
  const sourcePaths = ["models.json", "settings.json", "auth.json"].map(name => join(sourceDirectory, name));
  const sourceBefore = await Promise.all(sourcePaths.map(path => readModelData(path, "utf8")));
  const authBefore = await readModelData(join(f.directory, "auth.json"), "utf8");
  const localBefore = JSON.parse(await readModelData(join(f.directory, "models.json"), "utf8"));

  f.handler.handle({ op: "modelImport", requestId: "automatic-import" });
  await completed(f.events, "automatic-import");
  const saved = JSON.parse(await readModelData(join(f.directory, "models.json"), "utf8"));
  assert.equal(saved.providers["fixture-provider"].baseUrl, localBefore.providers["fixture-provider"].baseUrl);
  assert.deepEqual(saved.providers["fixture-provider"].models[0], localBefore.providers["fixture-provider"].models[0]);
  assert.ok(saved.providers["fixture-provider"].models.some((model: { id: string }) => model.id === "new-model"));
  assert.equal(saved.providers["new-provider"].models[0].id, "imported");
  assert.equal(JSON.stringify(saved).includes("import-secret"), false);
  assert.equal(JSON.stringify(saved).includes("imported-header-secret"), false);
  assert.deepEqual(f.configuration.snapshot.selected, { provider: "new-provider", model: "imported", thinkingLevel: "high" });
  assert.equal(f.configuration.snapshot.providers.find(provider => provider.id === "new-provider")?.configured, false);
  await f.configuration.load();
  assert.equal(await readModelData(join(f.directory, "auth.json"), "utf8"), authBefore);
  assert.deepEqual(await Promise.all(sourcePaths.map(path => readModelData(path, "utf8"))), sourceBefore);
  assert.equal(JSON.stringify(f.events).includes("source-auth-secret"), false);
});

test("自动导入缺失或损坏的 Pi 配置返回明确错误且不改变本地文件", async t => {
  const f = await setup(t);
  const source = await mkdtemp(join(isolatedPiRoot, "invalid-import-"));
  const sourceDirectory = join(source, "pi");
  const previous = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = sourceDirectory;
  t.after(() => { process.env.PI_CODING_AGENT_DIR = previous; });
  const localPaths = ["models.json", "settings.json", "auth.json"].map(name => join(f.directory, name));
  const before = await Promise.all(localPaths.map(path => readModelData(path, "utf8")));
  f.handler.handle({ op: "modelImport", requestId: "missing-import" });
  const failure = await completed(f.events, "missing-import", "failed");
  assert.match(String(failure.payload.message), /未找到 Pi 模型配置/);
  await mkdir(sourceDirectory);
  await assert.rejects(f.configuration.importConfiguration(), /未找到 Pi 模型配置/);
  await writeModelData(join(sourceDirectory, "models.json"), "{ broken");
  await assert.rejects(f.configuration.importConfiguration(), /导入的 models.json 无效/);
  await writeModelData(join(sourceDirectory, "models.json"), '{"providers":{"bad":{"models":[{"id":"invalid"}]}}}');
  await assert.rejects(f.configuration.importConfiguration(), /导入的 models.json 无效/);
  await writeModelData(join(sourceDirectory, "models.json"), '{"providers":{}}');
  await writeModelData(join(sourceDirectory, "settings.json"), "{ broken");
  await assert.rejects(f.configuration.importConfiguration(), /settings.json 无法读取/);
  assert.deepEqual(await Promise.all(localPaths.map(path => readModelData(path, "utf8"))), before);
  await assert.rejects(readModelData(join(f.directory, "pi-discovery.json")), { code: "ENOENT" });
});

test("账户切换恢复不同协议与模型，取消保存回滚且重启不丢失原账户", async t => {
  const f = await setup(t);
  const c = f.configuration;
  await c.configureAPI({ provider: "fixture-provider", baseUrl: "https://first.invalid/v1", api: "openai-completions",
    model: "fixture", apiKey: "account-first", thinkingLevel: "high", accountName: "First" });
  const first = c.snapshot.providers.find(item => item.id === "fixture-provider")!.accountId!;
  await c.configureAPI({ provider: "fixture-provider", baseUrl: "https://second.invalid", api: "anthropic-messages",
    model: "claude-second", apiKey: "account-second", thinkingLevel: "off", newAccount: true, accountName: "Second" });
  const second = c.snapshot.providers.find(item => item.id === "fixture-provider")!.accountId!;
  await c.selectAccount(first);
  assert.equal(c.selection?.model.api, "openai-completions");
  assert.equal(c.selection?.model.id, "fixture");
  assert.equal(c.selection?.thinkingLevel, "high");
  assert.equal(c.readAPIKey(first), "account-first");
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(c.configureAPI({ provider: "fixture-provider", baseUrl: "https://cancelled.invalid", api: "openai-responses",
    model: "cancelled", apiKey: "cancelled-secret", newAccount: true }, controller.signal));
  c.close();
  await c.load();
  assert.equal(c.snapshot.accounts?.filter(item => item.provider === "fixture-provider").length, 2);
  await c.selectAccount(second);
  assert.equal(c.selection?.model.api, "anthropic-messages");
  assert.equal(c.selection?.model.id, "claude-second");
  assert.equal(c.selection?.model.baseUrl, "https://second.invalid");
  assert.equal(c.selection?.thinkingLevel, "off");
  assert.equal(c.readAPIKey(second), "account-second");
});

test("旧配置迁移失败保留原文件，修复后原子迁移到 SQLite 并可重启", async t => {
  const root = await mkdtemp(join(tmpdir(), "another-you-migration-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const directory = await writePiFixture(root, "http://127.0.0.1:1/v1");
  const settingsPath = join(directory, "settings.json");
  const original = await readModelData(settingsPath);
  await writeModelData(settingsPath, "{broken");
  const configuration = new ModelConfiguration(root);
  t.after(() => configuration.close());
  await configuration.load();
  assert.match(configuration.message, /settings.json 无法读取/);
  await access(join(directory, "auth.json"));
  await access(join(directory, "models.json"));
  assert.equal(await readModelData(settingsPath), "{broken");
  await writeModelData(settingsPath, original);
  await configuration.load();
  assert.equal(configuration.selection?.configured, true);
  const account = configuration.snapshot.providers.find(item => item.id === "fixture-provider")!.accountId!;
  await assert.rejects(access(join(directory, "auth.json")), { code: "ENOENT" });
  await assert.rejects(access(join(directory, "models.json")), { code: "ENOENT" });
  assert.equal((await stat(join(directory, "models.sqlite"))).mode & 0o777, 0o600);
  configuration.close();
  await configuration.load();
  assert.equal(configuration.snapshot.providers.find(item => item.id === "fixture-provider")!.accountId, account);
  assert.equal(configuration.readAPIKey(account), "another-you-fixture");
});
