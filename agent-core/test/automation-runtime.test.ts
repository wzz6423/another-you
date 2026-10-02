import { strict as assert } from 'node:assert';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import test, { type TestContext } from 'node:test';
import { createDefaultConfig, saveConfig } from '../src/config.ts';

import { writePiFixture } from "./pi-fixture.ts";

const png = { mimeType: 'image/png', data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jYZkAAAAASUVORK5CYII=' };

async function fixture(t: TestContext, supportsImages = true) {
  const dataDir = await mkdtemp(join(tmpdir(), 'another-you-automation-'));
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const requests: any[] = [];
  const server = createServer(async (req, res) => {
    let body = '';
    for await (const chunk of req) body += chunk;
    requests.push(JSON.parse(body));
    const tool = requests.length % 2 === 1;
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const delta = tool ? { role: 'assistant', tool_calls: [{ index: 0, id: 'native-1', type: 'function', function: { name: 'computer_use', arguments: JSON.stringify({ action: 'screenshot', mode: 'window' }) } }] } : { role: 'assistant', content: '已读取应用截图。' };
    for (const choice of [{ index: 0, delta, finish_reason: null }, { index: 0, delta: {}, finish_reason: tool ? 'tool_calls' : 'stop' }]) {
      res.write(`data: ${JSON.stringify({ id: 'fixture', object: 'chat.completion.chunk', model: 'fixture', choices: [choice] })}\n\n`);
    }
    res.end('data: [DONE]\n\n');
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise<void>(done => server.close(() => done())); });
  const address = server.address();
  assert.ok(address && typeof address !== 'string');
  const config = createDefaultConfig(dataDir);
  const piDir = await writePiFixture(dataDir, `http://127.0.0.1:${address.port}/v1`);
  if (!supportsImages) {
    const path = join(piDir, 'models.json');
    const models = JSON.parse(await readFile(path, 'utf8'));
    models.providers['fixture-provider'].models[0].input = ['text'];
    await writeFile(path, JSON.stringify(models));
  }
  const configPath = join(dataDir, 'config.json');
  await saveConfig(config, configPath);
  const child = spawn(process.execPath, ['--experimental-strip-types', resolve('src/cli.ts'), '--stdio', '--config', configPath], { env: { ...process.env, ANOTHER_YOU_DESKTOP_HOST: '1', PI_CODING_AGENT_DIR: piDir } });
  const events: any[] = [];
  const reader = createInterface({ input: child.stdout });
  let stderr = '';
  child.stderr.on('data', data => { stderr += String(data); });
  reader.on('line', line => events.push(JSON.parse(line)));
  const exit = once(child, 'exit');
  t.after(async () => { if (child.exitCode === null) { child.kill('SIGTERM'); await exit; } reader.close(); });
  const send = (value: unknown) => child.stdin.write(`${JSON.stringify(value)}\n`);
  const wait = async (kind: string, after = 0): Promise<any> => {
    const start = Date.now();
    while (Date.now() - start < 8000) {
      const event = events.slice(after).find(event => event.kind === kind);
      if (event) return event;
      if (child.exitCode !== null) throw new Error(`sidecar退出: ${stderr}`);
      await new Promise(done => setTimeout(done, 10));
    }
    throw new Error(`等待${kind}超时: ${stderr}`);
  };
  await wait('agent.status');
  return { dataDir, requests, events, send, wait };
}

test('真实Pi与JSONL完成截图附件、原生工具回执及图片再次入模，截图不写状态', async t => {
  const f = await fixture(t);
  f.send({ op: 'prompt', requestId: 'screenshot-roundtrip', prompt: '分析截图', attachments: [{ ...png, context: { appName: 'Fixture', text: 'capture-only-context-42' } }] });
  const request = await f.wait('desktop.request');
  assert.equal(request.payload.arguments.background, true);
  f.send({ op: 'desktopResult', requestId: request.payload.requestId, result: { image: png, context: { appName: 'Fixture' } } });
  const response = await f.wait('agent.response');
  assert.equal(response.payload.text, '已读取应用截图。');
  assert.equal(f.requests.length, 2);
  for (const request of f.requests) assert.ok(JSON.stringify(request.messages).includes(`data:image/png;base64,${png.data}`));
  const names = f.requests[0].tools.map((tool: any) => tool.function.name);
  assert.ok(names.includes('computer_use') && names.includes('browser_use'));
  const state = await readFile(join(f.dataDir, 'state.json'), 'utf8');
  assert.ok(!state.includes(png.data));
  assert.ok(!state.includes('capture-only-context-42'));
  assert.ok(!state.includes('desktop.request'));
});

test('等待原生工具时可查询状态和取消，不阻塞JSONL且旧回执不恢复动作', async t => {
  const f = await fixture(t);
  f.send({ op: 'prompt', requestId: 'cancel-native', prompt: '截图' });
  const request = await f.wait('desktop.request');
  const after = f.events.length;
  f.send({ op: 'status' });
  await f.wait('agent.status', after);
  f.send({ op: 'cancel' });
  const cancelled = await f.wait('desktop.cancel');
  assert.equal(cancelled.payload.requestId, request.payload.requestId);
  const failed = await f.wait('agent.error');
  assert.equal(failed.payload.requestId, 'cancel-native');
  f.send({ op: 'desktopResult', requestId: request.payload.requestId, result: {} });
  assert.equal(f.requests.length, 1);
});

test('纯文本Pi模型明确拒绝截图而非静默丢弃图片', async t => {
  const f = await fixture(t, false);
  f.send({ op: 'prompt', requestId: 'text-only', prompt: '分析截图', attachments: [png] });
  const error = await f.wait('agent.error');
  assert.match(error.payload.message, /不支持图片/);
  assert.equal(f.requests.length, 0);
});
