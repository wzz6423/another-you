#!/usr/bin/env node
import { strict as assert } from 'node:assert';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { monitorEventLoopDelay, performance } from 'node:perf_hooks';
import { fileURLToPath, pathToFileURL } from 'node:url';

function summary(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const percentile = p => Number(sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))].toFixed(3));
  return { samples: values.length, p50: percentile(0.5), p95: percentile(0.95), max: percentile(1) };
}

async function sample(root, directory) {
  const moduleURL = async name => {
    const directory = join(root, 'node_modules', name);
    const manifest = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'));
    return pathToFileURL(join(directory, manifest.exports?.['.']?.import ?? manifest.main)).href;
  };
  const eventLoop = monitorEventLoopDelay({ resolution: 10 });
  eventLoop.enable();
  await new Promise(done => setTimeout(done, 20));
  const cpu = process.cpuUsage();
  const imports = {};
  const modules = {};
  for (const name of ['@earendil-works/pi-agent-core', '@earendil-works/pi-coding-agent']) {
    const url = await moduleURL(name);
    const started = performance.now();
    modules[name] = await import(url);
    imports[name] = Number((performance.now() - started).toFixed(3));
  }
  const { Agent } = modules['@earendil-works/pi-agent-core'];
  const { createAssistantMessageEventStream } = await import(await moduleURL('@earendil-works/pi-ai'));
  const { createAgentTools } = await import(join(root, 'src/tools.ts'));
  const { createDefaultConfig } = await import(join(root, 'src/config.ts'));
  await new Promise(done => setTimeout(done, 20));
  const importEventLoopMaxMs = Number((eventLoop.max / 1e6).toFixed(3));
  eventLoop.reset();
  const filesystem = createAgentTools(createDefaultConfig(directory)).find(tool => tool.name === 'filesystem');
  const file = join(directory, 'fixture.txt');
  await writeFile(file, 'local fixture '.repeat(300));
  const args = { action: 'read', path: file };
  const direct = [], loop = [];
  let toolCalls = 0;
  const model = { id: 'fixture', name: 'fixture', provider: 'fixture', api: 'openai-completions', baseUrl: 'http://127.0.0.1:1', reasoning: false, input: ['text'], contextWindow: 32768, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
  for (let index = 0; index < 100; index += 1) {
    let started = performance.now();
    await filesystem.execute('direct', args);
    direct.push(performance.now() - started);
    const agent = new Agent({ initialState: { model, systemPrompt: 'local fixture', tools: [filesystem], thinkingLevel: 'off' }, streamFn: (_model, context) => {
      const stream = createAssistantMessageEventStream();
      const complete = context.messages.at(-1)?.role === 'toolResult';
      const message = { role: 'assistant', content: complete ? [{ type: 'text', text: 'fixture completed' }] : [{ type: 'toolCall', id: `fixture-${index}`, name: 'filesystem', arguments: args }], api: model.api, provider: model.provider, model: model.id, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: complete ? 'stop' : 'toolUse', timestamp: Date.now() };
      queueMicrotask(() => { stream.push({ type: 'start', partial: message }); stream.push({ type: 'done', reason: message.stopReason, message }); stream.end(); });
      return stream;
    } });
    agent.subscribe(event => { if (event.type === 'tool_execution_start') toolCalls += 1; });
    started = performance.now();
    await agent.prompt('Read the local fixture');
    assert.equal(agent.state.messages.at(-1)?.stopReason, 'stop');
    loop.push(performance.now() - started);
    await new Promise(done => setImmediate(done));
  }
  assert.equal(toolCalls, 100);
  await new Promise(done => setTimeout(done, 20));
  eventLoop.disable();
  const used = process.cpuUsage(cpu);
  return { node: process.versions.node, importsMs: imports, importEventLoopMaxMs, filesystemDirectMs: summary(direct), piFileToolLoopMs: summary(loop), toolCalls, steadyEventLoopDelayMs: { resolution: 10, p99: Number((eventLoop.percentile(99) / 1e6).toFixed(3)), max: Number((eventLoop.max / 1e6).toFixed(3)) }, cpuMs: { user: used.user / 1000, system: used.system / 1000 }, memoryMiB: { rss: process.memoryUsage().rss / 1048576, maxRSS: process.resourceUsage().maxRSS / 1024 } };
}

const script = fileURLToPath(import.meta.url);
if (process.argv[2] === '--sample') {
  process.stdout.write('{"phase":"ready"}\n');
  process.stdout.write(JSON.stringify(await sample(resolve(process.argv[3]), resolve(process.argv[4]))) + '\n');
} else {
  const root = resolve(process.argv[2] ?? 'agent-core');
  const node = process.argv[3] ?? process.execPath;
  const directory = await mkdtemp(join(tmpdir(), 'another-you-pi-benchmark-'));
  const results = [];
  try {
    for (let index = 0; index < 7; index += 1) {
      const home = join(directory, String(index));
      await mkdir(home);
      const started = performance.now();
      const child = spawn(node, ['--experimental-strip-types', script, '--sample', root, home], { cwd: home, env: { HOME: home, PATH: '/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR: home }, stdio: ['ignore', 'pipe', 'pipe'] });
      let stdout = '', stderr = '';
      let processBootMs;
      child.stdout.on('data', chunk => { processBootMs ??= Number((performance.now() - started).toFixed(3)); stdout += chunk; });
      child.stderr.on('data', chunk => { stderr += chunk; });
      const timeout = setTimeout(() => child.kill('SIGKILL'), 30_000);
      const [code, signal] = await once(child, 'exit');
      clearTimeout(timeout);
      assert.equal(code, 0, `Pi benchmark failed ${signal ?? ''}: ${stderr}`);
      results.push({ processBootMs, processWallMs: Number((performance.now() - started).toFixed(3)), ...JSON.parse(stdout.trim().split('\n').at(-1)) });
    }
    process.stdout.write(JSON.stringify({ networkModelLatencyIncluded: false, method: '7 fresh processes; each executes 100 real filesystem reads directly and through the unchanged official Pi Agent with an in-memory model stream', processBootMs: summary(results.map(value => value.processBootMs)), processWallMs: summary(results.map(value => value.processWallMs)), samples: results }, null, 2) + '\n');
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
