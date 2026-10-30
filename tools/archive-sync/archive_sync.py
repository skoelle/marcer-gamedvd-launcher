#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Marcer GameDVD archive sync.

Downloads new or size-changed files from the Marcer FTP into the patch layer
(``MARCER_PATCH_DIR``).  The root layer is only used as a comparison base; it
is never modified.  Every run compares the remote tree against the local
union (root + patch) and writes a report; no persistent comparison state is
kept.

Commands::

    run.sh plan
    run.sh sync
    run.sh status

Detection is deliberately size-based.  Remote modification times are stored
and reported as diagnostics, but do not trigger downloads.  Unlike the old
Node.js ftp-sync, this tool has no interactive UI and no forced re-download
after an idle minute.
"""

from __future__ import annotations

import argparse
import calendar
import fnmatch
import json
import os
import posixpath
import queue
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from ftplib import FTP, all_errors as FTP_ALL_ERRORS, error_perm, error_temp
from pathlib import Path, PurePosixPath

TOOL_VERSION = "0.2.0"
REPORT_SCHEMA = 2
DEFAULT_REMOTE = "/GameDVD/"
DEFAULT_EXCLUDES = (
    "@eaDir",
    ".DS_Store",
    "Thumbs.db",
    "__MACOSX",
    "*.tmp",
    "*.part",
)
MLSD_TIME_FORMATS = (
    "%Y%m%d%H%M%S.%f",
    "%Y%m%d%H%M%S",
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S",
)


class ConfigError(Exception):
    pass


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def iso_now() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def split_host_port(raw: str, default_port: int = 21) -> tuple[str, int]:
    raw = raw.strip()
    if raw.startswith("["):
        end = raw.find("]")
        host = raw[1:end] if end > 0 else raw
        rest = raw[end + 1 :] if end > 0 else ""
        if rest.startswith(":") and rest[1:].isdigit():
            return host, int(rest[1:])
        return host, default_port
    if raw.count(":") == 1:
        head, tail = raw.rsplit(":", 1)
        if tail.isdigit():
            return head, int(tail)
    return raw, default_port


def normalize_remote(raw: str | None) -> str:
    value = (raw or DEFAULT_REMOTE).strip() or DEFAULT_REMOTE
    value = "/" + value.lstrip("/")
    value = value.rstrip("/")
    if not value:
        return "/"
    return value + "/" if value != "/" else "/"


def normalize_rel(raw: str | None) -> str | None:
    if raw is None:
        return None
    value = str(raw).strip()
    if not value or "\x00" in value or "\\" in value or value.startswith("/"):
        return None
    value = value.rstrip("/")
    if not value:
        return None
    path = PurePosixPath(value)
    if path.is_absolute():
        return None
    parts = path.parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        return None
    return path.as_posix()


def normalize_remote_prefix(raw: str) -> str | None:
    return normalize_rel(str(raw).strip().lstrip("/"))


def normalize_prefixes(values) -> tuple[str, ...]:
    result = []
    for value in values or ():
        for part in str(value).split(","):
            prefix = normalize_remote_prefix(part)
            if prefix and prefix not in result:
                result.append(prefix)
    return tuple(result)


def split_list(raw: str) -> list[str]:
    return [part.strip() for part in raw.split(",") if part.strip()]


def matches_exclude(rel: str, patterns: tuple[str, ...]) -> bool:
    low = rel.lower()
    components = low.split("/")
    for pattern in patterns:
        value = pattern.strip().strip("/").lower()
        if not value:
            continue
        if "/" in value:
            if fnmatch.fnmatchcase(low, value):
                return True
        elif any(fnmatch.fnmatchcase(component, value) for component in components):
            return True
    return False


def in_only(rel: str, only: tuple[str, ...]) -> bool:
    if not only:
        return True
    low = rel.lower()
    return any(
        low == prefix.lower() or low.startswith(prefix.lower() + "/")
        for prefix in only
    )


def dir_may_match(rel: str, only: tuple[str, ...]) -> bool:
    if not only:
        return True
    low = rel.lower()
    for prefix in only:
        value = prefix.lower()
        if low == value or low.startswith(value + "/") or value.startswith(low + "/"):
            return True
    return False


def in_scope(rel: str, only: tuple[str, ...], excludes: tuple[str, ...]) -> bool:
    return in_only(rel, only) and not matches_exclude(rel, excludes)


def parse_remote_mtime(value: str | None) -> float | None:
    if not value:
        return None
    text = value.strip()
    for fmt in MLSD_TIME_FORMATS:
        try:
            parsed = datetime.strptime(text, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        return calendar.timegm(parsed.utctimetuple()) + parsed.microsecond / 1e6
    return None


def safe_dest(patch: Path, rel: str) -> Path:
    normalized = normalize_rel(rel)
    if normalized is None:
        raise ValueError(f"unsafe relative path: {rel!r}")
    patch_root = patch.resolve()
    dest = (patch_root / normalized).resolve()
    if dest == patch_root or not dest.is_relative_to(patch_root):
        raise ValueError(f"path escapes patch directory: {rel!r}")
    return dest


def atomic_write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=1, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=".txt")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load_json(path: Path) -> dict:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("top-level JSON value is not an object")
    return data


def resolve_report_dir(arg: str | None) -> Path:
    value = arg or env("MARCER_SYNC_REPORT_DIR")
    return Path(value) if value else repo_root() / "local" / "archive-sync"


def parse_int(value, default: int, minimum: int = 0) -> int:
    if value is None or value == "":
        return default
    number = int(value)
    if number < minimum:
        raise ConfigError(f"value must be >= {minimum}: {value}")
    return number


@dataclass(frozen=True)
class RemoteFile:
    rel: str
    remote_path: str
    size: int | None
    mtime: str | None


@dataclass(frozen=True)
class LocalFile:
    rel: str
    layer: str
    size: int
    path: Path


@dataclass(frozen=True)
class Download:
    remote: RemoteFile
    dest_rel: str
    reason: str
    local: LocalFile | None


@dataclass
class SyncPlan:
    remote: dict[str, RemoteFile]
    local: dict[str, LocalFile]
    new: list[RemoteFile]
    changed: list[RemoteFile]
    in_sync_count: int
    unknown_size: list[RemoteFile]
    local_only: list[LocalFile]
    downloads: list[Download]
    case_conflicts: list[str]
    local_conflicts: list[str]
    warnings: list[str]
    incomplete_dirs: list[str]


@dataclass
class Config:
    root: Path | None
    patch: Path
    report_dir: Path
    remote: str
    host: str
    port: int
    user: str
    password: str
    encoding: str
    timeout: int
    retries: int
    passive: bool
    max_depth: int
    workers: int
    only: tuple[str, ...]
    excludes: tuple[str, ...]
    force: bool
    verbose: bool
    report_limit: int


@dataclass(frozen=True)
class DirEntry:
    name: str
    path: str
    kind: str
    size: int | None
    modify: str | None


class FtpClient:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.ftp: FTP | None = None

    def connect(self) -> None:
        if self.ftp is not None:
            return
        ftp = FTP()
        ftp.encoding = self.cfg.encoding
        ftp.connect(self.cfg.host, self.cfg.port, timeout=self.cfg.timeout)
        ftp.login(self.cfg.user or "anonymous", self.cfg.password or "")
        ftp.set_pasv(self.cfg.passive)
        self.ftp = ftp

    def close(self) -> None:
        if self.ftp is not None:
            try:
                self.ftp.quit()
            except Exception:  # noqa: BLE001 - best effort close
                try:
                    self.ftp.close()
                except Exception:  # noqa: BLE001 - best effort close
                    pass
            self.ftp = None

    def _with_retry(self, action, description: str):
        last: Exception | None = None
        for attempt in range(self.cfg.retries + 1):
            try:
                self.connect()
                return action()
            except FTP_ALL_ERRORS as exc:
                last = exc
                self.close()
                if attempt >= self.cfg.retries:
                    break
                delay = min(2**attempt, 10)
                print(
                    f"warning: {description} failed ({exc}); "
                    f"retrying in {delay}s",
                    file=sys.stderr,
                )
                time.sleep(delay)
        raise RuntimeError(
            f"{description} failed after {self.cfg.retries + 1} attempt(s): {last}"
        ) from last

    @staticmethod
    def _mlsd_unsupported(exc: Exception) -> bool:
        return str(exc)[:3] in {"500", "501", "502", "504"}

    def list_dir(self, path: str) -> list[DirEntry]:
        return self._with_retry(
            lambda: self._list_once(path),
            f"listing {path}",
        )

    def _list_once(self, path: str) -> list[DirEntry]:
        assert self.ftp is not None
        try:
            rows = list(self.ftp.mlsd(path))
        except error_perm as exc:
            if not self._mlsd_unsupported(exc):
                raise
            return self._list_fallback(path)
        except error_temp:
            raise

        result: list[DirEntry] = []
        for name, facts in rows:
            if name in (".", ".."):
                continue
            kind = facts.get("type")
            if kind in ("cdir", "pdir"):
                continue
            full = self._join_remote(path, name)
            modify = facts.get("modify")
            if kind == "dir":
                result.append(DirEntry(name, full, "dir", None, modify))
            elif kind in (None, "file"):
                size = facts.get("size")
                result.append(
                    DirEntry(
                        name,
                        full,
                        "file",
                        int(size) if str(size or "").isdigit() else None,
                        modify,
                    )
                )
            else:
                result.append(DirEntry(name, full, "skip", None, modify))
        return result

    def _list_fallback(self, path: str) -> list[DirEntry]:
        assert self.ftp is not None
        result: list[DirEntry] = []
        for raw in self.ftp.nlst(path):
            name = posixpath.basename(str(raw).rstrip("/"))
            if not name or name in (".", ".."):
                continue
            full = self._join_remote(path, name)
            size = None
            try:
                self.ftp.voidcmd("TYPE I")
                size = self.ftp.size(full)
            except Exception:  # noqa: BLE001 - size probe is best effort
                size = None
            if size is not None:
                result.append(DirEntry(name, full, "file", int(size), None))
                continue
            try:
                self.ftp.cwd(full)
                self.ftp.cwd(path)
                result.append(DirEntry(name, full, "dir", None, None))
            except Exception:  # noqa: BLE001 - treat as file
                result.append(DirEntry(name, full, "file", None, None))
        return result

    @staticmethod
    def _join_remote(path: str, name: str) -> str:
        return posixpath.join(path, name) if path != "/" else "/" + name

    def retr(self, remote_path: str, fileobj) -> None:
        def action():
            assert self.ftp is not None
            fileobj.seek(0)
            fileobj.truncate(0)
            self.ftp.retrbinary(f"RETR {remote_path}", fileobj.write)

        self._with_retry(action, f"download {remote_path}")


@dataclass
class RemoteScan:
    files: dict[str, RemoteFile]
    case_conflicts: list[str]
    warnings: list[str]
    incomplete: list[str]


def _prepare_entries(
    entries: list[DirEntry],
    rel_dir: str,
    depth: int,
    cfg: Config,
) -> tuple[list[RemoteFile], list[tuple[str, str, int]], list[str]]:
    file_items: list[RemoteFile] = []
    dirs: list[tuple[str, str, int]] = []
    warnings: list[str] = []
    for entry in sorted(entries, key=lambda item: (item.name.casefold(), item.name)):
        rel = normalize_rel(
            posixpath.join(rel_dir, entry.name) if rel_dir else entry.name
        )
        if rel is None:
            warnings.append(f"skipping unsafe remote name: {entry.name!r}")
            continue
        if matches_exclude(rel, cfg.excludes):
            continue
        if entry.kind == "dir":
            if not dir_may_match(rel, cfg.only):
                continue
            if depth >= cfg.max_depth:
                warnings.append(f"max depth reached at: {rel}")
                continue
            dirs.append((entry.path, rel, depth + 1))
        elif entry.kind == "file":
            if in_only(rel, cfg.only):
                file_items.append(
                    RemoteFile(rel, entry.path, entry.size, entry.modify)
                )
        else:
            warnings.append(f"skipping non-file remote entry: {rel}")
    return file_items, dirs, warnings


def _merge_file(
    files: dict[str, RemoteFile],
    case_index: dict[str, str],
    conflicts: list[str],
    item: RemoteFile,
) -> None:
    key = item.rel.lower()
    existing_rel = case_index.get(key)
    if existing_rel is None:
        case_index[key] = item.rel
        files[item.rel] = item
        return
    winner = min(existing_rel, item.rel, key=lambda value: (value.casefold(), value))
    if winner == item.rel and winner != existing_rel:
        files.pop(existing_rel, None)
        files[winner] = item
        case_index[key] = winner
    conflicts.append(
        f"{existing_rel!r} conflicts with {item.rel!r} "
        f"(case-insensitive match; keeping {winner!r})"
    )


def scan_remote(client: FtpClient, cfg: Config) -> RemoteScan:
    if cfg.workers <= 1:
        return _scan_remote_sequential(client, cfg)
    return _scan_remote_parallel(cfg)


def _scan_remote_sequential(client: FtpClient, cfg: Config) -> RemoteScan:
    files: dict[str, RemoteFile] = {}
    case_index: dict[str, str] = {}
    case_conflicts: list[str] = []
    warnings: list[str] = []
    incomplete: set[str] = set()
    seen_dirs: set[str] = set()
    stack: list[tuple[str, str, int]] = [(cfg.remote, "", 0)]
    dirs_scanned = 0
    started = time.monotonic()
    scope = ", ".join(cfg.only) if cfg.only else cfg.remote
    if cfg.verbose:
        print(f"remote scan: {scope}", file=sys.stderr, flush=True)

    while stack:
        remote_dir, rel_dir, depth = stack.pop()
        if remote_dir in seen_dirs:
            warnings.append(f"skipping repeated remote directory: {remote_dir}")
            continue
        seen_dirs.add(remote_dir)
        dirs_scanned += 1
        if cfg.verbose and dirs_scanned % 100 == 0:
            print(
                f"remote scan: {dirs_scanned} dirs, {len(files)} files, "
                f"{time.monotonic() - started:.0f}s",
                file=sys.stderr,
                flush=True,
            )
        try:
            entries = client.list_dir(remote_dir)
        except Exception as exc:  # noqa: BLE001 - never report local-only under it
            warnings.append(f"cannot list {remote_dir}: {exc}")
            incomplete.add(rel_dir)
            continue

        file_items, dirs, prepared_warnings = _prepare_entries(
            entries, rel_dir, depth, cfg
        )
        warnings.extend(prepared_warnings)
        for item in file_items:
            _merge_file(files, case_index, case_conflicts, item)
        stack.extend(dirs)

    if cfg.verbose:
        print(
            f"remote scan done: {dirs_scanned} dirs, {len(files)} files, "
            f"{time.monotonic() - started:.1f}s",
            file=sys.stderr,
            flush=True,
        )
    return RemoteScan(files, case_conflicts, warnings, sorted(incomplete))


def _scan_remote_parallel(cfg: Config) -> RemoteScan:
    files: dict[str, RemoteFile] = {}
    case_index: dict[str, str] = {}
    case_conflicts: list[str] = []
    warnings: list[str] = []
    incomplete: set[str] = set()
    seen_dirs: set[str] = set()
    lock = threading.Lock()
    stop = threading.Event()
    work: queue.Queue = queue.Queue()
    work.put((cfg.remote, "", 0))
    dirs_scanned = 0
    started = time.monotonic()
    scope = ", ".join(cfg.only) if cfg.only else cfg.remote
    if cfg.verbose:
        print(
            f"remote scan: {scope} ({cfg.workers} workers)",
            file=sys.stderr,
            flush=True,
        )

    def worker() -> None:
        nonlocal dirs_scanned
        client = FtpClient(cfg)
        try:
            while not stop.is_set():
                try:
                    item = work.get(timeout=0.5)
                except queue.Empty:
                    continue
                if item is None:
                    work.task_done()
                    return
                remote_dir, rel_dir, depth = item
                try:
                    with lock:
                        if remote_dir in seen_dirs:
                            warnings.append(
                                f"skipping repeated remote directory: {remote_dir}"
                            )
                            continue
                        seen_dirs.add(remote_dir)
                        dirs_scanned += 1
                    try:
                        entries = client.list_dir(remote_dir)
                    except Exception as exc:  # noqa: BLE001 - keep the sync safe
                        with lock:
                            warnings.append(f"cannot list {remote_dir}: {exc}")
                            incomplete.add(rel_dir)
                        continue
                    file_items, dirs, prepared_warnings = _prepare_entries(
                        entries, rel_dir, depth, cfg
                    )
                    with lock:
                        warnings.extend(prepared_warnings)
                        for file_item in file_items:
                            _merge_file(
                                files, case_index, case_conflicts, file_item
                            )
                        for dir_item in dirs:
                            work.put(dir_item)
                        if cfg.verbose and dirs_scanned % 100 == 0:
                            print(
                                f"remote scan: {dirs_scanned} dirs, "
                                f"{len(files)} files, "
                                f"{time.monotonic() - started:.0f}s",
                                file=sys.stderr,
                                flush=True,
                            )
                except Exception as exc:  # noqa: BLE001 - a worker must not die
                    with lock:
                        warnings.append(
                            f"worker error in {rel_dir or cfg.remote}: {exc}"
                        )
                        incomplete.add(rel_dir)
                finally:
                    work.task_done()
        finally:
            client.close()

    threads = [
        threading.Thread(target=worker, name=f"archive-sync-{index}", daemon=True)
        for index in range(cfg.workers)
    ]
    for thread in threads:
        thread.start()
    try:
        work.join()
    except KeyboardInterrupt:
        stop.set()
        raise
    finally:
        if not stop.is_set():
            for _ in threads:
                work.put(None)
        for thread in threads:
            thread.join(timeout=10)

    if cfg.verbose:
        print(
            f"remote scan done: {dirs_scanned} dirs, {len(files)} files, "
            f"{time.monotonic() - started:.1f}s",
            file=sys.stderr,
            flush=True,
        )
    return RemoteScan(files, case_conflicts, warnings, sorted(incomplete))


def scan_local_layer(
    base: Path | None,
    layer: str,
    index: dict[str, LocalFile],
    conflicts: list[str],
    warnings: list[str],
    only: tuple[str, ...] = (),
    verbose: bool = True,
) -> None:
    if base is None:
        return
    if not base.is_dir():
        warnings.append(f"{layer.lower()} directory not found: {base}")
        return

    stack: list[tuple[Path, str]] = [(base, "")]
    dirs_scanned = 0
    started = time.monotonic()
    if verbose:
        print(f"local scan {layer}: {base}", file=sys.stderr, flush=True)
    while stack:
        directory, rel_dir = stack.pop()
        dirs_scanned += 1
        if verbose and dirs_scanned % 250 == 0:
            print(
                f"local scan {layer}: {dirs_scanned} dirs, {len(index)} files, "
                f"{time.monotonic() - started:.0f}s",
                file=sys.stderr,
                flush=True,
            )
        try:
            with os.scandir(directory) as iterator:
                entries = sorted(iterator, key=lambda item: item.name.casefold())
        except OSError as exc:
            warnings.append(f"cannot list {directory}: {exc}")
            continue
        for entry in entries:
            rel = normalize_rel(
                posixpath.join(rel_dir, entry.name) if rel_dir else entry.name
            )
            if rel is None:
                warnings.append(f"skipping unsafe local name: {entry.name!r}")
                continue
            if entry.is_symlink():
                warnings.append(f"skipping local symlink: {rel}")
                continue
            if entry.is_dir(follow_symlinks=False):
                if dir_may_match(rel, only):
                    stack.append((Path(entry.path), rel))
                continue
            if not in_only(rel, only):
                continue
            if not entry.is_file(follow_symlinks=False):
                continue
            if entry.name.endswith(".part"):
                continue
            try:
                stat = entry.stat(follow_symlinks=False)
            except OSError as exc:
                warnings.append(f"cannot stat {entry.path}: {exc}")
                continue
            key = rel.lower()
            item = LocalFile(rel, layer, stat.st_size, Path(entry.path))
            previous = index.get(key)
            if previous is None:
                index[key] = item
            elif previous.layer == "ROOT" and layer == "PATCH":
                index[key] = item
            elif previous.layer == layer and previous.rel != rel:
                conflicts.append(
                    f"{layer}: {previous.rel!r} conflicts with {rel!r} "
                    "(case-insensitive match; keeping the first)"
                )
    if verbose:
        print(
            f"local scan {layer} done: {dirs_scanned} dirs, {len(index)} files, "
            f"{time.monotonic() - started:.1f}s",
            file=sys.stderr,
            flush=True,
        )


def scan_local(cfg: Config) -> tuple[dict[str, LocalFile], list[str], list[str]]:
    index: dict[str, LocalFile] = {}
    conflicts: list[str] = []
    warnings: list[str] = []
    scan_local_layer(
        cfg.root, "ROOT", index, conflicts, warnings, cfg.only, cfg.verbose
    )
    scan_local_layer(
        cfg.patch, "PATCH", index, conflicts, warnings, cfg.only, cfg.verbose
    )
    return index, conflicts, warnings


def under_incomplete(rel: str, incomplete: tuple[str, ...]) -> bool:
    if not incomplete:
        return False
    if "" in incomplete:
        return True
    return any(rel == prefix or rel.startswith(prefix + "/") for prefix in incomplete)


def build_plan(
    remote: dict[str, RemoteFile],
    local: dict[str, LocalFile],
    cfg: Config,
    case_conflicts: list[str],
    local_conflicts: list[str],
    warnings: list[str],
    incomplete: tuple[str, ...] = (),
) -> SyncPlan:
    new: list[RemoteFile] = []
    changed: list[RemoteFile] = []
    unknown_size: list[RemoteFile] = []
    local_only: list[LocalFile] = []
    downloads: list[Download] = []
    in_sync_count = 0
    remote_lower = {rel.lower() for rel in remote}

    for rel in sorted(remote, key=str.casefold):
        current = remote[rel]
        local_entry = local.get(rel.lower())
        reason = None
        if local_entry is None:
            new.append(current)
            reason = "missing"
        elif current.size is None:
            unknown_size.append(current)
            reason = "unknown_size"
        elif local_entry.size != current.size:
            changed.append(current)
            reason = "size_mismatch"
        else:
            in_sync_count += 1

        if cfg.force:
            downloads.append(
                Download(
                    current,
                    local_entry.rel if local_entry else current.rel,
                    "forced",
                    local_entry,
                )
            )
        elif reason is not None:
            downloads.append(
                Download(
                    current,
                    local_entry.rel if local_entry else current.rel,
                    reason,
                    local_entry,
                )
            )

    for item in sorted(local.values(), key=lambda value: value.rel.casefold()):
        if item.rel.lower() in remote_lower:
            continue
        if not in_scope(item.rel, cfg.only, cfg.excludes):
            continue
        if under_incomplete(item.rel, incomplete):
            continue
        local_only.append(item)

    return SyncPlan(
        remote=remote,
        local=local,
        new=new,
        changed=changed,
        in_sync_count=in_sync_count,
        unknown_size=unknown_size,
        local_only=local_only,
        downloads=downloads,
        case_conflicts=case_conflicts,
        local_conflicts=local_conflicts,
        warnings=warnings,
        incomplete_dirs=list(incomplete),
    )


def execute_downloads(
    client: FtpClient, cfg: Config, downloads: list[Download]
) -> tuple[list[dict], list[dict]]:
    done: list[dict] = []
    errors: list[dict] = []
    total = len(downloads)
    for index, item in enumerate(downloads, 1):
        started = time.monotonic()
        part: Path | None = None
        try:
            dest = safe_dest(cfg.patch, item.dest_rel)
            dest.parent.mkdir(parents=True, exist_ok=True)
            part = dest.with_name(dest.name + ".part")
            if part.exists():
                part.unlink()
            if cfg.verbose:
                print(
                    f"[{index}/{total}] {item.remote.rel} "
                    f"({item.reason}, {item.remote.size or '?'} bytes)",
                    flush=True,
                )
            with open(part, "wb") as handle:
                client.retr(item.remote.remote_path, handle)
            if item.remote.size is not None:
                actual = part.stat().st_size
                if actual != item.remote.size:
                    raise IOError(
                        f"size mismatch: expected {item.remote.size}, got {actual}"
                    )
            timestamp = parse_remote_mtime(item.remote.mtime)
            if timestamp is not None:
                os.utime(part, (time.time(), timestamp))
            os.replace(part, dest)
            done.append(
                {
                    "path": item.remote.rel,
                    "dest": item.dest_rel,
                    "size": item.remote.size,
                    "reason": item.reason,
                    "seconds": round(time.monotonic() - started, 3),
                }
            )
        except Exception as exc:  # noqa: BLE001 - one failure must not stop the run
            if part is not None:
                try:
                    if part.exists():
                        part.unlink()
                except OSError:
                    pass
            errors.append({"path": item.remote.rel, "error": str(exc)})
            print(f"error: {item.remote.rel}: {exc}", file=sys.stderr)
    return done, errors


def change_entry(remote: RemoteFile) -> dict:
    return {
        "path": remote.rel,
        "size": remote.size,
        "mtime": remote.mtime,
    }


def build_report(
    cfg: Config,
    plan: SyncPlan,
    downloaded: list[dict],
    errors: list[dict],
    duration_s: float,
    mode: str,
) -> dict:
    counts = {
        "remote_files": len(plan.remote),
        "new": len(plan.new),
        "changed": len(plan.changed),
        "in_sync": plan.in_sync_count,
        "unknown_size": len(plan.unknown_size),
        "local_only": len(plan.local_only),
        "downloads": len(plan.downloads),
        "downloaded": len(downloaded),
        "download_errors": len(errors),
        "case_conflicts": len(plan.case_conflicts),
        "local_conflicts": len(plan.local_conflicts),
        "warnings": len(plan.warnings),
        "incomplete_dirs": len(plan.incomplete_dirs),
    }
    changed = []
    for item in plan.changed:
        local_item = plan.local.get(item.rel.lower())
        changed.append(
            {
                **change_entry(item),
                "local_size": local_item.size if local_item else None,
                "local_rel": local_item.rel if local_item else None,
                "layer": local_item.layer if local_item else None,
            }
        )
    return {
        "schema": REPORT_SCHEMA,
        "tool": "archive-sync",
        "tool_version": TOOL_VERSION,
        "generated_at": iso_now(),
        "mode": mode,
        "remote": cfg.remote,
        "local": {
            "root": str(cfg.root) if cfg.root else None,
            "patch": str(cfg.patch),
        },
        "duration_s": round(duration_s, 3),
        "counts": counts,
        "new": [change_entry(item) for item in plan.new],
        "changed": changed,
        "unknown_size": [change_entry(item) for item in plan.unknown_size],
        "local_only": [
            {
                "path": item.rel,
                "size": item.size,
                "layer": item.layer,
            }
            for item in plan.local_only
        ],
        "downloads": [
            {
                "path": item.remote.rel,
                "dest": item.dest_rel,
                "size": item.remote.size,
                "reason": item.reason,
            }
            for item in plan.downloads
        ],
        "downloaded": downloaded,
        "download_errors": errors,
        "case_conflicts": plan.case_conflicts,
        "local_conflicts": plan.local_conflicts,
        "warnings": plan.warnings,
        "incomplete_dirs": plan.incomplete_dirs,
    }


def render_report(report: dict, limit: int = 0) -> str:
    counts = report["counts"]
    lines = [
        f"Archive sync report — {report['generated_at']}",
        f"mode: {report['mode']}",
        f"remote: {report['remote']}",
        f"root: {report['local']['root'] or '-'}",
        f"patch: {report['local']['patch']}",
        "",
        f"remote files: {counts['remote_files']}",
        f"new (missing locally): {counts['new']}",
        f"changed (size differs): {counts['changed']}",
        f"in sync: {counts['in_sync']}",
        f"unknown size: {counts['unknown_size']}",
        f"local only (not on remote): {counts['local_only']}",
        f"planned downloads: {counts['downloads']}",
        f"downloaded: {counts['downloaded']}",
        f"download errors: {counts['download_errors']}",
        f"case conflicts: {counts['case_conflicts']}",
        f"local conflicts: {counts['local_conflicts']}",
        f"warnings: {counts['warnings']}",
        f"incomplete directories: {counts['incomplete_dirs']}",
        "",
        "Comparison is current local vs remote; no persistent state is used.",
        "Downloads are based on remote size. mtime is diagnostic only.",
    ]

    def section(title: str, items: list[str]) -> None:
        shown = items[:limit] if limit else items
        lines.extend(["", f"--- {title} ({len(items)})", *shown])
        if limit and len(items) > limit:
            lines.append(f"... {len(items) - limit} more")

    new = [f"{item['path']} ({item['size'] or '?'} bytes)" for item in report["new"]]
    changed = [
        f"{item['path']} (local {item['local_size'] or '?'} -> remote "
        f"{item['size'] or '?'} bytes)"
        for item in report["changed"]
    ]
    unknown = [
        f"{item['path']} ({item['mtime'] or 'no mtime'})"
        for item in report["unknown_size"]
    ]
    local_only = [
        f"{item['path']} ({item['size'] or '?'} bytes, {item['layer']})"
        for item in report["local_only"]
    ]
    downloads = [
        f"{item['path']} -> {item['dest']} ({item['reason']})"
        for item in report["downloads"]
    ]
    downloaded = [
        f"{item['path']} -> {item['dest']} ({item['seconds']}s)"
        for item in report["downloaded"]
    ]
    errors = [f"{item['path']}: {item['error']}" for item in report["download_errors"]]

    section("New (missing locally)", new)
    section("Changed (size differs)", changed)
    section("Unknown size (downloaded)", unknown)
    section("Local only (not on remote; kept)", local_only)
    section("Planned downloads", downloads)
    section("Downloaded", downloaded)
    section("Download errors", errors)
    section(
        "Incomplete directories (local-only reporting suppressed)",
        list(report["incomplete_dirs"]),
    )
    section(
        "Warnings",
        list(report["warnings"] + report["case_conflicts"] + report["local_conflicts"]),
    )
    return "\n".join(lines) + "\n"


def print_summary(report: dict) -> None:
    counts = report["counts"]
    print(f"archive-sync {TOOL_VERSION} ({report['mode']})")
    print(f"remote: {report['remote']}")
    print(f"root:   {report['local']['root'] or '-'}")
    print(f"patch:  {report['local']['patch']}")
    print(f"remote files: {counts['remote_files']}")
    print(
        "new: {new}  changed: {changed}  in sync: {in_sync}  "
        "unknown size: {unknown_size}  local only: {local_only}".format(**counts)
    )
    print(
        "downloads: {downloads}  errors: {download_errors}".format(**counts)
    )
    if (
        counts["case_conflicts"]
        or counts["local_conflicts"]
        or counts["warnings"]
        or counts["incomplete_dirs"]
    ):
        print(
            "warnings: {warnings}  case conflicts: {case_conflicts}  "
            "local conflicts: {local_conflicts}  incomplete dirs: "
            "{incomplete_dirs}".format(**counts)
        )
        messages = (
            report["warnings"] + report["case_conflicts"] + report["local_conflicts"]
        )
        for message in messages[:5]:
            print(f"  warning: {message}")
        if len(messages) > 5:
            print(f"  ... {len(messages) - 5} more warnings")


def run_sync(cfg: Config, dry_run: bool) -> int:
    started = time.monotonic()
    if not dry_run:
        cfg.patch.mkdir(parents=True, exist_ok=True)

    client = FtpClient(cfg)
    try:
        scan = scan_remote(client, cfg)
        remote = scan.files
        local, local_conflicts, local_warnings = scan_local(cfg)
        warnings = list(scan.warnings) + local_warnings
        plan = build_plan(
            remote,
            local,
            cfg,
            scan.case_conflicts,
            local_conflicts,
            warnings,
            tuple(scan.incomplete),
        )
        if dry_run:
            report = build_report(
                cfg, plan, [], [], time.monotonic() - started, mode="plan"
            )
            print_summary(report)
            return 1 if scan.incomplete else 0

        downloaded, errors = execute_downloads(client, cfg, plan.downloads)
        report = build_report(
            cfg, plan, downloaded, errors, time.monotonic() - started, mode="sync"
        )
        cfg.report_dir.mkdir(parents=True, exist_ok=True)
        atomic_write_json(cfg.report_dir / "changes.json", report)
        atomic_write_text(
            cfg.report_dir / "changes.txt",
            render_report(report, cfg.report_limit),
        )
        print_summary(report)
        print(f"changes: {cfg.report_dir / 'changes.json'}")
        return 0 if not errors and not scan.incomplete else 1
    finally:
        client.close()


def cmd_status(args) -> int:
    report_dir = resolve_report_dir(args.report_dir)
    changes_path = report_dir / "changes.json"
    last_changes = None
    if changes_path.is_file():
        try:
            last_changes = load_json(changes_path)
        except (OSError, ValueError):
            last_changes = None
    counts = (last_changes or {}).get("counts") or {}
    summary = {
        "tool": "archive-sync",
        "tool_version": TOOL_VERSION,
        "report_dir": str(report_dir),
        "changes": str(changes_path) if changes_path.is_file() else None,
        "generated_at": (last_changes or {}).get("generated_at"),
        "mode": (last_changes or {}).get("mode"),
        "counts": counts,
        "incomplete_dirs": (last_changes or {}).get("incomplete_dirs") or [],
    }
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    print(f"archive-sync {TOOL_VERSION}")
    if not last_changes:
        print(f"report: {changes_path} (missing)")
        return 0
    print(f"report: {changes_path}")
    print(f"last run: {summary['generated_at']} ({summary['mode']})")
    print(
        "  remote files: {remote_files}  new: {new}  changed: {changed}  "
        "in sync: {in_sync}  local only: {local_only}".format(
            remote_files=counts.get("remote_files", 0),
            new=counts.get("new", 0),
            changed=counts.get("changed", 0),
            in_sync=counts.get("in_sync", 0),
            local_only=counts.get("local_only", 0),
        )
    )
    print(
        "  downloads: {downloads}  errors: {download_errors}  "
        "incomplete dirs: {incomplete_dirs}".format(
            downloads=counts.get("downloads", 0),
            download_errors=counts.get("download_errors", 0),
            incomplete_dirs=counts.get("incomplete_dirs", 0),
        )
    )
    return 0


def build_config(args) -> Config:
    root_raw = args.root or env("MARCER_ROOT_DIR")
    patch_raw = args.patch or env("MARCER_PATCH_DIR")
    if not patch_raw:
        raise ConfigError(
            "MARCER_PATCH_DIR is not set (add it to local/paths.env or pass --patch)"
        )
    host_raw = args.host or env("MARCER_FTP_HOST")
    if not host_raw:
        raise ConfigError(
            "MARCER_FTP_HOST is not set (add it to local/paths.env or pass --host)"
        )
    host, parsed_port = split_host_port(host_raw)
    port = parse_int(args.port, parsed_port, minimum=1)
    if port > 65535:
        raise ConfigError(f"port out of range: {port}")
    report_dir = resolve_report_dir(args.report_dir)

    env_excludes = split_list(env("MARCER_SYNC_EXCLUDES"))
    excludes = list(DEFAULT_EXCLUDES) + env_excludes + list(args.exclude or [])
    cleaned = []
    for pattern in excludes:
        value = pattern.strip()
        if value and value not in cleaned:
            cleaned.append(value)

    only = normalize_prefixes(split_list(env("MARCER_SYNC_ONLY")) + list(args.only or []))

    passive = True
    passive_env = env("MARCER_FTP_PASSIVE")
    if passive_env and passive_env.lower() in {"0", "false", "no", "off"}:
        passive = False
    if args.no_passive:
        passive = False

    return Config(
        root=Path(root_raw) if root_raw else None,
        patch=Path(patch_raw),
        report_dir=report_dir,
        remote=normalize_remote(args.remote or env("MARCER_FTP_REMOTE")),
        host=host,
        port=port,
        user=args.user if args.user is not None else env("MARCER_FTP_USER"),
        password=(
            args.ftp_pass if args.ftp_pass is not None else env("MARCER_FTP_PASS")
        ),
        encoding=args.encoding or env("MARCER_FTP_ENCODING") or "utf-8",
        timeout=parse_int(
            args.timeout or env("MARCER_FTP_TIMEOUT"), 60, minimum=1
        ),
        retries=parse_int(
            args.retries or env("MARCER_SYNC_RETRIES"), 3, minimum=0
        ),
        passive=passive,
        max_depth=parse_int(args.max_depth, 64, minimum=1),
        workers=parse_int(
            args.workers or env("MARCER_SYNC_WORKERS"), 4, minimum=1
        ),
        only=only,
        excludes=tuple(cleaned),
        force=args.force,
        verbose=not args.quiet,
        report_limit=parse_int(
            args.report_limit or env("MARCER_SYNC_REPORT_LIMIT"), 0, minimum=0
        ),
    )


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", help="root game tree (default: MARCER_ROOT_DIR)")
    parser.add_argument(
        "--patch", help="patch tree / sync target (default: MARCER_PATCH_DIR)"
    )
    parser.add_argument(
        "--report-dir",
        help="report directory (default: MARCER_SYNC_REPORT_DIR or "
        "local/archive-sync)",
    )
    parser.add_argument("--remote", help="remote base (default: MARCER_FTP_REMOTE)")
    parser.add_argument("--host", help="FTP host or host:port")
    parser.add_argument("--port", help="FTP port (overrides host:port)")
    parser.add_argument("--user", help="FTP user (default: MARCER_FTP_USER)")
    parser.add_argument("--ftp-pass", help="FTP password (default: MARCER_FTP_PASS)")
    parser.add_argument("--encoding", help="FTP encoding (default: utf-8)")
    parser.add_argument("--timeout", help="FTP timeout in seconds (default: 60)")
    parser.add_argument("--retries", help="retry count (default: 3)")
    parser.add_argument(
        "--no-passive", action="store_true", help="disable passive FTP mode"
    )
    parser.add_argument(
        "--max-depth", default=64, help="maximum remote directory depth (default: 64)"
    )
    parser.add_argument(
        "--workers",
        help="parallel FTP listing workers (default: 4)",
    )
    parser.add_argument(
        "--only",
        action="append",
        help="sync only this relative prefix (repeatable or comma-separated)",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        help="exclude a name/path glob (repeatable or comma-separated)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="download every selected remote file even when the size matches",
    )
    parser.add_argument(
        "--report-limit",
        help="limit list entries in changes.txt (0 = unlimited)",
    )
    parser.add_argument("-q", "--quiet", action="store_true", help="less progress output")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="archive-sync",
        description="Synchronise the Marcer FTP archive into the patch layer.",
    )
    parser.add_argument(
        "--version", action="version", version=f"archive-sync {TOOL_VERSION}"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    plan = sub.add_parser("plan", help="compare remote and local trees; write nothing")
    add_common_args(plan)

    sync = sub.add_parser("sync", help="download new/changed files into the patch tree")
    add_common_args(sync)
    sync.add_argument(
        "--dry-run", action="store_true", help="same as plan; write nothing"
    )

    status = sub.add_parser("status", help="show the last report")
    status.add_argument("--report-dir", help="report directory")
    status.add_argument("--json", action="store_true", help="machine-readable summary")
    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "status":
            return cmd_status(args)
        cfg = build_config(args)
        dry_run = args.command == "plan" or bool(getattr(args, "dry_run", False))
        return run_sync(cfg, dry_run=dry_run)
    except ConfigError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except Exception as exc:  # noqa: BLE001 - CLI boundary
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
