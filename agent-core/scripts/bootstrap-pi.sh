#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
lock_file="${PI_SOURCE_LOCK:-${script_dir}/../pi-source.lock.json}"
source_dir="${PI_SOURCE_DIR:-${script_dir}/../.cache/pi}"
mode="${1:-fetch}"

if [[ ! -f "$lock_file" ]]; then
  echo "找不到 Pi 锁定文件：$lock_file" >&2
  exit 1
fi

read -r repository ref commit < <(node -e '
const fs = require("node:fs");
const lock = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const key of ["repository", "ref", "commit"]) {
  if (typeof lock[key] !== "string" || lock[key].length === 0) throw new Error(`锁定字段无效：${key}`);
}
process.stdout.write(`${lock.repository} ${lock.ref} ${lock.commit}\n`);
' "$lock_file")

if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "锁定提交不是完整 SHA：$commit" >&2
  exit 1
fi

fetch_repository="$repository"
if [[ "${PI_GIT_TRANSPORT:-https}" == "ssh" && "$repository" == https://github.com/* ]]; then
  fetch_repository="git@github.com:${repository#https://github.com/}"
fi

case "$mode" in
  --print)
    cat "$lock_file"
    ;;
  --check)
    remote_commit="$(git ls-remote "$fetch_repository" "refs/heads/$ref" | awk 'NR == 1 { print $1 }')"
    if [[ "$remote_commit" != "$commit" ]]; then
      echo "锁定提交已不是 ${ref} 当前提交：锁定=${commit}，远端=${remote_commit}；需要显式执行 --refresh" >&2
      exit 1
    fi
    echo "Pi 锁定有效：$repository@$commit"
    ;;
  --refresh)
    latest_commit="$(git ls-remote "$fetch_repository" "refs/heads/$ref" | awk 'NR == 1 { print $1 }')"
    if [[ ! "$latest_commit" =~ ^[0-9a-f]{40}$ ]]; then
      echo "无法解析远端分支提交：$repository#$ref" >&2
      exit 1
    fi
    node --input-type=module - "$lock_file" "$latest_commit" <<'NODE'
import { readFile, writeFile } from "node:fs/promises";
const [lockPath, commit] = process.argv.slice(2);
const lock = JSON.parse(await readFile(lockPath, "utf8"));
lock.commit = commit;
lock.resolvedAt = new Date().toISOString().slice(0, 10);
await writeFile(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
NODE
    echo "已将 Pi 锁定提交更新为：$latest_commit"
    ;;
  fetch|sync)
    if [[ -e "$source_dir" && ! -d "$source_dir/.git" ]]; then
      echo "目标目录已存在但不是 Git 仓库：$source_dir" >&2
      exit 1
    fi
    if [[ -d "$source_dir/.git" ]]; then
      current_repository="$(git -C "$source_dir" remote get-url origin)"
      if [[ "$current_repository" != "$repository" && "$current_repository" != "$fetch_repository" && "$current_repository" != "https://github.com/badlogic/pi-mono.git" ]]; then
        echo "目标仓库来源不匹配：$current_repository" >&2
        exit 1
      fi
      git -C "$source_dir" fetch --depth=1 "$fetch_repository" "$commit"
    else
      mkdir -p "$(dirname "$source_dir")"
      git init "$source_dir"
      git -C "$source_dir" remote add origin "$repository"
      git -C "$source_dir" fetch --depth=1 "$fetch_repository" "$commit"
    fi
    git -C "$source_dir" checkout --detach "$commit"
    actual_commit="$(git -C "$source_dir" rev-parse HEAD)"
    if [[ "$actual_commit" != "$commit" ]]; then
      echo "Pi 来源校验失败：期望=${commit}，实际=${actual_commit}" >&2
      exit 1
    fi
    echo "Pi 已就绪：$source_dir@$actual_commit"
    ;;
  *)
    echo "用法：$0 [fetch|sync|--check|--refresh|--print]" >&2
    exit 2
    ;;
esac
