import { strict as assert } from "node:assert";
import { once } from "node:events";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createDefaultConfig, parseAgentConfig } from "../src/config.ts";
import { createAgentTools } from "../src/tools.ts";

test("完整权限迁移后提供文件、命令行与网络工具", () => {
  const config = parseAgentConfig({ tools: { filesystem: false, shell: false, network: false }, privacy: { mode: "strict-local", allowNetwork: false } });
  assert.deepEqual(createAgentTools(config).map((tool) => tool.name), ["filesystem", "shell", "network"]);
  assert.equal(config.permissionMode, "full-access");
});

test("文件工具真实读写、列出目录并脱敏返回内容", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "another-you-tools-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const tool = createAgentTools(createDefaultConfig()).find((item) => item.name === "filesystem")!;
  const file = join(dir, "test.txt");
  await tool.execute("write", { action: "write", path: file, content: "hello\napi_key=private-value" });
  assert.equal(await readFile(file, "utf8"), "hello\napi_key=private-value");
  const read = await tool.execute("read", { action: "read", path: file });
  assert.ok(JSON.stringify(read).includes("hello"));
  assert.ok(JSON.stringify(read).includes("已隐藏密钥"));
  assert.ok(!JSON.stringify(read).includes("private-value"));
  assert.ok(JSON.stringify(await tool.execute("list", { action: "list", path: dir })).includes("test.txt"));
  await assert.rejects(tool.execute("missing", { action: "read", path: join(dir, "missing") }), /ENOENT/);
});

test("shell 工具执行真实命令并响应取消", async () => {
  const tool = createAgentTools(createDefaultConfig()).find((item) => item.name === "shell")!;
  assert.ok(JSON.stringify(await tool.execute("shell", { command: "printf actual-shell-output" })).includes("actual-shell-output"));
  const abort = new AbortController();
  const running = tool.execute("abort", { command: "sleep 10" }, abort.signal);
  abort.abort();
  await assert.rejects(running, /abort/i);
});

test("network 工具访问真实 HTTP fixture 并拒绝非 HTTP 协议", async (t) => {
  const server = createServer((req, res) => { if (req.url === "/hang") return; res.end("network-fixture"); });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(async () => { server.closeAllConnections(); await new Promise<void>((done) => server.close(() => done())); });
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const tool = createAgentTools(createDefaultConfig()).find((item) => item.name === "network")!;
  const url = `http://127.0.0.1:${address.port}`;
  assert.ok(JSON.stringify(await tool.execute("network", { url })).includes("network-fixture"));
  await assert.rejects(tool.execute("file", { url: "file:///etc/hosts" }), /HTTP/);
  const abort = new AbortController();
  const running = tool.execute("abort", { url: `${url}/hang` }, abort.signal);
  abort.abort();
  await assert.rejects(running, /abort/i);
});
