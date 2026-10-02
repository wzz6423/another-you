import { strict as assert } from 'node:assert';
import test from 'node:test';
import { loadedDylibDependencies } from './test-bundled-runtime.mjs';

function commands(entries) {
  return entries.map(([kind, name], index) => `Load command ${index}\n      cmd ${kind}\n  cmdsize 56\n     name ${name} (offset 24)\n`).join('');
}

test('自身 install name 不作为动态库加载依赖', () => {
  assert.deepEqual(loadedDylibDependencies(commands([
    ['LC_ID_DYLIB', './libEGL.dylib'],
    ['LC_LOAD_DYLIB', '/usr/lib/libSystem.B.dylib'],
  ])), ['/usr/lib/libSystem.B.dylib']);
});

test('保留所有依赖加载类型和实际外部相对路径', () => {
  const entries = [
    ['LC_LOAD_DYLIB', './libEGL.dylib'],
    ['LC_LOAD_WEAK_DYLIB', '/opt/homebrew/lib/external.dylib'],
    ['LC_REEXPORT_DYLIB', '@rpath/Local.framework/Local'],
    ['LC_LOAD_UPWARD_DYLIB', '@loader_path/Library With Spaces.dylib'],
    ['LC_LAZY_LOAD_DYLIB', '@executable_path/../Frameworks/Local.dylib'],
  ];
  assert.deepEqual(loadedDylibDependencies(commands([['LC_ID_DYLIB', './libEGL.dylib'], ...entries])), entries.map(([, name]) => name));
});

test('包含 universal binary 每个架构的加载依赖', () => {
  const output = `/tmp/fixture (architecture arm64):\n${commands([['LC_ID_DYLIB', 'self'], ['LC_LOAD_DYLIB', '/usr/lib/libSystem.B.dylib']])}/tmp/fixture (architecture x86_64):\n${commands([['LC_ID_DYLIB', 'self'], ['LC_LOAD_DYLIB', '/external/x86-only.dylib']])}`;
  assert.deepEqual(loadedDylibDependencies(output), ['/usr/lib/libSystem.B.dylib', '/external/x86-only.dylib']);
});

test('无法解析实际加载命令时失败，不跳过检查', () => {
  assert.throws(() => loadedDylibDependencies('Load command 0\n      cmd LC_LOAD_DYLIB\n  cmdsize 56\n'), /无法解析动态库加载命令/);
});
