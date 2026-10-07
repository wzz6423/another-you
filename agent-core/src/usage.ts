import type { PiRunUsage } from "./pi-adapter.ts";

export interface UsageRecord {
  id: string;
  occurredAt: string;
  source: "prompt" | "proposal" | "context-analyst" | "notification-analyst" | "proactive-parent";
  model: string;
  outcome: "completed" | "failed";
  usage?: PiRunUsage["usage"];
  reasoningEffort: string;
  toolCalls: PiRunUsage["toolCalls"];
  runId?: string;
  requestId?: string;
  suggestionId?: string;
  appName?: string;
  bundleId?: string;
  windowTitle?: string;
  route?: "local" | "remote";
  provider?: string;
  endpoint?: string;
  requestPath?: string;
  upstreamRequestId?: string;
  startedAt?: string;
  durationMs?: number;
}

export const USAGE_RETENTION_MS = 186 * 24 * 60 * 60_000;

export function retainedUsage(records: UsageRecord[], now: Date): UsageRecord[] {
  const cutoff = now.getTime() - USAGE_RETENTION_MS;
  const seen = new Set<string>();
  return records.filter(record => {
    const date = Date.parse(record.occurredAt);
    if (!record.id || !Number.isFinite(date) || date < cutoff || seen.has(record.id)) return false;
    seen.add(record.id);
    return true;
  });
}
