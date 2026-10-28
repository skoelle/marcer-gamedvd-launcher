#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Crew ranking for the cracked-games section.

Counts direct Disk-1 release ZIPs per scene group (crews and individual
crackers) and prints a "crew view" ranking. The canonical group names come from
the ``Crew Sorted/Cracked Games - Crew Sorted`` tree; additional groups are
taken from the ``crew``/``cracked_by`` fields of ``games-cracked.json``. The
ZIP universe is the direct (non-subfolder) release layer of
``Title Sorted/Cracked Games - Title Sorted`` from
``<GameinfoDirectory>/full-index.json.gz`` (built by ``tools/full-index-gen``,
no screenshots required); disk-2+ entries are derived from the filename. The
screenshot index is only a fallback when the full index is missing.

Attribution is intentionally conservative and prefers crews over individual
crackers (crew view):

1. exact ZIP basename match against the Crew Sorted tree,
2. ``crew``/``cracked_by`` of the matching gameinfo folder (crew wins),
3. alias/fuzzy matching against canonical group aliases.

Paths/environment (see ``run.sh`` and the repo ``local/paths.env``):
``MARCER_ROOT_DIR``, ``MARCER_DATA_DIR`` (gameinfo files and
``full-index.json.gz`` are read/written under ``<MARCER_DATA_DIR>/gameinfo``)
and optionally ``MARCER_OUT_DIR`` (screenshot index fallback; override with
``--index``).

Outputs go to ``--out`` (default ``local/crew-analysis``) and contain the
ranking plus audit files for alias curation. No game data is modified.
"""
from __future__ import annotations

import argparse
import csv
import difflib
import gzip
import html
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from _lib import catalog_sections as cs  # noqa: E402

TOOL_VERSION = "0.1.5"
SCHEMA_VERSION = 1

REPO_ROOT = Path(__file__).resolve().parents[2]
GAMEINFO_SUBDIR = "gameinfo"
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


def default_gameinfo_dir() -> str:
    """The gameinfo directory: ``<MARCER_DATA_DIR>/gameinfo``."""
    data = env("MARCER_DATA_DIR")
    return str(Path(data) / GAMEINFO_SUBDIR) if data else ""


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


def load_tab_selection(path: Path) -> dict:
    if not path.is_file():
        return {"include_until": "", "keep": set(), "exclude": set()}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        sys.exit(f"error: cannot read crew-tab selection {path}: {exc}")
    keep_values = [clean_label(str(value)) for value in data.get("keep", []) if str(value).strip()]
    exclude_values = [clean_label(str(value)) for value in data.get("exclude", []) if str(value).strip()]
    return {
        "include_until": norm(str(data.get("include_until") or "")),
        "keep": {norm(value) for value in keep_values},
        "keep_exact": set(keep_values),
        "exclude": {norm(value) for value in exclude_values},
        "exclude_exact": set(exclude_values),
    }


def tab_selection_flags(names: list[str], selection: dict) -> dict[str, bool]:
    """Map original group name -> excluded flag for the Crews tab.

    Without ``include_until`` all groups are visible except explicit excludes.
    With it, groups up to the cutoff are visible, and only the ``keep`` groups
    after the cutoff remain. Matching uses normalized names, but the returned
    flags are keyed by the original name so groups whose names normalize to
    the same value (e.g. ``Replicants / Union`` and ``Replicants/Union``) keep
    independent visibility. For a normalized collision, ``keep``/``exclude``
    only apply to the configured original spelling.
    """
    include_until = selection["include_until"]
    keep = selection["keep"]
    keep_exact = selection.get("keep_exact", set())
    exclude = selection["exclude"]
    exclude_exact = selection.get("exclude_exact", set())
    norm_counts = Counter(norm(name) for name in names)

    def is_match(value: str, normalized_set: set[str], exact_set: set[str]) -> bool:
        normalized = norm(value)
        if normalized not in normalized_set:
            return False
        # A normalized collision (e.g. "Replicants / Masters" vs
        # "Replicants/Masters") only matches when the original spelling was
        # configured explicitly.
        return norm_counts.get(normalized, 0) == 1 or value in exact_set

    if not include_until:
        return {name: is_match(name, exclude, exclude_exact) for name in names}

    flags: dict[str, bool] = {}
    reached = False
    found = False
    for name in names:
        normalized = norm(name)
        if normalized == include_until:
            found = True
        if is_match(name, exclude, exclude_exact):
            flags[name] = True
            if normalized == include_until:
                reached = True
            continue
        if not reached:
            flags[name] = False
            if normalized == include_until:
                reached = True
        else:
            flags[name] = not is_match(name, keep, keep_exact)
    if not found:
        print(f"warning: include_until group not found: {include_until}",
              file=sys.stderr)
        return {name: is_match(name, exclude, exclude_exact) for name in names}
    return flags


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


# --------------------------------------------------------------------------
# crew image suggestions (cracktro candidates)
# --------------------------------------------------------------------------


def phash_distance(a: str, b: str) -> int:
    try:
        return bin(int(a, 16) ^ int(b, 16)).count("1")
    except (TypeError, ValueError):
        return 999


def compute_phash(path: Path) -> str:
    """Optional pHash fallback for images without sidecar metadata."""
    try:
        import imagehash
        from PIL import Image
    except Exception:
        return ""
    try:
        with Image.open(path) as image:
            return str(imagehash.phash(image))
    except Exception:
        return ""


def read_sidecar(screenshot_dir: Path, rel: str) -> dict | None:
    sidecar = screenshot_dir / Path(rel).parent / (Path(rel).stem + ".json")
    if not sidecar.is_file():
        return None
    try:
        return json.loads(sidecar.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def entry_image_candidates(screenshot_dir: Path, release: dict, entry: dict) -> list[dict]:
    """Candidate images of one release with pHash/kind/quality metadata.

    The screenshot index only stores image basenames. The sidecar JSON keeps
    the pHashes and capture statistics; replaying the generator's
    preview/candidate ordering maps the retained `_cNN` files back to those
    shots. Unmapped images fall back to a locally computed pHash when
    Pillow/imagehash are available.
    """
    rel = release.get("rel", "")
    folder = release.get("folder", "")
    if not rel:
        return []

    out: list[dict] = []
    seen: set[tuple[str, str]] = set()

    def add(
        file: str | None,
        phash: str | None,
        kind: str | None,
        status: str | None,
        shot: dict | None,
        order: int,
    ) -> None:
        if not file or not phash:
            return
        key = (rel, file)
        if key in seen:
            return
        seen.add(key)
        out.append({
            "release_rel": rel,
            "folder": folder,
            "file": file,
            "phash": phash,
            "kind": kind or "",
            "status": status or "",
            "order": order,
            "entropy": float((shot or {}).get("entropy") or 0),
            "std": float((shot or {}).get("std") or 0),
            "edges": float((shot or {}).get("edges") or 0),
            "score": float((shot or {}).get("score") or 0),
        })

    meta = read_sidecar(screenshot_dir, rel)
    if meta:
        shots = meta.get("shots", []) or []
        survivors = [
            shot for shot in shots
            if shot.get("kind") != "black"
            and not shot.get("boot_logo")
            and shot.get("dropped") != "duplicate"
        ]
        games = [shot for shot in survivors if shot.get("kind") == "game"]
        desktops = [shot for shot in survivors if shot.get("kind") == "desktop"]
        pick = max(games, key=lambda shot: shot.get("score") or 0, default=None)
        if pick is None:
            pick = max(desktops, key=lambda shot: shot.get("score") or 0, default=None)

        if pick is not None and entry.get("preview"):
            add(entry["preview"], pick.get("phash"), pick.get("kind"),
                entry.get("status"), pick, -1)
        others = [shot for shot in survivors if shot is not pick]
        candidate_names = list(entry.get("candidates") or [])
        for index, shot in enumerate(others):
            if index >= len(candidate_names):
                break
            add(candidate_names[index], shot.get("phash"), shot.get("kind"),
                entry.get("status"), shot, index)

    # Fallback for images the sidecar mapping did not cover.
    mapped = {item["file"] for item in out}
    for file in [entry.get("preview"), *(entry.get("candidates") or [])]:
        if not file or file in mapped:
            continue
        phash = compute_phash(screenshot_dir / Path(rel).parent / file)
        if phash:
            add(file, phash, entry.get("kind"), entry.get("status"), None, 1000)
    return out


def cluster_candidates(candidates: list[dict], threshold: int) -> list[list[dict]]:
    """Greedy perceptual clusters (Hamming distance on the 64-bit pHash)."""
    clusters: list[list[dict]] = []
    ordered = sorted(candidates, key=lambda item: (
        item["release_rel"], item["order"], item["file"]))
    for candidate in ordered:
        for cluster in clusters:
            if min(phash_distance(candidate["phash"], member["phash"])
                   for member in cluster) <= threshold:
                cluster.append(candidate)
                break
        else:
            clusters.append([candidate])
    return clusters


def candidate_quality(candidate: dict) -> float:
    weight = {
        "textscreen": 1.10,
        "darkscreen": 1.05,
        "game": 1.0,
        "desktop": 0.55,
    }.get(candidate.get("kind", ""), 0.8)
    entropy = candidate.get("entropy") or 0.0
    std = candidate.get("std") or 0.0
    edges = candidate.get("edges") or 0.0
    return (entropy + std / 100.0 + edges / 100.0) * weight


def cluster_stats(cluster: list[dict], total_releases: int) -> dict:
    releases = {item["release_rel"] for item in cluster}
    games = {item["folder"] for item in cluster}
    best = max(cluster, key=lambda item: (
        candidate_quality(item), -item["order"], item.get("entropy") or 0))
    coverage = len(releases) / max(1, total_releases)
    quality = candidate_quality(best)
    return {
        "distinct_releases": len(releases),
        "distinct_games": len(games),
        "coverage": round(coverage, 4),
        "quality": round(quality, 4),
        "phash": best["phash"],
        "image_rel": best["release_rel"],
        "image_name": best["file"],
        "kind": best["kind"],
        "status": best["status"],
        "entropy": best["entropy"],
        "std": best["std"],
        "edges": best["edges"],
        "rank_key": (len(games), len(releases), coverage, quality),
    }


PLAIN_DESKTOP_PHASHES = {"ffbf9c9c9c888088"}
GENERIC_CREW_THRESHOLD = 3


def suggest_crew_images(
    groups: list[dict],
    index: dict,
    screenshot_dir: Path,
    per_crew: int,
    phash_threshold: int,
) -> list[dict]:
    # First pass: gather per-crew candidates and how many crews share a pHash.
    # Generic screens (TOS/GEM desktop, common menus) appear across many crews;
    # a crew cracktro is usually specific to that crew.
    gathered: list[tuple[dict, list[dict], int]] = []
    phash_crews: dict[str, set[str]] = defaultdict(set)
    for group in groups:
        name = group.get("name", "")
        candidates: list[dict] = []
        releases_with_images = 0
        for release in group.get("releases", []):
            entry = index.get(release.get("rel", ""))
            if not entry:
                continue
            images = entry_image_candidates(screenshot_dir, release, entry)
            if images:
                releases_with_images += 1
                candidates.extend(images)
        candidates = [
            candidate for candidate in candidates
            if candidate["phash"] not in PLAIN_DESKTOP_PHASHES
        ]
        for candidate in candidates:
            phash_crews[candidate["phash"]].add(name)
        gathered.append((group, candidates, releases_with_images))

    suggestions: list[dict] = []
    for group, candidates, releases_with_images in gathered:
        if not candidates:
            suggestions.append({
                "group": group.get("name", ""),
                "crew_rank": group.get("rank", 0),
                "zips": group.get("zips", 0),
                "releases_with_images": 0,
                "suggestions": [],
            })
            continue
        clusters = cluster_candidates(candidates, phash_threshold)
        stats = []
        for cluster in clusters:
            item = cluster_stats(cluster, releases_with_images)
            cross = max(
                len(phash_crews.get(member["phash"], ())) for member in cluster)
            item["cross_crews"] = cross
            item["generic"] = cross > GENERIC_CREW_THRESHOLD
            item["rank_key"] = (
                0 if item["generic"] else 1,
                item["distinct_games"],
                item["distinct_releases"],
                item["coverage"],
                item["quality"],
            )
            stats.append(item)
        stats.sort(key=lambda item: item["rank_key"], reverse=True)
        selected = []
        for position, item in enumerate(stats[:per_crew], 1):
            selected.append({
                "position": position,
                "distinct_releases": item["distinct_releases"],
                "distinct_games": item["distinct_games"],
                "coverage": item["coverage"],
                "quality": item["quality"],
                "cross_crews": item["cross_crews"],
                "generic": item["generic"],
                "phash": item["phash"],
                "image_rel": item["image_rel"],
                "image_name": item["image_name"],
                "kind": item["kind"],
                "status": item["status"],
                "entropy": item["entropy"],
                "std": item["std"],
                "edges": item["edges"],
            })
        suggestions.append({
            "group": group.get("name", ""),
            "crew_rank": group.get("rank", 0),
            "zips": group.get("zips", 0),
            "releases_with_images": releases_with_images,
            "suggestions": selected,
        })
    return suggestions


def write_image_suggestions(
    suggestions: list[dict],
    screenshot_dir: Path,
    outdir: Path,
    generated: str,
) -> None:
    outdir.mkdir(parents=True, exist_ok=True)
    flat: list[dict] = []
    for crew in suggestions:
        for item in crew["suggestions"]:
            flat.append({
                "group": crew["group"],
                "crew_rank": crew["crew_rank"],
                "zips": crew["zips"],
                "releases_with_images": crew["releases_with_images"],
                **item,
                "path": str(screenshot_dir / Path(item["image_rel"]).parent / item["image_name"]),
            })

    with (outdir / "crew-image-suggestions.csv").open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow([
            "group", "crew_rank", "position", "distinct_games",
            "distinct_releases", "coverage", "cross_crews", "generic",
            "kind", "phash", "image_rel", "image_name", "path",
        ])
        for item in flat:
            writer.writerow([
                item["group"], item["crew_rank"], item["position"],
                item["distinct_games"], item["distinct_releases"],
                item["coverage"], item["cross_crews"],
                "yes" if item["generic"] else "no",
                item["kind"], item["phash"],
                item["image_rel"], item["image_name"], item["path"],
            ])

    payload = {
        "schema": SCHEMA_VERSION,
        "generated_at": generated,
        "screenshot_directory": str(screenshot_dir),
        "crews": suggestions,
    }
    (outdir / "crew-image-suggestions.json").write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    lines = [
        f"# Crew image suggestions ({generated})",
        "",
        "| Crew | # | Games | Releases | Cross-crews | Kind | Image |",
        "|---|---:|---:|---:|---:|---|---|",
    ]
    for item in flat:
        lines.append(
            f"| {item['group']} | {item['position']} | {item['distinct_games']} | "
            f"{item['distinct_releases']} | {item['cross_crews']} | "
            f"{item['kind']} | `{item['path']}` |")
    (outdir / "crew-image-suggestions.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8")

    html_lines = [
        "<!doctype html><html><head><meta charset='utf-8'>",
        "<title>Crew image suggestions</title>",
        "<style>body{background:#111;color:#ddd;font:13px sans-serif}"
        "table{border-collapse:collapse;margin:8px 0 24px}"
        "td,th{border:1px solid #333;padding:6px;vertical-align:top}"
        "img{max-width:320px;max-height:240px;display:block}"
        ".muted{color:#888}</style></head><body>",
        f"<h1>Crew image suggestions</h1><p class='muted'>{html.escape(generated)}</p>",
    ]
    current = None
    for item in flat:
        if item["group"] != current:
            if current is not None:
                html_lines.append("</table>")
            current = item["group"]
            html_lines.append(f"<h2>{html.escape(current)}</h2><table>")
            html_lines.append(
                "<tr><th>#</th><th>Image</th><th>Stats</th></tr>")
        path = Path(item["path"])
        uri = path.as_uri() if path.is_absolute() else str(path)
        html_lines.append(
            "<tr>"
            f"<td>{item['position']}</td>"
            f"<td><a href='{html.escape(uri)}'><img src='{html.escape(uri)}'></a>"
            f"<div class='muted'>{html.escape(item['image_name'])}</div></td>"
            f"<td>games {item['distinct_games']} · releases {item['distinct_releases']} · "
            f"coverage {item['coverage']:.1%} · cross-crews {item['cross_crews']}"
            f"{' · GENERIC' if item['generic'] else ''} · kind {html.escape(item['kind'])}<br>"
            f"<span class='muted'>{html.escape(item['image_rel'])}</span></td>"
            "</tr>")
    if current is not None:
        html_lines.append("</table>")
    html_lines.append("</body></html>")
    (outdir / "crew-image-suggestions.html").write_text(
        "\n".join(html_lines) + "\n", encoding="utf-8")


def load_zips_from_index(
    path: Path,
    include_subdirs: bool,
) -> tuple[list[tuple[str, str, str, str, int | None, bool]], int]:
    """Load the direct release ZIP universe from the screenshot index.

    Returns ``(zips, skipped_disks)``. ``skipped_disks`` counts the disk-2+
    entries excluded via ``status == "skipped_disk_n"`` within the selected
    scope (direct layer, or all entries with ``include_subdirs``).
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        sys.exit(f"error: cannot read screenshot index {path}: {exc}")
    entries = data.get("entries", data)
    out = []
    skipped_disks = 0
    for key, value in entries.items():
        if not isinstance(key, str) or not key.startswith(INDEX_PREFIX):
            continue
        if not isinstance(value, dict):
            continue
        rel = key[len(INDEX_PREFIX):]
        parts = rel.split("/")
        direct = len(parts) == 3
        if not direct and not include_subdirs:
            continue
        if len(parts) < 3:
            continue
        if value.get("status") == "skipped_disk_n":
            skipped_disks += 1
            continue
        name = str(value.get("name") or parts[-1])
        size = value.get("size")
        out.append((rel, parts[0], parts[1], name, size, direct))
    return out, skipped_disks


def load_zips_from_full_index(
    path: Path,
    include_subdirs: bool,
) -> tuple[list[tuple[str, str, str, str, int | None, bool]], int]:
    """Load the cracked ZIP universe from ``full-index.json.gz``.

    The full index is built from the game trees before screenshots exist, so
    the ranking no longer depends on the screenshot index. Disk-2+ entries are
    derived from the filename with the shared shotgen regex.
    """
    try:
        with gzip.open(path, "rt", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError, gzip.BadGzipFile) as exc:
        sys.exit(f"error: cannot read full index {path}: {exc}")
    entries = data.get("entries", {})
    out = []
    skipped_disks = 0
    for rel, value in entries.items():
        if not isinstance(rel, str) or not rel.startswith(INDEX_PREFIX):
            continue
        if not isinstance(value, dict):
            continue
        if value.get("section") not in (None, "cracked"):
            continue
        short = rel[len(INDEX_PREFIX):]
        parts = short.split("/")
        direct = len(parts) == 3
        if not direct and not include_subdirs:
            continue
        if len(parts) < 3:
            continue
        name = str(value.get("name") or parts[-1])
        if cs.is_skipped_disk(name):
            skipped_disks += 1
            continue
        size = value.get("size")
        out.append((rel, parts[0], parts[1], name, size, direct))
    return out, skipped_disks


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


def run_images(args) -> int:
    gameinfo_dir = Path(args.gameinfo).expanduser() if args.gameinfo else None
    if not gameinfo_dir or not gameinfo_dir.is_dir():
        sys.exit("error: GameinfoDirectory missing (set MARCER_DATA_DIR or --gameinfo)")

    crews_path = (
        Path(args.crews).expanduser()
        if args.crews
        else gameinfo_dir / "crews.json"
    )
    if not crews_path.is_file():
        sys.exit(f"error: {crews_path} not found — run the ranking command first")

    if not args.index:
        sys.exit("error: ScreenshotDirectory missing (set MARCER_OUT_DIR or --index)")
    candidate = Path(args.index).expanduser()
    index_path = candidate if candidate.is_file() else candidate / "index.json"
    if not index_path.is_file():
        sys.exit(f"error: screenshot index not found: {index_path}")
    screenshot_dir = index_path.parent

    try:
        crew_data = json.loads(crews_path.read_text(encoding="utf-8"))
        index_data = json.loads(index_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        sys.exit(f"error: cannot read crew/index data: {exc}")
    tab_selection = load_tab_selection(Path(args.crew_tab))
    all_groups = crew_data.get("groups", [])
    selection_flags = tab_selection_flags(
        [group.get("name", "") for group in all_groups], tab_selection)
    groups = [
        group for group in all_groups
        if not selection_flags.get(group.get("name", ""), False)
    ]
    if args.top > 0:
        groups = groups[:args.top]
    entries = index_data.get("entries", index_data)

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    suggestions = suggest_crew_images(
        groups, entries, screenshot_dir, args.per_crew, args.phash_distance)

    outdir = Path(args.out).expanduser()
    write_image_suggestions(suggestions, screenshot_dir, outdir, generated)

    print(f"crews analysed: {len(groups)}")
    print(f"suggestions: {sum(len(c['suggestions']) for c in suggestions)}")
    print(f"screenshot dir: {screenshot_dir}")
    print(f"output: {outdir}")
    for crew in suggestions:
        top = crew["suggestions"][0] if crew["suggestions"] else None
        if top is None:
            print(f"  {crew['crew_rank']:>3} {crew['group']}: no image candidates")
            continue
        print(f"  {crew['crew_rank']:>3} {crew['group']}: "
              f"{top['image_name']} (games {top['distinct_games']}, "
              f"releases {top['distinct_releases']}, kind {top['kind']})")

    if args.write_images:
        crew_images_path = (
            Path(args.crew_images_out).expanduser()
            if args.crew_images_out
            else gameinfo_dir / "crew-images.json"
        )
        if crew_images_path.exists() and not args.force:
            print(f"crew-images: {crew_images_path} exists (use --force to overwrite)")
        else:
            images = {}
            for crew in suggestions:
                if not crew["suggestions"]:
                    continue
                top = crew["suggestions"][0]
                images[crew["group"]] = {
                    "rel": top["image_rel"],
                    "name": top["image_name"],
                    "source": "auto",
                    "note": (
                        f"auto suggestion rank {top['position']}; "
                        f"games {top['distinct_games']}, "
                        f"releases {top['distinct_releases']}, "
                        f"cross-crews {top['cross_crews']}"
                    ),
                    "phash": top["phash"],
                }
            manual_path = Path(args.manual_images).expanduser()
            if manual_path.is_file():
                try:
                    manual = json.loads(manual_path.read_text(encoding="utf-8"))
                    for group, image in (manual.get("images") or {}).items():
                        if isinstance(image, dict):
                            images[group] = image
                except (OSError, ValueError) as exc:
                    print(f"manual images ignored: {exc}")
            payload = {
                "schema": SCHEMA_VERSION,
                "generated_at": generated,
                "images": images,
            }
            crew_images_path.parent.mkdir(parents=True, exist_ok=True)
            crew_images_path.write_text(
                json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            print(f"crew-images: {crew_images_path} "
                  f"({len(images)} entries, manual overrides included)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Rank cracked-game crews by direct Disk-1 release ZIPs.")
    parser.add_argument("command", nargs="?", default="ranking", choices=["ranking", "images"],
                        help="ranking (default) or images (suggest cracktro card images)")
    parser.add_argument("--root", default=env("MARCER_ROOT_DIR"), help="Root game directory (MARCER_ROOT_DIR)")
    parser.add_argument("--gameinfo", default=default_gameinfo_dir(), help="Gameinfo directory containing games-cracked.json (default: MARCER_DATA_DIR/gameinfo)")
    parser.add_argument("--full-index", default="", help="full-index.json.gz path (default: <GameinfoDirectory>/full-index.json.gz; preferred over --index)")
    parser.add_argument("--index", default=env("MARCER_OUT_DIR"), help="Screenshot output directory or index.json path (MARCER_OUT_DIR; fallback when the full index is missing)")
    parser.add_argument("--include-subdirs", action="store_true", help="Include STX/Original/Demo/... subfolders")
    parser.add_argument("--top", type=int, default=24, help="Rows printed to the console (default: 24)")
    parser.add_argument("--out", default=str(REPO_ROOT / "local" / "crew-analysis"), help="Output directory")
    parser.add_argument("--aliases", default=str(Path(__file__).with_name("aliases.json")))
    parser.add_argument("--exclude", default=str(Path(__file__).with_name("exclude.txt")))
    parser.add_argument("--crew-tab", default=str(Path(__file__).with_name("crew-tab.json")),
                        help="Crews tab selection (include_until/keep/exclude)")
    parser.add_argument("--crews-out", default="", help="crews.json path (default: <GameinfoDirectory>/crews.json)")
    parser.add_argument("--crews", default="", help="crews.json input for `images` (default: <GameinfoDirectory>/crews.json)")
    parser.add_argument("--per-crew", type=int, default=3, help="image suggestions per crew (default: 3)")
    parser.add_argument("--phash-distance", type=int, default=8, help="pHash Hamming threshold for image clustering (default: 8)")
    parser.add_argument("--write-images", action="store_true", help="write <GameinfoDirectory>/crew-images.json from the top suggestions")
    parser.add_argument("--crew-images-out", default="", help="crew-images.json output path for --write-images")
    parser.add_argument("--manual-images", default=str(Path(__file__).with_name("manual-images.json")),
                        help="curated crew image overrides merged by --write-images")
    parser.add_argument("--force", action="store_true", help="overwrite an existing crew-images.json")
    args = parser.parse_args()

    if args.command == "images":
        return run_images(args)

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
    tab_selection = load_tab_selection(Path(args.crew_tab))
    raw_crew_canon, alias_to_groups, abbrev_aliases, label_canon = build_registry(
        raw_crew_groups, gameinfo_labels, explicit, exclude
    )

    full_index_path = (
        Path(args.full_index).expanduser()
        if args.full_index
        else gameinfo_dir / "full-index.json.gz"
    )
    if full_index_path.is_file():
        zips, skipped_disks = load_zips_from_full_index(
            full_index_path, args.include_subdirs)
        zip_source = str(full_index_path)
    else:
        index_path: Path | None = None
        if args.index:
            candidate = Path(args.index).expanduser()
            index_path = candidate if candidate.is_file() else candidate / "index.json"
        if not index_path or not index_path.is_file():
            target = str(index_path) if index_path else "MARCER_OUT_DIR is not set"
            sys.exit(
                f"error: full index not found: {full_index_path}; screenshot "
                f"index not found: {target} (run full-index-gen, or set "
                f"MARCER_OUT_DIR/--index)"
            )
        zips, skipped_disks = load_zips_from_index(
            index_path, args.include_subdirs)
        zip_source = str(index_path)

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
            "skipped_disks": skipped_disks,
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

    selection_flags = tab_selection_flags([group for group, _ in ordered], tab_selection)
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
            "excluded": selection_flags.get(group, False),
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
            "skipped_disks": skipped_disks,
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
        f"- Disk 2+ excluded (`skipped_disk_n`): **{skipped_disks}**",
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

    print(f"direct release ZIPs: {len(zips)}  (disk 2+ excluded: {skipped_disks})")
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
