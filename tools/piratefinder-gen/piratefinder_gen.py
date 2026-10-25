#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Import the PirateFinder catalogue for local analysis.

PirateFinder publishes a read-only SQLite catalogue (CC BY-NC-SA 4.0) as a
weekly GitHub release.  This tool fetches that release, verifies its SHA-256,
extracts the Atari ST subset into compact JSON, and matches the Marcer cracked
ZIPs against it (by decoded disk-image hashes, with a title fallback).

Nothing is written to the game trees, the catalog artifacts or the repository
data directories.  Output goes to ``MARCER_PIRATEFINDER_DIR`` (default
``<repo>/local/piratefinder``); the catalogue is never redistributed.

Commands::

    run.sh fetch [--tag catalogue-YYYY-MM-DD] [--force]
    run.sh extract [--force]
    run.sh match [--limit N] [--scan] [--include-subdirs]
    run.sh report

See README.md for the data model and the environment variables.
"""

from __future__ import annotations

import argparse
import bisect
import csv
import difflib
import gzip
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
import time
import unicodedata
import urllib.error
import urllib.request
import zipfile
import zlib
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

import tomllib

TOOL_VERSION = "0.1.1"
INDEX_SCHEMA = 1
MATCH_SCHEMA = 1
EXPECTED_CATALOGUE_SCHEMA = 3
GAMEINFO_SUBDIR = "gameinfo"

REPO = "peteclarke-del/PirateFinder"
API_ROOT = "https://api.github.com/repos/" + REPO
RAW_ROOT = "https://raw.githubusercontent.com/" + REPO
TAG_PREFIX = "catalogue-"
USER_AGENT = f"marcer-piratefinder-gen/{TOOL_VERSION} (+https://github.com/skoelle/marcer-gamedvd-launcher)"

DEFAULT_TREE = "Title Sorted/Cracked Games - Title Sorted"
IMAGE_SUFFIXES = {".msa", ".st", ".stx"}
MAX_MEMBER_SIZE = 32 * 1024 * 1024
PLACEHOLDER_GROUPS = {"", "original", "unknown", "none", "n/a", "-", "?"}
GENERIC_ZIP_LABELS = {
    "tr",
    "trainer",
    "trained",
    "crack",
    "cracked",
    "cracktro",
    "french",
    "german",
    "english",
    "usa",
    "us",
    "europe",
    "disk",
    "demo",
    "version",
    "enhanced",
    "by",
    "fix",
    "fixed",
    "preview",
    "beta",
    "alt",
}


# --------------------------------------------------------------------------
# Paths and small helpers
# --------------------------------------------------------------------------


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def env(name: str) -> str:
    return os.environ.get(name, "").strip()


def output_root() -> Path:
    value = env("MARCER_PIRATEFINDER_DIR")
    return Path(value) if value else repo_root() / "local" / "piratefinder"


def raw_dir() -> Path:
    return output_root() / "raw"


def index_dir() -> Path:
    return output_root() / "index"


def match_dir() -> Path:
    return output_root() / "matches"


def report_dir() -> Path:
    return output_root() / "report"


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ensure_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def write_json(path: Path, payload: object, *, pretty: bool = False) -> None:
    ensure_dir(path.parent)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        if pretty:
            json.dump(payload, handle, ensure_ascii=False, indent=1, sort_keys=True)
        else:
            json.dump(
                payload,
                handle,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            )
        handle.write("\n")
    os.replace(tmp, path)


def read_json(path: Path) -> object:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def fmt_bytes(value: int) -> str:
    units = ("B", "KB", "MB", "GB")
    number = float(value)
    for unit in units:
        if number < 1024 or unit == units[-1]:
            return f"{number:.1f} {unit}"
        number /= 1024
    return f"{value} B"


def log(message: str) -> None:
    print(message, flush=True)


def normalize_name(value: str) -> str:
    """Normalize a crew/cracker label for comparison."""
    text = unicodedata.normalize("NFKD", value or "")
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.lower().replace("&", " and ").replace("+", " and ")
    text = re.sub(r"[^a-z0-9]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    text = text.removeprefix("the ")
    return text


def title_key(value: str) -> str:
    """Normalize a game title the way the matching/report code compares them."""
    text = unicodedata.normalize("NFKD", value or "")
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.lower()
    text = re.split(r"[\(\[\{]", text, maxsplit=1)[0]
    text = re.sub(r"\s+v\d+(?:\.\d+)*$", "", text).strip()
    match = re.match(r"^(.*?),\s*(the|a|an)\s*$", text)
    if match:
        text = f"{match.group(2)} {match.group(1)}"
    text = text.replace("&", " and ").replace("+", " and ")
    text = re.sub(r"[^a-z0-9]+", " ", text).strip()
    text = text.removeprefix("the ")
    text = re.sub(
        r"\b(ii|iii|iv|vi|vii|viii|ix|x)\b",
        lambda match: {
            "ii": "2",
            "iii": "3",
            "iv": "4",
            "vi": "6",
            "vii": "7",
            "viii": "8",
            "ix": "9",
            "x": "10",
        }[match.group(1)],
        text,
    )
    return re.sub(r"\s+", " ", text).strip()


def title_from_zip(name: str) -> str:
    """Title part of a release ZIP name such as ``Game - Cracker.zip``."""
    stem = PurePosixPath(name.replace("\\", "/")).stem
    return re.split(r"\s+-\s+", stem, maxsplit=1)[0].strip()


def platform_is_st(value: str) -> bool:
    text = (value or "").strip().lower().replace("_", "-").replace(" ", "-")
    return text in {"atari-st", "atari-st-", "st"}


# --------------------------------------------------------------------------
# GitHub / catalogue fetching
# --------------------------------------------------------------------------


def http_json(url: str) -> object:
    request = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"}
    )
    token = env("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")[:400]
        raise SystemExit(
            f"error: GitHub request failed ({error.code}): {url}\n{body}"
        ) from error
    except urllib.error.URLError as error:
        raise SystemExit(f"error: cannot reach GitHub: {error.reason}") from error


def download(
    url: str, destination: Path, *, expect_sha256: str = "", force: bool = False
) -> str:
    if destination.is_file() and not force:
        digest = sha256_file(destination)
        if not expect_sha256 or digest == expect_sha256:
            log(
                f"  cached {destination.name} ({fmt_bytes(destination.stat().st_size)})"
            )
            return digest
        log(f"  cached {destination.name} has the wrong SHA-256, downloading again")
    ensure_dir(destination.parent)
    part = destination.with_suffix(destination.suffix + ".part")
    digest = hashlib.sha256()
    size = 0
    started = time.monotonic()
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with (
            urllib.request.urlopen(request, timeout=120) as response,
            part.open("wb") as handle,
        ):
            total = int(response.headers.get("Content-Length") or 0)
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
                digest.update(chunk)
                size += len(chunk)
                if total and (
                    size // (5 * 1024 * 1024)
                    != (size - len(chunk)) // (5 * 1024 * 1024)
                ):
                    log(
                        f"  {destination.name}: {size / total * 100:5.1f}% ({fmt_bytes(size)})"
                    )
    except urllib.error.HTTPError as error:
        raise SystemExit(f"error: download failed ({error.code}): {url}") from error
    except urllib.error.URLError as error:
        raise SystemExit(f"error: download failed: {error.reason}") from error
    os.replace(part, destination)
    actual = digest.hexdigest()
    if expect_sha256 and actual != expect_sha256:
        destination.unlink(missing_ok=True)
        raise SystemExit(
            f"error: SHA-256 mismatch for {destination.name}: got {actual}, expected {expect_sha256}"
        )
    log(
        f"  saved {destination.name} ({fmt_bytes(size)}, {time.monotonic() - started:.1f}s)"
    )
    return actual


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_release(tag: str) -> dict:
    if tag:
        return http_json(f"{API_ROOT}/releases/tags/{tag}")  # type: ignore[return-value]
    releases = http_json(f"{API_ROOT}/releases?per_page=100")
    if not isinstance(releases, list):
        raise SystemExit("error: unexpected GitHub release response")
    candidates = [
        item
        for item in releases
        if str(item.get("tag_name", "")).startswith(TAG_PREFIX)
    ]
    if not candidates:
        raise SystemExit(
            f"error: no {TAG_PREFIX}* release found in the last 100 releases"
        )
    candidates.sort(
        key=lambda item: item.get("published_at") or item.get("created_at") or "",
        reverse=True,
    )
    return candidates[0]


def cmd_fetch(args: argparse.Namespace) -> int:
    log("fetch: resolving PirateFinder catalogue release")
    release = find_release(args.tag or "")
    tag = str(release.get("tag_name", ""))
    commit = str(release.get("target_commitish", "") or "")
    assets = release.get("assets") or []
    catalogue_assets = [
        a
        for a in assets
        if re.fullmatch(r"catalogue-layout\d+\.sqlite\.gz", str(a.get("name", "")))
    ]
    if not catalogue_assets:
        raise SystemExit(
            f"error: release {tag} has no catalogue-layout*.sqlite.gz asset"
        )
    expected_name = f"catalogue-layout{EXPECTED_CATALOGUE_SCHEMA}.sqlite.gz"
    asset = next(
        (
            item
            for item in catalogue_assets
            if str(item.get("name", "")) == expected_name
        ),
        catalogue_assets[0],
    )
    asset_name = str(asset["name"])
    sha_asset = next(
        (a for a in assets if str(a.get("name", "")).endswith(".sha256")), None
    )
    expected_sha = ""
    if sha_asset:
        sha_url = str(sha_asset.get("browser_download_url", ""))
        sha_text = download_text(sha_url)
        first = sha_text.strip().split()[0] if sha_text.strip() else ""
        if re.fullmatch(r"[0-9a-fA-F]{64}", first):
            expected_sha = first.lower()
    elif asset.get("digest"):
        digest = str(asset["digest"])
        if digest.startswith("sha256:"):
            expected_sha = digest.split(":", 1)[1].lower()

    log(f"  release {tag} (commit {commit[:12] or 'unknown'}), asset {asset_name}")
    archive = raw_dir() / asset_name
    actual_sha = download(
        str(asset["browser_download_url"]),
        archive,
        expect_sha256=expected_sha,
        force=args.force,
    )

    sqlite_name = (
        asset_name[:-3] if asset_name.endswith(".gz") else asset_name + ".sqlite"
    )
    sqlite_path = raw_dir() / sqlite_name
    if args.force or not sqlite_path.is_file() or sqlite_path.stat().st_size == 0:
        log(f"  unpacking {asset_name} -> {sqlite_name}")
        tmp = sqlite_path.with_suffix(sqlite_path.suffix + ".tmp")
        with gzip.open(archive, "rb") as source, tmp.open("wb") as target:
            shutil.copyfileobj(source, target, length=1024 * 1024)
        os.replace(tmp, sqlite_path)
    with sqlite_path.open("rb") as handle:
        header = handle.read(16)
    if not header.startswith(b"SQLite format 3\x00"):
        raise SystemExit(f"error: {sqlite_path} is not a SQLite database")
    log(f"  database {sqlite_path.name} ({fmt_bytes(sqlite_path.stat().st_size)})")

    groups_path = raw_dir() / "groups.toml"
    groups_url = f"{RAW_ROOT}/{commit if re.fullmatch(r'[0-9a-f]{40}', commit) else tag}/data/groups.toml"
    try:
        groups_text = download_text(groups_url)
        ensure_dir(groups_path.parent)
        groups_path.write_text(groups_text, encoding="utf-8")
        log(f"  saved {groups_path.name} ({fmt_bytes(groups_path.stat().st_size)})")
    except SystemExit as error:
        log(f"  warning: could not fetch groups.toml: {error}")

    source = {
        "repo": REPO,
        "tag": tag,
        "commit": commit,
        "release_id": release.get("id"),
        "asset": asset_name,
        "sha256": actual_sha,
        "sqlite": sqlite_name,
        "fetched_at": utc_now(),
        "licence": "CC BY-NC-SA 4.0 (PirateFinder catalogue; includes Atari Legend data)",
    }
    write_json(raw_dir() / "source.json", source, pretty=True)
    log(f"fetch: done; source metadata in {raw_dir() / 'source.json'}")
    return 0


def download_text(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        raise SystemExit(f"HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise SystemExit(str(error.reason)) from error


# --------------------------------------------------------------------------
# Extraction
# --------------------------------------------------------------------------


def find_sqlite() -> Path:
    source_path = raw_dir() / "source.json"
    if source_path.is_file():
        source = read_json(source_path)  # type: ignore[assignment]
        candidate = raw_dir() / str(source.get("sqlite", ""))  # type: ignore[union-attr]
        if candidate.is_file():
            return candidate
    candidates = sorted(raw_dir().glob("catalogue-layout*.sqlite"))
    if candidates:
        return candidates[-1]
    raise SystemExit("error: no catalogue database found; run `run.sh fetch` first")


def read_source_meta() -> dict:
    source_path = raw_dir() / "source.json"
    return read_json(source_path) if source_path.is_file() else {}  # type: ignore[return-value]


def connect_readonly(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def rows(connection: sqlite3.Connection, sql: str) -> list[sqlite3.Row]:
    return list(connection.execute(sql))


def cmd_extract(args: argparse.Namespace) -> int:
    database = find_sqlite()
    log(f"extract: reading {database}")
    connection = connect_readonly(database)
    try:
        meta = {
            str(row["key"]): str(row["value"])
            for row in rows(connection, "SELECT key, value FROM meta")
        }
        schema = int(meta.get("schema_version", "0"))
        if schema != EXPECTED_CATALOGUE_SCHEMA:
            raise SystemExit(
                f"error: catalogue schema {schema} is not supported (expected {EXPECTED_CATALOGUE_SCHEMA}); "
                "update tools/piratefinder-gen if PirateFinder changed its layout"
            )

        all_disks = rows(
            connection,
            """
            SELECT d.id, d.series_id, s.name AS series_name, s.group_name AS series_group,
                   s.kind AS series_kind, d.number, d.part, d.version, d.label, d.title,
                   d.date, d.platform, d.kind, d.publisher, d.cracker, d.condition,
                   d.notes, d.credits, d.category, d.crew, d.crew_id, d.year, d.month,
                   d.day, d.sort_title
            FROM disks d LEFT JOIN series s ON s.id = d.series_id
            ORDER BY d.id
            """,
        )
        st_disks = [
            dict(row) for row in all_disks if platform_is_st(str(row["platform"]))
        ]
        st_ids = {int(row["id"]) for row in st_disks}
        if not st_ids:
            raise SystemExit(
                "error: the catalogue contains no Atari ST disks (unexpected platform spelling?)"
            )

        contents: dict[int, list[dict]] = defaultdict(list)
        for row in rows(
            connection, "SELECT * FROM contents ORDER BY disk_id, position, id"
        ):
            disk_id = int(row["disk_id"])
            if disk_id not in st_ids:
                continue
            contents[disk_id].append(
                {
                    "id": row["id"],
                    "position": row["position"],
                    "title": row["title"],
                    "kind": row["kind"],
                    "publisher": row["publisher"],
                    "cracker": row["cracker"],
                    "version": row["version"],
                    "extra": row["extra"],
                    "source": row["source"],
                }
            )
        images: list[dict] = []
        for row in rows(connection, "SELECT * FROM images ORDER BY disk_id, rank, id"):
            if int(row["disk_id"]) not in st_ids:
                continue
            images.append(
                {
                    "id": row["id"],
                    "disk_id": row["disk_id"],
                    "name": row["name"],
                    "format": row["format"],
                    "flags": row["flags"],
                    "size": row["size"],
                    "crc32": row["crc32"],
                    "md5": row["md5"],
                    "sha1": row["sha1"],
                    "sha512": row["sha512"],
                    "bad": row["bad"],
                    "rank": row["rank"],
                    "source": row["source"],
                    "virus": row["virus"],
                    "virus_damage": row["virus_damage"],
                    "antivirus": row["antivirus"],
                }
            )
        crews = []
        for row in rows(connection, "SELECT * FROM crews ORDER BY name"):
            if not platform_is_st(str(row["platform"])):
                continue
            crews.append(dict(row))
        sources = [
            dict(row) for row in rows(connection, "SELECT * FROM sources ORDER BY id")
        ]
        series_aliases = [
            dict(row)
            for row in rows(
                connection,
                """
                SELECT a.alias, a.series_id, s.name AS series_name
                FROM series_alias a JOIN series s ON s.id = a.series_id
                ORDER BY a.alias
                """,
            )
        ]
    finally:
        connection.close()

    for disk in st_disks:
        disk["contents"] = contents.get(int(disk["id"]), [])
    st_disks.sort(key=lambda item: int(item["id"]))

    appearances: dict[str, list[dict]] = defaultdict(list)
    appearance_seen: dict[str, set[int]] = defaultdict(set)
    for disk in st_disks:
        if str(disk["kind"]) not in {"menu", "pack", "compilation"}:
            continue
        for content in disk["contents"]:
            key = title_key(str(content["title"]))
            if not key or int(disk["id"]) in appearance_seen[key]:
                continue
            appearance_seen[key].add(int(disk["id"]))
            appearances[key].append(
                {
                    "disk_id": disk["id"],
                    "label": disk["label"],
                    "kind": disk["kind"],
                    "series": disk["series_name"],
                    "number": disk["number"],
                    "year": disk["year"],
                    "crew": disk["crew"],
                }
            )
    for value in appearances.values():
        value.sort(key=lambda item: int(item["disk_id"]))
        del value[100:]

    aliases = parse_groups(raw_dir() / "groups.toml")
    source = read_source_meta()
    meta_payload = {
        "schema": INDEX_SCHEMA,
        "tool": "tools/piratefinder-gen",
        "tool_version": TOOL_VERSION,
        "generated_at": utc_now(),
        "source": source,
        "catalogue": {
            "schema_version": schema,
            "meta": meta,
            "sources": sources,
        },
        "counts": {
            "disks_st": len(st_disks),
            "images_st": len(images),
            "contents_st": sum(len(value) for value in contents.values()),
            "crews_st": len(crews),
            "title_appearances": len(appearances),
            "groups": len(aliases.get("groups", [])),
        },
        "licence": "CC BY-NC-SA 4.0 (PirateFinder catalogue; not redistributed by this tool)",
    }

    write_json(index_dir() / "meta.json", meta_payload, pretty=True)
    write_json(
        index_dir() / "disks-st.json", {"schema": INDEX_SCHEMA, "disks": st_disks}
    )
    write_json(
        index_dir() / "images-st.json", {"schema": INDEX_SCHEMA, "images": images}
    )
    write_json(index_dir() / "crews-st.json", {"schema": INDEX_SCHEMA, "crews": crews})
    write_json(
        index_dir() / "contents-by-title.json",
        {"schema": INDEX_SCHEMA, "titles": appearances},
    )
    write_json(
        index_dir() / "series-aliases.json",
        {"schema": INDEX_SCHEMA, "aliases": series_aliases},
    )
    write_json(index_dir() / "groups.json", aliases)
    log(
        f"extract: {len(st_disks):,} ST disks, {len(images):,} images, "
        f"{len(crews):,} crews, {len(appearances):,} titles -> {index_dir()}"
    )
    return 0


def parse_groups(path: Path) -> dict:
    if not path.is_file():
        return {"schema": 1, "groups": [], "source": "missing"}
    try:
        with path.open("rb") as handle:
            payload = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        log(f"warning: cannot read {path}: {error}")
        return {"schema": 1, "groups": [], "source": f"error: {error}"}
    groups = []
    for item in payload.get("group", []):
        groups.append(
            {
                "name": item.get("name", ""),
                "abbreviations": item.get("abbreviations", []),
                "aliases": item.get("aliases", []),
                "platforms": item.get("platforms", []),
            }
        )
    return {"schema": 1, "groups": groups, "source": str(path)}


def load_index() -> tuple[dict, list[dict], list[dict], list[dict], dict]:
    index = index_dir()
    required = [
        "disks-st.json",
        "images-st.json",
        "crews-st.json",
        "contents-by-title.json",
        "meta.json",
    ]
    missing = [name for name in required if not (index / name).is_file()]
    if missing:
        raise SystemExit(
            f"error: missing index files {', '.join(missing)}; run `run.sh extract` first"
        )
    disks = read_json(index / "disks-st.json")["disks"]  # type: ignore[index]
    images = read_json(index / "images-st.json")["images"]  # type: ignore[index]
    crews = read_json(index / "crews-st.json")["crews"]  # type: ignore[index]
    appearances = read_json(index / "contents-by-title.json")["titles"]  # type: ignore[index]
    meta = read_json(index / "meta.json")
    return meta, disks, images, crews, appearances  # type: ignore[return-value]


# --------------------------------------------------------------------------
# MSA decoding (ported from PirateFinder's vendored msa.py, layout 3)
# --------------------------------------------------------------------------

MSA_MAGIC = b"\x0e\x0f"
MSA_HEADER = 10
MSA_RUN = 0xE5
SECTOR_SIZE = 512


class MSAError(ValueError):
    pass


def unpack_msa_track(packed: bytes, expected: int) -> bytes:
    out = bytearray()
    index = 0
    end = len(packed)
    while index < end:
        marker = packed.find(MSA_RUN, index)
        if marker < 0:
            out += packed[index:]
            if len(out) > expected:
                raise MSAError(f"track unpacks to more than {expected} bytes")
            break
        out += packed[index:marker]
        index = marker + 1
        if index + 3 > end:
            raise MSAError("run record is cut off")
        fill = packed[index]
        count = int.from_bytes(packed[index + 1 : index + 3], "big")
        index += 3
        out += bytes((fill,)) * count
        if len(out) > expected:
            raise MSAError(f"track unpacks to more than {expected} bytes")
    if len(out) != expected:
        raise MSAError(f"track unpacks to {len(out)} bytes, expected {expected}")
    return bytes(out)


def decode_msa(data: bytes) -> bytes:
    """Rebuild the raw ST sector image an MSA archive was made from."""
    if len(data) < MSA_HEADER or data[:2] != MSA_MAGIC:
        raise MSAError("not an MSA file")
    sectors = int.from_bytes(data[2:4], "big")
    sides = int.from_bytes(data[4:6], "big") + 1
    start = int.from_bytes(data[6:8], "big")
    end = int.from_bytes(data[8:10], "big")
    if not 1 <= sectors <= 36:
        raise MSAError(f"invalid sectors per track {sectors}")
    if sides not in (1, 2):
        raise MSAError(f"invalid sides {sides}")
    if end < start or end > 255:
        raise MSAError(f"invalid track range {start}-{end}")
    track_size = sectors * SECTOR_SIZE
    raw = bytearray((end + 1) * sides * track_size)
    index = MSA_HEADER
    for track in range(start, end + 1):
        for side in range(sides):
            if index + 2 > len(data):
                raise MSAError(f"archive ends before track {track} side {side}")
            length = int.from_bytes(data[index : index + 2], "big")
            index += 2
            packed = data[index : index + length]
            if len(packed) != length:
                raise MSAError(f"track {track} side {side} is truncated")
            index += length
            if length > track_size:
                raise MSAError(f"track {track} side {side} is too long")
            unpacked = (
                packed if length == track_size else unpack_msa_track(packed, track_size)
            )
            offset = (track * sides + side) * track_size
            raw[offset : offset + track_size] = unpacked
    return bytes(raw)


def hashes_of(data: bytes) -> dict[str, str]:
    return {
        "crc32": f"{zlib.crc32(data) & 0xFFFFFFFF:08x}",
        "md5": hashlib.md5(data, usedforsecurity=False).hexdigest(),
        "sha1": hashlib.sha1(data, usedforsecurity=False).hexdigest(),
        "sha512": hashlib.sha512(data).hexdigest(),
    }


# --------------------------------------------------------------------------
# Matching
# --------------------------------------------------------------------------


class Matcher:
    def __init__(self, disks: list[dict], images: list[dict], appearances: dict):
        self.disks = {int(item["id"]): item for item in disks}
        self.images = images
        self.appearances = appearances
        self.image_by_id = {int(item["id"]): item for item in images}
        self.lookups: dict[str, dict] = {
            "sha1": {},
            "md5": {},
            "crc32": {},
            "sha512": {},
        }
        for image in images:
            for kind, field in (("sha1", "sha1"), ("md5", "md5"), ("sha512", "sha512")):
                value = str(image.get(field) or "").lower()
                if value:
                    self.lookups[kind].setdefault(value, []).append(int(image["id"]))
            crc = str(image.get("crc32") or "").lower()
            size = image.get("size")
            if crc and size is not None:
                self.lookups["crc32"].setdefault((crc, int(size)), []).append(
                    int(image["id"])
                )  # type: ignore[index]
        self.single_titles: dict[str, list[int]] = defaultdict(list)
        for disk in self.disks.values():
            if str(disk["kind"]) != "single":
                continue
            key = self.title_key_for_disk(disk)
            if key:
                self.single_titles[key].append(int(disk["id"]))
        self.sorted_titles = sorted(self.single_titles)

    @staticmethod
    def title_key_for_disk(disk: dict) -> str:
        title = str(disk.get("title") or "")
        if not title:
            for content in disk.get("contents") or []:
                if str(content.get("kind")) == "game":
                    title = str(content.get("title") or "")
                    break
            if not title and disk.get("contents"):
                title = str(disk["contents"][0].get("title") or "")
        return title_key(title)

    def image_quality(self, image_id: int) -> tuple:
        image = self.image_by_id[image_id]
        disk = self.disks.get(int(image["disk_id"]), {})
        return (
            1 if image.get("bad") else 0,
            0 if str(disk.get("kind")) == "single" else 1,
            int(image.get("rank") or 0),
            int(image["id"]),
        )

    def best_for_hashes(self, hashes: dict[str, str]) -> tuple[int, str, str] | None:
        for kind in ("sha1", "md5", "sha512"):
            value = hashes[kind]
            candidates = self.lookups[kind].get(value)
            if candidates:
                best = min(candidates, key=self.image_quality)
                return best, kind, "raw"
        return None

    def best_for_crc(self, crc32: str, size: int) -> tuple[int, str, str] | None:
        candidates = self.lookups["crc32"].get((crc32, size))
        if candidates:
            best = min(candidates, key=self.image_quality)
            return best, "crc32", "raw"
        return None

    def disk_summary(self, disk: dict, image: dict | None = None) -> dict:
        summary = {
            "id": disk.get("id"),
            "label": disk.get("label"),
            "title": disk.get("title"),
            "kind": disk.get("kind"),
            "series": disk.get("series_name"),
            "series_group": disk.get("series_group"),
            "number": disk.get("number"),
            "part": disk.get("part"),
            "version": disk.get("version"),
            "year": disk.get("year"),
            "month": disk.get("month"),
            "day": disk.get("day"),
            "publisher": disk.get("publisher"),
            "cracker": disk.get("cracker"),
            "crew": disk.get("crew"),
            "category": disk.get("category"),
            "contents": [
                {
                    "title": item.get("title"),
                    "kind": item.get("kind"),
                    "publisher": item.get("publisher"),
                    "cracker": item.get("cracker"),
                }
                for item in (disk.get("contents") or [])
            ],
        }
        if image:
            summary["image"] = {
                "id": image.get("id"),
                "name": image.get("name"),
                "format": image.get("format"),
                "flags": image.get("flags"),
                "size": image.get("size"),
                "virus": image.get("virus") or "",
                "virus_damage": bool(image.get("virus_damage")),
                "antivirus": image.get("antivirus") or "",
                "bad": bool(image.get("bad")),
            }
        return summary

    def menu_appearances(self, disk: dict) -> list[dict]:
        key = self.title_key_for_disk(disk)
        if not key:
            return []
        items = []
        for item in self.appearances.get(key, []):
            if int(item["disk_id"]) == int(disk["id"]):
                continue
            items.append(item)
        return items[:12]


def zip_members(path: Path) -> tuple[list[dict], str]:
    candidates: list[dict] = []
    try:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if (
                    info.is_dir()
                    or info.file_size <= 0
                    or info.file_size > MAX_MEMBER_SIZE
                ):
                    continue
                suffix = PurePosixPath(info.filename.replace("\\", "/")).suffix.lower()
                if suffix not in IMAGE_SUFFIXES:
                    continue
                try:
                    data = archive.read(info)
                except (OSError, RuntimeError, zipfile.BadZipFile) as error:
                    candidates.append(
                        {
                            "name": info.filename,
                            "format": suffix.lstrip("."),
                            "decoded": False,
                            "error": str(error),
                        }
                    )
                    continue
                entry: dict = {
                    "name": info.filename,
                    "format": suffix.lstrip("."),
                    "decoded": False,
                    "size": len(data),
                }
                if suffix == ".msa":
                    entry["data"] = data
                    try:
                        raw = decode_msa(data)
                        entry["decoded"] = True
                        entry["raw_size"] = len(raw)
                        entry["raw_hashes"] = hashes_of(raw)
                    except MSAError as error:
                        entry["error"] = str(error)
                elif suffix == ".st":
                    entry["decoded"] = True
                    entry["raw_size"] = len(data)
                    entry["raw_hashes"] = hashes_of(data)
                else:
                    entry["file_hashes"] = hashes_of(data)
                candidates.append(entry)
    except (OSError, zipfile.BadZipFile) as error:
        return [], str(error)
    return candidates, ""


def match_members(
    matcher: Matcher, members: list[dict]
) -> tuple[list[dict], list[int]]:
    matches: list[dict] = []
    disk_ids: list[int] = []
    for member in members:
        found: tuple[int, str, str] | None = None
        raw_hashes = member.get("raw_hashes")
        if raw_hashes:
            found = matcher.best_for_hashes(raw_hashes)
            if found is None:
                found = matcher.best_for_crc(
                    raw_hashes["crc32"], int(member.get("raw_size") or 0)
                )
        file_hashes = member.get("file_hashes")
        if found is None and file_hashes is None and member.get("data") is not None:
            file_hashes = hashes_of(member["data"])
            member["file_hashes"] = file_hashes
        if found is None and file_hashes:
            found = matcher.best_for_hashes(file_hashes)
            if found is None:
                found = matcher.best_for_crc(
                    file_hashes["crc32"], int(member.get("size") or 0)
                )
        if found:
            image_id, kind, _source = found
            image = matcher.image_by_id[image_id]
            disk_id = int(image["disk_id"])
            matches.append(
                {
                    "member": member["name"],
                    "format": member["format"],
                    "method": kind,
                    "image_id": image_id,
                    "disk_id": disk_id,
                }
            )
            if disk_id not in disk_ids:
                disk_ids.append(disk_id)
    return matches, disk_ids


def title_fallback(
    matcher: Matcher, folder: str, game: dict | None, zip_name: str = ""
) -> tuple[dict | None, str, list[int]]:
    keys = [title_key(folder), title_key(title_from_zip(zip_name))]
    if game:
        keys.append(title_key(str(game.get("matched_title") or "")))
    candidate_ids: list[int] = []
    for key in keys:
        for disk_id in matcher.single_titles.get(key, []):
            if disk_id not in candidate_ids:
                candidate_ids.append(disk_id)
    if not candidate_ids:
        # A short local title ("Ween") may be the prefix of the catalogue title
        # ("Ween - The Prophecy"); only use this when nothing matched exactly.
        for key in keys:
            if len(key) < 3:
                continue
            start = bisect.bisect_left(matcher.sorted_titles, key + " ")
            for candidate_key in matcher.sorted_titles[start:]:
                if not candidate_key.startswith(key + " "):
                    break
                for disk_id in matcher.single_titles[candidate_key]:
                    if disk_id not in candidate_ids:
                        candidate_ids.append(disk_id)
                if len(candidate_ids) >= 60:
                    break
            if candidate_ids:
                break
    if not candidate_ids:
        return None, "no-title-match", []

    zip_labels: set[str] = set()
    game_labels: set[str] = set()
    years = set()
    publishers = set()
    # The ZIP stem often names the cracker after " - ", which is more precise
    # than the folder-level gameinfo variants (a folder holds many releases).
    stem = PurePosixPath(zip_name.replace("\\", "/")).stem
    for part in re.split(r"\s+-\s+", stem)[1:]:
        part = re.sub(r"\s+v\d+(?:\.\d+)*$", "", part, flags=re.IGNORECASE).strip()
        if not part or re.fullmatch(r"(19|20)\d{2}", part):
            continue
        value = normalize_name(part)
        if (
            value
            and value not in PLACEHOLDER_GROUPS
            and value not in GENERIC_ZIP_LABELS
        ):
            zip_labels.add(value)
    if game:
        for variant in game.get("variants") or []:
            for field in ("crew", "cracked_by"):
                value = normalize_name(str(variant.get(field) or ""))
                if value and value not in PLACEHOLDER_GROUPS:
                    game_labels.add(value)
            match = re.search(r"(19|20)\d{2}", str(variant.get("release") or ""))
            if match:
                years.add(int(match.group(0)))
            publisher = normalize_name(str(variant.get("publisher") or ""))
            if publisher:
                publishers.add(publisher)

    def disk_labels(disk: dict) -> set[str]:
        return {
            value
            for value in (
                normalize_name(str(disk.get("crew") or "")),
                normalize_name(str(disk.get("cracker") or "")),
            )
            if value
        }

    part_hint = ""
    part_match = re.search(r"\b(?:disk|disks|part)\s*(\d+)\b", stem, re.IGNORECASE)
    if part_match:
        part_hint = part_match.group(1)

    filtered = candidate_ids
    if zip_labels:
        with_zip = [
            disk_id
            for disk_id in filtered
            if disk_labels(matcher.disks[disk_id]) & zip_labels
        ]
        if with_zip:
            filtered = with_zip
    if filtered is candidate_ids and game_labels:
        with_game = [
            disk_id
            for disk_id in filtered
            if disk_labels(matcher.disks[disk_id]) & game_labels
        ]
        if with_game:
            filtered = with_game
    if len(filtered) > 1 and part_hint:
        with_part = [
            disk_id
            for disk_id in filtered
            if str(matcher.disks[disk_id].get("part") or "").split(" ")[0] == part_hint
        ]
        if with_part:
            filtered = with_part
    if len(filtered) > 1 and years:
        with_year = [
            disk_id
            for disk_id in filtered
            if matcher.disks[disk_id].get("year") in years
        ]
        if with_year:
            filtered = with_year
    if len(filtered) > 1 and publishers:
        with_publisher = [
            disk_id
            for disk_id in filtered
            if normalize_name(str(matcher.disks[disk_id].get("publisher") or ""))
            in publishers
        ]
        if with_publisher:
            filtered = with_publisher
    if len(filtered) == 1:
        return matcher.disks[filtered[0]], "title", filtered
    return None, "ambiguous-title", filtered


def resolve_zip(rel: str, root: str, patch: str) -> Path | None:
    for base in (patch, root):
        if base:
            candidate = Path(base) / rel
            if candidate.is_file():
                return candidate
    return None


def load_gameinfo() -> dict[str, dict]:
    data = env("MARCER_DATA_DIR")
    if not data:
        log("warning: MARCER_DATA_DIR not set; title fallback and gap reports "
            "are limited")
        return {}
    path = Path(data) / GAMEINFO_SUBDIR / "games-cracked.json"
    if not path.is_file():
        log(f"warning: {path} not found; title fallback and gap reports are limited")
        return {}
    try:
        payload = read_json(path)
    except (OSError, json.JSONDecodeError) as error:
        log(f"warning: cannot read {path}: {error}")
        return {}
    result = {}
    for game in payload.get("games", []):  # type: ignore[union-attr]
        folder = str(game.get("folder") or "")
        if folder:
            result[folder] = game
    return result


def cmd_match(args: argparse.Namespace) -> int:
    started = time.monotonic()
    meta, disks, images, _crews, appearances = load_index()
    matcher = Matcher(disks, images, appearances)
    gameinfo = load_gameinfo()
    root = env("MARCER_ROOT_DIR")
    patch = env("MARCER_PATCH_DIR")
    tree = args.tree or DEFAULT_TREE

    universe: list[tuple[str, str]] = []
    if args.scan:
        if not root:
            raise SystemExit("error: MARCER_ROOT_DIR is not set")
        for base in (root, patch):
            if not base:
                continue
            tree_path = Path(base) / tree
            if not tree_path.is_dir():
                continue
            for path in tree_path.rglob("*.zip"):
                rel_tree = path.relative_to(tree_path).as_posix()
                universe.append(
                    (
                        f"{tree}/{rel_tree}",
                        rel_tree.rsplit("/", 1)[0] if "/" in rel_tree else "",
                    )
                )
    else:
        index_path = (
            Path(args.index)
            if args.index
            else Path(env("MARCER_OUT_DIR")) / "index.json"
        )
        if not index_path.is_file():
            raise SystemExit(
                f"error: screenshot index not found: {index_path} (use --scan)"
            )
        payload = read_json(index_path)
        for key in payload.get("entries", {}):  # type: ignore[union-attr]
            if not key.startswith(tree + "/"):
                continue
            parts = key[len(tree) + 1 :].split("/")
            if len(parts) < 3:
                continue
            if len(parts) != 3 and not args.include_subdirs:
                continue
            universe.append((key, key[len(tree) + 1 :]))
    universe.sort(key=lambda item: item[0])
    if args.limit:
        universe = universe[: args.limit]
    log(f"match: {len(universe):,} ZIPs from {tree}{' (scan)' if args.scan else ''}")

    results: dict[str, dict] = {}
    counts: Counter = Counter()
    formats: Counter = Counter()
    methods: Counter = Counter()
    virus_count = 0
    appearance_count = 0
    missing_files = 0

    for position, (rel, rel_tree) in enumerate(universe, start=1):
        folder = rel_tree.split("/")[1] if rel_tree.count("/") >= 1 else rel_tree
        zip_path = resolve_zip(rel, root, patch)
        entry: dict = {
            "status": "unmatched",
            "method": None,
            "confidence": None,
            "folder": folder,
            "zip": PurePosixPath(rel).name,
            "image": {"members": 0, "formats": [], "decoded": 0, "errors": 0},
        }
        if zip_path is None:
            missing_files += 1
            entry["status"] = "missing"
            entry["reason"] = "ZIP not found in root or patch layer"
            results[rel] = entry
            counts["missing"] += 1
            continue
        members, zip_error = zip_members(zip_path)
        entry["image"]["members"] = len(members)
        entry["image"]["formats"] = sorted({member["format"] for member in members})
        entry["image"]["decoded"] = sum(
            1 for member in members if member.get("decoded")
        )
        entry["image"]["errors"] = sum(1 for member in members if member.get("error"))
        for member in members:
            formats[member["format"]] += 1
        if zip_error:
            entry["reason"] = f"ZIP error: {zip_error}"

        member_matches, disk_ids = match_members(matcher, members)
        if disk_ids:
            best_disk_id = min(
                disk_ids,
                key=lambda disk_id: matcher.image_quality(
                    next(
                        int(item["image_id"])
                        for item in member_matches
                        if int(item["disk_id"]) == disk_id
                    )
                ),
            )
            disk = matcher.disks[best_disk_id]
            chosen_match = next(
                item for item in member_matches if int(item["disk_id"]) == best_disk_id
            )
            image = matcher.image_by_id.get(int(chosen_match["image_id"]))
            entry.update(
                {
                    "status": "matched",
                    "method": chosen_match["method"],
                    "confidence": "exact",
                    "disk": matcher.disk_summary(disk, image),
                    "disk_ids": disk_ids,
                    "members": member_matches,
                    "menu_appearances": matcher.menu_appearances(disk),
                }
            )
            counts["matched"] += 1
            counts[f"hash-{entry['method']}"] += 1
            methods[entry["method"]] += 1
            if entry["menu_appearances"]:
                appearance_count += 1
            image_info = entry["disk"].get("image") or {}
            if image_info.get("virus") or image_info.get("virus_damage"):
                virus_count += 1
        else:
            game = gameinfo.get(folder)
            disk, reason, candidate_ids = title_fallback(
                matcher, folder, game, entry["zip"]
            )
            if disk is not None:
                entry.update(
                    {
                        "status": "matched",
                        "method": "title",
                        "confidence": "likely",
                        "disk": matcher.disk_summary(disk),
                        "disk_ids": [int(disk["id"])],
                        "menu_appearances": matcher.menu_appearances(disk),
                    }
                )
                counts["matched"] += 1
                methods["title"] += 1
                if entry["menu_appearances"]:
                    appearance_count += 1
            elif candidate_ids:
                entry.update(
                    {
                        "status": "ambiguous",
                        "reason": reason,
                        "candidates": [
                            {
                                "disk_id": disk_id,
                                "label": matcher.disks[disk_id].get("label"),
                                "year": matcher.disks[disk_id].get("year"),
                                "crew": matcher.disks[disk_id].get("crew"),
                                "cracker": matcher.disks[disk_id].get("cracker"),
                            }
                            for disk_id in candidate_ids[:10]
                        ],
                    }
                )
                counts["ambiguous"] += 1
            else:
                entry["reason"] = reason
                counts["unmatched"] += 1
        results[rel] = entry
        if position % 250 == 0 or position == len(universe):
            elapsed = time.monotonic() - started
            rate = position / elapsed if elapsed else 0
            log(
                f"  {position:,}/{len(universe):,} "
                f"(matched {counts['matched']:,}, unmatched {counts['unmatched']:,}, "
                f"ambiguous {counts['ambiguous']:,}, {rate:.1f} ZIP/s)"
            )

    elapsed = time.monotonic() - started
    payload = {
        "schema": MATCH_SCHEMA,
        "tool": "tools/piratefinder-gen",
        "tool_version": TOOL_VERSION,
        "generated_at": utc_now(),
        "source": meta.get("source", {}),
        "universe": {
            "tree": tree,
            "total": len(universe),
            "scan": bool(args.scan),
            "include_subdirs": bool(args.include_subdirs),
        },
        "counts": {
            "matched": counts["matched"],
            "unmatched": counts["unmatched"],
            "ambiguous": counts["ambiguous"],
            "missing": counts["missing"],
            "virus": virus_count,
            "with_menu_appearances": appearance_count,
            "methods": dict(methods),
        },
        "runtime_seconds": round(elapsed, 1),
        "results": results,
    }
    ensure_dir(match_dir())
    write_json(match_dir() / "matches.json", payload)
    write_lines(
        match_dir() / "unmatched.txt",
        [rel for rel, item in results.items() if item["status"] == "unmatched"],
    )
    write_lines(
        match_dir() / "ambiguous.txt",
        [rel for rel, item in results.items() if item["status"] == "ambiguous"],
    )
    write_lines(
        match_dir() / "missing.txt",
        [rel for rel, item in results.items() if item["status"] == "missing"],
    )
    log(
        f"match: {counts['matched']:,} matched, {counts['unmatched']:,} unmatched, "
        f"{counts['ambiguous']:,} ambiguous, {counts['missing']:,} missing in {elapsed:.1f}s"
    )
    write_reports(payload, gameinfo)
    return 0


def write_lines(path: Path, values: list[str]) -> None:
    ensure_dir(path.parent)
    path.write_text("\n".join(values) + ("\n" if values else ""), encoding="utf-8")


# --------------------------------------------------------------------------
# Reports
# --------------------------------------------------------------------------


def load_groups() -> dict[str, dict[str, object]]:
    path = index_dir() / "groups.json"
    if not path.is_file():
        return {"exact": {}, "alias": {}}
    payload = read_json(path)
    exact: dict[str, str] = {}
    alias: dict[str, str] = {}
    for group in payload.get("groups", []):  # type: ignore[union-attr]
        platforms = group.get("platforms") or []
        if platforms and not any(platform_is_st(str(item)) for item in platforms):
            continue
        name = str(group.get("name") or "")
        if not name:
            continue
        exact[normalize_name(name)] = name
        for value in (group.get("aliases") or []) + (group.get("abbreviations") or []):
            alias[normalize_name(str(value))] = name
    return {"exact": exact, "alias": alias}


def game_labels(game: dict | None) -> dict[str, set[str]]:
    labels: set[str] = set()
    years: set[str] = set()
    publishers: set[str] = set()
    if not game:
        return {"labels": labels, "years": years, "publishers": publishers}
    for variant in game.get("variants") or []:
        for field in ("crew", "cracked_by"):
            value = str(variant.get(field) or "").strip()
            if normalize_name(value) not in PLACEHOLDER_GROUPS:
                labels.add(value)
        release = str(variant.get("release") or "").strip()
        match = re.search(r"(19|20)\d{2}", release)
        if match:
            years.add(match.group(0))
        publisher = str(variant.get("publisher") or "").strip()
        if publisher:
            publishers.add(publisher)
    return {"labels": labels, "years": years, "publishers": publishers}


def write_reports(payload: dict, gameinfo: dict[str, dict]) -> None:
    out = ensure_dir(report_dir())
    results: dict[str, dict] = payload["results"]
    counts = payload["counts"]
    universe = payload["universe"]

    matched = {
        rel: item for rel, item in results.items() if item["status"] == "matched"
    }
    image_zips = {
        rel: item for rel, item in results.items() if item["image"]["members"] > 0
    }
    hash_matched = {
        rel: item for rel, item in matched.items() if item["method"] != "title"
    }
    title_matched = {
        rel: item for rel, item in matched.items() if item["method"] == "title"
    }
    virus = {
        rel: item
        for rel, item in matched.items()
        if (item["disk"].get("image") or {}).get("virus")
    }
    virus_damage = {
        rel: item
        for rel, item in matched.items()
        if (item["disk"].get("image") or {}).get("virus_damage")
    }
    with_appearances = {
        rel: item for rel, item in matched.items() if item.get("menu_appearances")
    }

    pf_crews = set()
    for crew in read_json(index_dir() / "crews-st.json")["crews"]:  # type: ignore[index]
        if crew.get("name"):
            pf_crews.add(normalize_name(str(crew["name"])))
    for item in matched.values():
        for field in ("crew", "cracker"):
            value = normalize_name(str(item["disk"].get(field) or ""))
            if value:
                pf_crews.add(value)
    groups = load_groups()
    exact_groups: dict[str, str] = groups["exact"]  # type: ignore[assignment]
    alias_groups: dict[str, str] = groups["alias"]  # type: ignore[assignment]

    label_zips: Counter = Counter()
    label_pf: dict[str, str] = {}
    for rel, item in results.items():
        game = gameinfo.get(item.get("folder") or "")
        for label in game_labels(game)["labels"]:
            label_zips[label] += 1
    for label in label_zips:
        key = normalize_name(label)
        if key in exact_groups:
            label_pf[label] = exact_groups[key]
        elif key in alias_groups:
            label_pf[label] = alias_groups[key]
        elif key in pf_crews:
            label_pf[label] = label

    crew_rows = []
    for label, zips in label_zips.most_common():
        key = normalize_name(label)
        pf_name = label_pf.get(label, "")
        best = ""
        score = ""
        if not pf_name:
            key_tokens = set(key.split())
            close = difflib.get_close_matches(key, sorted(pf_crews), n=3, cutoff=0.75)
            for candidate in close:
                if not key_tokens & set(candidate.split()):
                    continue
                best = candidate
                score = f"{difflib.SequenceMatcher(None, key, candidate).ratio():.2f}"
                break
        crew_rows.append(
            {
                "group": label,
                "zips": zips,
                "pf_exact": "yes" if key in pf_crews or key in exact_groups else "no",
                "pf_alias": "yes" if key in alias_groups else "no",
                "pf_name": pf_name,
                "best_pf_candidate": best,
                "score": score,
            }
        )
    write_csv(
        out / "crew-coverage.csv",
        [
            "group",
            "zips",
            "pf_exact",
            "pf_alias",
            "pf_name",
            "best_pf_candidate",
            "score",
        ],
        crew_rows,
    )
    write_csv(
        out / "alias-candidates.csv",
        ["group", "zips", "best_pf_candidate", "score"],
        [
            {
                "group": row["group"],
                "zips": row["zips"],
                "best_pf_candidate": row["best_pf_candidate"],
                "score": row["score"],
            }
            for row in crew_rows
            if row["pf_exact"] == "no"
            and row["pf_alias"] == "no"
            and row["best_pf_candidate"]
        ],
    )

    gap_rows = []
    for rel, item in matched.items():
        folder = item.get("folder") or ""
        game = gameinfo.get(folder)
        if not game:
            continue
        variant = (game.get("variants") or [{}])[0]
        disk = item["disk"]
        fields = {
            "year": (str(variant.get("release") or ""), str(disk.get("year") or "")),
            "publisher": (
                str(variant.get("publisher") or ""),
                str(disk.get("publisher") or ""),
            ),
            "crew": (
                str(variant.get("crew") or variant.get("cracked_by") or ""),
                str(disk.get("crew") or ""),
            ),
            "cracker": (
                str(variant.get("cracked_by") or ""),
                str(disk.get("cracker") or ""),
            ),
        }
        missing = [
            name
            for name, (local, remote) in fields.items()
            if not local.strip() and remote.strip()
        ]
        if not missing:
            continue
        gap_rows.append(
            {
                "folder": folder,
                "zip": item["zip"],
                "pf_label": disk.get("label") or "",
                "gap_fields": " ".join(missing),
                **{f"{name}_marcer": value[0] for name, value in fields.items()},
                **{f"{name}_pf": value[1] for name, value in fields.items()},
            }
        )
    write_csv(
        out / "gameinfo-gaps.csv",
        [
            "folder",
            "zip",
            "pf_label",
            "gap_fields",
            "year_marcer",
            "year_pf",
            "publisher_marcer",
            "publisher_pf",
            "crew_marcer",
            "crew_pf",
            "cracker_marcer",
            "cracker_pf",
        ],
        gap_rows,
    )

    match_rows = []
    for rel, item in sorted(results.items()):
        disk = item.get("disk") or {}
        match_rows.append(
            {
                "zip": rel,
                "status": item["status"],
                "method": item["method"] or "",
                "confidence": item["confidence"] or "",
                "pf_label": disk.get("label") or "",
                "pf_kind": disk.get("kind") or "",
                "pf_year": disk.get("year") or "",
                "pf_publisher": disk.get("publisher") or "",
                "pf_crew": disk.get("crew") or "",
                "pf_cracker": disk.get("cracker") or "",
                "virus": (disk.get("image") or {}).get("virus") or "",
            }
        )
    write_csv(
        out / "matches.csv",
        [
            "zip",
            "status",
            "method",
            "confidence",
            "pf_label",
            "pf_kind",
            "pf_year",
            "pf_publisher",
            "pf_crew",
            "pf_cracker",
            "virus",
        ],
        match_rows,
    )

    top_crews = Counter()
    for item in matched.values():
        value = str(item["disk"].get("crew") or "").strip()
        if value:
            top_crews[value] += 1
    top_unmatched = Counter(
        item.get("folder") or ""
        for rel, item in results.items()
        if item["status"] == "unmatched"
    )

    source = payload.get("source") or {}
    lines = [
        "# PirateFinder catalogue match report",
        "",
        f"Generated: {payload.get('generated_at')}  ",
        f"Source: `{source.get('repo', REPO)}` `{source.get('tag', '?')}`  ",
        "Catalogue licence: CC BY-NC-SA 4.0 (not redistributed)",
        "",
        "## Universe",
        "",
        f"- Tree: `{universe.get('tree')}`",
        f"- ZIPs: **{universe.get('total'):,}**",
        f"- With a decodable/recognised image member: **{len(image_zips):,}**",
        f"- Matched by hash: **{len(hash_matched):,}**",
        f"- Matched by title fallback: **{len(title_matched):,}**",
        f"- Unmatched: **{counts.get('unmatched', 0):,}**",
        f"- Ambiguous: **{counts.get('ambiguous', 0):,}**",
        f"- Missing files: **{counts.get('missing', 0):,}**",
        f"- Runtime: {payload.get('runtime_seconds', 0)} s",
        "",
        "## Methods",
        "",
    ]
    for method, count in sorted(
        (counts.get("methods") or {}).items(), key=lambda item: (-item[1], item[0])
    ):
        lines.append(f"- `{method}`: {count:,}")
    lines += [
        "",
        "## Enrichment",
        "",
        f"- Matched with a nameable boot virus: **{len(virus):,}**",
        f"- Matched with virus damage: **{len(virus_damage):,}**",
        f"- Matched with menu-disk appearances: **{len(with_appearances):,}**",
        (
            f"- Crew labels in gameinfo: **{len(label_zips):,}**; "
            f"exact/alias-covered by PF: **{sum(1 for row in crew_rows if row['pf_name']):,}**"
        ),
        "",
        "## Top PF crews among matched ZIPs",
        "",
        "| # | Crew | ZIPs |",
        "|---:|---|---:|",
    ]
    for number, (crew, count) in enumerate(top_crews.most_common(25), start=1):
        lines.append(f"| {number} | {crew} | {count:,} |")
    lines += [
        "",
        "## Top unmatched folders",
        "",
        "| # | Folder | ZIPs |",
        "|---:|---|---:|",
    ]
    for number, (folder, count) in enumerate(top_unmatched.most_common(20), start=1):
        lines.append(f"| {number} | {folder} | {count:,} |")
    lines += [
        "",
        "## Files",
        "",
        "- `matches.json` — full per-ZIP result",
        "- `matches.csv` — flat summary",
        "- `crew-coverage.csv` / `alias-candidates.csv` — Marcer crew labels vs. PF",
        "- `gameinfo-gaps.csv` — PF values missing in the local XLS metadata",
        "- `unmatched.txt`, `ambiguous.txt`, `missing.txt`",
        "",
    ]
    (out / "report.md").write_text("\n".join(lines), encoding="utf-8")
    log(f"report: {out / 'report.md'}")


def write_csv(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    ensure_dir(path.parent)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def cmd_report(args: argparse.Namespace) -> int:
    path = match_dir() / "matches.json"
    if not path.is_file():
        raise SystemExit(f"error: {path} not found; run `run.sh match` first")
    payload = read_json(path)
    write_reports(payload, load_gameinfo())  # type: ignore[arg-type]
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Import and match the PirateFinder catalogue."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    fetch = sub.add_parser(
        "fetch", help="download the newest catalogue release and verify its checksum"
    )
    fetch.add_argument(
        "--tag", help="specific catalogue tag, e.g. catalogue-2026-10-19"
    )
    fetch.add_argument(
        "--force", action="store_true", help="download/extract again even when cached"
    )
    fetch.set_defaults(func=cmd_fetch)

    extract = sub.add_parser(
        "extract", help="extract the Atari ST subset into compact JSON"
    )
    extract.add_argument("--force", action="store_true", help="ignore cached output")
    extract.set_defaults(func=cmd_extract)

    match = sub.add_parser(
        "match", help="match the cracked ZIP universe against the catalogue"
    )
    match.add_argument(
        "--index", help="screenshot index.json (default: $MARCER_OUT_DIR/index.json)"
    )
    match.add_argument(
        "--scan",
        action="store_true",
        help="scan the game tree instead of using index.json",
    )
    match.add_argument(
        "--include-subdirs",
        action="store_true",
        help="include STX/Original/... subfolders",
    )
    match.add_argument(
        "--limit", type=int, default=0, help="only the first N ZIPs (trial run)"
    )
    match.add_argument(
        "--tree",
        default=DEFAULT_TREE,
        help=f"tree below the game root (default: {DEFAULT_TREE})",
    )
    match.set_defaults(func=cmd_match)

    report = sub.add_parser("report", help="regenerate reports from matches.json")
    report.set_defaults(func=cmd_report)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
