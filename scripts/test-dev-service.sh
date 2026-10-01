#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=en_US.UTF-8

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/another-you-dev-test.XXXXXX")"
test_dir="$(cd -- "$test_dir" && pwd -P)"
workspace="${test_dir}/中文 workspace with spaces"
app_binary="${workspace}/dist/dev/Another You.app/Contents/MacOS/AnotherYou"
state_file="${workspace}/dist/dev/process"
unrelated_pid=""
passed=0

cleanup() {
  local command
  if [[ -x "${workspace}/scripts/dev-service.sh" ]]; then
    "${workspace}/scripts/dev-service.sh" stop >/dev/null 2>&1 || true
  fi
  if [[ -f "${test_dir}/pids" ]]; then
    while IFS= read -r pid; do
      command="$(ps -p "$pid" -ww -o command= 2>/dev/null || true)"
      if [[ "$command" == "$app_binary" || "$command" == "${test_dir}/pids 60" ]]; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done < "${test_dir}/pids"
  fi
  if [[ -n "$unrelated_pid" ]]; then
    kill -TERM "$unrelated_pid" 2>/dev/null || true
    wait "$unrelated_pid" 2>/dev/null || true
  fi
  rm -rf -- "$test_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf '失败：%s（此前通过 %s 项）\n' "$1" "$passed" >&2
  [[ ! -f "${test_dir}/command.log" ]] || cat "${test_dir}/command.log" >&2
  exit 1
}

pass() {
  passed=$((passed + 1))
  printf '通过 %s：%s\n' "$passed" "$1"
}

is_running() {
  local status
  status="$(ps -p "$1" -o stat= 2>/dev/null || true)"
  [[ -n "$status" && "$status" != *Z* ]]
}

run_dev() {
  ANOTHER_YOU_FIXTURE_PIDS="${test_dir}/pids" \
    ANOTHER_YOU_FIXTURE_CHILD="${test_dir}/child" \
    ANOTHER_YOU_FIXTURE_EVENTS="${test_dir}/events" \
    "${workspace}/scripts/dev-service.sh" "$@" >"${test_dir}/command.log" 2>&1
}

run_make() {
  ANOTHER_YOU_FIXTURE_PIDS="${test_dir}/pids" \
    ANOTHER_YOU_FIXTURE_CHILD="${test_dir}/child" \
    ANOTHER_YOU_FIXTURE_EVENTS="${test_dir}/events" \
    make -C "$workspace" "$@" >"${test_dir}/command.log" 2>&1
}

mkdir -p "${workspace}/scripts"
cp "${repo_dir}/scripts/dev-service.sh" "${workspace}/scripts/"
cp "${repo_dir}/Makefile" "${workspace}/"
cat > "${workspace}/scripts/build-app.sh" <<'BUILD'
#!/usr/bin/env bash
set -euo pipefail
fixture_dir="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
[[ ! -f "${fixture_dir}/fail-build" ]] || exit 42
mkdir -p "${OUTPUT_DIRECTORY}/Another You.app/Contents/MacOS"
cp "${fixture_dir}/fixture-app" "${OUTPUT_DIRECTORY}/Another You.app/Contents/MacOS/AnotherYou"
BUILD
chmod +x "${workspace}/scripts/build-app.sh"

# 使用真实 PID 与父子关系，验证信号和回收行为；编译产物只存在于临时目录。
cat > "${test_dir}/fixture.c" <<'C'
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t stopped = 0;
static void stop(int signal_number) { (void)signal_number; stopped = 1; }
static void record_pid(void) {
  FILE *file = fopen(getenv("ANOTHER_YOU_FIXTURE_PIDS"), "a");
  if (!file) _exit(2);
  fprintf(file, "%d\n", getpid());
  fclose(file);
}
static void record_exit(const char *name) {
  FILE *file = fopen(getenv("ANOTHER_YOU_FIXTURE_EVENTS"), "a");
  if (!file) _exit(2);
  fprintf(file, "%s\n", name);
  fclose(file);
}
int main(void) {
  if (getenv("ANOTHER_YOU_FIXTURE_EXIT")) return 9;
  signal(SIGTERM, stop);
  record_pid();
  if (getenv("ANOTHER_YOU_FIXTURE_EXEC")) {
    if (getenv("ANOTHER_YOU_FIXTURE_DELAY_EXEC")) usleep(200000);
    execl("/bin/sleep", getenv("ANOTHER_YOU_FIXTURE_PIDS"), "60", (char *)NULL);
    return 4;
  }
  pid_t child = fork();
  if (child < 0) return 3;
  if (child == 0) {
    record_pid();
    if (getenv("ANOTHER_YOU_FIXTURE_IGNORE_TERM")) signal(SIGTERM, SIG_IGN);
    while (!stopped) usleep(10000);
    record_exit("child");
    return 0;
  }
  FILE *file = fopen(getenv("ANOTHER_YOU_FIXTURE_CHILD"), "w");
  if (!file) return 2;
  fprintf(file, "%d\n", child);
  fclose(file);
  while (!stopped) { waitpid(child, NULL, WNOHANG); usleep(10000); }
  waitpid(child, NULL, 0);
  record_exit("parent");
  return 0;
}
C
cc -Wall -Wextra -Werror "${test_dir}/fixture.c" -o "${test_dir}/fixture-app"

run_dev stop || fail '未启动时 stop 应成功'
[[ ! -e "$state_file" ]] || fail '未启动时不应写运行记录'
pass '未启动时可重复停止'

run_dev run || fail '带中文与空格工作区启动失败'
pid="$(head -n 1 "$state_file")"
child="$(cat "${test_dir}/child")"
is_running "$pid" && is_running "$child" || fail '未同时启动宿主和子进程'
[[ "$(ps -p "$pid" -ww -o command=)" == "$app_binary" ]] || fail '启动路径未限定到当前工作区'
pass '带中文与空格路径启动真实宿主与子进程'

run_make update || fail 'make update 失败'
new_pid="$(head -n 1 "$state_file")"
new_child="$(cat "${test_dir}/child")"
[[ "$new_pid" != "$pid" ]] && ! is_running "$pid" && ! is_running "$child" || fail '重启未清除旧实例'
is_running "$new_pid" && is_running "$new_child" || fail '重启未保留新实例'
[[ "$(cat "${test_dir}/events")" == $'child\nparent' ]] || fail '宿主未等待子进程先退出'
pass 'update 替换实例并先回收旧子进程'

touch "${test_dir}/fail-build"
if run_dev run; then fail '构建失败应返回非零'; fi
[[ "$(head -n 1 "$state_file")" == "$new_pid" ]] && is_running "$new_pid" && is_running "$new_child" || fail '构建失败中断了原实例'
rm "${test_dir}/fail-build"
pass '构建失败保留原运行实例'

cp "$state_file" "${test_dir}/saved-process"
printf '%s\n' "$new_pid" 'stale process start time' "$app_binary" > "$state_file"
run_dev stop || fail '过期记录停止失败'
is_running "$new_pid" && is_running "$new_child" || fail '忽略了启动时间校验'
cp "${test_dir}/saved-process" "$state_file"
run_dev stop || fail '恢复真实记录后停止失败'
! is_running "$new_pid" && ! is_running "$new_child" && [[ ! -e "$state_file" ]] || fail '停止遗留了活进程或状态'
run_dev stop || fail '重复停止失败'
pass '拒绝过期 PID 身份并完整停止实际实例'

sleep 60 &
unrelated_pid=$!
printf '%s\n' "$unrelated_pid" "$(ps -p "$unrelated_pid" -o lstart=)" "$app_binary" > "$state_file"
run_dev stop || fail '非本应用 PID 的记录处理失败'
is_running "$unrelated_pid" || fail '误杀了同用户的无关进程'
kill -TERM "$unrelated_pid"
wait "$unrelated_pid" 2>/dev/null || true
unrelated_pid=""
pass 'PID 复用到其他命令时不发送信号'

if ANOTHER_YOU_FIXTURE_EXIT=1 run_dev run; then fail '应用启动即退出应返回非零'; fi
[[ ! -e "$state_file" ]] || fail '启动失败遗留了运行记录'
pass '启动即退出明确失败且不留下运行记录'

if ANOTHER_YOU_FIXTURE_EXEC=1 run_dev run; then fail '执行文件异常替换为其他命令应返回非零'; fi
pid="$(tail -n 1 "${test_dir}/pids")"
! is_running "$pid" && [[ ! -e "$state_file" ]] || fail '异常启动遗留了子进程或状态'
pass '异常启动不会无限等待或留下自身创建的进程'

if ANOTHER_YOU_FIXTURE_EXEC=1 ANOTHER_YOU_FIXTURE_DELAY_EXEC=1 run_dev run; then fail '启动确认期间 exec 应返回非零'; fi
pid="$(tail -n 1 "${test_dir}/pids")"
! is_running "$pid" && [[ ! -e "$state_file" ]] || fail '启动确认失败未回收自身子进程'
pass '启动确认期间更换命令仍完整回收自身子进程'

ANOTHER_YOU_FIXTURE_IGNORE_TERM=1 run_dev run || fail '顽固子进程 fixture 启动失败'
pid="$(head -n 1 "$state_file")"
child="$(cat "${test_dir}/child")"
run_dev stop || fail '顽固子进程停止失败'
! is_running "$pid" && ! is_running "$child" || fail '超时后未清理顽固子进程'
pass 'TERM 超时仅强制终止已核验的进程'

mkdir -p "${workspace}/dist/dev/.lock"
if run_dev stop; then fail '并发命令应被锁拒绝'; fi
rmdir "${workspace}/dist/dev/.lock"
pass '并发生命周期命令被明确拒绝'

mkdir -p "${test_dir}/external/Another You.app"
touch "${test_dir}/external/Another You.app/keep"
ln -s "${test_dir}/external" "${workspace}/dist/macos"
if run_make clean; then fail 'clean 不应遍历外部符号链接'; fi
[[ -f "${test_dir}/external/Another You.app/keep" ]] || fail 'clean 删除了链接外部文件'
rm "${workspace}/dist/macos"
pass 'clean 拒绝外部目录符号链接'

mkdir -p "${workspace}/dist/macos/Another You.app" "${workspace}/macos/AnotherYou/.build" \
  "${workspace}/agent-core/coverage" "${workspace}/agent-core/.cache/pi" "${test_dir}/personal-data" \
  "${workspace}/dist/dev/.build.interrupted"
touch "${workspace}/dist/macos/keep" "${workspace}/agent-core/.cache/pi/keep" "${test_dir}/personal-data/config.json"
run_dev run || fail 'clean 前启动失败'
pid="$(head -n 1 "$state_file")"
child="$(cat "${test_dir}/child")"
run_make clean || fail 'make clean 失败'
! is_running "$pid" && ! is_running "$child" || fail 'clean 遗留了进程'
[[ ! -e "${workspace}/dist/dev" && ! -e "${workspace}/dist/macos/Another You.app" && ! -e "${workspace}/macos/AnotherYou/.build" && ! -e "${workspace}/agent-core/coverage" ]] || fail 'clean 未清除全部已知产物'
[[ -f "${workspace}/dist/macos/keep" && -f "${workspace}/agent-core/.cache/pi/keep" && -f "${test_dir}/personal-data/config.json" ]] || fail 'clean 删除了非构建数据'
pass 'clean 停止进程、清产物并保留其他输出、Pi 缓存和个人数据'

printf '开发脚本测试：%s 通过，0 失败。\n' "$passed"
