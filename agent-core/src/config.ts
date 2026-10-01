import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir, platform } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";

export const CONFIG_VERSION = 1;

export type PrivacyMode = "strict-local" | "local-first" | "custom";
export type ModelProvider = "local" | "openai-compatible" | "anthropic";
export type ToolName = "filesystem" | "shell" | "network" | "calendar" | "notifications";

export interface ModelConfig {
  provider: ModelProvider;
  model: string;
  endpoint?: string;
  apiKeyEnv?: string;
  temperature: number;
}

export interface ToolConfig {
  filesystem: boolean;
  shell: boolean;
  network: boolean;
  calendar: boolean;
  notifications: boolean;
}

export interface PrivacyPolicy {
  mode: PrivacyMode;
  allowNetwork: boolean;
  allowedNetworkHosts: string[];
  storePrompts: boolean;
  storeResponses: boolean;
  redactSecrets: boolean;
}

export interface SchedulerConfig {
  enabled: boolean;
  pollIntervalMs: number;
  defaultCooldownMs: number;
  defaultDedupeWindowMs: number;
}

export interface AgentConfig {
  version: typeof CONFIG_VERSION;
  dataDir: string;
  model: ModelConfig;
  tools: ToolConfig;
  privacy: PrivacyPolicy;
  scheduler: SchedulerConfig;
}

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

const DEFAULT_MODEL: ModelConfig = {
  provider: "local",
  model: "local-default",
  temperature: 0.2,
};

const DEFAULT_TOOLS: ToolConfig = {
  filesystem: true,
  shell: false,
  network: false,
  calendar: false,
  notifications: true,
};

const DEFAULT_PRIVACY: PrivacyPolicy = {
  mode: "strict-local",
  allowNetwork: false,
  allowedNetworkHosts: [],
  storePrompts: true,
  storeResponses: true,
  redactSecrets: true,
};

const DEFAULT_SCHEDULER: SchedulerConfig = {
  enabled: true,
  pollIntervalMs: 30_000,
  defaultCooldownMs: 30 * 60_000,
  defaultDedupeWindowMs: 5 * 60_000,
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown, field: string, fallback?: string): string {
  if (value === undefined && fallback !== undefined) return fallback;
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new ConfigError(`${field} 必须是非空字符串`);
  }
  return value.trim();
}

function booleanValue(value: unknown, field: string, fallback: boolean): boolean {
  if (value === undefined) return fallback;
  if (typeof value !== "boolean") throw new ConfigError(`${field} 必须是布尔值`);
  return value;
}

function durationValue(value: unknown, field: string, fallback: number): number {
  if (value === undefined) return fallback;
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    throw new ConfigError(`${field} 必须是大于等于 0 的有限数字`);
  }
  return Math.floor(value);
}

function expandPath(value: string): string {
  const expanded = value === "~" || value.startsWith("~/") ? join(homedir(), value.slice(2)) : value;
  return resolve(expanded);
}

export function defaultDataDir(systemPlatform = platform(), home = homedir()): string {
  if (systemPlatform === "darwin") return join(home, "Library", "Application Support", "AnotherYou");
  if (systemPlatform === "win32") return join(process.env.APPDATA ?? join(home, "AppData", "Roaming"), "AnotherYou");
  return join(process.env.XDG_DATA_HOME ?? join(home, ".local", "share"), "another-you");
}

export function configPathForDataDir(dataDir = defaultDataDir()): string {
  return join(expandPath(dataDir), "config.json");
}

export function createDefaultConfig(dataDir = defaultDataDir()): AgentConfig {
  return {
    version: CONFIG_VERSION,
    dataDir: expandPath(dataDir),
    model: { ...DEFAULT_MODEL },
    tools: { ...DEFAULT_TOOLS },
    privacy: { ...DEFAULT_PRIVACY, allowedNetworkHosts: [] },
    scheduler: { ...DEFAULT_SCHEDULER },
  };
}

function parseModel(value: unknown): ModelConfig {
  if (value === undefined) return { ...DEFAULT_MODEL };
  if (!isRecord(value)) throw new ConfigError("model 必须是对象");
  if ("apiKey" in value || "api_key" in value) {
    throw new ConfigError("禁止把 API 密钥写入配置，请使用 apiKeyEnv 指向环境变量");
  }
  const provider = value.provider ?? DEFAULT_MODEL.provider;
  if (provider !== "local" && provider !== "openai-compatible" && provider !== "anthropic") {
    throw new ConfigError("model.provider 不受支持");
  }
  const temperature = value.temperature ?? DEFAULT_MODEL.temperature;
  if (typeof temperature !== "number" || !Number.isFinite(temperature) || temperature < 0 || temperature > 2) {
    throw new ConfigError("model.temperature 必须位于 0 到 2 之间");
  }
  const endpoint = value.endpoint === undefined ? undefined : stringValue(value.endpoint, "model.endpoint");
  const apiKeyEnv = value.apiKeyEnv === undefined ? undefined : stringValue(value.apiKeyEnv, "model.apiKeyEnv");
  return {
    provider,
    model: stringValue(value.model, "model.model", DEFAULT_MODEL.model),
    ...(endpoint ? { endpoint } : {}),
    ...(apiKeyEnv ? { apiKeyEnv } : {}),
    temperature,
  };
}

function parseTools(value: unknown): ToolConfig {
  if (value === undefined) return { ...DEFAULT_TOOLS };
  if (!isRecord(value)) throw new ConfigError("tools 必须是对象");
  return {
    filesystem: booleanValue(value.filesystem, "tools.filesystem", DEFAULT_TOOLS.filesystem),
    shell: booleanValue(value.shell, "tools.shell", DEFAULT_TOOLS.shell),
    network: booleanValue(value.network, "tools.network", DEFAULT_TOOLS.network),
    calendar: booleanValue(value.calendar, "tools.calendar", DEFAULT_TOOLS.calendar),
    notifications: booleanValue(value.notifications, "tools.notifications", DEFAULT_TOOLS.notifications),
  };
}

function parsePrivacy(value: unknown): PrivacyPolicy {
  if (value === undefined) return { ...DEFAULT_PRIVACY, allowedNetworkHosts: [] };
  if (!isRecord(value)) throw new ConfigError("privacy 必须是对象");
  const mode = value.mode ?? DEFAULT_PRIVACY.mode;
  if (mode !== "strict-local" && mode !== "local-first" && mode !== "custom") {
    throw new ConfigError("privacy.mode 不受支持");
  }
  const hosts = value.allowedNetworkHosts ?? DEFAULT_PRIVACY.allowedNetworkHosts;
  if (!Array.isArray(hosts) || hosts.some((host) => typeof host !== "string" || host.trim().length === 0)) {
    throw new ConfigError("privacy.allowedNetworkHosts 必须是字符串数组");
  }
  return {
    mode,
    allowNetwork: booleanValue(value.allowNetwork, "privacy.allowNetwork", DEFAULT_PRIVACY.allowNetwork),
    allowedNetworkHosts: [...new Set(hosts.map((host) => host.trim().toLowerCase()))],
    storePrompts: booleanValue(value.storePrompts, "privacy.storePrompts", DEFAULT_PRIVACY.storePrompts),
    storeResponses: booleanValue(value.storeResponses, "privacy.storeResponses", DEFAULT_PRIVACY.storeResponses),
    redactSecrets: booleanValue(value.redactSecrets, "privacy.redactSecrets", DEFAULT_PRIVACY.redactSecrets),
  };
}

function parseScheduler(value: unknown): SchedulerConfig {
  if (value === undefined) return { ...DEFAULT_SCHEDULER };
  if (!isRecord(value)) throw new ConfigError("scheduler 必须是对象");
  const pollIntervalMs = durationValue(value.pollIntervalMs, "scheduler.pollIntervalMs", DEFAULT_SCHEDULER.pollIntervalMs);
  if (pollIntervalMs < 100) throw new ConfigError("scheduler.pollIntervalMs 不能小于 100 毫秒");
  return {
    enabled: booleanValue(value.enabled, "scheduler.enabled", DEFAULT_SCHEDULER.enabled),
    pollIntervalMs,
    defaultCooldownMs: durationValue(value.defaultCooldownMs, "scheduler.defaultCooldownMs", DEFAULT_SCHEDULER.defaultCooldownMs),
    defaultDedupeWindowMs: durationValue(value.defaultDedupeWindowMs, "scheduler.defaultDedupeWindowMs", DEFAULT_SCHEDULER.defaultDedupeWindowMs),
  };
}

export function parseAgentConfig(value: unknown, dataDirOverride?: string): AgentConfig {
  if (!isRecord(value)) throw new ConfigError("配置根节点必须是对象");
  if (value.version !== undefined && value.version !== CONFIG_VERSION) {
    throw new ConfigError(`不支持的配置版本：${String(value.version)}`);
  }
  const dataDir = dataDirOverride ?? stringValue(value.dataDir, "dataDir", defaultDataDir());
  const config = {
    version: CONFIG_VERSION,
    dataDir: expandPath(dataDir),
    model: parseModel(value.model),
    tools: parseTools(value.tools),
    privacy: parsePrivacy(value.privacy),
    scheduler: parseScheduler(value.scheduler),
  } satisfies AgentConfig;
  if (config.privacy.mode === "strict-local") {
    config.privacy.allowNetwork = false;
  }
  return config;
}

export function isToolAllowed(config: AgentConfig, tool: ToolName): boolean {
  if (!config.tools[tool]) return false;
  if (tool === "network") {
    return config.privacy.mode !== "strict-local" && config.privacy.allowNetwork;
  }
  return true;
}

export async function loadConfig(configPath = configPathForDataDir()): Promise<AgentConfig> {
  try {
    const raw = await readFile(configPath, "utf8");
    return parseAgentConfig(JSON.parse(raw));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return createDefaultConfig(dirname(configPath));
    if (error instanceof ConfigError || error instanceof SyntaxError) throw error;
    throw new ConfigError(`读取配置失败：${String(error)}`);
  }
}

export async function saveConfig(config: AgentConfig, configPath = configPathForDataDir(config.dataDir)): Promise<void> {
  const normalized = parseAgentConfig(config);
  await mkdir(dirname(configPath), { recursive: true });
  const tempPath = `${configPath}.${process.pid}.tmp`;
  await writeFile(tempPath, `${JSON.stringify(normalized, null, 2)}\n`, { mode: 0o600 });
  await rename(tempPath, configPath);
}
