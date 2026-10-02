import { createInterface } from "node:readline";
import { configPathForDataDir, loadConfig } from "./config.ts";
import { encodeEvent } from "./events.ts";
import { AgentCore } from "./index.ts";
import type { SchedulerSignal, TriggerRule } from "./scheduler.ts";
import type { ProposalDecision } from "./state.ts";
import type { ContextResult } from "./proactive.ts";
import { DesktopBridge } from "./desktop-bridge.ts";
import { PiSdkBackend } from "./pi-adapter.ts";
import { ModelCommandHandler, type ModelCommand } from "./model-commands.ts";

interface StdioCommand extends ModelCommand {
  sources?: unknown;
  contextResult?: ContextResult;
  signal?: SchedulerSignal;
  now?: string;
  idleForMs?: number;
  rule?: TriggerRule;
  ruleId?: string;
  requestId?: string;
  readId?: string;
  conversationId?: string;
  action?: string;
  prompt?: string;
  suggestionId?: string;
  decision?: ProposalDecision;
  snoozeMinutes?: number;
  attachments?: unknown;
  allowForeground?: boolean;
  result?: unknown;
  error?: unknown;
}

function argumentValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

async function main(): Promise<void> {
  if (!process.argv.includes("--stdio")) throw new Error("当前只支持 --stdio JSON Lines 模式");
  const configPath = argumentValue("--config") ?? configPathForDataDir();
  const config = await loadConfig(configPath);
  const desktop = process.env.ANOTHER_YOU_DESKTOP_HOST === "1"
    ? new DesktopBridge(event => process.stdout.write(`${JSON.stringify(event)}\n`)) : undefined;
  const backend = new PiSdkBackend(config, desktop);
  await backend.initialize();
  const core = new AgentCore({ config, backend });
  const unsubscribe = core.events.subscribe((event) => process.stdout.write(encodeEvent(event)));
  const input = createInterface({ input: process.stdin, crlfDelay: Number.POSITIVE_INFINITY });
  let activeTask: Promise<void> | undefined;
  let closing = false;
  const finish = (): void => { closing = true; core.stop(); input.close(); };
  process.once("SIGTERM", finish);
  process.once("SIGINT", finish);
  const status = (): void => { core.events.emit({ kind: "agent.status", source: "system", payload: { configPath, ...core.status(false) } }); };
  const modelCommands = new ModelCommandHandler(backend, event => process.stdout.write(encodeEvent(event)), () => { if (!closing) status(); });
  const reportError = (command: StdioCommand | undefined, error: unknown): void => {
    core.events.emit({ kind: "agent.error", source: "system", payload: { ...(command?.requestId ? { requestId: command.requestId } : {}), ...(command?.readId ? { readId: command.readId } : {}), ...(command?.suggestionId ? { suggestionId: command.suggestionId } : {}), ...(command?.conversationId ? { conversationId: command.conversationId } : {}), message: error instanceof Error ? error.message : String(error) } });
  };
  const runModel = (command: StdioCommand, run: () => Promise<void>): void => {
    if (activeTask) throw new Error("模型正在处理另一条请求，请稍后重试");
    activeTask = run().catch((error) => reportError(command, error)).finally(() => {
      activeTask = undefined;
      if (!closing) status();
    });
  };
  core.start();
  status();
  try {
    for await (const line of input) {
      if (!line.trim()) continue;
      let command: StdioCommand | undefined;
      try {
        if (line.length > 4_000_000) throw new Error("命令超过最大长度");
        const value: unknown = JSON.parse(line);
        if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("命令必须是 JSON 对象");
        command = value as StdioCommand;
        const now = command.now === undefined ? undefined : new Date(command.now);
        if (now && !Number.isFinite(now.getTime())) throw new Error("now 必须是有效时间");
        if (modelCommands.handle(command)) continue;
        if (command.op === "signal" && command.signal) core.signal(command.signal, now);
        else if (command.op === "tick") core.tick(now, command.idleForMs);
        else if (command.op === "addRule" && command.rule) core.addRule(command.rule);
        else if (command.op === "removeRule" && command.ruleId) core.removeRule(command.ruleId);
        else if (command.op === "conversationRead" && command.conversationId && command.readId) core.readConversation(command.conversationId, command.readId);
        else if (command.op === "conversationAction" && command.conversationId && command.action) { core.manageConversation(command.conversationId, command.action); status(); }
        else if (command.op === "status") { await backend.reloadModelConfiguration(); status(); }
        else if (command.op === "contextCapabilities") { core.registerContextSources(command.sources); status(); }
        else if (command.op === "contextResult" && command.contextResult) core.receiveContext(command.contextResult);
        else if (command.op === "desktopResult" && desktop) desktop.receive(command);
        else if (command.op === "cancel") backend.abort();
        else if (command.op === "pause" || command.op === "resume") { core.setPaused(command.op === "pause"); status(); }
        else if (command.op === "prompt" && command.requestId && command.prompt) {
          const { requestId, prompt, attachments, allowForeground, conversationId } = command;
          runModel(command, () => core.prompt(requestId, prompt, attachments, allowForeground, conversationId));
        }
        else if (command.op === "decide" && command.suggestionId && command.decision) {
          const { suggestionId, decision, snoozeMinutes } = command;
          if (decision === "execute") runModel(command, () => core.decide(suggestionId, decision, snoozeMinutes));
          else await core.decide(suggestionId, decision, snoozeMinutes);
        }
        else if (command.op === "shutdown") break;
        else throw new Error("无法识别或缺少字段的命令");
      } catch (error) {
        reportError(command, error);
      }
    }
  } finally {
    finish();
    await modelCommands.close();
    await activeTask;
    await core.settleBackground();
    await backend.close();
    unsubscribe();
    process.removeListener("SIGTERM", finish);
    process.removeListener("SIGINT", finish);
  }
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 1;
});
