#!/usr/bin/env python3
"""Another You 的本地发布打包、验证及 Homebrew 元数据生成工具。"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
ARCHES = ("arm64", "x86_64")
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MACHO = {bytes.fromhex(v) for v in ("feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(args, *, env=None, data=None):
    result = subprocess.run([str(x) for x in args], input=data, capture_output=True, env=env)
    if result.returncode:
        # 签名工具可能在错误中回显密钥；调用方只接收命令名和退出码。
        raise ValueError(f"{Path(args[0]).name} 执行失败（退出码 {result.returncode}）")
    return result.stdout.decode().strip()


def version_build(version, build):
    require(isinstance(version, str) and re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version), "版本必须为 X.Y.Z 稳定语义版本")
    require(isinstance(build, str) and re.fullmatch(r"[1-9]\d*", build), "构建号必须为正整数")


def https_url(value):
    require(isinstance(value, str) and value and not re.search(r'[\s\\"\x00-\x1f]', value), "发布地址必须为 HTTPS URL")
    parsed = urlsplit(value)
    require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password and not parsed.fragment and not parsed.query, "发布地址必须为无凭据、无查询参数的 HTTPS URL")
    require("{" not in value and "}" not in value, "URL 模板含未知占位符")
    return value


def public_key(value):
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise ValueError("SUPublicEDKey 必须为 Base64 编码的 32 字节 Ed25519 公钥") from None
    require(len(decoded) == 32, "SUPublicEDKey 必须为 Base64 编码的 32 字节 Ed25519 公钥")
    return decoded


def node_crypto(payload):
    script = '''const fs=require('node:fs'),c=require('node:crypto');
const p=JSON.parse(fs.readFileSync(0,'utf8'));
if(p.seed){const k=c.createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),Buffer.from(p.seed,'base64')]),format:'der',type:'pkcs8'});process.stdout.write(c.createPublicKey(k).export({format:'der',type:'spki'}).subarray(-32).toString('base64'));}
else{const k=c.createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),Buffer.from(p.public,'base64')]),format:'der',type:'spki'});let b=fs.readFileSync(p.path);if(p.length!==undefined)b=b.subarray(0,p.length);if(!c.verify(null,b,k,Buffer.from(p.signature,'base64')))process.exit(1);}
'''
    return run([os.environ.get("ANOTHER_YOU_NODE", "node"), "-e", script], data=json.dumps(payload).encode())


def verify_key_pair(path, public):
    public_key(public)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as handle:
        info = os.fstat(handle.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_mode & 0o077 == 0, "Sparkle 私钥必须为权限 600 的普通文件")
        try:
            raw = base64.b64decode(handle.read().strip(), validate=True)
        except ValueError:
            raise ValueError("Sparkle 私钥格式无效") from None
    require(len(raw) in (32, 64), "Sparkle 私钥必须包含 32 或 64 字节")
    actual = node_crypto({"seed": base64.b64encode(raw[:32]).decode()})
    require(actual == public and (len(raw) == 32 or raw[32:] == public_key(public)), "Sparkle 私钥与发布公钥不匹配")


def package_name(version, arch):
    require(arch in ARCHES, "架构仅支持 arm64 或 x86_64；不生成伪 universal 包")
    return f"another-you-v{version}-macOS-{arch}.zip"


def load_config(path):
    config = json.loads(Path(path).read_text())
    require(config.get("schemaVersion") == 1, "发布配置 schemaVersion 必须为 1")
    return config


def resolved_config(config, version, arch):
    require(isinstance(config.get("repository"), str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", config["repository"]), "请在发布配置中指定 repository")
    public_key(config.get("publicEDKey"))
    values = {"version": version, "arch": arch, "filename": package_name(version, arch)}
    result = {"repository": config["repository"], "publicEDKey": config["publicEDKey"], "homepage": https_url(config.get("homepage"))}
    for key in ("downloadURLTemplate", "feedURLTemplate", "fallbackFeedURLTemplate", "fallbackDownloadURLTemplate"):
        template = config.get(key)
        if key.startswith("fallback") and not template:
            result[key] = ""
            continue
        require(isinstance(template, str), f"请配置 {key}")
        require("{arch}" in template or "{filename}" in template, f"{key} 必须区分架构")
        try:
            result[key] = https_url(template.format(**values))
        except (KeyError, IndexError):
            raise ValueError(f"{key} 含未知占位符") from None
    require(result["downloadURLTemplate"].endswith("/" + values["filename"]), "下载地址文件名必须与版本和架构一致")
    require(bool(result["fallbackFeedURLTemplate"]) == bool(result["fallbackDownloadURLTemplate"]), "备用 feed 与备用下载地址必须同时配置")
    if result["fallbackDownloadURLTemplate"]:
        require(result["fallbackDownloadURLTemplate"].endswith("/" + values["filename"]), "备用下载地址文件名不匹配")
    return result


def build_settings():
    configuration = os.environ.get("CONFIGURATION", "release")
    require(configuration in ("debug", "release"), "CONFIGURATION 必须为 debug 或 release")
    version, build = os.environ.get("APP_VERSION", "0.1.0"), os.environ.get("APP_BUILD", "1")
    version_build(version, build)
    enabled = os.environ.get("ANOTHER_YOU_UPDATES_ENABLED", "0")
    require(enabled in ("0", "1"), "ANOTHER_YOU_UPDATES_ENABLED 必须为 0 或 1")
    require(configuration != "debug" or enabled == "0", "Debug 应用不能启用在线更新")
    settings = {"CFBundleIdentifier": "com.anotheryou.mac", "CFBundleName": "Another You", "CFBundleDisplayName": "Another You", "CFBundleExecutable": "AnotherYou", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": build, "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True, "AnotherYouUpdatesEnabled": enabled == "1", "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True, "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False}
    settings["AnotherYouBuildConfiguration"] = configuration
    settings["CFBundleIconFile"] = "AppIcon.icns"
    if configuration == "debug":
        settings.update(CFBundleIdentifier="com.anotheryou.mac.debug", CFBundleName="Another You Debug", CFBundleDisplayName="Another You Debug")
    if enabled == "1":
        settings["SUFeedURL"] = https_url(os.environ.get("SU_FEED_URL"))
        key = os.environ.get("SPARKLE_PUBLIC_ED_KEY")
        public_key(key)
        settings["SUPublicEDKey"] = key
        fallback = os.environ.get("ANOTHER_YOU_FALLBACK_FEED_URL")
        if fallback:
            settings["AnotherYouFallbackFeedURL"] = https_url(fallback)
    return settings


def binaries(app):
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as handle:
                if handle.read(4) in MACHO:
                    yield path


def verify_architecture(app, arch):
    for path in binaries(app):
        require(run(["lipo", "-archs", path]).split() == [arch], f"架构不匹配：{path.relative_to(app)}")


def prepare_bundle(app, framework, arch, sparkle_license):
    require(arch in ARCHES, "BUILD_ARCH 必须为 arm64 或 x86_64")
    settings = build_settings()
    localized_resources = app / "Contents/Resources/AnotherYou_AnotherYouCore.bundle"
    if localized_resources.is_dir():
        # Xcode 27 使用 macOS bundle 布局；旧版 SwiftPM 直接在 bundle 顶层放资源。
        resource_directory = localized_resources / "Contents/Resources" if (localized_resources / "Contents").is_dir() else localized_resources
        languages = sorted({path.stem for path in resource_directory.glob("*.lproj") if (path / "Localizable.strings").is_file()})
        require("en" in languages, "应用本地化资源缺少英语回退语言")
        settings.update(CFBundleLocalizations=languages, CFBundleDevelopmentRegion="en")
    with (app / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump(settings, handle)
    require(sparkle_license.is_file() and sparkle_license.stat().st_size > 0, "Sparkle 官方 LICENSE 缺失")
    notices = app / "Contents/Resources/ThirdParty"
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copy2(sparkle_license, notices / "Sparkle-LICENSE")
    target = app / "Contents/Frameworks/Sparkle.framework"
    target.parent.mkdir(parents=True, exist_ok=True)
    require(framework.is_dir(), "Swift 构建未提供 Sparkle.framework")
    shutil.copytree(framework, target, symlinks=True)
    for path in binaries(target):
        actual = run(["lipo", "-archs", path]).split()
        require(arch in actual, f"Sparkle 缺少 {arch} 架构")
        if actual != [arch]:
            temporary = path.with_name(path.name + ".thin")
            run(["lipo", path, "-thin", arch, "-output", temporary])
            temporary.chmod(path.stat().st_mode)
            temporary.replace(path)
    verify_architecture(app, arch)
    sign_bundle(app)


def sign_bundle(app):
    identity = os.environ.get("CODE_SIGN_IDENTITY", "-")
    args = ["codesign", "--force", "--sign", identity]
    if os.environ.get("CODE_SIGN_KEYCHAIN"):
        args += ["--keychain", os.environ["CODE_SIGN_KEYCHAIN"]]
    if identity != "-":
        args += ["--options", "runtime", "--timestamp"]
    with tempfile.TemporaryDirectory(prefix="another-you-sign-") as directory:
        entitlements = Path(directory) / "runtime.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.cs.allow-jit": True, "com.apple.security.cs.allow-unsigned-executable-memory": True}))
        jit_runtimes = (app / "Contents/Resources/runtime/node", app / "Contents/Resources/runtime/browser/chrome-headless-shell")
        for path in sorted(binaries(app), key=lambda p: len(p.parts), reverse=True):
            extra = ["--entitlements", entitlements] if path in jit_runtimes else []
            run(args + extra + [path])
        bundles = [p for p in app.rglob("*") if p.is_dir() and not p.is_symlink() and p.suffix in (".app", ".xpc", ".framework")]
        for path in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
            run(args + [path])
        run(args + [app])
    run(["codesign", "--verify", "--deep", "--strict", "--all-architectures", app])


def clean_source_commit():
    require(not run(["git", "-C", ROOT, "status", "--porcelain", "--untracked-files=all"]), "发布需要干净源码；请提交版本化改动与未忽略的新文件后重试")
    return run(["git", "-C", ROOT, "rev-parse", "HEAD"])


def preflight(config, version, build, arch):
    version_build(version, build)
    resolved = resolved_config(config, version, arch)
    require(sys.platform == "darwin", "发布打包需要 macOS")
    for command in ("swift", "codesign", "lipo", "ditto", "otool", "npm", "git"):
        require(shutil.which(command), f"缺少命令：{command}")
    identity = os.environ.get("CODE_SIGN_IDENTITY", "")
    require(identity.strip() and identity != "-", "发布需要显式 CODE_SIGN_IDENTITY 稳定证书；不接受 ad-hoc")
    key_path = os.environ.get("SPARKLE_ED_KEY_FILE")
    require(key_path, "请设置 SPARKLE_ED_KEY_FILE 私钥文件路径")
    verify_key_pair(key_path, resolved["publicEDKey"])
    sparkle_bin = Path(os.environ.get("SPARKLE_BIN", ""))
    for name in ("generate_appcast", "sign_update"):
        require(sparkle_bin.is_absolute() and os.access(sparkle_bin / name, os.X_OK), f"SPARKLE_BIN 缺少 {name}")
    node = os.environ.get("ANOTHER_YOU_NODE")
    require(node and Path(node).is_absolute() and os.access(node, os.X_OK), "发布需 ANOTHER_YOU_NODE 指向官方自包含 Node 二进制")
    node_license = Path(os.environ.get("ANOTHER_YOU_NODE_LICENSE", str(Path(node).parent.parent / "LICENSE")))
    require(node_license.is_file() and node_license.stat().st_size > 0, "内置 Node 缺少 LICENSE；可设置 ANOTHER_YOU_NODE_LICENSE")
    run([node, "-e", 'const [a,b]=process.versions.node.split(".").map(Number);if(a<22||(a===22&&b<19))process.exit(1)'])
    require(run(["lipo", "-archs", node]).split() == [arch], "Node 架构与发布目标不匹配")
    dependencies = run(["otool", "-L", node]).splitlines()[1:]
    require(all(line.strip().startswith(("/usr/lib/", "/System/Library/")) for line in dependencies), "Node 依赖外部动态库；请使用 nodejs.org 官方 macOS 二进制")
    resolved["sourceCommit"] = clean_source_commit()
    return resolved


def sha256(path):
    with path.open("rb") as handle:
        digest = hashlib.sha256()
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
        return digest.hexdigest()


def asset(path):
    return {"name": path.name, "sha256": sha256(path), "size": path.stat().st_size}


def verify_signature(path, signature, public, length=None):
    try:
        require(len(base64.b64decode(signature, validate=True)) == 64, "Ed25519 签名长度无效")
    except (TypeError, ValueError):
        raise ValueError("Ed25519 签名无效") from None
    payload = {"path": str(path), "signature": signature, "public": public}
    if length is not None:
        payload["length"] = length
    node_crypto(payload)


def verify_feed(feed, archive, metadata, resolved):
    data = feed.read_bytes()
    match = re.search(rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: (\d+)\n-->\n?$", data)
    require(match and int(match[2]) == match.start(), "Appcast 缺少有效的完整 feed 签名")
    verify_signature(feed, match[1].decode(), resolved["publicEDKey"], int(match[2]))
    require(not re.search(rb"<!DOCTYPE|<!ENTITY", data, re.I), "不接受含外部实体的 appcast")
    tree = ET.fromstring(data)
    items = tree.findall("./channel/item")
    require(len(items) == 1, "Appcast 必须包含当前单个发布")
    item = items[0]
    enclosure = item.findall("enclosure")
    require(len(enclosure) == 1, "Appcast 必须包含单个 ZIP")
    enclosure = enclosure[0]
    require(enclosure.get("url") == resolved["downloadURLTemplate"] and enclosure.get("length") == str(archive.stat().st_size), "Appcast URL、版本、架构或文件大小不匹配")
    for key, value in (("shortVersionString", metadata["version"]), ("version", metadata["build"])):
        require(item.findtext(f"{{{SPARKLE}}}{key}") == value or enclosure.get(f"{{{SPARKLE}}}{key}") == value, f"Appcast {key} 不匹配")
    verify_signature(archive, enclosure.get(f"{{{SPARKLE}}}edSignature"), resolved["publicEDKey"])


def verify_app(app, metadata, resolved):
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    expected = {"CFBundleIdentifier": "com.anotheryou.mac", "CFBundleShortVersionString": metadata["version"], "CFBundleVersion": metadata["build"], "AnotherYouUpdatesEnabled": True, "SUPublicEDKey": resolved["publicEDKey"], "SUFeedURL": resolved["feedURLTemplate"], "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True, "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False}
    require(all(info.get(k) == v for k, v in expected.items()), "应用发布元数据与配置不一致")
    require(info.get("AnotherYouFallbackFeedURL", "") == resolved["fallbackFeedURLTemplate"], "应用 fallback feed 不匹配")
    for name in ("Contents/MacOS/AnotherYou", "Contents/Resources/runtime/node", "Contents/Resources/runtime/LICENSE", "Contents/Resources/ThirdParty/Sparkle-LICENSE", "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate", "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"):
        require((app / name).is_file(), f"发布包缺少 {name}")
    require(any((app / "Contents/Frameworks/Sparkle.framework").rglob("*.xpc")), "发布包缺少 Sparkle XPC 服务")
    verify_architecture(app, metadata["arch"])
    run(["codesign", "--verify", "--deep", "--strict", "--all-architectures", app])
    details = subprocess.run(["codesign", "-d", "-r-", "--verbose=4", str(app)], capture_output=True, text=True)
    requirement = details.stderr + details.stdout
    require(details.returncode == 0 and "certificate" in requirement and "cdhash" not in requirement, "发布应用必须使用稳定证书签名")
    if "signing" in metadata:
        signing = metadata["signing"]
        require(isinstance(signing, dict) and type(signing.get("developerID")) is bool and type(signing.get("notarized")) is bool, "Manifest 签名状态无效")
        require(signing["developerID"] == ("Authority=Developer ID Application:" in requirement), "Manifest Developer ID 状态与实际签名不一致")
        if signing["notarized"]:
            require(signing["developerID"], "公证产物必须使用 Developer ID 签名")
            run(["xcrun", "stapler", "validate", app])
    linkage = run(["otool", "-L", app / "Contents/MacOS/AnotherYou"])
    require("@rpath/Sparkle.framework/" in linkage, "应用未链接内置 Sparkle")
    commands = run(["otool", "-l", app / "Contents/MacOS/AnotherYou"])
    require("@executable_path/../Frameworks" in commands, "应用缺少独立运行需要的 Frameworks rpath")
    return info


def checked_asset(directory, entry):
    require(isinstance(entry, dict) and isinstance(entry.get("name"), str) and Path(entry["name"]).name == entry["name"], "Manifest 含无效文件名")
    path = directory / entry["name"]
    require(path.is_file() and not path.is_symlink(), f"发布文件不存在或为符号链接：{entry['name']}")
    require(asset(path) == entry, f"发布文件大小或 SHA256 不匹配：{entry['name']}")
    return path


def verify_manifest(path, config, *, inspect_bundle=True):
    metadata = json.loads(path.read_text())
    require(metadata.get("schemaVersion") == 1, "Manifest schemaVersion 必须为 1")
    version_build(metadata.get("version"), metadata.get("build"))
    resolved = resolved_config(config, metadata["version"], metadata.get("arch"))
    require(metadata.get("sourceCommit") and re.fullmatch(r"[0-9a-f]{40}", metadata["sourceCommit"]), "Manifest 缺少源码提交")
    require("signing" in metadata, "Manifest 缺少签名与公证状态")
    require(metadata.get("repository") == resolved["repository"] and metadata.get("publicEDKey") == resolved["publicEDKey"], "Manifest 发布身份不匹配")
    directory = path.parent
    archive = checked_asset(directory, metadata["archive"])
    require(archive.name == package_name(metadata["version"], metadata["arch"]), "Manifest ZIP 版本或架构不匹配")
    checksum = checked_asset(directory, metadata["checksum"])
    require(checksum.name == archive.name + ".sha256" and checksum.read_text().strip() == f"{sha256(archive)}  {archive.name}", "SHA256 文件记录与发布包不匹配")
    feed = checked_asset(directory, metadata["appcast"])
    require(feed.name == f"appcast-{metadata['arch']}.xml", "Appcast 文件架构不匹配")
    verify_feed(feed, archive, metadata, resolved)
    if resolved["fallbackFeedURLTemplate"]:
        fallback = checked_asset(directory, metadata["fallbackAppcast"])
        require(fallback.name == f"appcast-fallback-{metadata['arch']}.xml", "备用 appcast 文件架构不匹配")
        verify_feed(fallback, archive, metadata, dict(resolved, downloadURLTemplate=resolved["fallbackDownloadURLTemplate"]))
    else:
        require(not metadata.get("fallbackAppcast"), "Manifest 存在未配置的备用 feed")
    if inspect_bundle:
        with tempfile.TemporaryDirectory(prefix="another-you-verify-") as directory:
            run(["ditto", "-x", "-k", archive, directory])
            verify_app(Path(directory) / "Another You.app", metadata, resolved)
    return metadata, resolved


def package(args, config):
    resolved = preflight(config, args.version, args.build, args.arch)
    output = Path(args.output).absolute()
    require(not os.path.lexists(output), "输出目录已存在；请使用新目录，禁止覆盖历史发布")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".another-you-release-", dir=output.parent) as temporary:
        stage = Path(temporary)
        bundle_dir = stage / "bundle"
        env = dict(os.environ, CONFIGURATION="release", APP_VERSION=args.version, APP_BUILD=args.build, BUILD_ARCH=args.arch, OUTPUT_DIRECTORY=str(bundle_dir), BUNDLE_NODE="1", ANOTHER_YOU_UPDATES_ENABLED="1", SU_FEED_URL=resolved["feedURLTemplate"], ANOTHER_YOU_FALLBACK_FEED_URL=resolved["fallbackFeedURLTemplate"], SPARKLE_PUBLIC_ED_KEY=resolved["publicEDKey"])
        print(f"构建 {args.version} ({args.build}) / {args.arch}…", flush=True)
        subprocess.run([str(ROOT / "scripts/build-app.sh")], env=env, check=True)
        app = bundle_dir / "Another You.app"
        metadata = {"schemaVersion": 1, "version": args.version, "build": args.build, "arch": args.arch, "repository": resolved["repository"], "publicEDKey": resolved["publicEDKey"], "sourceCommit": resolved["sourceCommit"]}
        verify_app(app, metadata, resolved)
        archive = stage / package_name(args.version, args.arch)
        run(["ditto", "-c", "-k", "--keepParent", app, archive])
        details = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], capture_output=True, text=True).stderr
        metadata["signing"] = {"developerID": "Authority=Developer ID Application:" in details, "notarized": False}
        if os.environ.get("NOTARYTOOL_PROFILE"):
            require(metadata["signing"]["developerID"], "公证需要 Developer ID Application 签名")
            result = json.loads(run(["xcrun", "notarytool", "submit", archive, "--keychain-profile", os.environ["NOTARYTOOL_PROFILE"], "--wait", "--output-format", "json"]))
            require(result.get("status") == "Accepted", "Apple 公证未通过")
            run(["xcrun", "stapler", "staple", app])
            run(["xcrun", "stapler", "validate", app])
            archive.unlink()
            run(["ditto", "-c", "-k", "--keepParent", app, archive])
            metadata["signing"]["notarized"] = True
        feed_dir = stage / "feed-input"
        feed_dir.mkdir()
        os.link(archive, feed_dir / archive.name)
        feed = stage / f"appcast-{args.arch}.xml"
        sparkle_bin = Path(os.environ["SPARKLE_BIN"])
        tool_home = stage / "tool-home"
        tool_home.mkdir()
        tool_env = dict(os.environ, CFFIXED_USER_HOME=str(tool_home))
        run([sparkle_bin / "generate_appcast", "--ed-key-file", os.environ["SPARKLE_ED_KEY_FILE"], "--download-url-prefix", resolved["downloadURLTemplate"].rsplit("/", 1)[0] + "/", "-o", feed, feed_dir], env=tool_env)
        run([sparkle_bin / "sign_update", "--verify", "--ed-key-file", os.environ["SPARKLE_ED_KEY_FILE"], feed], env=tool_env)
        if resolved["fallbackDownloadURLTemplate"]:
            fallback = stage / f"appcast-fallback-{args.arch}.xml"
            run([sparkle_bin / "generate_appcast", "--ed-key-file", os.environ["SPARKLE_ED_KEY_FILE"], "--download-url-prefix", resolved["fallbackDownloadURLTemplate"].rsplit("/", 1)[0] + "/", "-o", fallback, feed_dir], env=tool_env)
            run([sparkle_bin / "sign_update", "--verify", "--ed-key-file", os.environ["SPARKLE_ED_KEY_FILE"], fallback], env=tool_env)
            metadata["fallbackAppcast"] = asset(fallback)
        checksum = stage / (archive.name + ".sha256")
        checksum.write_text(f"{sha256(archive)}  {archive.name}\n")
        metadata.update(archive=asset(archive), checksum=asset(checksum), appcast=asset(feed))
        manifest = stage / "manifest.json"
        manifest.write_text(json.dumps(metadata, indent=2) + "\n")
        verify_manifest(manifest, config)
        require(clean_source_commit() == resolved["sourceCommit"], "构建期间源码提交发生变化，拒绝产生发布包")
        shutil.rmtree(bundle_dir)
        shutil.rmtree(feed_dir)
        shutil.rmtree(tool_home)
        # 只移动工具自身产生的已验证结果，不清理或覆盖现有用户输出。
        require(not os.path.lexists(output), "发布输出在构建期间已被创建，拒绝覆盖")
        stage.rename(output)
    print(f"发布包已验证：{output}\nDeveloper ID：{metadata['signing']['developerID']}；已公证：{metadata['signing']['notarized']}；未执行远端发布")


def cask_text(records):
    require(len(records) in (1, 2), "Cask 接受一个或两个架构 manifest")
    first, config = records[0]
    require(all(m["version"] == first["version"] and m["build"] == first["build"] and m["sourceCommit"] == first["sourceCommit"] and c["repository"] == config["repository"] and c["publicEDKey"] == config["publicEDKey"] for m, c in records), "Cask manifest 版本、构建、源码提交或发布身份不一致")
    require(len({m["arch"] for m, _ in records}) == len(records), "Cask 含重复架构")
    lines = ['cask "another-you" do', f'  version "{first["version"]}"', '']
    for metadata, resolved in sorted(records, key=lambda value: value[0]["arch"]):
        ruby_arch = "arm" if metadata["arch"] == "arm64" else "intel"
        lines += [f'  on_{ruby_arch} do', f'    sha256 "{metadata["archive"]["sha256"]}"', '', f'    url "{resolved["downloadURLTemplate"]}"', '    livecheck do', f'      url "{resolved["feedURLTemplate"]}"', '      strategy :sparkle, &:short_version', '    end', '  end']
    lines += ['', '  name "Another You"', '  desc "Private personal AI assistant"', f'  homepage "{config["homepage"]}"', '', '  auto_updates true']
    if len(records) == 1:
        lines += [f'  depends_on arch: :{"arm64" if first["arch"] == "arm64" else "x86_64"}']
    lines += ['  depends_on macos: :sonoma', '', '  app "Another You.app"', '', '  zap trash: [', '    "~/Library/Application Support/AnotherYou",', '    "~/Library/Caches/com.anotheryou.mac",', '    "~/Library/Preferences/com.anotheryou.mac.plist",', '    "~/Library/Saved Application State/com.anotheryou.mac.savedState",', '  ]']
    if not all(m.get("signing", {}).get("notarized") is True for m, _ in records):
        lines += ['', '  caveats "This release is not Apple-notarized. macOS may require approval in Privacy & Security on first launch."']
    return "\n".join(lines + ['end', ''])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=str(ROOT / "release/config.json"))
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check-build-settings")
    prepare = commands.add_parser("prepare-bundle")
    prepare.add_argument("--app", type=Path, required=True)
    prepare.add_argument("--framework", type=Path, required=True)
    prepare.add_argument("--arch", choices=ARCHES, required=True)
    prepare.add_argument("--sparkle-license", type=Path, required=True)
    for name in ("preflight", "package"):
        sub = commands.add_parser(name)
        sub.add_argument("--version", required=True)
        sub.add_argument("--build", required=True)
        sub.add_argument("--arch", choices=ARCHES, required=True)
        if name == "package":
            sub.add_argument("--output", required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("--manifest", type=Path, required=True)
    cask = commands.add_parser("cask")
    cask.add_argument("--manifest", type=Path, action="append", required=True)
    cask.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "check-build-settings":
        build_settings()
    elif args.command == "prepare-bundle":
        prepare_bundle(args.app, args.framework, args.arch, args.sparkle_license)
    else:
        config = load_config(args.config)
        if args.command == "preflight":
            preflight(config, args.version, args.build, args.arch)
            print("发布前置检查通过；未构建、未发布")
        elif args.command == "package":
            package(args, config)
        elif args.command == "verify":
            verify_manifest(args.manifest, config)
            print("发布 manifest、签名、校验和、架构和应用验证通过")
        elif args.command == "cask":
            require(not os.path.lexists(args.output), "Cask 输出已存在，拒绝覆盖")
            text = cask_text([verify_manifest(path, config) for path in args.manifest])
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with args.output.open("x") as handle:
                handle.write(text)
            print(f"Cask 已生成：{args.output}；未推送 tap")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"失败：{error}", file=sys.stderr)
        sys.exit(1)
