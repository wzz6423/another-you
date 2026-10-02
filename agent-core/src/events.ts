import { randomUUID } from "node:crypto";

export type AgentEventKind =
  | "proactive.suggestion"
  | "proactive.status"
  | "context.request"
  | "context.cancel"
  | "scheduler.signal"
  | "scheduler.status"
  | "agent.status"
  | "agent.request"
  | "agent.response"
  | "agent.usage"
  | "agent.activity"
  | "conversation.updated"
  | "conversation.messages"
  | "protocol.chunk"
  | "model.catalog"
  | "model.operation"
  | "model.auth"
  | "proposal.updated"
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
  const json = JSON.stringify(event);
  const bytes = Buffer.from(json);
  if (bytes.length <= 3 * 1024 * 1024) return `${json}\n`;
  const size = 128 * 1024;
  const total = Math.ceil(bytes.length / size);
  const chunks: string[] = [];
  for (let index = 0; index < total; index++) {
    chunks.push(JSON.stringify({ id: `${event.id}:${index}`, occurredAt: event.occurredAt, kind: "protocol.chunk", source: "system",
      payload: { eventId: event.id, index, total, data: bytes.subarray(index * size, (index + 1) * size).toString("base64") } }));
  }
  return `${chunks.join("\n")}\n`;
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
