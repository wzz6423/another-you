#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/another-you-toolchain-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
passed=0
fixture_app="${test_dir}/中文 Xcode.app"
fixture_developer="${fixture_app}/Contents/Developer"
fixture_sdk="${fixture_developer}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk"
fixture_swift="${fixture_developer}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
workspace="${test_dir}/中文 workspace"

fail() {
  printf '失败：%s（此前通过 %s 项）\n' "$1" "$passed" >&2
  cat "${test_dir}/stderr" >&2
  exit 1
}
pass() {
  passed=$((passed + 1))
  printf '通过 %s：%s\n' "$passed" "$1"
}
run_command() {
  rm -f "${test_dir}/invocation"
  "$@" >"${test_dir}/stdout" 2>"${test_dir}/stderr"
}
run_toolchain() { run_command "${repo_dir}/scripts/xcode-toolchain.sh" "$@"; }
expect_rejection() {
  local description="$1"
  shift
  if run_command "$@"; then fail "$description"; fi
  [[ ! -e "${test_dir}/invocation" ]] || fail '校验失败时不应执行 Swift'
  [[ -s "${test_dir}/stderr" ]] || fail '拒绝时应解释原因'
  pass "$description"
}

mkdir -p "${test_dir}/bin" "$(dirname -- "$fixture_swift")" "$fixture_sdk" "${workspace}/scripts"
cp "${repo_dir}/Makefile" "$workspace/"
cp "${repo_dir}/scripts/xcode-toolchain.sh" "${workspace}/scripts/"
cat > "${test_dir}/bin/xcode-select" <<'SELECT'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -p ]]
printf '%s\n' "$ANOTHER_YOU_FIXTURE_SELECTED"
SELECT
cat > "${test_dir}/bin/xcodebuild" <<'XCODE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -version && -n "$DEVELOPER_DIR" ]]
printf 'Xcode %s\nBuild version 27A266a\n' "$ANOTHER_YOU_FIXTURE_XCODE_VERSION"
XCODE
cat > "${test_dir}/bin/xcrun" <<'XCRUN'
#!/usr/bin/env bash
set -euo pipefail
sdk=""
toolchain=""
while (( $# > 0 )); do
  case "$1" in
    --sdk) sdk="$2"; shift 2 ;;
    --toolchain) toolchain="$2"; shift 2 ;;
    --show-sdk-version) printf '%s\n' "$ANOTHER_YOU_FIXTURE_SDK_VERSION"; exit 0 ;;
    --show-sdk-path)
      [[ "${ANOTHER_YOU_FIXTURE_SDK_ERROR:-0}" == 0 ]] || exit 3
      printf '%s\n' "$ANOTHER_YOU_FIXTURE_SDK_PATH"; exit 0 ;;
    swift)
      [[ "$sdk" == macosx && "$toolchain" == XcodeDefault ]] || exit 4
      shift
      exec "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" "$@" ;;
    *) exit 5 ;;
  esac
done
exit 6
XCRUN
cat > "$fixture_swift" <<'SWIFT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$DEVELOPER_DIR" "$SDKROOT" "$@" > "$ANOTHER_YOU_FIXTURE_INVOCATION"
exit "${ANOTHER_YOU_FIXTURE_SWIFT_EXIT:-0}"
SWIFT
cat > "${test_dir}/bin/swift" <<'PATH_SWIFT'
#!/usr/bin/env bash
printf '不应调用 PATH 中的 Swift\n' >&2
exit 99
PATH_SWIFT
chmod +x "${test_dir}/bin/"* "$fixture_swift"
export PATH="${test_dir}/bin:${PATH}"
export ANOTHER_YOU_FIXTURE_SELECTED="$fixture_developer"
export ANOTHER_YOU_FIXTURE_XCODE_VERSION=27.0
export ANOTHER_YOU_FIXTURE_SDK_VERSION=27.0
export ANOTHER_YOU_FIXTURE_SDK_PATH="$fixture_sdk"
export ANOTHER_YOU_FIXTURE_INVOCATION="${test_dir}/invocation"
unset DEVELOPER_DIR SDKROOT

run_toolchain || fail '所选完整 Xcode 27 应可用'
[[ "$(cat "${test_dir}/stdout")" == "$fixture_developer" ]] || fail '无参数 stdout 只能包含 Developer 目录'
[[ -s "${test_dir}/stderr" ]] || fail '工具链诊断应写入 stderr'
pass '接受完整 Xcode 27，stdout 与诊断分离'

DEVELOPER_DIR="$fixture_app" ANOTHER_YOU_FIXTURE_SELECTED=/Library/Developer/CommandLineTools run_toolchain || fail '显式 .app 应优先于 xcode-select'
[[ "$(cat "${test_dir}/stdout")" == "$fixture_developer" ]] || fail '.app 应解析为 Contents/Developer'
pass '支持中文空格 .app 路径，并优先使用 DEVELOPER_DIR'

expect_rejection '拒绝 Xcode 26' env ANOTHER_YOU_FIXTURE_XCODE_VERSION=26.4 "${repo_dir}/scripts/xcode-toolchain.sh" build
expect_rejection '拒绝 macOS SDK 26' env ANOTHER_YOU_FIXTURE_SDK_VERSION=26.4 "${repo_dir}/scripts/xcode-toolchain.sh" build
expect_rejection '拒绝仅有 Command Line Tools' env ANOTHER_YOU_FIXTURE_SELECTED="${test_dir}/CommandLineTools" "${repo_dir}/scripts/xcode-toolchain.sh" build
expect_rejection '显式无效 DEVELOPER_DIR 不回退到其他 Xcode' env DEVELOPER_DIR="${test_dir}/missing.app" "${repo_dir}/scripts/xcode-toolchain.sh" build
expect_rejection '拒绝不可解析的 Xcode 版本' env ANOTHER_YOU_FIXTURE_XCODE_VERSION=unknown "${repo_dir}/scripts/xcode-toolchain.sh" build
expect_rejection '拒绝空 SDK 版本' env ANOTHER_YOU_FIXTURE_SDK_VERSION= "${repo_dir}/scripts/xcode-toolchain.sh" build
expect_rejection 'SDK 路径查询失败时不执行 Swift' env ANOTHER_YOU_FIXTURE_SDK_ERROR=1 "${repo_dir}/scripts/xcode-toolchain.sh" build
expect_rejection 'SDK 路径无效时不执行 Swift' env ANOTHER_YOU_FIXTURE_SDK_PATH="${test_dir}/missing-sdk" "${repo_dir}/scripts/xcode-toolchain.sh" build

SDKROOT=/other/SDK run_toolchain build --package-path '中文 package' --scratch-path 'scratch with spaces' || fail '应使用所选工具链执行 Swift'
printf '%s\n' "$fixture_developer" "$fixture_sdk" build --package-path '中文 package' --scratch-path 'scratch with spaces' > "${test_dir}/expected"
cmp -s "${test_dir}/expected" "${test_dir}/invocation" || fail 'Swift 参数、DEVELOPER_DIR 和 SDKROOT 应保留正确边界'
pass '固定 Xcode Swift 和 SDKROOT，保留中文空格参数'

status=0
ANOTHER_YOU_FIXTURE_SWIFT_EXIT=42 run_toolchain test || status=$?
[[ "$status" == 42 ]] || fail '应透传 Swift 退出码'
pass '透传 Swift 失败退出码'

for target in build test-swift; do
  swift_command=build
  [[ "$target" != test-swift ]] || swift_command=test
  run_command make --no-print-directory -C "$workspace" "$target" "SWIFT_SCRATCH_PATH=${test_dir}/scratch with spaces" || fail "make $target 应通过工具链入口执行"
  printf '%s\n' "$fixture_developer" "$fixture_sdk" "$swift_command" --package-path macos/AnotherYou --scratch-path "${test_dir}/scratch with spaces" > "${test_dir}/expected"
  cmp -s "${test_dir}/expected" "${test_dir}/invocation" || fail "make $target 的工具链或 scratch 路径不正确"
  pass "make $target 使用所选 Swift、SDK 与独立 scratch"
done

printf '工具链测试通过：%s 项。\n' "$passed"
