import type { AgentEvent } from "./events.ts";

export interface ActivityRecord {
  id: string;
  occurredAt: string;
  kind: "prompt" | "suggestion";
  appName?: string;
}

// 六个日历月最长为 184 天，为本地日期边界保留余量。
export const ACTIVITY_RETENTION_MS = 186 * 24 * 60 * 60_000;

export function retainedActivity(records: ActivityRecord[], now: Date): ActivityRecord[] {
  const seen = new Set<string>();
  return records.filter(record => {
    const date = Date.parse(record.occurredAt);
    if (!record.id || !["prompt", "suggestion"].includes(record.kind) || !Number.isFinite(date)
        || date < now.getTime() - ACTIVITY_RETENTION_MS || date > now.getTime() || seen.has(record.id)) return false;
    seen.add(record.id);
    return true;
  });
}

export function activityFromEvent(event: AgentEvent): ActivityRecord | undefined {
  if (event.kind !== "agent.request" && event.kind !== "proactive.suggestion") return;
  if (event.kind === "proactive.suggestion" && event.payload.trigger === "snooze") return;
  const kind = event.kind === "agent.request" ? "prompt" : "suggestion";
  const context = event.payload.context as Record<string, unknown> | undefined;
  const value = event.payload.appName ?? context?.appName;
  const appName = typeof value === "string" ? value.trim().slice(0, 200) : "";
  return {
    id: `${kind}:${kind === "suggestion" ? event.payload.suggestionId ?? event.id : event.id}`,
    occurredAt: event.occurredAt, kind, ...(appName ? { appName } : {}),
  };
}
