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
}

export const USAGE_RETENTION_MS = 30 * 24 * 60 * 60_000;

export function retainedUsage(records: UsageRecord[], now: Date): UsageRecord[] {
  return records.filter((record) => Date.parse(record.occurredAt) >= now.getTime() - USAGE_RETENTION_MS);
}
