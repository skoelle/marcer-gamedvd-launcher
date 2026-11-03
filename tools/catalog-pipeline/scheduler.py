#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Weekly catalog scheduler.

Runs inside the pipeline service and starts a full catalog-update job using the
existing JobManager. The schedule is a five-field cron expression in a
configurable IANA timezone. Missed runs are either caught up within a bounded
window or skipped, depending on ``MARCER_SCHEDULE_CATCH_UP_HOURS``.
"""
from __future__ import annotations

import json
import os
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from jobs import BusyError, JobError

DEFAULT_CRON = "0 20 * * 4"
DEFAULT_TIMEZONE = "Europe/Berlin"
DEFAULT_CATCH_UP_HOURS = 24
DEFAULT_POLL_SECONDS = 20
MAX_LOOKAHEAD_DAYS = 370


class SchedulerError(Exception):
    """Invalid scheduler configuration."""


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def iso_now(now: datetime | None = None) -> str:
    value = now or datetime.now(timezone.utc)
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _parse_field(value: str, minimum: int, maximum: int) -> set[int]:
    value = value.strip()
    if not value:
        raise SchedulerError("empty cron field")
    result: set[int] = set()
    for part in value.split(","):
        part = part.strip()
        if not part:
            raise SchedulerError(f"invalid cron field: {value!r}")
        step = 1
        if "/" in part:
            base, step_text = part.split("/", 1)
            try:
                step = int(step_text)
            except ValueError as exc:
                raise SchedulerError(f"invalid cron step: {part!r}") from exc
            if step <= 0:
                raise SchedulerError(f"invalid cron step: {part!r}")
        else:
            base = part
        if base == "*":
            start, end = minimum, maximum
        elif "-" in base:
            start_text, end_text = base.split("-", 1)
            try:
                start, end = int(start_text), int(end_text)
            except ValueError as exc:
                raise SchedulerError(f"invalid cron range: {part!r}") from exc
        else:
            try:
                start = end = int(base)
            except ValueError as exc:
                raise SchedulerError(f"invalid cron value: {part!r}") from exc
        if start > end:
            raise SchedulerError(f"invalid cron range: {part!r}")
        for number in range(start, end + 1, step):
            if number < minimum or number > maximum:
                raise SchedulerError(f"cron value out of range: {part!r}")
            result.add(number)
    if not result:
        raise SchedulerError(f"empty cron field: {value!r}")
    return result


def parse_cron(expression: str) -> dict:
    fields = expression.split()
    if len(fields) != 5:
        raise SchedulerError(
            "cron expression must have five fields: minute hour day month weekday"
        )
    minute, hour, day, month, weekday = fields
    weekdays = _parse_field(weekday, 0, 7)
    if 7 in weekdays:
        weekdays.discard(7)
        weekdays.add(0)
    return {
        "minutes": _parse_field(minute, 0, 59),
        "hours": _parse_field(hour, 0, 23),
        "days": _parse_field(day, 1, 31),
        "months": _parse_field(month, 1, 12),
        "weekdays": weekdays,
        "day_restricted": day != "*",
        "weekday_restricted": weekday != "*",
    }


def _cron_matches(value: datetime, fields: dict) -> bool:
    if value.minute not in fields["minutes"]:
        return False
    if value.hour not in fields["hours"]:
        return False
    if value.month not in fields["months"]:
        return False
    cron_weekday = (value.weekday() + 1) % 7
    day_match = value.day in fields["days"]
    weekday_match = cron_weekday in fields["weekdays"]
    if fields["day_restricted"] and fields["weekday_restricted"]:
        return day_match or weekday_match
    return day_match and weekday_match


def next_cron_run(after: datetime, fields: dict, tz: ZoneInfo) -> datetime:
    """Return the next matching local time strictly after ``after`` (UTC)."""
    local = after.astimezone(tz)
    start = local.replace(second=0, microsecond=0)
    if start <= local:
        start += timedelta(minutes=1)
    deadline = start + timedelta(days=MAX_LOOKAHEAD_DAYS)
    candidate = start
    while candidate <= deadline:
        if _cron_matches(candidate, fields):
            return candidate.astimezone(timezone.utc)
        candidate += timedelta(minutes=1)
    raise SchedulerError(
        f"cron expression does not match within {MAX_LOOKAHEAD_DAYS} days"
    )


def _atomic_write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.part")
    try:
        tmp.write_text(
            json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def _read_json(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


class Scheduler:
    def __init__(
        self,
        manager,
        state_dir: Path | None = None,
        cron: str | None = None,
        timezone_name: str | None = None,
        catch_up_hours: int | None = None,
        poll_seconds: float = DEFAULT_POLL_SECONDS,
        now_fn=None,
        log=None,
    ) -> None:
        self.manager = manager
        self.state_dir = (
            Path(state_dir)
            if state_dir is not None
            else Path(manager.state_dir)
        )
        self.state_path = self.state_dir / "scheduler.json"
        self.cron = cron or env("MARCER_SCHEDULE_CRON", DEFAULT_CRON)
        self.timezone_name = timezone_name or env(
            "MARCER_TZ", DEFAULT_TIMEZONE
        )
        if catch_up_hours is None:
            try:
                catch_up_hours = int(
                    env("MARCER_SCHEDULE_CATCH_UP_HOURS",
                        str(DEFAULT_CATCH_UP_HOURS))
                    or DEFAULT_CATCH_UP_HOURS
                )
            except ValueError:
                catch_up_hours = DEFAULT_CATCH_UP_HOURS
        self.catch_up_hours = max(0, int(catch_up_hours))
        self.poll_seconds = max(0.1, float(poll_seconds))
        self.now_fn = now_fn or (lambda: datetime.now(timezone.utc))
        self.log = log or (lambda message: print(message, flush=True))

        try:
            self.tz = ZoneInfo(self.timezone_name)
        except ZoneInfoNotFoundError as exc:
            raise SchedulerError(
                f"unknown timezone: {self.timezone_name}"
            ) from exc
        self.fields = parse_cron(self.cron)

        self._state: dict = {}
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._state = self._load_state()
        self._ensure_state()

    # -- public API --------------------------------------------------------

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._run, name="catalog-scheduler", daemon=True
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5)

    def status(self) -> dict:
        with self._lock:
            return dict(self._state)

    def tick(self, now: datetime | None = None) -> dict:
        current = self._now(now)
        with self._lock:
            self._ensure_state_locked(current)
            state = self._state
            next_run = parse_iso(state.get("next_run"))
            if next_run is None or current < next_run:
                return dict(state)

            lateness = max(0.0, (current - next_run).total_seconds())
            catch_up_seconds = self.catch_up_hours * 3600
            allowed = (
                lateness <= catch_up_seconds
                if catch_up_seconds > 0
                else lateness <= max(60.0, self.poll_seconds)
            )
            state["last_attempt"] = iso_now(current)
            state["updated_at"] = iso_now(current)
            if not allowed:
                state["last_status"] = "skipped"
                state["last_error"] = (
                    f"missed scheduled run by {int(lateness)} seconds"
                )
                state["next_run"] = iso_now(
                    next_cron_run(current, self.fields, self.tz)
                )
                self._write_state_locked()
                self.log(
                    f"[scheduler] skipped missed run "
                    f"({int(lateness)}s late)"
                )
                return dict(state)

            try:
                job = self.manager.start(
                    "full", {"source": "scheduler"}
                )
            except BusyError as exc:
                # Keep next_run unchanged so a later tick retries while the
                # catch-up window is still open.
                state["last_status"] = "busy"
                state["last_error"] = str(exc)
                self._write_state_locked()
                self.log(f"[scheduler] busy: {exc}")
                return dict(state)
            except (JobError, SchedulerError) as exc:
                state["last_status"] = "error"
                state["last_error"] = str(exc)
                state["next_run"] = iso_now(
                    next_cron_run(current, self.fields, self.tz)
                )
                self._write_state_locked()
                self.log(f"[scheduler] could not start job: {exc}")
                return dict(state)

            state["last_status"] = "started"
            state["last_started"] = iso_now(current)
            state["last_job_id"] = job.get("id")
            state["last_error"] = None
            state["next_run"] = iso_now(
                next_cron_run(current, self.fields, self.tz)
            )
            self._write_state_locked()
            self.log(
                f"[scheduler] started job {job.get('id')} "
                f"(next run {state['next_run']})"
            )
            return dict(state)

    # -- internals ---------------------------------------------------------

    def _now(self, now: datetime | None = None) -> datetime:
        value = now or self.now_fn()
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)

    def _load_state(self) -> dict:
        state = _read_json(self.state_path) or {}
        return state if isinstance(state, dict) else {}

    def _ensure_state(self) -> None:
        with self._lock:
            self._ensure_state_locked(self._now())

    def _ensure_state_locked(self, now: datetime) -> None:
        state = self._state
        config_changed = (
            state.get("cron") != self.cron
            or state.get("timezone") != self.timezone_name
            or state.get("catch_up_hours") != self.catch_up_hours
        )
        next_run = parse_iso(state.get("next_run"))
        if not config_changed and next_run is not None:
            return
        state.update(
            schema=1,
            cron=self.cron,
            timezone=self.timezone_name,
            catch_up_hours=self.catch_up_hours,
            updated_at=iso_now(now),
            next_run=iso_now(next_cron_run(now, self.fields, self.tz)),
            last_attempt=state.get("last_attempt"),
            last_started=state.get("last_started"),
            last_status=state.get("last_status"),
            last_job_id=state.get("last_job_id"),
            last_error=state.get("last_error"),
        )
        self._write_state_locked()

    def _write_state_locked(self) -> None:
        _atomic_write_json(self.state_path, self._state)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.tick()
            except Exception as exc:  # noqa: BLE001 - scheduler must not die
                self.log(f"[scheduler] tick failed: {exc!r}")
                if self._stop.wait(self.poll_seconds):
                    break
                continue
            if self._stop.wait(self.poll_seconds):
                break
