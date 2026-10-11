#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Marcer GameDVD Game-Info Extractor.

Implements ANALYSIS-game-data.md (M1):
  extract   parse the XLS workbooks, match on-disk folders, write JSON to
            <PATCH>/Data/ (games-cracked.json, games-pd.json, games-utils.json,
            manifest.json, unmatched-report.txt)
  check     validate the generated output against the sources (exit 1 on
            missing or stale output)
  report    print an audit summary (TOS/bad notes, dump flags, coverage)

Paths come exclusively from environment variables (see run.sh and
local/paths.env). This file contains no real data paths.
"""
import argparse
import difflib
import json
import os
import struct
import sys
import tempfile
import time
import unicodedata
from collections import Counter, OrderedDict
from datetime import datetime, timedelta, timezone
from pathlib import Path

TOOL_VERSION = "0.1.0"
SCHEMA_VERSION = 1

KINDS = ("cracked", "pd", "utils")

# BIFF5 record ids
RID_LABEL = 0x0204
RID_RK = 0x027E
RID_MULRK = 0x00BD
RID_NUMBER = 0x0203
RID_BOUNDSHEET = 0x0085

FIRST_DATA_ROW = 2  # row 0 = header, row 1 = generation note

FLAG_YES = {"yes", "y", "x", "1"}


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------

DEFAULT_CONFIG = {
    "xls": {
        "cracked": "Games.xls",
        "pd": "PD Games.xls",
        "utils": "Utils_.xls",
    },
    "trees": {
        "cracked": "Cracked Games - Title Sorted",
        "pd": "PD Games - Title Sorted",
        "utils": "Utilitys - Title Sorted",
    },
    "title_sorted_dir": "Title Sorted",
    "out_subdir": "Data",
    "fuzzy_cutoff": 0.92,
    "prefer_patch_xls": True,
}

# Column layout per kind: index -> (json field, type)
# type: "str" | "int" | "flag" | "release"
COLUMN_MAPS = {
    "cracked": {
        0: ("title", "str"),
        1: ("publisher", "str"),
        2: ("cracked_by", "str"),
        3: ("crew", "str"),
        4: ("intro_code", "str"),
        5: ("special_flag", "str"),
        6: ("language", "str"),
        7: ("disks", "int"),
        8: ("raw_dump", "flag"),
        9: ("pasti_dump", "flag"),
        10: ("boxscan", "flag"),
        11: ("release", "release"),
        12: ("tos_bad", "str"),
        13: ("special_note", "str"),
    },
    "pd": {
        0: ("title", "str"),
        1: ("version", "str"),
        2: ("publisher", "str"),
        3: ("company", "str"),
        4: ("licence", "str"),
        5: ("screen_format", "str"),
        6: ("language", "str"),
        7: ("disks", "int"),
        8: ("release", "release"),
        9: ("add_info", "str"),
        10: ("tos_bad", "str"),
    },
    "utils": {
        0: ("title", "str"),
        1: ("version", "str"),
        2: ("publisher", "str"),
        3: ("company", "str"),
        4: ("licence", "str"),
        5: ("cracked_by", "str"),
        6: ("crew", "str"),
        7: ("cracktro", "str"),
        8: ("screen_format", "str"),
        9: ("language", "str"),
        10: ("disks", "int"),
        11: ("release", "release"),
        12: ("raw_dump", "flag"),
        13: ("tos_bad", "str"),
    },
}


def log(msg: str) -> None:
    print(f"[gameinfo] {msg}", flush=True)


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
    root = repo_root() / "tools" / "gameinfo-gen"
    for name in ("config.example.json", "config.local.json"):
        p = root / name
        if p.exists():
            with open(p, encoding="utf-8") as f:
                _deep_merge(cfg, json.load(f))
    return cfg


def paths() -> dict:
    patch = os.environ.get("MARCER_PATCH_DIR", "").strip()
    if not patch:
        sys.exit("error: environment variable MARCER_PATCH_DIR is not set "
                 "(add it to local/paths.env)")
    root = os.environ.get("MARCER_ROOT_DIR", "").strip()
    return {"patch": Path(patch), "root": Path(root) if root else None}


# --------------------------------------------------------------------------
# BIFF5 (Excel 5.0/95) reader
# --------------------------------------------------------------------------

def _rk_to_num(rk: int) -> float:
    cents = rk & 1
    if rk & 2:
        v = rk >> 2
        if v >= 2 ** 29:
            v -= 2 ** 30
        v = float(v)
    else:
        v = struct.unpack("<d", struct.pack("<Q", (rk & 0xFFFFFFFC) << 32))[0]
    return v / 100 if cents else v


def _decode_text(raw: bytes) -> str:
    try:
        return raw.decode("cp1252")
    except UnicodeDecodeError:
        return raw.decode("latin-1", "replace")


def read_xls(path: Path) -> tuple:
    """Parse a BIFF5 workbook. Returns (cells, sheet_name).

    cells: {(row, col): str | float}
    """
    import olefile

    if not path.is_file():
        raise FileNotFoundError(path)
    ole = olefile.OleFileIO(str(path))
    try:
        stream = "Workbook" if ole.exists("Workbook") else "Book"
        data = ole.openstream(stream).read()
    finally:
        ole.close()

    cells = {}
    sheet_name = ""
    pos = 0
    while pos + 4 <= len(data):
        rid, rlen = struct.unpack("<HH", data[pos:pos + 4])
        d = data[pos + 4:pos + 4 + rlen]
        if rid == RID_BOUNDSHEET and len(d) >= 8 and not sheet_name:
            cch = d[6]
            sheet_name = _decode_text(d[7:7 + cch])
        elif rid == RID_LABEL and len(d) >= 8:
            r, c = struct.unpack("<HH", d[:4])
            cch = struct.unpack("<H", d[6:8])[0]
            cells[(r, c)] = _decode_text(d[8:8 + cch])
        elif rid == RID_RK and len(d) >= 10:
            r, c = struct.unpack("<HH", d[:4])
            cells[(r, c)] = _rk_to_num(struct.unpack("<I", d[6:10])[0])
        elif rid == RID_MULRK and len(d) >= 6:
            r, cf = struct.unpack("<HH", d[:4])
            for i in range((len(d) - 6) // 6):
                off = 4 + i * 6 + 2
                cells[(r, cf + i)] = _rk_to_num(struct.unpack("<I", d[off:off + 4])[0])
        elif rid == RID_NUMBER and len(d) >= 14:
            r, c = struct.unpack("<HH", d[:4])
            cells[(r, c)] = struct.unpack("<d", d[6:14])[0]
        pos += 4 + rlen
    return cells, sheet_name


# --------------------------------------------------------------------------
# workbook -> variants
# --------------------------------------------------------------------------

def _norm_str(v) -> str:
    if v is None:
        return ""
    if isinstance(v, float):
        return str(int(v)) if v == int(v) else str(v)
    return str(v).strip()


def _norm_int(v):
    if v is None or v == "":
        return None
    if isinstance(v, (int, float)):
        return int(v)
    s = str(v).strip()
    if not s:
        return None
    try:
        return int(float(s.replace(",", ".")))
    except ValueError:
        return None


def _norm_flag(v, anomalies: list, where: str) -> bool:
    s = _norm_str(v).lower()
    if not s:
        return False
    if s in FLAG_YES:
        return True
    anomalies.append(f"{where}: unexpected flag value {s!r}")
    return False


def _norm_release(v, anomalies: list, where: str) -> str:
    if v is None or v == "":
        return ""
    if isinstance(v, (int, float)):
        n = float(v)
        if 1900 <= n <= 2100:
            return str(int(n))
        if 10000 <= n <= 60000:  # Excel serial date (1899-12-30 epoch)
            dt = datetime(1899, 12, 30) + timedelta(days=int(n))
            return dt.strftime("%d-%m-%Y")
        anomalies.append(f"{where}: unexpected numeric release {n!r}")
        return str(int(n)) if n == int(n) else str(n)
    return _norm_str(v)


def parse_workbook(path: Path, kind: str) -> tuple:
    """Return (variants, meta).

    variants: list of dicts (file order), each with all mapped fields + source_row
    meta: dict with sheet/rows/titles
    """
    cells, sheet_name = read_xls(path)
    colmap = COLUMN_MAPS[kind]
    rows = sorted({r for r, _ in cells})
    anomalies = []
    variants = []
    titles_seen = set()
    for r in rows:
        if r < FIRST_DATA_ROW:
            continue
        title = _norm_str(cells.get((r, 0)))
        if not title:
            continue
        titles_seen.add(title)
        rec = {"source_row": r}
        for ci, (field, ftype) in colmap.items():
            raw = cells.get((r, ci))
            where = f"{path.name}:r{r}:{field}"
            if ftype == "str":
                rec[field] = _norm_str(raw)
            elif ftype == "int":
                rec[field] = _norm_int(raw)
            elif ftype == "flag":
                rec[field] = _norm_flag(raw, anomalies, where)
            elif ftype == "release":
                rec[field] = _norm_release(raw, anomalies, where)
            else:
                raise ValueError(ftype)
        variants.append(rec)
    meta = {
        "sheet": sheet_name,
        "rows": len(rows),
        "titles": len(titles_seen),
        "anomalies": anomalies,
    }
    return variants, meta


def group_by_title(variants: list) -> "OrderedDict":
    grouped = OrderedDict()
    for rec in variants:
        grouped.setdefault(rec["title"], []).append(rec)
    return grouped


# --------------------------------------------------------------------------
# tree scan
# --------------------------------------------------------------------------

SKIP_NAMES = {"@eaDir"}


def scan_tree(base: Path, title_sorted: str, tree: str) -> dict:
    """Return {folder: {"letter": str, "layer": set}} for one base dir."""
    out = {}
    tree_dir = base / title_sorted / tree
    if not tree_dir.is_dir():
        return out
    layer = base.name or str(base)
    for letter in sorted(os.listdir(tree_dir)):
        if letter.startswith(".") or letter in SKIP_NAMES:
            continue
        lp = tree_dir / letter
        if not lp.is_dir():
            continue
        for name in os.listdir(lp):
            if name.startswith(".") or name in SKIP_NAMES:
                continue
            if not (lp / name).is_dir():
                continue
            entry = out.get(name)
            if entry is None:
                out[name] = {"letter": letter, "layers": {layer}}
            else:
                entry["layers"].add(layer)
    return out


def layer_label(base: Path, patch: Path) -> str:
    return "PATCH" if base == patch else "ROOT"


def scan_folders(patch: Path, root, title_sorted: str, tree: str) -> dict:
    """Union of folders across PATCH and ROOT.

    Returns {folder: {"letter": str, "layers": ["PATCH", ...]}}
    """
    merged = {}
    bases = [patch] + ([root] if root else [])
    for base in bases:
        for folder, info in scan_tree(base, title_sorted, tree).items():
            entry = merged.get(folder)
            if entry is None:
                merged[folder] = {
                    "letter": info["letter"],
                    "layers": {layer_label(base, patch)},
                }
            else:
                if info["letter"] != entry["letter"]:
                    log(f"warning: letter conflict for {folder!r}: "
                        f"{entry['letter']} vs {info['letter']} (keeping first)")
                entry["layers"].add(layer_label(base, patch))
    for entry in merged.values():
        entry["layers"] = sorted(entry["layers"])
    return merged


# --------------------------------------------------------------------------
# matching
# --------------------------------------------------------------------------

def normalize(s: str) -> str:
    s = unicodedata.normalize("NFKD", s)
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    s = s.lower()
    s = "".join(ch if ch.isalnum() else " " for ch in s)
    return " ".join(s.split())


def match_folder(folder: str, title_index: dict, fuzzy_cutoff: float) -> tuple:
    """Return (title or None, matched_via).

    title_index: {normalized_title: [original_title, ...]}
    Strategy: exact -> prefix (longest title wins) -> fuzzy.
    """
    fn = normalize(folder)
    if not fn:
        return None, "none"
    # exact
    if fn in title_index:
        return title_index[fn][0], "exact"
    # prefix: folder starts with title (+ word boundary) or title with folder
    best = ""
    best_title = None
    for tn, titles in title_index.items():
        if not tn:
            continue
        hit = False
        if fn.startswith(tn + " "):
            hit = True
        elif tn.startswith(fn + " "):
            hit = True
        if hit and len(tn) > len(best):
            best = tn
            best_title = titles[0]
    if best_title is not None:
        return best_title, "prefix"
    # fuzzy
    close = difflib.get_close_matches(fn, list(title_index.keys()), n=1,
                                      cutoff=fuzzy_cutoff)
    if close:
        return title_index[close[0]][0], "fuzzy"
    return None, "none"


# --------------------------------------------------------------------------
# build output
# --------------------------------------------------------------------------

def build_kind(kind: str, cfg: dict, paths_: dict, anomalies_all: list) -> dict:
    patch, root = paths_["patch"], paths_["root"]
    ts_dir = cfg["title_sorted_dir"]

    # source XLS: prefer PATCH, fallback ROOT
    xls_name = cfg["xls"][kind]
    candidates = [patch / ts_dir / xls_name]
    if root:
        candidates.append(root / ts_dir / xls_name)
    src = next((p for p in candidates if p.is_file()), None)
    if src is None:
        raise FileNotFoundError(f"{xls_name} not found in {' or '.join(map(str, candidates))}")
    used_layer = "PATCH" if src.parent.parent == patch else "ROOT"
    if used_layer == "ROOT":
        log(f"warning: {xls_name} taken from ROOT (no PATCH copy found)")

    log(f"{kind}: parsing {xls_name} ({used_layer}) ...")
    variants, meta = parse_workbook(src, kind)
    anomalies_all.extend(meta["anomalies"])
    grouped = group_by_title(variants)

    # folder scan (union)
    folders = scan_folders(patch, root, ts_dir, cfg["trees"][kind])
    log(f"{kind}: {meta['titles']} titles, {len(folders)} folders on disk")

    # title index for matching
    title_index = {}
    for t in grouped:
        title_index.setdefault(normalize(t), []).append(t)

    games = []
    matched_via_counter = Counter()
    unmatched_folders = []
    for folder in sorted(folders, key=str.casefold):
        title, how = match_folder(folder, title_index, cfg["fuzzy_cutoff"])
        matched_via_counter[how] += 1
        if title is None:
            unmatched_folders.append(folder)
            continue
        games.append({
            "folder": folder,
            "letter": folders[folder]["letter"],
            "layers": folders[folder]["layers"],
            "matched_via": how,
            "matched_title": title,
            "variants": grouped[title],
        })

    matched_titles = {g["matched_title"] for g in games}
    orphan_titles = [t for t in grouped if t not in matched_titles]

    data = {
        "schema_version": SCHEMA_VERSION,
        "kind": kind,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": {
            "file": xls_name,
            "path_symbolic": f"<{'PATCH' if used_layer == 'PATCH' else 'ROOT'}>/{ts_dir}/{xls_name}",
            "layer": used_layer,
            "mtime": datetime.fromtimestamp(src.stat().st_mtime, timezone.utc)
                         .strftime("%Y-%m-%dT%H:%M:%SZ"),
            "size": src.stat().st_size,
            "sheet": meta["sheet"],
        },
        "games": games,
    }
    stats = {
        "kind": kind,
        "file": xls_name,
        "layer": used_layer,
        "mtime": data["source"]["mtime"],
        "size": data["source"]["size"],
        "rows": meta["rows"],
        "titles": meta["titles"],
        "folders_total": len(folders),
        "matched_folders": len(games),
        "unmatched_folders": len(unmatched_folders),
        "matched_via": dict(matched_via_counter),
        "orphan_titles": len(orphan_titles),
    }
    return {
        "data": data,
        "stats": stats,
        "unmatched_folders": unmatched_folders,
        "orphan_titles": orphan_titles,
        "anomalies": meta["anomalies"],
    }


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


def build_unmatched_report(results: dict) -> str:
    lines = ["# gameinfo-gen unmatched report", ""]
    for kind in KINDS:
        res = results[kind]
        lines.append(f"## {kind}")
        lines.append("")
        lines.append(f"### Folders without XLS entry ({len(res['unmatched_folders'])})")
        for folder in res["unmatched_folders"]:
            lines.append(f"  {folder}")
        lines.append("")
        lines.append(f"### XLS titles without folder ({len(res['orphan_titles'])})")
        for title in res["orphan_titles"]:
            lines.append(f"  {title}")
        lines.append("")
        if res["anomalies"]:
            lines.append(f"### Anomalies ({len(res['anomalies'])})")
            for a in res["anomalies"]:
                lines.append(f"  {a}")
            lines.append("")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_extract(args) -> int:
    cfg = load_config()
    paths_ = paths()
    out_dir = paths_["patch"] / cfg["title_sorted_dir"] / cfg["out_subdir"]
    kinds = (args.kind,) if args.kind else KINDS

    anomalies_all = []
    results = {}
    t0 = time.time()
    for kind in kinds:
        results[kind] = build_kind(kind, cfg, paths_, anomalies_all)

    # summary
    log("")
    log(f"{'kind':8} {'titles':>7} {'folders':>8} {'matched':>8} {'exact':>6} "
        f"{'prefix':>7} {'fuzzy':>6} {'orphans':>8}")
    for kind in kinds:
        s = results[kind]["stats"]
        mv = s["matched_via"]
        log(f"{kind:8} {s['titles']:>7} {s['folders_total']:>8} "
            f"{s['matched_folders']:>8} {mv.get('exact', 0):>6} "
            f"{mv.get('prefix', 0):>7} {mv.get('fuzzy', 0):>6} "
            f"{s['orphan_titles']:>8}")

    if args.dry_run:
        log("")
        log(f"dry-run: would write to {out_dir}")
        return 0

    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for kind in kinds:
        p = out_dir / f"games-{kind}.json"
        atomic_write_json(p, results[kind]["data"])
        written.append(p)
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "generator": "tools/gameinfo-gen",
        "generator_version": TOOL_VERSION,
        "sources": [results[k]["stats"] for k in kinds],
    }
    mp = out_dir / "manifest.json"
    atomic_write_json(mp, manifest)
    written.append(mp)
    rp = out_dir / "unmatched-report.txt"
    atomic_write_text(rp, build_unmatched_report(results))
    written.append(rp)

    log("")
    for p in written:
        log(f"wrote {p} ({p.stat().st_size} bytes)")
    log(f"done in {time.time() - t0:.1f}s")
    return 0


def cmd_check(args) -> int:
    cfg = load_config()
    paths_ = paths()
    out_dir = paths_["patch"] / cfg["title_sorted_dir"] / cfg["out_subdir"]
    mp = out_dir / "manifest.json"
    if not mp.is_file():
        log(f"error: {mp} not found (run extract first)")
        return 1
    with open(mp, encoding="utf-8") as f:
        manifest = json.load(f)
    problems = []
    for src in manifest.get("sources", []):
        kind = src["kind"]
        jp = out_dir / f"games-{kind}.json"
        if not jp.is_file():
            problems.append(f"{jp} missing")
            continue
        with open(jp, encoding="utf-8") as f:
            data = json.load(f)
        n_games = len(data.get("games", []))
        if n_games != src.get("matched_folders"):
            problems.append(
                f"{kind}: games count {n_games} != manifest {src.get('matched_folders')}")
        # staleness: compare source file mtime with manifest entry
        xls_name = cfg["xls"][kind]
        ts_dir = cfg["title_sorted_dir"]
        cand = [paths_["patch"] / ts_dir / xls_name]
        if paths_["root"]:
            cand.append(paths_["root"] / ts_dir / xls_name)
        cur = next((p for p in cand if p.is_file()), None)
        if cur is None:
            problems.append(f"{kind}: source {xls_name} not found anymore")
        else:
            cur_mtime = datetime.fromtimestamp(cur.stat().st_mtime, timezone.utc) \
                .strftime("%Y-%m-%dT%H:%M:%SZ")
            if cur_mtime != src.get("mtime"):
                problems.append(
                    f"{kind}: source {xls_name} changed ({cur_mtime} != "
                    f"manifest {src.get('mtime')}) - re-run extract")
    if problems:
        for p in problems:
            log(f"FAIL: {p}")
        return 1
    log(f"ok: {mp} consistent with sources")
    return 0


def cmd_report(args) -> int:
    cfg = load_config()
    paths_ = paths()
    anomalies_all = []
    for kind in KINDS:
        res = build_kind(kind, cfg, paths_, anomalies_all)
        s = res["stats"]
        data = res["data"]
        log("")
        log(f"=== {kind} ({s['file']}, {s['layer']}) ===")
        log(f"titles in XLS: {s['titles']}   rows: {s['rows']}")
        log(f"folders on disk (union): {s['folders_total']}   "
            f"matched: {s['matched_folders']}   unmatched: {s['unmatched_folders']}")
        log(f"matched_via: {s['matched_via']}   titles without folder: {s['orphan_titles']}")
        # audit stats over variants
        all_variants = [v for g in data["games"] for v in g["variants"]]
        flag_counts = {}
        for flag in ("raw_dump", "pasti_dump", "boxscan"):
            if any(flag in v for v in all_variants):
                flag_counts[flag] = sum(1 for v in all_variants if v.get(flag))
        tos = [v for v in all_variants if v.get("tos_bad")]
        langs = Counter(v.get("language") or "" for v in all_variants)
        years = Counter()
        for v in all_variants:
            rel = v.get("release") or ""
            if len(rel) == 4 and rel.isdigit():
                years[rel] += 1
        if flag_counts:
            log(f"variants with dump flags: {flag_counts} (of {len(all_variants)})")
        log(f"variants with TOS/bad notes: {len(tos)}")
        for v in tos[:10]:
            log(f"  TOS/BAD: {v['title']} - {v['tos_bad']}")
        if len(tos) > 10:
            log(f"  ... and {len(tos) - 10} more")
        top_langs = ", ".join(f"{k or '-'}={v}" for k, v in langs.most_common(5))
        log(f"top languages: {top_langs}")
        if years:
            span = f"{min(years)}-{max(years)}"
            log(f"release years: {span} ({len(years)} distinct years)")
        unmatched = res["unmatched_folders"]
        if unmatched:
            log(f"folders without data (first 10 of {len(unmatched)}):")
            for f in unmatched[:10]:
                log(f"  {f}")
    log("")
    log("report done (full unmatched list: extract writes unmatched-report.txt)")
    return 0


# --------------------------------------------------------------------------
# cli
# --------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        prog="gameinfo",
        description="Marcer GameDVD game-info extractor (see ANALYSIS-game-data.md)")
    ap.add_argument("--version", action="version", version=f"gameinfo {TOOL_VERSION}")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_ex = sub.add_parser("extract", help="parse XLS files and write JSON output")
    p_ex.add_argument("--dry-run", action="store_true",
                      help="only parse and print summary, do not write")
    p_ex.add_argument("--kind", choices=KINDS, help="process only one kind")
    p_ex.set_defaults(func=cmd_extract)

    p_ck = sub.add_parser("check", help="validate output against sources")
    p_ck.set_defaults(func=cmd_check)

    p_rp = sub.add_parser("report", help="print an audit summary")
    p_rp.set_defaults(func=cmd_report)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
