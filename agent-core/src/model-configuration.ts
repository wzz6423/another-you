import { randomUUID } from "node:crypto";
import { chmod, mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, resolve } from "node:path";
import {
  clampThinkingLevel, createModels, getSupportedThinkingLevels, lazyStream,
  type Api, type AuthInteraction, type AuthType, type Context, type Credential, type CredentialStore,
  type Model, type ModelsSimpleStreamOptions, type ModelThinkingLevel, type MutableModels,
  type ProviderHeaders,
} from "@earendil-works/pi-ai";
import { getAgentDir, ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import { piDirectoryForDataDir } from "./config.ts";
import { ModelDatabase, type ModelAccount } from "./model-database.ts";
import { redactSecrets as redactTextSecrets } from "./state.ts";

const { getConfigValueEnvVarNames, isCommandConfigValue } = await import(new URL(
  "./core/resolve-config-value.js", import.meta.resolve("@earendil-works/pi-coding-agent"),
).href);

export interface CatalogModel {
  id: string;
  name: string;
  provider: string;
  input: readonly string[];
  thinkingLevels: ModelThinkingLevel[];
  contextWindow: number;
  maxTokens: number;
  configured: boolean;
}

export interface CatalogProvider {
  id: string;
  name: string;
  configured: boolean;
  credentialType?: AuthType;
  authMethods: { type: AuthType; name: string }[];
  configurationIssue?: string;
  apiConfiguration?: { baseUrl: string; api: string };
  accountId?: string;
}

const CONFIGURATION_APIS = new Set(["openai-completions", "openai-responses", "anthropic-messages"]);

export interface AccountInput {
  accountId?: string;
  accountName?: string;
  newAccount?: boolean;
}

export interface ApiConfigurationInput extends AccountInput {
  provider: string;
  baseUrl: string;
  api: string;
  model: string;
  apiKey?: string;
  thinkingLevel?: string;
}

export interface ModelCatalog {
  models: CatalogModel[];
  providers: CatalogProvider[];
  selected?: { provider: string; model: string; thinkingLevel: ModelThinkingLevel };
  message?: string;
  accounts?: { id: string; provider: string; name: string; hasAPIKey: boolean; credentialType?: AuthType }[];
}

interface PiStorageModules {
  AuthStorage: { inMemory(): CredentialStore };
  ReadOnlyAuthStorage: new (path: string) => CredentialStore;
  ModelConfig: { load(path: string): Promise<{
    getProviderIds(): readonly string[];
    getProvider(id: string): unknown;
    getError(): string | undefined;
  }> };
  resolveConfiguredModelHeaders(model: Model<Api>, config: unknown, extension: undefined, env?: Record<string, string>): ProviderHeaders | undefined;
}

let storageModules: Promise<PiStorageModules> | undefined;
function piStorageModules(): Promise<PiStorageModules> {
  // Pi 0.99.2 的文件解析器未从包根导出；导入继续遵循官方 JSONC 与认证格式。
  return storageModules ??= (async () => {
    const root = import.meta.resolve("@earendil-works/pi-coding-agent");
    const [auth, composer, config] = await Promise.all([
      import(new URL("./core/auth-storage.js", root).href),
      import(new URL("./core/provider-composer.js", root).href),
      import(new URL("./core/model-config.js", root).href),
    ]);
    return { AuthStorage: auth.AuthStorage, ReadOnlyAuthStorage: auth.ReadOnlyAuthStorage,
      ModelConfig: config.ModelConfig,
      resolveConfiguredModelHeaders: composer.resolveConfiguredModelHeaders };
  })();
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function hasExternalConfigurationValue(value: unknown): boolean {
  if (typeof value === "string") return isCommandConfigValue(value) || getConfigValueEnvVarNames(value).length > 0;
  if (Array.isArray(value)) return value.some(hasExternalConfigurationValue);
  return record(value) && Object.values(value).some(hasExternalConfigurationValue);
}

async function jsonFile(path: string, missing: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
  try {
    const value: unknown = JSON.parse((await readFile(path, "utf8")).replace(/^\uFEFF/, ""));
    if (!record(value)) throw new Error();
    return value;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return missing;
    throw new Error(`${path.endsWith("auth.json") ? "auth.json" : path.endsWith("settings.json") ? "settings.json" : "models.json"} 无法读取，请检查文件格式`);
  }
}

async function writeJSON(path: string, value: unknown): Promise<void> {
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
    await rename(temporary, path);
  } finally { await rm(temporary, { force: true }); }
}

function withoutAuthentication(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(withoutAuthentication);
  if (!record(value)) return value;
  return Object.fromEntries(Object.entries(value)
    .filter(([key]) => !["apiKey", "headers", "env", "authorization", "access", "refresh"].includes(key))
    .map(([key, child]) => [key, withoutAuthentication(child)]));
}

export class ModelConfiguration {
  readonly directory: string;
  private models?: MutableModels;
  private settings?: SettingsManager;
  private credentials?: CredentialStore;
  private database?: ModelDatabase;
  private providerConfiguration: Record<string, unknown> = {};
  private catalog: ModelCatalog = { models: [], providers: [] };
  private configurationError?: string;
  private discoveryError?: string;
  private readonly configureModels?: (models: MutableModels) => void;

  constructor(dataDir: string, configureModels?: (models: MutableModels) => void) {
    this.directory = piDirectoryForDataDir(dataDir);
    this.configureModels = configureModels;
  }

  get snapshot(): ModelCatalog { return this.catalog; }

  close(): void { this.database?.close(); this.database = undefined; }

  redactSecrets(message: string): string {
    for (const account of this.database?.accounts() ?? []) {
      const credential = account.credential;
      const secrets = credential?.type === "api_key" ? [credential.key] : credential?.type === "oauth" ? [credential.access, credential.refresh] : [];
      for (const secret of secrets) if (typeof secret === "string" && secret) message = message.split(secret).join("[已隐藏]");
    }
    return redactTextSecrets(message);
  }

  private get storage(): ModelDatabase {
    if (!this.database) throw new Error("本地模型数据库尚未加载");
    return this.database;
  }

  private async runtime(raw: Record<string, unknown>): Promise<ModelRuntime> {
    const temporary = join(this.directory, `models.${randomUUID()}.json`);
    try {
      await writeJSON(temporary, raw);
      return await ModelRuntime.create({ credentials: this.storage.credentials(), modelsPath: temporary,
        modelsStore: this.storage.modelsStore(), allowModelNetwork: false, refreshOnCreate: false });
    } finally { await rm(temporary, { force: true }); }
  }

  private saveImportedConfiguration(raw: Record<string, unknown>, auth: Record<string, unknown>, settings: Record<string, unknown>): void {
    const models = structuredClone(raw);
    const providers = record(models.providers) ? models.providers : {};
    const credentials = { ...auth };
    for (const [provider, configuration] of Object.entries(providers)) {
      if (!record(configuration)) continue;
      if (typeof configuration.apiKey === "string") {
        credentials[provider] ??= { type: "api_key", key: configuration.apiKey };
        delete configuration.apiKey;
      }
    }
    this.storage.write("models.json", { ...models, providers });
    this.storage.write("settings.json", settings);
    const ids = new Set([...Object.keys(providers), ...Object.keys(credentials), ...this.storage.activeAccountIDs().keys()]);
    for (const provider of ids) {
      const current = this.storage.activeAccount(provider);
      const model = settings.defaultProvider === provider && typeof settings.defaultModel === "string" ? settings.defaultModel : current?.model;
      const levels = record(settings.modelThinkingLevels) ? settings.modelThinkingLevels : {};
      const level = model ? levels[`${provider}/${model}`] ?? settings.defaultThinkingLevel : current?.thinkingLevel;
      const account: ModelAccount = { id: current?.id ?? randomUUID(), provider, name: current?.name ?? provider,
        configuration: record(providers[provider]) ? providers[provider] : {},
        ...(model ? { model } : {}), ...(typeof level === "string" ? { thinkingLevel: level } : {}),
        ...(record(credentials[provider]) ? { credential: credentials[provider] as unknown as Credential } : {}) };
      this.storage.saveAccount(account);
      this.storage.activate(account);
    }
  }

  private async migrateLegacyConfiguration(): Promise<void> {
    if (this.storage.read("migration").version === 1) return;
    const sdk = await piStorageModules();
    const parsed = await sdk.ModelConfig.load(join(this.directory, "models.json"));
    if (parsed.getError()) throw new Error("models.json 无法读取，请检查模型配置");
    const models = { providers: Object.fromEntries(parsed.getProviderIds().map(id => [id, parsed.getProvider(id)])) };
    const settings = await jsonFile(join(this.directory, "settings.json"));
    const auth = await jsonFile(join(this.directory, "auth.json"));
    const device = await jsonFile(join(this.directory, "device-id.json"));
    const discovery = await jsonFile(join(this.directory, "pi-discovery.json"));
    const cache = await jsonFile(join(this.directory, "models-store.json"));
    if ((await this.runtime(models)).getError()) throw new Error("models.json 无法读取，请检查模型配置");
    await this.storage.transactionAsync(async () => {
      this.saveImportedConfiguration(models, auth, settings);
      this.storage.write("device-id.json", device);
      this.storage.write("pi-discovery.json", discovery);
      const store = this.storage.modelsStore();
      for (const [provider, value] of Object.entries(cache)) {
        if (record(value) && Array.isArray(value.models)) await store.write(provider, value as unknown as import("@earendil-works/pi-ai").ModelsStoreEntry);
      }
      this.storage.write("migration", { version: 1 });
    });
    if (resolve(getAgentDir()) !== resolve(this.directory)) {
      for (const name of ["models.json", "settings.json", "auth.json", "device-id.json", "pi-discovery.json", "models-store.json"]) {
        await rm(join(this.directory, name), { force: true });
      }
    }
  }

  get selection(): { model: Model<Api>; thinkingLevel: ModelThinkingLevel; configured: boolean } | undefined {
    const selection = this.catalog.selected;
    const model = selection && this.models?.getModel(selection.provider, selection.model);
    if (!model || !selection) return undefined;
    return { model, thinkingLevel: selection.thinkingLevel,
      configured: !this.configurationError && this.catalog.providers.some(provider => provider.id === model.provider && provider.configured) };
  }

  get message(): string {
    if (this.configurationError) return this.configurationError;
    if (!this.catalog.selected) return this.discoveryError ?? "请在设置中选择模型并配置账户";
    if (!this.selection) return `所选 Pi 模型不存在：${this.catalog.selected.provider}/${this.catalog.selected.model}`;
    if (!this.selection.configured) return "请在设置中配置此提供方的认证";
    return "模型配置已保存；发送请求后验证可用性";
  }

  async load(): Promise<void> {
    this.models = undefined;
    this.credentials = undefined;
    this.settings = undefined;
    this.configurationError = undefined;
    this.discoveryError = undefined;
    this.providerConfiguration = {};
    this.catalog = { models: [], providers: [] };
    try {
      await mkdir(this.directory, { recursive: true, mode: 0o700 });
      await chmod(this.directory, 0o700);
      this.database ??= new ModelDatabase(this.directory);
      await this.migrateLegacyConfiguration();
      const device = this.storage.read("device-id.json");
      if (typeof device.id === "string" && device.id) this.deviceId = device.id;
      else this.storage.write("device-id.json", { id: this.deviceId });
      await this.discoverPiConfiguration();
      const credentials = this.storage.credentials();
      const rawModels = this.storage.read("models.json", { providers: {} });
      this.providerConfiguration = record(rawModels.providers) ? rawModels.providers : {};
      const runtime = await this.runtime(rawModels);
      if (runtime.getError()) this.configurationError = "models.json 无法读取，请检查模型配置";
      const models = createModels({ credentials, modelsStore: this.storage.modelsStore(),
        authContext: { env: async () => undefined, fileExists: async () => false } });
      for (const provider of runtime.getProviders()) models.setProvider(provider);
      this.configureModels?.(models);
      this.credentials = credentials;
      this.models = models;
      this.settings = SettingsManager.fromStorage(this.storage.settingsStorage, { projectTrusted: false });
      if (this.settings.drainErrors().length) this.configurationError = "settings.json 无法读取，请检查模型设置";
      // 即使离线刷新，Pi 仍会读取并解析凭据；先排除外部引用，避免执行认证命令。
      await this.updateCatalog();
      const providers = this.catalog.providers.filter(provider => !provider.configurationIssue).map(provider => provider.id);
      await models.refresh({ allowNetwork: false, providers, signal: AbortSignal.timeout(5_000) });
      await this.updateCatalog();
    } catch (error) {
      this.configurationError = error instanceof Error && /^(auth|settings|models)\.json 无法读取/.test(error.message)
        ? error.message : "Pi 配置无法读取，请检查模型设置和账户文件";
      this.catalog = { ...this.catalog, message: this.configurationError };
    }
  }

  private async discoverPiConfiguration(): Promise<void> {
    const source = resolve(getAgentDir());
    if (source === resolve(this.directory)) return;
    try {
      if (this.storage.read("pi-discovery.json").version === 1) return;
      const sdk = await piStorageModules();
      const sourceModels = await sdk.ModelConfig.load(join(source, "models.json"));
      if (sourceModels.getError()) throw new Error("models.json");
      const sourceAuth = new sdk.ReadOnlyAuthStorage(join(source, "auth.json"));
      await sourceAuth.list();
      const rawAuth = await jsonFile(join(source, "auth.json"));
      const settings = SettingsManager.create(source, source, { projectTrusted: false });
      if (settings.drainErrors().length) throw new Error("settings.json");
      const sourceSettings = settings.getGlobalSettings();
      const providers = Object.fromEntries(sourceModels.getProviderIds().map(id => [id, sourceModels.getProvider(id)]));
      if (!Object.keys(providers).length && !Object.keys(rawAuth).length
        && !sourceSettings.defaultProvider && !sourceSettings.defaultModel) return;

      const localModels = this.storage.read("models.json", { providers: {} });
      const localAuth = this.storage.authData();
      const localSettings = this.storage.read("settings.json");
      const mergedModels = { ...localModels, providers: { ...providers,
        ...(record(localModels.providers) ? localModels.providers : {}) } };
      const validation = await this.runtime(mergedModels);
      if (validation.getError()) throw new Error("models.json");
      const mergedSettings = { ...localSettings };
      if (!Object.hasOwn(localSettings, "defaultProvider") && !Object.hasOwn(localSettings, "defaultModel")
        && typeof sourceSettings.defaultProvider === "string" && typeof sourceSettings.defaultModel === "string") {
        const model = validation.getModel(sourceSettings.defaultProvider, sourceSettings.defaultModel);
        if (!model) throw new Error("settings.json");
        mergedSettings.defaultProvider = model.provider;
        mergedSettings.defaultModel = model.id;
      }
      if (!Object.hasOwn(localSettings, "defaultThinkingLevel") && sourceSettings.defaultThinkingLevel !== undefined) {
        mergedSettings.defaultThinkingLevel = sourceSettings.defaultThinkingLevel;
      }
      mergedSettings.modelThinkingLevels = { ...sourceSettings.modelThinkingLevels,
        ...(record(localSettings.modelThinkingLevels) ? localSettings.modelThinkingLevels : {}) };
      // 自动复用是独立快照；记录成功后不再覆盖用户编辑，也不恢复用户已注销的账户。
      this.storage.transaction(() => {
        this.saveImportedConfiguration(mergedModels, { ...rawAuth, ...localAuth }, mergedSettings);
        this.storage.write("pi-discovery.json", { version: 1 });
      });
    } catch {
      // 本机 Pi 文件损坏不应让已有的应用配置失效；下次重新读取仍会重试。
      this.discoveryError = "本机 Pi 配置无法自动读取，请检查 Pi 配置后重新读取";
    }
  }

  private async updateCatalog(): Promise<void> {
    if (!this.models || !this.credentials) throw new Error("Pi 模型目录尚未加载");
    const rawAuth = this.storage.authData();
    const credentialInfo = await this.credentials.list();
    const metadata = new Map(credentialInfo.map(item => [item.providerId, item.type]));
    const providers = await Promise.all(this.models.getProviders().map(async (provider): Promise<CatalogProvider> => {
      const providerConfig = this.providerConfiguration[provider.id];
      const configuredKey = record(providerConfig) ? providerConfig.apiKey : undefined;
      const headers = record(providerConfig) ? { ...providerConfig, apiKey: undefined } : undefined;
      const external = hasExternalConfigurationValue(rawAuth[provider.id]) || hasExternalConfigurationValue(headers)
        || (!metadata.has(provider.id) && hasExternalConfigurationValue(configuredKey));
      let configured = false;
      if (!external) {
        try { configured = Boolean(await this.models!.checkAuth(provider.id, { signal: AbortSignal.timeout(2_000) })); }
        catch { /* 一个提供方的无效凭据不应阻止其余目录展示。 */ }
      }
      const authMethods: CatalogProvider["authMethods"] = [];
      if (provider.auth.apiKey?.login) authMethods.push({ type: "api_key", name: provider.auth.apiKey.name });
      if (provider.auth.oauth) authMethods.push({ type: "oauth", name: provider.auth.oauth.loginLabel ?? provider.auth.oauth.name });
      const providerModels = this.models!.getModels().filter(model => model.provider === provider.id && CONFIGURATION_APIS.has(model.api));
      const apiModel = providerModels.find(model => this.settings?.getDefaultProvider() === provider.id && this.settings.getDefaultModel() === model.id)
        ?? providerModels.find(model => model.api === "openai-responses") ?? providerModels[0];
      const editableAPI = ["openai", "anthropic"].includes(provider.id)
        || (!provider.auth.oauth && record(providerConfig) && typeof providerConfig.api === "string" && CONFIGURATION_APIS.has(providerConfig.api));
      let publicBaseUrl = "";
      if (apiModel) {
        try {
          const url = new URL(apiModel.baseUrl);
          if (["http:", "https:"].includes(url.protocol)) {
            url.username = ""; url.password = ""; url.search = ""; url.hash = "";
            publicBaseUrl = url.toString();
          }
        } catch { /* 保留地址输入入口，让用户修复无效端点。 */ }
      }
      const account = this.storage.activeAccount(provider.id);
      return { id: provider.id, name: provider.name, configured, authMethods,
        ...(account ? { accountId: account.id } : {}),
        ...(metadata.has(provider.id) ? { credentialType: metadata.get(provider.id)! } : {}),
        ...(editableAPI && apiModel && provider.auth.apiKey ? { apiConfiguration: { baseUrl: publicBaseUrl, api: apiModel.api } } : {}),
        ...(external ? { configurationIssue: "凭据使用环境变量或命令，请在应用内配置账户并移除外部引用" } : {}) };
    }));
    const availableProviders = new Set(providers.filter(provider => provider.configured).map(provider => provider.id));
    const provider = this.settings?.getDefaultProvider();
    const modelId = this.settings?.getDefaultModel();
    const model = provider && modelId ? this.models.getModel(provider, modelId) : undefined;
    const requested = provider && modelId
      ? this.settings?.getModelThinkingLevel(provider, modelId) ?? this.settings?.getDefaultThinkingLevel() ?? "medium" : "off";
    this.catalog = {
      models: this.models.getModels().map(model => ({ id: model.id, name: model.name, provider: model.provider,
        input: model.input, thinkingLevels: getSupportedThinkingLevels(model), contextWindow: model.contextWindow,
        maxTokens: model.maxTokens, configured: availableProviders.has(model.provider) })),
      providers: providers.sort((a, b) => a.name.localeCompare(b.name)),
      accounts: this.storage.accounts().map(account => ({ id: account.id, provider: account.provider, name: account.name,
        hasAPIKey: account.credential?.type === "api_key" && typeof account.credential.key === "string" && Boolean(account.credential.key)
          && !hasExternalConfigurationValue(account.credential),
        ...(account.credential ? { credentialType: account.credential.type } : {}) })),
      ...(provider && modelId ? { selected: { provider, model: modelId, thinkingLevel: model ? clampThinkingLevel(model, requested) : "off" } } : {}),
      ...(this.configurationError || this.discoveryError ? { message: this.configurationError ?? this.discoveryError } : {}),
    };
  }

  private accountFor(provider: string, input: AccountInput = {}): ModelAccount {
    if (input.newAccount !== undefined && typeof input.newAccount !== "boolean") throw new Error("账户选项无效");
    if (input.accountId !== undefined && (typeof input.accountId !== "string" || !input.accountId || input.newAccount)) throw new Error("账户选项无效");
    const current = input.newAccount ? undefined : input.accountId ? this.storage.account(input.accountId) : this.storage.activeAccount(provider);
    if (input.accountId && (!current || current.provider !== provider)) throw new Error("账户不存在，请重新选择账户");
    if (input.accountName !== undefined && (typeof input.accountName !== "string" || !input.accountName.trim()
      || input.accountName.length > 120 || /[\x00-\x1f\x7f]/.test(input.accountName))) throw new Error("账户名称无效");
    const selected = this.catalog.selected?.provider === provider ? this.catalog.selected : undefined;
    return { ...(current ?? { id: randomUUID(), provider,
      name: `${provider} ${this.storage.accounts().filter(item => item.provider === provider).length + 1}`,
      configuration: record(this.providerConfiguration[provider]) ? structuredClone(this.providerConfiguration[provider]) : {},
      ...(selected ? { model: selected.model, thinkingLevel: selected.thinkingLevel } : {}) }),
      ...(input.accountName ? { name: input.accountName.trim() } : {}) };
  }

  private async change(work: () => Promise<void>, signal?: AbortSignal): Promise<void> {
    try { await this.storage.transactionAsync(work, signal); }
    catch (error) { await this.load(); throw error; }
  }

  async select(provider: string, modelId: string, thinkingLevel?: string, accountName?: string): Promise<void> {
    if (!this.models || !this.settings || this.configurationError) throw new Error(this.message);
    const model = this.models.getModel(provider, modelId);
    if (!model) throw new Error("模型不在当前 Pi 目录中");
    const levels = getSupportedThinkingLevels(model);
    if (thinkingLevel !== undefined && !levels.includes(thinkingLevel as ModelThinkingLevel)) throw new Error("此模型不支持所选思考深度");
    const level = thinkingLevel as ModelThinkingLevel | undefined
      ?? clampThinkingLevel(model, this.settings.getModelThinkingLevel(provider, modelId) ?? this.settings.getDefaultThinkingLevel() ?? "medium");
    const account = this.accountFor(provider, { accountName });
    await this.change(async () => {
      this.settings!.setDefaultModelAndProvider(provider, modelId);
      this.settings!.setModelThinkingLevel(provider, modelId, level);
      await this.settings!.flush();
      if (this.settings!.drainErrors().length) throw new Error("模型设置保存失败");
      this.storage.saveAccount({ ...account, model: modelId, thinkingLevel: level });
      this.storage.activate(account);
    });
    await this.updateCatalog();
  }

  async configureAPI(input: ApiConfigurationInput, signal?: AbortSignal): Promise<void> {
    if (!this.models || !this.credentials || !this.settings || this.configurationError) throw new Error(this.message);
    const provider = input.provider.trim(), modelId = input.model.trim(), baseUrl = input.baseUrl.trim();
    for (const value of [provider, modelId, baseUrl]) {
      if (!value || value.length > 8192 || /[\x00-\x1f\x7f]/.test(value)) throw new Error("提供方、接口地址和模型 ID 不能为空或包含控制字符");
    }
    if (["__proto__", "constructor", "prototype"].includes(provider)) throw new Error("提供方名称无效");
    if (!CONFIGURATION_APIS.has(input.api)) throw new Error("请选择支持的 API 协议");
    try {
      const url = new URL(baseUrl);
      if (!["http:", "https:"].includes(url.protocol) || !url.hostname || url.username || url.password || url.search || url.hash || /\s/.test(baseUrl)) throw new Error();
    } catch { throw new Error("请输入有效的 HTTP 或 HTTPS 接口地址，不能包含凭据、查询参数或片段"); }
    if (input.apiKey !== undefined && (typeof input.apiKey !== "string" || input.apiKey.length > 8192)) throw new Error("API Key 无效");
    const key = input.apiKey?.trim();
    if (key && /\s|[\x00-\x1f\x7f]/.test(key)) throw new Error("API Key 无效");
    if (key && hasExternalConfigurationValue(key)) throw new Error("请输入凭据本身，不能使用环境变量或命令");
    const knownProvider = this.catalog.providers.find(item => item.id === provider);
    if (knownProvider && !knownProvider.apiConfiguration) throw new Error("此提供方需要使用原有账户配置方式");

    const originalModels = this.storage.read("models.json", { providers: {} });
    const account = this.accountFor(provider, input);
    const stored = account.credential;
    if (!key && (!stored || stored.type !== "api_key" || typeof stored.key !== "string" || !stored.key.trim()
      || hasExternalConfigurationValue(stored))) throw new Error("请输入 API Key");
    if (!record(originalModels.providers)) throw new Error("models.json 必须包含 providers 对象");
    const previous = account.configuration;
    const definitions = Array.isArray(previous.models) ? previous.models : [];
    const existing = this.models.getModel(provider, modelId);
    const existingDefinition = definitions.find(item => record(item) && item.id === modelId);
    const definition: Record<string, unknown> = { ...(existing ? { name: existing.name, reasoning: existing.reasoning, input: existing.input,
      thinkingLevelMap: existing.thinkingLevelMap, inputLimits: existing.inputLimits, cost: existing.cost,
      promptCache: existing.promptCache, contextWindow: existing.contextWindow, maxTokens: existing.maxTokens,
      samplingParams: existing.samplingParams, ...(existing.api === input.api ? { compat: existing.compat } : {}) } : {}),
      ...(record(existingDefinition) ? existingDefinition : {}), id: modelId, api: input.api, baseUrl };
    const updatedProvider: Record<string, unknown> = { ...previous, baseUrl, api: input.api,
      models: [...definitions.filter(item => !record(item) || item.id !== modelId), definition] };
    const credentialFields = [updatedProvider, definition];
    if (record(previous.modelOverrides) && record(previous.modelOverrides[modelId])) {
      const override = { ...previous.modelOverrides[modelId] };
      updatedProvider.modelOverrides = { ...previous.modelOverrides, [modelId]: override };
      credentialFields.push(override);
    }
    // 已有认证 header 不能继续覆盖界面刚保存的账户密钥。
    for (const fields of credentialFields) {
      delete fields.apiKey;
      if (record(fields.headers)) {
        const headers = Object.fromEntries(Object.entries(fields.headers)
          .filter(([name]) => !["authorization", "x-api-key", "api-key"].includes(name.toLowerCase())));
        if (Object.keys(headers).length) fields.headers = headers;
        else delete fields.headers;
      }
    }
    if (hasExternalConfigurationValue(updatedProvider)) throw new Error("凭据使用环境变量或命令，请在应用内配置账户并移除外部引用");
    const updated = { ...originalModels, providers: { ...originalModels.providers, [provider]: updatedProvider } };
    signal?.throwIfAborted();
    const validation = await this.runtime(updated);
    const validatedModel = validation.getModel(provider, modelId);
    if (validation.getError() || !validatedModel) throw new Error("模型配置无效，请检查接口地址和模型");
    if (input.thinkingLevel !== undefined && !getSupportedThinkingLevels(validatedModel).includes(input.thinkingLevel as ModelThinkingLevel)) {
      throw new Error("此模型不支持所选思考深度");
    }
    await this.change(async () => {
      this.storage.saveAccount({ ...account, configuration: updatedProvider,
        ...(key ? { credential: { type: "api_key", key } } : {}) });
      this.storage.activate(account);
      this.storage.write("models.json", updated);
      await this.load();
      if (this.configurationError) throw new Error(this.message);
      await this.select(provider, modelId, input.thinkingLevel);
    }, signal);
  }

  async login(provider: string, type: AuthType, interaction: AuthInteraction, input: AccountInput = {}): Promise<void> {
    if (!this.models) throw new Error("Pi 模型目录尚未加载");
    if (!this.catalog.providers.find(item => item.id === provider)?.authMethods.some(method => method.type === type)) {
      throw new Error("此提供方不支持所选登录方式");
    }
    const account = this.accountFor(provider, input);
    const sdk = await piStorageModules();
    const models = createModels({ credentials: sdk.AuthStorage.inMemory(), authContext: { env: async () => undefined, fileExists: async () => false } });
    models.setProvider(this.models.getProvider(provider)!);
    const credential = await models.login(provider, type, interaction, { getDeviceId: () => this.deviceId });
    await this.change(async () => {
      this.storage.saveAccount({ ...account, credential });
      await this.selectAccount(account.id, interaction.signal);
    }, interaction.signal);
  }

  private deviceId: string = randomUUID();

  async logout(provider: string, accountId?: string): Promise<void> {
    if (!this.models || !this.models.getProvider(provider)) throw new Error("提供方不在当前 Pi 目录中");
    const account = this.accountFor(provider, { accountId });
    await this.change(async () => {
      this.storage.saveAccount({ ...account, credential: undefined });
      await this.load();
    });
  }

  readAPIKey(accountId: string): string {
    const credential = this.storage.account(accountId)?.credential;
    if (credential?.type !== "api_key" || !credential.key || hasExternalConfigurationValue(credential)) throw new Error("此账户没有可查看的 API Key");
    return credential.key;
  }

  async selectAccount(accountId: string, signal?: AbortSignal): Promise<void> {
    const account = this.storage.account(accountId);
    if (!account) throw new Error("账户不存在，请重新选择账户");
    await this.change(async () => {
      const models = this.storage.read("models.json", { providers: {} });
      const providers = { ...(record(models.providers) ? models.providers : {}) };
      if (Object.keys(account.configuration).length) providers[account.provider] = account.configuration;
      else delete providers[account.provider];
      this.storage.write("models.json", { ...models, providers });
      this.storage.activate(account);
      if (!account.model) {
        this.storage.write("settings.json", { ...this.storage.read("settings.json"), defaultProvider: undefined, defaultModel: undefined });
      }
      await this.load();
      if (this.configurationError) throw new Error(this.message);
      if (account.model) await this.select(account.provider, account.model, account.thinkingLevel);
    }, signal);
  }

  async deleteAccount(accountId: string, signal?: AbortSignal): Promise<void> {
    const account = this.storage.account(accountId);
    if (!account) throw new Error("账户不存在，请重新选择账户");
    await this.change(async () => {
      const active = this.storage.activeAccount(account.provider)?.id === accountId;
      this.storage.deleteAccount(accountId);
      const replacement = this.storage.accounts().find(item => item.provider === account.provider);
      if (active && replacement) await this.selectAccount(replacement.id, signal);
      else await this.load();
    }, signal);
  }

  async refreshCatalog(signal: AbortSignal): Promise<void> {
    if (!this.models) throw new Error("Pi 模型目录尚未加载");
    const providers = this.catalog.providers.filter(item => item.configured && !item.configurationIssue).map(item => item.id);
    const result = await this.models.refresh({ allowNetwork: true, providers, force: true, signal });
    await this.updateCatalog();
    if (result.aborted) throw new Error("模型目录刷新已取消");
    if (result.errors.size) throw new Error("部分提供方的模型目录刷新失败，请稍后重试");
  }

  streamSimple(model: Model<Api>, context: Context, options?: ModelsSimpleStreamOptions) {
    const models = this.models;
    if (!models) throw new Error("Pi 模型目录尚未加载");
    return lazyStream(model, async () => {
      const sdk = await piStorageModules();
      const auth = await models.getAuth(model, { signal: options?.signal });
      const headers = sdk.resolveConfiguredModelHeaders(model, this.providerConfiguration[model.provider], undefined, auth?.env);
      return models.streamSimple(model, context, { ...options, headers: { ...headers, ...options?.headers } });
    });
  }

  async importConfiguration(path: string = resolve(getAgentDir())): Promise<void> {
    if (!isAbsolute(path)) throw new Error("请选择配置文件或目录的绝对路径");
    const source = resolve(path);
    let directory: string, modelsPath: string;
    try {
      const isDirectory = (await stat(source)).isDirectory();
      directory = isDirectory ? source : dirname(source);
      modelsPath = isDirectory ? join(source, "models.json") : source;
      await stat(modelsPath);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") throw new Error("未找到 Pi 模型配置，请先在 Pi 中配置模型");
      throw new Error("Pi 模型配置无法读取，请检查文件权限");
    }
    if (resolve(modelsPath) === join(this.directory, "models.json")) { await this.load(); return; }
    const sdk = await piStorageModules();
    const sourceModels = await sdk.ModelConfig.load(modelsPath);
    if (sourceModels.getError()) throw new Error("导入的 models.json 无效");
    const raw = { providers: Object.fromEntries(sourceModels.getProviderIds().map(id => [id, sourceModels.getProvider(id)])) };
    const importedSettings = await jsonFile(join(directory, "settings.json"));
    const local = this.storage.read("models.json", { providers: {} });
    if (!record(local.providers)) throw new Error("models.json 必须包含 providers 对象");
    const imported = withoutAuthentication(raw) as Record<string, unknown>;
    const importedProviders = imported.providers as Record<string, unknown>;
    const providers = { ...importedProviders, ...local.providers };
    for (const [id, provider] of Object.entries(importedProviders)) {
      const current = local.providers[id];
      if (!record(provider) || !record(current)) continue;
      const merged = { ...provider, ...current };
      if (Array.isArray(provider.models) || Array.isArray(current.models)) {
        const currentModels: unknown[] = Array.isArray(current.models) ? current.models : [];
        const currentIDs = new Set(currentModels.filter(record).map(model => model.id));
        const newModels: unknown[] = Array.isArray(provider.models) ? provider.models : [];
        merged.models = [...currentModels, ...newModels.filter(model => !record(model) || !currentIDs.has(model.id))];
      }
      if (record(provider.modelOverrides) || record(current.modelOverrides)) {
        merged.modelOverrides = { ...(record(provider.modelOverrides) ? provider.modelOverrides : {}),
          ...(record(current.modelOverrides) ? current.modelOverrides : {}) };
      }
      providers[id] = merged;
    }
    const merged = { ...imported, ...local, providers };
    for (const value of [imported, merged]) {
      if ((await this.runtime(value)).getError()) throw new Error("导入的 models.json 无效");
    }
    await this.change(async () => {
      this.saveImportedConfiguration(merged, this.storage.authData(), this.storage.read("settings.json"));
      // 显式导入只包含模型，后续重读不能再触发首次发现并复制源账户。
      this.storage.write("pi-discovery.json", { version: 1 });
      await this.load();
      if (typeof importedSettings.defaultProvider === "string" && typeof importedSettings.defaultModel === "string"
        && this.models?.getModel(importedSettings.defaultProvider, importedSettings.defaultModel)) {
        const level = (record(importedSettings.modelThinkingLevels)
          ? importedSettings.modelThinkingLevels[`${importedSettings.defaultProvider}/${importedSettings.defaultModel}`] : undefined)
          ?? importedSettings.defaultThinkingLevel;
        const importedModel = this.models.getModel(importedSettings.defaultProvider, importedSettings.defaultModel)!;
        const selectedLevel = typeof level === "string" && ["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(level)
          ? clampThinkingLevel(importedModel, level as ModelThinkingLevel) : undefined;
        await this.select(importedSettings.defaultProvider, importedSettings.defaultModel, selectedLevel);
      }
    });
  }
}
