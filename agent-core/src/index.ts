import { randomUUID } from "node:crypto";
import type { AgentConfig } from "./config.ts";
import { EventBus, type AgentEvent } from "./events.ts";
import { PiSdkBackend, type PiAgentBackend, type PiRequest, type PiResponse, type PiRunUsage } from "./pi-adapter.ts";
import { ProactiveScheduler, type SchedulerSignal, type TriggerRule } from "./scheduler.ts";
import { StateStore, type PersistedState, type Proposal, type ProposalDecision, type ConversationSession } from "./state.ts";
import { ProactiveCoordinator, type ContextResult } from "./proactive.ts";

import { retainedUsage, type UsageRecord } from "./usage.ts";
import { activityFromEvent, retainedActivity, type ActivityRecord } from "./activity.ts";
import { parseAttachments, parseDesktopSnapshot } from "./desktop-bridge.ts";
import { retainedHistory } from "./activity-history.ts";
import { LocalModelBackend, localModelRecommendation } from "./local-model.ts";

export * from "./usage.ts";
export * from "./activity.ts";
export * from "./config.ts";
export * from "./events.ts";
export * from "./pi-adapter.ts";
export * from "./scheduler.ts";
export * from "./state.ts";
export * from "./proactive.ts";
export * from "./proactive-config.ts";

export const DEFAULT_RULES: TriggerRule[] = [
  { id: "morning", type: "time", at: "09:00", title: "早间整理", message: "现在是早上九点。要不要生成一个今日计划的空白草稿，再由你补充真实安排？", cooldownMs: 20 * 60 * 60_000 },
  { id: "idle", type: "idle", minIdleMs: 15 * 60_000, title: "留一个继续的入口", message: "设备已闲置一段时间。可以生成一个简短的恢复工作清单；我还不知道你刚才在做什么。", cooldownMs: 2 * 60 * 60_000 },
];

const LEGACY_WELCOME_RULE: TriggerRule = {
  id: "welcome", type: "event", eventName: "app-launched", title: "给今天留一个起点",
  message: "可以一起梳理今天的优先事项。当前未连接日历或任务来源，你可以先告诉我最想推进的一件事。", cooldownMs: 24 * 60 * 60_000,
};

function retireWelcomeSample(saved: PersistedState | undefined): boolean {
  if (!saved) return false;
  const hasLegacyRule = saved.rules?.some(rule => {
    const { enabled, ...definition } = rule;
    return enabled !== false && Object.keys(definition).length === Object.keys(LEGACY_WELCOME_RULE).length
      && Object.entries(LEGACY_WELCOME_RULE).every(([key, value]) => definition[key as keyof typeof definition] === value);
  });
  if (!hasLegacyRule) return false;
  saved.rules = saved.rules!.filter(rule => rule.id !== LEGACY_WELCOME_RULE.id);
  // 原始触发仍在历史中且没有后续决策，才能确认这只是未经用户操作的旧样例。
  const samples = new Set(saved.proposals.filter(proposal =>
    proposal.ruleId === LEGACY_WELCOME_RULE.id && proposal.title === LEGACY_WELCOME_RULE.title
    && proposal.summary === LEGACY_WELCOME_RULE.message && proposal.reason === "由应用事件触发"
    && proposal.state === "pending" && proposal.text === undefined && proposal.snoozedUntil === undefined
    && proposal.archived === undefined && !proposal.pinned && Object.keys(proposal.context ?? {}).length === 0
    && saved.history.some(event => event.id === proposal.id && event.kind === "proactive.suggestion"
      && event.source === "scheduler" && event.occurredAt === proposal.createdAt
      && event.payload.ruleId === LEGACY_WELCOME_RULE.id && event.payload.trigger === "event"
      && (event.payload.signal as Record<string, unknown> | undefined)?.name === "app-launched")
    && !saved.history.some(event => event.kind === "proposal.updated" && event.payload.suggestionId === proposal.id)
  ).map(proposal => proposal.id));
  saved.proposals = saved.proposals.filter(proposal => !samples.has(proposal.id));
  saved.history = saved.history.filter(event => !samples.has(event.id));
  return true;
}

export interface AgentCoreOptions {
  config: AgentConfig;
  rules?: TriggerRule[];
  backend?: PiAgentBackend;
  localBackend?: PiAgentBackend;
  now?: () => Date;
}

export class AgentCore {
  readonly events: EventBus;
  readonly scheduler: ProactiveScheduler;
  readonly backend: PiAgentBackend;
  readonly localBackend: PiAgentBackend;
  readonly config: AgentConfig;
  readonly proactive: ProactiveCoordinator;
  private readonly clock: () => Date;
  private readonly store: StateStore;
  private readonly proposals = new Map<string, Proposal>();
  private history: AgentEvent[] = [];
  private usageRecords: UsageRecord[] = [];
  private activityRecords: ActivityRecord[] = [];
  private readonly conversations = new Map<string, ConversationSession>();
  private paused = false;
  private timer: ReturnType<typeof setInterval> | undefined;
  private started = false;
  private readonly foregroundRuns = new Map<string, { controller: AbortController; conversationId?: string }>();
  private get foregroundBusy(): boolean { return this.foregroundRuns.size > 0; }
  private localOperationBusy = false;

  constructor(options: AgentCoreOptions) {
    this.config = options.config;
    this.clock = options.now ?? (() => new Date());
    this.store = new StateStore(this.config.dataDir, this.config.privacy);
    const saved = this.store.load();
    const retiredWelcome = options.rules === undefined && retireWelcomeSample(saved);
    this.paused = saved?.paused ?? false;
    this.history = retainedHistory(saved?.history ?? [], this.clock());
    this.usageRecords = retainedUsage(saved?.usageRecords ?? [], this.clock());
    this.activityRecords = retainedActivity(saved?.activityRecords ?? (saved?.history ?? []).flatMap(event => {
      const record = activityFromEvent(event);
      return record ? [record] : [];
    }), this.clock());
    for (const session of saved?.conversations ?? []) this.conversations.set(session.id, session);
    for (const proposal of saved?.proposals ?? []) this.proposals.set(proposal.id, proposal);
    this.events = new EventBus();
    this.scheduler = new ProactiveScheduler(options.rules ?? saved?.rules ?? DEFAULT_RULES, this.events, {
      defaults: options.config.scheduler,
      now: this.clock,
      shouldFire: (ruleId) => !this.foregroundBusy && this.proactive.canSuggest() && ![...this.proposals.values()].some((proposal) => proposal.ruleId === ruleId && !proposal.archived && ["pending", "running", "snoozed", "failed"].includes(proposal.state)),
    });
    if (saved) this.scheduler.restore(saved.scheduler);
    this.backend = options.backend ?? new PiSdkBackend(options.config);
    this.localBackend = options.localBackend ?? new LocalModelBackend(options.config.proactive.localModel);
    this.proactive = new ProactiveCoordinator({
      config: this.config.proactive, events: this.events, now: this.clock, saved: saved?.proactive,
      run: (request) => this.runWithUsage(request, request.agentRole as "context-analyst" | "notification-analyst" | "proactive-parent", {}, this.localBackend),
      runRemote: (request) => this.runWithUsage(request, "proactive-parent"),
      remoteConfigured: () => this.backend.status?.().configured !== false,
      canSuggest: () => !this.paused && !this.foregroundBusy && ![...this.proposals.values()].some((proposal) => proposal.ruleId === "context-insight" && !proposal.archived && ["pending", "running", "snoozed", "failed"].includes(proposal.state)),
      recentSuggestions: () => this.history.filter(event => event.kind === "proactive.suggestion").slice(-10)
        .map(event => ({ title: String(event.payload.title ?? ""), summary: String(event.payload.message ?? ""), state: String(event.payload.state ?? "pending") })),
    });
    this.events.subscribe((event) => this.record(event));
    if (retiredWelcome) this.persist();
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
    this.proactive.tick(this.started && !this.foregroundBusy && !this.localOperationBusy && this.localBackend.status?.().configured !== false);
    const restored: AgentEvent[] = [];
    for (const proposal of this.proposals.values()) {
      if (proposal.archived || proposal.state !== "snoozed" || !proposal.snoozedUntil || Date.parse(proposal.snoozedUntil) > now.getTime()) continue;
      if (this.foregroundBusy || !this.proactive.canSuggest(now.getTime())) continue;
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
    void this.proactive.interrupt();
    this.scheduler.stop();
    this.cancel();
  }

  cancel(conversationId?: string): void {
    if (conversationId !== undefined && (typeof conversationId !== "string" || !conversationId.trim())) throw new Error("conversationId 无效");
    for (const run of this.foregroundRuns.values()) {
      if (conversationId === undefined || run.conversationId === conversationId) run.controller.abort();
    }
    if (conversationId === undefined) { this.backend.abort?.(); this.localBackend.abort?.(); }
  }

  setPaused(paused: boolean): void {
    this.paused = paused;
    if (paused) void this.proactive.interrupt();
    this.persist();
    this.events.emit({ kind: "scheduler.status", source: "scheduler", payload: { running: this.started && this.config.scheduler.enabled && !paused, paused } });
    if (!paused) this.tick();
  }

  addRule(rule: TriggerRule): void { this.scheduler.addRule(rule); this.persist(); }
  removeRule(ruleId: string): void { this.scheduler.removeRule(ruleId); this.persist(); }

  registerContextSources(sources: unknown): void { this.proactive.registerSources(sources); }
  receiveContext(result: ContextResult): void { this.proactive.receive(result); }
  async settleBackground(): Promise<void> { await this.proactive.settle(); }

  async withLocalModelOperation<T>(operation: () => Promise<T>): Promise<T> {
    if (this.foregroundBusy || this.localOperationBusy) throw new Error("正在处理请求，请稍后修改本地模型");
    this.localOperationBusy = true;
    try { await this.proactive.interrupt(); return await operation(); }
    finally { this.localOperationBusy = false; }
  }

  checkContextNow(): void {
    if (this.paused || !this.config.scheduler.enabled || !this.config.proactive.enabled) throw new Error("请先恢复主动建议");
    if (this.localBackend.status?.().configured === false) throw new Error("请先配置本地模型");
    if (this.foregroundBusy || this.localOperationBusy) throw new Error("正在处理请求，请稍后检查");
    this.proactive.checkNow();
    this.tick();
  }

  status(includeConversationMessages = true): Record<string, unknown> {
    return {
      paused: this.paused,
      schedulerEnabled: this.config.scheduler.enabled,
      proactive: this.proactive.status(),
      localModel: { ...this.localBackend.status?.(), configuration: { ...this.config.proactive.localModel, apiKey: undefined },
        workLookbackHours: this.config.proactive.workLookbackHours,
        hasAPIKey: !!this.config.proactive.localModel.apiKey, recommendation: localModelRecommendation() },
      model: this.backend.status?.() ?? { configured: true, available: null, model: "unknown", endpoint: "", provider: "", reasoningEffort: "unknown", configDirectory: "", message: "自定义模型后端" },
      rules: this.scheduler.listRules(),
      proposals: [...this.proposals.values()].map((proposal) => ({ ...proposal })),
      conversations: this.conversationSnapshots(includeConversationMessages),
      history: structuredClone(retainedHistory(this.history, this.clock())),
      usageRecords: structuredClone(retainedUsage(this.usageRecords, this.clock())),
      activityRecords: structuredClone(retainedActivity(this.activityRecords, this.clock())),
    };
  }

  async prompt(requestId: string, prompt: string, attachments?: unknown, allowForeground = false, conversationId = "default", desktopSnapshot?: unknown): Promise<void> {
    if (typeof requestId !== "string" || !requestId.trim() || requestId.length > 256) throw new Error("requestId 必须是非空字符串且不超过 256 字符");
    if (typeof prompt !== "string" || !prompt.trim() || prompt.length > 50_000) throw new Error("prompt 必须为非空文本且不超过 50000 字符");
    if (this.history.some((event) => event.kind === "agent.response" && event.payload.requestId === requestId)) throw new Error("此请求已完成，请使用新的 requestId");
    const images = parseAttachments(attachments);
    const snapshot = parseDesktopSnapshot(desktopSnapshot);
    if (typeof allowForeground !== "boolean") throw new Error("allowForeground 必须为布尔值");
    if (typeof conversationId !== "string" || !conversationId.trim() || conversationId.length > 256) throw new Error("conversationId 无效");
    if (this.proposals.has(conversationId)) throw new Error("会话编号已被建议占用");
    let session = this.conversations.get(conversationId);
    if (session?.state === "running") throw new Error("当前会话正在处理请求，请完成或取消后继续");
    if (session?.archived) throw new Error("请先恢复已归档的会话");
    if (session?.messages.some(message => message.id === requestId)) throw new Error("请求编号已使用");
    const appName = [snapshot?.context.appName, ...images.map(image => image.context?.appName)].find(value => typeof value === "string");
    if (!session) {
      session = { id: conversationId, title: prompt.slice(0, 100), ...(typeof appName === "string" ? { appName: appName.slice(0, 200) } : {}),
        createdAt: this.clock().toISOString(), updatedAt: this.clock().toISOString(), state: "running", archived: false, pinned: false, messages: [] };
      this.conversations.set(conversationId, session);
    } else if (!session.appName && typeof appName === "string") session.appName = appName.slice(0, 200);
    const context = session.messages.flatMap(message => message.response === undefined ? [] : [
      { role: "user", content: message.prompt }, { role: "assistant", content: message.response },
    ]).slice(-40);
    const turn = { id: requestId, prompt } as ConversationSession["messages"][number];
    session.messages.push(turn);
    session.state = "running";
    session.updatedAt = this.clock().toISOString();
    this.publishConversation(session.id);
    this.events.emit({ kind: "agent.request", source: "agent", occurredAt: this.clock(), payload: { requestId, conversationId, prompt,
      ...(appName || session.appName ? { appName: appName || session.appName } : {}), ...(images.length ? { screenshotCount: images.length } : {}) } });
    try {
      const response = await this.runWithUsage({ prompt, conversationId, attachments: images, allowForeground, desktopSnapshot: snapshot, context: { conversation: context },
        activityContext: appName || session.appName ? { appName: appName || session.appName } : undefined }, "prompt", { requestId, conversationId });
      turn.response = response.text;
      session.state = "completed";
      this.events.emit({ kind: "agent.response", source: "agent", payload: { requestId, conversationId, text: response.text, model: response.model } });
    } catch (error) {
      turn.error = error instanceof Error ? error.message : String(error);
      session.state = "failed";
      this.events.emit({ kind: "agent.error", source: "agent", payload: { requestId, conversationId, message: turn.error } });
    } finally {
      session.updatedAt = this.clock().toISOString();
      this.publishConversation(session.id);
    }
  }

  manageConversation(id: string, action: string): void {
    if (!["archive", "unarchive", "delete", "pin", "unpin"].includes(action)) throw new Error("不支持的会话操作");
    const session = this.conversations.get(id);
    const proposal = this.proposals.get(id);
    const item = session ?? proposal;
    if (!item) throw new Error("找不到会话");
    if (item.state === "running") throw new Error("请先停止正在执行的会话");
    const previous = structuredClone(item);
    const history = this.history;
    if (action === "delete") {
      this.conversations.delete(id);
      this.proposals.delete(id);
      this.history = this.history.filter(event => event.payload.conversationId !== id && event.payload.suggestionId !== id);
    } else if (action === "pin" || action === "unpin") item.pinned = action === "pin";
    else item.archived = action === "archive";
    try { this.publishConversation(id, action); }
    catch (error) {
      if (session) this.conversations.set(id, previous as ConversationSession);
      else this.proposals.set(id, previous as Proposal);
      this.history = history;
      throw error;
    }
  }

  forkConversation(id: string, requestId: string, messageId?: string): void {
    if (typeof requestId !== "string" || !requestId.trim() || requestId.length > 256) throw new Error("requestId 无效");
    if (messageId !== undefined && (typeof messageId !== "string" || !messageId.trim())) throw new Error("messageId 无效");
    const source = this.conversations.get(id);
    if (!source) throw new Error("找不到会话");
    if (this.foregroundBusy || source.state === "running") throw new Error("请先停止正在执行的会话");
    const index = messageId === undefined ? source.messages.length - 1 : source.messages.findIndex(message => message.id === messageId);
    if (index < 0) throw new Error("找不到分支起点");
    const messages = structuredClone(source.messages.slice(0, index + 1));
    if (messages.some(message => message.response === undefined && message.error === undefined)) throw new Error("请先停止正在执行的会话");
    const fork: ConversationSession = {
      id: randomUUID(), title: source.title, ...(source.appName ? { appName: source.appName } : {}),
      createdAt: this.clock().toISOString(), updatedAt: this.clock().toISOString(), archived: false, pinned: false,
      state: messages.at(-1)?.error === undefined ? "completed" : "failed", messages,
      forkedFrom: { conversationId: id, messageId: messages.at(-1)!.id },
    };
    this.conversations.set(fork.id, fork);
    try { this.publishConversation(fork.id, "fork", { requestId, sourceConversationId: id }); }
    catch (error) { this.conversations.delete(fork.id); throw error; }
  }

  private conversationSnapshots(includeMessages: boolean): Record<string, unknown>[] {
    return [...this.conversations.values()].map(session => {
      const { messages, ...summary } = session;
      return includeMessages ? structuredClone(session) : summary;
    });
  }

  readConversation(id: string, readId: string): void {
    if (typeof readId !== "string" || !readId || readId.length > 256) throw new Error("readId 无效");
    const session = this.conversations.get(id);
    if (!session) throw new Error("找不到会话");
    this.events.emit({ kind: "conversation.messages", source: "agent", payload: {
      conversationId: id, readId, conversation: structuredClone(session),
    } });
  }

  private publishConversation(id: string, action?: string, operation: Record<string, string> = {}): void {
    this.persist();
    this.events.emit({ kind: "conversation.updated", source: "agent", payload: { conversationId: id, ...(action ? { action } : {}), ...operation,
      conversations: this.conversationSnapshots(false), proposals: structuredClone([...this.proposals.values()]) } });
  }

  async decide(suggestionId: string, decision: ProposalDecision, snoozeMinutes = 15): Promise<void> {
    if (!["execute", "later", "ignore"].includes(decision)) throw new Error("decision 必须是 execute、later 或 ignore");
    const proposal = this.proposals.get(suggestionId);
    if (!proposal) throw new Error("找不到这条主动建议");
    if (proposal.archived || ["completed", "ignored", "running"].includes(proposal.state)) throw new Error("这条建议已处理或正在执行，不能重复处理");
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
      const local = proposal.context?.executionRoute === "local";
      const response = await this.runWithUsage({ prompt: `用户批准了以下建议，请生成一份可审阅的草稿。只使用已给出的信息。\n建议：${proposal.title}\n说明：${proposal.summary}`, context: proposal.context,
        activityContext: Object.fromEntries(["appName", "bundleId", "windowTitle"].flatMap(key => typeof proposal.context?.[key] === "string" ? [[key, proposal.context[key]]] : [])) },
      "proposal", { suggestionId }, local ? this.localBackend : this.backend);
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

  private async runWithUsage(request: PiRequest, source: UsageRecord["source"], correlation: Record<string, string> = {}, backend = this.backend): Promise<PiResponse> {
    const foreground = source === "prompt" || source === "proposal";
    if (foreground && this.localOperationBusy) throw new Error("本地模型配置操作尚未结束");
    let summary: Partial<PiRunUsage> | undefined;
    let outcome: UsageRecord["outcome"] = "failed";
    const status = backend.status?.();
    let model = status?.model ?? "unknown";
    let result: string | undefined;
    let failure: string | undefined;
    const startedAt = this.clock();
    const route = backend === this.localBackend ? "local" : "remote";
    const metadata = { runId: request.runId ?? randomUUID(), ...request.activityContext, ...correlation, route,
      provider: status?.provider, endpoint: status?.endpoint, model, reasoningEffort: status?.reasoningEffort, startedAt: startedAt.toISOString() };
    const controller = new AbortController();
    if (foreground) this.foregroundRuns.set(metadata.runId, { controller, conversationId: correlation.conversationId });
    const signal = request.signal ? AbortSignal.any([request.signal, controller.signal]) : controller.signal;
    try {
      if (foreground) await this.proactive.interrupt();
      signal.throwIfAborted();
      this.events.emit({ kind: "agent.activity", source: "agent", occurredAt: this.clock(), payload: { category: "execution", phase: "started", source, ...metadata, input: request.prompt.slice(0, 12000) } });
      const response = await backend.run({ ...request, runId: metadata.runId, signal, onUsage: (value) => { summary = value; },
        onActivity: (activity) => this.events.emit({ kind: "agent.activity", source: "agent", occurredAt: this.clock(), payload: { ...metadata, ...activity, source } }),
      });
      summary ??= response;
      model = response.model ?? model;
      outcome = "completed";
      result = response.text.slice(0, 12000);
      return response;
    } catch (error) {
      failure = foreground ? (error instanceof Error ? error.message : String(error)).slice(0, 1000) : "后台模型请求失败或已取消，请查看本地连接和任务状态";
      throw error;
    } finally {
      if (foreground) this.foregroundRuns.delete(metadata.runId);
      const usage = { ...metadata, source, model: summary?.model ?? model, outcome,
        durationMs: Math.max(0, this.clock().getTime() - startedAt.getTime()), ...(summary?.usage ? { usage: summary.usage } : {}),
        reasoningEffort: summary?.reasoningEffort ?? "unknown", toolCalls: [
          ...(request.activityContext?.parentRunId ? [{ name: "remote_assist", kind: "skill" }] : []), ...(summary?.toolCalls ?? [])],
        upstreamRequestId: summary?.upstreamRequestId, requestPath: summary?.requestPath,
      };
      this.events.emit({ kind: "agent.activity", source: "agent", occurredAt: this.clock(), payload: {
        ...usage, category: "execution", phase: outcome, ...(result ? { result } : {}), ...(failure ? { message: failure } : {}),
      } });
      this.events.emit({ kind: "agent.usage", source: "agent", occurredAt: this.clock(), payload: usage });
    }
  }

  private update(proposal: Proposal, decision: ProposalDecision): void {
    this.events.emit({ kind: "proposal.updated", source: "agent", payload: { suggestionId: proposal.id, decision, state: proposal.state, ...(proposal.text ? { text: proposal.text } : {}), ...(proposal.snoozedUntil ? { snoozedUntil: proposal.snoozedUntil } : {}) } });
  }

  private record(event: AgentEvent): void {
    if (event.kind === "agent.status" || event.kind === "scheduler.status") return;
    if (event.kind === "activity.recorded") {
      this.activityRecords = retainedActivity([...this.activityRecords, {
        id: event.id, occurredAt: event.occurredAt, ...event.payload,
      } as unknown as ActivityRecord], this.clock());
      this.persist();
      return;
    }
    if (event.kind === "conversation.updated" || event.kind === "conversation.messages") return;
    if (event.kind === "context.request") return;
    if (event.kind === "context.cancel") return;
    if (event.kind === "proactive.status") { this.persist(); return; }
    if (event.kind === "proactive.suggestion") {
      this.proactive.noteSuggestion(Date.parse(event.occurredAt));
      const id = typeof event.payload.suggestionId === "string" ? event.payload.suggestionId : event.id;
      const context = event.payload.context as Record<string, unknown> | undefined;
      const draft = event.payload.ruleId === "context-insight" && typeof event.payload.draft === "string" ? event.payload.draft : undefined;
      if (draft) {
        const session: ConversationSession = { id, source: "proactive", title: String(event.payload.title), createdAt: event.occurredAt, updatedAt: event.occurredAt,
          state: "completed", archived: false, pinned: false, ...(typeof context?.appName === "string" ? { appName: context.appName } : {}),
          messages: [{ id: randomUUID(), prompt: String(event.payload.message), response: draft }] };
        this.conversations.set(id, session);
        Object.assign(event.payload, { conversationId: id, suggestionId: id, state: "completed", text: draft });
        this.publishConversation(id);
      } else if (!this.proposals.has(id)) {
        const proposal: Proposal = {
          id, ruleId: String(event.payload.ruleId), title: String(event.payload.title), summary: String(event.payload.message),
          reason: typeof event.payload.reason === "string" ? event.payload.reason : `由${event.payload.trigger === "time" ? "本地时间" : event.payload.trigger === "idle" ? "设备闲置状态" : "应用事件"}触发`,
          createdAt: event.occurredAt, state: "pending", pinned: false, context: event.payload.context as Record<string, unknown>,
        };
        this.proposals.set(id, proposal);
      }
      const proposal = this.proposals.get(id);
      if (proposal) Object.assign(event.payload, { suggestionId: id, summary: proposal.summary, reason: proposal.reason, createdAt: proposal.createdAt, state: proposal.state, pinned: proposal.pinned });
    }
    if (event.kind === "agent.usage") {
      this.usageRecords.push({ id: event.id, occurredAt: event.occurredAt, ...event.payload } as unknown as UsageRecord);
      this.usageRecords = retainedUsage(this.usageRecords, this.clock());
      this.persist();
      return;
    }
    this.history.push(structuredClone(event));
    const activity = activityFromEvent(event);
    if (activity && !this.activityRecords.some(record => record.id === activity.id)) {
      const { id, occurredAt, ...payload } = activity;
      this.events.emit({ id, occurredAt, kind: "activity.recorded", source: "agent", payload });
    }
    const finished = [...this.proposals.values()].filter((proposal) => !proposal.pinned && ["completed", "ignored"].includes(proposal.state));
    for (const proposal of finished.slice(0, Math.max(0, finished.length - 100))) this.proposals.delete(proposal.id);
    this.persist();
  }

  private persist(): void {
    this.history = retainedHistory(this.history, this.clock());
    this.store.save({ version: 1, paused: this.paused, proposals: [...this.proposals.values()], conversations: [...this.conversations.values()], history: this.history, usageRecords: retainedUsage(this.usageRecords, this.clock()), activityRecords: retainedActivity(this.activityRecords, this.clock()), scheduler: this.scheduler.snapshot(), rules: this.scheduler.listRules(), proactive: this.proactive.snapshot() }, this.config.dataDir);
  }
}
