#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("publish_release", Path(__file__).with_name("publish-release.py"))
publish = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = publish
spec.loader.exec_module(publish)


def make_plan(arches=("arm64", "x86_64"), version="1.2.3", build="7"):
    records, packages, feeds, urls = [], [], {h: [] for h in publish.HOSTS}, {h: {} for h in publish.HOSTS}
    for arch in arches:
        archive = publish.Asset(f"another-you-v{version}-macOS-{arch}.zip", f"zip:{arch}".encode())
        checksum = publish.Asset(archive.name + ".sha256", f"{archive.sha256}  {archive.name}\n".encode())
        packages.extend((archive, checksum))
        metadata = {"arch": arch, "version": version, "build": build, "sourceCommit": "a" * 40,
                    "archive": {"name": archive.name, "sha256": archive.sha256}, "signing": {"notarized": False}}
        resolved = {"repository": publish.REPOSITORY, "publicEDKey": "test-public-key", "homepage": "https://example.com"}
        for host in publish.HOSTS:
            prefix = f"https://{host}.com/{publish.REPOSITORY}/releases/"
            data = (f'<rss xmlns:sparkle="{publish.release.SPARKLE}"><channel><item>'
                    f'<sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString><enclosure url="{host}/{arch}" />'
                    '</item></channel></rss>').encode()
            feed = publish.Asset(f"appcast-{arch}.xml", data)
            feeds[host].append(feed)
            urls[host][feed.name] = prefix + ("latest/download/" if host == "github" else "download/update-release/") + feed.name
            urls[host][archive.name] = prefix + f"download/v{version}/" + archive.name
            urls[host][checksum.name] = urls[host][archive.name] + ".sha256"
            if host == "github":
                resolved.update(downloadURLTemplate=urls[host][archive.name], feedURLTemplate=urls[host][feed.name])
        records.append((metadata, resolved))
    return publish.Plan(version, build, "a" * 40, records, packages, feeds, urls, "cask contents\n")


class FakeAPI(publish.ReleaseAPI):
    def __init__(self, host, events):
        super().__init__(host, "secret")
        self.events, self.releases, self.attachments = events, {}, {}
        self.next_id, self.latest, self.failures = 1, None, {}
        self.tag_commits = {}
        self.public = True

    def preflight(self, commit):
        publish.require(self.public, "仓库不是公开仓库")
        self.events.append((self.host, "preflight"))

    def get_release(self, tag):
        return self.releases.get(tag)

    def tag_commit(self, tag):
        return self.tag_commits.get(tag)

    def call(self, suffix, *, method="GET", payload=None, missing=False):
        if suffix.startswith("/commits/"):
            ref = suffix.split("/")[-1]
            if ref in self.tag_commits:
                return {"sha": self.tag_commits[ref]}
            if len(ref) == 40:
                return {"sha": ref}
            return None
        if suffix == "/releases/latest":
            return self.latest
        if suffix == "/releases" and method == "POST":
            item = dict(payload, id=self.next_id)
            self.next_id += 1
            self.releases[item["tag_name"]] = item
            self.attachments[item["id"]] = []
            if not item.get("draft"):
                self.tag_commits[item["tag_name"]] = item["target_commitish"]
            self.events.append((self.host, "create", item["tag_name"]))
            return item
        if suffix.startswith("/releases/") and method == "PATCH":
            identifier = int(suffix.split("/")[-1])
            item = next(r for r in self.releases.values() if r["id"] == identifier)
            item.update(payload)
            if payload.get("make_latest") == "true":
                self.latest = item
            self.tag_commits[item["tag_name"]] = item["target_commitish"]
            action = "latest" if payload.get("make_latest") == "true" else "publish-version"
            self.events.append((self.host, action, item["tag_name"]))
            return item
        raise AssertionError((suffix, method))

    def assets(self, item):
        return self.attachments[item["id"]]

    def download(self, item, remote, maximum):
        publish.require(len(remote["data"]) <= maximum, "远端响应超过预期大小")
        self.events.append((self.host, "download", item["tag_name"], remote["name"]))
        return remote["data"]

    def upload_new(self, item, asset):
        key = (item["tag_name"], asset.name)
        self.events.append((self.host, "upload", *key))
        if self.failures.get(key, 0):
            self.failures[key] -= 1
            raise ValueError("模拟上传失败")
        remote = {"id": self.next_id, "name": asset.name, "data": asset.data}
        self.next_id += 1
        self.attachments[item["id"]].append(remote)
        return self.checked(item, asset)

    def delete(self, item, remote):
        self.attachments[item["id"]].remove(remote)
        self.events.append((self.host, "delete", item["tag_name"], remote["name"]))

    def verify_public(self, url, asset):
        if "/latest/" in url:
            item = self.latest
        elif "/update-release/" in url:
            item = self.releases.get("update-release")
        else:
            tag = url.split("/download/", 1)[1].split("/", 1)[0]
            item = self.releases.get(tag)
        publish.require(item and not item.get("draft", False), "匿名附件不可用")
        self.checked(item, asset)
        self.events.append((self.host, "public", asset.name))


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.plan = make_plan()
        self.events = []
        self.apis = {h: FakeAPI(h, self.events) for h in publish.HOSTS}

    def test_publish_order_and_anonymous_verification(self):
        publish.publish(self.plan, self.apis, "notes")
        permanent = self.events.index(("gitee", "create", "update-release"))
        version = self.events.index(("gitee", "create", self.plan.tag))
        self.assertLess(permanent, version)
        first_feed = next(i for i, e in enumerate(self.events) if len(e) == 4 and e[1] == "upload" and e[3].startswith("appcast-"))
        for host in publish.HOSTS:
            for asset in self.plan.packages:
                self.assertTrue(any(i < first_feed and e == (host, "download", self.plan.tag, asset.name) for i, e in enumerate(self.events)))
        self.assertEqual(sum(e[1] == "public" for e in self.events), 24)
        self.assertTrue(self.apis["github"].latest)

    def test_anonymous_packages_verified_before_switching_either_feed(self):
        publish.publish(self.plan, self.apis, "notes")
        switch = next(i for i, e in enumerate(self.events) if len(e) == 4 and e[1] == "upload" and e[2] == "update-release")
        for host in publish.HOSTS:
            for asset in self.plan.packages + self.plan.feeds[host]:
                self.assertTrue(any(i < switch and e == (host, "public", asset.name) for i, e in enumerate(self.events)))
        self.assertLess(self.events.index(("github", "publish-version", self.plan.tag)), switch)
        self.assertGreater(self.events.index(("github", "latest", self.plan.tag)), switch)

    def test_anonymous_download_failure_leaves_update_feeds_unchanged_and_can_resume(self):
        with patch.object(self.apis["gitee"], "verify_public", side_effect=ValueError("匿名下载失败")):
            with self.assertRaisesRegex(ValueError, "匿名下载失败"):
                publish.publish(self.plan, self.apis, "notes")
        self.assertFalse(any(e[1] == "latest" or (len(e) == 4 and e[1] == "upload" and e[2] == "update-release") for e in self.events))
        self.assertFalse(self.apis["github"].releases[self.plan.tag]["draft"])
        publish.publish(self.plan, self.apis, "notes")
        self.assertTrue(self.apis["github"].latest)

    def test_same_hash_is_idempotent(self):
        publish.publish(self.plan, self.apis, "notes")
        self.events.clear()
        publish.publish(self.plan, self.apis, "notes")
        self.assertFalse(any(e[1] in ("upload", "delete", "create") for e in self.events))

    def test_different_hash_refused_before_writes(self):
        publish.publish(self.plan, self.apis, "notes")
        target = self.apis["github"].releases[self.plan.tag]
        self.apis["github"].attachments[target["id"]][0]["data"] = b"bad"
        self.events.clear()
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            publish.publish(self.plan, self.apis, "notes")
        self.assertFalse(any(e[1] in ("upload", "delete", "create", "latest") for e in self.events))

    def test_partial_package_failure_does_not_switch_feed(self):
        asset = self.plan.packages[-1]
        self.apis["gitee"].failures[(self.plan.tag, asset.name)] = 1
        with self.assertRaisesRegex(ValueError, "模拟上传失败"):
            publish.publish(self.plan, self.apis, "notes")
        self.assertFalse(any(e[1] == "latest" or (len(e) == 4 and e[1] == "upload" and e[3].startswith("appcast-")) for e in self.events))
        publish.publish(self.plan, self.apis, "notes")
        self.assertTrue(self.apis["github"].latest)

    def test_existing_tag_source_mismatch_refused(self):
        self.apis["github"].tag_commits[self.plan.tag] = "b" * 40
        with self.assertRaisesRegex(ValueError, "另一提交"):
            publish.publish(self.plan, self.apis, "notes")
        self.assertIsNone(self.apis["github"].latest)
        self.assertFalse(any(e[1] in ("upload", "delete", "create", "latest") for e in self.events))

    def test_existing_release_source_mismatch_refused(self):
        publish.publish(self.plan, self.apis, "notes")
        self.apis["gitee"].tag_commits[self.plan.tag] = "b" * 40
        self.events.clear()
        with self.assertRaisesRegex(ValueError, "另一提交"):
            publish.publish(self.plan, self.apis, "notes")
        self.assertFalse(any(e[1] in ("upload", "delete", "create") for e in self.events))

    def test_wrong_permanent_release_order_refused(self):
        self.apis["gitee"].ensure_release(self.plan.tag, self.plan.commit, "notes")
        with self.assertRaisesRegex(ValueError, "早于"):
            publish.publish(self.plan, self.apis, "notes")

    def test_missing_architecture_refused_before_network(self):
        with self.assertRaisesRegex(ValueError, "x86_64"):
            publish.publish(make_plan(("arm64",)), self.apis, "notes")
        self.assertEqual(self.events, [])

    def test_non_public_repository_refused(self):
        self.apis["gitee"].public = False
        with self.assertRaisesRegex(ValueError, "公开"):
            publish.publish(self.plan, self.apis, "notes")
        self.assertFalse(any(e[1] == "create" for e in self.events))

    def test_feed_replace_restores_previous_bytes(self):
        publish.publish(self.plan, self.apis, "notes")
        api = self.apis["gitee"]
        item = api.releases["update-release"]
        previous = self.plan.feeds["gitee"][0]
        replacement = publish.Asset(previous.name, b"new signed feed")
        api.failures[("update-release", previous.name)] = 1
        with self.assertRaisesRegex(ValueError, "旧 feed 已保留或恢复"):
            api.replace_feed(item, replacement)
        api.checked(item, previous)
        self.assertTrue(any(a["name"].startswith(previous.name + ".pending-") for a in api.assets(item)))

    def test_feed_delete_response_failure_restores_previous_bytes(self):
        publish.publish(self.plan, self.apis, "notes")
        api = self.apis["gitee"]
        item = api.releases["update-release"]
        previous = self.plan.feeds["gitee"][0]
        replacement = publish.Asset(previous.name, b"new signed feed")
        original_delete = api.delete
        def delete_then_timeout(target, remote):
            original_delete(target, remote)
            raise ValueError("服务器已删除，但响应丢失")
        with patch.object(api, "delete", side_effect=delete_then_timeout):
            with self.assertRaisesRegex(ValueError, "旧 feed 已保留或恢复"):
                api.replace_feed(item, replacement)
        api.checked(item, previous)

    def test_feed_retry_cleans_stage_after_previous_cleanup_failure(self):
        publish.publish(self.plan, self.apis, "notes")
        api = self.apis["gitee"]
        item = api.releases["update-release"]
        replacement = publish.Asset(self.plan.feeds["gitee"][0].name, b"next signed feed")
        original_delete = api.delete
        def fail_pending_cleanup(target, remote):
            if ".pending-" in remote["name"]:
                raise ValueError("暂存清理失败")
            original_delete(target, remote)
        with patch.object(api, "delete", side_effect=fail_pending_cleanup):
            with self.assertRaisesRegex(ValueError, "暂存清理失败"):
                api.replace_feed(item, replacement)
        api.checked(item, replacement)
        api.replace_feed(item, replacement)
        self.assertFalse(any(".pending-" in a["name"] for a in api.assets(item)))

    def test_mirror_version_downgrade_refused_even_with_higher_build(self):
        publish.publish(self.plan, self.apis, "notes")
        self.apis["github"].latest = None
        self.events.clear()
        with self.assertRaisesRegex(ValueError, "gitee.*降级"):
            publish.publish(make_plan(version="1.2.2", build="99"), self.apis, "notes")
        self.assertFalse(any(e[1] in ("upload", "delete", "create", "latest") for e in self.events))

    def test_feed_same_build_different_bytes_refused(self):
        publish.publish(self.plan, self.apis, "notes")
        next_plan = make_plan(version="1.2.4", build="7")
        next_plan.feeds["gitee"][0] = publish.Asset(next_plan.feeds["gitee"][0].name, next_plan.feeds["gitee"][0].data + b"\n")
        self.events.clear()
        with self.assertRaisesRegex(ValueError, "构建号"):
            publish.publish(next_plan, self.apis, "notes")
        self.assertFalse(any(e[1] in ("upload", "delete", "create") for e in self.events))

    def test_no_downgrade(self):
        publish.publish(self.plan, self.apis, "notes")
        self.events.clear()
        with self.assertRaisesRegex(ValueError, "降级"):
            publish.publish(make_plan(version="1.2.2", build="8"), self.apis, "notes")
        self.assertFalse(any(e[1] in ("upload", "delete", "create") for e in self.events))

    def test_verify_is_read_only(self):
        publish.publish(self.plan, self.apis, "notes")
        self.events.clear()
        publish.verify_remote(self.plan, self.apis)
        self.assertFalse(any(e[1] in ("upload", "delete", "create", "latest") for e in self.events))


class InputTests(unittest.TestCase):
    @contextlib.contextmanager
    def verified_inputs(self):
        plan = make_plan()
        with tempfile.TemporaryDirectory(prefix="another-you-publish-input-") as directory:
            paths, records = [], {}
            for metadata, resolved in plan.records:
                arch = metadata["arch"]
                folder = Path(directory) / arch
                folder.mkdir()
                record = dict(metadata)
                for key, asset in zip(("archive", "checksum"), [a for a in plan.packages if f"-{arch}.zip" in a.name]):
                    path = folder / asset.name
                    path.write_bytes(asset.data)
                    record[key] = publish.release.asset(path)
                for host, key in (("github", "appcast"), ("gitee", "fallbackAppcast")):
                    asset = next(a for a in plan.feeds[host] if arch in a.name)
                    name = asset.name if host == "github" else asset.name.replace("appcast-", "appcast-fallback-")
                    path = folder / name
                    path.write_bytes(asset.data)
                    record[key] = publish.release.asset(path)
                resolved = dict(resolved, fallbackDownloadURLTemplate=plan.urls["gitee"][record["archive"]["name"]],
                                fallbackFeedURLTemplate=plan.urls["gitee"][f"appcast-{arch}.xml"])
                manifest = folder / "manifest.json"
                paths.append(manifest)
                records[manifest] = (record, resolved)
            with patch.object(publish.release, "verify_manifest", side_effect=lambda path, config: records[path]) as verify:
                yield paths, records, verify

    def test_load_plan_reuses_manifest_verifier_and_mirror_names(self):
        with self.verified_inputs() as (paths, records, verify):
            plan = publish.load_plan(paths, {"repository": publish.REPOSITORY})
            self.assertEqual(verify.call_count, 2)
            self.assertEqual(plan.missing_arches, [])
            self.assertEqual([a.name for a in plan.feeds["gitee"]], ["appcast-arm64.xml", "appcast-x86_64.xml"])
            self.assertIn("auto_updates true", plan.cask)

    def test_duplicate_architecture_and_mixed_metadata_refused(self):
        with self.verified_inputs() as (paths, records, _):
            with self.assertRaisesRegex(ValueError, "重复架构"):
                publish.load_plan([paths[0], paths[0]], {"repository": publish.REPOSITORY})
            for key, different in (("build", "8"), ("sourceCommit", "b" * 40)):
                metadata = records[paths[1]][0]
                original = metadata[key]
                metadata[key] = different
                with self.assertRaisesRegex(ValueError, "不一致"):
                    publish.load_plan(paths, {"repository": publish.REPOSITORY})
                metadata[key] = original

    def test_url_outside_repository_refused(self):
        with self.verified_inputs() as (paths, records, _):
            records[paths[0]][1]["fallbackFeedURLTemplate"] = "https://gitee.com/other/repository/feed.xml"
            with self.assertRaisesRegex(ValueError, "本仓库"):
                publish.load_plan(paths, {"repository": publish.REPOSITORY})

    def test_cli_requires_manifest_and_exclusive_mode(self):
        for args in ([], ["--publish", "--verify", "--manifest", "manifest.json"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
                publish.parse_args(args)
            self.assertEqual(result.exception.code, 2)

    def test_dry_run_no_credentials_api_or_tap_write(self):
        plan = make_plan(("arm64",))
        with patch.object(publish, "load_plan", return_value=plan), patch.object(publish.release, "load_config", return_value={}), \
                patch.object(publish, "credentials", side_effect=AssertionError("credentials called")), \
                patch.object(publish, "ReleaseAPI", side_effect=AssertionError("network called")), \
                patch.object(publish, "write_tap", side_effect=AssertionError("tap write called")), contextlib.redirect_stdout(io.StringIO()) as output:
            publish.main(["--manifest", "unused.json"])
        self.assertIn('"mode": "dry-run"', output.getvalue())
        self.assertIn('"x86_64"', output.getvalue())

    def test_invalid_signature_stops_before_credentials(self):
        with patch.object(publish.release, "load_config", return_value={"repository": publish.REPOSITORY}), \
                patch.object(publish.release, "verify_manifest", side_effect=ValueError("签名无效")) as verify, \
                patch.object(publish, "credentials", side_effect=AssertionError("credentials called")):
            with self.assertRaisesRegex(ValueError, "签名无效"):
                publish.main(["--publish", "--manifest", "unused.json"])
            verify.assert_called_once()

    def test_repository_mismatch_refused(self):
        with self.assertRaisesRegex(ValueError, "发布仓库"):
            publish.load_plan([Path("x")], {"repository": "owner/other"})

    def test_missing_credentials_are_clear(self):
        with patch.object(publish.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "secret")):
            with self.assertRaisesRegex(ValueError, "GitHub 凭据"):
                publish.credentials({})
        with self.assertRaisesRegex(ValueError, "GITEE_TOKEN"):
            publish.credentials({"GH_TOKEN": "secret"})

    def test_api_error_does_not_expose_response_or_token(self):
        class BadTransport:
            def request(self, url, **kwargs):
                self.url, self.kwargs = url, kwargs
                return 403, b"credential=super-secret-value"
        transport = BadTransport()
        api = publish.ReleaseAPI("gitee", "super-secret-value", transport)
        with self.assertRaises(ValueError) as error:
            api.call("/releases", method="POST", payload={"body": "notes"})
        self.assertNotIn("super-secret", str(error.exception))
        self.assertNotIn("super-secret", transport.url)
        self.assertEqual(transport.kwargs["headers"]["Authorization"], "Bearer super-secret-value")
        self.assertEqual(transport.kwargs["data"], b'{"body": "notes"}')

    def test_github_tag_lookup_dereferences_annotated_tag_without_branch_fallback(self):
        api = publish.ReleaseAPI("github", "test")
        with patch.object(api, "call", side_effect=[
                {"ref": "refs/tags/v1.2.3", "object": {"type": "tag", "sha": "b" * 40}},
                {"object": {"type": "commit", "sha": "a" * 40}}]) as call:
            self.assertEqual(api.tag_commit("v1.2.3"), "a" * 40)
        self.assertEqual(call.call_args_list[0].args[0], "/git/ref/tags/v1.2.3")
        self.assertEqual(call.call_args_list[1].args[0], "/git/tags/" + "b" * 40)
        with patch.object(api, "call", return_value=None) as call:
            self.assertIsNone(api.tag_commit("v1.2.3"))
            call.assert_called_once_with("/git/ref/tags/v1.2.3", missing=True)

    def test_gitee_tag_lookup_uses_paginated_exact_name_and_commit_sha(self):
        api = publish.ReleaseAPI("gitee", "test")
        with patch.object(api, "call", side_effect=[
                [{"name": f"other-{i}", "commit": {"sha": "b" * 40}} for i in range(100)],
                [{"name": "v1.2.3", "commit": {"sha": "a" * 40}}]]) as call:
            self.assertEqual(api.tag_commit("v1.2.3"), "a" * 40)
        self.assertEqual([c.args[0] for c in call.call_args_list], ["/tags?per_page=100&page=1", "/tags?per_page=100&page=2"])

    def test_upload_and_download_http_contracts(self):
        class Transport:
            def __init__(self, replies):
                self.replies, self.calls = list(replies), []
            def request(self, url, **kwargs):
                self.calls.append((url, kwargs))
                return self.replies.pop(0)
        asset = publish.Asset("another-you-v1.2.3-macOS-arm64.zip", b"ZIP fixture")
        for host in publish.HOSTS:
            with self.subTest(host=host):
                remote = {"id": 12, "name": asset.name}
                transport = Transport([(201, json.dumps(remote).encode()), (200, json.dumps([remote]).encode()), (200, asset.data)])
                api = publish.ReleaseAPI(host, "secret", transport)
                api.upload_new({"id": 7}, asset)
                upload_url, upload = transport.calls[0]
                download_url, download = transport.calls[-1]
                self.assertEqual(upload["headers"]["Authorization"], "Bearer secret")
                self.assertEqual(download["headers"]["Accept"], "application/octet-stream")
                self.assertEqual(download["maximum"], len(asset.data))
                self.assertTrue(download["redirects"])
                self.assertNotIn("secret", upload_url + download_url)
                if host == "github":
                    self.assertIn("uploads.github.com/repos/", upload_url)
                    self.assertIn("/releases/7/assets?name=", upload_url)
                    self.assertTrue(download_url.endswith("/releases/assets/12"))
                    self.assertEqual(upload["data"], asset.data)
                else:
                    self.assertTrue(upload_url.endswith("/releases/7/attach_files"))
                    self.assertTrue(download_url.endswith("/releases/7/attach_files/12/download"))
                    self.assertTrue(upload["headers"]["Content-Type"].startswith("multipart/form-data; boundary="))
                    self.assertIn(b'name="file"; filename="' + asset.name.encode() + b'"', upload["data"])
                    self.assertIn(asset.data, upload["data"])

    def test_github_publication_does_not_set_latest_early(self):
        api = publish.ReleaseAPI("github", "secret")
        with patch.object(api, "call", return_value={"id": 1}) as call:
            api.publish_version({"id": 1, "draft": True})
            call.assert_called_once_with("/releases/1", method="PATCH", payload={"draft": False, "prerelease": False, "make_latest": "false"})

    def test_network_error_is_sanitized(self):
        transport = publish.Transport()
        with patch.object(transport.opener, "open", side_effect=urllib.error.URLError("secret-token")):
            with self.assertRaises(ValueError) as error:
                transport.request("https://gitee.com/api/v5/repos/example")
        self.assertNotIn("secret-token", str(error.exception))

    def test_redirect_drops_credentials(self):
        class Response:
            status = 200
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def read(self, maximum):
                return b"package"
        transport = publish.Transport()
        redirect = urllib.error.HTTPError("https://api.github.com/download", 302, "Found",
                                          {"Location": "https://release-assets.githubusercontent.com/file"}, None)
        with patch.object(transport.opener, "open", side_effect=[redirect, Response()]) as opened:
            status, data = transport.request("https://api.github.com/download", headers={"Authorization": "Bearer secret"}, redirects=True)
        self.assertEqual((status, data), (200, b"package"))
        self.assertEqual(opened.call_args_list[0].args[0].get_header("Authorization"), "Bearer secret")
        self.assertIsNone(opened.call_args_list[1].args[0].get_header("Authorization"))

    def test_tap_not_written_if_publish_fails(self):
        with patch.object(publish, "load_plan", return_value=make_plan()), patch.object(publish.release, "load_config", return_value={}), \
                patch.object(publish, "prepare_tap", return_value=("prepared",)), \
                patch.object(publish, "credentials", return_value={h: "test" for h in publish.HOSTS}), \
                patch.object(publish, "publish", side_effect=ValueError("上传失败")), patch.object(publish, "write_tap") as write:
            with self.assertRaisesRegex(ValueError, "上传失败"):
                publish.main(["--publish", "--manifest", "unused", "--tap-path", "unused"])
            write.assert_not_called()

    def test_tap_dirty_file_refused_and_clean_file_updated(self):
        with tempfile.TemporaryDirectory(prefix="another-you-publish-test-") as directory:
            path = Path(directory)
            subprocess.run(["git", "init", "-q", directory], check=True)
            (path / "Casks").mkdir()
            target = path / "Casks/another-you.rb"
            target.write_text("old\n")
            subprocess.run(["git", "-C", directory, "add", "Casks/another-you.rb"], check=True)
            subprocess.run(["git", "-C", directory, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "initial"], check=True)
            target.write_text("user work\n")
            with self.assertRaisesRegex(ValueError, "未提交"):
                publish.prepare_tap(path, "new\n")
            target.write_text("old\n")
            prepared = publish.prepare_tap(path, "new\n")
            with contextlib.redirect_stdout(io.StringIO()):
                publish.write_tap(prepared)
            self.assertEqual(target.read_text(), "new\n")

    def test_tap_changed_during_publish_refused(self):
        with tempfile.TemporaryDirectory(prefix="another-you-publish-test-") as directory:
            path = Path(directory)
            subprocess.run(["git", "init", "-q", directory], check=True)
            prepared = publish.prepare_tap(path, "new\n")
            (path / "Casks").mkdir()
            (path / "Casks/another-you.rb").write_text("concurrent work\n")
            with self.assertRaisesRegex(ValueError, "发生变化"):
                publish.write_tap(prepared)


if __name__ == "__main__":
    unittest.main(verbosity=2)
