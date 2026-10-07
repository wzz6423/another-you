import { build } from 'esbuild';
import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const root = fileURLToPath(new URL('.', import.meta.url));
const output = join(root, '../Sources/AnotherYouCore/Markdown');
await mkdir(output, { recursive: true });
await build({
  absWorkingDir: root, entryPoints: ['render.mjs', 'mermaid.mjs'], outdir: output,
  bundle: true, minify: true, format: 'iife', platform: 'browser', target: 'safari17',
  legalComments: 'external', logLevel: 'warning',
});
for (const name of ['index.html', 'markdown.css']) await cp(join(root, name), join(output, name));
await cp(join(root, 'node_modules/katex/dist/katex.min.css'), join(output, 'katex.min.css'));
await rm(join(output, 'fonts'), { recursive: true, force: true });
await cp(join(root, 'node_modules/katex/dist/fonts'), join(output, 'fonts'), { recursive: true });
const lock = JSON.parse(await readFile(join(root, 'package-lock.json'), 'utf8'));
const notices = [];
for (const [directory, metadata] of Object.entries(lock.packages)) {
  if (!directory || metadata.dev) continue;
  const files = await readdir(join(root, directory));
  for (const name of files.filter(name => /^(licen[cs]e|copying|notice)(\.|$)/i.test(name))) {
    const text = await readFile(join(root, directory, name), 'utf8');
    notices.push(`${directory} ${metadata.version}\n${text}`);
  }
}
await writeFile(join(output, 'LICENSES.txt'), notices.join('\n\n---\n\n'));
