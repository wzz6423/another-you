import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { PrivacyPolicy } from "./config.ts";
import type { AgentEvent } from "./events.ts";
import type { SchedulerState, TriggerRule } from "./scheduler.ts";

export type ProposalState = "pending" | "running" | "completed" | "snoozed" | "ignored" | "failed";
export type ProposalDecision = "execute" | "later" | "ignore";
export interface Proposal {
  id: string;
  ruleId: string;
  title: string;
  summary: string;
  reason: string;
  createdAt: string;
  state: ProposalState;
  context: Record<string, unknown>;
  text?: string;
  snoozedUntil?: string;
}
export interface PersistedState {
  version: 1;
  paused: boolean;
  proposals: Proposal[];
  history: AgentEvent[];
  scheduler: SchedulerState;
  rules?: TriggerRule[];
}

export function redactSecrets(value: string): string {
  return value
    .replace(/\b(?:sk|ghp|github_pat)[-_][A-Za-z0-9_-]{12,}\b/g, "[已隐藏密钥]")
    .replace(/(bearer\s+)[^\s"'<>]+/gi, "$1[已隐藏密钥]")
    .replace(/((?:api[_-]?key|password|secret|token)\s*[:=]\s*)["']?[^\s,"'}]+["']?/gi, "$1[已隐藏密钥]");
}

function redactValue(value: unknown): unknown {
  if (typeof value === "string") return redactSecrets(value);
  if (Array.isArray(value)) return value.map(redactValue);
  if (typeof value === "object" && value !== null) {
    return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, /^(api[_-]?key|password|secret|token|authorization)$/i.test(key) ? "[已隐藏密钥]" : redactValue(child)]));
  }
  return value;
}

export class StateStore {
  private readonly path: string;
  private readonly privacy: PrivacyPolicy;

  constructor(dataDir: string, privacy: PrivacyPolicy) {
    this.path = join(dataDir, "state.json");
    this.privacy = privacy;
  }

  load(): PersistedState | undefined {
    if (!existsSync(this.path)) return undefined;
    const value = JSON.parse(readFileSync(this.path, "utf8")) as PersistedState;
    if (value.version !== 1 || typeof value.paused !== "boolean" || !Array.isArray(value.proposals) || !Array.isArray(value.history) || !value.scheduler) {
      throw new Error("本地状态文件无效，请保留 state.json 并修复后重试");
    }
    for (const proposal of value.proposals) {
      if (typeof proposal.id !== "string" || typeof proposal.title !== "string" || typeof proposal.summary !== "string" || !["pending", "running", "completed", "snoozed", "ignored", "failed"].includes(proposal.state)) {
        throw new Error("本地建议状态无效");
      }
      if (proposal.state === "running") {
        proposal.state = "failed";
        proposal.text = "上次生成在完成前中断，可手动重试。";
      }
    }
    return value;
  }

  save(state: PersistedState, dataDir: string): void {
    const copy = structuredClone(state);
    if (!this.privacy.storePrompts) {
      for (const rule of copy.rules ?? []) delete rule.context;
    }
    for (const proposal of copy.proposals) {
      if (!this.privacy.storeResponses || (!this.privacy.storePrompts && proposal.state === "failed")) delete proposal.text;
      if (!this.privacy.storePrompts) proposal.context = {};
    }
    for (const event of copy.history) {
      if (!this.privacy.storePrompts) {
        delete event.payload.prompt;
        delete event.payload.context;
        delete event.payload.signal;
      }
      if (!this.privacy.storeResponses) delete event.payload.text;
      if ((!this.privacy.storePrompts || !this.privacy.storeResponses) && event.kind === "agent.error") {
        event.payload.message = "错误详情未保存";
      }
      if (!this.privacy.storePrompts && event.kind === "proposal.updated" && event.payload.state === "failed") delete event.payload.text;
    }
    mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    const tempPath = `${this.path}.${process.pid}.tmp`;
    try {
      writeFileSync(tempPath, `${JSON.stringify(this.privacy.redactSecrets ? redactValue(copy) : copy, null, 2)}\n`, { mode: 0o600 });
      renameSync(tempPath, this.path);
    } finally {
      rmSync(tempPath, { force: true });
    }
  }
}
