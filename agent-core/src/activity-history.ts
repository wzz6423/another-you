import type { AgentEvent } from "./events.ts";

export function retainedHistory(events: AgentEvent[], now: Date): AgentEvent[] {
  const cutoff = now.getTime() - 30 * 24 * 60 * 60_000;
  return events.filter(event => Date.parse(event.occurredAt) >= cutoff);
}
