#!/usr/bin/env python3
"""Another You 双端发布：默认只计划，--publish 写远端，--verify 只回读。"""
import argparse
from dataclasses import dataclass
import hashlib
import http.client
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
import release

REPOSITORY = "wzz6423/another-you"
HOSTS = ("github", "gitee")


def require(condition, message):
    if not condition:
        raise ValueError(message)


@dataclass(frozen=True)
class Asset:
    name: str
    data: bytes

    @property
    def sha256(self):
        return hashlib.sha256(self.data).hexdigest()


@dataclass
class Plan:
    version: str
    build: str
    commit: str
    records: list
    packages: list
    feeds: dict
    urls: dict
    cask: str

    @property
    def tag(self):
        return f"v{self.version}"

    @property
    def missing_arches(self):
        return sorted(set(release.ARCHES) - {m["arch"] for m, _ in self.records})

    def summary(self):
        return {"repository": REPOSITORY, "version": self.version, "build": self.build,
                "sourceCommit": self.commit, "architectures": sorted(m["arch"] for m, _ in self.records),
                "missingArchitectures": self.missing_arches,
                "packages": [a.name for a in self.packages],
                "feeds": {host: [a.name for a in self.feeds[host]] for host in HOSTS},
                "steps": ["核对公开仓库、源码提交与既有版本", "先确保 Gitee update-release 存在",
                          "创建版本 Release；GitHub 新版本保持 draft", "上传两站 ZIP 与 SHA-256 并回读验证",
                          "上传各站版本 feed", "公开 GitHub 版本但暂不设为 latest", "匿名核验两站版本附件",
                          "切换 Gitee 永久 feed", "将 GitHub Release 设为 latest",
                          "匿名回读所有安装包与更新源", "如指定 tap，写入已核验 cask，留待审阅"]}


def load_plan(paths, config):
    require(len(paths) in (1, 2), "需要一个或两个 --manifest")
    require(config.get("repository") == REPOSITORY, f"发布仓库必须为 {REPOSITORY}")
    records, packages, feeds, urls = [], [], {h: [] for h in HOSTS}, {h: {} for h in HOSTS}
    for path in paths:
        metadata, resolved = release.verify_manifest(path, config)
        records.append((metadata, resolved))
        arch, version = metadata["arch"], metadata["version"]
        expected = {
            "downloadURLTemplate": f"https://github.com/{REPOSITORY}/releases/download/v{version}/{metadata['archive']['name']}",
            "feedURLTemplate": f"https://github.com/{REPOSITORY}/releases/latest/download/appcast-{arch}.xml",
            "fallbackDownloadURLTemplate": f"https://gitee.com/{REPOSITORY}/releases/download/v{version}/{metadata['archive']['name']}",
            "fallbackFeedURLTemplate": f"https://gitee.com/{REPOSITORY}/releases/download/update-release/appcast-{arch}.xml",
        }
        require(all(resolved.get(k) == v for k, v in expected.items()), "发布 URL 必须指向本仓库的 GitHub 主站与 Gitee 镜像")
        for key in ("archive", "checksum"):
            entry = metadata[key]
            data = release.checked_asset(path.parent, entry).read_bytes()
            require(hashlib.sha256(data).hexdigest() == entry["sha256"], "本地发布文件在验证后改变")
            packages.append(Asset(entry["name"], data))
        for host, key, feed_key, zip_key in (
            ("github", "appcast", "feedURLTemplate", "downloadURLTemplate"),
            ("gitee", "fallbackAppcast", "fallbackFeedURLTemplate", "fallbackDownloadURLTemplate"),
        ):
            entry = metadata[key]
            data = release.checked_asset(path.parent, entry).read_bytes()
            require(hashlib.sha256(data).hexdigest() == entry["sha256"], "本地 feed 在验证后改变")
            feed = Asset(f"appcast-{arch}.xml", data)
            feeds[host].append(feed)
            urls[host][feed.name] = resolved[feed_key]
            urls[host][metadata["archive"]["name"]] = resolved[zip_key]
            urls[host][metadata["checksum"]["name"]] = resolved[zip_key] + ".sha256"
    cask = release.cask_text(records)
    first = records[0][0]
    return Plan(first["version"], first["build"], first["sourceCommit"], records, packages, feeds, urls, cask)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Transport:
    def __init__(self):
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, url, *, method="GET", headers=None, data=None, redirects=False, maximum=16 * 1024 * 1024):
        headers = dict(headers or {})
        for attempt in range(6):
            parsed = urllib.parse.urlsplit(url)
            require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password,
                    "远端地址必须为无凭据的 HTTPS URL")
            try:
                request = urllib.request.Request(url, method=method, headers=headers, data=data)
                with self.opener.open(request, timeout=90) as response:
                    body = response.read(maximum + 1)
                    require(len(body) <= maximum, "远端响应超过预期大小")
                    return response.status, body
            except urllib.error.HTTPError as error:
                status = error.code
                location = error.headers.get("Location")
                error.close()
                if redirects and method == "GET" and status in (301, 302, 303, 307, 308) and location:
                    url = urllib.parse.urljoin(url, location)
                    # 下载跳转到 CDN 后不能携带源站认证头。
                    headers = {k: v for k, v in headers.items() if k.lower() != "authorization"}
                    continue
                return status, b""
            except (urllib.error.URLError, TimeoutError, OSError, ValueError, http.client.HTTPException):
                raise ValueError(f"{parsed.hostname} 网络请求失败") from None
        raise ValueError("下载重定向次数超过限制")


def credentials(environ=None):
    env = os.environ if environ is None else environ
    github = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN")
    if not github:
        try:
            result = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True)
            github = result.stdout.strip() if result.returncode == 0 else ""
        except OSError:
            github = ""
    require(github, "缺少 GitHub 凭据；请设置 GH_TOKEN 或完成 gh auth login")
    gitee = env.get("GITEE_TOKEN")
    require(gitee, "缺少 GITEE_TOKEN 环境变量")
    return {"github": github, "gitee": gitee}


class ReleaseAPI:
    def __init__(self, host, token, transport=None):
        require(host in HOSTS, "未知发布站点")
        self.host, self.token = host, token
        self.transport = transport or Transport()
        self.base = "https://api.github.com" if host == "github" else "https://gitee.com/api/v5"
        self.prefix = f"/repos/{REPOSITORY}"

    def call(self, suffix, *, method="GET", payload=None, missing=False):
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json", "User-Agent": "AnotherYou-release"}
        data = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(payload).encode()
        status, body = self.transport.request(self.base + self.prefix + suffix, method=method, headers=headers, data=data)
        if missing and status == 404:
            return None
        require(200 <= status < 300, f"{self.host} {method} {suffix.split('?')[0]}：HTTP {status}")
        if not body:
            return None
        try:
            return json.loads(body)
        except (ValueError, UnicodeError):
            raise ValueError(f"{self.host} 响应不是有效 JSON") from None

    def preflight(self, commit):
        repo = self.call("")
        require(isinstance(repo, dict) and repo.get("full_name") == REPOSITORY and repo.get("private") is False
                and repo.get("public", True) is not False, f"{self.host} 必须为公开的 {REPOSITORY}")
        require(repo.get("permissions", {}).get("push") is not False, f"{self.host} 当前凭据没有写权限")
        source = self.call(f"/commits/{commit}")
        require(isinstance(source, dict) and source.get("sha") == commit, f"{self.host} 缺少指定源码提交")

    def get_release(self, tag):
        result = self.call(f"/releases/tags/{urllib.parse.quote(tag, safe='')}", missing=True)
        if result is not None or self.host != "github":
            return result
        for page in range(1, 101):
            values = self.call(f"/releases?per_page=100&page={page}")
            require(isinstance(values, list), f"{self.host} Release 列表无效")
            matches = [r for r in values if r.get("tag_name") == tag]
            require(len(matches) <= 1, "GitHub 存在重复 tag 的 Release")
            if matches:
                return matches[0]
            if len(values) < 100:
                return None
        raise ValueError("GitHub Release 列表过大，无法确认 tag 唯一性")

    def tag_commit(self, tag):
        if self.host == "gitee":
            for page in range(1, 101):
                values = self.call(f"/tags?per_page=100&page={page}")
                require(isinstance(values, list), "Gitee tag 列表无效")
                for value in values:
                    if value.get("name") == tag:
                        commit = value.get("commit", {}).get("sha", "")
                        require(isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit), "Gitee tag 缺少有效提交 SHA")
                        return commit
                if len(values) < 100:
                    return None
            raise ValueError("Gitee tag 列表过大，无法确认指定 tag")
        reference = self.call(f"/git/ref/tags/{urllib.parse.quote(tag, safe='')}", missing=True)
        if reference is None:
            return None
        require(isinstance(reference, dict) and reference.get("ref") == f"refs/tags/{tag}", "GitHub 返回了不同的 tag ref")
        target = reference.get("object")
        for _ in range(8):
            require(isinstance(target, dict) and isinstance(target.get("sha"), str)
                    and re.fullmatch(r"[0-9a-f]{40}", target["sha"]), "GitHub tag 对象无效")
            if target.get("type") == "commit":
                return target["sha"]
            require(target.get("type") == "tag", "GitHub tag 未指向提交")
            annotated = self.call(f"/git/tags/{target['sha']}")
            require(isinstance(annotated, dict), "GitHub annotated tag 无效")
            target = annotated.get("object")
        raise ValueError("GitHub annotated tag 嵌套过深")

    def check_release(self, item, tag, commit):
        require(isinstance(item, dict) and isinstance(item.get("id"), int) and item.get("tag_name") == tag,
                f"{self.host} Release 身份不匹配")
        if tag != "update-release":
            source = self.tag_commit(tag)
            if source is None:
                require(self.host == "github" and item.get("draft") is True and item.get("target_commitish") == commit,
                        f"{self.host} 既有 Release 的源码无法确认")
            else:
                require(source == commit, f"{self.host} 既有版本 tag 指向另一提交")
            require(not item.get("prerelease", False), f"{self.host} 既有版本是 prerelease")

    def ensure_release(self, tag, commit, notes, *, permanent=False):
        item = self.get_release(tag)
        if item:
            self.check_release(item, tag, commit)
            return item
        if not permanent:
            source = self.tag_commit(tag)
            require(source is None or source == commit, f"{self.host} 既有 tag 指向另一提交")
        payload = {"tag_name": tag, "target_commitish": commit,
                   "name": "Another You update feed" if permanent else f"Another You {tag}",
                   "body": notes, "prerelease": permanent}
        if self.host == "github":
            payload.update(draft=True, make_latest="false")
        item = self.call("/releases", method="POST", payload=payload)
        require(isinstance(item, dict) and isinstance(item.get("id"), int), f"{self.host} 创建 Release 未返回有效 ID")
        self.check_release(item, tag, commit)
        return item

    def assets(self, item):
        result = []
        endpoint = "assets" if self.host == "github" else "attach_files"
        for page in range(1, 101):
            values = self.call(f"/releases/{item['id']}/{endpoint}?per_page=100&page={page}")
            require(isinstance(values, list), f"{self.host} 附件列表无效")
            result.extend(values)
            if len(values) < 100:
                return result
        raise ValueError(f"{self.host} 附件列表过大")

    def download(self, item, remote, maximum):
        require(isinstance(remote.get("id"), int), f"{self.host} 附件 ID 无效")
        suffix = f"/releases/assets/{remote['id']}" if self.host == "github" else f"/releases/{item['id']}/attach_files/{remote['id']}/download"
        status, data = self.transport.request(self.base + self.prefix + suffix,
                                             headers={"Authorization": f"Bearer {self.token}", "Accept": "application/octet-stream"},
                                             redirects=True, maximum=maximum)
        require(status == 200, f"{self.host} 附件 {remote['id']} 下载：HTTP {status}")
        return data

    def matching(self, item, asset):
        matches = [a for a in self.assets(item) if a.get("name") == asset.name]
        require(len(matches) <= 1, f"{self.host} 存在重名附件：{asset.name}")
        return matches[0] if matches else None

    def checked(self, item, asset):
        remote = self.matching(item, asset)
        require(remote is not None, f"{self.host} 缺少附件：{asset.name}")
        data = self.download(item, remote, len(asset.data))
        require(data == asset.data, f"{self.host} 附件 SHA-256 不一致：{asset.name}")
        return remote

    def upload(self, item, asset):
        remote = self.matching(item, asset)
        if remote:
            self.checked(item, asset)
            return remote
        return self.upload_new(item, asset)

    def upload_new(self, item, asset):
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if self.host == "github":
            url = f"https://uploads.github.com{self.prefix}/releases/{item['id']}/assets?name={urllib.parse.quote(asset.name, safe='')}"
            data = asset.data
            headers["Content-Type"] = "application/octet-stream"
        else:
            url = self.base + self.prefix + f"/releases/{item['id']}/attach_files"
            boundary = "AnotherYou" + uuid.uuid4().hex
            headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
            data = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{asset.name}"\r\n'
                    'Content-Type: application/octet-stream\r\n\r\n').encode() + asset.data + f"\r\n--{boundary}--\r\n".encode()
        status, _ = self.transport.request(url, method="POST", headers=headers, data=data)
        require(200 <= status < 300, f"{self.host} 上传 {asset.name}：HTTP {status}")
        return self.checked(item, asset)

    def delete(self, item, remote):
        suffix = f"/releases/assets/{remote['id']}" if self.host == "github" else f"/releases/{item['id']}/attach_files/{remote['id']}"
        self.call(suffix, method="DELETE")

    def replace_feed(self, item, asset):
        require(self.host == "gitee" and item.get("tag_name") == "update-release" and asset.name.startswith("appcast-"),
                "仅 Gitee 永久更新 feed 允许受控替换")
        old = self.matching(item, asset)
        previous = self.download(item, old, 2 * 1024 * 1024) if old else None
        staged = Asset(asset.name + ".pending-" + asset.sha256[:12], asset.data)
        if previous == asset.data:
            if self.matching(item, staged):
                pending = self.checked(item, staged)
                self.delete(item, pending)
            return
        self.upload(item, staged)
        try:
            if old:
                self.delete(item, old)
            self.upload(item, asset)
        except ValueError:
            if old:
                try:
                    current = self.matching(item, asset)
                    if not current or self.download(item, current, 2 * 1024 * 1024) != previous:
                        if current:
                            self.delete(item, current)
                        self.upload(item, Asset(asset.name, previous))
                except ValueError:
                    raise ValueError(f"Gitee 永久 feed 替换失败且恢复失败：{asset.name}；保留暂存附件，请手工恢复") from None
            recovery = "旧 feed 已保留或恢复" if old else "没有旧 feed；暂存附件已保留"
            raise ValueError(f"Gitee 永久 feed 替换失败：{asset.name}；{recovery}") from None
        pending = self.matching(item, staged)
        if pending:
            self.delete(item, pending)

    def publish_version(self, item):
        require(self.host == "github", "仅 GitHub 版本需要从 draft 公开")
        if not item.get("draft", False):
            return item
        return self.call(f"/releases/{item['id']}", method="PATCH", payload={"draft": False, "prerelease": False, "make_latest": "false"})

    def make_latest(self, item):
        require(self.host == "github", "仅 GitHub 设置 latest")
        return self.call(f"/releases/{item['id']}", method="PATCH", payload={"draft": False, "prerelease": False, "make_latest": "true"})

    def verify_public(self, url, asset):
        status, data = self.transport.request(url, redirects=True, maximum=len(asset.data))
        require(status == 200 and data == asset.data, f"{self.host} 匿名下载或 SHA-256 验证失败：{asset.name}（HTTP {status}）")


def check_feed_progress(api, item, feeds, build, version):
    if not item:
        return
    for asset in feeds:
        remote = api.matching(item, asset)
        if not remote:
            continue
        data = api.download(item, remote, 2 * 1024 * 1024)
        if data == asset.data:
            continue
        try:
            require(not any(value in data.upper() for value in (b"<!DOCTYPE", b"<!ENTITY")), "旧 feed 含外部实体")
            entry = ET.fromstring(data).find("./channel/item")
            require(entry is not None, "旧 feed 缺少发布条目")
            old_build = entry.findtext(f"{{{release.SPARKLE}}}version")
            if old_build is None:
                enclosure = entry.find("enclosure")
                old_build = enclosure.get(f"{{{release.SPARKLE}}}version") if enclosure is not None else None
            old_version = entry.findtext(f"{{{release.SPARKLE}}}shortVersionString")
            if old_version is None:
                enclosure = entry.find("enclosure")
                old_version = enclosure.get(f"{{{release.SPARKLE}}}shortVersionString") if enclosure is not None else None
            release.version_build(old_version, old_build)
            require(tuple(map(int, old_version.split("."))) <= tuple(map(int, version.split("."))),
                    f"本次版本早于 {api.host} 已发布 feed，拒绝降级")
            require(old_build and old_build.isdecimal() and int(old_build) < int(build),
                    f"构建号未高于 {api.host} 已发布 feed，拒绝替换")
        except ET.ParseError:
            raise ValueError(f"{api.host} 旧 feed 无法解析，拒绝自动覆盖") from None


def existing_releases(plan, apis):
    found = {}
    for host, api in apis.items():
        api.preflight(plan.commit)
        tag = api.tag_commit(plan.tag)
        require(tag is None or tag == plan.commit, f"{host} 既有 tag 指向另一提交")
        item = api.get_release(plan.tag)
        if item:
            api.check_release(item, plan.tag, plan.commit)
            # 先发现既有冲突，避免另一站先写入部分版本。
            for asset in plan.packages + plan.feeds[host]:
                if api.matching(item, asset):
                    api.checked(item, asset)
        found[host] = item
    permanent = apis["gitee"].get_release("update-release")
    latest = apis["github"].call("/releases/latest", missing=True)
    if latest:
        name = latest.get("tag_name", "")
        try:
            release.version_build(name.removeprefix("v"), "1")
        except ValueError:
            raise ValueError("GitHub latest 不是可识别的稳定版本，拒绝自动切换") from None
        require(tuple(map(int, name.removeprefix("v").split("."))) <= tuple(map(int, plan.version.split("."))),
                "本次版本早于 GitHub latest，拒绝降级")
    check_feed_progress(apis["github"], latest, plan.feeds["github"], plan.build, plan.version)
    check_feed_progress(apis["gitee"], permanent, plan.feeds["gitee"], plan.build, plan.version)
    if found["gitee"]:
        require(permanent and permanent["id"] < found["gitee"]["id"],
                "Gitee update-release 必须早于版本 Release；请先修复既有发布顺序")
    return found, permanent


def verify_remote(plan, apis):
    require(not plan.missing_arches, "缺少发布架构：" + ", ".join(plan.missing_arches))
    for host, api in apis.items():
        api.preflight(plan.commit)
        item = api.get_release(plan.tag)
        require(item is not None, f"{host} 未发布 {plan.tag}")
        api.check_release(item, plan.tag, plan.commit)
        require(not item.get("draft", False), f"{host} Release 仍是 draft")
        for asset in plan.packages + plan.feeds[host]:
            api.checked(item, asset)
        if host == "github":
            latest = api.call("/releases/latest")
            require(latest and latest.get("id") == item["id"], "GitHub latest 未指向本次版本")
        else:
            permanent = api.get_release("update-release")
            require(permanent and permanent["id"] < item["id"], "Gitee 永久 feed Release 顺序无效")
            for asset in plan.feeds[host]:
                api.checked(permanent, asset)
        for asset in plan.packages + plan.feeds[host]:
            api.verify_public(plan.urls[host][asset.name], asset)


def publish(plan, apis, notes):
    require(not plan.missing_arches, "正式发布缺少架构：" + ", ".join(plan.missing_arches))
    found, permanent = existing_releases(plan, apis)
    mirror = apis["gitee"]
    permanent = permanent or mirror.ensure_release("update-release", plan.commit, "Signed Sparkle feeds for Another You.", permanent=True)
    items = {host: found[host] or api.ensure_release(plan.tag, plan.commit, notes) for host, api in apis.items()}
    for host, api in apis.items():
        for asset in plan.packages:
            api.upload(items[host], asset)
        for asset in plan.packages:
            api.checked(items[host], asset)
    # 两站所有包均已回读验证后，才让任何更新源引用它们。
    for host, api in apis.items():
        for asset in plan.feeds[host]:
            api.upload(items[host], asset)
    items["github"] = apis["github"].publish_version(items["github"])
    # API 携带凭据的下载成功不能证明 Sparkle 客户端能匿名取得附件。
    for host, api in apis.items():
        for asset in plan.packages + plan.feeds[host]:
            url = f"https://{host}.com/{REPOSITORY}/releases/download/{plan.tag}/{asset.name}"
            api.verify_public(url, asset)
    for asset in plan.feeds["gitee"]:
        mirror.replace_feed(permanent, asset)
    apis["github"].make_latest(items["github"])
    verify_remote(plan, apis)


def prepare_tap(path, cask):
    if path is None:
        return None
    path = path.absolute()
    require(path.is_dir() and not path.is_symlink(), "--tap-path 必须是实际 Git 仓库目录")
    result = subprocess.run(["git", "-C", str(path), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    require(result.returncode == 0 and Path(result.stdout.strip()).resolve() == path.resolve(), "--tap-path 必须指向 tap 仓库根")
    directory, target = path / "Casks", path / "Casks/another-you.rb"
    require(not directory.is_symlink() and not target.is_symlink(), "Cask 目录或文件不能为符号链接")
    require(not directory.exists() or directory.is_dir(), "Casks 不是目录")
    require(not target.exists() or target.is_file(), "Cask 不是普通文件")
    prior = target.read_bytes() if target.exists() else None
    status = subprocess.run(["git", "-C", str(path), "status", "--porcelain", "--", "Casks/another-you.rb"], capture_output=True, text=True)
    require(status.returncode == 0, "无法读取 tap 工作区状态")
    require(not status.stdout or prior == cask.encode(), "Cask 有不同的未提交内容，拒绝覆盖")
    return target, prior, cask.encode()


def write_tap(prepared):
    if prepared is None:
        return
    target, previous, contents = prepared
    require(not target.parent.is_symlink() and not target.is_symlink(), "Cask 路径在发布期间变成符号链接")
    require((target.read_bytes() if target.exists() else None) == previous, "Cask 在发布期间发生变化，拒绝覆盖")
    target.parent.mkdir(exist_ok=True)
    target.write_bytes(contents)
    print("Cask 已写入指定 tap；请审阅差异并按仓库流程提交 PR。未提交或推送 tap。")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="仅校验本地文件并打印计划（默认）")
    mode.add_argument("--publish", action="store_true", help="执行双端发布并回读验证")
    mode.add_argument("--verify", action="store_true", help="只回读已发布资产")
    parser.add_argument("--manifest", action="append", type=Path, required=True)
    parser.add_argument("--config", type=Path, default=release.ROOT / "release/config.json")
    parser.add_argument("--notes-file", type=Path)
    parser.add_argument("--tap-path", type=Path)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    plan = load_plan(args.manifest, release.load_config(args.config))
    require(not args.verify or args.tap_path is None, "--verify 不写 tap；请移除 --tap-path")
    prepared = prepare_tap(args.tap_path, plan.cask)
    if not args.publish and not args.verify:
        print(json.dumps({"mode": "dry-run", **plan.summary(), "tapRequested": prepared is not None}, ensure_ascii=False, indent=2))
        print("仅本地验证和计划；未访问发布 API、写入 tap 或执行上传。")
        return
    require(not plan.missing_arches, "缺少发布架构：" + ", ".join(plan.missing_arches))
    tokens = credentials()
    apis = {host: ReleaseAPI(host, tokens[host]) for host in HOSTS}
    if args.verify:
        verify_remote(plan, apis)
        print("双端 Release、附件哈希与匿名更新源验证通过。未执行发布。")
    else:
        notes = args.notes_file.read_text() if args.notes_file else f"Another You {plan.tag}\n\nBuild {plan.build}; source {plan.commit}."
        publish(plan, apis, notes)
        write_tap(prepared)
        print(f"Another You {plan.tag} 双端发布及匿名回读验证完成。")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        # 网络响应正文和 SDK 异常可能携带凭据；只有已受控的 ValueError 可展示。
        message = str(error) if isinstance(error, ValueError) else "本地输入或发布操作失败，请检查配置与文件状态"
        print(f"失败：{message}", file=sys.stderr)
        sys.exit(1)
