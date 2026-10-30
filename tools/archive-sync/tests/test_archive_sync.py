# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/archive-sync (stdlib unittest)."""

from __future__ import annotations

import calendar
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import archive_sync as a


def make_config(tmp: Path, **overrides) -> a.Config:
    values = {
        "root": None,
        "patch": tmp / "patch",
        "report_dir": tmp / "reports",
        "remote": "/GameDVD/",
        "host": "ftp.example",
        "port": 21,
        "user": "user",
        "password": "pass",
        "encoding": "utf-8",
        "timeout": 5,
        "retries": 0,
        "passive": True,
        "max_depth": 64,
        "workers": 1,
        "only": (),
        "excludes": a.DEFAULT_EXCLUDES,
        "force": False,
        "verbose": False,
        "report_limit": 0,
    }
    values.update(overrides)
    return a.Config(**values)


def remote(rel: str, size: int | None, mtime: str | None = None) -> a.RemoteFile:
    return a.RemoteFile(rel, "/GameDVD/" + rel, size, mtime)


def local(rel: str, size: int, layer: str = "PATCH", base: Path | None = None):
    path = (base or Path("/tmp")) / rel
    return a.LocalFile(rel, layer, size, path)


class FakeClient:
    def __init__(self, listings, contents=None, fail=()):
        self.listings = listings
        self.contents = contents or {}
        self.fail = set(fail)
        self.closed = False

    def list_dir(self, path):
        if path not in self.listings:
            raise OSError(f"no listing for {path}")
        return self.listings[path]

    def retr(self, remote_path, fileobj):
        if remote_path in self.fail:
            raise OSError("simulated failure")
        fileobj.write(self.contents[remote_path])

    def close(self):
        self.closed = True


class HelperTests(unittest.TestCase):
    def test_split_host_port(self):
        self.assertEqual(a.split_host_port("ftp.example"), ("ftp.example", 21))
        self.assertEqual(a.split_host_port("ftp.example:2121"), ("ftp.example", 2121))
        self.assertEqual(a.split_host_port("[::1]:2121"), ("::1", 2121))
        self.assertEqual(a.split_host_port("[::1]"), ("::1", 21))

    def test_normalize_remote(self):
        self.assertEqual(a.normalize_remote(None), "/GameDVD/")
        self.assertEqual(a.normalize_remote("GameDVD"), "/GameDVD/")
        self.assertEqual(a.normalize_remote("/"), "/")
        self.assertEqual(a.normalize_remote("/GameDVD"), "/GameDVD/")

    def test_normalize_rel_rejects_unsafe_paths(self):
        self.assertIsNone(a.normalize_rel("../evil"))
        self.assertIsNone(a.normalize_rel("/absolute"))
        self.assertIsNone(a.normalize_rel("a\\b"))
        self.assertIsNone(a.normalize_rel(""))
        self.assertIsNone(a.normalize_rel("NUL\x00byte"))
        self.assertEqual(a.normalize_rel("Title Sorted/A/Game.zip"),
                         "Title Sorted/A/Game.zip")

    def test_excludes_match_components_and_paths(self):
        patterns = a.DEFAULT_EXCLUDES + ("Bonus/Dupes/*",)
        self.assertTrue(a.matches_exclude("Title/@eaDir/x.zip", patterns))
        self.assertTrue(a.matches_exclude(".DS_Store", patterns))
        self.assertTrue(a.matches_exclude("Bonus/Dupes/a.zip", patterns))
        self.assertFalse(a.matches_exclude("Title Sorted/A/Game.zip", patterns))

    def test_only_prefixes(self):
        only = ("Title Sorted/A",)
        self.assertTrue(a.in_only("Title Sorted/A/Game.zip", only))
        self.assertFalse(a.in_only("Title Sorted/B/Game.zip", only))
        self.assertTrue(a.dir_may_match("Title Sorted", only))
        self.assertTrue(a.dir_may_match("Title Sorted/A", only))
        self.assertFalse(a.dir_may_match("Bonus", only))
        self.assertTrue(a.in_only("title sorted/a/Game.zip", only))

    def test_parse_remote_mtime(self):
        expected = calendar.timegm((2026, 10, 26, 12, 0, 0))
        self.assertEqual(a.parse_remote_mtime("20261026120000"), expected)
        self.assertEqual(a.parse_remote_mtime("20261026120000.500"),
                         expected + 0.5)
        self.assertIsNone(a.parse_remote_mtime("not-a-time"))
        self.assertIsNone(a.parse_remote_mtime(None))

    def test_safe_dest_stays_inside_patch(self):
        with tempfile.TemporaryDirectory() as tmp:
            patch = Path(tmp) / "patch"
            patch.mkdir()
            self.assertEqual(a.safe_dest(patch, "A/Game.zip"),
                             (patch / "A/Game.zip").resolve())
            with self.assertRaises(ValueError):
                a.safe_dest(patch, "../escape.zip")
            with self.assertRaises(ValueError):
                a.safe_dest(patch, "/etc/passwd")


class ScanRemoteTests(unittest.TestCase):
    def test_scan_excludes_and_reads_metadata(self):
        root = "/GameDVD/"
        listings = {
            root: [
                a.DirEntry("Title Sorted", root + "Title Sorted", "dir", None, None),
                a.DirEntry(".DS_Store", root + ".DS_Store", "file", 10, None),
            ],
            root + "Title Sorted": [
                a.DirEntry("A", root + "Title Sorted/A", "dir", None, None),
            ],
            root + "Title Sorted/A": [
                a.DirEntry(
                    "Game.zip",
                    root + "Title Sorted/A/Game.zip",
                    "file",
                    100,
                    "20261026120000",
                )
            ],
        }
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_config(Path(tmp))
            scan = a.scan_remote(FakeClient(listings), cfg)
        files, conflicts, warnings = scan.files, scan.case_conflicts, scan.warnings
        self.assertIn("Title Sorted/A/Game.zip", files)
        self.assertNotIn(".DS_Store", files)
        self.assertEqual(files["Title Sorted/A/Game.zip"].size, 100)
        self.assertEqual(conflicts, [])
        self.assertEqual(warnings, [])

    def test_only_limits_the_scan(self):
        root = "/GameDVD/"
        listings = {
            root: [
                a.DirEntry("A", root + "A", "dir", None, None),
                a.DirEntry("B", root + "B", "dir", None, None),
            ],
            root + "A": [
                a.DirEntry("one.zip", root + "A/one.zip", "file", 1, None)
            ],
            root + "B": [
                a.DirEntry("two.zip", root + "B/two.zip", "file", 2, None)
            ],
        }
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_config(Path(tmp), only=("A",))
            files = a.scan_remote(FakeClient(listings), cfg).files
        self.assertEqual(list(files), ["A/one.zip"])

    def test_max_depth_is_enforced(self):
        root = "/GameDVD/"
        listings = {
            root: [a.DirEntry("A", root + "A", "dir", None, None)],
            root + "A": [a.DirEntry("B", root + "A/B", "dir", None, None)],
            root + "A/B": [
                a.DirEntry("deep.zip", root + "A/B/deep.zip", "file", 1, None)
            ],
        }
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_config(Path(tmp), max_depth=1)
            scan = a.scan_remote(FakeClient(listings), cfg)
        files, warnings = scan.files, scan.warnings
        self.assertEqual(files, {})
        self.assertTrue(any("max depth" in item for item in warnings))

    def test_case_conflict_is_reported(self):
        root = "/GameDVD/"
        listings = {
            root: [
                a.DirEntry("Game.zip", root + "Game.zip", "file", 10, None),
                a.DirEntry("game.zip", root + "game.zip", "file", 20, None),
            ]
        }
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_config(Path(tmp))
            scan = a.scan_remote(FakeClient(listings), cfg)
        files, conflicts = scan.files, scan.case_conflicts
        self.assertEqual(len(files), 1)
        self.assertEqual(len(conflicts), 1)

    def test_parallel_scan_matches_sequential_result(self):
        root = "/GameDVD/"
        listings = {
            root: [a.DirEntry("A", root + "A", "dir", None, None)],
            root + "A": [
                a.DirEntry("one.zip", root + "A/one.zip", "file", 1, None),
                a.DirEntry("two.zip", root + "A/two.zip", "file", 2, None),
            ],
        }
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_config(Path(tmp), workers=2)
            with mock.patch.object(a, "FtpClient", lambda _cfg: FakeClient(listings)):
                scan = a.scan_remote(None, cfg)
        self.assertEqual(sorted(scan.files), ["A/one.zip", "A/two.zip"])
        self.assertEqual(scan.incomplete, [])

    def test_incomplete_directory_is_reported(self):
        root = "/GameDVD/"
        listings = {
            root: [a.DirEntry("A", root + "A", "dir", None, None)],
        }
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_config(Path(tmp))
            scan = a.scan_remote(FakeClient(listings), cfg)
        self.assertEqual(scan.incomplete, ["A"])

    def test_unsafe_and_non_file_entries_are_skipped(self):
        root = "/GameDVD/"
        listings = {
            root: [
                a.DirEntry("../evil.zip", root + "../evil.zip", "file", 1, None),
                a.DirEntry("link", root + "link", "skip", None, None),
            ]
        }
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_config(Path(tmp))
            scan = a.scan_remote(FakeClient(listings), cfg)
        files, warnings = scan.files, scan.warnings
        self.assertEqual(files, {})
        self.assertTrue(any("unsafe remote name" in item for item in warnings))
        self.assertTrue(any("non-file" in item for item in warnings))


class ScanLocalTests(unittest.TestCase):
    def test_patch_wins_over_root_case_insensitively(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "root"
            patch = tmp_path / "patch"
            (root / "A").mkdir(parents=True)
            (patch / "a").mkdir(parents=True)
            (root / "A" / "Game.zip").write_bytes(b"root")
            (patch / "a" / "game.zip").write_bytes(b"patch!")
            cfg = make_config(tmp_path, root=root, patch=patch)
            index, conflicts, warnings = a.scan_local(cfg)
        item = index["a/game.zip"]
        self.assertEqual(item.layer, "PATCH")
        self.assertEqual(item.size, 6)
        self.assertEqual(conflicts, [])
        self.assertEqual(warnings, [])

    def test_same_layer_case_conflict_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "root"
            patch = tmp_path / "patch"
            (patch / "A").mkdir(parents=True)
            (patch / "A" / "Game.zip").write_bytes(b"one")
            (patch / "A" / "game.zip").write_bytes(b"two!")
            cfg = make_config(tmp_path, root=root, patch=patch)
            index, conflicts, _ = a.scan_local(cfg)
        self.assertEqual(len(index), 1)
        self.assertEqual(len(conflicts), 1)

    def test_missing_layer_is_a_warning(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_config(Path(tmp), root=Path(tmp) / "missing")
            index, _, warnings = a.scan_local(cfg)
        self.assertEqual(index, {})
        self.assertTrue(any("root directory not found" in item for item in warnings))

    def test_local_scan_respects_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            patch = tmp_path / "patch"
            (patch / "A").mkdir(parents=True)
            (patch / "B").mkdir(parents=True)
            (patch / "A" / "one.zip").write_bytes(b"1")
            (patch / "B" / "two.zip").write_bytes(b"2")
            cfg = make_config(tmp_path, patch=patch, only=("A",))
            index, _, _ = a.scan_local(cfg)
        self.assertEqual(list(index), ["a/one.zip"])


class BuildPlanTests(unittest.TestCase):
    def plan(self, tmp, remote_files, local_files, incomplete=(), **overrides):
        cfg = make_config(tmp, **overrides)
        return a.build_plan(
            remote_files, local_files, cfg, [], [], [], incomplete=incomplete
        )

    def test_missing_local_is_new_and_downloaded(self):
        with tempfile.TemporaryDirectory() as tmp:
            item = remote("A/Game.zip", 10)
            plan = self.plan(Path(tmp), {item.rel: item}, {})
        self.assertEqual(plan.new, [item])
        self.assertEqual(plan.changed, [])
        self.assertEqual(plan.in_sync_count, 0)
        self.assertEqual(len(plan.downloads), 1)
        self.assertEqual(plan.downloads[0].reason, "missing")

    def test_same_size_is_in_sync(self):
        with tempfile.TemporaryDirectory() as tmp:
            item = remote("A/Game.zip", 10, "20261026120000")
            local_item = local("A/Game.zip", 10)
            plan = self.plan(
                Path(tmp), {item.rel: item}, {"a/game.zip": local_item}
            )
        self.assertEqual(plan.new, [])
        self.assertEqual(plan.changed, [])
        self.assertEqual(plan.in_sync_count, 1)
        self.assertEqual(plan.downloads, [])

    def test_size_mismatch_is_changed_and_downloaded(self):
        with tempfile.TemporaryDirectory() as tmp:
            item = remote("A/Game.zip", 20)
            local_item = local("A/Game.zip", 10)
            plan = self.plan(
                Path(tmp), {item.rel: item}, {"a/game.zip": local_item}
            )
        self.assertEqual(plan.changed, [item])
        self.assertEqual(plan.in_sync_count, 0)
        self.assertEqual(len(plan.downloads), 1)
        self.assertEqual(plan.downloads[0].reason, "size_mismatch")

    def test_unknown_size_is_downloaded(self):
        with tempfile.TemporaryDirectory() as tmp:
            item = remote("A/Game.zip", None)
            local_item = local("A/Game.zip", 10)
            plan = self.plan(
                Path(tmp), {item.rel: item}, {"a/game.zip": local_item}
            )
        self.assertEqual(plan.unknown_size, [item])
        self.assertEqual(len(plan.downloads), 1)
        self.assertEqual(plan.downloads[0].reason, "unknown_size")

    def test_force_downloads_even_when_in_sync(self):
        with tempfile.TemporaryDirectory() as tmp:
            item = remote("A/Game.zip", 10)
            local_item = local("A/Game.zip", 10)
            plan = self.plan(
                Path(tmp),
                {item.rel: item},
                {"a/game.zip": local_item},
                force=True,
            )
        self.assertEqual(plan.in_sync_count, 1)
        self.assertEqual(len(plan.downloads), 1)
        self.assertEqual(plan.downloads[0].reason, "forced")

    def test_destination_uses_local_case_variant(self):
        with tempfile.TemporaryDirectory() as tmp:
            item = remote("A/Game.zip", 20)
            local_item = local("A/game.zip", 10, layer="ROOT")
            plan = self.plan(
                Path(tmp), {item.rel: item}, {"a/game.zip": local_item}
            )
        self.assertEqual(plan.downloads[0].dest_rel, "A/game.zip")

    def test_local_only_respects_scope_and_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            local_files = {
                "a/keep.zip": local("A/keep.zip", 1),
                "a/skip/gone.zip": local("A/skip/gone.zip", 2),
                "b/out.zip": local("B/out.zip", 3),
            }
            plan = self.plan(
                Path(tmp),
                {},
                local_files,
                only=("A",),
                incomplete=("A/skip",),
            )
        self.assertEqual([item.rel for item in plan.local_only], ["A/keep.zip"])

    def test_local_only_ignores_case_insensitive_remote_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            item = remote("A/Game.zip", 10)
            local_item = local("a/game.zip", 10)
            plan = self.plan(
                Path(tmp), {item.rel: item}, {"a/game.zip": local_item}
            )
        self.assertEqual(plan.local_only, [])
        self.assertEqual(plan.in_sync_count, 1)


class ExecuteDownloadsTests(unittest.TestCase):
    def test_download_is_atomic_and_sets_mtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            item = remote("A/Game.zip", 5, "20261026120000")
            cfg = make_config(tmp_path)
            cfg.patch.mkdir()
            download = a.Download(item, "A/Game.zip", "missing", None)
            client = FakeClient({}, {item.remote_path: b"hello"})
            done, errors = a.execute_downloads(client, cfg, [download])
            dest = cfg.patch / "A" / "Game.zip"
            self.assertEqual(dest.read_bytes(), b"hello")
            self.assertFalse((cfg.patch / "A" / "Game.zip.part").exists())
            self.assertEqual(errors, [])
            self.assertEqual(len(done), 1)
            expected = calendar.timegm((2026, 10, 26, 12, 0, 0))
            self.assertAlmostEqual(int(dest.stat().st_mtime), expected, delta=1)

    def test_failure_keeps_existing_file_and_removes_part(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            item = remote("A/Game.zip", 5)
            cfg = make_config(tmp_path)
            dest = cfg.patch / "A" / "Game.zip"
            dest.parent.mkdir(parents=True)
            dest.write_bytes(b"old")
            download = a.Download(item, "A/Game.zip", "size_mismatch", None)
            client = FakeClient({}, {item.remote_path: b"hello"}, fail={item.remote_path})
            with contextlib.redirect_stderr(io.StringIO()):
                done, errors = a.execute_downloads(client, cfg, [download])
            self.assertEqual(done, [])
            self.assertEqual(len(errors), 1)
            self.assertEqual(dest.read_bytes(), b"old")
            self.assertFalse((dest.parent / "Game.zip.part").exists())

    def test_wrong_size_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            item = remote("A/Game.zip", 99)
            cfg = make_config(tmp_path)
            cfg.patch.mkdir()
            download = a.Download(item, "A/Game.zip", "missing", None)
            client = FakeClient({}, {item.remote_path: b"hello"})
            with contextlib.redirect_stderr(io.StringIO()):
                done, errors = a.execute_downloads(client, cfg, [download])
            self.assertEqual(done, [])
            self.assertEqual(len(errors), 1)
            self.assertFalse((cfg.patch / "A" / "Game.zip").exists())


class RunSyncTests(unittest.TestCase):
    def test_sync_writes_reports_without_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            cfg = make_config(tmp_path)
            scan = a.RemoteScan({}, [], [], [])
            with (
                mock.patch.object(a, "FtpClient", lambda _cfg: FakeClient({})),
                mock.patch.object(a, "scan_remote", return_value=scan),
                mock.patch.object(a, "scan_local", return_value=({}, [], [])),
                mock.patch.object(a, "execute_downloads", return_value=([], [])),
            ):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(a.run_sync(cfg, dry_run=False), 0)
            self.assertTrue((cfg.report_dir / "changes.json").is_file())
            self.assertTrue((cfg.report_dir / "changes.txt").is_file())
            self.assertFalse((cfg.report_dir / "state.json").exists())
            report = json.loads((cfg.report_dir / "changes.json").read_text())
        self.assertEqual(report["counts"]["in_sync"], 0)

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_config(Path(tmp))
            scan = a.RemoteScan({}, [], [], [])
            with (
                mock.patch.object(a, "FtpClient", lambda _cfg: FakeClient({})),
                mock.patch.object(a, "scan_remote", return_value=scan),
                mock.patch.object(a, "scan_local", return_value=({}, [], [])),
            ):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(a.run_sync(cfg, dry_run=True), 0)
            self.assertFalse(cfg.report_dir.exists())
            self.assertFalse(cfg.patch.exists())


class ReportTests(unittest.TestCase):
    def test_report_renders_sections_and_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_config(Path(tmp), report_limit=1)
            item = remote("A/Game.zip", 10)
            plan = a.build_plan(
                {item.rel: item},
                {},
                cfg,
                ["case conflict"],
                [],
                ["warning"],
            )
            report = a.build_report(cfg, plan, [], [], 0.1, "sync")
            text = a.render_report(report, limit=1)
            self.assertIn("--- New (missing locally) (1)", text)
            self.assertIn("no persistent state is used", text)
            self.assertIn("case conflict", text)
            json.dumps(report)

    def test_report_limit_marks_truncation(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_config(Path(tmp))
            remote_files = {
                f"A/{index}.zip": remote(f"A/{index}.zip", index)
                for index in range(3)
            }
            plan = a.build_plan(remote_files, {}, cfg, [], [], [])
            report = a.build_report(cfg, plan, [], [], 0.1, "sync")
            text = a.render_report(report, limit=1)
        self.assertIn("--- New (missing locally) (3)", text)
        self.assertIn("... 2 more", text)

    def test_status_without_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = SimpleNamespace(report_dir=str(Path(tmp) / "report"), json=True)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(a.cmd_status(args), 0)

    def test_status_reads_last_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            report_dir = Path(tmp) / "report"
            report_dir.mkdir()
            (report_dir / "changes.json").write_text(
                json.dumps(
                    {
                        "generated_at": "2026-10-26T12:00:00Z",
                        "mode": "sync",
                        "counts": {
                            "remote_files": 3,
                            "new": 1,
                            "changed": 0,
                            "in_sync": 2,
                            "local_only": 0,
                            "downloads": 1,
                            "download_errors": 0,
                            "incomplete_dirs": 0,
                        },
                        "incomplete_dirs": [],
                    }
                ),
                encoding="utf-8",
            )
            args = SimpleNamespace(report_dir=str(report_dir), json=True)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(a.cmd_status(args), 0)
            summary = json.loads(output.getvalue())
        self.assertEqual(summary["mode"], "sync")
        self.assertEqual(summary["counts"]["in_sync"], 2)
        self.assertNotIn("state", summary)

    def test_report_covers_changed_and_local_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_config(Path(tmp))
            item = remote("A/Game.zip", 20)
            local_item = local("A/Game.zip", 10)
            extra = local("B/extra.zip", 5)
            plan = a.build_plan(
                {item.rel: item},
                {"a/game.zip": local_item, "b/extra.zip": extra},
                cfg,
                [],
                [],
                [],
            )
            report = a.build_report(cfg, plan, [], [], 0.1, "sync")
            text = a.render_report(report)
        self.assertEqual(report["counts"]["changed"], 1)
        self.assertEqual(report["counts"]["local_only"], 1)
        self.assertEqual(report["counts"]["in_sync"], 0)
        self.assertIn("Changed (size differs)", text)
        self.assertIn("Local only (not on remote; kept)", text)


class ConfigTests(unittest.TestCase):
    def test_env_defaults_and_overrides(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env = {
                "MARCER_ROOT_DIR": str(tmp_path / "root"),
                "MARCER_PATCH_DIR": str(tmp_path / "patch"),
                "MARCER_FTP_HOST": "ftp.example:2121",
                "MARCER_FTP_USER": "user",
                "MARCER_FTP_PASS": "pass",
                "MARCER_FTP_REMOTE": "/GameDVD",
                "MARCER_FTP_ENCODING": "latin-1",
                "MARCER_SYNC_EXCLUDES": "skipme,*.bak",
                "MARCER_SYNC_ONLY": "/Title Sorted/A,/Bonus",
                "MARCER_SYNC_RETRIES": "1",
                "MARCER_SYNC_WORKERS": "2",
                "MARCER_SYNC_REPORT_DIR": str(tmp_path / "report"),
            }
            parser = a.build_parser()
            args = parser.parse_args(["plan"])
            with mock.patch.dict(os.environ, env, clear=False):
                cfg = a.build_config(args)
        self.assertEqual(cfg.root, tmp_path / "root")
        self.assertEqual(cfg.patch, tmp_path / "patch")
        self.assertEqual(cfg.report_dir, tmp_path / "report")
        self.assertEqual(cfg.host, "ftp.example")
        self.assertEqual(cfg.port, 2121)
        self.assertEqual(cfg.remote, "/GameDVD/")
        self.assertEqual(cfg.encoding, "latin-1")
        self.assertEqual(cfg.only, ("Title Sorted/A", "Bonus"))
        self.assertIn("skipme", cfg.excludes)
        self.assertIn("*.bak", cfg.excludes)
        self.assertEqual(cfg.retries, 1)
        self.assertEqual(cfg.workers, 2)

    def test_default_encoding_is_utf8(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env = {
                "MARCER_PATCH_DIR": str(tmp_path / "patch"),
                "MARCER_FTP_HOST": "ftp.example:2121",
            }
            parser = a.build_parser()
            args = parser.parse_args(["plan"])
            with mock.patch.dict(os.environ, env, clear=True):
                cfg = a.build_config(args)
        self.assertEqual(cfg.encoding, "utf-8")

    def test_missing_patch_or_host_is_a_config_error(self):
        parser = a.build_parser()
        args = parser.parse_args(["plan"])
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(a.ConfigError):
                a.build_config(args)
            with mock.patch.dict(os.environ, {"MARCER_PATCH_DIR": "/tmp/p"}, clear=True):
                with self.assertRaises(a.ConfigError):
                    a.build_config(args)


if __name__ == "__main__":
    unittest.main()
