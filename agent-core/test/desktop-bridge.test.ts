import { strict as assert } from 'node:assert';
import test from 'node:test';
import { DesktopBridge, createDesktopTools, desktopResult, parseAttachments, parseDesktopSnapshot, type DesktopRequest, type DesktopSnapshot } from '../src/desktop-bridge.ts';

const png = { mimeType: 'image/png', data: 'iVBORw0KGgo=' };
const snapshot = (): DesktopSnapshot => ({ capturedAt: '2026-10-07T10:00:00Z',
  context: { pid: 42, appName: 'Original App', title: 'Original Window', tree: { value: 'Original content' } },
  image: { ...png, mimeType: 'image/png' }, mode: 'screen' });

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
  bridge.receive({ requestId: events[0].payload.requestId, result: { image: png, context: { title: 'test', appName: 'Preview', bundleId: 'com.apple.Preview' } } });
  const resultWithDetails = desktopResult(await result);
  const content = resultWithDetails.content;
  assert.deepEqual(resultWithDetails.details, { appName: 'Preview', bundleId: 'com.apple.Preview', windowTitle: 'test' });
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

test('唤起快照校验时间、上下文、图片与错误边界并复制嵌套内容', () => {
  assert.equal(parseDesktopSnapshot(undefined), undefined);
  const original = snapshot();
  const parsed = parseDesktopSnapshot(original)!;
  (original.context.tree as any).value = 'Changed content';
  assert.equal((parsed.context.tree as any).value, 'Original content');
  for (const value of [null, [], {}, { ...snapshot(), capturedAt: 'invalid' }, { ...snapshot(), context: [] },
    { ...snapshot(), context: { value: 'x'.repeat(100_001) } }, { ...snapshot(), context: { pid: -1 } },
    { ...snapshot(), image: { ...png, data: 'YWJjZA==' } }, { ...snapshot(), mode: 'other' },
    { ...snapshot(), contextError: false }, { ...snapshot(), screenshotError: 'x'.repeat(2001) }]) {
    assert.throws(() => parseDesktopSnapshot(value));
  }
});

test('切换应用或同应用内容变化后重复读取仍使用唤起快照且不请求实时宿主', async () => {
  const events: DesktopRequest[] = [];
  const original = snapshot();
  const tool = createDesktopTools(new DesktopBridge(event => events.push(event)), false, original)[0];
  original.context.title = 'New Window';
  (original.context.tree as any).value = 'New content';
  original.image!.data = '/9j/';
  for (let index = 0; index < 2; index++) {
    const context = await tool.execute(`context-${index}`, { action: 'context' });
    assert.equal(context.content[0].type, 'text');
    const text = JSON.stringify(context.content);
    assert.match(text, /Original Window/);
    assert.match(text, /Original content/);
    assert.ok(!text.includes('New content'));
    const capture = await tool.execute(`image-${index}`, { action: 'screenshot', mode: 'window' });
    assert.deepEqual(capture.content.find(item => item.type === 'image'), { type: 'image', ...png });
    assert.match(JSON.stringify(capture.content[0]), /screen/);
    assert.deepEqual(capture.details, { appName: 'Original App', windowTitle: 'Original Window' });
  }
  await assert.rejects(tool.execute('other-app', { action: 'context', pid: 99 }), /唤起输入框/);
  await assert.rejects(tool.execute('other-app-shot', { action: 'screenshot', pid: 99 }), /唤起输入框/);
  assert.equal(events.length, 0);
});

test('唤起采集失败保持失败，取消后不读快照，均不回退当前屏幕', async () => {
  const events: DesktopRequest[] = [];
  const tool = createDesktopTools(new DesktopBridge(event => events.push(event)), false, {
    capturedAt: snapshot().capturedAt, context: {}, contextError: '目标已退出', screenshotError: '需要屏幕权限',
  })[0];
  await assert.rejects(tool.execute('context', { action: 'context' }), /目标已退出/);
  await assert.rejects(tool.execute('image', { action: 'screenshot' }), /屏幕权限/);
  await assert.rejects(tool.execute('press', { action: 'press', elementId: 'old' }), /未能确定目标应用/);
  const cancelled = new AbortController();
  cancelled.abort();
  await assert.rejects(createDesktopTools(undefined, false, snapshot())[0].execute('cancelled', { action: 'context' }, cancelled.signal), /取消/);
  assert.equal(events.length, 0);
});

test('快照仅绑定本轮，后续普通消息照常读取宿主；写操作默认目标固定', async () => {
  const events: DesktopRequest[] = [];
  const bridge = new DesktopBridge(event => events.push(event));
  const first = createDesktopTools(bridge, false, snapshot())[0];
  const nextSnapshot = snapshot();
  nextSnapshot.context = { pid: 99, appName: 'Next App' };
  const next = createDesktopTools(bridge, false, nextSnapshot)[0];
  assert.match(JSON.stringify((await first.execute('first', { action: 'context' })).content), /Original App/);
  assert.match(JSON.stringify((await next.execute('next', { action: 'context' })).content), /Next App/);
  const write = first.execute('write', { action: 'press', elementId: 'original-element' });
  assert.deepEqual(events[0].payload.arguments, { action: 'press', elementId: 'original-element', background: true, pid: 42 });
  bridge.receive({ requestId: events[0].payload.requestId, result: { performed: true } });
  await write;
  const live = createDesktopTools(bridge)[0].execute('live', { action: 'context' });
  assert.deepEqual(events[1].payload.arguments, { action: 'context', background: true });
  bridge.receive({ requestId: events[1].payload.requestId, result: { appName: 'Current App' } });
  assert.match(JSON.stringify((await live).content), /Current App/);
});

test('完整应用快照包含窗口身份、文字控件树和画面，缺少画面仍返回可读内容与错误', async () => {
  const original = snapshot();
  original.context.targetId = 'original-target';
  original.context.windowId = 101;
  const result = await createDesktopTools(undefined, false, original)[0].execute('full', { action: 'snapshot' });
  const text = JSON.parse((result.content[0] as any).text);
  assert.equal(text.context.targetId, 'original-target');
  assert.equal(text.context.windowId, 101);
  assert.equal(text.context.tree.value, 'Original content');
  assert.equal(text.frozen, true);
  assert.deepEqual(result.content[1], { type: 'image', ...png });
  delete original.image;
  original.screenshotError = '没有屏幕权限';
  const partial = await createDesktopTools(undefined, false, original)[0].execute('partial', { action: 'snapshot' });
  assert.match(JSON.stringify(partial.content), /Original content/);
  assert.match(JSON.stringify(partial.content), /没有屏幕权限/);
  assert.equal(partial.content.length, 1);
});

test('后台补读固定原窗口且强制窗口截图，初始快照与下一个会话不变', async () => {
  const events: DesktopRequest[] = [];
  const bridge = new DesktopBridge(event => events.push(event));
  const original = snapshot();
  original.context.targetId = 'original-target';
  original.context.windowId = 101;
  const tool = createDesktopTools(bridge, true, original)[0];
  for (const action of ['context', 'screenshot', 'snapshot']) {
    const pending = tool.execute(action, { action, refresh: true, mode: 'screen', background: false });
    const event = events.at(-1)!;
    const arguments_ = event.payload.arguments as Record<string, unknown>;
    assert.equal(arguments_.pid, 42);
    assert.equal(arguments_.targetId, 'original-target');
    assert.equal(arguments_.background, true);
    assert.ok(!('refresh' in arguments_));
    if (action !== 'context') assert.equal(arguments_.mode, 'window');
    bridge.receive({ requestId: event.payload.requestId, result: { context: { ...original.context, tree: { value: 'Updated original content' } }, image: png, mode: 'window' } });
    assert.match(JSON.stringify((await pending).content), /Updated original content/);
  }
  assert.match(JSON.stringify((await tool.execute('initial', { action: 'snapshot' })).content), /Original content/);
  assert.ok(!JSON.stringify((await tool.execute('initial-again', { action: 'context' })).content).includes('Updated original content'));
  const other = snapshot();
  other.context.targetId = 'other-target';
  other.context.windowId = 102;
  const pending = createDesktopTools(bridge, false, other)[0].execute('other', { action: 'snapshot', refresh: true });
  assert.equal((events.at(-1)!.payload.arguments as Record<string, unknown>).targetId, 'other-target');
  bridge.receive({ requestId: events.at(-1)!.payload.requestId, error: '原窗口已经关闭' });
  await assert.rejects(pending, /原窗口已经关闭/);
  const write = tool.execute('write-original', { action: 'press', elementId: 'original-element' });
  assert.equal((events.at(-1)!.payload.arguments as Record<string, unknown>).targetId, 'original-target');
  bridge.receive({ requestId: events.at(-1)!.payload.requestId, result: { performed: true } });
  await write;
});

test('补读拒绝跨应用、缺少原窗口引用和断开宿主，错误不会回退前台', async () => {
  const events: DesktopRequest[] = [];
  const bridge = new DesktopBridge(event => events.push(event));
  const original = snapshot();
  const unbound = createDesktopTools(bridge, false, original)[0];
  await assert.rejects(unbound.execute('missing', { action: 'snapshot', refresh: true }), /不能读取当前桌面/);
  original.context.targetId = 'original-target';
  const bound = createDesktopTools(bridge, false, original)[0];
  await assert.rejects(bound.execute('cross-app', { action: 'snapshot', refresh: true, pid: 99 }), /唤起输入框/);
  await assert.rejects(createDesktopTools(undefined, false, original)[0].execute('disconnected', { action: 'context', refresh: true }), /连接 macOS/);
  assert.equal(events.length, 0);
  for (const context of [{ targetId: '' }, { targetId: false }, { targetId: 'x'.repeat(257) }, { windowId: 0 }, { windowId: 1.5 }, { windowId: 4_294_967_296 }]) {
    assert.throws(() => parseDesktopSnapshot({ ...snapshot(), context }));
  }
});
