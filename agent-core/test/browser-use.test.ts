import { strict as assert } from "node:assert";
import { chmod, mkdir, mkdtemp, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import type { BrowserContext } from "playwright-core";
import type { AgentToolResult } from "@earendil-works/pi-agent-core";
import { BrowserSession, createBrowserTools, findBrowserExecutable } from "../src/browser-use.ts";

function data(result: AgentToolResult): any {
  const text = result.content.find((item) => item.type === "text");
  assert.equal(text?.type, "text");
  return JSON.parse(text!.text);
}

async function fixture(crossOrigin?: string): Promise<{ server: Server; url: string }> {
  const server = createServer((request, response) => {
    if (request.url === "/slow") return;
    response.setHeader("content-type", "text/html; charset=utf-8");
    if (request.url?.startsWith("/frame")) {
      response.end(`<!doctype html><html><body><p>嵌入页面</p>
        <label for="email">邮箱</label><input id="email"><button id="save">保存邮箱</button><p id="saved"></p>
        <label for="city">城市</label><select id="city"><option value="">请选择</option><option value="sh">上海</option><option value="bj">北京</option></select><p id="selected"></p>
        <div id="frame-shadow"></div><a href="/frame-next">框架内导航</a>
        <script>
          document.getElementById('save').onclick=()=>document.getElementById('saved').textContent='已保存：'+document.getElementById('email').value;
          document.getElementById('city').onchange=(event)=>document.getElementById('selected').textContent='城市：'+event.target.value;
          const shadow=document.getElementById('frame-shadow').attachShadow({mode:'open'});
          shadow.innerHTML='<button>框架影子按钮</button><p></p>';
          shadow.querySelector('button').onclick=()=>shadow.querySelector('p').textContent='影子按钮已点击';
        </script></body></html>`);
      return;
    }
    if (request.url === "/modern") {
      response.end(`<!doctype html><html><body><h1>现代网页</h1>
        <iframe title="同源" src="/frame" style="width:600px;height:330px"></iframe>
        <iframe title="跨源" src="${crossOrigin}/frame" style="width:600px;height:330px"></iframe>
        <iframe title="隐藏" src="/frame-hidden" style="display:none"></iframe>
        <div id="open-shadow"><button slot="action">插槽按钮</button></div><div id="closed-shadow"></div>
        <script>
          const root=document.getElementById('open-shadow').attachShadow({mode:'open'});
          root.innerHTML='开放影子文字<label for="shadow-input">影子输入</label><input id="shadow-input"><div id="nested"></div><slot name="action"></slot>';
          const nested=root.getElementById('nested').attachShadow({mode:'open'});
          nested.innerHTML='<label for="color">颜色</label><select id="color"><option value="red">红色</option><option value="blue">蓝色</option></select><p></p>';
          nested.querySelector('select').onchange=(event)=>nested.querySelector('p').textContent='颜色：'+event.target.value;
          document.getElementById('closed-shadow').attachShadow({mode:'closed'}).innerHTML='<button>不可遍历的闭合影子按钮</button>';
        </script></body></html>`);
      return;
    }
    response.end(`<!doctype html><html><head><title>后台浏览器验收</title></head><body>
      <h1>后台网页</h1><label for="name">姓名</label><input id="name" placeholder="输入姓名">
      <input type="password" value="never-output-this-password" aria-label="密码">
      <button id="greet">问候</button><p id="result"></p>
      <button id="login">保存登录</button><p id="session"></p>
      <a href="/next" target="_blank">打开另一页</a><button style="display:none">隐藏按钮</button>
      <div style="height:2300px">可以滚动的页面</div><p>页尾</p>
      <script>
        document.getElementById('greet').onclick=()=>document.getElementById('result').textContent='你好，'+document.getElementById('name').value;
        document.getElementById('name').onkeydown=(event)=>{if(event.key==='Enter') document.getElementById('result').textContent='已提交：'+event.target.value};
        document.getElementById('session').textContent=localStorage.getItem('session')||'尚未登录';
        document.getElementById('login').onclick=()=>{localStorage.setItem('session','登录已保留');document.getElementById('session').textContent='登录已保留'};
      </script></body></html>`);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  return { server, url: `http://127.0.0.1:${address.port}` };
}

test("后台浏览器严格校验动作参数和 URL，缺失浏览器给出安装指引", async () => {
  const session = new BrowserSession({ dataDir: join(tmpdir(), "unused-another-you-browser") });
  assert.equal(createBrowserTools(session)[0].name, "browser_use");
  assert.deepEqual(data(await session.execute({ action: "tabs" })).tabs, []);
  for (const value of [
    { action: "evaluate", script: "alert(1)" }, { action: "open", url: "file:///etc/passwd" },
    { action: "open", url: "javascript:alert(1)" }, { action: "open", url: "https://a:b@example.test" },
    { action: "navigate" }, { action: "fill", ref: "e1" },
    { action: "scroll", direction: "down", amount: 9000 }, { action: "screenshot", fullPage: "true" },
    { action: "snapshot", script: "alert(1)" }, { action: "click", ref: "" },
    { action: "select", ref: "e1" }, { action: "select", ref: "e1", value: ["a"] },
  ]) await assert.rejects(session.execute(value));
  await assert.rejects(findBrowserExecutable("/missing/another-you/chrome"), /ANOTHER_YOU_BROWSER_EXECUTABLE/);
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(session.execute({ action: "tabs" }, controller.signal));
  await session.close();
});

test("完整应用优先内置浏览器，损坏和越界路径不能回退本机浏览器", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "another-you-browser-runtime-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const runtime = join(directory, "runtime");
  await mkdir(join(runtime, "browser"), { recursive: true });
  const executable = join(runtime, "browser", "chrome-headless-shell");
  await writeFile(executable, "#!/bin/sh\nexit 0\n");
  await chmod(executable, 0o700);
  const manifest = join(runtime, "manifest.json");
  await writeFile(manifest, JSON.stringify({ schemaVersion: 1, browser: { executable: "browser/chrome-headless-shell" } }));
  assert.equal(await findBrowserExecutable("/missing/developer-browser", runtime), await realpath(executable));
  const outside = join(directory, "private-browser");
  await writeFile(outside, "#!/bin/sh\nexit 0\n");
  await chmod(outside, 0o700);
  await symlink(outside, join(runtime, "browser", "escape"));
  for (const path of ["../private-browser", outside, "browser/escape", "browser/missing"]) {
    await writeFile(manifest, JSON.stringify({ schemaVersion: 1, browser: { executable: path } }));
    await assert.rejects(findBrowserExecutable(outside, runtime), /内置浏览器不完整/);
  }
  await rm(manifest);
  await assert.rejects(findBrowserExecutable(outside, runtime), /内置浏览器不完整/);
  assert.equal(await findBrowserExecutable(outside, join(directory, "source-without-runtime")), outside);
  await writeFile(join(directory, "runtime-required"), "");
  await rm(runtime, { recursive: true });
  await assert.rejects(findBrowserExecutable(outside, runtime), /内置浏览器不完整/);
});

test("真实无头 Chrome 支持同源和跨源 iframe、嵌套开放 Shadow DOM 与下拉框选择", { timeout: 45_000 }, async (t) => {
  let executablePath: string;
  try { executablePath = await findBrowserExecutable(); } catch (error) { t.skip(String(error)); return; }
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-browser-frames-"));
  const session = new BrowserSession({ dataDir, executablePath, timeoutMs: 10_000 });
  const cross = await fixture();
  const main = await fixture(cross.url);
  try {
    let snapshot = data(await session.execute({ action: "open", url: `${main.url}/modern` }));
    assert.equal(snapshot.frames.length, 3);
    assert.match(snapshot.text, /开放影子文字/);
    assert.doesNotMatch(snapshot.text, /不可遍历的闭合影子按钮/);
    assert.ok(snapshot.elements.some((element: any) => element.name === "插槽按钮"));
    assert.equal(snapshot.elements.filter((element: any) => element.name === "邮箱").length, 2);
    const crossEmail = snapshot.elements.find((element: any) => element.name === "邮箱" && element.frameUrl === `${cross.url}/frame`);
    const frameId = crossEmail.frameId;
    snapshot = data(await session.execute({ action: "fill", ref: crossEmail.ref, text: "test@example.local" }));
    const crossSave = snapshot.elements.find((element: any) => element.name === "保存邮箱" && element.frameId === frameId);
    snapshot = data(await session.execute({ action: "click", ref: crossSave.ref }));
    assert.match(snapshot.text, /已保存：test@example.local/);
    const city = snapshot.elements.find((element: any) => element.name === "城市" && element.frameId === frameId);
    assert.deepEqual(city.options.map((option: any) => option.value), ["", "sh", "bj"]);
    snapshot = data(await session.execute({ action: "select", ref: city.ref, value: "sh" }));
    assert.match(snapshot.text, /城市：sh/);
    assert.equal(snapshot.elements.find((element: any) => element.name === "城市" && element.frameId === frameId).options.find((option: any) => option.value === "sh").selected, true);
    await assert.rejects(session.execute({ action: "select", ref: city.ref, value: "bj" }), /ref 已失效/);
    const color = snapshot.elements.find((element: any) => element.name === "颜色");
    assert.equal(color.frameUrl, `${main.url}/modern`);
    snapshot = data(await session.execute({ action: "select", ref: color.ref, value: "blue" }));
    assert.match(snapshot.text, /颜色：blue/);
    const shadowButton = snapshot.elements.find((element: any) => element.name === "框架影子按钮" && element.frameId === frameId);
    snapshot = data(await session.execute({ action: "click", ref: shadowButton.ref }));
    assert.match(snapshot.text, /影子按钮已点击/);
    const navigate = snapshot.elements.find((element: any) => element.name === "框架内导航" && element.frameId === frameId);
    snapshot = data(await session.execute({ action: "click", ref: navigate.ref }));
    assert.ok(snapshot.frames.some((frame: any) => frame.frameId === frameId && frame.url === `${cross.url}/frame-next`));
    await assert.rejects(session.execute({ action: "click", ref: navigate.ref }), /ref 已失效/);
    assert.ok(JSON.stringify(snapshot).length <= 64 * 1024);
  } finally {
    await session.close();
    for (const { server } of [main, cross]) {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
    await rm(dataDir, { recursive: true, force: true });
  }
});

test("真实无头 Chrome 支持可见快照、录入、按键、点击、多标签、滚动、图片和独立登录持久化", { timeout: 60_000 }, async (t) => {
  let executablePath: string;
  try { executablePath = await findBrowserExecutable(); } catch (error) { t.skip(String(error)); return; }
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-browser-test-"));
  const session = new BrowserSession({ dataDir, executablePath, timeoutMs: 10_000 });
  const { server, url } = await fixture();
  try {
    assert.equal(session.profileDir, join(dataDir, "browser-profile"));
    let snapshot = data(await session.execute({ action: "open", url }));
    const firstTab = snapshot.tabId;
    assert.equal(snapshot.background, true);
    assert.equal(snapshot.title, "后台浏览器验收");
    assert.match(snapshot.text, /后台网页/);
    assert.doesNotMatch(JSON.stringify(snapshot), /never-output-this-password|隐藏按钮/);
    const nameRef = snapshot.elements.find((element: any) => element.name === "姓名").ref;
    snapshot = data(await session.execute({ action: "fill", ref: nameRef, text: "小明" }));
    await assert.rejects(session.execute({ action: "click", ref: nameRef }), /ref 已失效/);
    snapshot = data(await session.execute({ action: "press", ref: snapshot.elements.find((element: any) => element.name === "姓名").ref, key: "Enter" }));
    assert.match(snapshot.text, /已提交：小明/);
    snapshot = data(await session.execute({ action: "click", ref: snapshot.elements.find((element: any) => element.name === "问候").ref }));
    assert.match(snapshot.text, /你好，小明/);
    snapshot = data(await session.execute({ action: "click", ref: snapshot.elements.find((element: any) => element.name === "保存登录").ref }));
    assert.match(snapshot.text, /登录已保留/);
    snapshot = data(await session.execute({ action: "scroll", direction: "down", amount: 800 }));
    assert.equal(snapshot.scrollY, 800);
    snapshot = data(await session.execute({ action: "scroll", direction: "up", amount: 800 }));
    assert.equal(snapshot.scrollY, 0);
    const screenshot = await createBrowserTools(session)[0].execute("shot", { action: "screenshot", fullPage: true });
    const image = screenshot.content.find((item) => item.type === "image");
    assert.equal(image?.type, "image");
    if (image?.type === "image") {
      assert.equal(image.mimeType, "image/jpeg");
      const bytes = Buffer.from(image.data, "base64");
      assert.equal(bytes.readUInt16BE(0), 0xffd8);
      assert.ok(bytes.length < 4 * 1024 * 1024);
      assert.ok(bytes.length > 1000);
    }
    assert.ok(screenshot.content.filter((item) => item.type === "text").every((item) => !item.text.includes("base64")));
    snapshot = data(await session.execute({ action: "snapshot" }));
    await session.execute({ action: "click", ref: snapshot.elements.find((element: any) => element.name === "打开另一页").ref });
    const tabs = data(await session.execute({ action: "tabs" })).tabs;
    assert.ok(tabs.some((tab: any) => tab.url === `${url}/next`));
    snapshot = data(await session.execute({ action: "navigate", tabId: firstTab, url: `${url}/other` }));
    assert.equal(snapshot.url, `${url}/other`);
    const second = data(await session.execute({ action: "open", url: `${url}/second` }));
    assert.notEqual(second.tabId, firstTab);
    await session.execute({ action: "close", tabId: second.tabId });
    assert.ok(data(await session.execute({ action: "tabs" })).tabs.every((tab: any) => tab.tabId !== second.tabId));
    await session.close();
    assert.deepEqual(data(await session.execute({ action: "tabs" })).tabs, []);
    snapshot = data(await session.execute({ action: "open", url }));
    assert.match(snapshot.text, /登录已保留/);
    await session.execute({ action: "close" });
    assert.deepEqual(data(await session.execute({ action: "tabs" })).tabs, []);
  } finally {
    await session.close();
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(dataDir, { recursive: true, force: true });
  }
});

test("真实后台浏览器取消正在导航和排队动作后可重新启动", { timeout: 45_000 }, async (t) => {
  let executablePath: string;
  try { executablePath = await findBrowserExecutable(); } catch (error) { t.skip(String(error)); return; }
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-browser-abort-"));
  const session = new BrowserSession({ dataDir, executablePath, timeoutMs: 10_000 });
  const { server, url } = await fixture();
  try {
    await session.execute({ action: "open", url });
    const controller = new AbortController();
    let slowStarted!: () => void;
    const started = new Promise<void>((resolve) => { slowStarted = resolve; });
    server.on("request", (request) => { if (request.url === "/slow") slowStarted(); });
    const pending = session.execute({ action: "navigate", url: `${url}/slow` }, controller.signal);
    const checkPending = assert.rejects(pending, /取消/);
    const queued = session.execute({ action: "open", url: `${url}/must-not-open` });
    const checkQueued = assert.rejects(queued, /取消/);
    await started;
    controller.abort();
    await Promise.all([checkPending, checkQueued]);
    assert.deepEqual(data(await session.execute({ action: "tabs" })).tabs, []);
    const reopened = data(await session.execute({ action: "open", url }));
    assert.match(reopened.text, /后台网页/);
  } finally {
    await session.close();
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(dataDir, { recursive: true, force: true });
  }
});

test("真实后台浏览器超时会释放上下文并允许重启", { timeout: 30_000 }, async (t) => {
  let executablePath: string;
  try { executablePath = await findBrowserExecutable(); } catch (error) { t.skip(String(error)); return; }
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-browser-timeout-"));
  const options = { dataDir, executablePath, timeoutMs: 10_000 };
  const session = new BrowserSession(options);
  const { server, url } = await fixture();
  try {
    await session.execute({ action: "open", url });
    const context = await Reflect.get(session, "context") as BrowserContext;
    let closed = false;
    context.on("close", () => { closed = true; });
    // 仅缩短动作总时限，避免把 Chrome 冷启动也限制为 1.5 秒；底层导航仍保留 10 秒。
    options.timeoutMs = 1500;
    try {
      await assert.rejects(session.execute({ action: "navigate", url: `${url}/slow` }), { message: "浏览器操作超时，已关闭后台浏览器" });
    } finally { options.timeoutMs = 10_000; }
    assert.equal(closed, true);
    assert.deepEqual(context.pages(), []);
    assert.deepEqual(data(await session.execute({ action: "tabs" })).tabs, []);
    assert.match(data(await session.execute({ action: "open", url })).text, /后台网页/);
  } finally {
    await session.close();
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(dataDir, { recursive: true, force: true });
  }
});

test("Playwright 导航先于总截止时间超时也关闭上下文并取消排队动作", { timeout: 30_000 }, async (t) => {
  let executablePath: string;
  try { executablePath = await findBrowserExecutable(); } catch (error) { t.skip(String(error)); return; }
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-browser-early-timeout-"));
  const session = new BrowserSession({ dataDir, executablePath, timeoutMs: 10_000 });
  const { server, url } = await fixture();
  try {
    await session.execute({ action: "open", url });
    // 只缩短底层导航计时器，确定覆盖 Playwright 先于总 deadline 报错的分支。
    const context = await Reflect.get(session, "context") as BrowserContext;
    context.setDefaultNavigationTimeout(100);
    let closed = false;
    context.on("close", () => { closed = true; });
    const pending = assert.rejects(session.execute({ action: "navigate", url: `${url}/slow` }), { message: "浏览器操作超时，已关闭后台浏览器" });
    const queued = assert.rejects(session.execute({ action: "open", url: `${url}/must-not-open` }), /取消/);
    await Promise.all([pending, queued]);
    assert.equal(closed, true);
    assert.deepEqual(context.pages(), []);
    assert.deepEqual(data(await session.execute({ action: "tabs" })).tabs, []);
    assert.match(data(await session.execute({ action: "open", url })).text, /后台网页/);
  } finally {
    await session.close();
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(dataDir, { recursive: true, force: true });
  }
});
