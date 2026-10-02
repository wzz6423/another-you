#!/usr/bin/env bash
set -euo pipefail

developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ "$developer_dir" == *.app ]]; then
  developer_dir="${developer_dir}/Contents/Developer"
fi
if [[ ! -x "$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ||
      ! -d "$developer_dir/Platforms/MacOSX.platform/Developer/SDKs" ]]; then
  echo "需要完整 Xcode 27+；请通过 DEVELOPER_DIR 或 xcode-select 选择 Xcode，不能只使用 Command Line Tools。" >&2
  exit 1
fi
export DEVELOPER_DIR="$developer_dir"

# 消费完整输出，避免提前关闭管道使 xcodebuild 后续写入失败。
xcode_version="$(xcodebuild -version | awk '$1 == "Xcode" && !found { print $2; found = 1 }')"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ ! "$xcode_version" =~ ^[0-9]+([.][0-9]+)*$ || ! "$sdk_version" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
  echo "无法确认所选 Xcode 与 macOS SDK 版本。" >&2
  exit 1
fi
if (( ${xcode_version%%.*} < 27 || ${sdk_version%%.*} < 27 )); then
  echo "需要 Xcode 27+ 与 macOS SDK 27+；当前为 Xcode ${xcode_version}（SDK ${sdk_version}）。" >&2
  exit 1
fi
printf '使用 Xcode %s（macOS SDK %s）。\n' "$xcode_version" "$sdk_version" >&2

if (( $# == 0 )); then
  printf '%s\n' "$developer_dir"
  exit 0
fi

# 不继承其他项目留下的 SDKROOT，也不使用 PATH 中的独立 Swift 工具链。
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
if [[ ! -d "$sdk_path" ]]; then
  echo "所选 Xcode 未提供有效的 macOS SDK 路径。" >&2
  exit 1
fi
export SDKROOT="$sdk_path"
exec xcrun --toolchain XcodeDefault --sdk macosx swift "$@"
