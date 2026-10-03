#!/usr/bin/env node
import { strict as assert } from 'node:assert';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, readdir, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { openSync, readSync, closeSync, readlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath, pathToFileURL } from 'node:url';

const script = fileURLToPath(import.meta.url);
const systemPath = '/usr/bin:/bin:/usr/sbin:/sbin';

export function loadedDylibDependencies(output) {
  const dependencyCommands = new Set(['LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB']);
  return output.split(/^Load command \d+$/m).flatMap(command => {
    const kind = command.match(/^\s+cmd (\S+)$/m)?.[1];
    if (!dependencyCommands.has(kind)) return [];
    const name = command.match(/^\s+name (.+) \(offset \d+\)$/m)?.[1];
    assert.ok(name, `无法解析动态库加载命令：${kind}`);
    return [name];
  });
}

function toolData(result) {
  return JSON.parse(result.content.find(item => item.type === 'text').text);
}

async function sidecarStatus(root, directory) {
  const config = join(directory, 'config.json');
  await writeFile(config, JSON.stringify({ version: 1, dataDir: directory, scheduler: { enabled: false } }));
  const started = performance.now();
  const child = spawn(process.execPath, ['--experimental-strip-types', join(root, 'src/cli.ts'), '--stdio', '--config', config], { cwd: root, env: process.env, stdio: ['pipe', 'pipe', 'pipe'] });
  const exited = once(child, 'exit');
  const input = createInterface({ input: child.stdout });
  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk; });
  const timeout = setTimeout(() => child.kill('SIGKILL'), 20_000);
  try {
    let status;
    for await (const line of input) {
      const event = JSON.parse(line);
      assert.notEqual(event.kind, 'agent.error', JSON.stringify(event));
      if (event.kind === 'agent.status') { status = event; break; }
    }
    assert.ok(status, `内置 sidecar 未输出状态：${stderr}`);
    const startupMs = performance.now() - started;
    child.stdin.end('{"op":"shutdown"}\n');
    const [code, signal] = await exited;
    assert.equal(code, 0, `sidecar 退出异常 ${signal ?? ''}: ${stderr}`);
    return { startupMs: Number(startupMs.toFixed(2)), model: status.payload.model };
  } finally {
    clearTimeout(timeout);
    input.close();
    if (child.exitCode === null && child.signalCode === null) { child.kill('SIGKILL'); await exited; }
  }
}

async function worker(app, directory, homeState) {
  assert.equal(process.env.PATH, systemPath);
  assert.equal(process.env.HOME, join(directory, 'home'));
  if (homeState === 'empty') assert.equal(process.env.PI_CODING_AGENT_DIR, undefined);
  assert.equal(process.env.NODE_PATH, undefined);
  const resources = join(app, 'Contents/Resources');
  const runtime = join(resources, 'runtime');
  const root = join(resources, 'agent-core');
  const { BrowserSession, findBrowserExecutable } = await import(pathToFileURL(join(root, 'src/browser-use.ts')).href);
  const { createAgentTools } = await import(pathToFileURL(join(root, 'src/tools.ts')).href);
  const { createDefaultConfig } = await import(pathToFileURL(join(root, 'src/config.ts')).href);
  const sourcePaths = homeState === 'synthetic-private-config'
    ? ['settings.json', 'models.json', 'auth.json'].map(name => join(process.env.PI_CODING_AGENT_DIR, name)) : [];
  const sourceBefore = await Promise.all(sourcePaths.map(path => readFile(path, 'utf8')));
  const status = await sidecarStatus(root, join(directory, 'data'));
  assert.equal(resolve(status.model.configDirectory), join(directory, 'data/pi'));
  assert.equal(status.model.configured, homeState === 'synthetic-private-config');
  if (homeState === 'synthetic-private-config') {
    assert.equal(status.model.provider, 'developer-fixture');
    assert.equal(status.model.model, 'private-fixture');
    const auth = join(directory, 'data/pi/auth.json');
    assert.equal(await realpath(auth), auth);
    assert.deepEqual(JSON.parse(await readFile(auth, 'utf8')), JSON.parse(sourceBefore[2]));
    assert.deepEqual(await Promise.all(sourcePaths.map(path => readFile(path, 'utf8'))), sourceBefore);
  } else {
    assert.notEqual(status.model.provider, 'developer-fixture');
  }
  assert.ok(!JSON.stringify(status).includes('synthetic-'));
  const npmVersion = execFileSync(process.execPath, [join(runtime, 'lib/node_modules/npm/bin/npm-cli.js'), '--version'], { encoding: 'utf8', env: process.env }).trim();
  const executable = await findBrowserExecutable('/missing/developer/browser');
  assert.equal(executable, await realpath(join(runtime, 'browser/chrome-headless-shell')));
  const server = createServer((_request, response) => {
    response.setHeader('content-type', 'text/html; charset=utf-8');
    response.end('<!doctype html><title>Bundled browser fixture</title><label for="name">Name</label><input id="name"><button id="save">Save</button><p id="result"></p><script>document.querySelector("#save").onclick=()=>document.querySelector("#result").textContent="Saved "+document.querySelector("#name").value;</script>');
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  const url = `http://127.0.0.1:${address.port}`;
  const session = new BrowserSession({ dataDir: join(directory, 'data'), timeoutMs: 10_000 });
  const tools = createAgentTools(createDefaultConfig(join(directory, 'data')));
  try {
    const file = join(directory, 'tool-fixture.txt');
    const filesystem = tools.find(tool => tool.name === 'filesystem');
    await filesystem.execute('write', { action: 'write', path: file, content: 'bundled tools work' });
    assert.match(JSON.stringify(await filesystem.execute('read', { action: 'read', path: file })), /bundled tools work/);
    assert.match(JSON.stringify(await tools.find(tool => tool.name === 'shell').execute('shell', { command: 'printf bundled-shell' })), /bundled-shell/);
    assert.match(JSON.stringify(await tools.find(tool => tool.name === 'network').execute('network', { url })), /Bundled browser fixture/);
    const started = performance.now();
    let snapshot = toolData(await session.execute({ action: 'open', url }));
    const browserStartupMs = performance.now() - started;
    assert.equal(snapshot.title, 'Bundled browser fixture');
    const input = snapshot.elements.find(element => element.name === 'Name');
    assert.ok(input);
    snapshot = toolData(await session.execute({ action: 'fill', ref: input.ref, text: 'portable runtime' }));
    const button = snapshot.elements.find(element => element.name === 'Save');
    assert.ok(button);
    snapshot = toolData(await session.execute({ action: 'click', ref: button.ref }));
    assert.match(snapshot.text, /Saved portable runtime/);
    const screenshot = await session.execute({ action: 'screenshot' });
    assert.ok(screenshot.content.some(item => item.type === 'image' && item.mimeType === 'image/jpeg' && item.data.length > 100));
    assert.ok(session.profileDir.startsWith(join(directory, 'data') + '/'));
    process.stdout.write(JSON.stringify({ node: process.versions.node, npm: npmVersion, sidecar: status, browser: { executable: relative(app, executable), startupMs: Number(browserStartupMs.toFixed(2)), actions: ['open', 'snapshot', 'fill', 'click', 'screenshot'] }, tools: ['filesystem write/read', 'shell', 'network'], home: homeState, path: systemPath }) + '\n');
  } finally {
    await session.close();
    server.closeAllConnections();
    await new Promise(done => server.close(done));
  }
}

async function inspectBundle(app) {
  const resources = join(app, 'Contents/Resources');
  const manifest = JSON.parse(await readFile(join(resources, 'runtime/manifest.json'), 'utf8'));
  await stat(join(resources, 'runtime-required'));
  for (const file of ['runtime/LICENSE', 'runtime/lib/node_modules/npm/LICENSE', 'runtime/browser/LICENSE.headless_shell', 'ThirdParty/Pi-LICENSE', 'ThirdParty/Pi.json', 'ThirdParty/Sparkle-LICENSE']) {
    assert.ok((await stat(join(resources, file))).size > 0, `缺少许可证：${file}`);
  }
  const pi = JSON.parse(await readFile(join(resources, 'ThirdParty/Pi.json'), 'utf8'));
  assert.equal(createHash('sha256').update(await readFile(join(resources, 'ThirdParty/Pi-LICENSE'))).digest('hex'), pi.licenseSHA256);
  const packageLock = JSON.parse(await readFile(join(resources, 'agent-core/package-lock.json'), 'utf8'));
  assert.equal(packageLock.packages['node_modules/playwright-core'].version, manifest.browser.playwrightVersion);
  const browsers = JSON.parse(await readFile(join(resources, 'agent-core/node_modules/playwright-core/browsers.json'), 'utf8'));
  const browser = browsers.browsers.find(item => item.name === 'chromium-headless-shell');
  assert.equal(browser.browserVersion, manifest.browser.version);
  assert.equal(browser.revision, manifest.browser.revision);
  let binaries = 0;
  const magic = new Set(['feedface', 'feedfacf', 'cefaedfe', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']);
  async function visit(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isSymbolicLink()) {
        const target = resolve(dirname(path), readlinkSync(path));
        assert.ok(target.startsWith(app + '/'), `运行依赖指向应用外：${relative(app, path)}`);
      } else if (entry.isDirectory()) await visit(path);
      else if (entry.isFile()) {
        const descriptor = openSync(path, 'r');
        const header = Buffer.alloc(4);
        try { readSync(descriptor, header, 0, 4, 0); } finally { closeSync(descriptor); }
        if (!magic.has(header.toString('hex'))) continue;
        binaries += 1;
        // otool -L 也输出 LC_ID_DYLIB；自身 install name 不代表运行时依赖。
        const dependencies = loadedDylibDependencies(execFileSync('/usr/bin/otool', ['-l', path], { encoding: 'utf8' }));
        for (const dependency of dependencies) {
          assert.ok(/^(\/usr\/lib\/|\/System\/Library\/|@loader_path\/|@executable_path\/|@rpath\/)/.test(dependency), `运行依赖链接到应用外：${relative(app, path)} -> ${dependency}`);
        }
      }
    }
  }
  await visit(app);
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--all-architectures', app]);
  return { manifest, binaries };
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (isMain && process.argv[2] === '--worker') {
  await worker(resolve(process.argv[3]), resolve(process.argv[4]), process.argv[5] ?? 'empty');
} else if (isMain) {
  assert.ok(process.argv[2], '需要 Another You.app 的路径');
  const app = await realpath(resolve(process.argv[2]));
  const inspection = await inspectBundle(app);
  const directory = await mkdtemp(join(tmpdir(), 'another-you-bundled-test-'));
  try {
    const executions = [];
    for (const homeState of ['empty', 'synthetic-private-config']) {
      const isolated = await realpath(await mkdtemp(join(directory, 'case-')));
      await Promise.all(['home', 'data', 'tmp'].map(name => mkdir(join(isolated, name))));
      const environment = { HOME: join(isolated, 'home'), PATH: systemPath, TMPDIR: join(isolated, 'tmp'), LANG: 'en_US.UTF-8' };
      if (homeState === 'synthetic-private-config') {
        const legacy = join(environment.HOME, '.pi/agent');
        await mkdir(legacy, { recursive: true });
        await writeFile(join(legacy, 'settings.json'), JSON.stringify({ defaultProvider: 'developer-fixture', defaultModel: 'private-fixture' }));
        await writeFile(join(legacy, 'auth.json'), JSON.stringify({ 'developer-fixture': { type: 'api_key', key: 'synthetic-pi-fixture-key' } }));
        await writeFile(join(legacy, 'models.json'), JSON.stringify({ providers: { 'developer-fixture': { api: 'openai-completions', baseUrl: 'http://127.0.0.1:1', models: [{ id: 'private-fixture', name: 'private-fixture', contextWindow: 4096, maxTokens: 1024 }] } } }));
        await writeFile(join(environment.HOME, '.npmrc'), 'registry=http://127.0.0.1:1\n');
        environment.PI_CODING_AGENT_DIR = legacy;
        environment.OPENAI_API_KEY = 'synthetic-environment-key';
        environment.ANOTHER_YOU_BROWSER_EXECUTABLE = '/missing/private-browser';
        environment.PLAYWRIGHT_BROWSERS_PATH = '/missing/private-browser-cache';
      }
      const child = spawn(join(app, 'Contents/Resources/runtime/node'), ['--experimental-strip-types', script, '--worker', app, isolated, homeState], { cwd: isolated, env: environment, stdio: ['ignore', 'pipe', 'pipe'] });
      let stdout = '', stderr = '';
      child.stdout.on('data', chunk => { stdout += chunk; });
      child.stderr.on('data', chunk => { stderr += chunk; });
      const timeout = setTimeout(() => child.kill('SIGKILL'), 60_000);
      const [code, signal] = await once(child, 'exit');
      clearTimeout(timeout);
      assert.equal(code, 0, `隔离 HOME 验收失败（${homeState}） ${signal ?? ''}: ${stderr}`);
      executions.push(JSON.parse(stdout.trim()));
    }
    process.stdout.write(JSON.stringify({ passed: true, ...inspection, executions }, null, 2) + '\n');
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
