#!/usr/bin/env python3
"""Run the real updater and Sparkle installer in disposable local app bundles."""

import argparse
import base64
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(*arguments, env=None):
    result = subprocess.run([str(argument) for argument in arguments], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
    return result.stdout.strip()


def events(root):
    path = root / "events.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def wait_for(predicate, root, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    log = root / "fixture.log"
    raise AssertionError(f"Updater fixture timed out: {events(root)}\n{log.read_text() if log.exists() else ''}")


def build_fixture(root, framework):
    executable = root / "UpdaterFixture"
    run("xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-target",
        f"{platform.machine()}-apple-macos14.0", "-F", framework.parent, "-framework", "Sparkle",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        ROOT / "macos/AnotherYou/Sources/AnotherYouCore/UpdateController.swift",
        ROOT / "macos/AnotherYou/Tests/Fixtures/UpdaterInstallFixture.swift", "-o", executable)
    return executable


def run_case(root, framework, executable, mode):
    root.mkdir()
    served = root / "served"
    served.mkdir()
    bundle_id = "com.anotheryou.updater-fixture." + uuid.uuid4().hex
    requests = []

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            requests.append(self.path)
            super().do_GET()

    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(served)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    prefix = f"http://127.0.0.1:{server.server_port}/"
    key = root / "test.key"
    tool_env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(framework.parent))
    public_key = run(executable, "--generate-key", key, env=tool_env)
    key.chmod(0o600)
    process = None
    launched_pids = set()
    installed = root / "installed/Updater Fixture.app"

    def make_bundle(destination, build):
        contents = destination / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        shutil.copy2(executable, contents / "MacOS/UpdaterFixture")
        shutil.copytree(framework, contents / "Frameworks/Sparkle.framework", symlinks=True)
        info = {
            "CFBundleExecutable": "UpdaterFixture", "CFBundleIdentifier": bundle_id,
            "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "Updater Fixture",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": f"0.0.{build}",
            "CFBundleVersion": build, "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
            "SUFeedURL": prefix + ("missing.xml" if mode == "fallback-feed" else "appcast.xml"), "SUPublicEDKey": public_key,
            "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
            "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
            "AnotherYouFixtureRoot": str(root), "AnotherYouFixtureAutoInstall": mode != "download-only",
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        }
        if mode in ("fallback-feed", "fallback-download"):
            info["AnotherYouFixtureFallbackFeed"] = prefix + "fallback.xml"
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", destination)

    def build_number():
        path = installed / "Contents/Info.plist"
        return plistlib.loads(path.read_bytes())["CFBundleVersion"] if path.exists() else None

    try:
        make_bundle(installed, "1")
        update = root / "staged/Updater Fixture.app"
        make_bundle(update, "2")
        archive = served / "update.zip"
        run("/usr/bin/ditto", "-c", "-k", "--keepParent", update, archive)
        signature = run(executable, "--sign", key, archive, env=tool_env)
        if mode == "invalid-signature":
            signature = base64.b64encode(bytes(64)).decode()
        feed = served / "appcast.xml"
        feed.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>Disposable updater fixture</title><item><title>0.0.2</title>
<sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.0.2</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="{prefix}update.zip" length="{archive.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
</item></channel></rss>
''')
        content = feed.read_bytes()
        feed_signature = run(executable, "--sign", key, feed, env=tool_env)
        feed.write_bytes(content + f"<!-- sparkle-signatures:\nedSignature: {feed_signature}\nlength: {len(content)}\n-->\n".encode())
        if mode in ("fallback-feed", "fallback-download"):
            shutil.copy2(feed, served / "fallback.xml")
        if mode == "fallback-download":
            content = content.replace(b"update.zip", b"missing.zip")
            feed.write_bytes(content)
            feed_signature = run(executable, "--sign", key, feed, env=tool_env)
            feed.write_bytes(content + f"<!-- sparkle-signatures:\nedSignature: {feed_signature}\nlength: {len(content)}\n-->\n".encode())
        if mode == "busy":
            (root / "busy").touch()
        with (root / "fixture.log").open("w") as output:
            process = subprocess.Popen([str(installed / "Contents/MacOS/UpdaterFixture")], stdout=output, stderr=output)
            launched_pids.add(process.pid)
            first_pid = process.pid

            if mode == "invalid-signature":
                wait_for(lambda: any(event["stage"] == "sparkle-error" or
                                     (event["stage"] == "status" and "未完成" in event["detail"]) for event in events(root)), root)
                assert build_number() == "1", events(root)
                assert not (root / "relaunched.json").exists(), events(root)
                assert not any(event["stage"] == "shutdown-began" for event in events(root)), events(root)
                assert "/update.zip" in requests, requests
                (root / "quit").touch()
                process.wait(timeout=10)
            else:
                wait_for(lambda: any(event["stage"] == "status" and "更新已下载" in event["detail"] for event in events(root)), root)
                assert "/update.zip" in requests, requests
                if mode == "fallback-feed":
                    assert requests.count("/missing.xml") == 1 and requests.count("/fallback.xml") == 1, requests
                elif mode == "fallback-download":
                    assert requests.count("/missing.zip") == 1 and requests.count("/fallback.xml") == 1, requests
                else:
                    assert "/appcast.xml" in requests, requests
                assert not any(event["stage"] == "unexpected-prompt" for event in events(root)), events(root)
                if mode in ("busy", "download-only"):
                    time.sleep(2)
                    assert build_number() == "1" and process.poll() is None, events(root)
                    assert not any(event["stage"] == "shutdown-began" for event in events(root)), events(root)
                if mode == "busy":
                    (root / "busy").unlink()
                if mode == "download-only":
                    (root / "quit").touch()
                    wait_for(lambda: build_number() == "2", root)
                    assert not (root / "relaunched.json").exists(), "Download-only mode unexpectedly restarted the app"
                    process.wait(timeout=10)
                    process = subprocess.Popen([str(installed / "Contents/MacOS/UpdaterFixture")], stdout=output, stderr=output)
                    launched_pids.add(process.pid)
                wait_for(lambda: (root / "relaunched.json").exists(), root)
                marker = json.loads((root / "relaunched.json").read_text())
                launched_pids.add(marker["pid"])
                assert marker["build"] == "2" and marker["pid"] != first_pid, marker
                assert Path(marker["bundle"]).resolve() == installed.resolve(), marker
                assert build_number() == "2"
                stages = [event["stage"] for event in events(root)]
                assert stages.index("shutdown-began") < stages.index("shutdown-complete"), stages
                run("/usr/bin/codesign", "--verify", "--deep", "--strict", installed)
            print(f"Updater installer E2E: {mode} passed (real controller, signed feed/ZIP, isolated loopback transport)", flush=True)
    finally:
        if process and process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        for event in events(root):
            if event["stage"] == "launch":
                launched_pids.add(event["pid"])
        for pid in launched_pids:
            command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], text=True, capture_output=True).stdout
            if str(installed) in command:
                try:
                    os.kill(pid, 15)
                except ProcessLookupError:
                    pass
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        subprocess.run(["/usr/bin/defaults", "delete", bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(Path.home() / "Library/Caches" / bundle_id, ignore_errors=True)
        (Path.home() / "Library/Preferences" / f"{bundle_id}.plist").unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sparkle-framework", type=Path, help="Existing Sparkle.framework from the official SPM artifact")
    modes = ["automatic", "busy", "download-only", "invalid-signature", "fallback-feed", "fallback-download"]
    parser.add_argument("--mode", choices=["all", *modes], default="all")
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="another-you-updater-install-") as temporary:
        root = Path(temporary)
        framework = arguments.sparkle_framework
        if framework is None:
            scratch = root / "spm"
            run("swift", "package", "--package-path", ROOT / "macos/AnotherYou", "--scratch-path", scratch, "resolve")
            framework = next((scratch / "artifacts").glob("*/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"))
        framework = framework.resolve()
        assert plistlib.loads((framework / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"] == "2.9.4"
        executable = build_fixture(root, framework)
        modes = modes if arguments.mode == "all" else [arguments.mode]
        for mode in modes:
            run_case(root / mode, framework, executable, mode)
        print(f"Updater installer E2E: {len(modes)} passed, 0 failed; temporary bundles, keys and preferences removed", flush=True)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stdout)
        raise
