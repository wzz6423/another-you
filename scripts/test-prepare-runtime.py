#!/usr/bin/env python3
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("prepare_runtime", Path(__file__).with_name("prepare-runtime.py"))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="another-you-runtime-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.lock = json.loads(runtime.LOCK.read_text())

    def test_fixed_architecture_and_versions(self):
        for component in ("node", "browser"):
            for arch, platform in (("arm64", "arm64"), ("x86_64", "x64")):
                artifact = runtime.artifact(component, arch, self.lock)
                self.assertIn(platform, artifact["url"])
                self.assertEqual(len(artifact["sha256"]), 64)
                self.assertTrue(artifact["url"].startswith("https://"))
        with self.assertRaises(ValueError):
            runtime.artifact("node", "riscv64", self.lock)

    def test_verified_cache_requires_no_download(self):
        archive = self.directory / "dependency.zip"
        archive.write_bytes(b"public runtime")
        artifact = {"name": archive.name, "sha256": runtime.sha256(archive), "url": "https://example.invalid/runtime"}
        with patch.object(runtime.subprocess, "run") as download:
            self.assertEqual(runtime.cached_archive(artifact, self.directory), archive)
            download.assert_not_called()

    def test_bad_download_never_replaces_cache_and_cleans_partial_files(self):
        archive = self.directory / "dependency.zip"
        archive.write_bytes(b"old cache")
        artifact = {"name": archive.name, "sha256": "0" * 64, "url": "https://example.invalid/runtime"}
        def download(command, **_):
            Path(command[-1]).write_bytes(b"incorrect download")
        with patch.object(runtime.subprocess, "run", side_effect=download):
            with self.assertRaisesRegex(ValueError, "SHA256"):
                runtime.cached_archive(artifact, self.directory)
        self.assertEqual(archive.read_bytes(), b"old cache")
        self.assertEqual(list(self.directory.iterdir()), [archive])

    def test_archive_paths_cannot_escape(self):
        for name in ("/absolute", "../escape", "runtime/../escape", "other/node"):
            with self.assertRaises(ValueError):
                runtime.checked_path(name, "runtime")
        archive = self.directory / "runtime.tar.gz"
        self.addCleanup(lambda: archive.unlink(missing_ok=True))
        with tarfile.open(archive, "w:gz") as output:
            entry = tarfile.TarInfo("runtime/bin/npm")
            entry.type = tarfile.SYMTYPE
            entry.linkname = "../../../personal-config"
            output.addfile(entry)
        with self.assertRaises(ValueError):
            runtime.extract_archive(archive, {"root": "runtime"}, self.directory / "output")
        self.assertFalse((self.directory / "output").exists())

    def test_prepare_node_preserves_npm_and_licenses(self):
        artifact = runtime.artifact("node", "arm64", self.lock)
        cache = self.directory / "cache"
        cache.mkdir()
        archive = cache / artifact["name"]
        with tarfile.open(archive, "w:gz") as output:
            for name in ("bin/node", "LICENSE", "include/node/node_version.h", "lib/node_modules/npm/bin/npm-cli.js", "lib/node_modules/npm/LICENSE"):
                content = b"fixture runtime or license"
                entry = tarfile.TarInfo(artifact["root"] + "/" + name)
                entry.size = len(content)
                entry.mode = 0o755 if name == "bin/node" else 0o644
                output.addfile(entry, io.BytesIO(content))
            entry = tarfile.TarInfo(artifact["root"] + "/bin/npm")
            entry.type = tarfile.SYMTYPE
            entry.linkname = "../lib/node_modules/npm/bin/npm-cli.js"
            output.addfile(entry)
        self.lock["node"]["sha256"]["arm64"] = runtime.sha256(archive)
        output = self.directory / "prepared"
        runtime.prepare("node", "arm64", output, cache, self.lock)
        self.assertTrue(os.access(output / "bin/node", os.X_OK))
        self.assertTrue((output / "bin/npm").is_file())
        self.assertTrue((output / "LICENSE").is_file())
        with self.assertRaisesRegex(ValueError, "已存在"):
            runtime.prepare("node", "arm64", output, cache, self.lock)
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), ["cache", "prepared"])

    def test_browser_extraction_keeps_executable_permission(self):
        archive = self.directory / "runtime.zip"
        with zipfile.ZipFile(archive, "w") as output:
            entry = zipfile.ZipInfo("runtime/chrome-headless-shell")
            entry.external_attr = 0o100755 << 16
            output.writestr(entry, b"fixture")
        runtime.extract_archive(archive, {"root": "runtime"}, self.directory)
        self.assertTrue(os.access(self.directory / "runtime/chrome-headless-shell", os.X_OK))

    def test_playwright_lock_mismatch_fails_before_download(self):
        lock = copy.deepcopy(self.lock)
        lock["browser"]["playwrightVersion"] = "0.0.0"
        with patch.object(runtime, "cached_archive") as download:
            with self.assertRaisesRegex(ValueError, "Playwright"):
                runtime.prepare("browser", "arm64", self.directory / "browser", self.directory / "cache", lock)
            download.assert_not_called()


if __name__ == "__main__":
    unittest.main()
