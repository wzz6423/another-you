import { randomUUID } from "node:crypto";
import type { AuthEvent, AuthInteraction, AuthPrompt, AuthType } from "@earendil-works/pi-ai";
import { createAgentEvent, type AgentEvent } from "./events.ts";
import type { PiSdkBackend } from "./pi-adapter.ts";
import { hasExternalConfigurationValue } from "./model-configuration.ts";
import { redactSecrets } from "./state.ts";

export interface ModelCommand {
  op: string;
  requestId?: string;
  provider?: string;
  model?: string;
  thinkingLevel?: string;
  authType?: AuthType;
  promptId?: string;
  value?: string;
  path?: string;
  refresh?: boolean;
}

interface PendingPrompt {
  id: string;
  prompt: AuthPrompt;
  resolve(value: string): void;
}

const OPERATIONS = new Set(["modelCatalog", "modelSelect", "modelLogin", "modelLogout", "modelImport", "modelAuthReply", "modelAuthCancel"]);

function required(value: unknown, field: string): string {
  if (typeof value !== "string" || !value.trim() || value.length > 8192) throw new Error(`${field} 无效`);
  return value;
}

export class ModelCommandHandler {
  private readonly backend: PiSdkBackend;
  private readonly emit: (event: AgentEvent) => void;
  private readonly onChange: () => void;
  private active?: { requestId: string; op: string; provider?: string; abort: AbortController; task: Promise<void> };
  private prompt?: PendingPrompt;
  private secrets = new Set<string>();

  constructor(backend: PiSdkBackend, emit: (event: AgentEvent) => void, onChange: () => void = () => {}) {
    this.backend = backend;
    this.emit = emit;
    this.onChange = onChange;
  }

  handle(command: ModelCommand): boolean {
    if (!OPERATIONS.has(command.op)) return false;
    try {
      const requestId = required(command.requestId, "requestId");
      if (command.op === "modelAuthReply") {
        if (this.active?.requestId !== requestId || !this.prompt || command.promptId !== this.prompt.id) throw new Error("认证输入已失效");
        const value = required(command.value, "认证输入");
        if (this.prompt.prompt.type === "select" && !this.prompt.prompt.options.some(option => option.id === value)) throw new Error("请选择有效选项");
        if (this.prompt.prompt.type === "secret" && hasExternalConfigurationValue(value)) throw new Error("请输入凭据本身，不能使用环境变量或命令");
        if (this.prompt.prompt.type !== "select") this.secrets.add(value);
        this.prompt.resolve(value);
      } else if (command.op === "modelAuthCancel") {
        if (this.active?.requestId !== requestId) throw new Error("认证操作已结束");
        this.active.abort.abort();
      } else if (command.op === "modelCatalog" && command.refresh !== true) {
        this.catalog(requestId);
      } else {
        if (this.active || this.backend.isBusy) throw new Error("模型正在处理请求，请完成或取消后再修改配置");
        const abort = new AbortController();
        const provider = command.provider === undefined ? undefined : required(command.provider, "provider");
        const task = this.run(command, requestId, abort).finally(() => {
          if (this.active?.requestId === requestId) this.active = undefined;
          this.prompt = undefined;
          this.secrets.clear();
          this.onChange();
        });
        this.active = { requestId, op: command.op, provider, abort, task };
      }
    } catch (error) { this.operation(command, "failed", this.safeError(error)); }
    return true;
  }

  private async run(command: ModelCommand, requestId: string, abort: AbortController): Promise<void> {
    const timeout = setTimeout(() => abort.abort(), command.op === "modelLogin" ? 10 * 60_000 : 20_000);
    this.operation(command, "started");
    try {
      await this.backend.changeModelConfiguration(async () => {
        const configuration = this.backend.modelConfiguration;
        if (command.op === "modelSelect") {
          await configuration.select(required(command.provider, "provider"), required(command.model, "model"), command.thinkingLevel);
        } else if (command.op === "modelLogin") {
          if (command.authType !== "api_key" && command.authType !== "oauth") throw new Error("请选择有效登录方式");
          const provider = required(command.provider, "provider");
          const interaction: AuthInteraction = {
            signal: abort.signal,
            prompt: prompt => this.requestPrompt(requestId, provider, prompt, abort.signal),
            notify: event => this.notify(requestId, provider, event),
          };
          await configuration.login(provider, command.authType, interaction);
        } else if (command.op === "modelLogout") {
          await configuration.logout(required(command.provider, "provider"));
        } else if (command.op === "modelImport") {
          await configuration.importConfiguration(required(command.path, "path"));
        } else if (command.op === "modelCatalog") {
          await configuration.refreshCatalog(abort.signal);
        }
      });
      this.operation(command, "succeeded", command.op === "modelImport"
        ? "模型配置已导入，认证信息未复制"
        : command.op === "modelLogout" ? "账户已注销" : "配置已保存，发送请求后验证连接");
      this.catalog(requestId);
    } catch (error) {
      this.operation(command, abort.signal.aborted ? "cancelled" : "failed",
        abort.signal.aborted ? "操作已取消" : this.safeError(error));
      this.catalog(requestId);
    } finally { clearTimeout(timeout); }
  }

  private requestPrompt(requestId: string, provider: string, prompt: AuthPrompt, signal: AbortSignal): Promise<string> {
    const combined = prompt.signal ? AbortSignal.any([signal, prompt.signal]) : signal;
    combined.throwIfAborted();
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const finish = (): void => { combined.removeEventListener("abort", cancel); if (this.prompt?.id === id) this.prompt = undefined; };
      const cancel = (): void => {
        finish();
        this.auth({ requestId, provider, stage: "promptCancelled", promptId: id });
        reject(new Error("认证输入已取消"));
      };
      this.prompt = { id, prompt, resolve: value => {
        finish();
        this.auth({ requestId, provider, stage: "promptResolved", promptId: id });
        resolve(value);
      } };
      combined.addEventListener("abort", cancel, { once: true });
      const { signal: _signal, ...fields } = prompt;
      this.auth({ requestId, provider, stage: "prompt", prompt: { ...fields, id } });
      if (combined.aborted) cancel();
    });
  }

  private notify(requestId: string, provider: string, notice: AuthEvent): void {
    this.auth({ requestId, provider, stage: "notify", notice });
  }

  private auth(payload: Record<string, unknown>): void {
    // 认证交互只进传输通道，不进入 EventBus、会话或状态历史。
    this.emit(createAgentEvent({ kind: "model.auth", source: "system", payload }));
  }

  private catalog(requestId: string): void {
    this.emit(createAgentEvent({ kind: "model.catalog", source: "system", payload: { requestId, ...this.backend.modelConfiguration.snapshot } }));
  }

  private operation(command: ModelCommand, state: string, message?: string): void {
    this.emit(createAgentEvent({ kind: "model.operation", source: "system", payload: {
      requestId: command.requestId ?? "", operation: command.op, state,
      ...(command.provider ? { provider: command.provider } : {}), ...(message ? { message } : {}),
    } }));
  }

  private safeError(error: unknown): string {
    let message = error instanceof Error ? error.message : "模型配置操作失败";
    for (const secret of this.secrets) if (secret) message = message.split(secret).join("[已隐藏]");
    return redactSecrets(message).slice(0, 500);
  }

  async close(): Promise<void> {
    this.active?.abort.abort();
    await this.active?.task;
  }
}
