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
  extract  mirror ALL dump tables into a queryable SQLite database
           (atarilegend.sqlite) and store the folder->game match mapping;
           this is a tool-side analysis artifact (not shipped by the app)
  index    write the compact runtime index the app builds itself
           (folder->game mapping + developer/author/genre facets)
  detail   assemble the "AtariLegend details" payload for one game
           (reference for the app's detail panel)
  fixtures write detail fixtures for a few known games (diff harness)
  report   print a table inventory (row counts) of the relevant tables

The MariaDB dump is parsed with the Python standard library only (the SQLite
build uses the bundled ``sqlite3`` module); no extra dependencies are
required. Paths come exclusively from environment variables (see run.sh and
local/paths.env). This file contains no real data paths.
"""
import argparse
import difflib
import gzip
import hashlib
import json
import os
import re
import sqlite3
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
SITE = "https://www.atarilegend.com"
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

# Facet tables: what the app needs for the developer/author/genre filters.
FACET_TABLES = (
    "games",
    "game_akas",
    "game_releases",
    "game_release_akas",
    "genres",
    "game_genre",
    "game_developer",
    "companies",
    "developer_roles",
    "game_individual",
    "individuals",
    "individual_roles",
)

# Detail tables: everything the "AtariLegend details" panel assembles.
DETAIL_TABLES = FACET_TABLES + (
    "screenshots",
    "game_screenshot",
    "game_release_scans",
    "game_series",
    "ports",
    "game_progress_systems",
    "game_engine",
    "engines",
    "game_programming_language",
    "programming_languages",
    "game_control",
    "controls",
    "game_sound_hardware",
    "sound_hardware",
    "memories",
    "game_release_memory_minimum",
    "resolutions",
    "game_release_resolution",
    "languages",
    "game_release_language",
    "locations",
    "game_release_location",
    "game_release_distributor",
    "game_release_copy_protection",
    "copy_protections",
    "game_release_disk_protection",
    "disk_protections",
    "game_release_tos_incompatibilities",
    "tos",
    "crews",
    "game_release_crew",
    "sndh_archives",
    "sndhs",
    "game_sndh",
    "game_votes",
    "reviews",
    "magazine_indices",
    "magazine_issues",
    "magazines",
    "game_videos",
    "game_galleries",
    "game_facts",
)

# Default games for `fixtures` (slug + a folder that resolves to it).
FIXTURE_GAMES = ("buggy-boy", "arkanoid", "dungeon-master", "lemmings")

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


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _dump_date(path: Path) -> str:
    m = DUMP_RE.search(path.name)
    return m.group(1) if m else ""


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
# full dump -> SQLite mirror
# --------------------------------------------------------------------------

def _sql_kind(mariadb_type: str) -> str:
    t = mariadb_type.lower()
    if t in ("int", "bigint", "smallint", "tinyint", "mediumint"):
        return "INTEGER"
    if t in ("decimal", "float", "double", "numeric", "real"):
        return "REAL"
    return "TEXT"


def _key_cols(expr: str) -> list:
    return re.findall(r"`([^`]+)`", expr)


def parse_table_defs(text: str) -> dict:
    """Return {table: {columns: [(name, kind)], pk: [cols], indexes: [(unique, [cols])]}}.

    Only line-start ``CREATE TABLE`` statements are matched, so the DDL that
    is embedded as text inside ``database_changes`` is ignored.
    """
    defs = {}
    for m in re.finditer(r"^CREATE TABLE `([^`]+)` \((.*?)\n\) ENGINE=",
                         text, re.S | re.M):
        name, body = m.group(1), m.group(2)
        columns = []
        indexes = []
        pk = None
        for line in body.split("\n"):
            line = line.strip()
            cm = re.match(r"`([^`]+)`\s+([a-zA-Z]+)", line)
            if cm:
                columns.append((cm.group(1), _sql_kind(cm.group(2))))
                continue
            if re.match(r"PRIMARY KEY", line, re.I):
                mk = re.search(r"PRIMARY KEY \(([^)]*)\)", line, re.I)
                if mk:
                    pk = _key_cols(mk.group(1))
                continue
            mu = re.match(r"UNIQUE(?: KEY)? (?:`[^`]*`\s*)?\(([^)]*)\)", line, re.I)
            if mu:
                indexes.append((True, _key_cols(mu.group(1))))
                continue
            mkey = re.match(r"KEY (?:`[^`]*`\s*)?\(([^)]*)\)", line, re.I)
            if mkey:
                indexes.append((False, _key_cols(mkey.group(1))))
        defs[name] = {"columns": columns, "pk": pk, "indexes": indexes}
    return defs


def _coerce(value, kind):
    if value is None:
        return None
    if kind == "INTEGER":
        try:
            return int(value)
        except (TypeError, ValueError):
            return value
    if kind == "REAL":
        try:
            return float(value)
        except (TypeError, ValueError):
            return value
    return value


def _quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def build_sqlite(db_path: Path, text: str, defs: dict, cfg: dict,
                 folder_rows: list, meta: dict, tables_filter=None) -> dict:
    """Write all tables into a SQLite database. Returns {table: row_count}."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(db_path.parent), prefix=".tmp-",
                               suffix=".sqlite")
    os.close(fd)
    counts = {}
    con = sqlite3.connect(tmp)
    try:
        con.execute("PRAGMA journal_mode=OFF")
        con.execute("PRAGMA synchronous=OFF")
        con.execute("PRAGMA temp_store=MEMORY")
        for name, info in defs.items():
            if tables_filter and name not in tables_filter:
                continue
            cols = info["columns"]
            if not cols:
                continue
            colnames = [c for c, _ in cols]
            col_defs = [f"{_quote_ident(c)} {k}" for c, k in cols]
            if info["pk"]:
                col_defs.append("PRIMARY KEY (%s)"
                                % ", ".join(_quote_ident(c) for c in info["pk"]))
            con.execute(f"CREATE TABLE {_quote_ident(name)} ({', '.join(col_defs)})")

            placeholders = ", ".join("?" for _ in cols)
            insert = (f"INSERT INTO {_quote_ident(name)} "
                      f"({', '.join(_quote_ident(c) for c in colnames)}) "
                      f"VALUES ({placeholders})")
            kinds = [k for _, k in cols]
            batch = []
            n = 0
            for row in iter_insert_rows(text, name, cfg["unescape"]):
                if len(row) != len(cols):
                    row = (list(row) + [None] * len(cols))[:len(cols)]
                batch.append(tuple(_coerce(v, k) for v, k in zip(row, kinds)))
                n += 1
                if len(batch) >= 2000:
                    con.executemany(insert, batch)
                    batch.clear()
            if batch:
                con.executemany(insert, batch)
            counts[name] = n

            seen = set()
            for i, (_unique, cols_) in enumerate(info["indexes"]):
                if not cols_:
                    continue
                sig = tuple(cols_)
                if sig in seen:
                    continue
                seen.add(sig)
                idx = f"idx_{name}_{i}"
                con.execute(f"CREATE INDEX {_quote_ident(idx)} "
                            f"ON {_quote_ident(name)} "
                            f"({', '.join(_quote_ident(c) for c in cols_)})")

        if folder_rows:
            con.execute("CREATE TABLE folders ("
                        "section TEXT, letter TEXT, folder TEXT, "
                        "al_game_id INTEGER, al_game_name TEXT, "
                        "matched_via TEXT, confidence REAL, "
                        "PRIMARY KEY (section, letter, folder))")
            con.executemany(
                "INSERT INTO folders VALUES (?,?,?,?,?,?,?)", folder_rows)

        con.execute("CREATE TABLE _meta (key TEXT PRIMARY KEY, value TEXT)")
        for k, v in meta.items():
            con.execute("INSERT INTO _meta VALUES (?,?)",
                        (k, v if isinstance(v, str) else json.dumps(v)))

        con.execute("CREATE TABLE _table_stats ("
                    "table_name TEXT PRIMARY KEY, columns INTEGER, rows INTEGER)")
        for name, info in defs.items():
            if name in counts:
                con.execute("INSERT INTO _table_stats VALUES (?,?,?)",
                            (name, len(info["columns"]), counts[name]))

        con.commit()
    finally:
        con.close()
    os.replace(tmp, db_path)
    return counts


# --------------------------------------------------------------------------
# AtariLegend URL conventions (derived from ids/slugs, see ANALYSIS-atarilegend.md)
# --------------------------------------------------------------------------

def game_url(slug) -> str:
    return f"{SITE}/games/{slug}"


def review_url(review_id) -> str:
    return f"{SITE}/reviews/{review_id}"


def screenshot_url(slug, screenshot_id, ext) -> str:
    return f"{SITE}/games/{slug}/screenshot-{screenshot_id}.{ext}"


def boxscan_url(scan_id, ext) -> str:
    return f"{SITE}/storage/images/game_release_scans/{scan_id}.{ext}"


def company_logo_url(company_id, ext) -> str:
    return f"{SITE}/storage/images/company_logos/{company_id}.{ext}"


def magazine_url(magazine_id, issue_id=None) -> str:
    base = f"{SITE}/magazines/{magazine_id}"
    return f"{base}#magazine-issue-{issue_id}" if issue_id else base


def load_tables_dicts(text: str, defs: dict, cfg: dict, tables) -> dict:
    """Parse `tables` into {table: [ {column: value}, ... ]}.

    Values are coerced by the declared dump column type (int/real/text), so
    numeric ids/counts/scores come out as numbers and NULLs as None.
    """
    out = {}
    for t in tables:
        defcols = defs.get(t, {}).get("columns", [])
        cols = [c for c, _ in defcols]
        kinds = [k for _, k in defcols]
        rows = []
        for r in iter_insert_rows(text, t, cfg["unescape"]):
            if len(r) != len(cols):
                r = (list(r) + [None] * len(cols))[:len(cols)]
            rows.append({c: _coerce(v, k) for c, v, k in zip(cols, r, kinds)})
        out[t] = rows
    return out


def _by_id(table_rows, key="id") -> dict:
    return {r[key]: r for r in table_rows if key in r}


def _years_of(releases) -> list:
    years = []
    for r in releases:
        d = r.get("date") or ""
        if len(d) >= 4 and d[:4].isdigit():
            years.append(int(d[:4]))
    return years


def game_facets(T: dict, game_id) -> dict | None:
    """Name/slug/year + genre/developer/author facets for the filter dropdowns."""
    gid = _as_id(game_id)
    games = _by_id(T.get("games", []))
    g = games.get(gid)
    if not g:
        return None
    genres = {r["id"]: r["name"] for r in T.get("genres", [])}
    comps = _by_id(T.get("companies", []))
    inds = _by_id(T.get("individuals", []))

    def uniq(seq):
        seen = []
        for x in seq:
            if x and x not in seen:
                seen.append(x)
        return seen

    gen = [genres.get(r.get("genre_id")) for r in T.get("game_genre", [])
           if r.get("game_id") == gid]
    devs = [comps.get(r.get("company_id"), {}).get("name")
            for r in T.get("game_developer", []) if r.get("game_id") == gid]
    auths = [inds.get(r.get("individual_id"), {}).get("name")
             for r in T.get("game_individual", []) if r.get("game_id") == gid]
    releases = [r for r in T.get("game_releases", []) if r.get("game_id") == gid]
    years = _years_of(releases)
    return {
        "name": g.get("name"),
        "slug": g.get("slug"),
        "year": min(years) if years else None,
        "genres": uniq(gen),
        "developers": uniq(devs),
        "authors": uniq(auths),
    }


def assemble_detail(T: dict, game_id) -> dict | None:
    """Assemble the full 'AtariLegend details' payload for one game."""
    gid = _as_id(game_id)
    games = _by_id(T.get("games", []))
    g = games.get(gid)
    if not g:
        return None
    slug = g.get("slug") or ""

    names = {
        "genres": {r["id"]: r["name"] for r in T.get("genres", [])},
        "series": {r["id"]: r["name"] for r in T.get("game_series", [])},
        "ports": {r["id"]: r["name"] for r in T.get("ports", [])},
        "progress": {r["id"]: r["name"] for r in T.get("game_progress_systems", [])},
        "engines": {r["id"]: r["name"] for r in T.get("engines", [])},
        "prog": {r["id"]: r["name"] for r in T.get("programming_languages", [])},
        "controls": {r["id"]: r["name"] for r in T.get("controls", [])},
        "sound": {r["id"]: r["name"] for r in T.get("sound_hardware", [])},
        "droles": {r["id"]: r["name"] for r in T.get("developer_roles", [])},
        "iroles": {r["id"]: r["name"] for r in T.get("individual_roles", [])},
        "memories": {r["id"]: r["name"] for r in T.get("memories", [])},
        "resolutions": {r["id"]: r["name"] for r in T.get("resolutions", [])},
        "languages": {r["id"]: r["name"] for r in T.get("languages", [])},
        "locations": {r["id"]: r["name"] for r in T.get("locations", [])},
        "tos": {r["id"]: r["name"] for r in T.get("tos", [])},
        "copy": {r["id"]: r["name"] for r in T.get("copy_protections", [])},
        "disk": {r["id"]: r["name"] for r in T.get("disk_protections", [])},
    }
    comps = _by_id(T.get("companies", []))
    inds = _by_id(T.get("individuals", []))
    crews = _by_id(T.get("crews", []))
    mags = _by_id(T.get("magazines", []))
    issues = _by_id(T.get("magazine_issues", []))
    screenshots = _by_id(T.get("screenshots", []))
    sndh_archives = _by_id(T.get("sndh_archives", []))

    def uniq(seq):
        out = []
        for x in seq:
            if x and x not in out:
                out.append(x)
        return out

    def names_for(table, idkey, ref) -> list:
        return uniq(names[ref].get(r.get(idkey))
                    for r in T.get(table, []) if r.get("game_id") == gid)

    releases = [r for r in T.get("game_releases", []) if r.get("game_id") == gid]
    rel_by_id = {r["id"]: r for r in releases}

    def rel_rows(table, key="game_release_id"):
        return [r for r in T.get(table, []) if r.get(key) in rel_by_id]

    out_releases = []
    for r in releases:
        rid = r["id"]
        out_releases.append({
            "id": rid,
            "date": r.get("date"),
            "type": r.get("type"),
            "license": r.get("license"),
            "status": r.get("status"),
            "hd_installable": r.get("hd_installable"),
            "publisher": comps.get(r.get("company_id"), {}).get("name"),
            "distributor": uniq(comps.get(x.get("company_id"), {}).get("name")
                                for x in rel_rows("game_release_distributor") if x.get("game_release_id") == rid),
            "locations": uniq(names["locations"].get(x.get("location_id"))
                              for x in rel_rows("game_release_location") if x.get("game_release_id") == rid),
            "languages": uniq(names["languages"].get(x.get("language_id"))
                              for x in rel_rows("game_release_language") if x.get("game_release_id") == rid),
            "memory_minimum": uniq(names["memories"].get(x.get("memory_id"))
                                   for x in rel_rows("game_release_memory_minimum") if x.get("game_release_id") == rid),
            "resolutions": uniq(names["resolutions"].get(x.get("resolution_id"))
                                for x in rel_rows("game_release_resolution") if x.get("game_release_id") == rid),
            "copy_protection": uniq(names["copy"].get(x.get("copy_protection_id"))
                                    for x in rel_rows("game_release_copy_protection") if x.get("game_release_id") == rid),
            "disk_protection": uniq(names["disk"].get(x.get("disk_protection_id"))
                                    for x in rel_rows("game_release_disk_protection") if x.get("game_release_id") == rid),
            "tos_incompatible": uniq(names["tos"].get(x.get("tos_id"))
                                     for x in rel_rows("game_release_tos_incompatibilities") if x.get("game_release_id") == rid),
            "crews": uniq(crews.get(x.get("crew_id"), {}).get("name")
                          for x in rel_rows("game_release_crew") if x.get("game_release_id") == rid),
            "boxscans": [
                {"id": x["id"], "type": x.get("type"), "imgext": x.get("imgext"),
                 "url": boxscan_url(x["id"], x.get("imgext")), "notes": x.get("notes")}
                for x in rel_rows("game_release_scans") if x.get("game_release_id") == rid
            ],
        })

    screens = [
        {"id": x.get("screenshot_id"),
         "imgext": screenshots.get(x.get("screenshot_id"), {}).get("imgext"),
         "url": screenshot_url(slug, x.get("screenshot_id"),
                               screenshots.get(x.get("screenshot_id"), {}).get("imgext"))}
        for x in T.get("game_screenshot", []) if x.get("game_id") == gid
    ]

    # sndh_id is an archive-path key; ids may also appear with a leading slash
    sndhs = T.get("sndhs", [])
    music = []
    for link in T.get("game_sndh", []):
        if link.get("game_id") != gid:
            continue
        sid = link.get("sndh_id")
        for s in sndhs:
            if s.get("id") in (sid, "/" + str(sid)):
                arch = sndh_archives.get(s.get("sndh_archive_id"), {})
                music.append({
                    "id": s.get("id"), "title": s.get("title"),
                    "composer": s.get("composer"), "ripper": s.get("ripper"),
                    "subtunes": s.get("subtunes"), "year": s.get("year"),
                    "archive": s.get("sndh_archive_id"),
                    "download_url": arch.get("download_url"),
                })

    reviews = [
        {"id": r["id"], "url": review_url(r["id"]),
         "published_at": r.get("published_at"),
         "graphics": r.get("graphics"), "sound": r.get("sound"),
         "gameplay": r.get("gameplay"), "overall": r.get("overall")}
        for r in T.get("reviews", []) if r.get("game_id") == gid
    ]

    magazine_refs = []
    for m in T.get("magazine_indices", []):
        if m.get("game_id") != gid:
            continue
        iss = issues.get(m.get("magazine_issue_id"), {})
        magazine_refs.append({
            "magazine": mags.get(iss.get("magazine_id"), {}).get("name"),
            "issue": iss.get("issue"), "published": iss.get("published"),
            "page": m.get("page"), "score": m.get("score"),
            "url": magazine_url(iss.get("magazine_id"), m.get("magazine_issue_id")),
            "archive_url": iss.get("archiveorg_url") or iss.get("alternate_url"),
        })

    return {
        "game": {"id": g["id"], "name": g.get("name"), "slug": slug,
                 "url": game_url(slug)},
        "akas": [r.get("name") for r in T.get("game_akas", []) if r.get("game_id") == gid],
        "genres": [names["genres"].get(r.get("genre_id"))
                   for r in T.get("game_genre", []) if r.get("game_id") == gid],
        "series": names["series"].get(g.get("game_series_id")),
        "port": names["ports"].get(g.get("port_id")),
        "progress": names["progress"].get(g.get("game_progress_system_id")),
        "players": {
            "same_machine": g.get("players_same_machine"),
            "multiple_machines": g.get("players_multiple_machines"),
            "multiplayer_type": g.get("multiplayer_type"),
            "multiplayer_hardware": g.get("multiplayer_hardware"),
        },
        "developers": [
            {"name": comps.get(r.get("company_id"), {}).get("name"),
             "role": names["droles"].get(r.get("developer_role_id")),
             "logo_url": company_logo_url(r.get("company_id"), comps.get(r.get("company_id"), {}).get("imgext"))
             if comps.get(r.get("company_id"), {}).get("imgext") else None}
            for r in T.get("game_developer", []) if r.get("game_id") == gid
        ],
        "authors": [
            {"name": inds.get(r.get("individual_id"), {}).get("name"),
             "role": names["iroles"].get(r.get("individual_role_id"))}
            for r in T.get("game_individual", []) if r.get("game_id") == gid
        ],
        "engine": names_for("game_engine", "engine_id", "engines"),
        "programming_language": names_for("game_programming_language",
                                           "programming_language_id", "prog"),
        "controls": names_for("game_control", "control_id", "controls"),
        "sound_hardware": names_for("game_sound_hardware", "sound_hardware_id", "sound"),
        "releases": out_releases,
        "screenshots": screens,
        "music": music,
        "reviews": reviews,
        "magazines": magazine_refs,
        "videos": [{"title": r.get("title"), "youtube_id": r.get("youtube_id"),
                    "author": r.get("author")}
                   for r in T.get("game_videos", []) if r.get("game_id") == gid],
        "facts": [r.get("fact") for r in T.get("game_facts", []) if r.get("game_id") == gid],
    }


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


def compute_match(cfg: dict, text: str, idir: Path, sections) -> tuple:
    """Return (folder_map, result_sections, total_games, matched_ids)."""
    log("parsing tables")
    t0 = time.time()
    rows = parse_relevant_tables(text, cfg)
    key_index, block_index, short_keys, display, total_games = build_name_index(
        rows, cfg["block_size"])
    log(f"AtariLegend games: {total_games}, distinct name keys: {len(key_index)} "
        f"({time.time() - t0:.1f}s)")

    result_sections = {}
    folder_map = {}
    matched_ids = set()
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
    return folder_map, result_sections, total_games, matched_ids


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

    sections = KINDS if args.section == "all" else (args.section,)
    folder_map, result_sections, total_games, matched_ids = compute_match(
        cfg, text, idir, sections)
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

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


def cmd_extract(args) -> int:
    cfg = load_config()
    d = out_dir(args.dir)
    d.mkdir(parents=True, exist_ok=True)
    dump = _resolve_dump_path(args, d)
    log(f"reading dump: {dump}")
    text = read_dump(dump)

    defs = parse_table_defs(text)
    log(f"discovered {len(defs)} tables")

    folder_rows = []
    match_meta = {}
    idir = index_dir_optional(args.index_dir)
    if args.no_match:
        log("match mapping disabled (--no-match)")
    elif idir is None:
        log("MARCER_OUT_DIR not set -> skipping match mapping")
    else:
        folder_map, _sections, _total, matched_ids = compute_match(
            cfg, text, idir, KINDS)
        for key, v in folder_map.items():
            section, letter, folder = key.split("|", 2)
            folder_rows.append((section, letter, folder, v["al_game_id"],
                                v["al_name"], v["matched_via"], v["confidence"]))
        match_meta = {"matched_folders": len(folder_rows),
                      "matched_atarilegend_games": len(matched_ids)}

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    meta = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": generated_at,
        "generator": f"tools/atarilegend-gen {TOOL_VERSION}",
        "source_file": dump.name,
        "source_sha256": _sha256(dump),
        "dump_date": _dump_date(dump),
        "tables": len(defs),
    }
    meta.update(match_meta)

    db = d / "atarilegend.sqlite"
    counts = build_sqlite(db, text, defs, cfg, folder_rows, meta)
    total = sum(counts.values())
    size_mb = db.stat().st_size / 1e6
    log(f"wrote {db} ({len(counts)} tables, {total} rows, {size_mb:.1f} MB)")
    if folder_rows:
        log(f"folders table: {len(folder_rows)} matches")
    return 0


def _resolve_detail_gid(args, cfg, text, defs, T, d) -> str:
    if args.game_id is not None:
        return str(args.game_id)
    if args.slug:
        for r in T.get("games", []):
            if r.get("slug") == args.slug:
                return r["id"]
        sys.exit(f"error: slug not found: {args.slug}")
    if args.folder:
        idir = index_dir_optional(args.index_dir)
        if idir is None:
            sys.exit("error: --folder needs MARCER_OUT_DIR or --index-dir")
        parts = args.folder.split("/", 2)
        if len(parts) != 3:
            sys.exit("error: --folder must be kind/letter/folder")
        kind, letter, folder = parts
        if kind not in KINDS:
            sys.exit(f"error: kind must be one of {KINDS}")
        folder_map, _s, _t, _m = compute_match(cfg, text, idir, (kind,))
        key = f"{kind}|{letter}|{folder}"
        if key not in folder_map:
            sys.exit(f"error: folder not matched: {key}")
        return str(folder_map[key]["al_game_id"])
    sys.exit("error: give --slug, --game-id or --folder")


def cmd_detail(args) -> int:
    cfg = load_config()
    d = out_dir_optional(args.dir)
    dump = _resolve_dump_path(args, d)
    log(f"reading dump: {dump}")
    text = read_dump(dump)
    defs = parse_table_defs(text)
    T = load_tables_dicts(text, defs, cfg, DETAIL_TABLES)
    gid = _resolve_detail_gid(args, cfg, text, defs, T, d)
    detail = assemble_detail(T, gid)
    if detail is None:
        sys.exit(f"error: game id not found: {gid}")
    if args.json:
        atomic_write_json(Path(args.json), detail)
        log(f"wrote {args.json}")
    else:
        print(format_detail_text(detail))
    return 0


def cmd_index(args) -> int:
    cfg = load_config()
    d = out_dir(args.dir)
    d.mkdir(parents=True, exist_ok=True)
    dump = _resolve_dump_path(args, d)
    log(f"reading dump: {dump}")
    text = read_dump(dump)
    idir = index_dir_optional(args.index_dir)
    if idir is None:
        sys.exit("error: set MARCER_OUT_DIR (local/paths.env) or pass --index-dir")

    defs = parse_table_defs(text)
    folder_map, _sections, total_games, matched_ids = compute_match(
        cfg, text, idir, KINDS)
    T = load_tables_dicts(text, defs, cfg, FACET_TABLES)
    games = {}
    for gid in sorted({v["al_game_id"] for v in folder_map.values()}):
        facets = game_facets(T, gid)
        if facets:
            games[str(gid)] = facets

    payload = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "generator": f"tools/atarilegend-gen {TOOL_VERSION}",
        "source": {"file": dump.name, "dump_date": _dump_date(dump)},
        "totals": {"games": total_games, "matched_games": len(matched_ids),
                   "folders": len(folder_map)},
        "folders": {k: {"al_game_id": v["al_game_id"],
                        "matched_via": v["matched_via"],
                        "confidence": v["confidence"]}
                    for k, v in folder_map.items()},
        "games": games,
    }
    out = Path(args.out) if args.out else d / "atarilegend-index.json"
    atomic_write_json(out, payload)
    log(f"wrote {out} ({len(folder_map)} folders, {len(games)} games)")
    return 0


def cmd_fixtures(args) -> int:
    cfg = load_config()
    d = out_dir(args.dir)
    d.mkdir(parents=True, exist_ok=True)
    dump = _resolve_dump_path(args, d)
    text = read_dump(dump)
    defs = parse_table_defs(text)
    T = load_tables_dicts(text, defs, cfg, DETAIL_TABLES)
    outdir = Path(args.out) if args.out else d / "fixtures"
    outdir.mkdir(parents=True, exist_ok=True)
    slugs = args.slugs.split(",") if args.slugs else list(FIXTURE_GAMES)
    by_slug = {r.get("slug"): r["id"] for r in T.get("games", [])}
    n = 0
    for slug in slugs:
        gid = by_slug.get(slug)
        if gid is None:
            log(f"skip {slug}: not found")
            continue
        detail = assemble_detail(T, gid)
        p = outdir / f"detail-{slug}.json"
        atomic_write_json(p, detail)
        n += 1
    log(f"wrote {n} fixtures to {outdir}")
    return 0


def format_detail_text(detail: dict) -> str:
    g = detail["game"]
    L = [f"{g['name']}  (id {g['id']}, slug {g['slug']})",
         f"  {g['url']}"]
    if detail["akas"]:
        L.append(f"  AKA: {', '.join(detail['akas'])}")
    if detail["genres"]:
        L.append(f"  Genres: {', '.join(detail['genres'])}")
    for d_ in detail["developers"]:
        L.append(f"  Developer: {d_['name']}"
                 + (f" ({d_['role']})" if d_["role"] else ""))
    for a in detail["authors"]:
        L.append(f"  Author: {a['name']}"
                 + (f" ({a['role']})" if a["role"] else ""))
    if detail["series"]:
        L.append(f"  Series: {detail['series']}")
    if detail["port"]:
        L.append(f"  Original system: {detail['port']}")
    for key in ("screenshots", "music", "reviews", "magazines", "videos", "facts"):
        items = detail.get(key) or []
        if items:
            L.append(f"  {key}: {len(items)}")
    for r in detail["releases"]:
        L.append(f"  Release {r['date']} "
                 f"[{r['license']}/{r['type']}] publisher={r['publisher']} "
                 f"boxscans={len(r['boxscans'])}")
    for s in detail["screenshots"]:
        L.append(f"    screenshot {s['id']}: {s['url']}")
    for m in detail["music"]:
        L.append(f"    music {m['title']!r} by {m['composer']} -> {m['download_url']}")
    for rv in detail["reviews"]:
        L.append(f"    review {rv['id']}: {rv['url']} "
                 f"({rv['graphics']}/{rv['sound']}/{rv['gameplay']}/{rv['overall']})")
    return "\n".join(L)


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

    p_e = sub.add_parser(
        "extract", help="mirror all tables into atarilegend.sqlite (+ match)")
    p_e.add_argument("--dir", help="output dir (default MARCER_ATARILEGEND_DIR)")
    p_e.add_argument("--dump", help="dump file to use (default: newest cached)")
    p_e.add_argument("--index-dir",
                     help="screenshot index dir (default MARCER_OUT_DIR)")
    p_e.add_argument("--no-match", action="store_true",
                     help="skip building the folder->game match mapping")
    p_e.set_defaults(func=cmd_extract)

    p_d = sub.add_parser("detail",
                         help="assemble the AtariLegend detail payload for one game")
    p_d.add_argument("--dir", help="output dir (default MARCER_ATARILEGEND_DIR)")
    p_d.add_argument("--dump", help="dump file to use (default: newest cached)")
    p_d.add_argument("--index-dir",
                     help="screenshot index dir (default MARCER_OUT_DIR)")
    p_d.add_argument("--slug", help="game slug (e.g. buggy-boy)")
    p_d.add_argument("--game-id", help="AtariLegend game id")
    p_d.add_argument("--folder", help="kind/letter/folder (resolved via the match)")
    p_d.add_argument("--json", help="write the detail payload JSON to this path")
    p_d.set_defaults(func=cmd_detail)

    p_i = sub.add_parser("index",
                         help="write the runtime index (folders + filter facets)")
    p_i.add_argument("--dir", help="output dir (default MARCER_ATARILEGEND_DIR)")
    p_i.add_argument("--dump", help="dump file to use (default: newest cached)")
    p_i.add_argument("--index-dir",
                     help="screenshot index dir (default MARCER_OUT_DIR)")
    p_i.add_argument("--out", help="output JSON path (default atarilegend-index.json)")
    p_i.set_defaults(func=cmd_index)

    p_x = sub.add_parser("fixtures",
                         help="write detail fixtures for a few known games (diff harness)")
    p_x.add_argument("--dir", help="output dir (default MARCER_ATARILEGEND_DIR)")
    p_x.add_argument("--dump", help="dump file to use (default: newest cached)")
    p_x.add_argument("--out", help="fixture output dir (default <dir>/fixtures)")
    p_x.add_argument("--slugs", help="comma-separated slugs (default known set)")
    p_x.set_defaults(func=cmd_fixtures)

    p_r = sub.add_parser("report", help="print a table inventory of the dump")
    p_r.add_argument("--dir", help="output dir (default MARCER_ATARILEGEND_DIR)")
    p_r.add_argument("--dump", help="dump file to use (default: newest cached)")
    p_r.set_defaults(func=cmd_report)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
