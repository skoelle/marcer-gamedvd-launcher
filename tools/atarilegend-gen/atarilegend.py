#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""AtariLegend metadata importer / matcher for the Marcer GameDVD launcher.

Implements the first milestone of the AtariLegend integration:

  fetch    resolve and download the newest weekly MariaDB dump
           (``YYYY-MM-DD.sql.gz``) into MARCER_ATARILEGEND_DIR/dump
  match    parse the needed tables from the dump, build the AtariLegend
           name index, match it against the screenshot-index folders
           (index.json / index-pd.json / index-utils.json) and write a
           match report (text + JSON) into MARCER_ATARILEGEND_DIR
  report   print a table inventory (row counts) of the relevant tables

The MariaDB dump is parsed with the Python standard library only; no extra
dependencies are required. Paths come exclusively from environment variables
(see run.sh and local/paths.env). This file contains no real data paths.
"""
import argparse
import difflib
import gzip
import json
import os
import re
import sys
import tempfile
import time
import unicodedata
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

TOOL_VERSION = "0.1.0"
SCHEMA_VERSION = 1

BASE_URL = "https://www.atarilegend.com/data/database-dumps/"
DUMP_RE = re.compile(r"(\d{4}-\d{2}-\d{2})\.sql\.gz")

KINDS = ("cracked", "pd", "utils")

INDEX_FILES = {
    "cracked": "index.json",
    "pd": "index-pd.json",
    "utils": "index-utils.json",
}

# Tables parsed for the match (namespace: name -> fields needed).
# Only small/needed tables are parsed; the full dump is never imported.
RELEVANT_TABLES = (
    "games",
    "game_akas",
    "game_releases",
    "game_release_akas",
    "game_release_scans",
    "game_screenshot",
    "companies",
    "genres",
    "game_genre",
    "game_developer",
    "game_individual",
    "individuals",
    "crews",
    "dumps",
)

DEFAULT_CONFIG = {
    "fuzzy_cutoff": 0.90,
    "block_size": 3,
    "unescape": {
        "0": "\0",
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "Z": "\x1a",
        "b": "\b",
    },
}


def log(msg: str) -> None:
    print(f"[atarilegend] {msg}", flush=True)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _deep_merge(base: dict, over: dict) -> None:
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _deep_merge(base[k], v)
        else:
            base[k] = v


def load_config() -> dict:
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    root = repo_root() / "tools" / "atarilegend-gen"
    for name in ("config.example.json", "config.local.json"):
        p = root / name
        if p.exists():
            with open(p, encoding="utf-8") as f:
                _deep_merge(cfg, json.load(f))
    return cfg


def out_dir(explicit: str | None) -> Path:
    d = (explicit or os.environ.get("MARCER_ATARILEGEND_DIR", "")).strip()
    if not d:
        sys.exit("error: set MARCER_ATARILEGEND_DIR (local/paths.env) or --dir")
    return Path(d)


def out_dir_optional(explicit: str | None) -> Path | None:
    d = (explicit or os.environ.get("MARCER_ATARILEGEND_DIR", "")).strip()
    return Path(d) if d else None


def index_dir_optional(explicit: str | None) -> Path | None:
    d = (explicit or os.environ.get("MARCER_OUT_DIR", "")).strip()
    return Path(d) if d else None


# --------------------------------------------------------------------------
# MariaDB dump parsing (stdlib only)
# --------------------------------------------------------------------------

def _unescape(seq: str, table: dict) -> str:
    return table.get(seq, seq)


def _parse_quoted(text: str, i: int, esc_table: dict) -> tuple:
    """Parse a single-quoted SQL string at ``text[i] == "'"``.

    Returns (value, index_after_closing_quote).
    """
    i += 1
    out = []
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            out.append(_unescape(text[i + 1], esc_table))
            i += 2
            continue
        if c == "'":
            if i + 1 < n and text[i + 1] == "'":
                out.append("'")
                i += 2
                continue
            return "".join(out), i + 1
        out.append(c)
        i += 1
    return "".join(out), i


def _parse_unquoted(text: str, i: int) -> tuple:
    """Parse an unquoted SQL token (number, NULL, hex, function call)."""
    n = len(text)
    depth = 0
    start = i
    while i < n:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                break
            depth -= 1
        elif c == "," and depth == 0:
            break
        i += 1
    return text[start:i].strip(), i


def iter_insert_rows(text: str, table: str, esc_table: dict):
    """Yield rows (list of str|None) of all INSERT statements of ``table``."""
    marker = f"INSERT INTO `{table}` VALUES"
    pos = 0
    n = len(text)
    while True:
        start = text.find(marker, pos)
        if start < 0:
            return
        i = start + len(marker)
        while i < n:
            c = text[i]
            if c == ";":
                i += 1
                break
            if c in " \t\r\n,":
                i += 1
                continue
            if c != "(":
                i += 1
                continue
            i += 1
            row = []
            while True:
                while i < n and text[i] in " \t\r\n":
                    i += 1
                if i < n and text[i] == "'":
                    val, i = _parse_quoted(text, i, esc_table)
                else:
                    val, i = _parse_unquoted(text, i)
                    if val is not None and val.upper() == "NULL":
                        val = None
                row.append(val)
                while i < n and text[i] in " \t\r\n":
                    i += 1
                if i < n and text[i] == ",":
                    i += 1
                    continue
                if i < n and text[i] == ")":
                    i += 1
                    break
                break
            yield row
        pos = i


def read_dump(path: Path) -> str:
    if str(path).endswith(".gz"):
        with gzip.open(path, "rt", encoding="utf-8", errors="replace") as f:
            return f.read()
    return path.read_text(encoding="utf-8", errors="replace")


def latest_cached_dump(dump_dir: Path) -> Path | None:
    if not dump_dir.is_dir():
        return None
    dumps = sorted(dump_dir.glob("*.sql.gz"))
    return dumps[-1] if dumps else None


# --------------------------------------------------------------------------
# normalization / name index
# --------------------------------------------------------------------------

def norm_key(s: str | None) -> str:
    """Normalize a title for matching (casefold, punctuation, articles)."""
    if not s:
        return ""
    s = unicodedata.normalize("NFKD", s)
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    s = s.lower().replace("&", " and ")
    s = "".join(ch if ch.isalnum() else " " for ch in s)
    s = " ".join(s.split())
    m = re.match(r"^(.*?), (a|an|the)$", s)
    if m:
        s = f"{m.group(2)} {m.group(1)}"
    return " ".join(t for t in s.split() if t not in ("a", "an", "the"))


def _as_id(v):
    if isinstance(v, str) and v.isdigit():
        return int(v)
    return v


def build_name_index(rows_by_table: dict, block_size: int = 3) -> tuple:
    """Return (key_index, block_index, short_keys, display, total_games).

    key_index:   {norm_key: set(game_id)}
    block_index: {first N chars: [norm_key, ...]}
    display:     {game_id: original game name}
    """
    games = rows_by_table.get("games", [])
    akas = rows_by_table.get("game_akas", [])
    releases = rows_by_table.get("game_releases", [])
    rel_akas = rows_by_table.get("game_release_akas", [])

    key_index = {}
    display = {}
    for r in games:
        if len(r) < 2:
            continue
        gid = _as_id(r[0])
        display[gid] = r[1] or ""
        k = norm_key(r[1])
        if k:
            key_index.setdefault(k, set()).add(gid)

    def add(name, gid):
        gid = _as_id(gid)
        k = norm_key(name)
        if k and gid is not None:
            key_index.setdefault(k, set()).add(gid)

    for r in akas:
        if len(r) >= 3:
            add(r[2], r[1])

    release_to_game = {}
    for r in releases:
        if len(r) >= 3:
            release_to_game[r[0]] = r[1]
            if r[2]:
                add(r[2], r[1])

    for r in rel_akas:
        if len(r) >= 3:
            add(r[2], release_to_game.get(r[1]))

    block_index = {}
    short_keys = []
    for k in key_index:
        if len(k) < block_size:
            short_keys.append(k)
        else:
            block_index.setdefault(k[:block_size], []).append(k)

    return key_index, block_index, short_keys, display, len(games)


def match_folder(folder, key_index, block_index, short_keys, cfg):
    """Return (game_id, matched_key, via, confidence)."""
    k = norm_key(folder)
    if not k:
        return None, "", "none", 0.0
    ids = key_index.get(k)
    if ids:
        return sorted(ids)[0], k, "exact", 1.0

    block = cfg["block_size"]
    pool = list(block_index.get(k[:block], [])) if len(k) >= block else []
    pool.extend(short_keys)

    best = None
    for a in pool:
        if k.startswith(a + " ") or a.startswith(k + " "):
            if best is None or len(a) > len(best):
                best = a
    if best is not None:
        return sorted(key_index[best])[0], best, "prefix", 0.95

    close = difflib.get_close_matches(k, pool, n=1, cutoff=cfg["fuzzy_cutoff"])
    if close:
        a = close[0]
        ratio = difflib.SequenceMatcher(None, k, a).ratio()
        return sorted(key_index[a])[0], a, "fuzzy", round(ratio, 3)
    return None, "", "none", 0.0


# --------------------------------------------------------------------------
# screenshot-index folder extraction
# --------------------------------------------------------------------------

def read_index_folders(path: Path) -> dict:
    """Return {(letter, folder): zip_count} for one screenshot index file."""
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    folders = {}
    for rel in (data.get("entries") or {}):
        parts = rel.split("/")
        if len(parts) < 4:
            continue
        key = (parts[2], parts[3])
        folders[key] = folders.get(key, 0) + 1
    return folders


def parse_relevant_tables(text: str, cfg: dict, tables=RELEVANT_TABLES) -> dict:
    esc = cfg["unescape"]
    out = {}
    for t in tables:
        out[t] = list(iter_insert_rows(text, t, esc))
    return out


# --------------------------------------------------------------------------
# atomic writes
# --------------------------------------------------------------------------

def atomic_write_text(path: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=".txt")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def atomic_write_json(path: Path, obj) -> None:
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, indent=1, sort_keys=False)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_fetch(args) -> int:
    d = out_dir(args.dir)
    dump_dir = d / "dump"
    dump_dir.mkdir(parents=True, exist_ok=True)

    if args.dump:
        src = Path(args.dump)
        if not src.is_file():
            sys.exit(f"error: dump not found: {src}")
        log(f"using local dump: {src}")
        return 0

    log(f"resolving latest dump from {BASE_URL}")
    with urllib.request.urlopen(BASE_URL, timeout=60) as resp:
        listing = resp.read().decode("utf-8", "replace")
    dates = sorted({m.group(1) for m in DUMP_RE.finditer(listing)})
    if not dates:
        sys.exit("error: no YYYY-MM-DD.sql.gz found in directory listing")
    latest = dates[-1]
    target = dump_dir / f"{latest}.sql.gz"

    if target.exists() and not args.force:
        log(f"already cached: {target} ({target.stat().st_size} bytes)")
        return 0

    url = f"{BASE_URL}{latest}.sql.gz"
    log(f"downloading {url}")
    tmp = target.with_suffix(".sql.gz.part")
    with urllib.request.urlopen(url, timeout=600) as resp, open(tmp, "wb") as f:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    os.replace(tmp, target)
    log(f"saved {target} ({target.stat().st_size} bytes)")
    return 0


def _resolve_dump_path(args, d: Path | None) -> Path:
    if args.dump:
        p = Path(args.dump)
        if not p.is_file():
            sys.exit(f"error: dump not found: {p}")
        return p
    if d is not None:
        cached = latest_cached_dump(d / "dump")
        if cached:
            return cached
    sys.exit("error: no dump given; run `fetch` first or pass --dump PATH")


def cmd_report(args) -> int:
    cfg = load_config()
    d = out_dir_optional(args.dir)
    dump = _resolve_dump_path(args, d)
    log(f"reading dump: {dump}")
    text = read_dump(dump)

    print(f"{'table':28} {'rows':>10}")
    print("-" * 40)
    total = 0
    for t in RELEVANT_TABLES:
        n = sum(1 for _ in iter_insert_rows(text, t, cfg["unescape"]))
        total += n
        print(f"{t:28} {n:>10}")
    print("-" * 40)
    print(f"{'TOTAL':28} {total:>10}")
    return 0


def cmd_match(args) -> int:
    cfg = load_config()
    d = out_dir(args.dir)
    d.mkdir(parents=True, exist_ok=True)
    dump = _resolve_dump_path(args, d)
    log(f"reading dump: {dump}")
    text = read_dump(dump)

    idir = index_dir_optional(args.index_dir)
    if idir is None:
        sys.exit("error: set MARCER_OUT_DIR (local/paths.env) or pass --index-dir")

    log("parsing tables")
    t0 = time.time()
    rows = parse_relevant_tables(text, cfg)
    key_index, block_index, short_keys, display, total_games = build_name_index(
        rows, cfg["block_size"])
    log(f"AtariLegend games: {total_games}, distinct name keys: {len(key_index)} "
        f"({time.time() - t0:.1f}s)")

    sections = KINDS if args.section == "all" else (args.section,)
    result_sections = {}
    folder_map = {}
    matched_ids = set()
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    for kind in sections:
        idx = idir / INDEX_FILES[kind]
        if not idx.is_file():
            log(f"skip {kind}: {idx} not found")
            continue
        folders = read_index_folders(idx)
        stats = {"folders": len(folders), "exact": 0, "prefix": 0,
                 "fuzzy": 0, "none": 0, "ambiguous": 0, "zips": 0}
        unmatched = []
        ambiguous = []
        for (letter, folder), nzips in sorted(folders.items()):
            stats["zips"] += nzips
            ids = key_index.get(norm_key(folder))
            gid, key, via, conf = match_folder(
                folder, key_index, block_index, short_keys, cfg)
            if gid is None:
                stats["none"] += 1
                unmatched.append(folder)
                continue
            stats[via] += 1
            if ids and len(ids) > 1:
                stats["ambiguous"] += 1
                ambiguous.append({"folder": folder, "candidates": sorted(ids)})
            matched_ids.add(gid)
            folder_map[f"{kind}|{letter}|{folder}"] = {
                "al_game_id": gid,
                "al_name": display.get(gid, ""),
                "matched_via": via,
                "confidence": conf,
            }
        result_sections[kind] = {
            "stats": stats,
            "unmatched": sorted(unmatched),
            "ambiguous": ambiguous,
        }
        hit = stats["folders"] - stats["none"]
        pct = 100 * hit / stats["folders"] if stats["folders"] else 0.0
        log(f"[{kind}] folders={stats['folders']} exact={stats['exact']} "
            f"prefix={stats['prefix']} fuzzy={stats['fuzzy']} "
            f"unmatched={stats['none']} -> {pct:.1f}%")

    payload = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": generated_at,
        "generator": f"tools/atarilegend-gen {TOOL_VERSION}",
        "source": {"file": dump.name},
        "totals": {
            "atarilegend_games": total_games,
            "matched_atarilegend_games": len(matched_ids),
            "folders": sum(s["stats"]["folders"] for s in result_sections.values()),
        },
        "sections": {k: {"stats": v["stats"]} for k, v in result_sections.items()},
        "folders": folder_map,
        "unmatched": {k: v["unmatched"] for k, v in result_sections.items()},
        "ambiguous": {k: v["ambiguous"] for k, v in result_sections.items()},
    }

    if args.json:
        jp = Path(args.json)
        atomic_write_json(jp, payload)
        log(f"wrote {jp}")

    base = d / "atarilegend-match"
    atomic_write_json(base.with_suffix(".json"), payload)
    atomic_write_text(base.with_suffix(".txt"),
                      build_text_report(payload, result_sections))
    log(f"wrote {base}.json / {base}.txt")
    return 0


def build_text_report(payload: dict, sections: dict) -> str:
    lines = ["# atarilegend-gen match report", ""]
    lines.append(f"generated_at: {payload['generated_at']}")
    lines.append(f"source: {payload['source']['file']}")
    lines.append(f"atarilegend games: {payload['totals']['atarilegend_games']}")
    lines.append(f"matched atarilegend games: "
                 f"{payload['totals']['matched_atarilegend_games']}")
    lines.append("")
    for kind, res in sections.items():
        s = res["stats"]
        hit = s["folders"] - s["none"]
        pct = 100 * hit / s["folders"] if s["folders"] else 0.0
        lines.append(f"## {kind}")
        lines.append("")
        lines.append(f"folders={s['folders']} zips={s['zips']} "
                     f"exact={s['exact']} prefix={s['prefix']} fuzzy={s['fuzzy']} "
                     f"unmatched={s['none']} ambiguous={s['ambiguous']} "
                     f"-> {pct:.1f}%")
        lines.append("")
        lines.append(f"### unmatched folders ({len(res['unmatched'])})")
        for f in res["unmatched"]:
            lines.append(f"  {f}")
        lines.append("")
        if res["ambiguous"]:
            lines.append(f"### ambiguous folders ({len(res['ambiguous'])})")
            for a in res["ambiguous"]:
                lines.append(f"  {a['folder']} -> {a['candidates']}")
            lines.append("")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# cli
# --------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        prog="atarilegend",
        description="AtariLegend metadata importer/matcher for the Marcer GameDVD launcher")
    ap.add_argument("--version", action="version", version=f"atarilegend {TOOL_VERSION}")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_f = sub.add_parser("fetch", help="download the newest weekly dump")
    p_f.add_argument("--dir", help="output dir (default MARCER_ATARILEGEND_DIR)")
    p_f.add_argument("--dump", help="use an existing local dump instead of downloading")
    p_f.add_argument("--force", action="store_true", help="re-download even if cached")
    p_f.set_defaults(func=cmd_fetch)

    p_m = sub.add_parser("match", help="match dump against the screenshot index")
    p_m.add_argument("--dir", help="output dir (default MARCER_ATARILEGEND_DIR)")
    p_m.add_argument("--dump", help="dump file to use (default: newest cached)")
    p_m.add_argument("--index-dir",
                     help="screenshot index dir (default MARCER_OUT_DIR)")
    p_m.add_argument("--section", choices=("all",) + KINDS, default="all")
    p_m.add_argument("--json", help="also write the JSON report to this path")
    p_m.set_defaults(func=cmd_match)

    p_r = sub.add_parser("report", help="print a table inventory of the dump")
    p_r.add_argument("--dir", help="output dir (default MARCER_ATARILEGEND_DIR)")
    p_r.add_argument("--dump", help="dump file to use (default: newest cached)")
    p_r.set_defaults(func=cmd_report)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
