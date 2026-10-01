#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${OUTPUT_DIRECTORY:-${repo_dir}/dist/macos}"
bundle_node="${BUNDLE_NODE:-0}"
node_path="${ANOTHER_YOU_NODE:-$(command -v node || true)}"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "应用打包需要 macOS。" >&2
  exit 1
fi
if [[ "$bundle_node" != 0 && "$bundle_node" != 1 ]]; then
  echo "BUNDLE_NODE 必须为 0（本机开发）或 1（内置 Node）。" >&2
  exit 1
fi
if [[ ! -x "$node_path" ]]; then
  echo "需要 Node 22.19+；可通过 ANOTHER_YOU_NODE 指定可执行文件。" >&2
  exit 1
fi
"$node_path" -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 19)) process.exit(1)'

if [[ "$bundle_node" == 1 ]]; then
  # Homebrew Node 的外部动态库不会随单个可执行文件被复制。
  if otool -L "$node_path" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)' >/dev/null; then
    echo "该 Node 依赖外部动态库。内置运行时请使用 nodejs.org 官方 macOS 二进制，或 BUNDLE_NODE=0 本机开发。" >&2
    exit 1
  fi
fi

mkdir -p "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd)"
app_path="${output_dir}/Another You.app"
if [[ -e "$app_path" ]]; then
  echo "输出已存在，请指定新的 OUTPUT_DIRECTORY：$app_path" >&2
  exit 1
fi

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/another-you-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
staged_app="${build_dir}/Another You.app"
resources="${staged_app}/Contents/Resources"
mkdir -p "${staged_app}/Contents/MacOS" "${resources}/agent-core"

swift build --package-path "${repo_dir}/macos/AnotherYou" --scratch-path "${build_dir}/swift" -c release --product AnotherYou
bin_dir="$(swift build --package-path "${repo_dir}/macos/AnotherYou" --scratch-path "${build_dir}/swift" -c release --show-bin-path)"
cp "${bin_dir}/AnotherYou" "${staged_app}/Contents/MacOS/AnotherYou"
cp -R "${repo_dir}/agent-core/src" "${resources}/agent-core/src"
cp "${repo_dir}/agent-core/package.json" "${repo_dir}/agent-core/package-lock.json" "${repo_dir}/agent-core/pi-source.lock.json" "${resources}/agent-core/"
(
  cd -- "${resources}/agent-core"
  npm ci --omit=dev --ignore-scripts --no-audit --no-fund
)

if [[ "$bundle_node" == 1 ]]; then
  mkdir -p "${resources}/runtime"
  cp "$node_path" "${resources}/runtime/node"
  node_license="$(dirname -- "$node_path")/../LICENSE"
  if [[ -f "$node_license" ]]; then
    cp "$node_license" "${resources}/runtime/LICENSE"
  fi
  codesign --force --sign - "${resources}/runtime/node"
fi

cat > "${staged_app}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.anotheryou.mac</string>
  <key>CFBundleName</key><string>Another You</string>
  <key>CFBundleDisplayName</key><string>Another You</string>
  <key>CFBundleExecutable</key><string>AnotherYou</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

plutil -lint "${staged_app}/Contents/Info.plist"
codesign --force --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"
mv "$staged_app" "$app_path"
printf '开发应用已生成（未公证）：%s\n' "$app_path"
if [[ "$bundle_node" == 0 ]]; then
  echo "此应用依赖本机 Node 22.19+，不适合直接分发。"
fi
