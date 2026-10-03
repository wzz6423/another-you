#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  echo '请提供要执行的测试命令。' >&2
  exit 2
fi

test_pi_directory="$(mktemp -d "${TMPDIR:-/tmp}/another-you-test-pi.XXXXXX")"
trap 'rm -rf -- "$test_pi_directory"' EXIT

stop_tests() {
  local signal="$1" status="$2"
  trap '' INT TERM
  kill -s "$signal" -- "-${test_command_pid}" 2>/dev/null || true
  wait "$test_command_pid" 2>/dev/null || true
  exit "$status"
}
trap 'stop_tests INT 130' INT
trap 'stop_tests TERM 143' TERM

# 测试中的自动发现不能读取开发者或自托管 runner 的个人 Pi 账户。
export PI_CODING_AGENT_DIR="${test_pi_directory}/pi"
# 独立进程组让中断同时到达 npm/Swift 启动的子进程，后台 wait 才能及时处理信号。
set -m
"$@" <&0 &
test_command_pid=$!
set +m
wait "$test_command_pid"
