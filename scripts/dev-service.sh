#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
run_dir="${repo_dir}/dist/dev"
app_path="${run_dir}/Another You.app"
symbols_path="${app_path}.dSYM"
app_binary="${app_path}/Contents/MacOS/AnotherYou"
state_file="${run_dir}/process"
log_file="${run_dir}/another-you.log"
lock_dir="${run_dir}/.lock"
staging_dir=""
pending_pid=""
pending_started=""
pending_state=""

fail() {
  printf '错误：%s\n' "$1" >&2
  exit 1
}

require_real_directory() {
  [[ ! -L "$1" ]] || fail "为避免修改链接指向的其他目录，请先移除符号链接：$1"
}

# 固定日期格式，同时让 ps 保留中文工作区路径，避免 C locale 将其转义。
process_start() { LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null || true; }
process_command() { LC_ALL=en_US.UTF-8 ps -p "$1" -ww -o command= 2>/dev/null || true; }

process_matches() {
  local pid="$1" started="$2" command="$3" status
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != 1 && -n "$started" && -n "$command" ]] || return 1
  [[ "$(process_start "$pid")" == "$started" && "$(process_command "$pid")" == "$command" ]] || return 1
  status="$(ps -p "$pid" -o stat= 2>/dev/null || true)"
  [[ -n "$status" && "$status" != *Z* ]]
}

wait_for_exit() {
  local attempt status
  for ((attempt = 0; attempt < 50; attempt++)); do
    if ! process_matches "$@"; then
      status="$(ps -p "$1" -o stat= 2>/dev/null || true)"
      if [[ -z "$status" || "$status" == *Z* ]]; then wait "$1" 2>/dev/null || true; fi
      return 0
    fi
    sleep 0.1
  done
  return 1
}

stop_process() {
  process_matches "$@" || return 0
  kill -TERM "$1" 2>/dev/null || true
  if ! wait_for_exit "$@"; then
    process_matches "$@" && kill -KILL "$1" 2>/dev/null || true
    wait_for_exit "$@" || fail "进程 $1 未能退出，已保留运行状态供排查。"
  fi
}

stop_process_tree() {
  local pid="$1" started="$2" command="$3" child child_started child_command
  process_matches "$pid" "$started" "$command" || return 0
  # 先关闭 sidecar，让它完成状态写入，并由仍存活的宿主回收子进程。
  while IFS= read -r child; do
    process_matches "$pid" "$started" "$command" || break
    child_started="$(process_start "$child")"
    child_command="$(process_command "$child")"
    [[ "$(ps -p "$child" -o ppid= 2>/dev/null | tr -d ' ' || true)" == "$pid" ]] || continue
    stop_process "$child" "$child_started" "$child_command"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  stop_process "$pid" "$started" "$command"
}

stop_instance() {
  local pid started command
  [[ -e "$state_file" || -L "$state_file" ]] || return 0
  if [[ ! -L "$state_file" ]] && {
    IFS= read -r pid && IFS= read -r started && IFS= read -r command
  } < "$state_file" && [[ "$command" == "$app_binary" ]] && process_matches "$pid" "$started" "$command"; then
    stop_process_tree "$pid" "$started" "$command"
  else
    printf '运行记录已失效，未向其他进程发送信号。\n'
  fi
  rm -f -- "$state_file"
}

cleanup() {
  local pending_command="$app_binary"
  if [[ -n "$pending_pid" ]]; then
    # 启动失败的直属子进程可能已 exec 成其他命令，仍应由创建它的脚本回收。
    if [[ "$(ps -p "$pending_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)" == "$$" ]]; then
      pending_started="${pending_started:-$(process_start "$pending_pid")}"
      pending_command="$(process_command "$pending_pid")"
    fi
    stop_process_tree "$pending_pid" "$pending_started" "$pending_command"
    rm -f -- "$state_file"
  fi
  [[ -z "$pending_state" ]] || rm -f -- "$pending_state"
  [[ -z "$staging_dir" ]] || rm -rf -- "$staging_dir"
  rmdir "$lock_dir" 2>/dev/null || true
  rmdir "$run_dir" "${repo_dir}/dist" 2>/dev/null || true
}

start_instance() {
  local pid started attempt
  staging_dir="$(mktemp -d "${run_dir}/.build.XXXXXX")"
  CONFIGURATION=debug ANOTHER_YOU_UPDATES_ENABLED=0 OUTPUT_DIRECTORY="$staging_dir" "${repo_dir}/scripts/build-app.sh"
  [[ -x "${staging_dir}/Another You.app/Contents/MacOS/AnotherYou" ]] || fail "构建未生成 Another You.app 可执行文件。"
  [[ -s "${staging_dir}/Another You.app.dSYM/Contents/Resources/DWARF/AnotherYou" ]] || fail "构建未生成 Debug 调试符号。"
  stop_instance
  rm -rf -- "$app_path" "$symbols_path"
  mv "${staging_dir}/Another You.app" "$app_path"
  mv "${staging_dir}/Another You.app.dSYM" "$symbols_path"
  rm -f -- "$log_file"
  nohup "$app_binary" </dev/null >"$log_file" 2>&1 &
  pending_pid=$!
  pid="$pending_pid"
  started="$(process_start "$pid")"
  pending_started="$started"
  for ((attempt = 0; attempt < 50; attempt++)); do
    [[ "$(process_command "$pid")" == "$app_binary" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if ! process_matches "$pid" "$started" "$app_binary"; then
    fail "开发应用启动失败，请查看：$log_file"
  fi
  pending_state="$(mktemp "${run_dir}/.process.XXXXXX")"
  printf '%s\n' "$pid" "$started" "$app_binary" > "$pending_state"
  mv -f -- "$pending_state" "$state_file"
  pending_state=""
  sleep 0.5
  process_matches "$pid" "$started" "$app_binary" || fail "开发应用启动后退出，请查看：$log_file"
  pending_pid=""
  printf 'Another You Debug 已启动（PID %s）。停止：make stop\n日志：%s\n' "$pid" "$log_file"
}

clean_outputs() {
  local directory
  for directory in "${repo_dir}/dist/macos" "${repo_dir}/macos" "${repo_dir}/macos/AnotherYou" "${repo_dir}/agent-core"; do
    require_real_directory "$directory"
  done
  stop_instance
  rm -rf -- "$app_path" "$symbols_path" "$log_file" "${run_dir}"/.build.* "${run_dir}"/.process.* \
    "${repo_dir}/dist/macos/Another You.app" "${repo_dir}/dist/macos/Another You.app.dSYM" \
    "${repo_dir}/macos/AnotherYou/.build" "${repo_dir}/agent-core/coverage"
  rmdir "${repo_dir}/dist/macos" 2>/dev/null || true
  printf '已清理开发应用和构建、测试产物；个人数据、依赖和 Pi 源码缓存保留。\n'
}

case "${1:-}" in
  run|stop|clean) ;;
  *) printf '用法：%s {run|stop|clean}\n' "$0" >&2; exit 64 ;;
esac

require_real_directory "${repo_dir}/dist"
require_real_directory "$run_dir"
mkdir -p "$run_dir"
mkdir "$lock_dir" 2>/dev/null || fail "另一个开发命令正在执行；若它已异常退出，请确认后移除：$lock_dir"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$1" in
  run) start_instance ;;
  stop) stop_instance; printf '本工作区的 Another You 开发实例已停止。\n' ;;
  clean) clean_outputs ;;
esac
