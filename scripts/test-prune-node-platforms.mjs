import { strict as assert } from 'node:assert';
import test from 'node:test';
import { mkdtemp, mkdir, writeFile, access, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { platformMatches, pruneNodePlatforms } from './prune-node-platforms.mjs';

test('平台白名单与否定规则', () => {
  assert.equal(platformMatches(undefined, 'arm64'), true);
  assert.equal(platformMatches(['!x64'], 'arm64'), true);
  assert.equal(platformMatches(['arm64', '!arm64'], 'arm64'), false);
  assert.equal(platformMatches(['x64'], 'arm64'), false);
  assert.throws(() => platformMatches('arm64', 'arm64'));
});

test('仅清理暂存依赖的异平台包，保留当前架构与通用文件', async t => {
  const root = await mkdtemp(join(tmpdir(), 'another-you-platforms-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const dependencies = { 'pi/node_modules/@esbuild/darwin-x64': { os: ['darwin'], cpu: ['x64'] }, 'pi/node_modules/@esbuild/darwin-arm64': { os: ['darwin'], cpu: ['arm64'] }, 'pi/node_modules/linux': { os: ['linux'] }, 'js-package': {} };
  for (const [name, metadata] of Object.entries(dependencies)) {
    await mkdir(join(root, name), { recursive: true });
    await writeFile(join(root, name, 'package.json'), JSON.stringify(metadata));
    await writeFile(join(root, name, 'binary'), 'fixture');
  }
  for (const arch of ['arm64', 'x64']) {
    await mkdir(join(root, `pi/native/prebuilds/darwin-${arch}`), { recursive: true });
    await writeFile(join(root, `pi/native/prebuilds/darwin-${arch}/fixture.node`), 'fixture');
  }
  const removed = await pruneNodePlatforms(root, 'darwin', 'arm64');
  assert.equal(removed.length, 3);
  await access(join(root, 'pi/native/prebuilds/darwin-arm64/fixture.node'));
  await assert.rejects(access(join(root, 'pi/native/prebuilds/darwin-x64/fixture.node')));
  await access(join(root, 'pi/node_modules/@esbuild/darwin-arm64/binary'));
  await access(join(root, 'js-package/binary'));
  await assert.rejects(access(join(root, 'pi/node_modules/@esbuild/darwin-x64')));
  await assert.rejects(pruneNodePlatforms(root, 'darwin', 'wrong'));
});
