import type { AgentEvent } from "./events.ts";
import { USAGE_RETENTION_MS } from "./usage.ts";

export function retainedHistory(events: AgentEvent[], now: Date): AgentEvent[] {
  const cutoff = now.getTime() - USAGE_RETENTION_MS;
  return events.filter(event => Date.parse(event.occurredAt) >= cutoff);
}
