import { randomUUID } from "node:crypto";

export type AgentEventKind =
  | "proactive.suggestion"
  | "scheduler.signal"
  | "scheduler.status"
  | "agent.status"
  | "agent.error";

export type AgentEventSource = "scheduler" | "agent" | "system";

export interface AgentEvent<TPayload extends Record<string, unknown> = Record<string, unknown>> {
  id: string;
  occurredAt: string;
  kind: AgentEventKind;
  source: AgentEventSource;
  payload: TPayload;
  dedupeKey?: string;
}

export type AgentEventInput<TPayload extends Record<string, unknown> = Record<string, unknown>> = Omit<
  AgentEvent<TPayload>,
  "id" | "occurredAt"
> & {
  id?: string;
  occurredAt?: string | Date;
};

export type EventListener = (event: AgentEvent) => void;

export function createAgentEvent<TPayload extends Record<string, unknown>>(
  input: AgentEventInput<TPayload>,
): AgentEvent<TPayload> {
  const occurredAt = input.occurredAt instanceof Date ? input.occurredAt.toISOString() : input.occurredAt ?? new Date().toISOString();
  if (Number.isNaN(Date.parse(occurredAt))) throw new TypeError("occurredAt 必须是有效的 ISO 时间");
  return {
    id: input.id ?? randomUUID(),
    occurredAt,
    kind: input.kind,
    source: input.source,
    payload: input.payload,
    ...(input.dedupeKey ? { dedupeKey: input.dedupeKey } : {}),
  };
}

export function encodeEvent(event: AgentEvent): string {
  return `${JSON.stringify(event)}\n`;
}

export class EventBus {
  private readonly listeners = new Set<EventListener>();

  subscribe(listener: EventListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  emit<TPayload extends Record<string, unknown>>(input: AgentEventInput<TPayload>): AgentEvent<TPayload> {
    const event = createAgentEvent(input);
    for (const listener of this.listeners) listener(event);
    return event;
  }

  clear(): void {
    this.listeners.clear();
  }
}
