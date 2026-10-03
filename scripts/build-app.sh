#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${OUTPUT_DIRECTORY:-${repo_dir}/dist/macos}"
bundle_node="${BUNDLE_NODE:-1}"
build_arch="${BUILD_ARCH:-$(uname -m)}"
node_path="${ANOTHER_YOU_NODE:-}"
runtime_cache="${ANOTHER_YOU_RUNTIME_CACHE:-${repo_dir}/agent-core/.cache/runtime}"
configuration="${CONFIGURATION:-release}"

case "$configuration" in
  debug|release) ;;
  *) echo "CONFIGURATION 必须为 debug 或 release。" >&2; exit 1 ;;
esac
export CONFIGURATION="$configuration"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "应用打包需要 macOS。" >&2
  exit 1
fi
developer_dir="$("${repo_dir}/scripts/xcode-toolchain.sh")"
export DEVELOPER_DIR="$developer_dir"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
python3 "${repo_dir}/scripts/release.py" check-build-settings
if [[ "$build_arch" != arm64 && "$build_arch" != x86_64 ]]; then
  echo "BUILD_ARCH 必须为 arm64 或 x86_64。" >&2
  exit 1
fi
if [[ "$bundle_node" != 0 && "$bundle_node" != 1 ]]; then
  echo "BUNDLE_NODE 必须为 0（本机开发）或 1（内置 Node）。" >&2
  exit 1
fi
mkdir -p "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd)"
app_path="${output_dir}/Another You.app"
symbols_path="${app_path}.dSYM"
if [[ -e "$app_path" || -L "$app_path" || -e "$symbols_path" || -L "$symbols_path" ]]; then
  echo "输出已存在，请指定新的 OUTPUT_DIRECTORY：$app_path" >&2
  exit 1
fi

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/another-you-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

if [[ "$bundle_node" == 1 ]]; then
  if [[ -z "$node_path" ]]; then
    python3 -B "${repo_dir}/scripts/prepare-runtime.py" node --arch "$build_arch" --output "${build_dir}/node" --cache "$runtime_cache"
    node_path="${build_dir}/node/bin/node"
  fi
  node_license="${ANOTHER_YOU_NODE_LICENSE:-$(dirname -- "$node_path")/../LICENSE}"
  if [[ ! -s "$node_license" ]]; then
    echo "内置 Node 必须附带 LICENSE；可设置 ANOTHER_YOU_NODE_LICENSE。" >&2
    exit 1
  fi
  if [[ "$(lipo -archs "$node_path")" != "$build_arch" ]]; then
    echo "内置 Node 架构必须与 BUILD_ARCH 相同。" >&2
    exit 1
  fi
  # Homebrew Node 的外部动态库不会随单个可执行文件被复制。
  if otool -L "$node_path" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)' >/dev/null; then
    echo "该 Node 依赖外部动态库。内置运行时请使用 nodejs.org 官方 macOS 二进制，或 BUNDLE_NODE=0 本机开发。" >&2
    exit 1
  fi
  npm_root="$(dirname -- "$node_path")/../lib/node_modules/npm"
  if [[ ! -s "${npm_root}/bin/npm-cli.js" || ! -s "${npm_root}/LICENSE" ]]; then
    echo "内置 Node 需要官方发行目录中的 npm 与许可证。" >&2
    exit 1
  fi
  node_version="$(python3 - "$node_path" <<'PY'
from pathlib import Path
import re
import sys
header = (Path(sys.argv[1]).resolve().parent.parent / 'include/node/node_version.h').read_text()
version = tuple(int(re.search(r'#define NODE_' + part + r'_VERSION\s+(\d+)', header)[1]) for part in ('MAJOR', 'MINOR', 'PATCH'))
if version < (22, 19, 0):
    raise SystemExit('内置 Node 版本需要 22.19+')
print('.'.join(map(str, version)))
PY
)"
  build_node="$node_path"
  if [[ "$build_arch" != "$(uname -m)" ]]; then
    python3 -B "${repo_dir}/scripts/prepare-runtime.py" node --arch "$(uname -m)" --output "${build_dir}/host-node" --cache "$runtime_cache"
    build_node="${build_dir}/host-node/bin/node"
  fi
  npm_command=("$build_node" "${npm_root}/bin/npm-cli.js")
else
  node_path="${node_path:-$(command -v node || true)}"
  build_node="$node_path"
  npm_command=(npm)
fi
if [[ ! -x "$build_node" ]]; then
  echo "需要 Node 22.19+；可通过 ANOTHER_YOU_NODE 指定可执行文件。" >&2
  exit 1
fi
"$build_node" -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 19)) process.exit(1)'

staged_app="${build_dir}/Another You.app"
resources="${staged_app}/Contents/Resources"
mkdir -p "${staged_app}/Contents/MacOS" "${resources}/agent-core"

swift_build=("${repo_dir}/scripts/xcode-toolchain.sh" build --package-path "${repo_dir}/macos/AnotherYou"
  --scratch-path "${build_dir}/swift" -c "$configuration" --arch "$build_arch")
"${swift_build[@]}" --product AnotherYou -Xlinker -rpath -Xlinker @executable_path/../Frameworks
bin_dir="$("${swift_build[@]}" --show-bin-path)"
linked_sdk_version="$(xcrun vtool -show-build "${bin_dir}/AnotherYou" | awk '$1 == "sdk" && !found { print $2; found = 1 }')"
if [[ "$linked_sdk_version" != "$sdk_version" ]]; then
  echo "链接的 macOS SDK 为 ${linked_sdk_version:-未知}，预期为 ${sdk_version}；应用可能使用旧窗口兼容模式。" >&2
  exit 1
fi
cp "${bin_dir}/AnotherYou" "${staged_app}/Contents/MacOS/AnotherYou"
if [[ "$configuration" == debug ]]; then
  # scratch 会在退出时清理，先把调试映射中的对象文件合并到独立符号包。
  xcrun dsymutil "${bin_dir}/AnotherYou" -o "${build_dir}/Another You.app.dSYM"
fi
if [[ -d "${bin_dir}/AnotherYou_AnotherYouCore.bundle" ]]; then
  cp -R "${bin_dir}/AnotherYou_AnotherYouCore.bundle" "$resources/"
fi
icon_name="AppIcon"
if [[ "$configuration" == debug ]]; then
  icon_name="AppIconDark"
fi
cp "${repo_dir}/macos/AnotherYou/Sources/AnotherYouCore/Resources/${icon_name}.icns" "${resources}/AppIcon.icns"
cp -R "${repo_dir}/agent-core/src" "${resources}/agent-core/src"
cp "${repo_dir}/agent-core/package.json" "${repo_dir}/agent-core/package-lock.json" "${repo_dir}/agent-core/pi-source.lock.json" "${resources}/agent-core/"
(
  cd -- "${resources}/agent-core"
  touch "${build_dir}/npmrc" "${build_dir}/global-npmrc"
  "${npm_command[@]}" ci --omit=dev --ignore-scripts --no-audit --no-fund --os=darwin --cpu="${build_arch/x86_64/x64}" \
    --userconfig="${build_dir}/npmrc" --globalconfig="${build_dir}/global-npmrc" --registry=https://registry.npmjs.org --cache="${runtime_cache}/npm"
  "$build_node" "${repo_dir}/scripts/prune-node-platforms.mjs" node_modules darwin "${build_arch/x86_64/x64}"
)

python3 - "$repo_dir" "$resources" <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import sys
root, resources = map(Path, sys.argv[1:])
source = json.loads((root / 'agent-core/pi-source.lock.json').read_text())
provenance = json.loads((root / 'licenses/Pi.json').read_text())
license_path = root / 'licenses/Pi-LICENSE'
if provenance['commit'] != source['sdkCommit'] or provenance['version'] != source['sdkVersion'] or hashlib.sha256(license_path.read_bytes()).hexdigest() != provenance['licenseSHA256']:
    raise SystemExit('Pi SDK 许可证来源与锁定版本不匹配')
notices = resources / 'ThirdParty'
notices.mkdir(exist_ok=True)
for name in ('Pi-LICENSE', 'Pi.json'):
    shutil.copy2(root / 'licenses' / name, notices / name)
PY

if [[ "$bundle_node" == 1 ]]; then
  mkdir -p "${resources}/runtime/lib/node_modules"
  cp "$node_path" "${resources}/runtime/node"
  cp "$node_license" "${resources}/runtime/LICENSE"
  cp -R "$npm_root" "${resources}/runtime/lib/node_modules/npm"
  ln -s lib/node_modules/npm/bin/npm-cli.js "${resources}/runtime/npm"
  ln -s lib/node_modules/npm/bin/npx-cli.js "${resources}/runtime/npx"
  python3 -B "${repo_dir}/scripts/prepare-runtime.py" browser --arch "$build_arch" --output "${resources}/runtime/browser" --cache "$runtime_cache"
  "$build_node" --input-type=module - "${repo_dir}/scripts/runtime-dependencies.json" "${resources}/runtime" "$build_arch" "$node_version" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const [lockPath, directory, arch, nodeVersion] = process.argv.slice(2);
const lock = JSON.parse(readFileSync(lockPath, 'utf8'));
const browser = JSON.parse(readFileSync(join(directory, '../agent-core/node_modules/playwright-core/browsers.json'), 'utf8')).browsers.find(item => item.name === 'chromium-headless-shell');
if (browser?.browserVersion !== lock.browser.version || browser?.revision !== lock.browser.revision) throw new Error('浏览器运行依赖与已安装 Playwright 不匹配');
const manifest = {
  schemaVersion: 1, platform: 'darwin', arch,
  node: { version: nodeVersion, license: 'LICENSE' },
  npm: { version: JSON.parse(readFileSync(join(directory, 'lib/node_modules/npm/package.json'), 'utf8')).version, license: 'lib/node_modules/npm/LICENSE' },
  browser: { name: 'chromium-headless-shell', version: lock.browser.version, revision: lock.browser.revision, playwrightVersion: lock.browser.playwrightVersion, executable: 'browser/chrome-headless-shell', license: 'browser/LICENSE.headless_shell' },
};
writeFileSync(join(directory, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
JS
  touch "${resources}/runtime-required"
fi

framework="${bin_dir}/Sparkle.framework"
if [[ ! -d "$framework" ]]; then
  framework="$(find "${build_dir}/swift/artifacts" -type d -path '*/macos-arm64_x86_64/Sparkle.framework' -print -quit)"
fi
sparkle_artifact="$(find "${build_dir}/swift/artifacts" -type d -name Sparkle.xcframework -print -quit)"
python3 "${repo_dir}/scripts/release.py" prepare-bundle \
  --app "$staged_app" --framework "$framework" --arch "$build_arch" \
  --sparkle-license "$(dirname -- "$sparkle_artifact")/LICENSE"
plutil -lint "${staged_app}/Contents/Info.plist"
if [[ "$configuration" == debug ]]; then
  mv "${build_dir}/Another You.app.dSYM" "$symbols_path"
fi
mv "$staged_app" "$app_path"
printf '%s 应用已生成（此步骤不执行公证）：%s\n' "$configuration" "$app_path"
if [[ "$bundle_node" == 0 ]]; then
  echo "此应用依赖本机 Node 22.19+，不适合直接分发。"
fi
