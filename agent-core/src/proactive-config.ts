import { ConfigError } from "./config.ts";

export interface ProactiveConfig {
  enabled: boolean;
  workIntervalMs: number;
  notificationsIntervalMs: number;
  synthesisIntervalMs: number;
  suggestionCooldownMs: number;
  taskSpacingMs: number;
  collectionTimeoutMs: number;
  taskTimeoutMs: number;
}

export const DEFAULT_PROACTIVE: ProactiveConfig = {
  enabled: true,
  workIntervalMs: 5 * 60_000,
  notificationsIntervalMs: 3 * 60_000,
  synthesisIntervalMs: 10 * 60_000,
  suggestionCooldownMs: 15 * 60_000,
  taskSpacingMs: 30_000,
  collectionTimeoutMs: 15_000,
  taskTimeoutMs: 90_000,
};

export function parseProactiveConfig(value: unknown): ProactiveConfig {
  if (value === undefined) return { ...DEFAULT_PROACTIVE };
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ConfigError("proactive 必须是对象");
  const raw = value as Record<string, unknown>;
  const config = { ...DEFAULT_PROACTIVE };
  if (raw.enabled !== undefined) {
    if (typeof raw.enabled !== "boolean") throw new ConfigError("proactive.enabled 必须是布尔值");
    config.enabled = raw.enabled;
  }
  for (const key of Object.keys(DEFAULT_PROACTIVE) as (keyof ProactiveConfig)[]) {
    if (key === "enabled" || raw[key] === undefined) continue;
    const duration = raw[key];
    const minimum = key === "collectionTimeoutMs" || key === "taskTimeoutMs" || key === "taskSpacingMs" ? 1000 : 60_000;
    const maximum = key === "collectionTimeoutMs" ? 60_000 : key === "taskTimeoutMs" ? 120_000 : 24 * 60 * 60_000;
    if (typeof duration !== "number" || !Number.isSafeInteger(duration) || duration < minimum || duration > maximum) {
      throw new ConfigError(`proactive.${key} 必须是 ${minimum} 到 ${maximum} 之间的整数毫秒数`);
    }
    config[key] = duration;
  }
  if (config.taskTimeoutMs <= config.collectionTimeoutMs) throw new ConfigError("proactive.taskTimeoutMs 必须大于 collectionTimeoutMs");
  return config;
}
