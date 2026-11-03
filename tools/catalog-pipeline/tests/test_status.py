# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/catalog-pipeline (stdlib unittest)."""

from __future__ import annotations

import gzip
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import status as st

CRACKED = "Title Sorted/Cracked Games - Title Sorted"


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


def write_gzip_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(path, "wt", encoding="utf-8") as handle:
        json.dump(data, handle)


class StatusCollectorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def make_env(self) -> tuple[dict, dict]:
        paths = {
            "root": self.base / "root",
            "patch": self.base / "patch",
            "out": self.base / "out",
            "data": self.base / "data",
            "state": self.base / "state",
        }
        for path in paths.values():
            path.mkdir(parents=True, exist_ok=True)
        env = {
            "MARCER_ROOT_DIR": str(paths["root"]),
            "MARCER_PATCH_DIR": str(paths["patch"]),
            "MARCER_OUT_DIR": str(paths["out"]),
            "MARCER_DATA_DIR": str(paths["data"]),
            "MARCER_STATE_DIR": str(paths["state"]),
            "MARCER_FTP_HOST": "ftp.example",
            "MARCER_FTP_USER": "tester",
            "MARCER_FTP_PASS": "do-not-expose",
            "MARCER_GITHUB_TOKEN": "token-do-not-expose",
        }
        return env, paths

    def test_missing_configuration_is_safe(self) -> None:
        collector = st.StatusCollector(environ={}, repo_root=self.repo)
        result = collector.collect()
        self.assertEqual(result["mode"], "read-only")
        self.assertEqual(
            result["config"]["missing"],
            [
                "MARCER_ROOT_DIR",
                "MARCER_PATCH_DIR",
                "MARCER_OUT_DIR",
                "MARCER_DATA_DIR",
            ],
        )
        self.assertFalse(result["sync"]["present"])
        self.assertFalse(result["screenshots"]["present"])
        self.assertEqual(result["publish"]["gameinfo"]["status"], "missing")
        self.assertEqual(result["publish"]["screenshots"]["status"], "missing")
        self.assertEqual(collector.runs(), [])
        self.assertEqual(collector.health()["status"], "degraded")

    def test_collects_all_status_sources(self) -> None:
        env, paths = self.make_env()
        sync_dir = paths["state"] / "archive-sync"
        write_json(
            sync_dir / "changes.json",
            {
                "generated_at": "2026-11-03T18:00:00Z",
                "mode": "sync",
                "counts": {
                    "remote_files": 10,
                    "new": 2,
                    "changed": 1,
                    "in_sync": 7,
                    "local_only": 3,
                    "download_errors": 1,
                    "incomplete_dirs": 1,
                },
                "incomplete_dirs": ["Title Sorted/Broken"],
            },
        )

        gameinfo = paths["data"] / "gameinfo"
        write_json(
            gameinfo / "manifest.json",
            {
                "generated_at": "2026-11-03T19:00:00Z",
                "generator": "tools/gameinfo-gen",
                "generator_version": "1.0.0",
                "sources": [
                    {
                        "kind": "cracked",
                        "source": "Games.xls",
                        "matched_folders": 42,
                        "mtime": "2026-11-03T10:00:00Z",
                    }
                ],
            },
        )
        write_json(gameinfo / "games-cracked.json", {"games": []})
        write_gzip_json(
            gameinfo / "full-index.json.gz",
            {
                "tool": "tools/full-index-gen",
                "counts": {"zips": 3, "members": 4, "errors": 0},
                "errors": [],
                "entries": {},
            },
        )
        write_json(
            gameinfo / "crews.json",
            {"generated_at": "2026-11-03T19:30:00Z", "groups": [{}, {}]},
        )

        archive = paths["data"] / "gameinfo-20260101-000000.zip"
        archive.write_bytes(b"zip")
        write_json(
            paths["state"] / "asset-publish" / "state.json",
            {
                "schema": 1,
                "assets": {
                    "gameinfo": {
                        "archive": archive.name,
                        "size": 3,
                        "files": 2,
                        "uploaded": True,
                        "manifest_dirty": False,
                        "updated_at": "2026-11-03T20:00:00Z",
                        "manifest_updated_at": "2026-11-03T20:01:00Z",
                    }
                },
            },
        )

        rel_done = f"{CRACKED}/A/Alpha/Alpha.zip"
        rel_pending = f"{CRACKED}/A/Beta/Beta.zip"
        rel_skipped = f"{CRACKED}/A/Gamma/Gamma 2.zip"
        write_json(
            paths["out"] / "index.json",
            {
                "version": 1,
                "entries": {
                    rel_done: {
                        "status": "done",
                        "preview": "Alpha.png",
                        "candidates": ["Alpha_c01.png"],
                    },
                    rel_pending: {"status": "pending", "preview": None},
                    rel_skipped: {"status": "skipped_disk_n", "preview": None},
                },
            },
        )
        mirror = paths["out"] / CRACKED / "A" / "Alpha"
        mirror.mkdir(parents=True)
        (mirror / "Alpha.png").write_bytes(b"png")
        (mirror / "Alpha_c01.png").write_bytes(b"candidate")
        write_json(
            paths["out"] / "index-pd.json",
            {
                "version": 1,
                "entries": {
                    f"Title Sorted/PD Games - Title Sorted/P/Pong/Pong.zip": {
                        "status": "done",
                        "preview": "Pong.png",
                        "candidates": [],
                    }
                },
            },
        )

        write_json(
            paths["state"] / "catalog-update" / "runs" / "20261103T200000Z.json",
            {
                "status": "ok",
                "started_at": "2026-11-03T20:00:00Z",
                "finished_at": "2026-11-03T20:02:00Z",
                "error": None,
                "actions": {"publish": "skipped"},
                "steps": [{"name": "archive-sync"}],
            },
        )

        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        result = collector.collect()

        self.assertEqual(result["config"]["missing"], [])
        self.assertTrue(result["config"]["ftp_configured"])
        self.assertTrue(result["config"]["github_configured"])
        self.assertTrue(result["sync"]["present"])
        self.assertEqual(result["sync"]["counts"]["new"], 2)
        self.assertEqual(result["sync"]["incomplete_dirs"], ["Title Sorted/Broken"])

        self.assertTrue(result["gameinfo"]["present"])
        self.assertEqual(result["gameinfo"]["sources"][0]["matched_folders"], 42)
        self.assertTrue(result["full_index"]["present"])
        self.assertEqual(result["full_index"]["counts"]["zips"], 3)
        self.assertTrue(result["crews"]["present"])
        self.assertEqual(result["crews"]["groups"], 2)

        self.assertEqual(result["publish"]["gameinfo"]["status"], "uploaded")
        self.assertTrue(result["publish"]["gameinfo"]["archive_exists"])
        self.assertEqual(result["publish"]["screenshots"]["status"], "missing")

        cracked = result["screenshots"]["scopes"]["cracked"]
        self.assertTrue(cracked["present"])
        self.assertEqual(cracked["total"], 3)
        self.assertEqual(cracked["counts"]["done"], 1)
        self.assertEqual(cracked["counts"]["pending"], 1)
        self.assertEqual(cracked["counts"]["skipped_disk_n"], 1)
        self.assertEqual(cracked["without_preview"], 1)
        self.assertGreater(cracked["bytes"], 0)
        self.assertEqual(result["screenshots"]["without_preview"], 1)
        self.assertIsNotNone(result["screenshots"]["index_age_hours"])

        self.assertTrue(result["pipeline"]["report_dir_present"])
        self.assertEqual(result["pipeline"]["last_run"]["status"], "ok")
        self.assertEqual(collector.runs(5)[0]["file"], "20261103T200000Z.json")

        serialized = json.dumps(result)
        self.assertNotIn("do-not-expose", serialized)
        self.assertNotIn("token-do-not-expose", serialized)

    def test_state_defaults_to_data_state_and_reads_legacy_publish_state(self) -> None:
        env, paths = self.make_env()
        env.pop("MARCER_STATE_DIR")
        state_root = paths["data"] / "state"
        write_json(
            state_root / "archive-sync" / "changes.json",
            {"generated_at": "2026-11-03T18:00:00Z", "counts": {"new": 1}},
        )
        write_json(
            state_root / "catalog-update" / "runs" / "20261103T180000Z.json",
            {
                "status": "ok",
                "started_at": "2026-11-03T18:00:00Z",
                "finished_at": "2026-11-03T18:01:00Z",
                "steps": [],
            },
        )
        write_json(
            paths["data"] / ".asset-publish-state.json",
            {"assets": {"gameinfo": {"archive": "gameinfo-x.zip", "uploaded": True}}},
        )

        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        result = collector.collect()
        self.assertEqual(result["config"]["state_source"], "data")
        self.assertTrue(result["sync"]["present"])
        self.assertEqual(
            result["pipeline"]["last_run"]["file"], "20261103T180000Z.json"
        )
        self.assertEqual(result["publish"]["gameinfo"]["status"], "uploaded")
        self.assertEqual(
            result["publish"]["file"]["name"], ".asset-publish-state.json"
        )

    def test_screenshot_run_active_flag(self) -> None:
        env, paths = self.make_env()
        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        self.assertFalse(
            collector.collect()["config"]["screenshot_run_active"]
        )
        (paths["out"] / "shotgen.lock").write_text("123", encoding="utf-8")
        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        self.assertTrue(
            collector.collect()["config"]["screenshot_run_active"]
        )

    def test_pipeline_token_required_flag(self) -> None:
        env, _ = self.make_env()
        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        self.assertFalse(collector.collect()["config"]["pipeline_token_required"])
        env["MARCER_PIPELINE_TOKEN"] = "secret"
        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        self.assertTrue(collector.collect()["config"]["pipeline_token_required"])

    def test_collects_scheduler_state(self) -> None:
        env, paths = self.make_env()
        write_json(
            paths["state"] / "scheduler.json",
            {
                "cron": "0 20 * * 4",
                "timezone": "Europe/Berlin",
                "catch_up_hours": 24,
                "next_run": "2026-11-05T19:00:00Z",
                "last_attempt": "2026-10-29T19:00:05Z",
                "last_started": "2026-10-29T19:00:05Z",
                "last_status": "started",
                "last_job_id": "20261029T190005Z-abc123",
                "last_error": None,
            },
        )
        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        scheduler = collector.collect()["scheduler"]
        self.assertTrue(scheduler["present"])
        self.assertEqual(scheduler["next_run"], "2026-11-05T19:00:00Z")
        self.assertEqual(scheduler["last_status"], "started")
        self.assertEqual(scheduler["cron"], "0 20 * * 4")

    def test_collects_current_and_recent_jobs(self) -> None:
        env, paths = self.make_env()
        job_id = "20261103T210000Z-abc123"
        write_json(
            paths["state"] / "jobs" / job_id / "job.json",
            {
                "id": job_id,
                "mode": "full",
                "status": "running",
                "stage": "archive-sync",
                "started_at": "2026-11-03T21:00:00Z",
            },
        )
        (paths["state"] / "pipeline.lock").write_text("{}\n", encoding="utf-8")

        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        jobs = collector.collect()["jobs"]
        self.assertEqual(jobs["current"]["id"], job_id)
        self.assertEqual(jobs["recent"][0]["stage"], "archive-sync")
        self.assertTrue(jobs["lock_present"])

    def test_malformed_json_does_not_raise(self) -> None:
        env, paths = self.make_env()
        (paths["state"] / "archive-sync").mkdir(parents=True)
        (paths["state"] / "archive-sync" / "changes.json").write_text(
            "{not json", encoding="utf-8"
        )
        (paths["out"] / "index.json").write_text("{broken", encoding="utf-8")

        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        result = collector.collect()
        self.assertFalse(result["sync"]["present"])
        self.assertIn("cannot read changes.json", result["sync"]["error"])
        self.assertFalse(result["screenshots"]["scopes"]["cracked"]["present"])
        self.assertIn(
            "cannot read index.json",
            result["screenshots"]["scopes"]["cracked"]["error"],
        )

    def test_runs_are_sorted_newest_first_and_limited(self) -> None:
        env, paths = self.make_env()
        runs_dir = paths["state"] / "catalog-update" / "runs"
        for stamp, status in (
            ("20260101T000000Z", "error"),
            ("20260102T000000Z", "ok"),
            ("20260103T000000Z", "ok"),
        ):
            write_json(
                runs_dir / f"{stamp}.json",
                {
                    "status": status,
                    "started_at": "2026-01-01T00:00:00Z",
                    "finished_at": "2026-01-01T00:01:00Z",
                    "steps": [],
                },
            )

        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        runs = collector.runs(2)
        self.assertEqual(
            [run["file"] for run in runs],
            ["20260103T000000Z.json", "20260102T000000Z.json"],
        )

    def test_publish_reports_pending_and_dirty(self) -> None:
        env, paths = self.make_env()
        state_file = paths["state"] / "asset-publish" / "state.json"
        write_json(
            state_file,
            {
                "assets": {
                    "gameinfo": {
                        "archive": "gameinfo-x.zip",
                        "uploaded": True,
                        "manifest_dirty": True,
                    }
                }
            },
        )
        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        self.assertEqual(
            collector.collect()["publish"]["gameinfo"]["status"], "dirty"
        )

        write_json(
            state_file,
            {"assets": {"gameinfo": {"archive": "gameinfo-x.zip", "uploaded": False}}},
        )
        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        self.assertEqual(
            collector.collect()["publish"]["gameinfo"]["status"], "pending"
        )

    def test_publish_reports_screenshots_asset(self) -> None:
        env, paths = self.make_env()
        archive = paths["out"] / "screenshots-20260101-000000.zip"
        archive.write_bytes(b"zip")
        write_json(
            paths["state"] / "asset-publish" / "state.json",
            {
                "assets": {
                    "screenshots": {
                        "archive": archive.name,
                        "uploaded": True,
                        "manifest_dirty": False,
                    }
                }
            },
        )
        collector = st.StatusCollector(environ=env, repo_root=self.repo)
        publish = collector.collect()["publish"]
        self.assertEqual(publish["gameinfo"]["status"], "missing")
        self.assertEqual(publish["screenshots"]["status"], "uploaded")
        self.assertTrue(publish["screenshots"]["archive_exists"])

    def test_output_file_rejects_traversal(self) -> None:
        self.assertIsNone(st._output_file(Path("/tmp/out"), "../escape.zip", "a.png"))
        self.assertIsNone(
            st._output_file(Path("/tmp/out"), f"{CRACKED}/A/a.zip", "../a.png")
        )
        self.assertIsNone(
            st._output_file(Path("/tmp/out"), f"{CRACKED}/A/a.zip", "/etc/passwd")
        )


if __name__ == "__main__":
    unittest.main()
