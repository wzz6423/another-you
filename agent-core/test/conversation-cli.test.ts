import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import test from "node:test";
import { createDefaultConfig, saveConfig } from "../src/config.ts";
import type { AgentEvent } from "../src/events.ts";
import { writePiFixture } from "./pi-fixture.ts";

test("真实 JSONL 与 Pi 会话闭环：历史入模、分类工具日志、归档错误、重启与删除", async t => {
  const directory = await mkdtemp(join(tmpdir(), "another-you-conversation-cli-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const requests: Record<string, unknown>[] = [];
  const server = createServer(async (req, res) => {
    let body = "";
    for await (const part of req) body += part;
    requests.push(JSON.parse(body));
    const chunk = (delta: object, finish: string | null = null) => `data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", model: "fixture", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
    res.writeHead(200, { "content-type": "text/event-stream" });
    if (requests.length === 1) {
      res.end(chunk({ role: "assistant", reasoning_content: "fixture reasoning" }) + chunk({ tool_calls: [{ index: 0, id: "shell-fixture", type: "function", function: { name: "shell", arguments: JSON.stringify({ command: "printf fixture", cwd: directory }) } }] }, "tool_calls") + "data: [DONE]\n\n");
    } else res.end(chunk({ role: "assistant", content: "会话 fixture 回复" }, "stop") + "data: [DONE]\n\n");
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(async () => { server.closeAllConnections(); await new Promise<void>(done => server.close(() => done())); });
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const piDirectory = await writePiFixture(directory, `http://127.0.0.1:${address.port}/v1`, "high");
  const config = createDefaultConfig(directory);
  config.scheduler.enabled = false;
  config.proactive.enabled = false;
  const path = join(directory, "config.json");
  await saveConfig(config, path);

  async function launch() {
    const child = spawn(process.execPath, ["--experimental-strip-types", resolve("src/cli.ts"), "--stdio", "--config", path],
      { stdio: "pipe", env: { ...process.env, ANOTHER_YOU_PI_DIR: piDirectory } });
    const lines = createInterface({ input: child.stdout });
    const events: AgentEvent[] = [];
    let stderr = "";
    child.stderr.on("data", part => { stderr += String(part); });
    lines.on("line", line => events.push(JSON.parse(line)));
    const exited = once(child, "exit");
    t.after(async () => { if (child.exitCode === null) { child.kill("SIGTERM"); await exited; } lines.close(); });
    const send = (command: Record<string, unknown>) => child.stdin.write(`${JSON.stringify(command)}\n`);
    async function wait(kind: string, predicate: (event: AgentEvent) => boolean = () => true, after = 0): Promise<AgentEvent> {
      for (let attempt = 0; attempt < 1000; attempt++) {
        const event = events.slice(after).find(event => event.kind === kind && predicate(event));
        if (event) return event;
        if (child.exitCode !== null) throw new Error(`sidecar exited: ${stderr}`);
        await new Promise(resolve => setTimeout(resolve, 10));
      }
      throw new Error(`timeout ${kind}: ${stderr}`);
    }
    const status = await wait("agent.status");
    return { send, wait, events, status, close: async () => { send({ op: "shutdown" }); await exited; } };
  }
  const first = await launch();
  first.send({ op: "prompt", requestId: "one", conversationId: "session-a", prompt: "会话 A 独有输入" });
  await first.wait("agent.response");
  await first.wait("conversation.updated", event => (event.payload.conversations as { state: string }[])[0]?.state === "completed");
  assert.ok(first.events.some(event => event.kind === "agent.activity" && event.payload.category === "command" && event.payload.phase === "completed"));
  assert.ok(first.events.some(event => event.kind === "agent.activity" && event.payload.category === "thinking"));
  assert.equal(JSON.stringify(first.events).includes("fixture reasoning"), false);
  first.send({ op: "conversationAction", conversationId: "session-a", action: "archive" });
  await first.wait("conversation.updated", event => event.payload.action === "archive");
  first.send({ op: "prompt", requestId: "blocked", conversationId: "session-a", prompt: "不应执行" });
  await first.wait("agent.error", event => event.payload.conversationId === "session-a");
  await first.close();

  const restored = await launch();
  assert.equal((restored.status.payload.conversations as { archived: boolean }[])[0].archived, true);
  assert.equal((restored.status.payload.conversations as { messages?: unknown }[])[0].messages, undefined);
  restored.send({ op: "conversationRead", conversationId: "session-a", readId: "read-restored" });
  const loaded = await restored.wait("conversation.messages", event => event.payload.readId === "read-restored");
  assert.match(JSON.stringify(loaded.payload.conversation), /会话 A 独有输入/);
  restored.send({ op: "conversationAction", conversationId: "session-a", action: "unarchive" });
  await restored.wait("conversation.updated", event => event.payload.action === "unarchive");
  restored.send({ op: "prompt", requestId: "two", conversationId: "session-a", prompt: "继续 A" });
  await restored.wait("agent.response", event => event.payload.requestId === "two");
  assert.match(JSON.stringify(requests.at(-1)?.messages), /会话 A 独有输入/);
  const after = restored.events.length;
  restored.send({ op: "prompt", requestId: "three", conversationId: "session-b", prompt: "会话 B" });
  await restored.wait("agent.response", event => event.payload.requestId === "three", after);
  assert.equal(JSON.stringify(requests.at(-1)?.messages).includes("会话 A 独有输入"), false);
  restored.send({ op: "conversationAction", conversationId: "session-a", action: "delete" });
  await restored.wait("conversation.updated", event => event.payload.action === "delete");
  await restored.close();
  const deleted = await launch();
  assert.deepEqual((deleted.status.payload.conversations as { id: string }[]).map(session => session.id), ["session-b"]);
  await deleted.close();
});
