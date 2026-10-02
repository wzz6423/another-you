#!/usr/bin/env python3
import base64
import copy
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="another-you-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.seed = base64.b64encode(os.urandom(32)).decode()
        self.public = release.node_crypto({"seed": self.seed})
        self.config = {"schemaVersion": 1, "repository": "owner/another-you", "homepage": "https://example.com/another-you", "publicEDKey": self.public, "downloadURLTemplate": "https://example.com/v{version}/{filename}", "feedURLTemplate": "https://example.com/appcast-{arch}.xml", "fallbackFeedURLTemplate": None, "fallbackDownloadURLTemplate": None}

    def signature(self, data):
        script = '''const c=require('node:crypto'),fs=require('node:fs');const p=JSON.parse(fs.readFileSync(0,'utf8'));const k=c.createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),Buffer.from(p.seed,'base64')]),format:'der',type:'pkcs8'});process.stdout.write(c.sign(null,Buffer.from(p.data,'base64'),k).toString('base64'));'''
        return release.run(["node", "-e", script], data=json.dumps({"seed": self.seed, "data": base64.b64encode(data).decode()}).encode())

    def fixture(self, arch="arm64", config=None):
        config = config or self.config
        directory = self.root / arch
        directory.mkdir()
        metadata = {"schemaVersion": 1, "version": "1.2.3", "build": "7", "arch": arch, "sourceCommit": "a" * 40, "repository": config["repository"], "publicEDKey": self.public, "signing": {"developerID": False, "notarized": False}}
        archive = directory / release.package_name(metadata["version"], arch)
        archive.write_bytes(b"fixture ZIP for manifest boundary, bundle inspection tested separately")
        checksum = directory / (archive.name + ".sha256")
        checksum.write_text(f"{release.sha256(archive)}  {archive.name}\n")
        resolved = release.resolved_config(config, metadata["version"], arch)
        def feed(name, url):
            path = directory / name
            xml = (f'<?xml version="1.0"?><rss xmlns:sparkle="{release.SPARKLE}" version="2.0"><channel><item><sparkle:version>7</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><enclosure url="{url}" length="{archive.stat().st_size}" sparkle:edSignature="{self.signature(archive.read_bytes())}"/></item></channel></rss>\n').encode()
            path.write_bytes(xml + f'<!-- sparkle-signatures:\nedSignature: {self.signature(xml)}\nlength: {len(xml)}\n-->\n'.encode())
            return release.asset(path)
        metadata.update(archive=release.asset(archive), checksum=release.asset(checksum), appcast=feed(f"appcast-{arch}.xml", resolved["downloadURLTemplate"]))
        if resolved["fallbackDownloadURLTemplate"]:
            metadata["fallbackAppcast"] = feed(f"appcast-fallback-{arch}.xml", resolved["fallbackDownloadURLTemplate"])
        path = directory / "manifest.json"
        path.write_text(json.dumps(metadata))
        return path, metadata

    def verify(self, path, config=None):
        return release.verify_manifest(path, config or self.config, inspect_bundle=False)

    def rewrite(self, path, metadata):
        path.write_text(json.dumps(metadata))

    def test_versions_reject_invalid_and_zero_build(self):
        for version, build in (("1.2", "1"), ("v1.2.3", "1"), ("01.2.3", "1"), ("1.2.3-preview.1", "1"), ("1.2.3", "0"), ("1.2.3", "1;date")):
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                release.version_build(version, build)
        release.version_build("0.1.0", "1")

    def test_urls_reject_insecure_credentials_and_injection(self):
        for url in (None, "", "http://example.com/a", "https://user:pass@example.com/a", "https://example.com/a?token=secret", 'https://example.com/";system("x")', "https://example.com/{arch}"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                release.https_url(url)
        self.assertEqual(release.https_url("https://example.com/appcast.xml"), "https://example.com/appcast.xml")

    def test_public_key_requires_32_bytes(self):
        for key in (None, "", "!" * 44, base64.b64encode(b"short").decode()):
            with self.assertRaises(ValueError):
                release.public_key(key)

    def test_key_pair_rejects_mismatch_permissions_and_symlink(self):
        path = self.root / "key"
        path.write_text(self.seed)
        path.chmod(0o600)
        release.verify_key_pair(path, self.public)
        with self.assertRaises(ValueError):
            release.verify_key_pair(path, base64.b64encode(b"x" * 32).decode())
        path.chmod(0o644)
        with self.assertRaises(ValueError):
            release.verify_key_pair(path, self.public)
        path.chmod(0o600)
        link = self.root / "key-link"
        link.symlink_to(path)
        with self.assertRaises(OSError):
            release.verify_key_pair(link, self.public)

    def test_templates_require_distinct_arch_and_paired_mirror(self):
        for changes in ({"feedURLTemplate": "https://example.com/feed.xml"}, {"downloadURLTemplate": "https://example.com/{arch}/wrong.zip"}, {"feedURLTemplate": "https://example.com/{other}/{arch}"}, {"fallbackFeedURLTemplate": "https://mirror.example.com/feed-{arch}.xml"}):
            with self.assertRaises(ValueError):
                release.resolved_config(dict(self.config, **changes), "1.2.3", "arm64")
        with self.assertRaises(ValueError):
            release.resolved_config(self.config, "1.2.3", "universal")

    def test_development_disables_updates_and_release_requires_metadata(self):
        with patch.dict(os.environ, {}, clear=True):
            settings = release.build_settings()
            self.assertIs(settings["AnotherYouUpdatesEnabled"], False)
            self.assertNotIn("SUFeedURL", settings)
        with patch.dict(os.environ, {"ANOTHER_YOU_UPDATES_ENABLED": "1"}, clear=True), self.assertRaises(ValueError):
            release.build_settings()
        with patch.dict(os.environ, {"ANOTHER_YOU_UPDATES_ENABLED": "1", "SU_FEED_URL": "https://example.com/feed.xml", "SPARKLE_PUBLIC_ED_KEY": self.public}, clear=True):
            settings = release.build_settings()
            for key in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "AnotherYouUpdatesEnabled"):
                self.assertIs(settings[key], True)
            for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate"):
                self.assertIs(settings[key], False)

    def test_bundle_preserves_sparkle_license_and_rejects_missing_license(self):
        app = self.root / "Another You.app"
        (app / "Contents").mkdir(parents=True)
        framework = self.root / "Sparkle.framework"
        framework.mkdir()
        license_path = self.root / "LICENSE"
        with self.assertRaises(ValueError):
            release.prepare_bundle(app, framework, "arm64", license_path)
        license_path.write_text("Sparkle and third-party license notices\n")
        with patch.object(release, "sign_bundle"), patch.dict(os.environ, {}, clear=True):
            release.prepare_bundle(app, framework, "arm64", license_path)
        self.assertEqual((app / "Contents/Resources/ThirdParty/Sparkle-LICENSE").read_text(), license_path.read_text())

    def test_release_rejects_modified_or_untracked_source(self):
        for dirty in (" M scripts/build-app.sh", "?? new-source.swift"):
            with patch.object(release, "run", return_value=dirty), self.assertRaises(ValueError):
                release.clean_source_commit()
        with patch.object(release, "run", side_effect=["", "b" * 40]):
            self.assertEqual(release.clean_source_commit(), "b" * 40)

    def test_only_node_and_headless_browser_receive_jit_entitlements(self):
        app = self.root / "Another You.app"
        app.mkdir()
        paths = [app / path for path in ("Contents/Resources/runtime/node", "Contents/Resources/runtime/browser/chrome-headless-shell", "Contents/Resources/runtime/browser/libvulkan.dylib", "Contents/MacOS/AnotherYou")]
        signed = {}
        def sign(command, **_):
            if "--entitlements" in command:
                signed[command[-1]] = plistlib.loads(Path(command[command.index("--entitlements") + 1]).read_bytes())
            return ""
        with patch.object(release, "binaries", return_value=paths), patch.object(release, "run", side_effect=sign), patch.dict(os.environ, {}, clear=True):
            release.sign_bundle(app)
        self.assertEqual(set(signed), set(paths[:2]))
        for entitlements in signed.values():
            self.assertEqual(entitlements, {"com.apple.security.cs.allow-jit": True, "com.apple.security.cs.allow-unsigned-executable-memory": True})

    def test_bundle_localizations_follow_shipped_resources(self):
        framework = self.root / "Sparkle.framework"
        framework.mkdir()
        license_path = self.root / "LICENSE"
        license_path.write_text("Sparkle license fixture")
        for layout in ("flat", "macos"):
            with self.subTest(layout=layout):
                app = self.root / f"{layout} Another You.app"
                bundle = app / "Contents/Resources/AnotherYou_AnotherYouCore.bundle"
                resources = bundle / "Contents/Resources" if layout == "macos" else bundle
                for language in ("en", "zh-Hans", "ar"):
                    (resources / f"{language}.lproj").mkdir(parents=True)
                    (resources / f"{language}.lproj/Localizable.strings").write_text('"fixture" = "fixture";')
                (resources / "ja.lproj").mkdir()
                if layout == "macos":
                    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundlePackageType": "BNDL"}))
                    (bundle / "fr.lproj").mkdir()
                    (bundle / "fr.lproj/Localizable.strings").write_text('"fixture" = "fixture";')
                with patch.object(release, "sign_bundle"), patch.dict(os.environ, {}, clear=True):
                    release.prepare_bundle(app, framework, "arm64", license_path)
                settings = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                self.assertEqual(settings["CFBundleLocalizations"], ["ar", "en", "zh-Hans"])
                self.assertEqual(settings["CFBundleDevelopmentRegion"], "en")

    def test_bundle_localizations_reject_missing_english_table_in_both_layouts(self):
        for layout in ("flat", "macos"):
            with self.subTest(layout=layout):
                app = self.root / f"{layout} Another You.app"
                bundle = app / "Contents/Resources/AnotherYou_AnotherYouCore.bundle"
                resources = bundle / "Contents/Resources" if layout == "macos" else bundle
                (resources / "en.lproj").mkdir(parents=True)
                (resources / "fr.lproj").mkdir()
                (resources / "fr.lproj/Localizable.strings").write_text('"fixture" = "fixture";')
                if layout == "macos":
                    (bundle / "en.lproj").mkdir()
                    (bundle / "en.lproj/Localizable.strings").write_text('"fixture" = "fixture";')
                with patch.object(release, "sign_bundle") as sign, patch.dict(os.environ, {}, clear=True):
                    with self.assertRaisesRegex(ValueError, "缺少英语回退语言"):
                        release.prepare_bundle(app, self.root / "Sparkle.framework", "arm64", self.root / "LICENSE")
                    sign.assert_not_called()
                self.assertFalse((app / "Contents/Info.plist").exists())

    def test_valid_signed_manifest(self):
        path, metadata = self.fixture()
        self.assertEqual(self.verify(path)[0], metadata)

    def test_archive_tampering_rejected(self):
        path, metadata = self.fixture()
        (path.parent / metadata["archive"]["name"]).write_bytes(b"changed")
        with self.assertRaises(ValueError):
            self.verify(path)

    def test_wrong_checksum_even_with_updated_manifest_rejected(self):
        path, metadata = self.fixture()
        checksum = path.parent / metadata["checksum"]["name"]
        checksum.write_text("0" * 64 + "  " + metadata["archive"]["name"] + "\n")
        metadata["checksum"] = release.asset(checksum)
        self.rewrite(path, metadata)
        with self.assertRaises(ValueError):
            self.verify(path)

    def test_manifest_cannot_mix_architecture_or_version(self):
        path, original = self.fixture()
        for changes in ({"version": "1.2.4"}, {"arch": "x86_64"}, {"arch": "universal"}, {"build": "8"}):
            self.rewrite(path, dict(original, **changes))
            with self.assertRaises(ValueError):
                self.verify(path)

    def test_feed_signature_cannot_be_bypassed_with_new_checksum(self):
        path, metadata = self.fixture()
        feed = path.parent / metadata["appcast"]["name"]
        feed.write_bytes(feed.read_bytes().replace(b"<channel>", b"<channel> "))
        metadata["appcast"] = release.asset(feed)
        self.rewrite(path, metadata)
        with self.assertRaises(ValueError):
            self.verify(path)

    def test_signed_feed_cannot_point_to_wrong_host(self):
        path, _ = self.fixture()
        config = dict(self.config, downloadURLTemplate="https://other.example.com/v{version}/{filename}")
        with self.assertRaises(ValueError):
            self.verify(path, config)

    def test_mirror_requires_its_own_signed_download_url(self):
        config = dict(self.config, fallbackFeedURLTemplate="https://mirror.example.com/appcast-{arch}.xml", fallbackDownloadURLTemplate="https://mirror.example.com/v{version}/{filename}")
        path, metadata = self.fixture(config=config)
        self.verify(path, config)
        fallback = path.parent / metadata["fallbackAppcast"]["name"]
        fallback.write_bytes((path.parent / metadata["appcast"]["name"]).read_bytes())
        metadata["fallbackAppcast"] = release.asset(fallback)
        self.rewrite(path, metadata)
        with self.assertRaises(ValueError):
            self.verify(path, config)

    def test_asset_paths_and_symlinks_rejected(self):
        path, metadata = self.fixture()
        original = copy.deepcopy(metadata)
        metadata["archive"]["name"] = "../outside.zip"
        self.rewrite(path, metadata)
        with self.assertRaises(ValueError):
            self.verify(path)
        self.rewrite(path, original)
        archive = path.parent / original["archive"]["name"]
        moved = self.root / "outside.zip"
        archive.rename(moved)
        archive.symlink_to(moved)
        with self.assertRaises(ValueError):
            self.verify(path)

    def test_macho_architecture_mismatch_rejected(self):
        binary = self.root / "binary"
        binary.write_bytes(bytes.fromhex("cffaedfe") + b"fixture")
        with patch.object(release, "run", return_value="arm64 x86_64"), self.assertRaises(ValueError):
            release.verify_architecture(self.root, "arm64")
        with patch.object(release, "run", return_value="arm64"):
            release.verify_architecture(self.root, "arm64")

    def test_cask_uses_verified_hashes_urls_and_preserves_normal_uninstall_data(self):
        records = [self.verify(self.fixture(arch)[0]) for arch in release.ARCHES]
        text = release.cask_text(records)
        for metadata, resolved in records:
            self.assertIn(metadata["archive"]["sha256"], text)
            self.assertIn(resolved["downloadURLTemplate"], text)
        self.assertIn('version "1.2.3"', text)
        self.assertIn('auto_updates true', text)
        self.assertIn('depends_on macos: :sonoma', text)
        self.assertIn('app "Another You.app"', text)
        self.assertIn('zap trash:', text)
        self.assertNotIn('uninstall ', text)

    def test_cask_rejects_mixed_versions_and_duplicate_arches(self):
        records = [self.verify(self.fixture(arch)[0]) for arch in release.ARCHES]
        records[1][0]["version"] = "2.0.0"
        with self.assertRaises(ValueError):
            release.cask_text(records)
        with self.assertRaises(ValueError):
            release.cask_text([records[0], records[0]])

    def test_single_arch_cask_explicitly_restricts_architecture(self):
        text = release.cask_text([self.verify(self.fixture()[0])])
        self.assertIn('depends_on arch: :arm64', text)
        self.assertNotIn('on_intel', text)

    def test_cask_output_never_overwrites(self):
        config_path = self.root / "config.json"
        config_path.write_text(json.dumps(self.config))
        existing = self.root / "another-you.rb"
        existing.write_text("keep")
        result = subprocess.run([sys.executable, str(release.ROOT / "scripts/release.py"), "--config", str(config_path), "cask", "--manifest", str(self.root / "unused.json"), "--output", str(existing)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("输出已存在", result.stderr)
        self.assertEqual(existing.read_text(), "keep")

    @unittest.skipUnless(sys.platform == "darwin" and os.environ.get("SPARKLE_BIN"), "需设置 SPARKLE_BIN 执行真实 Sparkle 工具集成测试")
    def test_real_sparkle_generates_signed_appcast_and_archive(self):
        app = self.root / "Another You.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        source = self.root / "fixture.c"
        source.write_text("int main(void) { return 0; }\n")
        release.run(["cc", source, "-o", app / "Contents/MacOS/AnotherYou"])
        metadata = {"version": "1.2.3", "build": "7", "arch": "arm64" if os.uname().machine == "arm64" else "x86_64"}
        resolved = release.resolved_config(self.config, metadata["version"], metadata["arch"])
        with patch.dict(os.environ, {"APP_VERSION": metadata["version"], "APP_BUILD": metadata["build"], "ANOTHER_YOU_UPDATES_ENABLED": "1", "SU_FEED_URL": resolved["feedURLTemplate"], "SPARKLE_PUBLIC_ED_KEY": self.public}):
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(release.build_settings()))
        release.run(["codesign", "--force", "--sign", "-", app])
        source_directory = self.root / "archives"
        source_directory.mkdir()
        archive = source_directory / release.package_name(metadata["version"], metadata["arch"])
        release.run(["ditto", "-c", "-k", "--keepParent", app, archive])
        key = self.root / "sparkle.key"
        key.write_text(self.seed)
        key.chmod(0o600)
        release.verify_key_pair(key, self.public)
        feed = self.root / "appcast.xml"
        tool = Path(os.environ["SPARKLE_BIN"])
        tool_home = self.root / "tool-home"
        tool_home.mkdir()
        env = dict(os.environ, CFFIXED_USER_HOME=str(tool_home))
        release.run([tool / "generate_appcast", "--ed-key-file", key, "--download-url-prefix", resolved["downloadURLTemplate"].rsplit("/", 1)[0] + "/", "-o", feed, source_directory], env=env)
        release.run([tool / "sign_update", "--verify", "--ed-key-file", key, feed], env=env)
        release.verify_feed(feed, archive, metadata, resolved)

    def test_package_output_never_overwrites(self):
        from argparse import Namespace
        existing = self.root / "output"
        existing.mkdir()
        (existing / "keep").write_text("keep")
        with patch.object(release, "preflight", return_value={}), self.assertRaises(ValueError):
            release.package(Namespace(output=str(existing), version="1.2.3", build="7", arch="arm64"), self.config)
        self.assertEqual((existing / "keep").read_text(), "keep")


if __name__ == "__main__":
    unittest.main(verbosity=2)
