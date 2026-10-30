#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""One-shot catalog update: FTP sync, gameinfo, full index, crews and publish.

This orchestrator wraps the existing tools in the order documented in
``tools/full-index-gen/README.md`` and ``docs/plans/PLAN-docker-pipeline.md``:

1. ``tools/archive-sync`` downloads new/changed files into the patch layer.
2. ``tools/gameinfo-gen`` is refreshed when the XLS sources or gameinfo trees
   changed.
3. ``tools/full-index-gen`` is rebuilt when ZIPs or gameinfo changed.
4. ``tools/crew-analysis`` runs when gameinfo was rebuilt or the cracked tree
   changed.
5. ``tools/asset-publish`` packs/uploads gameinfo only when the content
   signature changed or a previous upload is still pending.

The root tree is never modified. There is no rename detection and no deletion.
"""
from __future__ import annotations

import argparse
import json
import os
import posixpath
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools"))

from _lib import catalog_sections as cs  # noqa: E402

TOOL_VERSION = "0.1.0"
DEFAULT_REPORT_DIR = REPO_ROOT / "local" / "catalog-update"
DEFAULT_SYNC_REPORT_DIR = REPO_ROOT / "local" / "archive-sync"
GAMEINFO_SCOPES = ("cracked", "pd", "utils")
PUBLISH_STATUSES = {
    "would-create-upload",
    "would-upload",
    "would-update-manifest",
}


class UpdateError(Exception):
    """A recoverable catalog-update error."""

    def __init__(self, stage: str, message: str) -> None:
        super().__init__(message)
        self.stage = stage


@dataclass
class StepResult:
    name: str
    argv: list[str]
    returncode: int
    duration_s: float = 0.0
    stdout: str = ""
    stderr: str = ""


@dataclass
class Options:
    repo_root: Path
    root: Path
    patch: Path
    data_dir: Path
    only: tuple[str, ...]
    excludes: tuple[str, ...]
    dry_run: bool
    skip_publish: bool
    no_crew: bool
    report_dir: Path
    sync_report_dir: Path

    @property
    def gameinfo_dir(self) -> Path:
        return self.data_dir / "gameinfo"

    @property
    def changes_path(self) -> Path:
        return self.sync_report_dir / "changes.json"


@dataclass
class UpdateReport:
    status: str = "running"
    started_at: str = field(default_factory=lambda: iso_now())
    finished_at: str = ""
    error: dict | None = None
    actions: dict = field(default_factory=dict)
    sync: dict = field(default_factory=dict)
    publish: dict = field(default_factory=dict)

    def as_dict(self, steps: list[StepResult]) -> dict:
        return {
            "schema": 1,
            "tool": "tools/catalog-update",
            "tool_version": TOOL_VERSION,
            "status": self.status,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "error": self.error,
            "actions": self.actions,
            "sync": self.sync,
            "publish": self.publish,
            "steps": [
                {
                    "name": step.name,
                    "argv": step.argv,
                    "returncode": step.returncode,
                    "duration_s": round(step.duration_s, 3),
                }
                for step in steps
            ],
        }


class CommandRunner:
    def __init__(self) -> None:
        self.steps: list[StepResult] = []
        self.env = dict(os.environ)
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"

    def run(
        self,
        name: str,
        argv: list[str],
        capture: bool = False,
    ) -> StepResult:
        print(f"\n==> {name}", flush=True)
        print("    " + " ".join(argv), flush=True)
        started = time.monotonic()
        try:
            proc = subprocess.run(
                argv,
                cwd=REPO_ROOT,
                env=self.env,
                text=True,
                stdout=subprocess.PIPE if capture else None,
                stderr=subprocess.PIPE if capture else None,
            )
        except OSError as exc:
            raise UpdateError(name, f"cannot execute {name}: {exc}") from exc
        duration = time.monotonic() - started
        stdout = proc.stdout or ""
        stderr = proc.stderr or ""
        if capture:
            if stdout:
                print(stdout, end="" if stdout.endswith("\n") else "\n", flush=True)
            if stderr:
                print(stderr, end="" if stderr.endswith("\n") else "\n", file=sys.stderr)
        step = StepResult(name, argv, proc.returncode, duration, stdout, stderr)
        self.steps.append(step)
        return step


class RunLock:
    """Small cross-platform lock file with stale-pid detection."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.acquired = False

    def acquire(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        for _ in range(2):
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            except FileExistsError:
                if self._stale():
                    try:
                        self.path.unlink()
                    except OSError:
                        pass
                    continue
                raise UpdateError(
                    "lock",
                    f"another catalog-update run is active ({self.path})",
                )
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(f"{os.getpid()} {iso_now()}\n")
            self.acquired = True
            return
        raise UpdateError("lock", f"could not acquire lock ({self.path})")

    def release(self) -> None:
        if not self.acquired:
            return
        try:
            self.path.unlink()
        except OSError:
            pass
        self.acquired = False

    def _stale(self) -> bool:
        try:
            age = time.time() - self.path.stat().st_mtime
        except OSError:
            return True
        if age > 24 * 3600:
            return True
        try:
            pid = int(self.path.read_text(encoding="utf-8").split()[0])
        except (OSError, ValueError, IndexError):
            return False
        if os.name == "nt":
            return False
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        except OSError:
            return False
        return False


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def report_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def atomic_write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    text = json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, path)


def tool_argv(repo_root: Path, script: str, *args: str) -> list[str]:
    return [sys.executable, str(repo_root / "tools" / script), *args]


def append_filters(argv: list[str], only: tuple[str, ...], excludes: tuple[str, ...]) -> list[str]:
    for prefix in only:
        argv.extend(["--only", prefix])
    for pattern in excludes:
        argv.extend(["--exclude", pattern])
    return argv


def load_scope_trees() -> dict[str, tuple[str, ...]]:
    cfg = cs.load_config()
    _, scopes = cs.resolve_scopes(cfg)
    return {name: tuple(scope["trees"]) for name, scope in scopes.items()}


def within_trees(rel: str, trees: tuple[str, ...]) -> bool:
    value = rel.casefold()
    return any(
        value == tree.casefold() or value.startswith(tree.casefold() + "/")
        for tree in trees
    )


def gameinfo_trees(scopes: dict[str, tuple[str, ...]]) -> tuple[str, ...]:
    trees: list[str] = []
    for name in GAMEINFO_SCOPES:
        trees.extend(scopes.get(name, ()))
    return tuple(trees)


def load_changes(path: Path) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as exc:
        raise UpdateError("sync", f"cannot read sync report {path}: {exc}") from exc
    except ValueError as exc:
        raise UpdateError("sync", f"invalid sync report {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise UpdateError("sync", f"invalid sync report {path}: not an object")
    return data


def new_gameinfo_dirs(
    changes: dict,
    root: Path,
    patch: Path,
    trees: tuple[str, ...],
) -> list[str]:
    """Return new gameinfo folders without walking the whole archive.

    A new folder is a parent directory that did not exist in root and whose
    patch directory contains no older files. Directories are ignored during
    that check: a folder that already existed but only gained new files may be
    classified as new, which merely triggers an extra (safe) gameinfo rebuild.
    """
    new_paths = [
        str(item.get("path") or "")
        for item in changes.get("new", [])
        if within_trees(str(item.get("path") or ""), trees)
    ]
    new_set = {path.casefold() for path in new_paths}
    cache: dict[str, bool] = {}
    result: set[str] = set()
    for rel in new_paths:
        parent = posixpath.dirname(rel)
        if not parent:
            continue
        key = parent.casefold()
        if key not in cache:
            if (root / parent).is_dir():
                cache[key] = False
            else:
                patch_parent = patch / parent
                if not patch_parent.is_dir():
                    cache[key] = True
                else:
                    try:
                        entries = list(os.scandir(patch_parent))
                    except OSError:
                        cache[key] = False
                    else:
                        cache[key] = not any(
                            not entry.is_dir(follow_symlinks=False)
                            and posixpath.join(parent, entry.name).casefold()
                            not in new_set
                            for entry in entries
                        )
        if cache[key]:
            result.add(parent)
    return sorted(result)


def changes_under(changes: dict, trees: tuple[str, ...]) -> bool:
    for key in ("new", "changed"):
        for item in changes.get(key, []):
            rel = str(item.get("path") or "")
            if rel and within_trees(rel, trees):
                return True
    return False


def asset_publish_paths(opts: Options) -> tuple[Path, Path]:
    output_dir = (
        Path(env("MARCER_ASSET_OUT_DIR")).expanduser()
        if env("MARCER_ASSET_OUT_DIR")
        else opts.data_dir
    )
    state_dir = env("MARCER_STATE_DIR")
    if state_dir:
        state_file = Path(state_dir).expanduser() / "asset-publish" / "state.json"
    else:
        state_file = opts.data_dir / ".asset-publish-state.json"
    return output_dir, state_file


def publish_pending(opts: Options) -> bool:
    """True when the published gameinfo asset is missing or still pending."""
    output_dir, state_file = asset_publish_paths(opts)
    try:
        state = json.loads(state_file.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return True
    entry = (state.get("assets") or {}).get("gameinfo")
    if not isinstance(entry, dict) or not entry:
        return True
    if not entry.get("uploaded"):
        return True
    if entry.get("manifest_dirty"):
        return True
    archive = entry.get("archive")
    if not archive or not (output_dir / archive).is_file():
        return True
    return False


def parse_json_stdout(name: str, step: StepResult) -> dict:
    text = (step.stdout or "").strip()
    try:
        data = json.loads(text)
    except ValueError as exc:
        raise UpdateError(
            name,
            f"expected JSON from {name}, got: {text[:200] or '<empty>'}",
        ) from exc
    if not isinstance(data, dict):
        raise UpdateError(name, f"unexpected JSON from {name}: {type(data).__name__}")
    return data


def run_step(
    runner: CommandRunner,
    name: str,
    argv: list[str],
    capture: bool = False,
) -> StepResult:
    step = runner.run(name, argv, capture=capture)
    if step.returncode != 0:
        raise UpdateError(name, f"{name} failed with exit code {step.returncode}")
    return step


def run_checks(
    runner: CommandRunner,
    opts: Options,
    name: str,
    script: str,
) -> StepResult:
    return runner.run(name, tool_argv(opts.repo_root, script, "check"))


def publish_gameinfo(runner: CommandRunner, opts: Options) -> dict:
    base = tool_argv(
        opts.repo_root,
        "asset-publish/asset_publish.py",
        "publish",
        "--only",
        "gameinfo",
    )
    dry_step = run_step(
        runner,
        "asset-publish dry-run",
        [*base, "--upload", "--dry-run", "--json"],
        capture=True,
    )
    dry = parse_json_stdout("asset-publish dry-run", dry_step)
    status = dry.get("status", "")
    if status == "would-skip":
        print("asset-publish: nothing changed, skipping upload", flush=True)
        return {"status": "skipped", "dry_run": dry}
    if status not in PUBLISH_STATUSES:
        raise UpdateError(
            "asset-publish",
            f"unexpected asset-publish dry-run status: {status or '<empty>'}",
        )

    real_step = run_step(
        runner,
        "asset-publish",
        [*base, "--upload", "--json"],
        capture=True,
    )
    result = parse_json_stdout("asset-publish", real_step)
    print(f"asset-publish: {result.get('status', 'unknown')}", flush=True)
    return {"status": result.get("status", "unknown"), "dry_run": dry, "result": result}


def run_update(opts: Options, runner: CommandRunner) -> int:
    report = UpdateReport()
    lock = RunLock(opts.repo_root / "local" / "catalog-update" / "run.lock")
    try:
        if not opts.dry_run:
            lock.acquire()
        return _run_locked(opts, runner, report)
    except KeyboardInterrupt:
        report.status = "interrupted"
        report.error = {"stage": "run", "message": "interrupted"}
        print("\ncatalog-update: interrupted", file=sys.stderr)
        return 130
    except UpdateError as exc:
        report.status = "error"
        report.error = {"stage": exc.stage, "message": str(exc)}
        print(f"\ncatalog-update error [{exc.stage}]: {exc}", file=sys.stderr)
        return 1
    finally:
        report.finished_at = iso_now()
        if not opts.dry_run:
            try:
                path = opts.report_dir / "runs" / f"{report_stamp()}.json"
                atomic_write_json(path, report.as_dict(getattr(runner, "steps", [])))
                print(f"\nreport: {path}", flush=True)
            except OSError as exc:
                print(f"warning: cannot write run report: {exc}", file=sys.stderr)
            lock.release()


def _run_locked(opts: Options, runner: CommandRunner, report: UpdateReport) -> int:
    if not opts.root.is_dir():
        raise UpdateError("config", f"root directory not found: {opts.root}")

    try:
        scopes = load_scope_trees()
    except ValueError as exc:
        raise UpdateError("config", f"cannot load catalog scopes: {exc}") from exc

    trees = gameinfo_trees(scopes)

    sync_argv = tool_argv(
        opts.repo_root,
        "archive-sync/archive_sync.py",
        "plan" if opts.dry_run else "sync",
        "--report-dir",
        str(opts.sync_report_dir),
    )
    append_filters(sync_argv, opts.only, opts.excludes)
    sync_step = runner.run("archive-sync plan" if opts.dry_run else "archive-sync", sync_argv)
    if sync_step.returncode != 0:
        raise UpdateError(
            "archive-sync",
            f"archive-sync failed with exit code {sync_step.returncode}",
        )

    if opts.dry_run:
        gi_check = run_checks(
            runner, opts, "gameinfo check (dry-run)", "gameinfo-gen/gameinfo.py"
        )
        fi_check = run_checks(
            runner, opts, "full-index check (dry-run)", "full-index-gen/full_index_gen.py"
        )
        report.status = "dry-run"
        report.actions = {
            "gameinfo_extract": gi_check.returncode != 0,
            "full_index_run": fi_check.returncode != 0,
            "crew_analysis": "unknown",
            "publish": "skipped (dry-run)",
        }
        print(
            "\ndry-run: no gameinfo/full-index/crew/publish step was executed",
            flush=True,
        )
        return 0

    changes = load_changes(opts.changes_path)
    counts = changes.get("counts") or {}
    report.sync = {
        "counts": counts,
        "new_dirs": new_gameinfo_dirs(changes, opts.root, opts.patch, trees),
    }
    has_zip_changes = bool(changes.get("new") or changes.get("changed"))
    cracked_changed = changes_under(changes, scopes.get("cracked", ()))

    gi_check = run_checks(runner, opts, "gameinfo check", "gameinfo-gen/gameinfo.py")
    needs_gameinfo = gi_check.returncode != 0 or bool(report.sync["new_dirs"])
    report.actions["gameinfo_extract"] = needs_gameinfo

    if needs_gameinfo:
        run_step(
            runner,
            "gameinfo extract",
            tool_argv(opts.repo_root, "gameinfo-gen/gameinfo.py", "extract"),
        )
        gi_final = run_checks(
            runner, opts, "gameinfo check (final)", "gameinfo-gen/gameinfo.py"
        )
        if gi_final.returncode != 0:
            raise UpdateError("gameinfo", "gameinfo check failed after extract")

    needs_full_index = has_zip_changes or needs_gameinfo
    if not needs_full_index:
        fi_check = run_checks(
            runner, opts, "full-index check", "full-index-gen/full_index_gen.py"
        )
        needs_full_index = fi_check.returncode != 0
    report.actions["full_index_run"] = needs_full_index

    if needs_full_index:
        run_step(
            runner,
            "full-index run",
            tool_argv(opts.repo_root, "full-index-gen/full_index_gen.py", "run"),
        )
        fi_final = run_checks(
            runner, opts, "full-index check (final)", "full-index-gen/full_index_gen.py"
        )
        if fi_final.returncode != 0:
            raise UpdateError("full-index", "full-index check failed after run")

    needs_crew = not opts.no_crew and (needs_gameinfo or cracked_changed)
    report.actions["crew_analysis"] = needs_crew
    if needs_crew:
        run_step(
            runner,
            "crew-analysis",
            tool_argv(opts.repo_root, "crew-analysis/crew_analysis.py"),
        )

    catalog_changed = bool(
        has_zip_changes or needs_gameinfo or needs_full_index or needs_crew
    )
    report.actions["catalog_changed"] = catalog_changed
    if opts.skip_publish:
        report.actions["publish"] = "skipped"
        report.publish = {"status": "skipped", "reason": "--skip-publish"}
        print("\npublish: skipped (--skip-publish)", flush=True)
    elif not catalog_changed and not publish_pending(opts):
        report.actions["publish"] = "skipped"
        report.publish = {"status": "skipped", "reason": "unchanged"}
        print("\npublish: skipped (no catalog changes)", flush=True)
    else:
        report.publish = publish_gameinfo(runner, opts)
        report.actions["publish"] = report.publish.get("status", "unknown")

    report.status = "ok"
    print("\n=== catalog-update summary ===", flush=True)
    print(f"status: {report.status}", flush=True)
    print(f"sync new/changed: {counts.get('new', 0)}/{counts.get('changed', 0)}", flush=True)
    print(f"gameinfo extract: {report.actions.get('gameinfo_extract')}", flush=True)
    print(f"full-index run: {report.actions.get('full_index_run')}", flush=True)
    print(f"crew-analysis: {report.actions.get('crew_analysis')}", flush=True)
    print(f"catalog changed: {report.actions.get('catalog_changed')}", flush=True)
    print(f"publish: {report.actions.get('publish')}", flush=True)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="catalog-update",
        description="Run the local catalog update pipeline once.",
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="run",
        choices=["run"],
        help="run the pipeline (default)",
    )
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        help="sync only this relative prefix (repeatable; passed to archive-sync)",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="exclude a name/path glob (repeatable; passed to archive-sync)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="run archive-sync plan and read-only checks; write nothing",
    )
    parser.add_argument(
        "--skip-publish",
        action="store_true",
        help="update the local catalog without packaging/uploading gameinfo",
    )
    parser.add_argument(
        "--no-crew",
        action="store_true",
        help="skip crew-analysis even when its inputs changed",
    )
    parser.add_argument(
        "--report-dir",
        default="",
        help=f"run report directory (default: {DEFAULT_REPORT_DIR})",
    )
    parser.add_argument(
        "--sync-report-dir",
        default="",
        help=f"archive-sync report directory (default: {DEFAULT_SYNC_REPORT_DIR})",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"catalog-update {TOOL_VERSION}",
    )
    return parser


def build_options(args: argparse.Namespace) -> Options:
    root = env("MARCER_ROOT_DIR")
    patch = env("MARCER_PATCH_DIR")
    data = env("MARCER_DATA_DIR")
    if not root or not patch or not data:
        raise UpdateError(
            "config",
            "MARCER_ROOT_DIR, MARCER_PATCH_DIR and MARCER_DATA_DIR must be set "
            "(add them to local/paths.env)",
        )
    report_dir = (
        Path(args.report_dir).expanduser()
        if args.report_dir
        else DEFAULT_REPORT_DIR
    )
    sync_report_dir = (
        Path(args.sync_report_dir).expanduser()
        if args.sync_report_dir
        else DEFAULT_SYNC_REPORT_DIR
    )
    return Options(
        repo_root=Path(__file__).resolve().parents[2],
        root=Path(root).expanduser(),
        patch=Path(patch).expanduser(),
        data_dir=Path(data).expanduser(),
        only=tuple(args.only or ()),
        excludes=tuple(args.exclude or ()),
        dry_run=bool(args.dry_run),
        skip_publish=bool(args.skip_publish),
        no_crew=bool(args.no_crew),
        report_dir=report_dir,
        sync_report_dir=sync_report_dir,
    )


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        opts = build_options(args)
    except UpdateError as exc:
        print(f"catalog-update error [{exc.stage}]: {exc}", file=sys.stderr)
        return 2
    return run_update(opts, CommandRunner())


if __name__ == "__main__":
    raise SystemExit(main())
