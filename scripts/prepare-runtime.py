#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "scripts/runtime-dependencies.json"


def artifact(component, arch, lock):
    if arch not in ("arm64", "x86_64") or lock.get("schemaVersion") != 1:
        raise ValueError("只支持 macOS arm64/x86_64 和 schemaVersion 1")
    spec = lock[component]
    checksum = spec["sha256"][arch]
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("运行依赖缺少有效 SHA256")
    cpu = "x64" if arch == "x86_64" else arch
    version = spec["version"]
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:\.\d+)?", version):
        raise ValueError("运行依赖版本无效")
    if component == "node":
        directory = f"node-v{version}-darwin-{cpu}"
        name = directory + ".tar.gz"
        url = f"https://nodejs.org/dist/v{version}/{name}"
    else:
        directory = f"chrome-headless-shell-mac-{cpu}"
        name = f"{directory}-{version}.zip"
        url = f"https://cdn.playwright.dev/builds/cft/{version}/mac-{cpu}/{directory}.zip"
    return {"name": name, "root": directory, "url": url, "sha256": checksum}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def cached_archive(spec, cache):
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / spec["name"]
    if destination.is_file() and not destination.is_symlink() and sha256(destination) == spec["sha256"]:
        return destination
    with tempfile.TemporaryDirectory(prefix=".download-", dir=cache) as directory:
        downloaded = Path(directory) / spec["name"]
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2", "--connect-timeout", "20", "--max-time", "600", "--proto", "=https", "--proto-redir", "=https", spec["url"], "--output", str(downloaded)], check=True)
        if sha256(downloaded) != spec["sha256"]:
            raise ValueError(f"运行依赖 SHA256 校验失败：{spec['name']}")
        downloaded.replace(destination)
    return destination


def checked_path(name, root):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != root:
        raise ValueError("运行依赖压缩包包含越界路径")
    return path


def extract_archive(archive, spec, destination):
    root = spec["root"]
    if archive.name.endswith(".tar.gz"):
        with tarfile.open(archive, "r:gz") as source:
            for member in source.getmembers():
                path = checked_path(member.name, root)
                if not (member.isdir() or member.isfile() or member.issym() or member.islnk()):
                    raise ValueError("运行依赖压缩包包含特殊文件")
                if member.issym() or member.islnk():
                    target = str(path.parent / member.linkname) if member.issym() else member.linkname
                    checked_path(os.path.normpath(target), root)
            if hasattr(tarfile, "data_filter"):
                source.extractall(destination, filter="data")
            else:
                source.extractall(destination)
    else:
        with zipfile.ZipFile(archive) as source:
            for entry in source.infolist():
                checked_path(entry.filename, root)
                mode = entry.external_attr >> 16
                if stat.S_ISLNK(mode):
                    raise ValueError("浏览器压缩包不接受符号链接")
                extracted = Path(source.extract(entry, destination))
                if mode & 0o777:
                    extracted.chmod(mode & 0o777)


def prepare(component, arch, destination, cache, lock):
    if destination.exists():
        raise ValueError(f"运行依赖输出已存在：{destination}")
    if component == "browser":
        package_lock = json.loads((ROOT / "agent-core/package-lock.json").read_text())
        if package_lock["packages"]["node_modules/playwright-core"]["version"] != lock["browser"]["playwrightVersion"]:
            raise ValueError("Playwright 已变化，请同时更新运行依赖浏览器版本与 SHA256")
    spec = artifact(component, arch, lock)
    archive = cached_archive(spec, cache)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".extract-", dir=destination.parent) as directory:
        extract_archive(archive, spec, Path(directory))
        extracted = Path(directory) / spec["root"]
        required = ("bin/node", "LICENSE", "include/node/node_version.h", "lib/node_modules/npm/bin/npm-cli.js", "lib/node_modules/npm/LICENSE") if component == "node" else ("chrome-headless-shell", "LICENSE.headless_shell", "icudtl.dat", "headless_lib_data.pak")
        if not all((extracted / name).is_file() and (extracted / name).stat().st_size for name in required):
            raise ValueError(f"{component} 运行依赖缺少可执行文件、资源或许可证")
        executable = extracted / required[0]
        if not os.access(executable, os.X_OK):
            raise ValueError(f"{component} 可执行文件权限无效")
        shutil.move(str(extracted), destination)
    return spec


def main():
    parser = argparse.ArgumentParser(description="准备已锁定和校验的官方 Node 或后台浏览器，不复制本机个人配置。")
    parser.add_argument("component", choices=("node", "browser"))
    parser.add_argument("--arch", choices=("arm64", "x86_64"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path, default=ROOT / "agent-core/.cache/runtime")
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text())
    spec = prepare(args.component, args.arch, args.output.resolve(), args.cache.resolve(), lock)
    print(f"已校验 {spec['name']} 并准备运行依赖。")


if __name__ == "__main__":
    main()
