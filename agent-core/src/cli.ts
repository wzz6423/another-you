import { createInterface } from "node:readline";
import { configPathForDataDir, loadConfig } from "./config.ts";
import { encodeEvent } from "./events.ts";
import { AgentCore } from "./index.ts";
import type { SchedulerSignal, TriggerRule } from "./scheduler.ts";
import type { ProposalDecision } from "./state.ts";

interface StdioCommand {
  op: string;
  signal?: SchedulerSignal;
  now?: string;
  idleForMs?: number;
  rule?: TriggerRule;
  ruleId?: string;
  requestId?: string;
  prompt?: string;
  suggestionId?: string;
  decision?: ProposalDecision;
  snoozeMinutes?: number;
}

function argumentValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

async function main(): Promise<void> {
  if (!process.argv.includes("--stdio")) throw new Error("当前只支持 --stdio JSON Lines 模式");
  const configPath = argumentValue("--config") ?? configPathForDataDir();
  const config = await loadConfig(configPath);
  const core = new AgentCore({ config });
  const unsubscribe = core.events.subscribe((event) => process.stdout.write(encodeEvent(event)));
  const input = createInterface({ input: process.stdin, crlfDelay: Number.POSITIVE_INFINITY });
  let activeTask: Promise<void> | undefined;
  let closing = false;
  const finish = (): void => { closing = true; core.stop(); input.close(); };
  process.once("SIGTERM", finish);
  process.once("SIGINT", finish);
  const status = (): void => { core.events.emit({ kind: "agent.status", source: "system", payload: { configPath, ...core.status() } }); };
  const reportError = (command: StdioCommand | undefined, error: unknown): void => {
    core.events.emit({ kind: "agent.error", source: "system", payload: { ...(command?.requestId ? { requestId: command.requestId } : {}), ...(command?.suggestionId ? { suggestionId: command.suggestionId } : {}), message: error instanceof Error ? error.message : String(error) } });
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
        if (line.length > 1_000_000) throw new Error("命令超过最大长度");
        const value: unknown = JSON.parse(line);
        if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("命令必须是 JSON 对象");
        command = value as StdioCommand;
        const now = command.now === undefined ? undefined : new Date(command.now);
        if (now && !Number.isFinite(now.getTime())) throw new Error("now 必须是有效时间");
        if (command.op === "signal" && command.signal) core.signal(command.signal, now);
        else if (command.op === "tick") core.tick(now, command.idleForMs);
        else if (command.op === "addRule" && command.rule) core.addRule(command.rule);
        else if (command.op === "removeRule" && command.ruleId) core.removeRule(command.ruleId);
        else if (command.op === "status") status();
        else if (command.op === "pause" || command.op === "resume") { core.setPaused(command.op === "pause"); status(); }
        else if (command.op === "prompt" && command.requestId && command.prompt) {
          const { requestId, prompt } = command;
          runModel(command, () => core.prompt(requestId, prompt));
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
    await activeTask;
    unsubscribe();
    process.removeListener("SIGTERM", finish);
    process.removeListener("SIGINT", finish);
  }
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 1;
});
