#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Marcer GameDVD catalog asset publisher.

Packages the catalog data directories into deterministic ZIP archives for the
desktop app and the ``catalog-latest`` release pointer.  This stage implements
the **gameinfo** asset: local packaging, optional FTP upload and the automatic
``latest.json`` pointer update.  Screenshot packaging follows later.

Usage::

    run.sh publish --only gameinfo              # local ZIP only
    run.sh publish --only gameinfo --upload     # ZIP + FTP upload + latest.json
    run.sh publish --only gameinfo --dry-run
    run.sh publish --only gameinfo --force

The source is ``<MARCER_DATA_DIR>/gameinfo``.  The ZIP is written to
``MARCER_ASSET_OUT_DIR`` (default: ``MARCER_DATA_DIR`` itself, next to the
``gameinfo/`` directory) as ``gameinfo-<yyyyMMdd-HHmmss>.zip``.

An unchanged content signature (sorted ``relpath,size,sha256`` list) skips the
packaging step unless ``--force`` is given.  The signature plus the upload and
manifest state are stored in the state file (default:
``<MARCER_DATA_DIR>/.asset-publish-state.json``,
``<MARCER_STATE_DIR>/asset-publish/state.json`` when that variable is set).

With ``--upload`` the archive is transferred directly into
``MARCER_FTP_ASSETS_REMOTE`` (default ``/Uploads/MarcerGameDVDLauncher-assets/``)
under its final name, then ``tools/asset-manifest`` is run (all kinds, so the
screenshots entry stays) so ``latest.json`` points at the new archive.  The
Marcer FTP does not support
``RNFR``/``RNTO`` or ``DELE``: an already complete same-size file is reused,
and a failed transfer is simply overwritten by the next ``--upload`` run (a
partial file cannot be removed remotely).  A failed upload leaves the local
archive marked as not uploaded; the next ``--upload`` run retries without
repacking.  A failed manifest update is remembered as ``manifest_dirty`` and
retried on the next ``--upload`` run.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import posixpath
import shutil
import subprocess
import sys
import time
import zipfile
from datetime import datetime, timezone
from ftplib import FTP, all_errors as FTP_ALL_ERRORS
from pathlib import Path, PurePosixPath

TOOL_VERSION = "0.2.0"
STATE_SCHEMA = 1

KIND_GAMEINFO = "gameinfo"
KINDS = (KIND_GAMEINFO,)

DEFAULT_ASSETS_REMOTE = "/Uploads/MarcerGameDVDLauncher-assets/"
FTP_TIMEOUT = 60
FTP_BLOCKSIZE = 1024 * 1024

# Only these files are published.  Everything else (backups, markers, temp
# files, legacy archives) is ignored by design.
INCLUDE_PATTERNS = (
    "games-*.json",
    "manifest.json",
    "crews.json",
    "crew-images.json",
    "crew-cluster.json",
    "unmatched-report.txt",
    "full-index.json.gz",
)

# Fixed timestamp inside the ZIP so identical content produces identical
# bytes regardless of when the archive was built.
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
ZIP_MODE = 0o644


class PublishError(Exception):
    """User-facing error (configuration, missing data, I/O)."""


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def iso_now() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_included(rel: PurePosixPath) -> bool:
    if any(part.startswith(".") for part in rel.parts):
        return False
    if "__MACOSX" in rel.parts:
        return False
    return any(fnmatch.fnmatch(rel.name, pattern) for pattern in INCLUDE_PATTERNS)


def collect_entries(source: Path) -> list[dict]:
    if not source.is_dir():
        raise PublishError(f"gameinfo source directory not found: {source}")

    entries: list[dict] = []
    for path in source.rglob("*"):
        if not path.is_file():
            continue
        rel = PurePosixPath(path.relative_to(source).as_posix())
        if not is_included(rel):
            continue
        entries.append(
            {
                "path": path,
                "relpath": rel.as_posix(),
                "size": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )
    entries.sort(key=lambda item: item["relpath"])
    if not entries:
        raise PublishError(f"no publishable files found in {source}")
    return entries


def content_signature(entries: list[dict]) -> str:
    payload = [
        {"path": entry["relpath"], "size": entry["size"], "sha256": entry["sha256"]}
        for entry in entries
    ]
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def load_state(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict) or not isinstance(data.get("assets"), dict):
        return {}
    return data


def write_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.part")
    try:
        tmp.write_text(
            json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def unique_archive_path(output_dir: Path, kind: str) -> Path:
    while True:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        candidate = output_dir / f"{kind}-{stamp}.zip"
        if not candidate.exists():
            return candidate
        # Keep the exact gameinfo-<yyyyMMdd-HHmmss>.zip scheme instead of
        # inventing a suffix the asset-manifest regex would not match.
        time.sleep(1)


def write_archive(output_dir: Path, kind: str, entries: list[dict]) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    target = unique_archive_path(output_dir, kind)
    tmp = target.with_name(f".{target.name}.{os.getpid()}.part")
    try:
        with zipfile.ZipFile(
            tmp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
        ) as archive:
            for entry in entries:
                info = zipfile.ZipInfo(entry["relpath"], date_time=ZIP_TIMESTAMP)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = ZIP_MODE << 16
                with entry["path"].open("rb") as src, archive.open(info, "w") as dst:
                    shutil.copyfileobj(src, dst)
        os.replace(tmp, target)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
    return target


# --------------------------------------------------------------------------
# FTP upload
# --------------------------------------------------------------------------


def split_host_port(raw: str, default_port: int = 21) -> tuple[str, int]:
    raw = raw.strip()
    if raw.startswith("["):  # [ipv6]:port
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


def ftp_settings() -> dict:
    host = env("MARCER_FTP_HOST")
    if not host:
        raise PublishError(
            "MARCER_FTP_HOST is not set — add the FTP credentials to "
            "local/paths.env or run without --upload"
        )
    remote = env("MARCER_FTP_ASSETS_REMOTE") or DEFAULT_ASSETS_REMOTE
    return {
        "host": host,
        "user": env("MARCER_FTP_USER"),
        "password": env("MARCER_FTP_PASS"),
        "remote": remote,
        "encoding": env("MARCER_FTP_ENCODING") or "utf-8",
    }


def _remote_size(ftp: FTP, name: str) -> int | None:
    try:
        size = ftp.size(name)
    except FTP_ALL_ERRORS:
        return None
    return size if isinstance(size, int) else None


def upload_archive(settings: dict, local_path: Path) -> str:
    """Upload ``local_path`` under its final name and return the remote path.

    The Marcer FTP server rejects ``RNFR``/``RNTO`` and ``DELE`` (and may
    disconnect the session for such commands), so the ZIP is stored directly
    as its final name.  An existing remote file with the same size is reused;
    otherwise ``STOR`` overwrites it.  A partial remote file cannot be removed
    and is overwritten on the next retry.
    """
    target_name = local_path.name
    remote_path = posixpath.join(settings["remote"], target_name)
    local_size = local_path.stat().st_size
    host, port = split_host_port(settings["host"])
    ftp = FTP()
    ftp.encoding = settings["encoding"]
    try:
        ftp.connect(host, port, timeout=FTP_TIMEOUT)
        ftp.login(settings["user"] or "anonymous", settings["password"] or "")
        ftp.set_pasv(True)
        try:
            ftp.cwd(settings["remote"])
        except FTP_ALL_ERRORS as exc:
            raise PublishError(
                f"remote asset directory not found: {settings['remote']} ({exc})"
            ) from exc

        ftp.voidcmd("TYPE I")
        if _remote_size(ftp, target_name) != local_size:
            with local_path.open("rb") as handle:
                ftp.storbinary(
                    f"STOR {target_name}", handle, blocksize=FTP_BLOCKSIZE
                )
            uploaded_size = _remote_size(ftp, target_name)
            if uploaded_size is not None and uploaded_size != local_size:
                raise PublishError(
                    f"FTP size mismatch for {target_name}: remote "
                    f"{uploaded_size}, local {local_size} — the partial file "
                    "cannot be deleted on the Marcer FTP; the next --upload "
                    "run overwrites it"
                )
        return remote_path
    except PublishError:
        raise
    except FTP_ALL_ERRORS as exc:
        raise PublishError(f"FTP upload failed for {target_name}: {exc}") from exc
    finally:
        try:
            ftp.quit()
        except Exception:  # noqa: BLE001 - best effort close
            try:
                ftp.close()
            except Exception:  # noqa: BLE001 - best effort close
                pass


def manifest_script() -> Path:
    return Path(__file__).resolve().parents[1] / "asset-manifest" / "asset_manifest.py"


def run_asset_manifest() -> None:
    """Publish the small ``latest.json`` pointer via ``tools/asset-manifest``.

    Always runs without ``--only`` so both the screenshots and gameinfo entries
    stay in the pointer.
    """
    script = manifest_script()
    if not script.is_file():
        raise PublishError(f"asset-manifest tool not found: {script}")
    command = [sys.executable, str(script)]
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=300,
            cwd=str(script.parents[2]),
        )
    except OSError as exc:
        raise PublishError(f"cannot run asset-manifest: {exc}") from exc
    except subprocess.TimeoutExpired as exc:
        raise PublishError("asset-manifest timed out after 300s") from exc
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        if len(detail) > 800:
            detail = detail[-800:]
        raise PublishError(
            f"asset-manifest failed (exit {completed.returncode}): {detail}"
        )



def resolve_paths(args: argparse.Namespace) -> tuple[Path, Path, Path]:
    data_dir_arg = args.data_dir or env("MARCER_DATA_DIR")
    if not data_dir_arg:
        raise PublishError(
            "MARCER_DATA_DIR is not set (add it to local/paths.env or pass --data-dir)"
        )
    data_dir = Path(data_dir_arg).expanduser()

    source = Path(args.source).expanduser() if args.source else data_dir / KIND_GAMEINFO

    if args.output_dir:
        output_dir = Path(args.output_dir).expanduser()
    elif env("MARCER_ASSET_OUT_DIR"):
        output_dir = Path(env("MARCER_ASSET_OUT_DIR")).expanduser()
    else:
        output_dir = data_dir

    if args.state_file:
        state_file = Path(args.state_file).expanduser()
    elif env("MARCER_STATE_DIR"):
        state_file = Path(env("MARCER_STATE_DIR")).expanduser() / "asset-publish" / "state.json"
    else:
        state_file = data_dir / ".asset-publish-state.json"

    return source, output_dir, state_file


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------


def publish(args: argparse.Namespace) -> int:
    kind = args.only
    source, output_dir, state_file = resolve_paths(args)
    ftp = ftp_settings() if args.upload else {}

    entries = collect_entries(source)
    signature = content_signature(entries)
    state = load_state(state_file)
    assets = state.setdefault("assets", {})
    previous = assets.get(kind, {})
    previous_archive = previous.get("archive")
    previous_path = output_dir / previous_archive if previous_archive else None
    unchanged = bool(
        previous.get("signature") == signature
        and previous_path is not None
        and previous_path.is_file()
    )
    uploaded = bool(previous.get("uploaded"))
    manifest_dirty = bool(previous.get("manifest_dirty"))

    result: dict = {
        "kind": kind,
        "source": str(source),
        "output_dir": str(output_dir),
        "state_file": str(state_file),
        "signature": signature,
        "files": len(entries),
        "force": bool(args.force),
        "upload": bool(args.upload),
        "dry_run": bool(args.dry_run),
    }

    if unchanged and not args.force:
        archive = previous_path
        size = archive.stat().st_size
        archive_sha = previous.get("sha256") or sha256_file(archive)
        result.update(
            archive=str(archive),
            size=size,
            sha256=archive_sha,
            uploaded=uploaded,
            remote=previous.get("remote", ""),
        )

        if args.dry_run:
            if not args.upload:
                status = "would-skip"
            elif not uploaded:
                status = "would-upload"
            elif manifest_dirty:
                status = "would-update-manifest"
            else:
                status = "would-skip"
            result["status"] = status
            emit(result, args.json)
            return 0

        if not args.upload or (uploaded and not manifest_dirty):
            result["status"] = "skipped"
            emit(result, args.json)
            return 0

        if not uploaded:
            try:
                remote = upload_archive(ftp, archive)
            except PublishError as exc:
                result.update(status="error", stage="upload", error=str(exc))
                emit(result, args.json)
                return 1
            previous["uploaded"] = True
            previous["remote"] = remote
            previous["uploaded_at"] = iso_now()
            previous["manifest_dirty"] = True
            assets[kind] = previous
            state["schema"] = STATE_SCHEMA
            write_state(state_file, state)

        try:
            run_asset_manifest()
        except PublishError as exc:
            previous["manifest_dirty"] = True
            assets[kind] = previous
            state["schema"] = STATE_SCHEMA
            write_state(state_file, state)
            result.update(
                status="error",
                stage="manifest",
                uploaded=bool(previous.get("uploaded")),
                remote=previous.get("remote", ""),
                manifest_updated=False,
                error=str(exc),
            )
            emit(result, args.json)
            return 1

        previous["manifest_dirty"] = False
        previous["manifest_updated_at"] = iso_now()
        assets[kind] = previous
        state["schema"] = STATE_SCHEMA
        write_state(state_file, state)
        result.update(
            status="uploaded",
            created=False,
            uploaded=True,
            remote=previous.get("remote", ""),
            manifest_updated=True,
        )
        emit(result, args.json)
        return 0

    if args.dry_run:
        result.update(
            status="would-create-upload" if args.upload else "would-create",
            archive="",
            uploaded=False,
            remote="",
        )
        emit(result, args.json)
        return 0

    archive = write_archive(output_dir, kind, entries)
    size = archive.stat().st_size
    archive_sha = sha256_file(archive)

    entry = {
        "signature": signature,
        "archive": archive.name,
        "size": size,
        "sha256": archive_sha,
        "files": len(entries),
        "updated_at": iso_now(),
        "uploaded": False,
        "manifest_dirty": False,
    }
    assets[kind] = entry
    state["schema"] = STATE_SCHEMA
    write_state(state_file, state)

    result.update(
        archive=str(archive),
        size=size,
        sha256=archive_sha,
        created=True,
        uploaded=False,
        remote="",
    )
    if not args.upload:
        result["status"] = "created"
        emit(result, args.json)
        return 0

    try:
        remote = upload_archive(ftp, archive)
    except PublishError as exc:
        result.update(status="error", stage="upload", error=str(exc))
        emit(result, args.json)
        return 1

    entry.update(
        uploaded=True,
        remote=remote,
        uploaded_at=iso_now(),
        manifest_dirty=True,
    )
    write_state(state_file, state)

    try:
        run_asset_manifest()
    except PublishError as exc:
        result.update(
            status="error",
            stage="manifest",
            uploaded=True,
            remote=remote,
            manifest_updated=False,
            error=str(exc),
        )
        emit(result, args.json)
        return 1

    entry["manifest_dirty"] = False
    entry["manifest_updated_at"] = iso_now()
    write_state(state_file, state)
    result.update(
        status="uploaded",
        uploaded=True,
        remote=remote,
        manifest_updated=True,
    )
    emit(result, args.json)
    return 0


def emit(result: dict, as_json: bool) -> None:
    if as_json:
        print(json.dumps(result, indent=2, sort_keys=True))
        return

    status = result["status"]
    kind = result["kind"]

    if status in ("skipped", "would-skip"):
        print(
            f"{kind}: unchanged ({result['files']} files, "
            f"signature {result['signature'][:12]}…)"
        )
        action = "skipped" if status == "skipped" else "would skip"
        print(f"{action}: {result['archive']}")
        return

    if status in ("would-create", "would-create-upload"):
        print(
            f"{kind}: would create from {result['files']} files "
            f"(signature {result['signature'][:12]}…)"
        )
        print(f"target directory: {result['output_dir']}")
        if status == "would-create-upload":
            print("would upload it and update latest.json")
        return

    if status == "would-upload":
        print(f"{kind}: would upload existing archive {result['archive']}")
        print("would update latest.json")
        return

    if status == "would-update-manifest":
        print(f"{kind}: archive already uploaded; would update latest.json")
        return

    if status == "created":
        print(
            f"{kind}: created {result['archive']} "
            f"({result['size']} bytes, {result['files']} files)"
        )
        return

    if status == "uploaded":
        if result.get("created"):
            print(
                f"{kind}: created {result['archive']} "
                f"({result['size']} bytes, {result['files']} files)"
            )
        else:
            print(f"{kind}: uploaded existing {result['archive']}")
        print(f"uploaded: {result['remote']}")
        print("latest.json updated")
        return

    print(
        f"error during {result.get('stage', 'publish')}: {result.get('error', '')}",
        file=sys.stderr,
    )
    if result.get("uploaded"):
        print("the archive was uploaded; latest.json is still pending", file=sys.stderr)
    if result.get("archive"):
        print(f"archive: {result['archive']}", file=sys.stderr)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="asset_publish.py",
        description="Package Marcer GameDVD catalog assets deterministically.",
    )
    parser.add_argument("--version", action="version", version=TOOL_VERSION)
    sub = parser.add_subparsers(dest="command", required=True)

    pub = sub.add_parser(
        "publish", help="package catalog assets (currently gameinfo only)"
    )
    pub.add_argument(
        "--only",
        choices=KINDS,
        default=KIND_GAMEINFO,
        help="asset kind to publish (default: gameinfo)",
    )
    pub.add_argument("--data-dir", help="override MARCER_DATA_DIR")
    pub.add_argument("--source", help="override the gameinfo source directory")
    pub.add_argument(
        "--output-dir",
        help="override MARCER_ASSET_OUT_DIR (default: MARCER_DATA_DIR)",
    )
    pub.add_argument("--state-file", help="override the signature state file")
    pub.add_argument(
        "--upload",
        action="store_true",
        help="upload to MARCER_FTP_ASSETS_REMOTE and update latest.json",
    )
    pub.add_argument(
        "--force", action="store_true", help="pack even when the signature is unchanged"
    )
    pub.add_argument(
        "--dry-run", action="store_true", help="report the action without writing"
    )
    pub.add_argument("--json", action="store_true", help="machine-readable output")
    pub.set_defaults(func=publish)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except PublishError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
