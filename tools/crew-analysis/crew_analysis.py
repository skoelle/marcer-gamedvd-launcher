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

# Values in the XLS `cracked_by`/`crew` columns that are not scene groups.
# Compared after `norm()`; never rendered as a cracker/crew.
PLACEHOLDER_LABELS = {"original", "unknown", "no 1 and no 2"}

# Tokens that are never part of a cracker/crew credit suffix.
SUFFIX_NOISE = {
    "zip", "disk", "disks", "version", "cracked", "unknown", "original",
    "demo", "preview", "modified", "fixed", "beta", "alpha", "bad", "tos",
    "tr", "hack", "trainer", "cheat", "patched", "release", "only", "mb",
    "kb", "msa", "stx", "ipf", "edition", "crack", "eng", "ger", "fre",
    "fra", "spa", "ita", "pol", "rus", "dut", "nor", "swe", "dan", "fin",
}

# Additional tokens that make a novel-name proposal noise (publishers,
# languages, display modes, …). Used only for new-groups-review.csv.
NOVEL_NOISE = SUFFIX_NOISE | {
    "polish", "mono", "unkown", "publisher", "pressimage", "atari", "corp",
    "ferde", "data", "pw", "ado", "kar", "ltd", "gmbh", "systems",
    "entertainment", "productions", "mag", "magazine", "magazin", "action",
    "log", "news", "international", "german", "french", "english",
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


def is_placeholder_label(value: str) -> bool:
    """True for XLS placeholders that must never be shown as cracker/crew."""
    label = clean_label(value)
    if not label:
        return False
    normalized = norm(label)
    return not normalized or normalized in PLACEHOLDER_LABELS


def clean_group_label(value: str) -> str:
    """Return a real cracker/crew label or ``""`` for placeholders."""
    label = clean_label(value)
    return "" if is_placeholder_label(label) else label


def unify_group_name(value: str) -> str:
    """Unify joint credits to the canonical ``A & B`` spelling."""
    label = clean_label(value)
    if not label:
        return ""
    label = re.sub(r"\s*(?:/|\+|&)\s*", " & ", label)
    label = re.sub(r"\s+\band\b\s+", " & ", label, flags=re.IGNORECASE)
    return re.sub(r"\s+", " ", label).strip()


def is_suffix_noise(token: str) -> bool:
    if token in SUFFIX_NOISE or token in DESCRIPTORS:
        return True
    return bool(re.fullmatch(r"v?\d+", token))


def credit_suffix(zip_name: str, title: str) -> list[str]:
    """Tokens of a ZIP filename after removing the game title/noise."""
    title_tokens = set(tokens(title))
    out: list[str] = []
    for token in tokens(zip_name):
        if token in title_tokens or is_suffix_noise(token):
            continue
        out.append(token)
    return out


def label_tokens(value: str) -> frozenset[str]:
    """Distinctive token set of a cracker/crew label (or empty)."""
    toks = tokens(clean_group_label(value))
    if not toks or not any(len(t) >= 3 for t in toks):
        return frozenset()
    return frozenset(toks)


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
        canonical = unify_group_name(clean_label(canonical))
        if not canonical:
            continue
        for alias in [canonical, *aliases]:
            alias = unify_group_name(clean_label(alias))
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


def load_joint_overrides(path: Path) -> set[str]:
    """Joint groups that may be dissolved into their main crew (exceptions)."""
    if not path.is_file():
        return set()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        sys.exit(f"error: cannot read joint-group config {path}: {exc}")
    return {
        unify_group_name(clean_label(str(value)))
        for value in data.get("dissolve", [])
        if str(value).strip()
    }


def load_zip_group_overrides(path: Path) -> dict[str, str]:
    """Exact ZIP rel -> group assignments that win over every matching step."""
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        sys.exit(f"error: cannot read zip-group config {path}: {exc}")
    out: dict[str, str] = {}
    for rel, group in (data.get("assign") or {}).items():
        rel = str(rel).replace("\\", "/").strip()
        group = unify_group_name(clean_group_label(str(group)))
        if rel and group:
            out[rel] = group
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

    raw_crew_canon = {
        raw: unify_group_name(canonical)
        for raw, canonical in raw_crew_canon.items()
    }
    label_canon = {
        label: unify_group_name(canonical)
        for label, canonical in label_canon.items()
    }
    alias_to_groups = {
        alias: {unify_group_name(canonical) for canonical in groups}
        for alias, groups in alias_to_groups.items()
    }
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
            groups.append(unify_group_name(parts[1]))
        if len(parts) < 2:
            continue
        crew = "!Unknown" if parts[0] == "!Unknown" else unify_group_name(parts[1])
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


def _is_trailing_marker(segment: str) -> bool:
    """True for dump/version markers such as BAD, Cracked, Disk 1, Tr."""
    label = clean_label(segment)
    if not label:
        return True
    words = tokens(label)
    if not words:
        # Pure numbering/punctuation (e.g. "1.0"), never a stopword like Crew.
        return all(not ch.isalpha() for ch in label)
    return all(word in SUFFIX_NOISE or word in DESCRIPTORS for word in words)


def exact_crew_entries(
    name: str,
    exact: dict[str, list[tuple[str, int]]],
) -> list[tuple[str, int]]:
    """Exact Crew Sorted lookup with trailing dump markers stripped.

    ``TNT - SJ Crew - BAD.zip`` falls back to ``TNT - SJ Crew.zip``; the base
    name must exist exactly in Crew Sorted, so this cannot invent matches.
    """
    hit = exact.get(name.lower())
    if hit:
        return hit
    stem, dot, extension = name.rpartition(".")
    if not dot:
        stem, extension = name, ""
    suffix = f".{extension}" if extension else ""
    parts = [clean_label(part) for part in stem.split(" - ")]
    while len(parts) > 1 and _is_trailing_marker(parts[-1]):
        parts.pop()
        # Never fall back to a bare game title: that matches unrelated ZIPs
        # from another crew folder (e.g. "Predator - Unknown" -> "Predator").
        if " - " not in " - ".join(parts):
            break
        hit = exact.get(f"{' - '.join(parts)}{suffix}".lower())
        if hit:
            return hit
    return []


def load_gameinfo(path: Path) -> tuple[dict[tuple[str, str], list[dict]], dict[str, set[str]]]:
    if not path.exists():
        sys.exit(f"error: gameinfo file not found: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    folders: dict[tuple[str, str], list[dict]] = {}
    labels: dict[str, set[str]] = defaultdict(set)
    for game in data.get("games", []):
        variants: list[dict] = []
        for variant in game.get("variants", []):
            crew = unify_group_name(
                clean_group_label(str(variant.get("crew") or "")))
            cracked_by = unify_group_name(
                clean_group_label(str(variant.get("cracked_by") or "")))
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


def pick_variant(
    variants: list[dict],
    group: str,
    label_canon: dict[str, str],
    zip_name: str,
) -> dict | None:
    """Return the XLS variant that belongs to this ZIP/group, or None.

    The group label wins when it is present in the gameinfo variants. Otherwise
    the variant whose crew/cracker label matches the ZIP filename is used. With
    several variants and no confident match the release metadata stays empty
    instead of falling back to the first (often ``Original``) variant, which
    used to show a wrong cracker/crew in the crew view.
    """
    for variant in variants:
        for label in (variant.get("crew", ""), variant.get("cracked_by", "")):
            if label and label_canon.get(label) == group:
                return variant
    zip_tokens = set(tokens(zip_name))
    zip_compact = compact(zip_name)
    best: tuple[int, dict] | None = None
    for variant in variants:
        for label in (variant.get("crew", ""), variant.get("cracked_by", "")):
            if not label:
                continue
            score = label_score(zip_tokens, zip_compact, label)
            if score < 2:
                continue
            if best is None or score > best[0]:
                best = (score, variant)
    if best is not None:
        return best[1]
    if len(variants) == 1:
        return variants[0]
    return None


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
    variant = pick_variant(variants, group, label_canon, name)
    base = variant or (variants[0] if variants else {})

    full_rel = rel if rel.startswith(f"{DEFAULT_TREE}/") else f"{DEFAULT_TREE}/{rel}"
    return {
        "rel": full_rel,
        "letter": letter,
        "folder": folder,
        "zip": name,
        "size": size,
        "source": source,
        "ambiguous": ambiguous,
        "title": base.get("title") or folder,
        "year": extract_year(base.get("release", "")),
        "publisher": base.get("publisher", ""),
        # Release-specific labels are only emitted when the variant was
        # identified; generic fields may still come from the first variant.
        "cracked_by": clean_group_label(
            variant.get("cracked_by", "") if variant else ""),
        "crew": clean_group_label(
            variant.get("crew", "") if variant else ""),
        "language": base.get("language", ""),
        "disks": base.get("disks", 0),
        "raw_dump": bool(base.get("raw_dump")),
        "pasti_dump": bool(base.get("pasti_dump")),
        "boxscan": bool(base.get("boxscan")),
        "tos_bad": base.get("tos_bad", ""),
        "special_flag": base.get("special_flag", ""),
        "special_note": base.get("special_note", ""),
    }


def _match_label(
    vocab: dict[frozenset[str], str], suffix: set[str]
) -> str | None:
    """Longest label whose tokens all occur in the credit suffix."""
    matches = [
        (len(key), len(label), label)
        for key, label in vocab.items()
        if key and key <= suffix
    ]
    if not matches:
        return None
    matches.sort(reverse=True)
    best = matches[0]
    if len(matches) > 1 and matches[1][0] == best[0] and matches[1][2] != best[2]:
        return None  # two equally specific labels -> do not guess
    return best[2]


def _group_name_in_suffix(
    group: str, aliases: set[str], suffix: set[str]
) -> bool:
    keys = [label_tokens(group)] + [label_tokens(a) for a in aliases]
    if any(key and key <= suffix for key in keys):
        return True
    suffix_compact = {compact(token) for token in suffix}
    for value in [group, *aliases]:
        value_compact = compact(value)
        if len(value_compact) >= 2 and value_compact in suffix_compact:
            return True
    return False


def collapse_single_zip_joint_crackers(
    release_rows: dict[str, list[dict]],
    primary: Counter[str],
    source_counts: Counter[str],
    crew_group_names: set[str],
    alias_to_groups: dict[str, set[str]],
    label_canon: dict[str, str],
) -> list[dict]:
    """Move one-ZIP joint cracker groups to the crew named in the release.

    Joint groups are protected by default, which is too strong for a combined
    credit that occurs only once: if its release carries an unambiguous crew
    label that resolves to an existing crew group, that crew wins.
    """
    existing_crews = {group for group in primary if primary[group] > 0}

    def resolve_crew(label: str) -> str | None:
        label = clean_group_label(label)
        if not label:
            return None
        canonical = label_canon.get(label)
        if canonical:
            return canonical
        groups = alias_to_groups.get(norm(label))
        if groups and len(groups) == 1:
            return next(iter(groups))
        return None

    moves: list[dict] = []
    for group, releases in list(release_rows.items()):
        if len(releases) != 1 or group in crew_group_names:
            continue
        if not is_combined(group):
            continue
        release = releases[0]
        target = resolve_crew(str(release.get("crew") or ""))
        if (
            not target
            or target == group
            or target not in crew_group_names
            or target not in existing_crews
        ):
            continue
        release_rows.setdefault(target, []).append(release)
        release_rows.pop(group, None)
        primary[target] += 1
        primary[group] -= 1
        if primary[group] <= 0:
            del primary[group]
        source_counts["weak_joint"] += 1
        release["crew"] = target
        moves.append({
            "from": group,
            "to": target,
            "zip": release.get("zip", ""),
        })
    return moves


def infer_release_labels(
    release_rows: dict[str, list[dict]],
    group_aliases: dict[str, set[str]],
    crew_group_names: set[str],
) -> dict[str, int]:
    """Fill empty cracker/crew labels from the ZIP credit suffix.

    Only groups with at least two releases contribute label vocabulary; a
    folder with a single release still gets its own group name when that name
    occurs in the ZIP. Returns counters for the run report.
    """
    cracker_vocab: dict[str, dict[frozenset[str], str]] = defaultdict(dict)
    crew_vocab: dict[str, dict[frozenset[str], str]] = defaultdict(dict)
    global_cracker: dict[frozenset[str], str] = {}
    global_crew: dict[frozenset[str], str] = {}
    for group, releases in release_rows.items():
        for release in releases:
            for field, vocab in (("cracked_by", cracker_vocab),
                                 ("crew", crew_vocab)):
                label = clean_group_label(str(release.get(field) or ""))
                key = label_tokens(label)
                if key:
                    vocab[group][key] = label
        if len(releases) >= 2:
            target = global_crew if group in crew_group_names else global_cracker
            for alias in group_aliases.get(group, set()) | {group}:
                key = label_tokens(alias)
                if key:
                    target.setdefault(key, group)

    stats = Counter()
    for group, releases in release_rows.items():
        multi = len(releases) >= 2
        aliases = group_aliases.get(group, set()) | {group}
        is_crew_group = group in crew_group_names
        # Do not re-use a token that is already part of the assigned group
        # name (e.g. "Empire" in "Dr Trap / Empire" must not mask crew "Elite").
        group_key = label_tokens(group)
        other_cracker = {
            key: label for key, label in global_cracker.items()
            if not (group_key and key <= group_key)
        }
        other_crew = {
            key: label for key, label in global_crew.items()
            if not (group_key and key <= group_key)
        }
        for release in releases:
            cracked_by = clean_group_label(
                str(release.get("cracked_by") or ""))
            crew = clean_group_label(str(release.get("crew") or ""))
            inferred: list[str] = []
            # An exact Crew Sorted match is authoritative; short names such
            # as "SJ Crew" would otherwise lose their distinctive token.
            if release.get("source") == "exact":
                if is_crew_group and not crew:
                    crew = group
                    inferred.append("crew")
                elif not is_crew_group and not cracked_by:
                    cracked_by = group
                    inferred.append("cracked_by")
            zip_tokens = set(tokens(str(release.get("zip") or "")))
            suffix = set(credit_suffix(
                str(release.get("zip") or ""),
                str(release.get("title") or release.get("folder") or ""),
            ))
            group_in_zip = _group_name_in_suffix(group, aliases, suffix)
            if not group_in_zip and (
                    abbrev_like(group) or len(compact(group)) <= 3):
                # Short brands such as V8 can be stripped as version noise.
                group_in_zip = _group_name_in_suffix(group, aliases, zip_tokens)
            if group_in_zip:
                if is_crew_group:
                    if crew != group:
                        crew = group
                        inferred.append("crew")
                elif cracked_by != group:
                    cracked_by = group
                    inferred.append("cracked_by")
            if suffix:
                if multi:
                    if not cracked_by:
                        label = _match_label(cracker_vocab.get(group, {}), suffix)
                        if label:
                            cracked_by = label
                            inferred.append("cracked_by")
                    if not crew:
                        label = _match_label(crew_vocab.get(group, {}), suffix)
                        if label:
                            crew = label
                            inferred.append("crew")
                # Global group registry (other crews/crackers in the credit).
                if not cracked_by:
                    label = _match_label(other_cracker, suffix)
                    if label and label != group:
                        cracked_by = label
                        inferred.append("cracked_by")
                if not crew:
                    label = _match_label(other_crew, suffix)
                    if label and label != group:
                        crew = label
                        inferred.append("crew")
            release["cracked_by"] = cracked_by
            release["crew"] = crew
            if inferred:
                release["inferred_fields"] = sorted(set(inferred))
                stats["releases"] += 1
                for field in release["inferred_fields"]:
                    stats[field] += 1
            else:
                release.pop("inferred_fields", None)
    return dict(stats)


def infer_unmatched_candidates(
    unmatched: list[tuple[str, str, str, str, int | None]],
    release_rows: dict[str, list[dict]],
    group_aliases: dict[str, set[str]],
) -> list[dict]:
    """Propose groups for unmatched ZIPs from their credit suffix.

    Matching tiers (strongest first): full group name/alias tokens, release-code
    prefix (``dbug192a`` -> D-Bug), compact contiguous name (``Dead Eye`` ->
    Deadeye), then tokens learned from assigned releases. Only one unique
    strong candidate is auto-applied; everything stays in the review CSV.
    """
    # Learned distinctive suffix tokens (mostly release codes such as SERE17).
    token_groups: dict[str, Counter[str]] = defaultdict(Counter)
    for group, releases in release_rows.items():
        if len(releases) < 2:
            continue
        for release in releases:
            suffix = credit_suffix(
                str(release.get("zip") or ""),
                str(release.get("title") or release.get("folder") or ""),
            )
            for token in set(suffix):
                if len(token) >= 4 or (len(token) >= 3 and any(
                        ch.isdigit() for ch in token)):
                    token_groups[token][group] += 1

    # Compact name/alias registry for code prefixes and joined names.
    compact_alias: dict[str, set[str]] = defaultdict(set)
    initials: dict[str, set[str]] = defaultdict(set)
    for group, aliases in group_aliases.items():
        if len(release_rows.get(group, [])) < 2:
            continue
        for alias in aliases | {group}:
            comp = compact(alias)
            if len(comp) >= 3:
                compact_alias[comp].add(group)
            words = tokens(alias)
            if len(words) >= 2:
                initials["".join(w[0] for w in words)].add(group)

    def code_groups(prefix: str) -> set[str]:
        exact = set(compact_alias.get(prefix, set()))
        if exact:
            return exact
        prefixed = {
            group for comp, groups in compact_alias.items()
            if len(comp) >= 4 and comp.startswith(prefix)
            for group in groups
        }
        if prefixed:
            return prefixed
        return set(initials.get(prefix, set()))

    out: list[dict] = []
    for rel, letter, folder, name, size in unmatched:
        suffix_list = credit_suffix(name, folder)
        suffix = set(suffix_list)
        high: dict[str, str] = {}
        code: dict[str, str] = {}
        compact_hits: dict[str, str] = {}
        medium: dict[str, str] = {}
        scores: dict[str, int] = {}
        for group, aliases in group_aliases.items():
            if len(release_rows.get(group, [])) < 2:
                continue
            keys = [label_tokens(group)] + [
                label_tokens(alias) for alias in aliases
            ]
            best: int | None = None
            for key in keys:
                if not key or not key <= suffix:
                    continue
                if best is None or len(key) > best:
                    best = len(key)
            if best is not None:
                scores[group] = best
        if scores:
            top_score = max(scores.values())
            top = sorted(g for g, score in scores.items() if score == top_score)
            if len(top) == 1:
                high[top[0]] = "group name"
            else:
                for group in top:
                    medium.setdefault(group, "group name (ambiguous)")
            for group in scores:
                if group not in high:
                    medium.setdefault(group, "group name (partial)")

        # Release-code prefixes: dbug192a -> D-Bug, SERE17 -> Serenade, …
        for token in suffix:
            match = re.match(r"^([a-z]{2,})(?=\d)", token)
            if not match:
                continue
            prefix = match.group(1)
            groups = code_groups(prefix)
            if len(groups) == 1:
                code[next(iter(groups))] = f"code:{prefix}"
            else:
                for group in groups:
                    medium.setdefault(group, f"code:{prefix} (ambiguous)")
        # Compact contiguous names: "dead eye" -> Deadeye, "rocky one" -> Rockyone.
        # Single tokens are already covered by the exact group-name tier.
        for i in range(len(suffix_list)):
            joined = suffix_list[i]
            for j in range(i + 1, min(len(suffix_list), i + 4)):
                joined += suffix_list[j]
                if len(joined) < 4:
                    continue
                groups = compact_alias.get(joined, set())
                if len(groups) == 1:
                    compact_hits[next(iter(groups))] = f"name:{joined}"
        for token in suffix:
            counts = token_groups.get(token) or {}
            owners = [g for g, n in counts.items() if n >= 2]
            if len(owners) == 1:
                medium.setdefault(owners[0], token)

        strong = set(high) | set(code) | set(compact_hits)
        candidates = sorted(strong | set(medium))
        if len(strong) == 1:
            group = next(iter(strong))
            confidence = "high"
            if group in high:
                match_type, evidence = "group_name", high[group]
            elif group in code:
                match_type, evidence = "code_prefix", code[group]
            else:
                match_type, evidence = "compact_name", compact_hits[group]
        elif len(strong) > 1:
            group, confidence, match_type, evidence = "", "ambiguous", "", ""
        elif len(candidates) == 1:
            group = candidates[0]
            confidence, match_type = "medium", "token"
            evidence = medium[group]
        else:
            group, confidence, match_type, evidence = "", "ambiguous", "", ""
        out.append({
            "rel": rel,
            "letter": letter,
            "folder": folder,
            "zip": name,
            "size": size,
            "group": group,
            "confidence": confidence,
            "match_type": match_type,
            "evidence": evidence,
            "candidates": ", ".join(candidates),
            "tokens": suffix_list,
        })
    return out


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


def crews_source_summary(zip_source: str) -> dict:
    """Path-free provenance block for the published ``crews.json``.

    The gameinfo asset is published; absolute local paths must never appear
    in it. The local audit (``local/crew-analysis/crew-ranking.json``) keeps
    the full paths via ``meta["source"]``.
    """
    return {
        "crew_tree": DEFAULT_CREW_TREE,
        "gameinfo": "games-cracked.json",
        "zips": Path(zip_source).name,
        "crews": "crews.json",
    }


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


def candidate_rank(
    group: str,
    source: str,
    score: int,
    width: int,
    crew_group_names: set[str],
    crew_strength: Counter[str],
    joint_overrides: set[str],
) -> tuple:
    """Rank one group candidate for the first-pass attribution."""
    protected_joint = 1 if (
        is_combined(group) and group not in joint_overrides
    ) else 0
    is_crew = 1 if group in crew_group_names else 0
    strength = crew_strength.get(group, 0)
    source_rank = 2 if source.startswith("gameinfo") else 1
    if protected_joint:
        # Preserve joint credits; among them the most specific match wins.
        return (1, score, width, is_crew, strength, source_rank)
    return (0, is_crew, strength, source_rank, score, width)


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
            if at_len >= 2:
                candidate = True
            elif alias_norm in abbrev_aliases or len(alias_tokens[0]) >= 4:
                # Single-token/abbreviation aliases must be in the credit
                # suffix; a game title must never satisfy them.
                candidate = alias_tokens[0] in suffix_tokens
            if candidate:
                for group in groups:
                    prev = hits.get(group, (0, 0))
                    hits[group] = max(prev, (at_len, len(alias_norm)))
        if at_len >= 2 and len(ca) >= 6 and ca in zip_compact:
            for group in groups:
                prev = hits.get(group, (0, 0))
                hits[group] = max(prev, (at_len, len(ca)))
        elif alias_norm in abbrev_aliases and ca in suffix_tokens:
            # Compact abbreviation (e.g. "A-HA" -> "aha") only counts in the
            # credit suffix, never in the game title ("TNT - SJ Crew").
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
    joint_overrides = load_joint_overrides(
        Path(__file__).with_name("joint-groups.json"))
    zip_group_overrides = load_zip_group_overrides(
        Path(__file__).with_name("zip-groups.json"))
    raw_crew_canon, alias_to_groups, abbrev_aliases, label_canon = build_registry(
        raw_crew_groups, gameinfo_labels, explicit, exclude
    )
    known_groups = (
        set(raw_crew_canon.values())
        | set(label_canon.values())
        | set(explicit.values())
    )
    for rel, group in zip_group_overrides.items():
        if group not in known_groups:
            sys.exit(
                f"error: zip-groups.json target {group!r} is not a known group "
                f"({rel})")
    crew_group_names = set(raw_crew_canon.values())
    for label, sources in gameinfo_labels.items():
        canonical = label_canon.get(label)
        if canonical and "crew" in sources:
            crew_group_names.add(canonical)
    raw_strength: Counter[str] = Counter()
    for entries in exact_name.values():
        for raw, _raw_size in entries:
            raw_strength[raw] += 1
    crew_strength: Counter[str] = Counter()
    for raw, count in raw_strength.items():
        canonical = raw_crew_canon.get(raw)
        if canonical:
            crew_strength[canonical] += count

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

    indexed_rels = {rel.replace("\\", "/") for rel, *_ in zips}
    for rel in zip_group_overrides:
        if rel not in indexed_rels:
            sys.exit(f"error: zip-groups.json rel not found in ZIP index: {rel}")

    primary: Counter[str] = Counter()
    source_counts: Counter[str] = Counter()
    unmatched: list[tuple[str, str, str, str, int | None]] = []
    ambiguous: list[tuple[str, str, str]] = []

    release_rows: dict[str, list[dict]] = defaultdict(list)
    ambiguous_rels: set[str] = set()

    for rel, letter, folder, name, size, _direct in zips:
        variants = folders.get((letter.casefold(), folder.casefold()), [])

        # 0) explicit ZIP rel overrides win over every matching step
        override = zip_group_overrides.get(rel.replace("\\", "/"))
        if override:
            primary[override] += 1
            source_counts["override"] += 1
            release_rows[override].append(make_release(
                rel, letter, folder, name, size, "override", override,
                variants, False, label_canon))
            continue

        # 1) exact basename match against Crew Sorted
        exact_crews = exact_crew_entries(name, exact_name)
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
        suffix_tokens = (
            set(tokens(name.split(" - ", 1)[1]))
            if " - " in name else set(tokens(name))
        )

        # 2) unified candidate selection: gameinfo labels + alias registry
        candidates: dict[str, tuple[tuple, str]] = {}

        def add_candidate(group: str, source: str, score: int,
                          width: int) -> None:
            if not group:
                return
            rank = candidate_rank(
                group, source, score, width,
                crew_group_names, crew_strength, joint_overrides,
            )
            prev = candidates.get(group)
            if prev is None or rank > prev[0]:
                candidates[group] = (rank, source)

        for variant in variants:
            for field, is_crew in (("crew", True), ("cracked_by", False)):
                label = variant.get(field, "")
                if not label:
                    continue
                canonical = label_canon.get(label)
                if not canonical:
                    continue
                score = label_score(zip_tokens, zip_compact, label)
                if score < 2:
                    continue
                add_candidate(
                    canonical,
                    "gameinfo_crew" if is_crew else "gameinfo_cracker",
                    score, len(label),
                )
        for at_len, width, group in alias_hits(
                zip_tokens, zip_compact, suffix_tokens,
                alias_to_groups, abbrev_aliases):
            add_candidate(group, "alias", at_len, width)

        if not candidates:
            unmatched.append((rel, letter, folder, name, size))
            continue
        group, (rank, source) = max(
            candidates.items(), key=lambda kv: kv[1][0])
        primary[group] += 1
        source_counts[source] += 1
        release_rows[group].append(make_release(
            rel, letter, folder, name, size, source, group,
            variants, rel in ambiguous_rels, label_canon))

    group_aliases: dict[str, set[str]] = defaultdict(set)
    for raw, canonical in raw_crew_canon.items():
        group_aliases[canonical].add(raw)
        if " - " in raw:
            base, suffix = [
                unify_group_name(clean_label(part))
                for part in raw.split(" - ", 1)
            ]
            if not is_combined(suffix):
                group_aliases[canonical].add(base)
                group_aliases[canonical].add(suffix)
    for label, canonical in label_canon.items():
        group_aliases[canonical].add(label)

    # Second pass (1/2): assign high-confidence unmatched ZIPs by name.
    unmatched_proposals = infer_unmatched_candidates(
        unmatched, release_rows, group_aliases)
    applied_rels: set[str] = set()
    for proposal in unmatched_proposals:
        if proposal["confidence"] != "high" or not proposal["group"]:
            continue
        group = proposal["group"]
        rel = proposal["rel"]
        letter = proposal["letter"]
        folder = proposal["folder"]
        name = proposal["zip"]
        size = proposal["size"]
        variants = folders.get((letter.casefold(), folder.casefold()), [])
        primary[group] += 1
        source_counts["inferred_name"] += 1
        release_rows[group].append(make_release(
            rel, letter, folder, name, size, "inferred_name", group,
            variants, False, label_canon))
        applied_rels.add(rel)
    if applied_rels:
        unmatched = [entry for entry in unmatched
                     if entry[0] not in applied_rels]

    # Second pass (2/2): fill empty cracker/crew labels from the ZIP name.
    inferred_stats = infer_release_labels(
        release_rows, group_aliases, crew_group_names)

    weak_joint_moves = collapse_single_zip_joint_crackers(
        release_rows, primary, source_counts, crew_group_names,
        alias_to_groups, label_canon)
    if weak_joint_moves:
        print(f"single-ZIP joint crackers collapsed: {len(weak_joint_moves)}", flush=True)

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
            "unmatched_inferred": len(applied_rels),
            "ambiguous": len(ambiguous),
            "groups": len(primary),
            "sources": dict(source_counts),
            "labels_inferred": inferred_stats,
        },
        "ranking": ranking,
    }

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
        "source": crews_source_summary(zip_source),
        "counts": {
            "groups": len(crew_groups),
            "releases": sum(len(g["releases"]) for g in crew_groups),
            "direct_zips": len(zips),
            "skipped_disks": skipped_disks,
            "unmatched": len(unmatched),
            "unmatched_inferred": len(applied_rels),
            "ambiguous": len(ambiguous),
            "labels_inferred": inferred_stats,
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
            crew = clean_group_label(str(variant.get("crew") or ""))
            cracked_by = clean_group_label(str(variant.get("cracked_by") or ""))
            if crew:
                label_occurrences[(crew, "crew")] += 1
            if cracked_by:
                label_occurrences[(cracked_by, "cracked_by")] += 1
    # Final release-side counts for every XLS label (groups-review.csv). One XLS
    # variant can cover several ZIPs, so these deliberately differ from the
    # xls_variant_rows count.
    release_stats: dict[tuple[str, str], dict] = defaultdict(
        lambda: {"zips": 0, "groups": Counter(), "inferred": 0})
    for group, releases in release_rows.items():
        for release in releases:
            inferred_fields = set(release.get("inferred_fields") or [])
            for field in ("cracked_by", "crew"):
                value = clean_group_label(str(release.get(field) or ""))
                if not value:
                    continue
                stats = release_stats[(value, field)]
                stats["zips"] += 1
                stats["groups"][group] += 1
                if field in inferred_fields:
                    stats["inferred"] += 1

    known_canonicals = set(raw_crew_canon.values()) | set(explicit.values())
    with (outdir / "groups-review.csv").open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow([
            "xls_label", "normalized", "xls_column", "xls_variant_rows",
            "canonical_group", "alias_status", "release_zips",
            "release_groups", "inferred_releases",
        ])
        for (label, source), count in sorted(
                label_occurrences.items(),
                key=lambda kv: (-kv[1], kv[0][0].lower())):
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
            stats = release_stats.get(
                (label, source),
                {"zips": 0, "groups": Counter(), "inferred": 0},
            )
            release_groups = "; ".join(
                group for group, _ in stats["groups"].most_common())
            writer.writerow([
                label, normalized, source, count, canonical or "", status,
                stats["zips"], release_groups, stats["inferred"],
            ])

    with (outdir / "label-inference.csv").open(
            "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow([
            "group", "rel", "zip", "cracked_by", "crew", "inferred_fields",
        ])
        for group, releases in release_rows.items():
            for release in releases:
                fields = release.get("inferred_fields") or []
                if not fields:
                    continue
                writer.writerow([
                    group,
                    release.get("rel", ""),
                    release.get("zip", ""),
                    release.get("cracked_by", ""),
                    release.get("crew", ""),
                    ",".join(fields),
                ])
    with (outdir / "inferred-matches.csv").open(
            "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow([
            "rel", "zip", "group", "confidence", "match_type", "evidence",
            "candidates", "tokens", "applied",
        ])
        for proposal in unmatched_proposals:
            writer.writerow([
                proposal["rel"],
                proposal["zip"],
                proposal["group"],
                proposal["confidence"],
                proposal["match_type"],
                proposal["evidence"],
                proposal["candidates"],
                " ".join(proposal.get("tokens") or []),
                "yes" if proposal["rel"] in applied_rels else "no",
            ])

    # Unknown cracker names are only proposed for review, never auto-created.
    novel: dict[str, dict] = {}
    for proposal in unmatched_proposals:
        if proposal["group"]:
            continue
        tokens_ = proposal.get("tokens") or []
        if not tokens_ or all(t in NOVEL_NOISE for t in tokens_):
            continue
        key = " ".join(tokens_)
        entry = novel.setdefault(key, {"count": 0, "examples": []})
        entry["count"] += 1
        if len(entry["examples"]) < 5:
            entry["examples"].append(proposal["zip"])
    with (outdir / "new-groups-review.csv").open(
            "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["candidate", "count", "examples"])
        for candidate, data in sorted(
                novel.items(), key=lambda kv: (-kv[1]["count"], kv[0])):
            writer.writerow([
                candidate, data["count"], " | ".join(data["examples"]),
            ])
    with (outdir / "unmatched.txt").open("w", encoding="utf-8") as fh:
        for rel, _letter, _folder, name, _size in unmatched:
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
        f"- Unmatched assigned by name (high confidence): **{len(applied_rels)}**",
        f"- Release labels inferred: **{inferred_stats.get('releases', 0)}** "
        f"({inferred_stats.get('cracked_by', 0)} cracker, "
        f"{inferred_stats.get('crew', 0)} crew)",
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
    print(f"inferred: {len(applied_rels)} unmatched ZIPs, "
          f"{inferred_stats.get('releases', 0)} release label sets")
    print(f"output: {outdir}")
    print(f"crews:  {crews_path}")
    print()
    print(f"{'#':>3}  {'ZIPs':>5}  Group")
    for row in ranking[: args.top]:
        print(f"{row['rank']:>3}  {row['zips']:>5}  {row['group']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
