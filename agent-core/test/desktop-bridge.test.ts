import { strict as assert } from 'node:assert';
import test from 'node:test';
import { DesktopBridge, createDesktopTools, desktopResult, parseAttachments, type DesktopRequest } from '../src/desktop-bridge.ts';

const png = { mimeType: 'image/png', data: 'iVBORw0KGgo=' };

test('截图验证限制类型、签名、上下文、数量与总大小', () => {
  assert.deepEqual(parseAttachments(undefined), []);
  assert.equal(parseAttachments([png])[0].mimeType, 'image/png');
  for (const value of [null, {}, Array(5).fill(png), [{ ...png, mimeType: 'image/svg+xml' }], [{ ...png, data: 'YWJjZA==' }], [{ ...png, context: [] }], [{ ...png, data: png.data + 'A'.repeat(3_000_000) }]]) {
    assert.throws(() => parseAttachments(value));
  }
});

test('原生回执按ID匹配，迟到回执忽略，结果拆分图片与文本', async () => {
  const events: DesktopRequest[] = [];
  const bridge = new DesktopBridge(event => events.push(event));
  const result = bridge.request({ action: 'screenshot' });
  bridge.receive({ requestId: 'unrelated', result: {} });
  bridge.receive({ requestId: events[0].payload.requestId, result: { image: png, context: { title: 'test' } } });
  const content = desktopResult(await result).content;
  assert.equal(content[0].type, 'text');
  assert.ok(!JSON.stringify(content[0]).includes(png.data));
  assert.equal(content[1].type, 'image');
  bridge.receive({ requestId: events[0].payload.requestId, result: {} });
});

test('取消与超时会通知原生终止，断开后释放全部请求', async () => {
  const events: DesktopRequest[] = [];
  const bridge = new DesktopBridge(event => events.push(event), 20);
  const signal = new AbortController();
  const pending = bridge.request({ action: 'context' }, signal.signal);
  signal.abort();
  await assert.rejects(pending, /取消/);
  assert.equal(events[1].kind, 'desktop.cancel');
  await assert.rejects(bridge.request({ action: 'context' }), /超时/);
  const next = bridge.request({ action: 'context' });
  bridge.abort();
  await assert.rejects(next, /停止/);
});

test('后台会话拒绝前台动作且不会向宿主发送命令', async () => {
  const events: DesktopRequest[] = [];
  const bridge = new DesktopBridge(event => events.push(event));
  const tool = createDesktopTools(bridge)[0];
  await assert.rejects(tool.execute('1', { action: 'click', background: false }), /仅允许后台/);
  assert.equal(events.length, 0);
  const pending = tool.execute('2', { action: 'context' });
  assert.deepEqual(events[0].payload.arguments, { action: 'context', background: true });
  bridge.receive({ requestId: events[0].payload.requestId, error: '需要辅助功能权限' });
  await assert.rejects(pending, /辅助功能/);
});
