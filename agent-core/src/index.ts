import type { AgentConfig } from "./config.ts";
import { EventBus, type AgentEvent } from "./events.ts";
import { UnconfiguredPiBackend, type PiAgentBackend } from "./pi-adapter.ts";
import { ProactiveScheduler, type SchedulerSignal, type TriggerRule } from "./scheduler.ts";

export * from "./config.ts";
export * from "./events.ts";
export * from "./pi-adapter.ts";
export * from "./scheduler.ts";

export interface AgentCoreOptions {
  config: AgentConfig;
  rules?: TriggerRule[];
  backend?: PiAgentBackend;
  now?: () => Date;
}

export class AgentCore {
  readonly events: EventBus;
  readonly scheduler: ProactiveScheduler;
  readonly backend: PiAgentBackend;
  readonly config: AgentConfig;

  constructor(options: AgentCoreOptions) {
    this.config = options.config;
    this.events = new EventBus();
    this.scheduler = new ProactiveScheduler(options.rules ?? [], this.events, {
      defaults: options.config.scheduler,
      now: options.now,
    });
    this.backend = options.backend ?? new UnconfiguredPiBackend({
      repository: "https://github.com/earendil-works/pi.git",
      ref: "main",
      commit: "8ce69e9d2b171d173fe4b6b2b6256f1f4411e69d",
    });
  }

  signal(signal: SchedulerSignal, now?: Date): AgentEvent[] {
    if (!this.config.scheduler.enabled) return [];
    return this.scheduler.ingest(signal, now);
  }

  tick(now?: Date, idleForMs?: number): AgentEvent[] {
    if (!this.config.scheduler.enabled) return [];
    return this.scheduler.tick(now, idleForMs);
  }

  start(getIdleForMs?: () => number | undefined): () => void {
    if (!this.config.scheduler.enabled) return () => undefined;
    return this.scheduler.start(getIdleForMs);
  }

  stop(): void {
    this.scheduler.stop();
  }
}
