import { strict as assert } from "node:assert";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { createAgentEvent, encodeEvent, AgentCore, createDefaultConfig, type AgentEvent, type ConversationSession, type PiAgentBackend, type PiRequest } from "../src/index.ts";

async function fixture(t: TestContext, run: (request: PiRequest) => Promise<{ text: string }> = async () => ({ text: "回答" })) {
  const directory = await mkdtemp(join(tmpdir(), "another-you-conversations-"));
  t.after(() => rm(directory, { force: true, recursive: true }));
  const config = createDefaultConfig(directory);
  const backend: PiAgentBackend = { source: { repository: "fixture", ref: "fixture", commit: "fixture" }, run };
  return { config, backend, directory, core: new AgentCore({ config, backend, rules: [] }) };
}
function sessions(core: AgentCore): ConversationSession[] { return core.status().conversations as ConversationSession[]; }

test("会话完成、恢复、归档、取消归档与删除跨重启保持，操作输出回执", async t => {
  const { core, config, backend } = await fixture(t);
  const events: AgentEvent[] = [];
  core.events.subscribe(event => events.push(event));
  await core.prompt("a", "第一条消息", undefined, false, "session-a");
  assert.equal(sessions(core)[0].state, "completed");
  assert.equal(sessions(core)[0].messages[0].response, "回答");
  core.manageConversation("session-a", "archive");
  assert.equal(events.at(-1)?.payload.action, "archive");
  const restored = new AgentCore({ config, backend, rules: [] });
  assert.equal(sessions(restored)[0].archived, true);
  await assert.rejects(restored.prompt("b", "不能发到归档会话", undefined, false, "session-a"), /归档/);
  restored.manageConversation("session-a", "unarchive");
  assert.equal(sessions(restored)[0].archived, false);
  restored.manageConversation("session-a", "delete");
  const final = new AgentCore({ config, backend, rules: [] });
  assert.equal(sessions(final).length, 0);
  assert.equal((final.status().history as AgentEvent[]).some(event => event.payload.conversationId === "session-a"), false);
});

test("独立会话不会串上下文，续聊包含自己的成功轮次", async t => {
  const contexts: unknown[] = [];
  const { core } = await fixture(t, async request => { contexts.push(request.context?.conversation); return { text: `回复 ${request.prompt}` }; });
  await core.prompt("a1", "会话 A", undefined, false, "a");
  await core.prompt("b1", "会话 B", undefined, false, "b");
  await core.prompt("a2", "继续 A", undefined, false, "a");
  assert.deepEqual(contexts[0], []);
  assert.deepEqual(contexts[1], []);
  assert.deepEqual(contexts[2], [{ role: "user", content: "会话 A" }, { role: "assistant", content: "回复 会话 A" }]);
});

test("运行中会话拒绝归档删除；失败状态与中断恢复不会伪装完成", async t => {
  let reject!: (error: Error) => void;
  const { core, config, backend, directory } = await fixture(t, async () => new Promise((_resolve, fail) => { reject = fail; }));
  const running = core.prompt("pending", "测试", undefined, false, "session");
  while (!reject) await new Promise(resolve => setImmediate(resolve));
  assert.throws(() => core.manageConversation("session", "archive"), /停止/);
  assert.throws(() => core.manageConversation("session", "delete"), /停止/);
  assert.equal(sessions(core)[0].state, "running");
  const interrupted = new AgentCore({ config, backend, rules: [] });
  assert.equal(sessions(interrupted)[0].state, "failed");
  assert.match(sessions(interrupted)[0].messages[0].error!, /中断/);
  reject(new Error("fixture failed"));
  await running;
  assert.equal(sessions(core)[0].state, "failed");
  assert.equal(sessions(core)[0].messages[0].error, "fixture failed");
  const disk = JSON.parse(await readFile(join(directory, "state.json"), "utf8"));
  assert.equal(disk.conversations[0].state, "failed");
});

test("应用分组从实际截图上下文读取且图片不写状态，隐私关闭同时去除消息和标题", async t => {
  const { core, config, backend, directory } = await fixture(t);
  const attachment = { mimeType: "image/jpeg", data: "/9j/", context: { appName: "Fixture App", text: "private screenshot context" } };
  await core.prompt("image", "私人消息内容", [attachment], false, "snapshot");
  assert.equal(sessions(core)[0].appName, "Fixture App");
  let disk = await readFile(join(directory, "state.json"), "utf8");
  assert.equal(disk.includes("/9j/"), false);
  assert.equal(disk.includes("private screenshot context"), false);
  config.privacy.storePrompts = false;
  config.privacy.storeResponses = false;
  const privateCore = new AgentCore({ config, backend, rules: [] });
  await privateCore.prompt("image2", "第二条私人消息", [attachment], false, "snapshot2");
  disk = await readFile(join(directory, "state.json"), "utf8");
  for (const content of ["私人消息内容", "第二条私人消息", "Fixture App", '"response": "回答"']) assert.equal(disk.includes(content), false);
  const restored = new AgentCore({ config, backend, rules: [] });
  assert.equal(sessions(restored).length, 2);
  assert.equal(sessions(restored)[0].messages[0].response, "回复内容未保存");
});

test("分类日志逐条接收真实执行回调并跨重启保持", async t => {
  const { core, config, backend } = await fixture(t, async request => {
    request.onActivity?.({ category: "thinking", phase: "started" });
    request.onActivity?.({ category: "thinking", phase: "completed" });
    request.onActivity?.({ category: "command", phase: "started", toolName: "shell" });
    request.onActivity?.({ category: "command", phase: "completed", toolName: "shell" });
    request.onActivity?.({ category: "context", phase: "started", toolName: "computer_use" });
    return { text: "完成" };
  });
  await core.prompt("logs", "测试日志");
  const logs = (new AgentCore({ config, backend, rules: [] }).status().history as AgentEvent[]).filter(event => event.kind === "agent.activity");
  assert.equal(logs.length, 7);
  assert.deepEqual(logs.map(event => event.payload.category), ["execution", "thinking", "thinking", "command", "command", "context", "execution"]);
  assert.equal(logs.every(event => event.payload.text === undefined && event.payload.arguments === undefined), true);
  assert.equal(logs.every(event => event.payload.conversationId === "default" && event.payload.requestId === "logs"), true);
});

test("主动建议也可归档删除，归档后的稍后提醒不重新出现", async t => {
  const { core, config, backend } = await fixture(t);
  core.addRule({ id: "rule", type: "event", eventName: "fixture", title: "建议", message: "待执行", cooldownMs: 0 });
  const suggestion = core.signal({ type: "event", name: "fixture" })[0];
  await core.decide(suggestion.id, "later", 1);
  core.manageConversation(suggestion.id, "archive");
  assert.equal(core.tick(new Date(Date.now() + 120_000)).length, 0);
  const restored = new AgentCore({ config, backend, rules: [] });
  assert.equal((restored.status().proposals as { archived: boolean }[])[0].archived, true);
  core.manageConversation(suggestion.id, "delete");
  assert.deepEqual(core.status().proposals, []);
  assert.throws(() => core.manageConversation(suggestion.id, "delete"), /找不到/);
});


test("保存失败不确认归档，也不让内存状态假装成功", async t => {
  const { core, directory } = await fixture(t);
  await core.prompt("save", "保留会话", undefined, false, "session");
  const path = join(directory, "state.json");
  const original = await readFile(path);
  await rm(path);
  await mkdir(path);
  const events: AgentEvent[] = [];
  core.events.subscribe(event => events.push(event));
  assert.throws(() => core.manageConversation("session", "archive"));
  assert.equal(sessions(core)[0].archived, false);
  assert.equal(events.length, 0);
  await rm(path, { recursive: true });
  await writeFile(path, original);
});


test("大历史状态仅发送摘要，按需读取不丢内容，也不重复记入日志", async t => {
  const response = "🧪会话边界".repeat(60_000);
  const { core } = await fixture(t, async () => ({ text: response }));
  await core.prompt("large-a", "大历史 A", undefined, false, "a");
  await core.prompt("large-b", "大历史 B", undefined, false, "b");
  const status = core.status(false);
  assert.equal((status.conversations as { messages?: unknown }[]).every(session => session.messages === undefined), true);
  const events: AgentEvent[] = [];
  core.events.subscribe(event => events.push(event));
  const historySize = (core.status().history as AgentEvent[]).length;
  core.readConversation("a", "read-a");
  assert.equal(events.length, 1);
  assert.equal(events[0].kind, "conversation.messages");
  const restored = events[0].payload.conversation as ConversationSession;
  assert.equal(restored.messages[0].response, response);
  assert.equal((core.status().history as AgentEvent[]).length, historySize);
});


test("超过四 MiB 的事件使用有序传输帧且保留完整 UTF8 内容", () => {
  const event = createAgentEvent({ kind: "agent.status", source: "system", payload: { text: "边界🧪".repeat(600_000) } });
  const frames = encodeEvent(event).trim().split("\n").map(line => JSON.parse(line) as AgentEvent);
  assert.ok(frames.length > 1);
  assert.equal(frames.every(frame => frame.kind === "protocol.chunk" && Buffer.byteLength(JSON.stringify(frame)) < 4 * 1024 * 1024), true);
  assert.deepEqual(frames.map(frame => frame.payload.index), frames.map((_frame, index) => index));
  const bytes = Buffer.concat(frames.map(frame => Buffer.from(String(frame.payload.data), "base64")));
  assert.deepEqual(JSON.parse(bytes.toString("utf8")), event);
});


test("第 101 轮后完整历史仍持久化并可读取，模型上下文只取最近 20 轮", async t => {
  let context: { role: string; content: string }[] = [];
  const { core, config, backend, directory } = await fixture(t, async request => {
    context = request.context?.conversation as typeof context;
    return { text: `回复 ${request.prompt}` };
  });
  for (let index = 1; index <= 101; index++) await core.prompt(`turn-${index}`, `消息 ${index}`, undefined, false, "long-session");
  assert.equal(sessions(core)[0].messages.length, 101);
  assert.equal(sessions(core)[0].messages[0].prompt, "消息 1");
  assert.equal(context.length, 40);
  assert.equal(context[0].content, "消息 81");
  assert.equal(context.at(-1)?.content, "回复 消息 100");
  const disk = JSON.parse(await readFile(join(directory, "state.json"), "utf8")) as { conversations: ConversationSession[] };
  assert.equal(disk.conversations[0].messages.length, 101);
  const restored = new AgentCore({ config, backend, rules: [] });
  let loaded: ConversationSession | undefined;
  restored.events.subscribe(event => { if (event.kind === "conversation.messages") loaded = event.payload.conversation as ConversationSession; });
  restored.readConversation("long-session", "read-long");
  assert.equal(loaded?.messages.length, 101);
  assert.equal(loaded?.messages[0].prompt, "消息 1");
  assert.equal(loaded?.messages.at(-1)?.response, "回复 消息 101");
  restored.forkConversation("long-session", "fork-all");
  assert.equal(sessions(restored).at(-1)?.messages.length, 101);
});

test("逐轮分支复制完整前缀，源会话不变，不重复计费且重启后独立续聊", async t => {
  let context: unknown;
  const { core, config, backend } = await fixture(t, async request => {
    context = request.context?.conversation;
    return { text: `回复 ${request.prompt}` };
  });
  await core.prompt("one", "第一轮", undefined, false, "source");
  await core.prompt("two", "第二轮", undefined, false, "source");
  const source = structuredClone(sessions(core)[0]);
  const usage = core.status().usageRecords;
  const history = core.status().history;
  const events: AgentEvent[] = [];
  core.events.subscribe(event => events.push(event));
  core.forkConversation("source", "fork-request", "one");
  const receipt = events.at(-1)!;
  assert.equal(receipt.kind, "conversation.updated");
  assert.equal(receipt.payload.action, "fork");
  assert.equal(receipt.payload.sourceConversationId, "source");
  assert.equal(receipt.payload.requestId, "fork-request");
  const id = receipt.payload.conversationId as string;
  assert.notEqual(id, "source");
  assert.deepEqual(sessions(core)[0], source);
  assert.deepEqual(core.status().usageRecords, usage);
  assert.deepEqual(core.status().history, history);
  const restored = new AgentCore({ config, backend, rules: [] });
  const fork = sessions(restored).find(session => session.id === id)!;
  assert.deepEqual(fork.forkedFrom, { conversationId: "source", messageId: "one" });
  assert.deepEqual(fork.messages, source.messages.slice(0, 1));
  await restored.prompt("branch-turn", "分支新输入", undefined, false, id);
  assert.deepEqual(context, [{ role: "user", content: "第一轮" }, { role: "assistant", content: "回复 第一轮" }]);
  assert.deepEqual(sessions(restored).find(session => session.id === "source"), source);
  assert.equal(sessions(restored).find(session => session.id === id)?.messages.length, 2);
});

test("分支失败不留下幽灵会话；错误起点、运行中与非法请求被拒绝", async t => {
  let resolve!: (response: { text: string }) => void;
  const { core, directory } = await fixture(t, async () => new Promise(done => { resolve = done; }));
  const running = core.prompt("one", "第一轮", undefined, false, "source");
  while (!resolve) await new Promise(done => setImmediate(done));
  assert.throws(() => core.forkConversation("source", "request"), /停止/);
  resolve({ text: "完成" });
  await running;
  assert.throws(() => core.forkConversation("source", "request", "missing"), /起点/);
  assert.throws(() => core.forkConversation("source", ""), /requestId/);
  core.manageConversation("source", "archive");
  core.forkConversation("source", "archive-fork");
  assert.equal(sessions(core)[1].archived, false);
  const before = sessions(core);
  const path = join(directory, "state.json");
  const original = await readFile(path);
  await rm(path);
  await mkdir(path);
  const events: AgentEvent[] = [];
  core.events.subscribe(event => events.push(event));
  assert.throws(() => core.forkConversation("source", "failed-fork"));
  assert.deepEqual(sessions(core), before);
  assert.equal(events.length, 0);
  await rm(path, { recursive: true });
  await writeFile(path, original);
});
