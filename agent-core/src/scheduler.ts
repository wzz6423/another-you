import type { SchedulerConfig } from "./config.ts";
import { EventBus, type AgentEvent } from "./events.ts";

export type SchedulerSignal =
  | { type: "time"; at?: Date | string; dedupeKey?: string }
  | { type: "event"; name: string; payload?: Record<string, unknown>; at?: Date | string; dedupeKey?: string }
  | { type: "idle"; idleForMs: number; at?: Date | string; dedupeKey?: string };

interface TriggerRuleBase {
  id: string;
  enabled?: boolean;
  title: string;
  message: string;
  context?: Record<string, unknown>;
  cooldownMs?: number;
  dedupeWindowMs?: number;
}

export type TriggerRule =
  | (TriggerRuleBase & { type: "time"; at: string; daysOfWeek?: number[] })
  | (TriggerRuleBase & { type: "event"; eventName: string })
  | (TriggerRuleBase & { type: "idle"; minIdleMs: number });

export interface SchedulerOptions {
  defaults?: Pick<SchedulerConfig, "defaultCooldownMs" | "defaultDedupeWindowMs" | "pollIntervalMs">;
  now?: () => Date;
}

export interface ProactiveSuggestionPayload {
  ruleId: string;
  title: string;
  message: string;
  trigger: SchedulerSignal["type"];
  context: Record<string, unknown>;
  signal: Record<string, unknown>;
}

const DEFAULTS: Required<SchedulerOptions["defaults"]> = {
  defaultCooldownMs: 30 * 60_000,
  defaultDedupeWindowMs: 5 * 60_000,
  pollIntervalMs: 30_000,
};

function parseDate(value: Date | string | undefined, fallback: Date): Date {
  if (value === undefined) return fallback;
  const date = value instanceof Date ? new Date(value.getTime()) : new Date(value);
  if (Number.isNaN(date.getTime())) throw new TypeError("信号时间必须是有效日期");
  return date;
}

function stableJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  const record = value as Record<string, unknown>;
  return `{${Object.keys(record).sort().map((key) => `${JSON.stringify(key)}:${stableJson(record[key])}`).join(",")}}`;
}

function normalizeTime(value: string): string {
  if (!/^\d{2}:\d{2}$/.test(value)) throw new TypeError("时间规则必须使用 HH:mm 格式");
  const [hour, minute] = value.split(":").map(Number);
  if (hour > 23 || minute > 59) throw new TypeError("时间规则超出范围");
  return value;
}

function validateRule(rule: TriggerRule): void {
  if (!rule.id || !rule.title || !rule.message) throw new TypeError("触发规则必须包含 id、title 和 message");
  if (rule.cooldownMs !== undefined && (!Number.isFinite(rule.cooldownMs) || rule.cooldownMs < 0)) {
    throw new TypeError("规则 cooldownMs 必须是大于等于 0 的有限数字");
  }
  if (rule.dedupeWindowMs !== undefined && (!Number.isFinite(rule.dedupeWindowMs) || rule.dedupeWindowMs < 0)) {
    throw new TypeError("规则 dedupeWindowMs 必须是大于等于 0 的有限数字");
  }
  if (rule.type === "time") {
    normalizeTime(rule.at);
    if (rule.daysOfWeek?.some((day) => !Number.isInteger(day) || day < 0 || day > 6)) {
      throw new TypeError("daysOfWeek 必须是 0 到 6 的整数数组");
    }
  }
  if (rule.type === "event" && !rule.eventName) throw new TypeError("事件规则必须包含 eventName");
  if (rule.type === "idle" && (!Number.isFinite(rule.minIdleMs) || rule.minIdleMs < 0)) {
    throw new TypeError("闲置规则 minIdleMs 必须是大于等于 0 的有限数字");
  }
}

function serializedSignal(signal: SchedulerSignal, at: Date): Record<string, unknown> {
  if (signal.type === "event") {
    return { type: signal.type, name: signal.name, payload: signal.payload ?? {}, at: at.toISOString() };
  }
  if (signal.type === "idle") {
    return { type: signal.type, idleForMs: signal.idleForMs, at: at.toISOString() };
  }
  return { type: signal.type, at: at.toISOString() };
}

export class ProactiveScheduler {
  readonly events: EventBus;
  private readonly clock: () => Date;
  private readonly defaults: Required<SchedulerOptions["defaults"]>;
  private readonly rules = new Map<string, TriggerRule>();
  private readonly lastFiredAt = new Map<string, number>();
  private readonly lastDedupeAt = new Map<string, number>();
  private timer: ReturnType<typeof setInterval> | undefined;

  constructor(rules: TriggerRule[] = [], events = new EventBus(), options: SchedulerOptions = {}) {
    this.events = events;
    this.clock = options.now ?? (() => new Date());
    this.defaults = { ...DEFAULTS, ...(options.defaults ?? {}) };
    for (const rule of rules) this.addRule(rule);
  }

  addRule(rule: TriggerRule): void {
    validateRule(rule);
    this.rules.set(rule.id, { ...rule, enabled: rule.enabled ?? true });
  }

  removeRule(ruleId: string): boolean {
    this.lastFiredAt.delete(ruleId);
    return this.rules.delete(ruleId);
  }

  listRules(): TriggerRule[] {
    return [...this.rules.values()].map((rule) => ({ ...rule }));
  }

  ingest(signal: SchedulerSignal, now = this.clock()): AgentEvent<ProactiveSuggestionPayload>[] {
    const receivedAt = parseDate(signal.at, now);
    const events: AgentEvent<ProactiveSuggestionPayload>[] = [];
    for (const rule of this.rules.values()) {
      if (!rule.enabled || !this.matches(rule, signal, receivedAt)) continue;
      const event = this.fire(rule, signal, receivedAt);
      if (event) events.push(event);
    }
    return events;
  }

  tick(now = this.clock(), idleForMs?: number): AgentEvent<ProactiveSuggestionPayload>[] {
    const signals: SchedulerSignal[] = [{ type: "time", at: now }];
    if (idleForMs !== undefined) signals.push({ type: "idle", idleForMs, at: now });
    return signals.flatMap((signal) => this.ingest(signal, now));
  }

  start(getIdleForMs?: () => number | undefined): () => void {
    if (this.timer) return () => this.stop();
    this.timer = setInterval(() => {
      try {
        this.tick(this.clock(), getIdleForMs?.());
      } catch (error) {
        this.events.emit({
          kind: "agent.error",
          source: "scheduler",
          payload: { message: error instanceof Error ? error.message : String(error) },
        });
      }
    }, this.defaults.pollIntervalMs);
    this.events.emit({ kind: "scheduler.status", source: "scheduler", payload: { running: true } });
    return () => this.stop();
  }

  stop(): void {
    if (!this.timer) return;
    clearInterval(this.timer);
    this.timer = undefined;
    this.events.emit({ kind: "scheduler.status", source: "scheduler", payload: { running: false } });
  }

  private matches(rule: TriggerRule, signal: SchedulerSignal, at: Date): boolean {
    if (rule.type !== signal.type) return false;
    if (rule.type === "time" && signal.type === "time") {
      const time = `${String(at.getHours()).padStart(2, "0")}:${String(at.getMinutes()).padStart(2, "0")}`;
      return time === rule.at && (rule.daysOfWeek === undefined || rule.daysOfWeek.includes(at.getDay()));
    }
    if (rule.type === "event" && signal.type === "event") return rule.eventName === signal.name;
    if (rule.type === "idle" && signal.type === "idle") return signal.idleForMs >= rule.minIdleMs;
    return false;
  }

  private fire(rule: TriggerRule, signal: SchedulerSignal, at: Date): AgentEvent<ProactiveSuggestionPayload> | undefined {
    const timestamp = at.getTime();
    const lastFire = this.lastFiredAt.get(rule.id);
    const cooldownMs = rule.cooldownMs ?? this.defaults.defaultCooldownMs;
    if (lastFire !== undefined && timestamp - lastFire < cooldownMs) return undefined;

    const dedupeKey = signal.dedupeKey ?? this.defaultDedupeKey(rule, signal, at);
    const lastDedupe = this.lastDedupeAt.get(dedupeKey);
    const dedupeWindowMs = rule.dedupeWindowMs ?? this.defaults.defaultDedupeWindowMs;
    if (lastDedupe !== undefined && timestamp - lastDedupe < dedupeWindowMs) return undefined;

    this.lastFiredAt.set(rule.id, timestamp);
    this.lastDedupeAt.set(dedupeKey, timestamp);
    return this.events.emit<ProactiveSuggestionPayload>({
      kind: "proactive.suggestion",
      source: "scheduler",
      dedupeKey,
      occurredAt: at,
      payload: {
        ruleId: rule.id,
        title: rule.title,
        message: rule.message,
        trigger: signal.type,
        context: rule.context ?? {},
        signal: serializedSignal(signal, at),
      },
    });
  }

  private defaultDedupeKey(rule: TriggerRule, signal: SchedulerSignal, at: Date): string {
    if (signal.type === "time") return `${rule.id}:time:${at.toISOString().slice(0, 16)}`;
    if (signal.type === "event") return `${rule.id}:event:${signal.name}:${stableJson(signal.payload ?? {})}`;
    return `${rule.id}:idle`;
  }
}
