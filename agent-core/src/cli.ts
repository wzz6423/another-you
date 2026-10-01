import { createInterface } from "node:readline";
import { configPathForDataDir, loadConfig } from "./config.ts";
import { encodeEvent } from "./events.ts";
import { AgentCore } from "./index.ts";
import type { SchedulerSignal, TriggerRule } from "./scheduler.ts";

interface StdioCommand {
  op: "signal" | "tick" | "addRule" | "removeRule" | "status" | "shutdown";
  signal?: SchedulerSignal;
  now?: string;
  idleForMs?: number;
  rule?: TriggerRule;
  ruleId?: string;
}

function argumentValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function writeError(core: AgentCore, message: string): void {
  const event = core.events.emit({ kind: "agent.error", source: "system", payload: { message } });
  process.stdout.write(encodeEvent(event));
}

async function main(): Promise<void> {
  if (!process.argv.includes("--stdio")) {
    throw new Error("当前只支持 --stdio JSON Lines 模式");
  }
  const configPath = argumentValue("--config") ?? configPathForDataDir();
  const config = await loadConfig(configPath);
  const core = new AgentCore({ config });
  const unsubscribe = core.events.subscribe((event) => process.stdout.write(encodeEvent(event)));
  const input = createInterface({ input: process.stdin, crlfDelay: Number.POSITIVE_INFINITY });

  const finish = (): void => {
    unsubscribe();
    core.stop();
    input.close();
  };

  for await (const line of input) {
    if (!line.trim()) continue;
    try {
      const command = JSON.parse(line) as StdioCommand;
      if (command.op === "signal" && command.signal) {
        core.signal(command.signal, command.now ? new Date(command.now) : undefined);
      } else if (command.op === "tick") {
        core.tick(command.now ? new Date(command.now) : undefined, command.idleForMs);
      } else if (command.op === "addRule" && command.rule) {
        core.scheduler.addRule(command.rule);
      } else if (command.op === "removeRule" && command.ruleId) {
        core.scheduler.removeRule(command.ruleId);
      } else if (command.op === "status") {
        core.events.emit({
          kind: "agent.status",
          source: "system",
          payload: { configPath, rules: core.scheduler.listRules(), schedulerEnabled: config.scheduler.enabled },
        });
      } else if (command.op === "shutdown") {
        finish();
        break;
      } else {
        writeError(core, "无法识别或缺少字段的命令");
      }
    } catch (error) {
      writeError(core, error instanceof Error ? error.message : String(error));
    }
  }
  finish();
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 1;
});
