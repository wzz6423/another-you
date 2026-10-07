import { loadConfig, saveConfig } from "./config.ts";
import { createAgentEvent, type AgentEvent } from "./events.ts";
import type { AgentCore } from "./index.ts";
import { LocalModelBackend, parseLocalModelConfig } from "./local-model.ts";

export interface LocalModelCommand {
  op: string;
  requestId?: string;
  localModel?: unknown;
  workLookbackHours?: unknown;
}

export class LocalModelCommandHandler {
  private readonly core: AgentCore;
  private readonly configPath: string;
  private readonly emit: (event: AgentEvent) => void;
  private readonly onChange: () => void;
  private active?: { requestId: string; controller: AbortController; task: Promise<void> };

  constructor(core: AgentCore, configPath: string, emit: (event: AgentEvent) => void, onChange: () => void) {
    this.core = core; this.configPath = configPath; this.emit = emit; this.onChange = onChange;
  }

  handle(command: LocalModelCommand): boolean {
    if (!["localModelConfigure", "localModelModels", "localModelTest", "localModelCancel", "proactiveCheck", "proactiveConfigure"].includes(command.op)) return false;
    if (!command.requestId || typeof command.requestId !== "string" || command.requestId.length > 256) {
      this.operation(command, "failed", "本地模型操作缺少有效请求编号"); return true;
    }
    if (command.op === "localModelCancel") {
      if (this.active?.requestId === command.requestId) this.active.controller.abort();
      return true;
    }
    if (this.active) { this.operation(command, "failed", "本地模型操作正在进行"); return true; }
    const controller = new AbortController();
    const task = this.run(command, controller).finally(() => {
      this.active = undefined;
      this.onChange();
    });
    this.active = { requestId: command.requestId, controller, task };
    return true;
  }

  private async run(command: LocalModelCommand, controller: AbortController): Promise<void> {
    this.operation(command, "started");
    const timer = setTimeout(() => controller.abort(), 65_000);
    try {
      if (command.op === "proactiveCheck") {
        this.core.checkContextNow();
        this.operation(command, "succeeded", "已开始检查当前工作");
      } else if (command.op === "localModelModels") {
        const config = parseLocalModelConfig(command.localModel);
        const saved = this.core.config.proactive.localModel;
        if ((command.localModel as Record<string, unknown> | undefined)?.useSavedAPIKey === true && config.provider === saved.provider && config.baseUrl === saved.baseUrl) config.apiKey = saved.apiKey;
        const backend = new LocalModelBackend(config);
        const models = await backend.models(controller.signal);
        this.operation(command, "succeeded", models.length ? "已读取本地模型" : "本地服务尚未安装或加载模型", { models });
      } else await this.core.withLocalModelOperation(async () => {
        controller.signal.throwIfAborted();
        if (command.op === "proactiveConfigure") {
          if (![24, 168, 720].includes(command.workLookbackHours as number)) throw new Error("工作上下文回看范围只接受 24h、7d 或 30d");
          const hours = command.workLookbackHours as 24 | 168 | 720;
          const config = await loadConfig(this.configPath);
          config.proactive.workLookbackHours = hours;
          controller.signal.throwIfAborted();
          await saveConfig(config, this.configPath);
          this.core.config.proactive.workLookbackHours = hours;
          this.core.proactive.checkNow();
          this.operation(command, "succeeded", "工作上下文回看范围已保存", { workLookbackHours: hours });
        } else if (command.op === "localModelConfigure") {
          const localModel = parseLocalModelConfig(command.localModel);
          const previous = this.core.config.proactive.localModel;
          // 留空保留同一服务的令牌；切换地址时不能把旧令牌发给另一个服务。
          if (!localModel.apiKey && localModel.baseUrl === previous.baseUrl && localModel.provider === previous.provider) localModel.apiKey = previous.apiKey;
          const config = await loadConfig(this.configPath);
          config.proactive.localModel = localModel;
          controller.signal.throwIfAborted();
          await saveConfig(config, this.configPath);
          (this.core.localBackend as LocalModelBackend).configure(localModel);
          this.core.config.proactive.localModel = localModel;
          this.core.proactive.checkNow();
          this.operation(command, "succeeded", "本地模型配置已保存，尚未测试连接");
        } else {
          const response = await this.core.localBackend.run({ agentRole: "context-analyst", prompt: '只返回 JSON：{"ok":true}', signal: controller.signal,
            responseSchema: { type: "object", properties: { ok: { type: "boolean" } }, required: ["ok"], additionalProperties: false } });
          const parsed: unknown = JSON.parse(response.text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, ""));
          if (!parsed || typeof parsed !== "object" || (parsed as Record<string, unknown>).ok !== true) throw new Error("本地模型未返回要求的 JSON，请选择支持结构化输出的模型");
          this.operation(command, "succeeded", "本地连接成功");
        }
      });
    } catch (error) {
      this.operation(command, controller.signal.aborted ? "cancelled" : "failed", controller.signal.aborted ? "本地模型操作已取消" : error instanceof Error ? error.message : "本地模型操作失败");
    } finally { clearTimeout(timer); }
  }

  private operation(command: LocalModelCommand, state: string, message?: string, extra: Record<string, unknown> = {}): void {
    this.emit(createAgentEvent({ kind: "localModel.operation", source: "system", payload: {
      requestId: command.requestId, operation: command.op, state, ...(message ? { message } : {}), ...extra,
    } }));
  }

  async close(): Promise<void> { this.active?.controller.abort(); await this.active?.task; }
}
