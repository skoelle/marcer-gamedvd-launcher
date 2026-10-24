#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Crew ranking for the cracked-games section.

Counts direct release ZIPs per scene group (crews and individual crackers) and
prints a "crew view" ranking. The canonical group names come from the
``Crew Sorted/Cracked Games - Crew Sorted`` tree; additional groups are taken
from the ``crew``/``cracked_by`` fields of ``games-cracked.json``. The ZIP
universe is the direct (non-subfolder) release layer of
``Title Sorted/Cracked Games - Title Sorted``.

Attribution is intentionally conservative and prefers crews over individual
crackers (crew view):

1. exact ZIP basename match against the Crew Sorted tree,
2. ``crew``/``cracked_by`` of the matching gameinfo folder (crew wins),
3. alias/fuzzy matching against canonical group aliases.

Paths/environment (see ``run.sh`` and the repo ``local/paths.env``):
``MARCER_ROOT_DIR``, ``MARCER_PATCH_DIR`` (optional), ``MARCER_DATA_DIR`` and
``MARCER_OUT_DIR`` (optional screenshot index for the merged ZIP list).

Outputs go to ``--out`` (default ``local/crew-analysis``) and contain the
ranking plus audit files for alias curation. No game data is modified.
"""
from __future__ import annotations

import argparse
import csv
import difflib
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

TOOL_VERSION = "0.1.0"
SCHEMA_VERSION = 1

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TREE = "Title Sorted/Cracked Games - Title Sorted"
DEFAULT_CREW_TREE = "Crew Sorted/Cracked Games - Crew Sorted"
INDEX_PREFIX = DEFAULT_TREE + "/"

STOPWORDS = {
    "and", "the", "co", "crew", "inc", "ltd", "software",
    "of", "de", "la", "le", "der", "die", "das",
}

DESCRIPTORS = {
    "usa", "us", "europe", "eu", "german", "germany", "deutsch",
    "french", "france", "uk", "english", "swedish", "sweden",
    "australia", "australian", "italian", "italy", "spanish", "spain",
    "dutch", "netherlands", "belgium", "belgian", "scandinavian",
    "nordic", "canada", "canadian",
}

ABBREV_RE = re.compile(r"[A-Z0-9&+\-]{2,7}")


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def norm(value: str) -> str:
    s = value.lower().replace("/", " and ").replace("&", " and ").replace("+", " and ")
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def tokens(value: str) -> list[str]:
    return [
        t for t in re.findall(r"[a-z0-9]+", norm(value))
        if t not in STOPWORDS and len(t) >= 2
    ]


def compact(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())


def clean_label(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def abbrev_like(value: str) -> bool:
    s = value.strip()
    if not s:
        return False
    if bool(ABBREV_RE.fullmatch(s)) or (s.upper() == s and len(s) <= 7):
        return True
    # Short hyphenated brands such as "D-Bug" / "A-Team".
    if "-" in s and " " not in s and len(compact(s)) <= 6:
        return True
    # Short numeric brands such as "42 Crew" are safe to match as a unit.
    return bool(re.search(r"\d", s)) and len(compact(s)) <= 6


def is_combined(value: str) -> bool:
    return bool(re.search(r"[/&+]|\band\b", value.lower()))


def descriptor_base(value: str) -> str | None:
    if " - " not in value:
        return None
    base, suffix = [clean_label(x) for x in value.split(" - ", 1)]
    if norm(suffix) in DESCRIPTORS:
        return base
    return None


# --------------------------------------------------------------------------
# registry
# --------------------------------------------------------------------------


def load_aliases(path: Path) -> dict[str, str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    explicit: dict[str, str] = {}
    for canonical, aliases in data.get("groups", {}).items():
        canonical = clean_label(canonical)
        for alias in [canonical, *aliases]:
            alias = clean_label(alias)
            if alias:
                explicit[norm(alias)] = canonical
    return explicit


def load_exclude(path: Path) -> set[str]:
    out: set[str] = set()
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.add(norm(line))
    return out


def prefer_group(candidates: set[str], alias_norm: str) -> str:
    if len(candidates) == 1:
        return next(iter(candidates))
    for group in candidates:
        if norm(group) == alias_norm:
            return group
    for group in candidates:
        if " - " in group and norm(group.split(" - ", 1)[1]) == alias_norm:
            return group
    return sorted(candidates, key=lambda g: (len(g), g))[0]


def build_registry(
    raw_crew_groups: list[str],
    gameinfo_labels: dict[str, set[str]],
    explicit: dict[str, str],
    exclude: set[str],
) -> tuple[dict[str, str], dict[str, set[str]], set[str], dict[str, str]]:
    """Return (raw crew -> canonical, alias norm -> groups, abbrev aliases,
    gameinfo label -> canonical)."""

    raw_by_norm = {norm(g): g for g in raw_crew_groups}

    def canonical_raw(raw: str) -> str | None:
        raw = clean_label(raw)
        n = norm(raw)
        if not n or n in exclude:
            return None
        if n in explicit:
            return explicit[n]
        base = descriptor_base(raw)
        if base:
            bn = norm(base)
            if bn in explicit:
                return explicit[bn]
            if bn in raw_by_norm:
                return raw_by_norm[bn]
            return clean_label(base)
        if n.startswith("the ") and n[4:] in raw_by_norm:
            return raw_by_norm[n[4:]]
        return raw

    raw_crew_canon: dict[str, str] = {}
    for raw in raw_crew_groups:
        canonical = canonical_raw(raw)
        if canonical:
            raw_crew_canon[raw] = canonical

    raw_canon_by_norm: dict[str, str] = {
        norm(raw): canonical for raw, canonical in raw_crew_canon.items()
    }
    combined_raw: list[tuple[frozenset[str], str]] = []
    for raw, canonical in raw_crew_canon.items():
        if is_combined(canonical):
            wanted = frozenset(tokens(canonical))
            if wanted:
                combined_raw.append((wanted, canonical))

    def canonicalize(label: str) -> str | None:
        label = clean_label(label)
        n = norm(label)
        if not n or n in exclude:
            return None
        if n in explicit:
            return explicit[n]
        canonical = raw_canon_by_norm.get(n)
        if canonical is not None:
            return canonical
        if n.startswith("the "):
            stripped = n[4:]
            canonical = explicit.get(stripped) or raw_canon_by_norm.get(stripped)
            if canonical:
                return canonical
        base = descriptor_base(label)
        if base:
            return canonicalize(base)
        if is_combined(label):
            wanted = frozenset(tokens(label))
            if wanted:
                matches = {canonical for tokenset, canonical in combined_raw if tokenset == wanted}
                if len(matches) == 1:
                    return next(iter(matches))
            # Joint credits stay their own group (no silent collapse to one member).
            return label
        # fuzzy fallback for typo variants
        best: tuple[float, str] | None = None
        for raw, canonical in raw_crew_canon.items():
            ratio = difflib.SequenceMatcher(None, n, norm(raw)).ratio()
            if ratio >= 0.92 and (best is None or ratio > best[0]):
                best = (ratio, canonical)
        if best is not None:
            return best[1]
        return label

    label_canon: dict[str, str] = {}
    for label in gameinfo_labels:
        canonical = canonicalize(label)
        if canonical:
            label_canon[label] = canonical

    canonical_groups = set(raw_crew_canon.values()) | set(label_canon.values()) | set(explicit.values())

    alias_to_groups: dict[str, set[str]] = defaultdict(set)
    abbrev_aliases: set[str] = set()

    def add_alias(alias: str, canonical: str) -> None:
        alias = clean_label(alias)
        if not alias:
            return
        n = norm(alias)
        if not n or n in exclude:
            return
        alias_to_groups[n].add(canonical)
        if abbrev_like(alias):
            abbrev_aliases.add(n)

    for raw, canonical in raw_crew_canon.items():
        add_alias(raw, canonical)
        if " - " in raw:
            base, suffix = [clean_label(x) for x in raw.split(" - ", 1)]
            if is_combined(suffix):
                continue
            if abbrev_like(suffix) or abbrev_like(base):
                add_alias(base, canonical)
                add_alias(suffix, canonical)
            else:
                add_alias(base, canonical)
    for label, canonical in label_canon.items():
        add_alias(label, canonical)
    for alias_norm, canonical in explicit.items():
        add_alias(alias_norm, canonical)
    for canonical in canonical_groups:
        add_alias(canonical, canonical)

    return raw_crew_canon, alias_to_groups, abbrev_aliases, label_canon


# --------------------------------------------------------------------------
# data sources
# --------------------------------------------------------------------------


def scan_crew_sorted(root: Path) -> tuple[list[str], dict[str, list[tuple[str, int]]]]:
    groups: list[str] = []
    exact: dict[str, list[tuple[str, int]]] = defaultdict(list)
    if not root.is_dir():
        sys.exit(f"error: Crew Sorted tree not found: {root}")
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "@eaDir" and not d.startswith(".")]
        rel = os.path.relpath(dirpath, root)
        parts = [] if rel == "." else rel.split(os.sep)
        if len(parts) == 2 and parts[0] != "!Unknown":
            groups.append(parts[1])
        if len(parts) < 2:
            continue
        crew = "!Unknown" if parts[0] == "!Unknown" else parts[1]
        for filename in filenames:
            if not filename.lower().endswith(".zip"):
                continue
            path = Path(dirpath) / filename
            try:
                size = path.stat().st_size
            except OSError:
                size = -1
            exact[filename.lower()].append((crew, size))
    return sorted(set(groups)), exact


def load_gameinfo(path: Path) -> tuple[dict[tuple[str, str], list[dict]], dict[str, set[str]]]:
    if not path.exists():
        sys.exit(f"error: gameinfo file not found: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    folders: dict[tuple[str, str], list[dict]] = {}
    labels: dict[str, set[str]] = defaultdict(set)
    for game in data.get("games", []):
        variants: list[dict] = []
        for variant in game.get("variants", []):
            crew = clean_label(str(variant.get("crew") or ""))
            cracked_by = clean_label(str(variant.get("cracked_by") or ""))
            try:
                disks = int(variant.get("disks") or 0)
            except (TypeError, ValueError):
                disks = 0
            variants.append({
                "title": clean_label(str(variant.get("title") or "")),
                "publisher": clean_label(str(variant.get("publisher") or "")),
                "crew": crew,
                "cracked_by": cracked_by,
                "release": str(variant.get("release") or ""),
                "language": clean_label(str(variant.get("language") or "")),
                "disks": disks,
                "raw_dump": bool(variant.get("raw_dump")),
                "pasti_dump": bool(variant.get("pasti_dump")),
                "boxscan": bool(variant.get("boxscan")),
                "tos_bad": clean_label(str(variant.get("tos_bad") or "")),
                "special_flag": clean_label(str(variant.get("special_flag") or "")),
                "special_note": clean_label(str(variant.get("special_note") or "")),
            })
            if crew:
                labels[crew].add("crew")
            if cracked_by:
                labels[cracked_by].add("cracked_by")
        key = (str(game.get("letter") or "").casefold(), str(game.get("folder") or "").casefold())
        folders.setdefault(key, []).extend(variants)
    return folders, labels


YEAR_RE = re.compile(r"\d{4}")


def extract_year(value: str) -> str:
    match = YEAR_RE.search(value or "")
    return match.group(0) if match else ""


def pick_variant(variants: list[dict], group: str, label_canon: dict[str, str]) -> dict:
    for variant in variants:
        for label in (variant.get("crew", ""), variant.get("cracked_by", "")):
            if label and label_canon.get(label) == group:
                return variant
    return variants[0] if variants else {}


def make_release(
    rel: str,
    letter: str,
    folder: str,
    name: str,
    size: int | None,
    source: str,
    group: str,
    variants: list[dict],
    ambiguous: bool,
    label_canon: dict[str, str],
) -> dict:
    variant = pick_variant(variants, group, label_canon)
    full_rel = rel if rel.startswith(f"{DEFAULT_TREE}/") else f"{DEFAULT_TREE}/{rel}"
    return {
        "rel": full_rel,
        "letter": letter,
        "folder": folder,
        "zip": name,
        "size": size,
        "source": source,
        "ambiguous": ambiguous,
        "title": variant.get("title") or folder,
        "year": extract_year(variant.get("release", "")),
        "publisher": variant.get("publisher", ""),
        "cracked_by": variant.get("cracked_by", ""),
        "crew": variant.get("crew", ""),
        "language": variant.get("language", ""),
        "disks": variant.get("disks", 0),
        "raw_dump": bool(variant.get("raw_dump")),
        "pasti_dump": bool(variant.get("pasti_dump")),
        "boxscan": bool(variant.get("boxscan")),
        "tos_bad": variant.get("tos_bad", ""),
        "special_flag": variant.get("special_flag", ""),
        "special_note": variant.get("special_note", ""),
    }


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "group"


def load_zips_from_index(path: Path, include_subdirs: bool) -> list[tuple[str, str, str, str, int | None, bool]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        sys.exit(f"error: cannot read screenshot index {path}: {exc}")
    entries = data.get("entries", data)
    out = []
    for key, value in entries.items():
        if not isinstance(key, str) or not key.startswith(INDEX_PREFIX):
            continue
        rel = key[len(INDEX_PREFIX):]
        parts = rel.split("/")
        direct = len(parts) == 3
        if not direct and not include_subdirs:
            continue
        if len(parts) < 3:
            continue
        name = str(value.get("name") or parts[-1])
        size = value.get("size")
        out.append((rel, parts[0], parts[1], name, size, direct))
    return out


def scan_tree(base: Path) -> dict[str, int]:
    found: dict[str, int] = {}
    if not base.is_dir():
        return found
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d != "@eaDir" and not d.startswith(".")]
        for filename in filenames:
            if not filename.lower().endswith(".zip"):
                continue
            path = Path(dirpath) / filename
            rel = os.path.relpath(path, base).replace(os.sep, "/")
            try:
                found[rel] = path.stat().st_size
            except OSError:
                found[rel] = -1
    return found


def load_zips_from_fs(
    root: Path,
    patch: Path | None,
    include_subdirs: bool,
) -> list[tuple[str, str, str, str, int | None, bool]]:
    merged: dict[str, tuple[str, int]] = {}
    for rel, size in scan_tree(root).items():
        merged[rel.casefold()] = (rel, size)
    if patch and patch.is_dir():
        for rel, size in scan_tree(patch).items():
            merged[rel.casefold()] = (rel, size)
    out = []
    for rel, size in merged.values():
        parts = rel.split("/")
        direct = len(parts) == 3
        if not direct and not include_subdirs:
            continue
        if len(parts) < 3:
            continue
        out.append((rel, parts[0], parts[1], parts[-1], size, direct))
    return out


# --------------------------------------------------------------------------
# matching
# --------------------------------------------------------------------------


def label_score(zip_tokens: set[str], zip_compact: str, label: str) -> int:
    label_tokens = tokens(label)
    strong = [t for t in label_tokens if len(t) >= 3]
    if not strong:
        return 0
    score = 2 * sum(1 for t in strong if t in zip_tokens)
    for t in strong:
        if t in zip_tokens:
            continue
        for z in zip_tokens:
            if len(t) >= 5 and len(z) >= 5 and (z.startswith(t) or t.startswith(z)):
                score += 1
                break
        else:
            continue
        break
    compact_label = compact(label)
    if len(label_tokens) >= 2 and len(compact_label) >= 6 and compact_label in zip_compact:
        score += 3
    return score


def alias_hits(
    zip_tokens: set[str],
    zip_compact: str,
    suffix_tokens: set[str],
    alias_to_groups: dict[str, set[str]],
    abbrev_aliases: set[str],
) -> list[tuple[int, int, str]]:
    hits: dict[str, tuple[int, int]] = {}
    for alias_norm, groups in alias_to_groups.items():
        if not alias_norm:
            continue
        alias_tokens = tokens(alias_norm)
        at_len = len(alias_tokens)
        ca = compact(alias_norm)
        candidate = False
        if alias_tokens and all(t in zip_tokens for t in alias_tokens):
            candidate = at_len >= 2 or alias_norm in abbrev_aliases or (
                at_len == 1 and len(alias_tokens[0]) >= 4 and alias_tokens[0] in suffix_tokens
            )
            if candidate:
                for group in groups:
                    prev = hits.get(group, (0, 0))
                    hits[group] = max(prev, (at_len, len(alias_norm)))
        if at_len >= 2 and len(ca) >= 6 and ca in zip_compact:
            for group in groups:
                prev = hits.get(group, (0, 0))
                hits[group] = max(prev, (at_len, len(ca)))
        elif alias_norm in abbrev_aliases and ca in zip_tokens:
            # compact abbreviation (e.g. "A-HA" -> "aha"), whole token only
            for group in groups:
                prev = hits.get(group, (0, 0))
                hits[group] = max(prev, (at_len, len(ca)))
    return [(length, width, group) for group, (length, width) in hits.items()]


# --------------------------------------------------------------------------
# main analysis
# --------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description="Rank cracked-game crews by direct release ZIPs.")
    parser.add_argument("--root", default=env("MARCER_ROOT_DIR"), help="Root game directory (MARCER_ROOT_DIR)")
    parser.add_argument("--patch", default=env("MARCER_PATCH_DIR"), help="Patch directory (MARCER_PATCH_DIR)")
    parser.add_argument("--gameinfo", default=env("MARCER_DATA_DIR"), help="Directory containing games-cracked.json")
    parser.add_argument("--index", default=env("MARCER_OUT_DIR"), help="Screenshot output directory or index.json path")
    parser.add_argument("--scan", action="store_true", help="Scan Title Sorted on disk instead of using index.json")
    parser.add_argument("--include-subdirs", action="store_true", help="Include STX/Original/Demo/... subfolders")
    parser.add_argument("--top", type=int, default=24, help="Rows printed to the console (default: 24)")
    parser.add_argument("--out", default=str(REPO_ROOT / "local" / "crew-analysis"), help="Output directory")
    parser.add_argument("--aliases", default=str(Path(__file__).with_name("aliases.json")))
    parser.add_argument("--exclude", default=str(Path(__file__).with_name("exclude.txt")))
    parser.add_argument("--crews-out", default="", help="crews.json path (default: <GameinfoDirectory>/crews.json)")
    args = parser.parse_args()

    root = Path(args.root).expanduser() if args.root else None
    if not root or not root.is_dir():
        sys.exit("error: RootDirectory is missing/not a directory (set MARCER_ROOT_DIR or --root)")

    crew_root = root / DEFAULT_CREW_TREE
    raw_crew_groups, exact_name = scan_crew_sorted(crew_root)

    gameinfo_dir = Path(args.gameinfo).expanduser() if args.gameinfo else None
    if not gameinfo_dir:
        sys.exit("error: gameinfo directory missing (set MARCER_DATA_DIR or --gameinfo)")
    folders, gameinfo_labels = load_gameinfo(gameinfo_dir / "games-cracked.json")

    explicit = load_aliases(Path(args.aliases))
    exclude = load_exclude(Path(args.exclude))
    raw_crew_canon, alias_to_groups, abbrev_aliases, label_canon = build_registry(
        raw_crew_groups, gameinfo_labels, explicit, exclude
    )

    if args.scan:
        title_root = root / DEFAULT_TREE
        patch_root = Path(args.patch).expanduser() / DEFAULT_TREE if args.patch else None
        zips = load_zips_from_fs(title_root, patch_root, args.include_subdirs)
        zip_source = "filesystem"
    else:
        index_path: Path | None = None
        if args.index:
            candidate = Path(args.index).expanduser()
            index_path = candidate if candidate.is_file() else candidate / "index.json"
        if index_path and index_path.is_file():
            zips = load_zips_from_index(index_path, args.include_subdirs)
            zip_source = str(index_path)
        else:
            title_root = root / DEFAULT_TREE
            patch_root = Path(args.patch).expanduser() / DEFAULT_TREE if args.patch else None
            zips = load_zips_from_fs(title_root, patch_root, args.include_subdirs)
            zip_source = "filesystem (index.json not found)"

    primary: Counter[str] = Counter()
    source_counts: Counter[str] = Counter()
    unmatched: list[tuple[str, str]] = []
    ambiguous: list[tuple[str, str, str]] = []

    release_rows: dict[str, list[dict]] = defaultdict(list)
    ambiguous_rels: set[str] = set()

    for rel, letter, folder, name, size, _direct in zips:
        variants = folders.get((letter.casefold(), folder.casefold()), [])

        # 1) exact basename match against Crew Sorted
        exact_crews = exact_name.get(name.lower(), [])
        canonical_crews = {
            raw_crew_canon[raw]
            for raw, _raw_size in exact_crews
            if raw in raw_crew_canon
        }
        if len(canonical_crews) > 1 and size is not None:
            sized = {
                raw_crew_canon[raw]
                for raw, raw_size in exact_crews
                if raw in raw_crew_canon and raw_size == size
            }
            if sized:
                canonical_crews = sized
        if len(canonical_crews) == 1:
            group = next(iter(canonical_crews))
            primary[group] += 1
            source_counts["exact"] += 1
            release_rows[group].append(make_release(
                rel, letter, folder, name, size, "exact", group,
                variants, False, label_canon))
            continue
        if len(canonical_crews) > 1:
            ambiguous.append((rel, name, ", ".join(sorted(canonical_crews))))
            ambiguous_rels.add(rel)

        zip_tokens = set(tokens(name))
        zip_compact = compact(name)
        suffix_tokens = set(tokens(name.split(" - ", 1)[1])) if " - " in name else set(tokens(name))

        # 2) gameinfo crew/cracker labels of the folder (crew wins over cracker)
        crew_best: tuple[int, int, str] | None = None
        cracker_best: tuple[int, int, str] | None = None
        for variant in variants:
            crew = variant.get("crew", "")
            cracked_by = variant.get("cracked_by", "")
            for label, is_crew in ((crew, True), (cracked_by, False)):
                if not label:
                    continue
                canonical = label_canon.get(label)
                if not canonical:
                    continue
                score = label_score(zip_tokens, zip_compact, label)
                if score < 2:
                    continue
                candidate = (score, len(label), canonical)
                target = crew_best if is_crew else cracker_best
                if target is None or candidate[:2] > target[:2]:
                    if is_crew:
                        crew_best = candidate
                    else:
                        cracker_best = candidate
        if crew_best is not None:
            group = crew_best[2]
            primary[group] += 1
            source_counts["gameinfo_crew"] += 1
            release_rows[group].append(make_release(
                rel, letter, folder, name, size, "gameinfo_crew", group,
                variants, rel in ambiguous_rels, label_canon))
            continue
        if cracker_best is not None:
            group = cracker_best[2]
            primary[group] += 1
            source_counts["gameinfo_cracker"] += 1
            release_rows[group].append(make_release(
                rel, letter, folder, name, size, "gameinfo_cracker", group,
                variants, rel in ambiguous_rels, label_canon))
            continue

        # 3) global alias/fuzzy fallback
        hits = alias_hits(zip_tokens, zip_compact, suffix_tokens, alias_to_groups, abbrev_aliases)
        if hits:
            hits.sort(key=lambda h: (h[0], h[1], h[2]), reverse=True)
            group = hits[0][2]
            primary[group] += 1
            source_counts["alias"] += 1
            release_rows[group].append(make_release(
                rel, letter, folder, name, size, "alias", group,
                variants, rel in ambiguous_rels, label_canon))
            continue

        unmatched.append((rel, name))

    ordered = sorted(primary.items(), key=lambda kv: (-kv[1], kv[0].casefold()))
    ranking = [
        {"rank": i + 1, "group": group, "zips": count}
        for i, (group, count) in enumerate(ordered)
    ]

    crews_path = (
        Path(args.crews_out).expanduser()
        if args.crews_out
        else gameinfo_dir / "crews.json"
    )

    outdir = Path(args.out).expanduser()
    outdir.mkdir(parents=True, exist_ok=True)
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    meta = {
        "schema": SCHEMA_VERSION,
        "tool_version": TOOL_VERSION,
        "generated_at": generated,
        "source": {
            "root": str(root),
            "crew_tree": str(crew_root),
            "gameinfo": str(gameinfo_dir / "games-cracked.json"),
            "zips": zip_source,
            "crews": str(crews_path),
        },
        "counts": {
            "direct_zips": len(zips),
            "assigned": sum(primary.values()),
            "unmatched": len(unmatched),
            "ambiguous": len(ambiguous),
            "groups": len(primary),
            "sources": dict(source_counts),
        },
        "ranking": ranking,
    }
    crew_group_names = set(raw_crew_canon.values())
    for label, sources in gameinfo_labels.items():
        canonical = label_canon.get(label)
        if canonical and "crew" in sources:
            crew_group_names.add(canonical)

    group_aliases: dict[str, set[str]] = defaultdict(set)
    for raw, canonical in raw_crew_canon.items():
        group_aliases[canonical].add(raw)
        if " - " in raw:
            base, suffix = [clean_label(part) for part in raw.split(" - ", 1)]
            if not is_combined(suffix):
                group_aliases[canonical].add(base)
                group_aliases[canonical].add(suffix)
    for label, canonical in label_canon.items():
        group_aliases[canonical].add(label)

    def dedupe_aliases(values: set[str]) -> list[str]:
        seen: set[str] = set()
        out: list[str] = []
        for value in sorted(values, key=str.casefold):
            key = value.casefold()
            if not value or key in seen:
                continue
            if norm(value) in exclude or norm(value) in DESCRIPTORS:
                continue
            seen.add(key)
            out.append(value)
        return out

    used_slugs: set[str] = set()
    crew_groups: list[dict] = []
    for rank, (group, count) in enumerate(ordered, 1):
        slug = slugify(group)
        base = slug
        suffix = 2
        while slug in used_slugs:
            slug = f"{base}-{suffix}"
            suffix += 1
        used_slugs.add(slug)
        aliases = dedupe_aliases(group_aliases.get(group, set()) | {group})
        releases = release_rows.get(group, [])
        releases.sort(key=lambda r: (
            r.get("year", "") == "",
            r.get("year", ""),
            r.get("title", "").casefold(),
            r.get("zip", "").casefold(),
        ))
        crew_groups.append({
            "id": slug,
            "name": group,
            "kind": "crew" if group in crew_group_names else "cracker",
            "rank": rank,
            "zips": count,
            "aliases": aliases,
            "image": None,
            "releases": releases,
        })

    crews_payload = {
        "schema": SCHEMA_VERSION,
        "generated_at": generated,
        "source": meta["source"],
        "counts": {
            "groups": len(crew_groups),
            "releases": sum(len(g["releases"]) for g in crew_groups),
            "direct_zips": len(zips),
            "unmatched": len(unmatched),
            "ambiguous": len(ambiguous),
        },
        "groups": crew_groups,
    }
    crews_path.parent.mkdir(parents=True, exist_ok=True)
    crews_path.write_text(
        json.dumps(crews_payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    (outdir / "crew-ranking.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    with (outdir / "crew-ranking.csv").open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["rank", "group", "zips"])
        for row in ranking:
            writer.writerow([row["rank"], row["group"], row["zips"]])

    # Per-label audit for alias curation.
    label_occurrences: Counter[tuple[str, str]] = Counter()
    for game in json.loads((gameinfo_dir / "games-cracked.json").read_text(encoding="utf-8")).get("games", []):
        for variant in game.get("variants", []):
            crew = clean_label(str(variant.get("crew") or ""))
            cracked_by = clean_label(str(variant.get("cracked_by") or ""))
            if crew:
                label_occurrences[(crew, "crew")] += 1
            if cracked_by:
                label_occurrences[(cracked_by, "cracked_by")] += 1
    known_canonicals = set(raw_crew_canon.values()) | set(explicit.values())
    with (outdir / "groups-review.csv").open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["label", "normalized", "source", "variants", "mapped_group", "status"])
        for (label, source), count in sorted(label_occurrences.items(), key=lambda kv: (-kv[1], kv[0][0].lower())):
            normalized = norm(label)
            canonical = label_canon.get(label)
            if normalized in exclude:
                status = "excluded"
            elif canonical is None:
                status = "unmapped"
            elif canonical not in known_canonicals:
                status = "new"
            elif normalized == norm(canonical) and label == canonical:
                status = "canonical"
            else:
                status = "aliased"
            writer.writerow([label, normalized, source, count, canonical or "", status])

    with (outdir / "unmatched.txt").open("w", encoding="utf-8") as fh:
        for rel, name in unmatched:
            fh.write(f"{rel}\t{name}\n")
    with (outdir / "ambiguous.txt").open("w", encoding="utf-8") as fh:
        for rel, name, groups in ambiguous:
            fh.write(f"{rel}\t{name}\t{groups}\n")

    lines = [
        f"# Cracked-game crew ranking ({generated})",
        "",
        f"- Direct release ZIPs: **{len(zips)}**",
        f"- Assigned: **{sum(primary.values())}** ({', '.join(f'{k} {v}' for k, v in sorted(source_counts.items()))})",
        f"- Unmatched: **{len(unmatched)}**; ambiguous exact matches: **{len(ambiguous)}**",
        f"- Groups with at least one ZIP: **{len(primary)}**",
        f"- ZIP source: `{zip_source}`",
        "",
        f"## Top {args.top}",
        "",
        "| # | Group | ZIPs |",
        "|---:|---|---:|",
    ]
    for row in ranking[: args.top]:
        lines.append(f"| {row['rank']} | {row['group']} | {row['zips']} |")
    (outdir / "crew-ranking.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"direct release ZIPs: {len(zips)}")
    print(f"assigned: {sum(primary.values())}  unmatched: {len(unmatched)}  groups: {len(primary)}")
    print(f"output: {outdir}")
    print(f"crews:  {crews_path}")
    print()
    print(f"{'#':>3}  {'ZIPs':>5}  Group")
    for row in ranking[: args.top]:
        print(f"{row['rank']:>3}  {row['zips']:>5}  {row['group']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
