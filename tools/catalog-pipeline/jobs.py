#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Small job runner for the catalog pipeline web service.

Runs ``tools/catalog-update`` as a child process, keeps a persistent job log
and job state under ``$MARCER_STATE_DIR/jobs`` and guards concurrent runs with
``$MARCER_STATE_DIR/pipeline.lock``. The runner is also used by the scheduler in
a later phase.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools"))

from _lib import pipeline_paths  # noqa: E402

import notify  # noqa: E402

TOOL_VERSION = "0.1.0"
JOB_SCHEMA = 1
JOB_RETENTION = 50
LOCK_STALE_SECONDS = 90
LOCK_HARD_STALE_SECONDS = 24 * 3600
CANCEL_GRACE_SECONDS = 10
HEARTBEAT_SECONDS = 5
STAGE_RE = re.compile(r"==>\s+(.+?)\s*$")
MODES = ("full", "dry-run")


class JobError(Exception):
    """Base error for the job runner."""


class BusyError(JobError):
    """Another job or an external catalog-update run is active."""


class NotFoundError(JobError):
    """The requested job does not exist or is not running."""


class InvalidJobError(JobError):
    """The requested mode or options are invalid."""


def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_from_epoch(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name != "nt":
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except (PermissionError, OSError):
            return True
        return True
    return True


def _is_catalog_process(pid: int) -> bool:
    """Best-effort guard so reconciliation never kills an unrelated PID."""
    if not _pid_alive(pid):
        return False
    cmdline = Path(f"/proc/{pid}/cmdline")
    if cmdline.is_file():
        try:
            command = cmdline.read_bytes().replace(b"\0", b" ").decode(
                "utf-8", "replace"
            )
        except OSError:
            return False
        return "catalog_update.py" in command
    return True


def _signal_pid(pid: int, sig: int) -> None:
    if pid <= 0 or not _pid_alive(pid):
        return
    try:
        if hasattr(os, "killpg"):
            os.killpg(os.getpgid(pid), sig)
        else:
            os.kill(pid, sig)
    except ProcessLookupError:
        pass
    except OSError:
        try:
            os.kill(pid, sig)
        except OSError:
            pass


def _read_json(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


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


class JobManager:
    def __init__(
        self,
        state_dir: Path | None = None,
        repo_root: Path | None = None,
        command_factory=None,
    ) -> None:
        self.repo_root = Path(repo_root) if repo_root else REPO_ROOT
        self.state_dir = (
            Path(state_dir)
            if state_dir is not None
            else pipeline_paths.state_root(self.repo_root)
        )
        self.jobs_dir = self.state_dir / "jobs"
        self.lock_path = self.state_dir / "pipeline.lock"
        self.catalog_report_dir = self.state_dir / "catalog-update"
        self.sync_report_dir = self.state_dir / "archive-sync"
        self.command_factory = command_factory or self._default_command

        self._mutex = threading.RLock()
        self._current: dict | None = None
        self._proc: subprocess.Popen | None = None
        self._reader: threading.Thread | None = None
        self._waiter: threading.Thread | None = None
        self._cancel_requested = False
        self._cancel_started = 0.0
        self._shutdown_requested = False

        self.jobs_dir.mkdir(parents=True, exist_ok=True)
        self.catalog_report_dir.mkdir(parents=True, exist_ok=True)
        self.sync_report_dir.mkdir(parents=True, exist_ok=True)
        self._reconcile()

    # -- public API --------------------------------------------------------

    def current(self) -> dict | None:
        with self._mutex:
            return dict(self._current) if self._current else None

    def start(self, mode: str = "full", options: dict | None = None) -> dict:
        options = options or {}
        if mode not in MODES:
            raise InvalidJobError(f"invalid mode: {mode}")
        only = self._string_list(options.get("only"), "only")
        exclude = self._string_list(options.get("exclude"), "exclude")
        skip_publish = bool(options.get("skip_publish"))
        no_crew = bool(options.get("no_crew"))
        source = str(options.get("source") or "manual")

        with self._mutex:
            if self._current and self._current.get("status") in (
                "running",
                "cancelling",
            ):
                raise BusyError("another catalog pipeline job is already running")
            if self._catalog_lock_active():
                raise BusyError("catalog-update is already running outside the service")

            job_id = self._new_job_id()
            job_dir = self.jobs_dir / job_id
            job_dir.mkdir(parents=True, exist_ok=True)
            log_path = job_dir / "job.log"
            job = {
                "schema": JOB_SCHEMA,
                "id": job_id,
                "mode": mode,
                "source": source,
                "status": "running",
                "stage": "starting",
                "started_at": iso_now(),
                "started_epoch": time.time(),
                "finished_at": "",
                "pid": 0,
                "exit_code": None,
                "error": None,
                "command": [],
                "report_file": None,
                "log_file": str(log_path),
                "heartbeat_epoch": time.time(),
            }
            _atomic_write_json(job_dir / "job.json", job)
            self._acquire_lock(job_id)

            job_options = {
                "only": only,
                "exclude": exclude,
                "skip_publish": skip_publish,
                "no_crew": no_crew,
            }
            log_handle = None
            try:
                argv = list(self.command_factory(mode, job_options))
                env = dict(os.environ)
                env["PYTHONUNBUFFERED"] = "1"
                env["PYTHONDONTWRITEBYTECODE"] = "1"
                log_handle = open(log_path, "w", encoding="utf-8")
                proc = subprocess.Popen(
                    argv,
                    cwd=str(self.repo_root),
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                    start_new_session=True,
                )
            except OSError as exc:
                if log_handle is not None:
                    log_handle.close()
                job.update(
                    status="error",
                    finished_at=iso_now(),
                    error={"stage": "start", "message": str(exc)},
                )
                _atomic_write_json(job_dir / "job.json", job)
                self._release_lock()
                raise JobError(f"cannot start catalog-update: {exc}") from exc

            job["pid"] = proc.pid
            job["command"] = argv
            job["heartbeat_epoch"] = time.time()
            _atomic_write_json(job_dir / "job.json", job)
            self._current = job
            self._proc = proc
            self._cancel_requested = False
            self._cancel_started = 0.0
            self._shutdown_requested = False
            self._reader = threading.Thread(
                target=self._read_output,
                args=(proc, log_handle, job_id),
                name=f"catalog-job-log-{job_id}",
                daemon=True,
            )
            self._waiter = threading.Thread(
                target=self._wait_job,
                args=(proc, job_id),
                name=f"catalog-job-wait-{job_id}",
                daemon=True,
            )
            self._reader.start()
            self._waiter.start()
            self._prune_jobs()
            return self._summary(job)

    def cancel(self, job_id: str | None = None) -> dict:
        with self._mutex:
            job = self._current
            if not job or job.get("status") not in ("running", "cancelling"):
                raise NotFoundError("no running job")
            if job_id and job_id != job.get("id"):
                raise NotFoundError(f"job not running: {job_id}")
            if not self._cancel_requested:
                self._cancel_requested = True
                self._cancel_started = time.monotonic()
                job["status"] = "cancelling"
                job["cancelling"] = True
                _atomic_write_json(self._job_file(job["id"]), job)
                self._signal_current(signal.SIGTERM)
            return self._summary(job)

    def list_jobs(self, limit: int = 10) -> list[dict]:
        jobs = []
        try:
            job_files = list(self.jobs_dir.glob("*/job.json"))
        except OSError:
            return []
        for path in job_files:
            job = _read_json(path)
            if job is not None:
                jobs.append(self._summary(job))
        jobs.sort(
            key=lambda job: (job.get("started_at") or "", job.get("id") or ""),
            reverse=True,
        )
        return jobs[: max(0, limit)]

    def get_job(self, job_id: str) -> dict:
        path = self._job_file(job_id)
        job = _read_json(path)
        if job is None:
            raise NotFoundError(f"job not found: {job_id}")
        return job

    def log_tail(self, job_id: str, lines: int = 200) -> dict:
        job = self.get_job(job_id)
        path = self.jobs_dir / job_id / "job.log"
        lines = max(0, min(lines, 2000))
        tail: deque[str] = deque(maxlen=lines)
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    tail.append(line.rstrip("\n"))
        except OSError:
            return {"id": job["id"], "lines": [], "truncated": False}
        return {"id": job["id"], "lines": list(tail), "truncated": False}

    def shutdown(self) -> None:
        with self._mutex:
            self._shutdown_requested = True
            proc = self._proc
        if proc is not None and proc.poll() is None:
            self._signal_current(signal.SIGTERM)
            deadline = time.monotonic() + 5
            while proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.1)
            if proc.poll() is None:
                self._signal_current(signal.SIGKILL)
        waiter = self._waiter
        if waiter is not None:
            waiter.join(timeout=3)
        with self._mutex:
            if self._current and self._current.get("status") in (
                "running",
                "cancelling",
            ):
                self._current.update(
                    status="interrupted",
                    finished_at=iso_now(),
                    error={
                        "stage": self._current.get("stage") or "run",
                        "message": "service stopped while the job was running",
                    },
                )
                _atomic_write_json(
                    self._job_file(self._current["id"]), self._current
                )
            self._current = None
            self._proc = None
            self._release_lock()

    # -- command / process -------------------------------------------------

    def _default_command(self, mode: str, options: dict) -> list[str]:
        argv = [
            sys.executable,
            str(self.repo_root / "tools" / "catalog-update" / "catalog_update.py"),
            "run",
            "--report-dir",
            str(self.catalog_report_dir),
            "--sync-report-dir",
            str(self.sync_report_dir),
        ]
        if mode == "dry-run":
            argv.append("--dry-run")
        for prefix in options.get("only") or ():
            argv.extend(["--only", prefix])
        for pattern in options.get("exclude") or ():
            argv.extend(["--exclude", pattern])
        if options.get("skip_publish"):
            argv.append("--skip-publish")
        if options.get("no_crew"):
            argv.append("--no-crew")
        return argv

    def _read_output(self, proc: subprocess.Popen, log_handle, job_id: str) -> None:
        try:
            if proc.stdout is None:
                return
            for line in proc.stdout:
                log_handle.write(line)
                log_handle.flush()
                match = STAGE_RE.search(line)
                if match:
                    self._set_stage(job_id, match.group(1).strip())
        except (OSError, ValueError):
            pass
        finally:
            try:
                proc.stdout.close()
            except OSError:
                pass
            try:
                log_handle.close()
            except OSError:
                pass

    def _wait_job(self, proc: subprocess.Popen, job_id: str) -> None:
        last_heartbeat = 0.0
        while True:
            returncode = proc.poll()
            now = time.monotonic()
            if now - last_heartbeat >= HEARTBEAT_SECONDS:
                self._heartbeat(job_id)
                last_heartbeat = now
            if (
                self._cancel_requested
                and self._cancel_started
                and now - self._cancel_started >= CANCEL_GRACE_SECONDS
            ):
                self._signal_current(signal.SIGKILL)
            if returncode is not None:
                break
            time.sleep(0.25)

        reader = self._reader
        if reader is not None:
            reader.join(timeout=5)
        self._finish(job_id, proc.returncode)

    def _finish(self, job_id: str, returncode: int | None) -> None:
        job_to_notify = None
        with self._mutex:
            job = self._current if self._current and self._current.get("id") == job_id else None
            if job is None:
                job = _read_json(self._job_file(job_id))
            if job is None:
                self._release_lock()
                return

            if self._shutdown_requested:
                status = "interrupted"
                error = {
                    "stage": job.get("stage") or "run",
                    "message": "service stopped while the job was running",
                }
            elif self._cancel_requested:
                status = "cancelled"
                error = {
                    "stage": job.get("stage") or "run",
                    "message": "cancelled by user",
                }
            elif returncode == 0:
                status = "ok"
                error = None
            else:
                status = "error"
                error = {
                    "stage": job.get("stage") or "run",
                    "message": f"catalog-update exited with code {returncode}",
                }

            job.update(
                status=status,
                finished_at=iso_now(),
                exit_code=returncode,
                error=error,
                report_file=self._newest_report(job.get("started_epoch")),
                heartbeat_epoch=time.time(),
            )
            job.pop("cancelling", None)
            _atomic_write_json(self._job_file(job_id), job)
            self._release_lock()
            job_to_notify = dict(job)
            self._current = None
            self._proc = None
            self._reader = None
            self._waiter = None
            self._cancel_requested = False
            self._cancel_started = 0.0
            self._shutdown_requested = False
        if job_to_notify is not None:
            self._notify(job_to_notify)

    def _notify(self, job: dict) -> None:
        if job.get("mode") != "full" or job.get("status") != "ok":
            return
        report_name = job.get("report_file")
        if not report_name:
            return
        report_path = self.catalog_report_dir / "runs" / str(report_name)
        try:
            report = json.loads(report_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        message = notify.notify_sync_changes(report)
        if not message:
            return
        try:
            with open(
                self.jobs_dir / str(job["id"]) / "job.log",
                "a",
                encoding="utf-8",
            ) as handle:
                handle.write(f"\nnotification: {message}\n")
        except OSError:
            pass

    def _set_stage(self, job_id: str, stage: str) -> None:
        with self._mutex:
            job = self._current
            if not job or job.get("id") != job_id:
                return
            if job.get("status") not in ("running", "cancelling"):
                return
            job["stage"] = stage
            job["heartbeat_epoch"] = time.time()
            _atomic_write_json(self._job_file(job_id), job)

    def _heartbeat(self, job_id: str) -> None:
        with self._mutex:
            job = self._current
            if job and job.get("id") == job_id:
                if job.get("status") not in ("running", "cancelling"):
                    return
                job["heartbeat_epoch"] = time.time()
                _atomic_write_json(self._job_file(job_id), job)
            lock = _read_json(self.lock_path)
            if lock is not None and lock.get("job_id") == job_id:
                lock["heartbeat_epoch"] = time.time()
                _atomic_write_json(self.lock_path, lock)

    def _signal_current(self, sig: int) -> None:
        proc = self._proc
        if proc is None or proc.poll() is not None:
            return
        try:
            if hasattr(os, "killpg"):
                os.killpg(os.getpgid(proc.pid), sig)
            else:
                proc.send_signal(sig)
        except ProcessLookupError:
            pass
        except OSError:
            try:
                proc.send_signal(sig)
            except OSError:
                pass

    # -- lock / reconciliation --------------------------------------------

    def _reconcile(self) -> None:
        lock = _read_json(self.lock_path)
        if lock is not None:
            lock_pid = int(lock.get("pid") or 0)
            if lock_pid and lock_pid != os.getpid() and _pid_alive(lock_pid):
                # Another live service owns this state directory. Do not kill
                # its job; a later start will fail cleanly on the active lock.
                return
        try:
            job_files = list(self.jobs_dir.glob("*/job.json"))
        except OSError:
            job_files = []
        for path in job_files:
            job = _read_json(path)
            if not job or job.get("status") not in ("running", "cancelling"):
                continue
            pid = int(job.get("pid") or 0)
            if pid and _is_catalog_process(pid):
                _signal_pid(pid, signal.SIGTERM)
                deadline = time.monotonic() + 3
                while _pid_alive(pid) and time.monotonic() < deadline:
                    time.sleep(0.1)
                if _pid_alive(pid):
                    _signal_pid(pid, signal.SIGKILL)
            job.update(
                status="interrupted",
                finished_at=iso_now(),
                error={
                    "stage": job.get("stage") or "run",
                    "message": "service restarted while the job was running",
                },
            )
            job.pop("cancelling", None)
            _atomic_write_json(path, job)
        self._release_lock()

    def _acquire_lock(self, job_id: str) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        for _ in range(2):
            try:
                fd = os.open(
                    self.lock_path,
                    os.O_CREAT | os.O_EXCL | os.O_WRONLY,
                    0o644,
                )
            except FileExistsError:
                if self._lock_stale():
                    try:
                        self.lock_path.unlink()
                    except OSError:
                        pass
                    continue
                raise BusyError("another catalog pipeline job is already running")
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(
                    json.dumps(
                        {
                            "pid": os.getpid(),
                            "job_id": job_id,
                            "started_at": iso_now(),
                            "heartbeat_epoch": time.time(),
                        },
                        sort_keys=True,
                    )
                    + "\n"
                )
            return
        raise BusyError("cannot acquire the pipeline lock")

    def _release_lock(self) -> None:
        try:
            self.lock_path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass

    def _lock_stale(self) -> bool:
        try:
            age = time.time() - self.lock_path.stat().st_mtime
        except OSError:
            return True
        if age > LOCK_HARD_STALE_SECONDS:
            return True
        lock = _read_json(self.lock_path)
        if lock is None:
            return age > LOCK_STALE_SECONDS
        pid = int(lock.get("pid") or 0)
        if pid and not _pid_alive(pid):
            return True
        heartbeat = lock.get("heartbeat_epoch")
        try:
            heartbeat = float(heartbeat)
        except (TypeError, ValueError):
            heartbeat = self.lock_path.stat().st_mtime
        return time.time() - heartbeat > LOCK_STALE_SECONDS

    def _catalog_lock_active(self) -> bool:
        path = self.catalog_report_dir / "run.lock"
        if not path.is_file():
            return False
        try:
            age = time.time() - path.stat().st_mtime
        except OSError:
            return True
        if age > LOCK_HARD_STALE_SECONDS:
            return False
        try:
            pid = int(path.read_text(encoding="utf-8").split()[0])
        except (OSError, ValueError, IndexError):
            return age <= LOCK_STALE_SECONDS
        return _pid_alive(pid)

    # -- helpers -----------------------------------------------------------

    def _new_job_id(self) -> str:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        return f"{stamp}-{uuid.uuid4().hex[:6]}"

    def _job_file(self, job_id: str) -> Path:
        if not job_id or "/" in job_id or "\\" in job_id or job_id in (".", ".."):
            raise NotFoundError(f"invalid job id: {job_id!r}")
        return self.jobs_dir / job_id / "job.json"

    def _newest_report(self, since_epoch) -> str | None:
        runs_dir = self.catalog_report_dir / "runs"
        try:
            since = float(since_epoch) - 5
        except (TypeError, ValueError):
            since = 0.0
        try:
            files = [
                path
                for path in runs_dir.glob("*.json")
                if path.stat().st_mtime >= since
            ]
        except OSError:
            return None
        if not files:
            return None
        newest = max(files, key=lambda path: path.stat().st_mtime)
        return newest.name

    def _summary(self, job: dict) -> dict:
        keys = (
            "id",
            "mode",
            "source",
            "status",
            "stage",
            "started_at",
            "finished_at",
            "exit_code",
            "error",
            "report_file",
            "pid",
            "cancelling",
            "heartbeat_epoch",
        )
        return {key: job.get(key) for key in keys if key in job}

    def _prune_jobs(self) -> None:
        try:
            job_dirs = sorted(
                [path for path in self.jobs_dir.iterdir() if path.is_dir()],
                key=lambda path: path.name,
                reverse=True,
            )
        except OSError:
            return
        current_id = self._current.get("id") if self._current else None
        for path in job_dirs[JOB_RETENTION:]:
            if path.name == current_id:
                continue
            shutil.rmtree(path, ignore_errors=True)

    @staticmethod
    def _string_list(value, name: str) -> list[str]:
        if value is None:
            return []
        if isinstance(value, str):
            return [value]
        if isinstance(value, (list, tuple)) and all(
            isinstance(item, str) for item in value
        ):
            return list(value)
        raise InvalidJobError(f"{name} must be a string or a list of strings")
