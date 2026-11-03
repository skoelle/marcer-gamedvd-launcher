# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/catalog-pipeline/scheduler.py."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import jobs
import scheduler as sched


class FakeManager:
    def __init__(self, state_dir: Path, behavior=None) -> None:
        self.state_dir = state_dir
        self.calls: list[tuple] = []
        self.behavior = list(behavior or [])

    def start(self, mode: str, options: dict) -> dict:
        self.calls.append((mode, options))
        if self.behavior:
            result = self.behavior.pop(0)
            if isinstance(result, Exception):
                raise result
            return result
        return {
            "id": f"job-{len(self.calls)}",
            "mode": mode,
            "source": options.get("source"),
        }


class CronTest(unittest.TestCase):
    def test_thursday_2000_berlin(self) -> None:
        tz = ZoneInfo("Europe/Berlin")
        fields = sched.parse_cron("0 20 * * 4")
        after = datetime(2026, 11, 5, 19, 1, tzinfo=timezone.utc)
        next_run = sched.next_cron_run(after, fields, tz)
        self.assertEqual(next_run.astimezone(tz).date().isoformat(), "2026-11-12")
        self.assertEqual(next_run.astimezone(tz).hour, 20)

    def test_dst_spring_forward(self) -> None:
        tz = ZoneInfo("Europe/Berlin")
        fields = sched.parse_cron("0 20 * * 4")
        after = datetime(2026, 3, 26, 19, 1, tzinfo=timezone.utc)
        next_run = sched.next_cron_run(after, fields, tz)
        local = next_run.astimezone(tz)
        self.assertEqual(local.date().isoformat(), "2026-04-02")
        self.assertEqual(local.hour, 20)
        self.assertEqual(local.utcoffset().total_seconds(), 7200)

    def test_dst_fall_back(self) -> None:
        tz = ZoneInfo("Europe/Berlin")
        fields = sched.parse_cron("0 20 * * 4")
        after = datetime(2026, 10, 22, 19, 1, tzinfo=timezone.utc)
        next_run = sched.next_cron_run(after, fields, tz)
        local = next_run.astimezone(tz)
        self.assertEqual(local.date().isoformat(), "2026-10-29")
        self.assertEqual(local.hour, 20)
        self.assertEqual(local.utcoffset().total_seconds(), 3600)

    def test_invalid_cron(self) -> None:
        with self.assertRaises(sched.SchedulerError):
            sched.parse_cron("0 20 * *")
        with self.assertRaises(sched.SchedulerError):
            sched.parse_cron("99 20 * * 4")


class SchedulerTest(unittest.TestCase):
    due = datetime(2026, 11, 5, 19, 0, tzinfo=timezone.utc)  # 20:00 Berlin
    before = datetime(2026, 11, 5, 18, 0, tzinfo=timezone.utc)

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.state = Path(self.temp.name) / "state"
        self.state.mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def scheduler(self, manager, **kwargs):
        return sched.Scheduler(
            manager,
            state_dir=self.state,
            cron="0 20 * * 4",
            timezone_name="Europe/Berlin",
            now_fn=lambda: self.before,
            log=lambda message: None,
            **kwargs,
        )

    def test_starts_at_due_time_and_not_twice(self) -> None:
        manager = FakeManager(self.state)
        scheduler = self.scheduler(manager)
        state = scheduler.tick(self.before)
        self.assertEqual(state["next_run"], "2026-11-05T19:00:00Z")
        self.assertEqual(manager.calls, [])

        state = scheduler.tick(self.due)
        self.assertEqual(len(manager.calls), 1)
        self.assertEqual(manager.calls[0], ("full", {"source": "scheduler"}))
        self.assertEqual(state["last_status"], "started")
        self.assertEqual(state["last_job_id"], "job-1")

        scheduler.tick(self.due)
        self.assertEqual(len(manager.calls), 1)

    def test_restart_does_not_rerun_scheduled_job(self) -> None:
        first = FakeManager(self.state)
        scheduler = self.scheduler(first)
        scheduler.tick(self.due)
        self.assertEqual(len(first.calls), 1)

        second = FakeManager(self.state)
        restarted = self.scheduler(second)
        restarted.tick(datetime(2026, 11, 5, 19, 30, tzinfo=timezone.utc))
        self.assertEqual(second.calls, [])

    def test_catch_up_within_window(self) -> None:
        manager = FakeManager(self.state)
        scheduler = self.scheduler(manager, catch_up_hours=24)
        scheduler.tick(self.due.replace(hour=20))  # one hour late
        self.assertEqual(len(manager.calls), 1)
        self.assertEqual(scheduler.status()["last_status"], "started")

    def test_missed_run_is_skipped_without_catch_up(self) -> None:
        manager = FakeManager(self.state)
        scheduler = self.scheduler(manager, catch_up_hours=0)
        state = scheduler.tick(self.due.replace(minute=2))
        self.assertEqual(manager.calls, [])
        self.assertEqual(state["last_status"], "skipped")
        self.assertNotEqual(state["next_run"], "2026-11-05T19:00:00Z")

    def test_busy_job_keeps_schedule_and_retries(self) -> None:
        manager = FakeManager(
            self.state,
            behavior=[jobs.BusyError("busy"), {"id": "job-retry"}],
        )
        scheduler = self.scheduler(manager)
        state = scheduler.tick(self.due)
        self.assertEqual(state["last_status"], "busy")
        self.assertEqual(len(manager.calls), 1)

        state = scheduler.tick(
            datetime(2026, 11, 5, 19, 0, 30, tzinfo=timezone.utc)
        )
        self.assertEqual(len(manager.calls), 2)
        self.assertEqual(state["last_status"], "started")
        self.assertEqual(state["last_job_id"], "job-retry")

    def test_state_file_contains_schedule(self) -> None:
        scheduler = self.scheduler(FakeManager(self.state))
        data = json.loads((self.state / "scheduler.json").read_text())
        self.assertEqual(data["cron"], "0 20 * * 4")
        self.assertEqual(data["timezone"], "Europe/Berlin")
        self.assertEqual(data["next_run"], "2026-11-05T19:00:00Z")
        self.assertEqual(scheduler.status()["next_run"], data["next_run"])


if __name__ == "__main__":
    unittest.main()
