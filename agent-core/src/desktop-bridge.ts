import { randomUUID } from "node:crypto";
import type { AgentTool, AgentToolResult } from "@earendil-works/pi-agent-core";
import { Type, type TSchema } from "typebox";

export interface DesktopRequest {
  id: string;
  occurredAt: string;
  kind: "desktop.request" | "desktop.cancel";
  source: "agent";
  payload: Record<string, unknown>;
}

export interface ScreenshotAttachment {
  data: string;
  mimeType: "image/jpeg" | "image/png";
  context?: Record<string, unknown>;
}

export function parseAttachments(value: unknown): ScreenshotAttachment[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 4) throw new Error("最多附加 4 张截图");
  let size = 0;
  return value.map((item: unknown) => {
    if (!item || typeof item !== "object") throw new Error("无效截图附件");
    const attachment = item as Record<string, unknown>;
    if (attachment.mimeType !== "image/jpeg" && attachment.mimeType !== "image/png") throw new Error("截图只支持 JPEG 或 PNG");
    if (typeof attachment.data !== "string" || !attachment.data.length || !/^[A-Za-z0-9+/]+={0,2}$/.test(attachment.data) || attachment.data.length % 4 !== 0) throw new Error("截图数据无效");
    size += attachment.data.length;
    if (size > 3_000_000) throw new Error("截图附件过大，请减少截图数量");
    const bytes = Buffer.from(attachment.data, "base64");
    const valid = attachment.mimeType === "image/png"
      ? bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
      : bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
    if (!valid) throw new Error("截图格式与内容不匹配");
    if (attachment.context !== undefined && (!attachment.context || typeof attachment.context !== "object" || Array.isArray(attachment.context) || JSON.stringify(attachment.context).length > 100_000)) throw new Error("截图上下文无效或过大");
    return { data: attachment.data, mimeType: attachment.mimeType, ...(attachment.context ? { context: attachment.context as Record<string, unknown> } : {}) };
  });
}

export class DesktopBridge {
  private pending = new Map<string, { resolve: (value: Record<string, unknown>) => void; reject: (error: Error) => void }>();
  private emit: (event: DesktopRequest) => void;
  private timeoutMs: number;

  constructor(emit: (event: DesktopRequest) => void, timeoutMs = 30_000) {
    this.emit = emit;
    this.timeoutMs = timeoutMs;
  }

  async request(arguments_: Record<string, unknown>, signal?: AbortSignal): Promise<Record<string, unknown>> {
    if (signal?.aborted) throw new Error("电脑操作已取消");
    const requestId = randomUUID();
    let cancel: () => void = () => {};
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await new Promise<Record<string, unknown>>((resolve, reject) => {
        this.pending.set(requestId, { resolve, reject });
        cancel = () => {
          if (!this.pending.delete(requestId)) return;
          this.emit({ id: randomUUID(), occurredAt: new Date().toISOString(), kind: "desktop.cancel", source: "agent", payload: { requestId } });
          reject(new Error("电脑操作已取消或超时"));
        };
        signal?.addEventListener("abort", cancel, { once: true });
        timer = setTimeout(cancel, this.timeoutMs);
        this.emit({ id: randomUUID(), occurredAt: new Date().toISOString(), kind: "desktop.request", source: "agent", payload: { requestId, arguments: arguments_ } });
      });
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", cancel);
      this.pending.delete(requestId);
    }
  }

  receive(command: { requestId?: unknown; result?: unknown; error?: unknown }): void {
    if (typeof command.requestId !== "string") throw new Error("电脑操作回执缺少 requestId");
    const pending = this.pending.get(command.requestId);
    if (!pending) return;
    this.pending.delete(command.requestId);
    if (typeof command.error === "string") pending.reject(new Error(command.error));
    else if (command.result && typeof command.result === "object" && !Array.isArray(command.result)) pending.resolve(command.result as Record<string, unknown>);
    else pending.reject(new Error("电脑操作返回了无效结果"));
  }

  abort(): void {
    for (const [requestId, pending] of this.pending) {
      this.emit({ id: randomUUID(), occurredAt: new Date().toISOString(), kind: "desktop.cancel", source: "agent", payload: { requestId } });
      pending.reject(new Error("电脑操作已停止"));
    }
    this.pending.clear();
  }
}

export function desktopResult(result: Record<string, unknown>): AgentToolResult {
  const { image, ...context } = result;
  const content: AgentToolResult["content"] = [{ type: "text", text: JSON.stringify(context).slice(0, 100_000) }];
  if (image) {
    const attachment = parseAttachments([image])[0];
    content.push({ type: "image", data: attachment.data, mimeType: attachment.mimeType });
  }
  return { content, details: undefined };
}

function defineTool<T extends TSchema>(tool: AgentTool<T>): AgentTool<T> { return tool; }

export function createDesktopTools(bridge: DesktopBridge, allowForeground = false): AgentTool<any>[] {
  return [defineTool({
    name: "computer_use", label: "电脑操作",
    description: "读取 macOS 应用上下文、截图，或按快照 elementId 操作。默认后台 AX 操作，不抢焦点。先获取 context 再使用其 elementId。后台不支持的操作会报错，禁止偷偷切换前台。网页请优先用 browser_use。",
    parameters: Type.Object({
      action: Type.Union(["capabilities", "context", "screenshot", "press", "setValue", "scroll", "click", "type", "key"].map(value => Type.Literal(value))),
      pid: Type.Optional(Type.Integer({ minimum: 1 })),
      elementId: Type.Optional(Type.String({ maxLength: 256 })),
      mode: Type.Optional(Type.Union([Type.Literal("window"), Type.Literal("screen")])),
      background: Type.Optional(Type.Boolean()),
      text: Type.Optional(Type.String({ maxLength: 8_000 })),
      value: Type.Optional(Type.String({ maxLength: 8_000 })),
      key: Type.Optional(Type.String({ maxLength: 100 })),
      modifiers: Type.Optional(Type.Array(Type.Union(["command", "shift", "option", "control"].map(value => Type.Literal(value))), { maxItems: 4 })),
      x: Type.Optional(Type.Number()), y: Type.Optional(Type.Number()),
      direction: Type.Optional(Type.Union(["up", "down", "left", "right"].map(value => Type.Literal(value)))),
      amount: Type.Optional(Type.Integer({ minimum: 1, maximum: 10 })),
    }, { additionalProperties: false }),
    async execute(_id, params, signal) {
      if (params.background === false && !allowForeground) throw new Error("当前会话仅允许后台操作，请让用户开启前台控制后重新发送");
      return desktopResult(await bridge.request({ ...params, background: params.background ?? true }, signal));
    },
  })];
}
