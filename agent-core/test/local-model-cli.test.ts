import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import test from "node:test";
import { createDefaultConfig } from "../src/config.ts";
import type { AgentEvent } from "../src/events.ts";

test("真实 sidecar JSONL：本地配置、连接测试、主动分析生成可读取会话和关联用量", async t => {
  const directory = await mkdtemp(join(tmpdir(), "another-you-local-cli-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const requests: { url: string; body: Record<string, unknown> }[] = [];
  const server = createServer(async (request, response) => {
    let content = "";
    for await (const chunk of request) content += chunk;
    const body = content ? JSON.parse(content) : {};
    requests.push({ url: request.url!, body });
    if (request.url === "/api/tags") { response.end(JSON.stringify({ models: [{ name: "fixture-local" }] })); return; }
    const prompt = JSON.stringify(body.messages);
    const result = prompt.includes("汇总新的")
      ? { suggest: true, title: "整理构建错误", message: "终端报告类型错误", reason: "构建受阻", sources: ["work"], draft: "先核对报错中的参数类型，再重新构建验证。" }
      : prompt.includes("ok") ? { ok: true } : { summary: "构建出现类型错误", actionable: true, evidence: ["编译器报告类型不匹配"] };
    response.setHeader("x-request-id", "local-cli-request");
    response.end(JSON.stringify({ model: "fixture-local", message: { content: JSON.stringify(result) }, prompt_eval_count: 18, eval_count: 12 }));
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  t.after(async () => { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); });
  const address = server.address(); assert.ok(address && typeof address !== "string");
  const config = createDefaultConfig(directory);
  config.scheduler.pollIntervalMs = 100; config.proactive.taskSpacingMs = 1000;
  const configPath = join(directory, "config.json");
  await writeFile(configPath, JSON.stringify({ ...config, proactive: { ...config.proactive, allowRemoteEscalation: false, autoDraft: false } }));
  const child = spawn(process.execPath, ["--experimental-strip-types", resolve("src/cli.ts"), "--stdio", "--config", configPath], { stdio: "pipe" });
  const exited = once(child, "exit");
  const lines = createInterface({ input: child.stdout });
  const events: AgentEvent[] = [];
  let stderr = "";
  child.stderr.on("data", value => { stderr += String(value); });
  const send = (command: Record<string, unknown>) => child.stdin.write(JSON.stringify(command) + "\n");
  lines.on("line", line => {
    const event = JSON.parse(line) as AgentEvent; events.push(event);
    if (event.kind === "context.request") send({ op: "contextResult", contextResult: { requestId: event.payload.requestId, source: "work", status: "ok",
      content: { appName: "Terminal", bundleId: "com.apple.Terminal", windowTitle: "fixture build", text: "编译器报告类型不匹配" } } });
  });
  t.after(async () => { if (child.exitCode === null) { child.kill("SIGTERM"); await exited; } lines.close(); });
  async function wait(kind: string, predicate: (event: AgentEvent) => boolean = () => true) {
    for (let attempt = 0; attempt < 1200; attempt++) {
      const event = events.find(value => value.kind === kind && predicate(value));
      if (event) return event;
      if (child.exitCode !== null) throw new Error(`sidecar exited: ${stderr}`);
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    throw new Error(`timeout ${kind}: ${stderr}`);
  }
  await wait("agent.status");
  for (const hours of [24, 168, 720]) {
    send({ op: "proactiveConfigure", requestId: `lookback-${hours}`, workLookbackHours: hours });
    const operation = await wait("localModel.operation", event => event.payload.requestId === `lookback-${hours}` && event.payload.state === "succeeded");
    assert.equal(operation.payload.workLookbackHours, hours);
    assert.equal(JSON.parse(await readFile(configPath, "utf8")).proactive.workLookbackHours, hours);
    await wait("agent.status", event => (event.payload.localModel as Record<string, unknown>)?.workLookbackHours === hours);
  }
  send({ op: "proactiveConfigure", requestId: "lookback-invalid", workLookbackHours: 48 });
  await wait("localModel.operation", event => event.payload.requestId === "lookback-invalid" && event.payload.state === "failed");
  assert.equal(JSON.parse(await readFile(configPath, "utf8")).proactive.workLookbackHours, 720);
  send({ op: "localModelConfigure", requestId: "configure", localModel: { provider: "ollama", baseUrl: `http://127.0.0.1:${address.port}`, model: "fixture-local" } });
  await wait("localModel.operation", event => event.payload.requestId === "configure" && event.payload.state === "succeeded");
  const saved = JSON.parse(await readFile(configPath, "utf8"));
  assert.equal(Object.hasOwn(saved.proactive, "allowRemoteEscalation"), false);
  assert.equal(Object.hasOwn(saved.proactive, "autoDraft"), false);
  send({ op: "localModelTest", requestId: "test" });
  await wait("localModel.operation", event => event.payload.requestId === "test" && event.payload.state === "succeeded");
  send({ op: "contextCapabilities", sources: ["work"] });
  const suggestion = await wait("proactive.suggestion");
  assert.ok(events.filter(event => event.kind === "context.request").every(event => event.payload.lookbackHours === 720));
  assert.equal(suggestion.payload.state, "completed");
  assert.equal(suggestion.payload.route, "local");
  assert.ok(suggestion.payload.conversationId);
  send({ op: "conversationRead", conversationId: suggestion.payload.conversationId, readId: "read" });
  const conversation = await wait("conversation.messages");
  assert.match(JSON.stringify(conversation.payload.conversation), /先核对报错中的参数类型/);
  const usage = events.filter(event => event.kind === "agent.usage");
  assert.equal(usage.length, 2);
  for (const event of usage) {
    assert.equal(event.payload.route, "local");
    assert.equal(event.payload.appName, "Terminal");
    assert.equal(event.payload.upstreamRequestId, "local-cli-request");
    assert.ok(events.some(row => row.kind === "agent.activity" && row.payload.runId === event.payload.runId && row.payload.phase === "completed"));
  }
  assert.ok(requests.every(request => request.url === "/api/chat"));
  assert.equal(requests.length, 3);
  send({ op: "shutdown" }); await exited;
  assert.equal(child.exitCode, 0);
});
