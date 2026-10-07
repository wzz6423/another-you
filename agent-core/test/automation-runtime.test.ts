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

async function fixture(t: TestContext, supportsImages = true, toolArguments: Record<string, unknown> = { action: 'screenshot', mode: 'window' }) {
  const dataDir = await mkdtemp(join(tmpdir(), 'another-you-automation-'));
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const requests: any[] = [];
  const server = createServer(async (req, res) => {
    let body = '';
    for await (const chunk of req) body += chunk;
    requests.push(JSON.parse(body));
    const tool = requests.length % 2 === 1;
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const delta = tool ? { role: 'assistant', tool_calls: [{ index: 0, id: 'native-1', type: 'function', function: { name: 'computer_use', arguments: JSON.stringify(toolArguments) } }] } : { role: 'assistant', content: '已读取应用截图。' };
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
  f.send({ op: 'desktopResult', requestId: request.payload.requestId, result: { image: png, context: { appName: 'Target Fixture', bundleId: 'test.target', title: '测试窗口', text: 'x'.repeat(5000) } } });
  const response = await f.wait('agent.response');
  assert.equal(response.payload.text, '已读取应用截图。');
  assert.equal(f.requests.length, 2);
  const activity = f.events.find(event => event.kind === 'agent.activity' && event.payload.toolCallId === 'native-1' && event.payload.phase === 'completed');
  assert.equal(activity?.payload.targetAppName, 'Target Fixture');
  assert.equal(activity?.payload.targetBundleId, 'test.target');
  assert.equal(activity?.payload.targetWindowTitle, '测试窗口');
  assert.equal(activity?.payload.result.length, 4000);
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

test('真实JSONL与Pi读取唤起快照，下一轮普通消息恢复实时读取且图片不落盘', async t => {
  const f = await fixture(t);
  f.send({ op: 'prompt', requestId: 'invocation-snapshot', prompt: '阅读一下屏幕', desktopSnapshot: {
    capturedAt: '2026-10-07T10:00:00Z', context: { pid: 42, appName: 'Original App', title: 'Invocation Window' }, image: png, mode: 'screen',
  } });
  await f.wait('agent.response');
  assert.equal(f.events.filter(event => event.kind === 'desktop.request').length, 0);
  assert.equal(f.requests.length, 2);
  assert.ok(!JSON.stringify(f.requests[0].messages).includes(png.data));
  const modelInput = JSON.stringify(f.requests[1].messages);
  assert.ok(modelInput.includes(`data:image/png;base64,${png.data}`));
  assert.ok(modelInput.includes('Invocation Window'));
  assert.ok(modelInput.includes('2026-10-07T10:00:00Z'));
  const state = await readFile(join(f.dataDir, 'state.json'), 'utf8');
  assert.ok(!state.includes(png.data));
  assert.ok(!state.includes('desktopSnapshot'));
  const after = f.events.length;
  f.send({ op: 'prompt', requestId: 'normal-followup', prompt: '阅读现在的屏幕' });
  const current = await f.wait('desktop.request', after);
  f.send({ op: 'desktopResult', requestId: current.payload.requestId, result: { image: png, context: { appName: 'Current App', title: 'Current Window' } } });
  await f.wait('agent.response', after);
  assert.equal(f.requests.length, 4);
  const followup = JSON.stringify(f.requests[3].messages);
  assert.ok(followup.includes('Current Window'));
  assert.ok(!followup.includes('Invocation Window'));
});

test('唤起时缺少截图只向Pi返回采集错误，不请求后来屏幕', async t => {
  const f = await fixture(t);
  f.send({ op: 'prompt', requestId: 'unavailable-snapshot', prompt: '阅读一下屏幕', desktopSnapshot: {
    capturedAt: '2026-10-07T10:00:00Z', context: { pid: 42, appName: 'Original App' }, screenshotError: '唤起时没有屏幕录制权限',
  } });
  await f.wait('agent.response');
  assert.equal(f.events.filter(event => event.kind === 'desktop.request').length, 0);
  assert.ok(JSON.stringify(f.requests[1].messages).includes('唤起时没有屏幕录制权限'));
  assert.ok(!JSON.stringify(f.requests[1].messages).includes('data:image/'));
});

test('真实JSONL与Pi后台补读原应用快照，窗口引用传到宿主且内容与画面不落盘', async t => {
  const f = await fixture(t, true, { action: 'snapshot', refresh: true, mode: 'screen' });
  f.send({ op: 'prompt', requestId: 'refresh-original', prompt: '继续读取原应用', desktopSnapshot: {
    capturedAt: '2026-10-07T10:00:00Z', context: { pid: 42, targetId: 'original-target', windowId: 101,
      appName: 'Original App', title: 'Invocation Window', tree: { value: 'Initial content' } }, image: png, mode: 'window',
  } });
  const request = await f.wait('desktop.request');
  assert.deepEqual(request.payload.arguments, { action: 'snapshot', mode: 'window', background: true, pid: 42, targetId: 'original-target' });
  f.send({ op: 'desktopResult', requestId: request.payload.requestId, result: { image: png,
    context: { pid: 42, targetId: 'original-target', windowId: 101, appName: 'Original App', title: 'Invocation Window',
      tree: { value: 'Updated original content', elementId: 'updated-element' } }, mode: 'window' } });
  await f.wait('agent.response');
  const input = JSON.stringify(f.requests[1].messages);
  assert.ok(input.includes('Updated original content'));
  assert.ok(input.includes('updated-element'));
  assert.ok(input.includes(`data:image/png;base64,${png.data}`));
  assert.ok(input.includes('invocationCapturedAt'));
  const state = await readFile(join(f.dataDir, 'state.json'), 'utf8');
  for (const value of [png.data, 'original-target', 'Updated original content', 'updated-element']) assert.ok(!state.includes(value), `unexpected persisted ${value}`);
});
