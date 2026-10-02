import { readdir, readFile, rm } from 'node:fs/promises';
import { resolve, join, basename } from 'node:path';
import { pathToFileURL } from 'node:url';

export function platformMatches(values, target) {
  if (values === undefined) return true;
  if (!Array.isArray(values) || !values.every(value => typeof value === 'string')) throw new Error('无效的平台限制');
  if (values.includes(`!${target}`)) return false;
  const allowed = values.filter(value => !value.startsWith('!'));
  return allowed.length === 0 || allowed.includes(target) || allowed.includes('any');
}

// Pi 的发行包内含多平台依赖，npm --cpu 不会裁剪这些已打包的子目录。
export async function pruneNodePlatforms(root, os, cpu) {
  if (os !== 'darwin' || !['arm64', 'x64'].includes(cpu)) throw new Error('只支持 macOS arm64/x64');
  const removed = [];
  async function visit(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    const manifest = entries.find(entry => entry.name === 'package.json' && entry.isFile());
    if (manifest) {
      const metadata = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'));
      if (!platformMatches(metadata.os, os) || !platformMatches(metadata.cpu, cpu)) {
        await rm(directory, { recursive: true });
        removed.push(directory);
        return;
      }
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const prebuild = basename(directory) === 'prebuilds' ? /^(darwin|linux|win32|freebsd|android)-(arm64|x64|ia32|arm|riscv64)$/.exec(entry.name) : null;
      if (prebuild && (prebuild[1] !== os || prebuild[2] !== cpu)) {
        const path = join(directory, entry.name);
        await rm(path, { recursive: true });
        removed.push(path);
      } else { await visit(join(directory, entry.name)); }
    }
  }
  await visit(resolve(root));
  return removed;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [root, os, cpu] = process.argv.slice(2);
  if (!root || !os || !cpu) throw new Error('需要 node_modules 路径、平台和架构');
  const removed = await pruneNodePlatforms(root, os, cpu);
  process.stdout.write(`已清理 ${removed.length} 个不适用平台的打包依赖。\n`);
}
