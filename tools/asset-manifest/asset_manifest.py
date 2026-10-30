#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Marcer GameDVD Launcher asset manifest tool.

Connects to the Marcer FTP server, lists the catalog asset archives
(``screenshots-<yyyyMMdd-HHmmss>.zip`` / ``gameinfo-<...>.zip``), picks the
newest per kind and publishes a small ``latest.json`` pointer as a **GitHub
Release asset** on a fixed tag (default ``catalog-latest``), so the desktop app
can check for catalog-data updates without touching the FTP itself.

The FTP is only ever read (list); nothing is uploaded there. The release asset
is (re)uploaded through the authenticated ``gh`` CLI with ``--clobber``, so it
can be replaced as often as the assets change — independent of app releases.

Usage:
  tools/asset-manifest/run.sh                     # list FTP, (re)upload latest.json
  tools/asset-manifest/run.sh --dry-run           # print latest.json, no upload
  tools/asset-manifest/run.sh --create-release    # create the fixed release once
  tools/asset-manifest/run.sh --out latest.json
  tools/asset-manifest/run.sh --hash              # include sha256 of the archives
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from ftplib import FTP, error_perm, error_temp
from pathlib import Path

TOOL_VERSION = "0.2.0"
SCHEMA_VERSION = 1

# <kind>-<yyyyMMdd>-<HHmmss>.zip
ARCHIVE_RE = re.compile(
    r"^(screenshots|gameinfo)-(\d{8}-\d{6})\.zip$", re.IGNORECASE)
KINDS = ("screenshots", "gameinfo")

REPO_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_CONFIG = {
    "remote": "/Uploads/MarcerGameDVDLauncher-assets/",
    "asset_name": "latest.json",
    "release_tag": "catalog-latest",
}


# --------------------------------------------------------------------------
# config / env
# --------------------------------------------------------------------------

def load_config() -> dict:
    cfg = dict(DEFAULT_CONFIG)
    for name in ("config.example.json", "config.local.json"):
        path = Path(__file__).with_name(name)
        if path.exists():
            try:
                cfg.update(json.loads(path.read_text(encoding="utf-8")))
            except (OSError, ValueError) as exc:
                sys.exit(f"error: cannot read {path}: {exc}")
    return cfg


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def ftp_settings(cfg: dict, ftp_config: str | None) -> dict:
    """FTP connection settings: env first, then a JSON config file.

    The JSON file uses the desktop app's schema (``Ftp.Host``/``User``/
    ``Password``/``AssetsRemote``); when [ftp_config] is omitted,
    ``apps/marcer_desktop/desktop.config.json`` is used if it exists.
    """
    host = env("MARCER_FTP_HOST")
    user = env("MARCER_FTP_USER")
    password = env("MARCER_FTP_PASS")
    remote = env("MARCER_FTP_ASSETS_REMOTE") or cfg["remote"]

    if not host:
        path = Path(ftp_config) if ftp_config else (
            REPO_ROOT / "apps" / "marcer_desktop" / "desktop.config.json")
        if path.exists():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                ftp = data.get("Ftp") or {}
                host = (ftp.get("Host") or "").strip()
                user = user or (ftp.get("User") or "").strip()
                password = password or (ftp.get("Password") or "").strip()
                remote = env("MARCER_FTP_ASSETS_REMOTE") or (
                    (ftp.get("AssetsRemote") or "").strip() or cfg["remote"])
            except (OSError, ValueError) as exc:
                sys.exit(f"error: cannot read {path}: {exc}")

    if not host:
        sys.exit("error: no FTP host — set MARCER_FTP_HOST in local/paths.env "
                 "(or pass --ftp-config).")
    return {"host": host, "user": user, "password": password, "remote": remote}


def split_host_port(raw: str, default_port: int = 21):
    raw = raw.strip()
    if raw.startswith("["):  # [ipv6]:port
        end = raw.find("]")
        host = raw[1:end] if end > 0 else raw
        rest = raw[end + 1:] if end > 0 else ""
        if rest.startswith(":") and rest[1:].isdigit():
            return host, int(rest[1:])
        return host, default_port
    if raw.count(":") == 1:
        head, tail = raw.rsplit(":", 1)
        if tail.isdigit():
            return head, int(tail)
    return raw, default_port


# --------------------------------------------------------------------------
# FTP listing
# --------------------------------------------------------------------------

def ftp_list(settings: dict, verbose: bool = False):
    host, port = split_host_port(settings["host"])
    ftp = FTP()
    ftp.encoding = env("MARCER_FTP_ENCODING") or "utf-8"
    if verbose:
        print(f"connecting to {host}:{port} …", file=sys.stderr)
    ftp.connect(host, port, timeout=60)
    ftp.login(settings["user"] or "anonymous", settings["password"] or "")
    ftp.set_pasv(True)
    if not ftp.cwd(settings["remote"]):
        ftp.quit()
        sys.exit(f"error: remote directory not found: {settings['remote']}")

    entries = []  # (name, size|None, modify|None)
    try:
        for name, facts in ftp.mlsd():
            if facts.get("type") not in (None, "file"):
                continue
            size = int(facts["size"]) if facts.get("size", "").isdigit() else None
            entries.append((name, size, facts.get("modify")))
    except (error_perm, error_temp):
        # Server has no MLSD: fall back to NLST + SIZE.
        for name in ftp.nlst():
            if name in (".", ".."):
                continue
            try:
                ftp.sendcmd("TYPE I")
                size = ftp.size(name)
            except Exception:  # noqa: BLE001 - size is best-effort
                size = None
            entries.append((name, size, None))
    return ftp, entries


def pick_newest(entries):
    """Return {kind: (name, size, modify, stamp)} with the newest per kind."""
    best: dict[str, tuple] = {}
    for name, size, modify in entries:
        m = ARCHIVE_RE.match(name)
        if not m:
            continue
        kind, stamp = m.group(1).lower(), m.group(2)
        current = best.get(kind)
        if current is None or stamp > current[3]:
            best[kind] = (name, size, modify, stamp)
    return best


def sha256_of(ftp: FTP, name: str) -> str:
    digest = hashlib.sha256()
    ftp.retrbinary(f"RETR {name}", digest.update)
    return digest.hexdigest()


# --------------------------------------------------------------------------
# GitHub release asset
# --------------------------------------------------------------------------

def gh(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(["gh", *args], text=True, capture_output=True)
    if check and proc.returncode != 0:
        sys.exit(f"error: gh {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc


def repo_slug(explicit: str | None) -> str:
    if explicit:
        return explicit
    if env("MARCER_REPO"):
        return env("MARCER_REPO")
    proc = gh("repo", "view", "--json", "nameWithOwner",
              "-q", ".nameWithOwner", check=False)
    if proc.returncode != 0 or not proc.stdout.strip():
        sys.exit("error: cannot determine the repository — run inside the repo "
                 "or pass --repo / set MARCER_REPO.")
    return proc.stdout.strip()


def release_exists(tag: str, repo: str) -> bool:
    return gh("release", "view", tag, "--json", "tagName", "--repo", repo,
              check=False).returncode == 0


def create_release(tag: str, repo: str, verbose: bool) -> None:
    if verbose:
        print(f"creating prerelease {tag} in {repo} …", file=sys.stderr)
    gh("release", "create", tag,
       "--repo", repo,
       "--title", "Catalog data (latest.json)",
       "--notes", "Pointer to the newest Marcer catalog asset archives.",
       "--prerelease", "--latest=false")


def upload_asset(tag: str, file_path: Path, repo: str, verbose: bool) -> None:
    if verbose:
        print(f"uploading {file_path.name} to {tag} …", file=sys.stderr)
    gh("release", "upload", tag, str(file_path), "--clobber", "--repo", repo)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def build_manifest(found: dict, ftp: FTP, remote: str, hashes: bool,
                   only: str, verbose: bool) -> dict:
    manifest = {
        "schema": SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc)
        .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "remote": remote,
    }
    for kind in KINDS:
        if only and kind != only:
            continue
        entry = found.get(kind)
        if entry is None:
            print(f"warning: no {kind}-*.zip found in {remote}",
                  file=sys.stderr)
            continue
        name, size, modify, _stamp = entry
        item = {"archive": name}
        if size is not None:
            item["size"] = size
        if modify:
            item["modified"] = modify
        if hashes:
            if verbose:
                print(f"hashing {name} …", file=sys.stderr)
            item["sha256"] = sha256_of(ftp, name)
        manifest[kind] = item
    return manifest


def main(argv=None) -> int:
    cfg = load_config()
    ap = argparse.ArgumentParser(
        prog="asset-manifest",
        description="Publish the newest Marcer FTP asset archives as a "
                    "latest.json pointer (GitHub release asset).")
    ap.add_argument("--dry-run", action="store_true",
                    help="print latest.json and do not upload anything")
    ap.add_argument("--out", metavar="PATH",
                    help="also write latest.json to PATH")
    ap.add_argument("--hash", action="store_true",
                    help="include a sha256 of each archive (downloads them)")
    ap.add_argument("--only", choices=KINDS,
                    help="restrict the manifest to one asset kind")
    ap.add_argument("--ftp-config", metavar="PATH",
                    help="JSON config with an Ftp section "
                         "(default: apps/marcer_desktop/desktop.config.json)")
    ap.add_argument("--release-tag", metavar="TAG",
                    help="release tag holding the pointer "
                         "(default: MARCER_RELEASE_TAG or catalog-latest)")
    ap.add_argument("--repo", metavar="OWNER/REPO",
                    help="target repository (default: MARCER_REPO or the "
                         "current git remote)")
    ap.add_argument("--create-release", action="store_true",
                    help="create the fixed prerelease/tag when it is missing")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--version", action="version",
                    version=f"asset-manifest {TOOL_VERSION}")
    args = ap.parse_args(argv)

    settings = ftp_settings(cfg, args.ftp_config)
    ftp, entries = ftp_list(settings, args.verbose)
    try:
        found = pick_newest(entries)
        if not found:
            sys.exit(f"error: no *_*.zip assets found in {settings['remote']}")
        manifest = build_manifest(found, ftp, settings["remote"],
                                  args.hash, args.only, args.verbose)
    finally:
        try:
            ftp.quit()
        except Exception:  # noqa: BLE001 - best effort
            ftp.close()

    content = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    for kind in KINDS:
        if kind in manifest:
            print(f"{kind:11} {manifest[kind]['archive']}")

    if args.out:
        Path(args.out).write_text(content, encoding="utf-8")
        print(f"wrote {args.out}")

    if args.dry_run:
        print("\n" + content, end="")
        return 0

    tag = args.release_tag or env("MARCER_RELEASE_TAG") or cfg["release_tag"]
    asset_name = cfg["asset_name"]
    repo = repo_slug(args.repo)

    if not release_exists(tag, repo):
        if not args.create_release:
            sys.exit(f"error: release '{tag}' not found in {repo} "
                     f"(pass --create-release to create it once).")
        create_release(tag, repo, args.verbose)

    with tempfile.TemporaryDirectory() as tmp:
        asset_file = Path(tmp) / asset_name
        asset_file.write_text(content, encoding="utf-8")
        upload_asset(tag, asset_file, repo, args.verbose)

    url = f"https://github.com/{repo}/releases/download/{tag}/{asset_name}"
    print(f"updated {url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
