# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/catalog-pipeline/jobs.py."""

from __future__ import annotations

import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import jobs


def wait_for(predicate, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def script_factory(code: str):
    def factory(mode: str, options: dict) -> list[str]:
        return [sys.executable, "-u", "-c", code]

    return factory


class JobManagerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.state = Path(self.temp.name) / "state"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def manager(self, code: str) -> jobs.JobManager:
        return jobs.JobManager(
            state_dir=self.state,
            repo_root=Path(self.temp.name),
            command_factory=script_factory(code),
        )

    def test_start_finishes_and_parses_stage(self) -> None:
        manager = self.manager(
            "print('==> archive-sync', flush=True)\n"
            "print('hello', flush=True)\n"
        )
        started = manager.start("full")
        self.assertEqual(started["status"], "running")
        self.assertTrue(wait_for(lambda: manager.current() is None))
        job = manager.get_job(started["id"])
        self.assertEqual(job["status"], "ok")
        self.assertEqual(job["stage"], "archive-sync")
        self.assertEqual(job["exit_code"], 0)
        self.assertFalse((self.state / "pipeline.lock").exists())
        log = manager.log_tail(started["id"])
        self.assertIn("hello", "\n".join(log["lines"]))

    def test_second_start_is_busy(self) -> None:
        manager = self.manager("import time; time.sleep(30)\n")
        started = manager.start("full")
        with self.assertRaises(jobs.BusyError):
            manager.start("full")
        manager.cancel()
        self.assertTrue(wait_for(lambda: manager.current() is None))
        self.assertEqual(manager.get_job(started["id"])["status"], "cancelled")
        self.assertFalse((self.state / "pipeline.lock").exists())

    def test_cancel_requests_and_marks_job(self) -> None:
        manager = self.manager(
            "print('==> archive-sync', flush=True)\n"
            "import time; time.sleep(30)\n"
        )
        started = manager.start("full")
        self.assertTrue(wait_for(lambda: (manager.current() or {}).get("stage") == "archive-sync"))
        manager.cancel(started["id"])
        self.assertTrue(wait_for(lambda: manager.current() is None, timeout=8))
        job = manager.get_job(started["id"])
        self.assertEqual(job["status"], "cancelled")
        self.assertFalse((self.state / "pipeline.lock").exists())

    def test_external_catalog_lock_is_busy(self) -> None:
        catalog_dir = self.state / "catalog-update"
        catalog_dir.mkdir(parents=True)
        (catalog_dir / "run.lock").write_text(f"{__import__('os').getpid()} now\n")
        manager = self.manager("print('done')\n")
        with self.assertRaises(jobs.BusyError):
            manager.start("full")

    def test_reconcile_marks_dead_running_job_interrupted(self) -> None:
        jobs_dir = self.state / "jobs" / "20260101T000000Z-dead"
        jobs_dir.mkdir(parents=True)
        (jobs_dir / "job.json").write_text(
            json.dumps(
                {
                    "id": jobs_dir.name,
                    "status": "running",
                    "stage": "archive-sync",
                    "pid": 999999,
                    "started_epoch": time.time(),
                }
            ),
            encoding="utf-8",
        )
        (self.state / "pipeline.lock").write_text(
            json.dumps({"pid": 999999, "job_id": jobs_dir.name}),
            encoding="utf-8",
        )

        manager = self.manager("print('done')\n")
        job = manager.get_job(jobs_dir.name)
        self.assertEqual(job["status"], "interrupted")
        self.assertFalse((self.state / "pipeline.lock").exists())

    def test_notification_is_sent_for_a_finished_report(self) -> None:
        report = self.state / "catalog-update" / "runs" / "20260101T000000Z.json"
        report.parent.mkdir(parents=True)
        code = (
            "import json, pathlib; "
            f"pathlib.Path({str(report)!r}).write_text("
            "json.dumps({'sync': {'counts': {'new': 1, 'changed': 0}}}), "
            "encoding='utf-8')"
        )
        manager = self.manager(code)
        with mock.patch.object(
            jobs.notify, "notify_sync_changes", return_value="e-mail sent"
        ) as notify:
            started = manager.start("full")
            self.assertTrue(wait_for(lambda: manager.current() is None))
            self.assertTrue(
                wait_for(
                    lambda: "notification: e-mail sent"
                    in "\n".join(manager.log_tail(started["id"])["lines"])
                )
            )
        notify.assert_called_once()

    def test_default_screenshot_command(self) -> None:
        manager = jobs.JobManager(
            state_dir=self.state, repo_root=Path.cwd()
        )
        argv = manager._default_command("screenshots", {})
        self.assertIn("asset-publish", " ".join(argv))
        self.assertIn("asset_publish.py", " ".join(argv))
        self.assertEqual(argv[-4:], ["--only", "screenshots", "--upload", "--json"])

    def test_jobs_are_listed_newest_first(self) -> None:
        manager = self.manager("print('done')\n")
        first = manager.start("full")
        self.assertTrue(wait_for(lambda: manager.current() is None))
        second = manager.start("dry-run")
        self.assertTrue(wait_for(lambda: manager.current() is None))
        listed = manager.list_jobs(10)
        self.assertEqual(
            {job["id"] for job in listed[:2]}, {first["id"], second["id"]}
        )


if __name__ == "__main__":
    unittest.main()
