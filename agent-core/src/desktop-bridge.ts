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

export interface DesktopSnapshot {
  capturedAt: string;
  context: Record<string, unknown>;
  contextError?: string;
  image?: ScreenshotAttachment;
  mode?: "screen" | "window" | "region";
  screenshotError?: string;
}

export function parseDesktopSnapshot(value: unknown): DesktopSnapshot | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("唤起时的桌面快照无效");
  const snapshot = value as Record<string, unknown>;
  if (typeof snapshot.capturedAt !== "string" || snapshot.capturedAt.length > 100 || !Number.isFinite(Date.parse(snapshot.capturedAt))) throw new Error("桌面快照缺少有效采集时间");
  if (!snapshot.context || typeof snapshot.context !== "object" || Array.isArray(snapshot.context) || JSON.stringify(snapshot.context).length > 100_000) throw new Error("桌面快照上下文无效或过大");
  const context = structuredClone(snapshot.context) as Record<string, unknown>;
  if (context.pid !== undefined && (typeof context.pid !== "number" || !Number.isInteger(context.pid) || context.pid < 1 || context.pid > 2_147_483_647)) throw new Error("桌面快照的目标进程无效");
  if (context.targetId !== undefined && (typeof context.targetId !== "string" || !context.targetId.length || context.targetId.length > 256)) throw new Error("应用快照的目标引用无效");
  if (context.windowId !== undefined && context.windowId !== null && (typeof context.windowId !== "number" || !Number.isInteger(context.windowId) || context.windowId < 1 || context.windowId > 4_294_967_295)) throw new Error("应用快照的窗口编号无效");
  for (const key of ["contextError", "screenshotError"] as const) {
    if (snapshot[key] !== undefined && (typeof snapshot[key] !== "string" || snapshot[key].length > 2_000)) throw new Error("桌面快照错误信息无效或过长");
  }
  if (snapshot.mode !== undefined && !["screen", "window", "region"].includes(String(snapshot.mode))) throw new Error("桌面快照截图模式无效");
  return { capturedAt: snapshot.capturedAt, context,
    ...(snapshot.contextError !== undefined ? { contextError: snapshot.contextError as string } : {}),
    ...(snapshot.image !== undefined ? { image: parseAttachments([snapshot.image])[0] } : {}),
    ...(snapshot.mode !== undefined ? { mode: snapshot.mode as DesktopSnapshot["mode"] } : {}),
    ...(snapshot.screenshotError !== undefined ? { screenshotError: snapshot.screenshotError as string } : {}) };
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
  const app = context.context && typeof context.context === "object" ? context.context as Record<string, unknown> : context;
  const details = Object.fromEntries(["appName", "bundleId", "windowTitle"].flatMap(key => {
    const value = app[key === "windowTitle" ? "title" : key];
    return typeof value === "string" ? [[key, value.slice(0, 1000)]] : [];
  }));
  const content: AgentToolResult["content"] = [{ type: "text", text: JSON.stringify(context).slice(0, 100_000) }];
  if (image) {
    const attachment = parseAttachments([image])[0];
    content.push({ type: "image", data: attachment.data, mimeType: attachment.mimeType });
  }
  return { content, details };
}

function defineTool<T extends TSchema>(tool: AgentTool<T>): AgentTool<T> { return tool; }

export function createDesktopTools(bridge: DesktopBridge | undefined, allowForeground = false, desktopSnapshot?: DesktopSnapshot): AgentTool<any>[] {
  const snapshot = desktopSnapshot ? structuredClone(desktopSnapshot) : undefined;
  return [defineTool({
    name: "computer_use", label: "电脑操作",
    description: "读取 macOS 应用上下文、截图，或用 snapshot 同时读取应用身份、窗口、文字、控件树和画面。默认后台 AX 操作，不抢焦点。先获取 context 再使用其 elementId。后台不支持的操作会报错，禁止偷偷切换前台。网页请优先用 browser_use。" + (snapshot ? " 本轮默认返回临时输入框唤起时的应用快照。需要补读时设置 refresh=true，只在后台读取原应用的原窗口；刷新后使用新的 elementId。原窗口失效会报错，不重新读取当前桌面。" : ""),
    parameters: Type.Object({
      action: Type.Union(["capabilities", "context", "snapshot", "screenshot", "press", "setValue", "scroll", "click", "type", "key"].map(value => Type.Literal(value))),
      refresh: Type.Optional(Type.Boolean()),
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
      if (signal?.aborted) throw new Error("电脑操作已取消");
      if (params.background === false && !allowForeground) throw new Error("当前会话仅允许后台操作，请让用户开启前台控制后重新发送");
      const read = ["context", "snapshot", "screenshot"].includes(params.action);
      if (snapshot && read) {
        if (params.pid !== undefined && params.pid !== snapshot.context.pid) throw new Error("本次桌面快照属于唤起输入框时的应用，不能读取后来切换的应用");
        if (!params.refresh && params.action === "context") {
          if (!Object.keys(snapshot.context).length) throw new Error(snapshot.contextError || "唤起输入框时未能采集应用上下文");
          return desktopResult({ ...snapshot.context, capturedAt: snapshot.capturedAt, frozen: true,
            ...(snapshot.contextError ? { warning: snapshot.contextError } : {}) });
        }
        if (!params.refresh) {
          if (!snapshot.image && params.action === "screenshot") throw new Error(snapshot.screenshotError || "唤起输入框时未能采集截图");
          return desktopResult({ ...snapshot, ...(snapshot.image ? { mode: snapshot.mode ?? "screen" } : {}), frozen: true });
        }
        if (typeof snapshot.context.targetId !== "string") throw new Error("唤起时未能固定原窗口，不能读取当前桌面");
      }
      if (!bridge) throw new Error("电脑操作需要连接 macOS 宿主");
      const arguments_: Record<string, unknown> = { ...params, background: params.background ?? true };
      delete arguments_.refresh;
      if (snapshot && (read || params.pid === undefined || params.pid === snapshot.context.pid) && params.action !== "capabilities") {
        if (typeof snapshot.context.targetId === "string") arguments_.targetId = snapshot.context.targetId;
        if (read) {
          arguments_.background = true;
          if (params.action !== "context") arguments_.mode = "window";
        }
      }
      if (snapshot && params.action !== "capabilities" && params.pid === undefined) {
        if (typeof snapshot.context.pid !== "number") throw new Error("唤起输入框时未能确定目标应用，不能操作当前应用");
        arguments_.pid = snapshot.context.pid;
      }
      const result = await bridge.request(arguments_, signal);
      return desktopResult(snapshot && read ? { ...result, invocationCapturedAt: snapshot.capturedAt, frozen: false } : result);
    },
  })];
}
