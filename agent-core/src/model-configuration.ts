import { randomUUID } from "node:crypto";
import { chmod, mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, resolve } from "node:path";
import {
  clampThinkingLevel, createModels, getSupportedThinkingLevels, lazyStream,
  type Api, type AuthInteraction, type AuthType, type Context, type CredentialStore,
  type Model, type ModelsSimpleStreamOptions, type ModelsStore, type ModelThinkingLevel, type MutableModels,
  type ProviderHeaders,
} from "@earendil-works/pi-ai";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import { piDirectoryForDataDir } from "./config.ts";

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
}

export interface ModelCatalog {
  models: CatalogModel[];
  providers: CatalogProvider[];
  selected?: { provider: string; model: string; thinkingLevel: ModelThinkingLevel };
  message?: string;
}

interface PiStorageModules {
  AuthStorage: { create(path: string): CredentialStore };
  FileModelsStore: new (path: string) => ModelsStore;
  resolveConfiguredModelHeaders(model: Model<Api>, config: unknown, extension: undefined, env?: Record<string, string>): ProviderHeaders | undefined;
}

let storageModules: Promise<PiStorageModules> | undefined;
function piStorageModules(): Promise<PiStorageModules> {
  // Pi 0.99.2 未从包根导出磁盘存储；保留原生文件锁及 OAuth 刷新写入语义。
  return storageModules ??= (async () => {
    const root = import.meta.resolve("@earendil-works/pi-coding-agent");
    const [auth, models, composer] = await Promise.all([
      import(new URL("./core/auth-storage.js", root).href),
      import(new URL("./core/models-store.js", root).href),
      import(new URL("./core/provider-composer.js", root).href),
    ]);
    return { AuthStorage: auth.AuthStorage, FileModelsStore: models.FileModelsStore,
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
    const value: unknown = JSON.parse(await readFile(path, "utf8"));
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
  private providerConfiguration: Record<string, unknown> = {};
  private catalog: ModelCatalog = { models: [], providers: [] };
  private configurationError?: string;
  private readonly configureModels?: (models: MutableModels) => void;

  constructor(dataDir: string, configureModels?: (models: MutableModels) => void) {
    this.directory = piDirectoryForDataDir(dataDir);
    this.configureModels = configureModels;
  }

  get snapshot(): ModelCatalog { return this.catalog; }

  get selection(): { model: Model<Api>; thinkingLevel: ModelThinkingLevel; configured: boolean } | undefined {
    const selection = this.catalog.selected;
    const model = selection && this.models?.getModel(selection.provider, selection.model);
    if (!model || !selection) return undefined;
    return { model, thinkingLevel: selection.thinkingLevel,
      configured: !this.configurationError && this.catalog.providers.some(provider => provider.id === model.provider && provider.configured) };
  }

  get message(): string {
    if (this.configurationError) return this.configurationError;
    if (!this.catalog.selected) return "请在设置中选择模型并配置账户";
    if (!this.selection) return `所选 Pi 模型不存在：${this.catalog.selected.provider}/${this.catalog.selected.model}`;
    if (!this.selection.configured) return "请在设置中配置此提供方的认证";
    return "模型配置已保存；发送请求后验证可用性";
  }

  async load(): Promise<void> {
    this.models = undefined;
    this.credentials = undefined;
    this.settings = undefined;
    this.configurationError = undefined;
    this.providerConfiguration = {};
    this.catalog = { models: [], providers: [] };
    try {
      await mkdir(this.directory, { recursive: true, mode: 0o700 });
      await chmod(this.directory, 0o700);
      const devicePath = join(this.directory, "device-id.json");
      const device = await jsonFile(devicePath);
      if (typeof device.id === "string" && device.id) this.deviceId = device.id;
      else await writeJSON(devicePath, { id: this.deviceId });
      for (const [name, initial] of [["auth.json", {}], ["settings.json", {}], ["models.json", { providers: {} }]] as const) {
        const path = join(this.directory, name);
        try { await writeFile(path, `${JSON.stringify(initial)}\n`, { flag: "wx", mode: 0o600 }); }
        catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
        await chmod(path, 0o600);
      }
      const sdk = await piStorageModules();
      const credentials = sdk.AuthStorage.create(join(this.directory, "auth.json"));
      const rawModels = await jsonFile(join(this.directory, "models.json"));
      this.providerConfiguration = record(rawModels.providers) ? rawModels.providers : {};
      const runtime = await ModelRuntime.create({ credentials, modelsPath: join(this.directory, "models.json"),
        modelsStorePath: join(this.directory, "models-store.json"), allowModelNetwork: false, refreshOnCreate: false });
      if (runtime.getError()) this.configurationError = "models.json 无法读取，请检查模型配置";
      const models = createModels({ credentials, modelsStore: new sdk.FileModelsStore(join(this.directory, "models-store.json")),
        authContext: { env: async () => undefined, fileExists: async () => false } });
      for (const provider of runtime.getProviders()) models.setProvider(provider);
      this.configureModels?.(models);
      this.credentials = credentials;
      this.models = models;
      this.settings = SettingsManager.create(this.directory, this.directory, { projectTrusted: false });
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

  private async updateCatalog(): Promise<void> {
    if (!this.models || !this.credentials) throw new Error("Pi 模型目录尚未加载");
    const rawAuth = await jsonFile(join(this.directory, "auth.json"));
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
      return { id: provider.id, name: provider.name, configured, authMethods,
        ...(metadata.has(provider.id) ? { credentialType: metadata.get(provider.id)! } : {}),
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
      ...(provider && modelId ? { selected: { provider, model: modelId, thinkingLevel: model ? clampThinkingLevel(model, requested) : "off" } } : {}),
      ...(this.configurationError ? { message: this.configurationError } : {}),
    };
  }

  async select(provider: string, modelId: string, thinkingLevel?: string): Promise<void> {
    if (!this.models || !this.settings || this.configurationError) throw new Error(this.message);
    const model = this.models.getModel(provider, modelId);
    if (!model) throw new Error("模型不在当前 Pi 目录中");
    const levels = getSupportedThinkingLevels(model);
    if (thinkingLevel !== undefined && !levels.includes(thinkingLevel as ModelThinkingLevel)) throw new Error("此模型不支持所选思考深度");
    const level = thinkingLevel as ModelThinkingLevel | undefined
      ?? clampThinkingLevel(model, this.settings.getModelThinkingLevel(provider, modelId) ?? this.settings.getDefaultThinkingLevel() ?? "medium");
    this.settings.setDefaultModelAndProvider(provider, modelId);
    this.settings.setModelThinkingLevel(provider, modelId, level);
    await this.settings.flush();
    if (this.settings.drainErrors().length) throw new Error("模型设置保存失败");
    await chmod(join(this.directory, "settings.json"), 0o600);
    await this.updateCatalog();
  }

  async login(provider: string, type: AuthType, interaction: AuthInteraction): Promise<void> {
    if (!this.models) throw new Error("Pi 模型目录尚未加载");
    if (!this.catalog.providers.find(item => item.id === provider)?.authMethods.some(method => method.type === type)) {
      throw new Error("此提供方不支持所选登录方式");
    }
    await this.models.login(provider, type, interaction, { getDeviceId: () => this.deviceId });
    await chmod(join(this.directory, "auth.json"), 0o600);
    await this.models.refresh({ allowNetwork: false, providers: [provider], signal: interaction.signal });
    await this.updateCatalog();
  }

  private deviceId: string = randomUUID();

  async logout(provider: string): Promise<void> {
    if (!this.models || !this.models.getProvider(provider)) throw new Error("提供方不在当前 Pi 目录中");
    await this.models.logout(provider, { signal: AbortSignal.timeout(5_000) });
    await this.updateCatalog();
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

  async importConfiguration(path: string): Promise<void> {
    if (!isAbsolute(path)) throw new Error("请选择配置文件或目录的绝对路径");
    const source = resolve(path);
    const directory = (await stat(source)).isDirectory() ? source : dirname(source);
    const modelsPath = (await stat(source)).isDirectory() ? join(source, "models.json") : source;
    if (resolve(modelsPath) === join(this.directory, "models.json")) { await this.load(); return; }
    const raw = await jsonFile(modelsPath);
    if (!record(raw.providers)) throw new Error("models.json 必须包含 providers 对象");
    const validation = await ModelRuntime.create({ modelsPath, authPath: join(this.directory, "auth.json"),
      modelsStorePath: join(this.directory, "models-store.json"), allowModelNetwork: false, refreshOnCreate: false });
    if (validation.getError()) throw new Error("导入的 models.json 无效");
    const importedSettings = await jsonFile(join(directory, "settings.json"));
    await writeJSON(join(this.directory, "models.json"), withoutAuthentication(raw));
    await this.load();
    if (typeof importedSettings.defaultProvider === "string" && typeof importedSettings.defaultModel === "string"
      && this.models?.getModel(importedSettings.defaultProvider, importedSettings.defaultModel)) {
      const level = record(importedSettings.modelThinkingLevels)
        ? importedSettings.modelThinkingLevels[`${importedSettings.defaultProvider}/${importedSettings.defaultModel}`] : importedSettings.defaultThinkingLevel;
      const importedModel = this.models.getModel(importedSettings.defaultProvider, importedSettings.defaultModel)!;
      const selectedLevel = typeof level === "string" && ["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(level)
        ? clampThinkingLevel(importedModel, level as ModelThinkingLevel) : undefined;
      await this.select(importedSettings.defaultProvider, importedSettings.defaultModel, selectedLevel);
    }
  }
}
