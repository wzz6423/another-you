import type { AgentConfig } from "./config.ts";
import { EventBus, type AgentEvent } from "./events.ts";
import { PiSdkBackend, type PiAgentBackend } from "./pi-adapter.ts";
import { ProactiveScheduler, type SchedulerSignal, type TriggerRule } from "./scheduler.ts";
import { StateStore, type Proposal, type ProposalDecision } from "./state.ts";

export * from "./config.ts";
export * from "./events.ts";
export * from "./pi-adapter.ts";
export * from "./scheduler.ts";
export * from "./state.ts";

export const DEFAULT_RULES: TriggerRule[] = [
  { id: "welcome", type: "event", eventName: "app-launched", title: "给今天留一个起点", message: "可以一起梳理今天的优先事项。当前未连接日历或任务来源，你可以先告诉我最想推进的一件事。", cooldownMs: 24 * 60 * 60_000 },
  { id: "morning", type: "time", at: "09:00", title: "早间整理", message: "现在是早上九点。要不要生成一个今日计划的空白草稿，再由你补充真实安排？", cooldownMs: 20 * 60 * 60_000 },
  { id: "idle", type: "idle", minIdleMs: 15 * 60_000, title: "留一个继续的入口", message: "设备已闲置一段时间。可以生成一个简短的恢复工作清单；我还不知道你刚才在做什么。", cooldownMs: 2 * 60 * 60_000 },
];

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
  private readonly clock: () => Date;
  private readonly store: StateStore;
  private readonly proposals = new Map<string, Proposal>();
  private history: AgentEvent[] = [];
  private paused = false;
  private timer: ReturnType<typeof setInterval> | undefined;
  private started = false;

  constructor(options: AgentCoreOptions) {
    this.config = options.config;
    this.clock = options.now ?? (() => new Date());
    this.store = new StateStore(this.config.dataDir, this.config.privacy);
    const saved = this.store.load();
    this.paused = saved?.paused ?? false;
    this.history = saved?.history ?? [];
    for (const proposal of saved?.proposals ?? []) this.proposals.set(proposal.id, proposal);
    this.events = new EventBus();
    this.scheduler = new ProactiveScheduler(options.rules ?? saved?.rules ?? DEFAULT_RULES, this.events, {
      defaults: options.config.scheduler,
      now: this.clock,
      shouldFire: (ruleId) => ![...this.proposals.values()].some((proposal) => proposal.ruleId === ruleId && ["pending", "running", "snoozed", "failed"].includes(proposal.state)),
    });
    if (saved) this.scheduler.restore(saved.scheduler);
    this.backend = options.backend ?? new PiSdkBackend(options.config);
    this.events.subscribe((event) => this.record(event));
  }

  signal(signal: SchedulerSignal, now?: Date): AgentEvent[] {
    if (!this.config.scheduler.enabled || this.paused) return [];
    if (!signal || !["event", "time", "idle"].includes(signal.type)) throw new Error("无效的调度信号");
    if (signal.type === "idle" && (!Number.isFinite(signal.idleForMs) || signal.idleForMs < 0)) throw new Error("idleForMs 必须是非负数字");
    return this.scheduler.ingest(signal, now);
  }

  tick(now = this.clock(), idleForMs?: number): AgentEvent[] {
    if (!Number.isFinite(now.getTime())) throw new Error("无效的 tick 时间");
    if (!this.config.scheduler.enabled || this.paused) return [];
    if (idleForMs !== undefined && (!Number.isFinite(idleForMs) || idleForMs < 0)) throw new Error("idleForMs 必须是非负数字");
    const restored: AgentEvent[] = [];
    for (const proposal of this.proposals.values()) {
      if (proposal.state !== "snoozed" || !proposal.snoozedUntil || Date.parse(proposal.snoozedUntil) > now.getTime()) continue;
      proposal.state = "pending";
      delete proposal.snoozedUntil;
      restored.push(this.events.emit({
        kind: "proactive.suggestion", source: "scheduler", occurredAt: now,
        payload: { suggestionId: proposal.id, ruleId: proposal.ruleId, title: proposal.title, message: proposal.summary, summary: proposal.summary, reason: proposal.reason, createdAt: proposal.createdAt, trigger: "snooze", state: "pending", context: proposal.context, signal: {} },
      }));
    }
    return [...restored, ...this.scheduler.tick(now, idleForMs)];
  }

  start(getIdleForMs?: () => number | undefined): () => void {
    if (this.started) return () => this.stop();
    this.started = true;
    if (this.config.scheduler.enabled) {
      this.timer = setInterval(() => {
        try { this.tick(this.clock(), getIdleForMs?.()); }
        catch (error) { this.events.emit({ kind: "agent.error", source: "scheduler", payload: { message: error instanceof Error ? error.message : String(error) } }); }
      }, this.config.scheduler.pollIntervalMs);
      this.events.emit({ kind: "scheduler.status", source: "scheduler", payload: { running: !this.paused, paused: this.paused } });
      this.tick();
      this.signal({ type: "event", name: "app-launched" });
    }
    return () => this.stop();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    this.started = false;
    this.scheduler.stop();
    this.backend.abort?.();
  }

  setPaused(paused: boolean): void {
    this.paused = paused;
    this.persist();
    this.events.emit({ kind: "scheduler.status", source: "scheduler", payload: { running: this.started && this.config.scheduler.enabled && !paused, paused } });
    if (!paused) this.tick();
  }

  addRule(rule: TriggerRule): void { this.scheduler.addRule(rule); this.persist(); }
  removeRule(ruleId: string): void { this.scheduler.removeRule(ruleId); this.persist(); }

  status(): Record<string, unknown> {
    return {
      paused: this.paused,
      schedulerEnabled: this.config.scheduler.enabled,
      model: this.backend.status?.() ?? { configured: true, available: null, model: this.config.model.model, endpoint: this.config.model.endpoint ?? "", message: "自定义模型后端" },
      rules: this.scheduler.listRules(),
      proposals: [...this.proposals.values()].map((proposal) => ({ ...proposal })),
      history: structuredClone(this.history),
    };
  }

  async prompt(requestId: string, prompt: string): Promise<void> {
    if (typeof requestId !== "string" || !requestId.trim() || requestId.length > 256) throw new Error("requestId 必须是非空字符串且不超过 256 字符");
    if (typeof prompt !== "string" || !prompt.trim() || prompt.length > 50_000) throw new Error("prompt 必须为非空文本且不超过 50000 字符");
    if (this.history.some((event) => event.kind === "agent.response" && event.payload.requestId === requestId)) throw new Error("此请求已完成，请使用新的 requestId");
    this.events.emit({ kind: "agent.request", source: "agent", payload: { requestId, prompt } });
    try {
      const response = await this.backend.run({ prompt });
      this.events.emit({ kind: "agent.response", source: "agent", payload: { requestId, text: response.text, model: response.model } });
    } catch (error) {
      this.events.emit({ kind: "agent.error", source: "agent", payload: { requestId, message: error instanceof Error ? error.message : String(error) } });
    }
  }

  async decide(suggestionId: string, decision: ProposalDecision, snoozeMinutes = 15): Promise<void> {
    if (!["execute", "later", "ignore"].includes(decision)) throw new Error("decision 必须是 execute、later 或 ignore");
    const proposal = this.proposals.get(suggestionId);
    if (!proposal) throw new Error("找不到这条主动建议");
    if (["completed", "ignored", "running"].includes(proposal.state)) throw new Error("这条建议已处理或正在执行，不能重复处理");
    if (decision === "later") {
      if (!Number.isFinite(snoozeMinutes) || snoozeMinutes < 1 || snoozeMinutes > 1440) throw new Error("snoozeMinutes 必须位于 1 到 1440 之间");
      proposal.state = "snoozed";
      proposal.snoozedUntil = new Date(this.clock().getTime() + snoozeMinutes * 60_000).toISOString();
      this.update(proposal, decision);
      return;
    }
    delete proposal.snoozedUntil;
    if (decision === "ignore") {
      proposal.state = "ignored";
      this.update(proposal, decision);
      return;
    }
    proposal.state = "running";
    delete proposal.text;
    this.update(proposal, decision);
    try {
      const response = await this.backend.run({ prompt: `用户批准了以下建议，请生成一份可审阅的草稿。只使用已给出的信息。\n建议：${proposal.title}\n说明：${proposal.summary}`, context: proposal.context });
      proposal.state = "completed";
      proposal.text = response.text;
      this.update(proposal, decision);
    } catch (error) {
      proposal.state = "failed";
      proposal.text = error instanceof Error ? error.message : String(error);
      this.update(proposal, decision);
      this.events.emit({ kind: "agent.error", source: "agent", payload: { suggestionId, message: proposal.text } });
    }
  }

  private update(proposal: Proposal, decision: ProposalDecision): void {
    this.events.emit({ kind: "proposal.updated", source: "agent", payload: { suggestionId: proposal.id, decision, state: proposal.state, ...(proposal.text ? { text: proposal.text } : {}), ...(proposal.snoozedUntil ? { snoozedUntil: proposal.snoozedUntil } : {}) } });
  }

  private record(event: AgentEvent): void {
    if (event.kind === "agent.status" || event.kind === "scheduler.status") return;
    if (event.kind === "proactive.suggestion") {
      const id = typeof event.payload.suggestionId === "string" ? event.payload.suggestionId : event.id;
      if (!this.proposals.has(id)) {
        const proposal: Proposal = {
          id, ruleId: String(event.payload.ruleId), title: String(event.payload.title), summary: String(event.payload.message),
          reason: `由${event.payload.trigger === "time" ? "本地时间" : event.payload.trigger === "idle" ? "设备闲置状态" : "应用事件"}触发`,
          createdAt: event.occurredAt, state: "pending", context: event.payload.context as Record<string, unknown>,
        };
        this.proposals.set(id, proposal);
      }
      const proposal = this.proposals.get(id)!;
      Object.assign(event.payload, { suggestionId: id, summary: proposal.summary, reason: proposal.reason, createdAt: proposal.createdAt, state: proposal.state });
    }
    this.history.push(structuredClone(event));
    this.history = this.history.slice(-200);
    const finished = [...this.proposals.values()].filter((proposal) => ["completed", "ignored"].includes(proposal.state));
    for (const proposal of finished.slice(0, Math.max(0, finished.length - 100))) this.proposals.delete(proposal.id);
    this.persist();
  }

  private persist(): void {
    this.store.save({ version: 1, paused: this.paused, proposals: [...this.proposals.values()], history: this.history, scheduler: this.scheduler.snapshot(), rules: this.scheduler.listRules() }, this.config.dataDir);
  }
}
