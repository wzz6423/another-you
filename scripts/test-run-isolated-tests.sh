#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 - "$repo_dir" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

wrapper = str(Path(sys.argv[1]) / "scripts/run-isolated-tests.sh")
passed = 0

def check(condition, description):
    global passed
    if not condition:
        raise AssertionError(description)
    passed += 1
    print(f"通过 {passed}：{description}", flush=True)

with tempfile.TemporaryDirectory(prefix="another-you-isolation-test-") as directory:
    root = Path(directory)
    scratch = root / "中文 临时目录"
    scratch.mkdir()
    original = root / "existing-pi"
    original.mkdir()
    account = original / "auth.json"
    account.write_text("personal-account-must-not-change")
    environment = {**os.environ, "TMPDIR": str(scratch), "PI_CODING_AGENT_DIR": str(original)}
    result = subprocess.run([wrapper], env=environment, capture_output=True, text=True)
    check(result.returncode == 2 and result.stderr and not list(scratch.iterdir()), "无参数拒绝且不创建临时目录")

    for code in (0, 42):
        result = subprocess.run([wrapper, sys.executable, "-c",
            'import json,os,sys; from pathlib import Path; p=Path(os.environ["PI_CODING_AGENT_DIR"]); '
            'p.mkdir(); (p/"auth.json").write_text("fixture"); '
            'print(json.dumps([str(p),sys.argv[1:]])); sys.exit(' + str(code) + ')',
            "中文 空格", "", "$literal"], env=environment, capture_output=True, text=True)
        path, arguments = json.loads(result.stdout)
        check(result.returncode == code and arguments == ["中文 空格", "", "$literal"]
            and Path(path).parent.parent == scratch and not list(scratch.iterdir()),
            f"透传参数与退出码 {code}，退出后清理隔离目录")

    result = subprocess.run([wrapper, sys.executable, "-c", "import sys; print(sys.stdin.read(),end='')"],
        input="测试 stdin\n", env=environment, capture_output=True, text=True)
    check(result.returncode == 0 and result.stdout == "测试 stdin\n", "保留测试命令的标准输入")
    check(account.read_text() == "personal-account-must-not-change", "不覆盖已有 Pi 账户")

    for sent_signal in (signal.SIGTERM, signal.SIGINT):
        marker = root / f"ready-{sent_signal}"
        child_code = (
            "import json,os,subprocess,sys,time; from pathlib import Path; "
            "leaf=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); "
            f"Path({str(marker)!r}).write_text(json.dumps([os.getpid(),leaf.pid])); "
            "leaf.wait()"
        )
        process = subprocess.Popen([wrapper, sys.executable, "-c", child_code], env=environment,
            start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        children = []
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            children = json.loads(marker.read_text())
            process.send_signal(sent_signal)
            try:
                status = process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                raise AssertionError(f"{sent_signal.name} 未及时终止测试进程") from None
            check(status == 128 + sent_signal and not list(scratch.iterdir()),
                f"{sent_signal.name} 保留退出码并清理隔离目录")
            for child in children:
                # 被 PID 1 收养的已退出子进程可能短暂保留为 zombie。
                state = subprocess.run(["ps", "-o", "stat=", "-p", str(child)], capture_output=True, text=True).stdout.strip()
                if state and not state.startswith("Z"):
                    raise AssertionError(f"{sent_signal.name} 遗留测试子进程 {child}")
            check(True, f"{sent_signal.name} 不遗留测试子孙进程")
        finally:
            for pid in children:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if process.poll() is None:
                process.kill()
            process.wait()

print(f"隔离测试脚本通过：{passed} 项。")
PY
