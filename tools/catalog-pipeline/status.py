#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Read-only status collector for the Marcer catalog pipeline.

Collects the state of the sync reports, gameinfo files, full index, crew data,
asset-publish state, screenshot indices, storage and recent run reports.
Nothing in this module writes to the catalog or the pipeline state.
"""
from __future__ import annotations

import gzip
import json
import os
import shutil
import threading
import time
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

TOOL_VERSION = "0.1.0"
STATUS_SCHEMA = 1
REPO_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_RUN_LIMIT = 10
SCREENSHOT_BYTES_BUDGET = 0.4
SHOTGEN_LOCK = "shotgen.lock"

SCOPES = (
    ("cracked", "index.json"),
    ("pd", "index-pd.json"),
    ("utils", "index-utils.json"),
    ("magazine", "index-magazine.json"),
    ("falcon", "index-falcon.json"),
)
SCOPE_KEYS = tuple(name for name, _ in SCOPES)
STATUS_ORDER = (
    "done",
    "desktop",
    "no_usable_shots",
    "pending",
    "error",
    "interrupted",
    "timeout",
    "skipped_disk_n",
    "unknown",
)
PUBLISHABLE_FILE_NAMES = {
    "manifest.json",
    "crews.json",
    "crew-images.json",
    "crew-cluster.json",
    "full-index.json.gz",
    "unmatched-report.txt",
}
SYNC_COUNT_KEYS = (
    "remote_files",
    "new",
    "changed",
    "in_sync",
    "unknown_size",
    "local_only",
    "downloads",
    "downloaded",
    "download_errors",
    "case_conflicts",
    "local_conflicts",
    "warnings",
    "incomplete_dirs",
)


def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_from_epoch(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def age_hours(epoch: float | None) -> float | None:
    if epoch is None:
        return None
    return round(max(0.0, time.time() - epoch) / 3600.0, 2)


def _file_info(path: Path) -> dict | None:
    try:
        stat = path.stat()
    except OSError:
        return None
    if not path.is_file():
        return None
    return {
        "name": path.name,
        "mtime": iso_from_epoch(stat.st_mtime),
        "mtime_epoch": stat.st_mtime,
        "size": stat.st_size,
        "age_hours": age_hours(stat.st_mtime),
    }


class JsonCache:
    """Tiny in-memory cache keyed by file mtime and size."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._items: dict[str, tuple[int, int, dict | None, str | None]] = {}

    def load(self, path: Path, compressed: bool = False) -> tuple[dict | None, str | None]:
        try:
            stat = path.stat()
        except OSError:
            return None, f"{path.name} missing"
        key = str(path)
        with self._lock:
            cached = self._items.get(key)
            if cached and cached[0] == stat.st_mtime_ns and cached[1] == stat.st_size:
                return cached[2], cached[3]
        try:
            if compressed:
                with gzip.open(path, "rt", encoding="utf-8") as handle:
                    data = json.load(handle)
            else:
                with open(path, encoding="utf-8") as handle:
                    data = json.load(handle)
        except (OSError, ValueError) as exc:
            result: tuple[dict | None, str | None] = (
                None,
                f"cannot read {path.name}: {exc}",
            )
        else:
            if isinstance(data, dict):
                result = (data, None)
            else:
                result = (None, f"invalid {path.name}: not an object")
        with self._lock:
            self._items[key] = (stat.st_mtime_ns, stat.st_size, result[0], result[1])
        return result


class StatusCollector:
    def __init__(
        self,
        environ: dict | None = None,
        repo_root: Path | None = None,
    ) -> None:
        self._env = dict(os.environ if environ is None else environ)
        self.repo_root = Path(repo_root) if repo_root else REPO_ROOT
        self.cache = JsonCache()
        self._screenshot_lock = threading.Lock()
        self._screenshot_cache: dict[str, tuple[int, int, dict]] = {}

    def env(self, name: str, default: str = "") -> str:
        return str(self._env.get(name, default) or "").strip()

    def path(self, name: str) -> Path | None:
        value = self.env(name)
        return Path(value).expanduser() if value else None

    def paths(self) -> dict:
        root = self.path("MARCER_ROOT_DIR")
        patch = self.path("MARCER_PATCH_DIR")
        out = self.path("MARCER_OUT_DIR")
        data = self.path("MARCER_DATA_DIR")
        state_explicit = self.path("MARCER_STATE_DIR")
        if state_explicit is not None:
            state = state_explicit
        elif data is not None:
            state = data / "state"
        else:
            state = None
        reports_root = state if state is not None else self.repo_root / "local"
        sync_dir = self.path("MARCER_SYNC_REPORT_DIR")
        if sync_dir is None:
            sync_dir = reports_root / "archive-sync"
        pipeline_dir = self.path("MARCER_PIPELINE_REPORT_DIR")
        if pipeline_dir is None:
            pipeline_dir = reports_root / "catalog-update"
        asset_out = self.path("MARCER_ASSET_OUT_DIR")
        if asset_out is None:
            asset_out = data
        if state is not None:
            asset_state = state / "asset-publish" / "state.json"
        elif data is not None:
            asset_state = data / ".asset-publish-state.json"
        else:
            asset_state = None
        legacy_asset_state = (
            data / ".asset-publish-state.json" if data is not None else None
        )
        return {
            "root": root,
            "patch": patch,
            "out": out,
            "data": data,
            "state": state,
            "state_explicit": state_explicit,
            "sync_dir": sync_dir,
            "pipeline_dir": pipeline_dir,
            "asset_out": asset_out,
            "asset_state": asset_state,
            "legacy_asset_state": legacy_asset_state,
            "jobs_dir": state / "jobs" if state is not None else None,
            "pipeline_lock": state / "pipeline.lock" if state is not None else None,
            "scheduler_state": (
                state / "scheduler.json" if state is not None else None
            ),
            "gameinfo": data / "gameinfo" if data is not None else None,
        }

    def health(self) -> dict:
        paths = self.paths()
        required = (
            ("MARCER_ROOT_DIR", paths["root"]),
            ("MARCER_PATCH_DIR", paths["patch"]),
            ("MARCER_OUT_DIR", paths["out"]),
            ("MARCER_DATA_DIR", paths["data"]),
        )
        missing = [name for name, path in required if path is None]
        warnings = [
            f"{name} is not a directory"
            for name, path in required
            if path is not None and not path.is_dir()
        ]
        return {
            "status": "ok" if not missing and not warnings else "degraded",
            "version": TOOL_VERSION,
            "missing": missing,
            "warnings": warnings,
        }

    def collect(self) -> dict:
        paths = self.paths()
        status = {
            "schema": STATUS_SCHEMA,
            "tool": "tools/catalog-pipeline",
            "tool_version": TOOL_VERSION,
            "generated_at": iso_now(),
            "mode": "read-only",
            "config": self._config(paths),
            "sync": self._sync(paths),
            "gameinfo": self._gameinfo(paths),
            "full_index": self._full_index(paths),
            "crews": self._crews(paths),
            "publish": self._publish(paths),
            "screenshots": self._screenshots(paths),
            "storage": self._storage(paths),
            "pipeline": self._pipeline(paths),
            "jobs": self._jobs(paths),
            "scheduler": self._scheduler(paths),
        }
        return status

    def runs(self, limit: int = DEFAULT_RUN_LIMIT) -> list[dict]:
        paths = self.paths()
        return self._runs(paths["pipeline_dir"], limit)

    def _config(self, paths: dict) -> dict:
        missing = [
            name
            for name, path in (
                ("MARCER_ROOT_DIR", paths["root"]),
                ("MARCER_PATCH_DIR", paths["patch"]),
                ("MARCER_OUT_DIR", paths["out"]),
                ("MARCER_DATA_DIR", paths["data"]),
            )
            if path is None
        ]
        warnings = [
            f"{name} is not a directory"
            for name, path in (
                ("MARCER_ROOT_DIR", paths["root"]),
                ("MARCER_PATCH_DIR", paths["patch"]),
                ("MARCER_OUT_DIR", paths["out"]),
                ("MARCER_DATA_DIR", paths["data"]),
            )
            if path is not None and not path.is_dir()
        ]
        if paths["state_explicit"] is not None and not paths["state_explicit"].is_dir():
            warnings.append("MARCER_STATE_DIR is not a directory")
        if paths["state"] is not None:
            state_source = "env" if paths["state_explicit"] is not None else "data"
        else:
            state_source = "missing"
        return {
            "missing": missing,
            "warnings": warnings,
            "ftp_configured": bool(
                self.env("MARCER_FTP_HOST") and self.env("MARCER_FTP_USER")
            ),
            "github_configured": bool(self.env("MARCER_GITHUB_TOKEN")),
            "pipeline_token_required": bool(self.env("MARCER_PIPELINE_TOKEN")),
            "screenshot_run_active": bool(
                paths["out"] is not None
                and (paths["out"] / SHOTGEN_LOCK).is_file()
            ),
            "state_configured": paths["state"] is not None,
            "state_source": state_source,
        }

    def _sync(self, paths: dict) -> dict:
        report = paths["sync_dir"] / "changes.json"
        data, error = self.cache.load(report)
        info = _file_info(report)
        result = {
            "present": data is not None,
            "error": error,
            "file": info,
        }
        if data is None:
            return result
        counts = data.get("counts")
        if isinstance(counts, dict):
            result["counts"] = {
                key: counts.get(key, 0)
                for key in SYNC_COUNT_KEYS
                if key in counts
            }
        else:
            result["counts"] = {}
        result["generated_at"] = data.get("generated_at")
        result["mode"] = data.get("mode")
        incomplete = data.get("incomplete_dirs")
        result["incomplete_dirs"] = (
            [str(item) for item in incomplete[:20]]
            if isinstance(incomplete, list)
            else []
        )
        return result

    def _gameinfo(self, paths: dict) -> dict:
        gameinfo = paths["gameinfo"]
        if gameinfo is None or not gameinfo.is_dir():
            return {"present": False, "error": "gameinfo directory missing", "files": []}
        manifest, manifest_error = self.cache.load(gameinfo / "manifest.json")
        files = []
        for path in sorted(gameinfo.iterdir(), key=lambda item: item.name.casefold()):
            if not path.is_file():
                continue
            if path.name.startswith(".") or path.name.endswith((".part", ".tmp")):
                continue
            if not (
                path.name.startswith("games-") or path.name in PUBLISHABLE_FILE_NAMES
            ):
                continue
            info = _file_info(path)
            if info is not None:
                files.append(info)
        result = {
            "present": manifest is not None,
            "error": manifest_error,
            "files": files,
        }
        if manifest is not None:
            result["generated_at"] = manifest.get("generated_at")
            result["generator"] = manifest.get("generator")
            result["generator_version"] = manifest.get("generator_version")
            sources = manifest.get("sources")
            if isinstance(sources, list):
                result["sources"] = [
                    {
                        key: source.get(key)
                        for key in (
                            "kind",
                            "source",
                            "matched_folders",
                            "title_count",
                            "mtime",
                        )
                        if isinstance(source, dict) and key in source
                    }
                    for source in sources
                    if isinstance(source, dict)
                ]
        return result

    def _full_index(self, paths: dict) -> dict:
        gameinfo = paths["gameinfo"]
        if gameinfo is None:
            return {"present": False, "error": "gameinfo directory missing"}
        path = gameinfo / "full-index.json.gz"
        data, error = self.cache.load(path, compressed=True)
        info = _file_info(path)
        result = {
            "present": data is not None,
            "error": error,
            "file": info,
        }
        if data is not None:
            counts = data.get("counts")
            result["counts"] = counts if isinstance(counts, dict) else {}
            errors = data.get("errors")
            result["error_count"] = len(errors) if isinstance(errors, list) else 0
            result["tool"] = data.get("tool")
        return result

    def _crews(self, paths: dict) -> dict:
        gameinfo = paths["gameinfo"]
        if gameinfo is None:
            return {"present": False, "error": "gameinfo directory missing"}
        path = gameinfo / "crews.json"
        data, error = self.cache.load(path)
        info = _file_info(path)
        result = {
            "present": data is not None,
            "error": error,
            "file": info,
        }
        if data is not None:
            groups = data.get("groups")
            result["generated_at"] = data.get("generated_at")
            result["groups"] = len(groups) if isinstance(groups, list) else 0
        return result

    def _publish(self, paths: dict) -> dict:
        state_file = paths["asset_state"]
        legacy = paths.get("legacy_asset_state")
        result = {
            "file": None,
            "error": None,
            "gameinfo": {"status": "missing", "error": "no gameinfo entry"},
            "screenshots": {"status": "missing", "error": "no screenshots entry"},
        }
        if state_file is None:
            result["error"] = "state directory missing"
            return result
        state, error = self.cache.load(state_file)
        if state is None and legacy is not None and legacy != state_file:
            legacy_state, legacy_error = self.cache.load(legacy)
            if legacy_state is not None:
                state, error, state_file = legacy_state, None, legacy
        result["file"] = _file_info(state_file)
        if state is None:
            result["error"] = error
            return result
        assets = state.get("assets")
        if not isinstance(assets, dict):
            assets = {}
        result["gameinfo"] = self._publish_asset(
            "gameinfo", assets.get("gameinfo"), paths["asset_out"]
        )
        result["screenshots"] = self._publish_asset(
            "screenshots", assets.get("screenshots"), paths["out"]
        )
        return result

    def _publish_asset(self, kind: str, entry, output_dir) -> dict:
        if not isinstance(entry, dict) or not entry:
            return {"status": "missing", "error": f"no {kind} entry"}
        uploaded = bool(entry.get("uploaded"))
        manifest_dirty = bool(entry.get("manifest_dirty"))
        if not uploaded:
            publish_status = "pending"
        elif manifest_dirty:
            publish_status = "dirty"
        else:
            publish_status = "uploaded"
        archive = entry.get("archive")
        archive_exists = bool(
            archive
            and output_dir is not None
            and (output_dir / str(archive)).is_file()
        )
        return {
            "status": publish_status,
            "error": None,
            "archive": archive,
            "archive_exists": archive_exists,
            "size": entry.get("size"),
            "files": entry.get("files"),
            "uploaded": uploaded,
            "manifest_dirty": manifest_dirty,
            "remote": entry.get("remote"),
            "updated_at": entry.get("updated_at"),
            "uploaded_at": entry.get("uploaded_at"),
            "manifest_updated_at": entry.get("manifest_updated_at"),
        }

    def _screenshots(self, paths: dict) -> dict:
        out = paths["out"]
        scopes: dict[str, dict] = {}
        if out is None or not out.is_dir():
            return {
                "present": False,
                "error": "MARCER_OUT_DIR missing",
                "scopes": {},
                "without_preview": 0,
                "index_age_hours": None,
                "bytes": 0,
                "bytes_partial": False,
            }

        total_without_preview = 0
        total_bytes = 0
        total_partial = False
        oldest_age = None
        for name, index_name in SCOPES:
            scope = self._screenshot_scope(out, name, index_name)
            scopes[name] = scope
            if scope.get("present"):
                total_without_preview += int(scope.get("without_preview") or 0)
                total_bytes += int(scope.get("bytes") or 0)
                total_partial = total_partial or bool(scope.get("bytes_partial"))
                age = scope.get("age_hours")
                if age is not None:
                    oldest_age = age if oldest_age is None else max(oldest_age, age)
        return {
            "present": any(scope.get("present") for scope in scopes.values()),
            "error": None,
            "scopes": scopes,
            "without_preview": total_without_preview,
            "bytes": total_bytes,
            "bytes_partial": total_partial,
            "index_age_hours": oldest_age,
        }

    def _screenshot_scope(self, out: Path, name: str, index_name: str) -> dict:
        path = out / index_name
        try:
            stat = path.stat()
        except OSError:
            stat = None
        info = _file_info(path)
        cache_key = str(path)
        if stat is not None:
            with self._screenshot_lock:
                cached = self._screenshot_cache.get(cache_key)
                if cached and cached[0] == stat.st_mtime_ns and cached[1] == stat.st_size:
                    return dict(cached[2])
        data, error = self.cache.load(path)
        if data is None:
            result = {
                "present": False,
                "error": error,
                "index": index_name,
                "file": info,
                "total": 0,
                "counts": {key: 0 for key in STATUS_ORDER},
                "without_preview": 0,
                "bytes": 0,
                "bytes_partial": False,
                "age_hours": None,
            }
            if stat is not None:
                with self._screenshot_lock:
                    self._screenshot_cache[cache_key] = (
                        stat.st_mtime_ns,
                        stat.st_size,
                        result,
                    )
            return result
        entries = data.get("entries")
        if not isinstance(entries, dict):
            entries = {}
        counts = {key: 0 for key in STATUS_ORDER}
        without_preview = 0
        for entry in entries.values():
            if not isinstance(entry, dict):
                continue
            status = str(entry.get("status") or "unknown")
            if status not in counts:
                status = "unknown"
            counts[status] += 1
            if not entry.get("preview") and status != "skipped_disk_n":
                without_preview += 1

        # Image sizes are optional and can be expensive on a network share.
        # Count them only within a small per-scope budget; the index size alone
        # is always included. The budget starts after the (possibly slow) JSON
        # load, so parsing a large index does not consume it.
        bytes_total = int(info["size"]) if info else 0
        bytes_partial = False
        deadline = time.monotonic() + SCREENSHOT_BYTES_BUDGET
        for rel, entry in entries.items():
            if time.monotonic() > deadline:
                bytes_partial = True
                break
            if not isinstance(entry, dict):
                continue
            names = []
            preview = entry.get("preview")
            if preview:
                names.append(preview)
            candidates = entry.get("candidates")
            if isinstance(candidates, list):
                names.extend(item for item in candidates if item)
            for image_name in names:
                image = _output_file(out, rel, str(image_name))
                if image is None:
                    continue
                try:
                    bytes_total += image.stat().st_size
                except OSError:
                    continue
        result = {
            "present": True,
            "error": None,
            "index": index_name,
            "file": info,
            "total": len(entries),
            "counts": counts,
            "without_preview": without_preview,
            "bytes": bytes_total,
            "bytes_partial": bytes_partial,
            "age_hours": age_hours(info["mtime_epoch"]) if info else None,
        }
        if stat is not None:
            with self._screenshot_lock:
                self._screenshot_cache[cache_key] = (
                    stat.st_mtime_ns,
                    stat.st_size,
                    result,
                )
        return result

    def _jobs(self, paths: dict) -> dict:
        jobs_dir = paths.get("jobs_dir")
        lock = paths.get("pipeline_lock")
        result = {
            "current": None,
            "recent": [],
            "lock_present": bool(lock is not None and lock.is_file()),
        }
        if jobs_dir is None or not jobs_dir.is_dir():
            return result
        jobs = []
        try:
            job_files = list(jobs_dir.glob("*/job.json"))
        except OSError:
            return result
        for path in job_files:
            data, error = self.cache.load(path)
            if data is not None and not error:
                jobs.append(_job_summary(data))
        jobs.sort(
            key=lambda job: (job.get("started_at") or "", job.get("id") or ""),
            reverse=True,
        )
        for job in jobs:
            if job.get("status") in ("running", "cancelling"):
                result["current"] = job
                break
        result["recent"] = jobs[:10]
        return result

    def _scheduler(self, paths: dict) -> dict:
        state_file = paths.get("scheduler_state")
        data, error = (None, "state directory missing")
        if state_file is not None:
            data, error = self.cache.load(state_file)
        cron = self.env("MARCER_SCHEDULE_CRON", "0 20 * * 4")
        timezone_name = self.env("MARCER_TZ", "Europe/Berlin")
        try:
            catch_up = int(
                self.env("MARCER_SCHEDULE_CATCH_UP_HOURS", "24") or "24"
            )
        except ValueError:
            catch_up = 24
        if isinstance(data, dict):
            cron = data.get("cron", cron)
            timezone_name = data.get("timezone", timezone_name)
            catch_up = data.get("catch_up_hours", catch_up)
        return {
            "present": isinstance(data, dict),
            "error": error,
            "cron": cron,
            "timezone": timezone_name,
            "catch_up_hours": catch_up,
            "next_run": data.get("next_run") if isinstance(data, dict) else None,
            "last_attempt": (
                data.get("last_attempt") if isinstance(data, dict) else None
            ),
            "last_started": (
                data.get("last_started") if isinstance(data, dict) else None
            ),
            "last_status": (
                data.get("last_status") if isinstance(data, dict) else None
            ),
            "last_job_id": (
                data.get("last_job_id") if isinstance(data, dict) else None
            ),
            "last_error": (
                data.get("last_error") if isinstance(data, dict) else None
            ),
        }

    def _storage(self, paths: dict) -> dict:
        result = {}
        for name in ("root", "patch", "out", "data", "state"):
            path = paths[name]
            if path is None:
                result[name] = None
                continue
            try:
                usage = shutil.disk_usage(path)
            except OSError:
                result[name] = None
                continue
            result[name] = {
                "free_bytes": usage.free,
                "total_bytes": usage.total,
                "used_bytes": usage.used,
            }
        return result

    def _pipeline(self, paths: dict) -> dict:
        runs = self._runs(paths["pipeline_dir"], 1)
        return {
            "report_dir_present": paths["pipeline_dir"].is_dir(),
            "last_run": runs[0] if runs else None,
        }

    def _runs(self, report_dir: Path, limit: int) -> list[dict]:
        runs_dir = report_dir / "runs"
        try:
            files = sorted(
                runs_dir.glob("*.json"),
                key=lambda item: item.name,
                reverse=True,
            )[: max(0, limit)]
        except OSError:
            return []
        result = []
        for path in files:
            data, error = self.cache.load(path)
            if data is None:
                result.append({"file": path.name, "error": error})
                continue
            error_info = data.get("error")
            if not isinstance(error_info, dict):
                error_info = None
            actions = data.get("actions")
            publish = data.get("publish")
            sync = data.get("sync")
            result.append(
                {
                    "file": path.name,
                    "status": data.get("status"),
                    "started_at": data.get("started_at"),
                    "finished_at": data.get("finished_at"),
                    "error": error_info,
                    "actions": actions if isinstance(actions, dict) else {},
                    "sync": sync if isinstance(sync, dict) else {},
                    "publish": publish if isinstance(publish, dict) else {},
                    "steps": len(data.get("steps") or []),
                }
            )
        return result


def _job_summary(job: dict) -> dict:
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


def _output_file(out: Path, rel: str, name: str) -> Path | None:
    rel_path = PurePosixPath(rel.replace("\\", "/"))
    if rel_path.is_absolute() or ".." in rel_path.parts:
        return None
    name_path = PurePosixPath(name.replace("\\", "/"))
    if name_path.is_absolute() or ".." in name_path.parts or len(name_path.parts) != 1:
        return None
    return out.joinpath(*rel_path.parent.parts) / name_path.name
