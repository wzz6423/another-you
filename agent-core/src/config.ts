import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir, platform } from "node:os";
import { dirname, join, resolve } from "node:path";
import { parseProactiveConfig, type ProactiveConfig } from "./proactive-config.ts";

export const CONFIG_VERSION = 1;

export type PrivacyMode = "strict-local" | "local-first" | "custom";
export type ToolName = "filesystem" | "shell" | "network" | "calendar" | "notifications";

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
  permissionMode: "full-access";
  version: typeof CONFIG_VERSION;
  dataDir: string;
  tools: ToolConfig;
  privacy: PrivacyPolicy;
  scheduler: SchedulerConfig;
  proactive: ProactiveConfig;
}

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

const DEFAULT_TOOLS: ToolConfig = {
  filesystem: true,
  shell: true,
  network: true,
  calendar: false,
  notifications: true,
};

const DEFAULT_PRIVACY: PrivacyPolicy = {
  mode: "local-first",
  allowNetwork: true,
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

export function piDirectoryForDataDir(dataDir: string): string {
  return join(expandPath(dataDir), "pi");
}

export function createDefaultConfig(dataDir = defaultDataDir()): AgentConfig {
  return {
    permissionMode: "full-access",
    version: CONFIG_VERSION,
    dataDir: expandPath(dataDir),
    tools: { ...DEFAULT_TOOLS },
    privacy: { ...DEFAULT_PRIVACY, allowedNetworkHosts: [] },
    scheduler: { ...DEFAULT_SCHEDULER },
    proactive: parseProactiveConfig(undefined),
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
    permissionMode: "full-access",
    version: CONFIG_VERSION,
    dataDir: expandPath(dataDir),
    tools: parseTools(value.tools),
    privacy: parsePrivacy(value.privacy),
    scheduler: parseScheduler(value.scheduler),
    proactive: parseProactiveConfig(value.proactive),
  } satisfies AgentConfig;
  config.tools.filesystem = true;
  config.tools.shell = true;
  config.tools.network = true;
  config.privacy.mode = "local-first";
  config.privacy.allowNetwork = true;
  config.privacy.allowedNetworkHosts = [];
  return config;
}

export function isToolAllowed(config: AgentConfig, tool: ToolName): boolean {
  if (tool === "filesystem" || tool === "shell" || tool === "network") return true;
  return config.tools[tool];
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
