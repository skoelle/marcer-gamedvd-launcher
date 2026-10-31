# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/asset-publish (stdlib unittest)."""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import sys
import tempfile
import time
import unittest
import zipfile
from ftplib import error_perm
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import asset_publish as ap

ARCHIVE_RE = re.compile(r"^gameinfo-\d{8}-\d{6}\.zip$")


def run_cli(*args: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = ap.main(list(args))
    return code, out.getvalue(), err.getvalue()


class FakeFTP:
    def __init__(self, fail_on: str | None = None, size_delta: int = 0) -> None:
        self.fail_on = fail_on
        self.size_delta = size_delta
        self.calls: list[tuple] = []
        self.files: dict[str, int] = {}
        self.remote = ""
        self.encoding = ""

    def connect(self, host: str, port: int, timeout: int | None = None) -> None:
        self.calls.append(("connect", host, port, timeout))

    def login(self, user: str, password: str) -> None:
        self.calls.append(("login", user, password))

    def set_pasv(self, passive: bool) -> None:
        self.calls.append(("set_pasv", passive))

    def cwd(self, path: str) -> None:
        if self.fail_on == "cwd":
            raise error_perm("550 no such directory")
        self.remote = path
        self.calls.append(("cwd", path))

    def voidcmd(self, command: str) -> None:
        self.calls.append(("voidcmd", command))

    def storbinary(self, command: str, handle, blocksize: int = 0) -> None:
        if self.fail_on == "stor":
            raise error_perm("550 upload failed")
        name = command.split(" ", 1)[1]
        data = handle.read()
        self.files[name] = len(data) + self.size_delta
        self.calls.append(("storbinary", name, len(data)))

    def size(self, name: str) -> int:
        if name not in self.files:
            raise error_perm("550 no such file")
        return self.files[name]

    def rename(self, src: str, dst: str) -> None:
        raise AssertionError("the Marcer FTP does not support RNFR/RNTO")

    def delete(self, name: str) -> None:
        raise AssertionError("the Marcer FTP does not support DELE")

    def quit(self) -> None:
        self.calls.append(("quit",))

    def close(self) -> None:
        self.calls.append(("close",))


class GameinfoPublishTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.data = self.tmp / "Data"
        self.source = self.data / "gameinfo"
        self.source.mkdir(parents=True)
        (self.source / "games-cracked.json").write_text('{"a": 1}\n')
        (self.source / "games-pd.json").write_text('{"b": 2}\n')
        (self.source / "manifest.json").write_text('{"count": 2}\n')
        (self.source / "crews.json").write_text('{"crews": []}\n')
        (self.source / "crew-cluster.json").write_text('{"clusters": []}\n')
        (self.source / "unmatched-report.txt").write_text("none\n")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def publish(self, *extra: str) -> tuple[int, dict]:
        code, result, err = self.publish_raw(*extra)
        self.assertEqual(code, 0, err)
        return code, result

    def publish_raw(self, *extra: str) -> tuple[int, dict, str]:
        code, out, err = run_cli(
            "publish", "--data-dir", str(self.data), "--json", *extra
        )
        result = json.loads(out) if out.strip() else {}
        return code, result, err

    def ftp_env(self, **overrides: str):
        values = {
            "MARCER_FTP_HOST": "ftp.example:2121",
            "MARCER_FTP_USER": "user",
            "MARCER_FTP_PASS": "pass",
            "MARCER_FTP_ASSETS_REMOTE": "/assets/",
        }
        values.update(overrides)
        return mock.patch.dict(os.environ, values)

    def archives(self) -> list[Path]:
        return sorted(self.data.glob("gameinfo-*.zip"))

    def test_ftp_settings_default_encoding_is_utf8(self) -> None:
        with self.ftp_env(MARCER_FTP_ENCODING=""):
            settings = ap.ftp_settings()
        self.assertEqual(settings["encoding"], "utf-8")

    def test_deterministic_archive_and_signature(self) -> None:
        first = ap.collect_entries(self.source)
        sig1 = ap.content_signature(first)
        archive1 = ap.write_archive(self.data, ap.KIND_GAMEINFO, first)
        payload1 = archive1.read_bytes()

        # Touch every file with a different mtime; content and ZIP bytes must
        # stay identical.
        later = time.time() + 60
        for path in self.source.iterdir():
            path.touch()
            os.utime(path, (later, later))
        second = ap.collect_entries(self.source)
        sig2 = ap.content_signature(second)
        archive2 = ap.write_archive(self.data, ap.KIND_GAMEINFO, second)

        self.assertEqual(sig1, sig2)
        self.assertEqual(payload1, archive2.read_bytes())

        with zipfile.ZipFile(archive1) as archive:
            self.assertEqual(
                archive.namelist(),
                sorted(
                    [
                        "games-cracked.json",
                        "games-pd.json",
                        "manifest.json",
                        "crews.json",
                        "crew-cluster.json",
                        "unmatched-report.txt",
                    ]
                ),
            )
            for info in archive.infolist():
                self.assertEqual(info.date_time, ap.ZIP_TIMESTAMP)

    def test_excludes_backups_markers_and_unknown_files(self) -> None:
        (self.source / "crew-images.json").write_text('{"images": {}}\n')
        (self.source / "crew-images.json.bak-20261028-162748").write_text("old\n")
        (self.source / "full-index.json.gz").write_bytes(b"index\n")
        (self.source / ".marcer-assets.json").write_text("{}\n")
        (self.source / "notes.txt").write_text("ignore me\n")
        (self.source / "games-cracked.json.tmp").write_text("tmp\n")

        names = [entry["relpath"] for entry in ap.collect_entries(self.source)]
        self.assertEqual(
            names,
            sorted(
                [
                    "games-cracked.json",
                    "games-pd.json",
                    "manifest.json",
                    "crews.json",
                    "crew-images.json",
                    "crew-cluster.json",
                    "full-index.json.gz",
                    "unmatched-report.txt",
                ]
            ),
        )

    def test_first_run_creates_archive_and_state(self) -> None:
        _, result = self.publish()
        self.assertEqual(result["status"], "created")
        archive = Path(result["archive"])
        self.assertTrue(archive.is_file())
        self.assertRegex(archive.name, ARCHIVE_RE)

        state = json.loads((self.data / ".asset-publish-state.json").read_text())
        entry = state["assets"]["gameinfo"]
        self.assertEqual(entry["signature"], result["signature"])
        self.assertEqual(entry["archive"], archive.name)
        self.assertEqual(entry["size"], archive.stat().st_size)

    def test_unchanged_content_is_skipped_and_force_repacks(self) -> None:
        _, first = self.publish()
        _, second = self.publish()
        self.assertEqual(second["status"], "skipped")
        self.assertEqual(second["archive"], first["archive"])
        self.assertEqual(len(self.archives()), 1)

        _, forced = self.publish("--force")
        self.assertEqual(forced["status"], "created")
        self.assertNotEqual(forced["archive"], first["archive"])
        self.assertEqual(len(self.archives()), 2)
        self.assertRegex(Path(forced["archive"]).name, ARCHIVE_RE)

    def test_changed_content_creates_new_archive(self) -> None:
        _, first = self.publish()
        (self.source / "games-pd.json").write_text('{"b": 3}\n')
        _, second = self.publish()
        self.assertEqual(second["status"], "created")
        self.assertNotEqual(second["signature"], first["signature"])
        self.assertNotEqual(second["archive"], first["archive"])

    def test_missing_archive_is_rebuilt_even_when_signature_matches(self) -> None:
        _, first = self.publish()
        Path(first["archive"]).unlink()
        _, second = self.publish()
        self.assertEqual(second["status"], "created")
        self.assertTrue(Path(second["archive"]).is_file())

    def test_dry_run_writes_nothing(self) -> None:
        _, first = self.publish("--dry-run")
        self.assertEqual(first["status"], "would-create")
        self.assertEqual(self.archives(), [])
        self.assertFalse((self.data / ".asset-publish-state.json").exists())

    def test_dry_run_reports_skip(self) -> None:
        self.publish()
        _, result = self.publish("--dry-run")
        self.assertEqual(result["status"], "would-skip")

    def test_missing_source_fails(self) -> None:
        code, _, err = run_cli(
            "publish", "--data-dir", str(self.data), "--source", str(self.tmp / "nope")
        )
        self.assertEqual(code, 1)
        self.assertIn("source directory not found", err)

    def test_upload_requires_host_before_packing(self) -> None:
        with self.ftp_env(MARCER_FTP_HOST=""):
            code, _, err = self.publish_raw("--upload")
        self.assertEqual(code, 1)
        self.assertIn("MARCER_FTP_HOST", err)
        self.assertEqual(self.archives(), [])
        self.assertFalse((self.data / ".asset-publish-state.json").exists())

    def test_upload_success_uploads_and_updates_manifest(self) -> None:
        fake = FakeFTP()
        with self.ftp_env(), mock.patch.object(
            ap, "FTP", lambda: fake
        ), mock.patch.object(ap, "run_asset_manifest") as manifest:
            _, result = self.publish("--upload")

        self.assertEqual(result["status"], "uploaded")
        self.assertTrue(result["created"])
        self.assertTrue(result["uploaded"])
        self.assertEqual(result["remote"], f"/assets/{Path(result['archive']).name}")
        self.assertTrue(result["manifest_updated"])
        manifest.assert_called_once_with()

        self.assertIn(("set_pasv", True), fake.calls)
        self.assertIn(("cwd", "/assets/"), fake.calls)
        self.assertIn(("voidcmd", "TYPE I"), fake.calls)
        self.assertIn(
            ("storbinary", Path(result["archive"]).name, result["size"]),
            fake.calls,
        )
        self.assertFalse(any(call[0] in ("rename", "delete") for call in fake.calls))
        self.assertEqual(
            fake.files, {Path(result["archive"]).name: result["size"]}
        )

        state = json.loads((self.data / ".asset-publish-state.json").read_text())
        entry = state["assets"]["gameinfo"]
        self.assertTrue(entry["uploaded"])
        self.assertFalse(entry["manifest_dirty"])
        self.assertEqual(entry["remote"], result["remote"])

    def test_reuses_complete_remote_file_without_storing_again(self) -> None:
        self.publish()
        archive = self.archives()[0]
        fake = FakeFTP()
        fake.files[archive.name] = archive.stat().st_size

        with self.ftp_env(), mock.patch.object(
            ap, "FTP", lambda: fake
        ), mock.patch.object(ap, "run_asset_manifest") as manifest:
            _, result = self.publish("--upload")

        self.assertEqual(result["status"], "uploaded")
        self.assertFalse(result["created"])
        self.assertFalse(any(call[0] == "storbinary" for call in fake.calls))
        manifest.assert_called_once_with()

    def test_leaves_existing_part_file_untouched(self) -> None:
        self.publish()
        archive = self.archives()[0]
        fake = FakeFTP()
        fake.files[f"{archive.name}.part"] = 123

        with self.ftp_env(), mock.patch.object(
            ap, "FTP", lambda: fake
        ), mock.patch.object(ap, "run_asset_manifest"):
            _, result = self.publish("--upload")

        self.assertEqual(result["status"], "uploaded")
        self.assertEqual(fake.files[f"{archive.name}.part"], 123)
        self.assertFalse(any(call[0] == "delete" for call in fake.calls))

    def test_skips_upload_when_already_uploaded(self) -> None:
        fake = FakeFTP()
        with self.ftp_env(), mock.patch.object(
            ap, "FTP", lambda: fake
        ), mock.patch.object(ap, "run_asset_manifest") as manifest:
            self.publish("--upload")
            _, result = self.publish("--upload")

        self.assertEqual(result["status"], "skipped")
        self.assertTrue(result["uploaded"])
        self.assertEqual(len(self.archives()), 1)
        manifest.assert_called_once()

    def test_upload_failure_is_retried_without_repacking(self) -> None:
        failing = FakeFTP(fail_on="stor")
        with self.ftp_env(), mock.patch.object(
            ap, "FTP", lambda: failing
        ), mock.patch.object(ap, "run_asset_manifest") as manifest:
            code, result, err = self.publish_raw("--upload")

        self.assertEqual(code, 1, err)
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["stage"], "upload")
        self.assertFalse(result["uploaded"])
        manifest.assert_not_called()
        self.assertEqual(len(self.archives()), 1)
        archive = Path(result["archive"])
        self.assertTrue(archive.is_file())
        state = json.loads((self.data / ".asset-publish-state.json").read_text())
        self.assertFalse(state["assets"]["gameinfo"]["uploaded"])

        working = FakeFTP()
        with self.ftp_env(), mock.patch.object(
            ap, "FTP", lambda: working
        ), mock.patch.object(ap, "run_asset_manifest") as manifest:
            _, second = self.publish("--upload")

        self.assertEqual(second["status"], "uploaded")
        self.assertFalse(second["created"])
        self.assertEqual(second["archive"], str(archive))
        self.assertEqual(len(self.archives()), 1)
        manifest.assert_called_once_with()

    def test_size_mismatch_reports_but_keeps_remote_file(self) -> None:
        fake = FakeFTP(size_delta=1)
        with self.ftp_env(), mock.patch.object(
            ap, "FTP", lambda: fake
        ), mock.patch.object(ap, "run_asset_manifest") as manifest:
            code, result, err = self.publish_raw("--upload")

        self.assertEqual(code, 1)
        self.assertEqual(result["stage"], "upload")
        self.assertIn("size mismatch", result["error"])
        manifest.assert_not_called()
        archive = Path(result["archive"])
        self.assertEqual(
            fake.files, {archive.name: archive.stat().st_size + 1}
        )
        self.assertFalse(any(call[0] == "delete" for call in fake.calls))
        state = json.loads((self.data / ".asset-publish-state.json").read_text())
        self.assertFalse(state["assets"]["gameinfo"]["uploaded"])

        with self.ftp_env(), mock.patch.object(
            ap, "FTP", lambda: FakeFTP()
        ), mock.patch.object(ap, "run_asset_manifest"):
            _, retried = self.publish("--upload")

        self.assertEqual(retried["status"], "uploaded")
        self.assertFalse(retried["created"])
        self.assertEqual(len(self.archives()), 1)

    def test_manifest_failure_is_retried_without_repacking(self) -> None:
        fake = FakeFTP()
        with self.ftp_env(), mock.patch.object(
            ap, "FTP", lambda: fake
        ), mock.patch.object(
            ap,
            "run_asset_manifest",
            side_effect=ap.PublishError("gh failed"),
        ):
            code, result, err = self.publish_raw("--upload")

        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["stage"], "manifest")
        self.assertTrue(result["uploaded"])
        self.assertIn("gh failed", result["error"])
        self.assertEqual(len(self.archives()), 1)
        state = json.loads((self.data / ".asset-publish-state.json").read_text())
        entry = state["assets"]["gameinfo"]
        self.assertTrue(entry["uploaded"])
        self.assertTrue(entry["manifest_dirty"])

        with self.ftp_env(), mock.patch.object(
            ap, "FTP", lambda: FakeFTP()
        ), mock.patch.object(ap, "run_asset_manifest") as manifest:
            _, second = self.publish("--upload")

        self.assertEqual(second["status"], "uploaded")
        self.assertFalse(second["created"])
        self.assertEqual(len(self.archives()), 1)
        manifest.assert_called_once_with()
        state = json.loads((self.data / ".asset-publish-state.json").read_text())
        self.assertFalse(state["assets"]["gameinfo"]["manifest_dirty"])

    def test_local_only_never_touches_ftp_or_manifest(self) -> None:
        def explode():
            raise AssertionError("FTP must not be used without --upload")

        with mock.patch.object(ap, "FTP", explode), mock.patch.object(
            ap, "run_asset_manifest"
        ) as manifest:
            _, result = self.publish()

        self.assertEqual(result["status"], "created")
        self.assertFalse(result["uploaded"])
        manifest.assert_not_called()

    def test_dry_run_upload_connects_nowhere(self) -> None:
        def explode():
            raise AssertionError("dry run must not connect")

        with self.ftp_env(), mock.patch.object(
            ap, "FTP", explode
        ), mock.patch.object(ap, "run_asset_manifest") as manifest:
            _, result = self.publish("--upload", "--dry-run")

        self.assertEqual(result["status"], "would-create-upload")
        self.assertEqual(self.archives(), [])
        self.assertFalse((self.data / ".asset-publish-state.json").exists())
        manifest.assert_not_called()

    def test_dry_run_upload_reports_existing_unuploaded_archive(self) -> None:
        self.publish()
        with self.ftp_env():
            _, result = self.publish("--upload", "--dry-run")
        self.assertEqual(result["status"], "would-upload")


if __name__ == "__main__":
    unittest.main()
