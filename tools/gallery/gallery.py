#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Marcer GameDVD gallery webapp — stdlib-only local server.

Serves the screenshot archive (MARCER_OUT_DIR/index.json + PNG tree) joined
with the game metadata (MARCER_DATA_DIR/gameinfo/games-*.json) as an
interactive gallery. See SPEC-gallery-webapp.md for the behavioral
specification.
"""
import argparse
import json
import os
import re
import signal
import sys
import threading
import time
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

TOOL_VERSION = "0.4.1"
BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

DEFAULTS = {
    "host": "0.0.0.0",
    "port": 8764,
    "page_size": 60,
    "show_candidates": True,
    "default_status": "with_screenshot",
    "image_cache_seconds": 86400,
    "local_assets_cache_seconds": 60,
}

# display order for status aggregation (SPEC-gallery-webapp.md 4.4)
STATUS_ORDER = ["done", "desktop", "no_usable_shots", "interrupted",
                "pending", "skipped_disk_n"]
STATUS_LABELS = {
    "done": "done (game)",
    "desktop": "desktop (only)",
    "desktop_any": "desktop (any ZIP)",
    "desktop_text": "desktop text",
    "desktop_black": "desktop black",
    "no_usable_shots": "no usable shots (only)",
    "no_usable_shots_any": "no usable shots (any ZIP)",
    "interrupted": "interrupted",
    "pending": "pending",
    "skipped_disk_n": "skipped (disk 2+)",
    "any": "any status",
    "with_screenshot": "with screenshot",
}
YEAR_RE = re.compile(r"\d{4}")
SORTS = ("name", "year", "publisher", "cracker", "crew")

# Per-section screenshot index filenames (screenshot-gen; desktop parity).
# `index.json` is the cracked archive (back-compat), pd/utils have their own.
SECTION_INDEX_NAMES = {
    "cracked": "index.json",
    "pd": "index-pd.json",
    "utils": "index-utils.json",
    "magazine": "index-magazine.json",
    "falcon": "index-falcon.json",
}
CANONICAL_SECTION_TREES = {
    "cracked": "Title Sorted/Cracked Games - Title Sorted",
    "pd": "Title Sorted/PD Games - Title Sorted",
    "utils": "Title Sorted/Utilitys - Title Sorted",
    "magazine": "Bonus/Magazine Cover Disks",
    "falcon": "Falcon 030/Title Sorted",
}
BOXSCAN_DIR_NAMES = frozenset({"boxscan", "box scan"})
MANUAL_DIR_NAMES = frozenset({"manual", "manuals"})
BOX_IMAGE_EXTS = frozenset({".png", ".jpg", ".jpeg"})
MANUAL_IMAGE_EXTS = frozenset({".png", ".jpg", ".jpeg", ".gif"})
MANUAL_DOC_EXTS = frozenset({".pdf", ".doc", ".txt", ".msa"})
MAX_ZIP_ENTRIES = 10000
GAMEINFO_SUBDIR = "gameinfo"
CREW_FILE = "crews.json"
CREW_IMAGES_FILE = "crew-images.json"

# XLS placeholders that are not scene groups (normalized).
PLACEHOLDER_GROUPS = frozenset({"original", "unknown", "no 1 and no 2"})


def normalize_group_label(value):
    s = str(value or "").strip().lower()
    s = re.sub(r"[&+]", " and ", s)
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def clean_group_label(value):
    """Return a real cracker/crew label, or ``""`` for XLS placeholders."""
    label = str(value or "").strip()
    if not label:
        return ""
    normalized = normalize_group_label(label)
    if not normalized or normalized in PLACEHOLDER_GROUPS:
        return ""
    return label


def clean_gameinfo_variants(games):
    """Normalize placeholder labels in-place for every XLS variant."""
    for game in games or []:
        for variant in game.get("variants") or []:
            if "cracked_by" in variant:
                variant["cracked_by"] = clean_group_label(
                    variant.get("cracked_by"))
            if "crew" in variant:
                variant["crew"] = clean_group_label(variant.get("crew"))
    return games


def log(msg):
    print(msg, flush=True)


def load_config():
    cfg = dict(DEFAULTS)
    for name in ("config.example.json", "config.local.json"):
        p = BASE_DIR / name
        if p.is_file():
            try:
                with open(p, encoding="utf-8") as f:
                    data = json.load(f)
                for key in DEFAULTS:
                    if key in data:
                        cfg[key] = data[key]
            except Exception as exc:  # noqa: BLE001 - config is best effort
                log(f"[warn] config {name}: {exc}")
    return cfg


def extract_year(release):
    if not release:
        return ""
    m = YEAR_RE.search(str(release))
    return m.group(0) if m else ""


def _rel_dir(rel):
    return rel.rsplit("/", 1)[0] if "/" in rel else ""


def _full_png(rel, name):
    if not name:
        return None
    return f"{_rel_dir(rel)}/{name}" if _rel_dir(rel) else name


def _section_tree(entries):
    for rel in entries:
        parts = rel.split("/")
        if len(parts) >= 4:
            return "/".join(parts[:2])
    return ""


def _variant_rank(variant):
    if variant.get("status") == "done" and variant.get("kind") == "game":
        return 0
    if variant.get("status") == "done":
        return 1
    if variant.get("status") == "desktop":
        return 2
    return 3


def _empty_local_assets():
    return {
        "boxscans": {
            "edition_count": 0,
            "image_count": 0,
            "editions": [],
        },
        "manuals": {
            "title_count": 0,
            "file_count": 0,
            "items": [],
        },
    }


def _safe_rel(rel):
    raw = (rel or "").replace("\\", "/")
    if not raw or raw.startswith("/") or re.match(r"^[A-Za-z]:", raw):
        return ""
    parts = [p for p in raw.split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts):
        return ""
    return "/".join(parts)


def _real_dir(path):
    if not path:
        return ""
    try:
        if not os.path.isdir(path):
            return ""
        return os.path.realpath(path)
    except OSError:
        return ""


def _is_within(base, path):
    return path == base or path.startswith(base + os.sep)


def _resolve_child_dir(parent, name):
    if not name or name in (".", ".."):
        return ""
    exact = os.path.join(parent, name)
    try:
        if os.path.isdir(exact) and not os.path.islink(exact):
            real = os.path.realpath(exact)
            return real if _is_within(os.path.realpath(parent), real) else ""
        with os.scandir(parent) as it:
            entries = sorted(it, key=lambda e: e.name.casefold())
    except OSError:
        return ""
    wanted = name.casefold()
    for entry in entries:
        if entry.name.casefold() != wanted:
            continue
        try:
            if entry.is_dir(follow_symlinks=False):
                real = os.path.realpath(entry.path)
                return real if _is_within(os.path.realpath(parent), real) else ""
        except OSError:
            continue
    return ""


def _resolve_game_dir(base, folder_rel):
    base_real = os.path.realpath(base)
    current = base_real
    for part in folder_rel.split("/"):
        current = _resolve_child_dir(current, part)
        if not current:
            return ""
    return current if _is_within(base_real, current) else ""


def _walk_files(base, rel=""):
    try:
        with os.scandir(base) as it:
            entries = sorted(it, key=lambda e: e.name.casefold())
    except OSError:
        return
    for entry in entries:
        if entry.name.startswith(".") or entry.name.casefold() == "@eadir":
            continue
        child_rel = f"{rel}/{entry.name}" if rel else entry.name
        try:
            if entry.is_dir(follow_symlinks=False):
                yield from _walk_files(entry.path, child_rel)
            elif entry.is_file(follow_symlinks=False):
                yield child_rel, entry.path
        except OSError:
            continue


def _find_asset_dirs(game_dir):
    try:
        with os.scandir(game_dir) as it:
            entries = sorted(it, key=lambda e: e.name.casefold())
    except OSError:
        return []
    out = []
    for entry in entries:
        try:
            if not entry.is_dir(follow_symlinks=False):
                continue
        except OSError:
            continue
        name = entry.name.casefold()
        if name in BOXSCAN_DIR_NAMES:
            out.append((True, entry.path))
        elif name in MANUAL_DIR_NAMES:
            out.append((False, entry.path))
    return out


def _zip_infos(path):
    out = []
    try:
        with zipfile.ZipFile(path) as zf:
            for info in zf.infolist():
                out.append(info)
                if len(out) >= MAX_ZIP_ENTRIES:
                    break
    except (OSError, zipfile.BadZipFile):
        return []
    return out


def _zip_basename(info):
    if info.is_dir():
        return ""
    name = info.filename.replace("\\", "/")
    return name.rsplit("/", 1)[-1] if name else ""


def _stem_parts(name):
    stem = os.path.splitext(os.path.basename(name))[0]
    text = stem.casefold().endswith("_text")
    return (stem[:-5] if text else stem), text


def _add_manual_variant(group, ext, text_variant):
    if ext == ".pdf":
        label = "Text" if text_variant else "Scan"
        kind, fmt = "pdf", "PDF"
    elif ext in (".doc", ".txt"):
        label = "Text" if text_variant else "Document"
        kind, fmt = "document", ext[1:].upper()
    elif ext in MANUAL_IMAGE_EXTS:
        label = "Image pages"
        kind, fmt = "imagePages", "JPG" if ext in (".jpg", ".jpeg") else ext[1:].upper()
        text_variant = False
    elif ext == ".msa":
        label = "Original disk"
        kind, fmt = "diskImage", "MSA"
        text_variant = False
    else:
        return
    key = (label, kind)
    variant = group["variants"].get(key)
    if variant is None:
        variant = {"label": label, "kind": kind, "format": fmt, "file_count": 0}
        group["variants"][key] = variant
    else:
        variant["format"] = "/".join(sorted(
            set(variant["format"].split("/")) | {fmt}))
    variant["file_count"] += 1


def _discover_local_assets(root_dir, patch_dir, folder_rel):
    box_loose = {}
    box_zips = {}
    manual_sources = {}
    for base in (root_dir, patch_dir):
        if not base:
            continue
        game_dir = _resolve_game_dir(base, folder_rel)
        if not game_dir:
            continue
        for is_box, asset_dir in _find_asset_dirs(game_dir):
            prefix = "box" if is_box else "manual"
            for rel, path in _walk_files(asset_dir):
                key = f"{prefix}/{rel.casefold()}"
                ext = os.path.splitext(path)[1].lower()
                if is_box:
                    if ext in BOX_IMAGE_EXTS:
                        edition = rel.split("/")[0] if "/" in rel else "Boxscan"
                        box_loose[key] = {
                            "name": os.path.basename(path),
                            "edition": edition,
                        }
                    elif ext == ".zip":
                        box_zips[key] = {
                            "path": path,
                            "label": os.path.splitext(os.path.basename(path))[0],
                        }
                elif ext == ".zip":
                    stem, text = _stem_parts(path)
                    manual_sources[key] = {
                        "kind": "zip",
                        "path": path,
                        "stem": stem,
                        "text": text,
                    }
                elif ext in MANUAL_DOC_EXTS or ext in MANUAL_IMAGE_EXTS:
                    stem, text = _stem_parts(path)
                    manual_sources[key] = {
                        "kind": "loose",
                        "path": path,
                        "stem": stem,
                        "text": text,
                        "name": os.path.basename(path),
                    }

    editions = {}

    def add_edition(label, name):
        key = label.casefold()
        edition = editions.get(key)
        if edition is None:
            edition = {"label": label, "images": set()}
            editions[key] = edition
        edition["images"].add(name.casefold())

    for image in box_loose.values():
        add_edition(image["edition"], image["name"])
    for source in box_zips.values():
        for info in _zip_infos(source["path"]):
            name = _zip_basename(info)
            ext = os.path.splitext(name)[1].lower()
            if name and ext in BOX_IMAGE_EXTS:
                add_edition(source["label"], name)
    box_editions = [
        {"label": edition["label"], "image_count": len(edition["images"])}
        for edition in sorted(editions.values(),
                              key=lambda e: e["label"].casefold())
        if edition["images"]
    ]

    groups = {}
    for source in manual_sources.values():
        key = source["stem"].casefold()
        group = groups.setdefault(key, {
            "label": source["stem"],
            "variants": {},
        })
        if source["kind"] == "zip":
            for info in _zip_infos(source["path"]):
                name = _zip_basename(info)
                if not name:
                    continue
                ext = os.path.splitext(name)[1].lower()
                _add_manual_variant(group, ext, source["text"])
        else:
            ext = os.path.splitext(source["name"])[1].lower()
            _add_manual_variant(group, ext, source["text"])

    manual_items = []
    for group in groups.values():
        variants = sorted(group["variants"].values(),
                          key=lambda v: (v["label"].casefold(), v["format"]))
        if not variants:
            continue
        manual_items.append({
            "label": group["label"],
            "variants": variants,
        })
    manual_items.sort(key=lambda item: item["label"].casefold())

    return {
        "boxscans": {
            "edition_count": len(box_editions),
            "image_count": sum(e["image_count"] for e in box_editions),
            "editions": box_editions,
        },
        "manuals": {
            "title_count": len(manual_items),
            "file_count": sum(
                sum(v["file_count"] for v in item["variants"])
                for item in manual_items),
            "items": manual_items,
        },
    }


class LocalAssetsService:
    def __init__(self, root_dir, patch_dir, cache_seconds=60):
        self.root_dir = _real_dir(root_dir)
        self.patch_dir = _real_dir(patch_dir)
        self.enabled = bool(self.root_dir)
        try:
            self.cache_seconds = max(0, int(cache_seconds))
        except (TypeError, ValueError):
            self.cache_seconds = 60
        self._cache = {}
        self._lock = threading.Lock()

    def discover(self, folder_rel):
        if not self.enabled:
            return _empty_local_assets()
        rel = _safe_rel(folder_rel)
        if not rel:
            return _empty_local_assets()
        now = time.monotonic()
        with self._lock:
            cached = self._cache.get(rel)
            if (cached is not None and self.cache_seconds > 0
                    and now - cached[0] < self.cache_seconds):
                return cached[1]
        result = _discover_local_assets(
            self.root_dir, self.patch_dir, rel)
        with self._lock:
            self._cache[rel] = (now, result)
        return result


def _variant_info_summary(info):
    """Flatten first XLS variant + count for hover/lightbox header."""
    if not info:
        return None
    variants = info.get("variants") or []
    v0 = variants[0] if variants else {}
    out = {
        "title": v0.get("title") or info.get("matched_title") or info.get("folder", ""),
        "publisher": v0.get("publisher", ""),
        "cracked_by": v0.get("cracked_by", ""),
        "crew": v0.get("crew", ""),
        "intro_code": v0.get("intro_code", ""),
        "language": v0.get("language", ""),
        "disks": v0.get("disks"),
        "raw_dump": v0.get("raw_dump", False),
        "pasti_dump": v0.get("pasti_dump", False),
        "boxscan": v0.get("boxscan", False),
        "release": v0.get("release", ""),
        "tos_bad": v0.get("tos_bad", ""),
        "special_flag": v0.get("special_flag", ""),
        "special_note": v0.get("special_note", ""),
        "version": v0.get("version", ""),
        "company": v0.get("company", ""),
        "licence": v0.get("licence", ""),
        "add_info": v0.get("add_info", ""),
        "cracktro": v0.get("cracktro", ""),
        "screen_format": v0.get("screen_format", ""),
        "variants": variants,
    }
    return out


def _info_search_text(info):
    if not info:
        return ""
    parts = [info.get("folder", ""), info.get("matched_title", "")]
    for v in info.get("variants") or []:
        parts.extend(str(v.get(k, "")) for k in v)
    return " ".join(parts).lower()


# --- magazine cover disks (filename-derived cards) -----------------------
#
# The magazine scope (`Bonus/Magazine Cover Disks`) has no metadata at all;
# every bit of information lives in the file name. One card = one magazine
# issue: multiple disks and ` (2)` copies become variants. The parser is
# mirrored in `packages/marcer_catalog/lib/src/magazine.dart`.

_MAGAZINE_SUFFIXES = (" - 2 missings", " - 4 missings", " - Complete")


def _magazine_name(letter):
    """Clean magazine folder name (`ST Action - 2 missings` -> `ST Action`)."""
    name = letter
    for suffix in _MAGAZINE_SUFFIXES:
        if name.endswith(suffix):
            name = name[: -len(suffix)]
    return name


def _magazine_key(letter, stem):
    """Return ``(folder_key, display_name, year)`` for one magazine ZIP.

    The stem is the file name without `.zip`; a trailing ` (2)`/` (3)`
    duplicate marker is ignored so copies group with the original issue.
    """
    mag = _magazine_name(letter)
    s = re.sub(r"\s*\(\d+\)\s*$", "", stem)
    ym = re.search(r"\b(19|20)\d{2}\b", s)
    year = ym.group(0) if ym else ""
    if mag == "ST Action":
        m = re.match(r"st action\s+(\d+)", s, re.I)
        if m:
            return m.group(1), f"ST Action {m.group(1)}", ""
    elif mag == "Start Micro":
        m = re.match(r"start\s*micro\s*(\d+)", s, re.I)
        if m:
            date = re.search(r"\((\d{4})-(\d{2})\)", s)
            return (m.group(1), f"Start Micro {m.group(1)}",
                    date.group(1) if date else "")
    elif mag == "ST Computer":
        m = re.match(r"(\d{4})[_-](\d{2}(?:-\d{2})?|s\d|p\d)", s, re.I)
        if m:
            label = f"{m.group(1)}-{m.group(2).upper()}"
            return m.group(0).lower(), f"ST Computer {label}", m.group(1)
    elif mag in ("The One", "Zero"):
        m = re.search(r"issue\s*(\d+)", s, re.I)
        if m:
            return m.group(1), f"{mag} Issue {m.group(1)}", year
    return s.lower(), s, year


def _group_key(rel, kind):
    """Return ``(letter, folder, display_name, year)`` for one index entry."""
    parts = rel.split("/")
    letter = parts[2] if len(parts) > 2 else ""
    if kind == "magazine":
        stem = (Path(parts[3]).stem if len(parts) > 3
                else Path(parts[-1]).stem)
        folder, display, year = _magazine_key(letter, stem)
        return letter, folder, display, year
    folder = parts[3] if len(parts) > 3 else Path(parts[-1]).stem
    return letter, folder, folder, ""


def _build_indexed_cards(entries, games, kind, union_gameinfo,
                         section_tree=""):
    """Group index entries by (letter, folder) into cards joined with gameinfo.

    With ``union_gameinfo`` (pd/utils) gameinfo-only folders without an index
    entry are appended as metadata-only cards (placeholder, no screenshots);
    cracked stays index-only (desktop-app parity, per-section indices).
    Magazine cards are grouped per issue with a filename-derived name/year.
    """
    info_by_key = {(g.get("letter", ""), g.get("folder", "")): g
                   for g in games}
    groups = {}
    for rel, e in entries.items():
        letter, folder, display, year = _group_key(rel, kind)
        group = groups.setdefault(
            (letter, folder), {"items": [], "display": display, "year": year})
        group["items"].append((rel, e))

    cards = []
    seen = set()
    for (letter, folder), group in groups.items():
        items = group["items"]
        # ZIPs directly in the game folder before ZIPs from subfolders
        # (`Original/`, `STX/`, …), then sorted rel — desktop parity
        # (`compareVariantRel` in marcer_catalog/lib/src/card.dart).
        items.sort(key=lambda t: (t[0].count("/"), t[0]))
        variants = []
        scounts = {}
        layers = set()
        for rel, e in items:
            st = e.get("status") or "unknown"
            scounts[st] = scounts.get(st, 0) + 1
            if e.get("layer"):
                layers.add(e["layer"])
            variants.append({
                "rel": rel,
                "name": e.get("name") or rel.rsplit("/", 1)[-1],
                "status": st,
                "kind": e.get("kind") or "",
                "layer": e.get("layer") or "",
                "preview": _full_png(rel, e.get("preview")),
                "candidates": [_full_png(rel, c)
                               for c in (e.get("candidates") or [])],
                "size": e.get("size"),
                # non-default TOS version the screenshot generator needed
                # (e.g. "1.02"); absent/null = default TOS
                # (SPEC-screenshot-generator §7.5)
                "tos": e.get("tos"),
            })
        display_status = next((s for s in STATUS_ORDER if scounts.get(s)),
                              "pending")
        # among done variants prefer a real game shot (e.g. over a
        # textscreen); within a tier the sorted-rel order decides
        # (desktop app `card.dart:331-374`, SPEC 4.4)
        preview = next((v["preview"] for v in variants
                        if v["status"] == "done" and v["kind"] == "game"
                        and v["preview"]), None)
        if preview is None:
            preview = next((v["preview"] for v in variants
                            if v["status"] == "done" and v["preview"]), None)
        if preview is None:
            preview = next((v["preview"] for v in variants
                            if v["status"] == "desktop" and v["preview"]),
                           None)
        # Fallback for entries whose only preview is not done/desktop, e.g.
        # a `no_usable_shots` entry that keeps its last capture (SPEC §8.5).
        if preview is None:
            preview = next((v["preview"] for v in variants if v["preview"]),
                           None)
        layer = next(iter(layers)) if len(layers) == 1 else "BOTH"
        info = info_by_key.get((letter, folder))
        first_rel = items[0][0]
        parts = first_rel.split("/")
        tree = ("/".join(parts[:2]) if len(parts) >= 4
                else (section_tree or CANONICAL_SECTION_TREES.get(kind, "")))
        if kind == "magazine":
            # Magazine cards group one issue below
            # `<tree>/<magazine>/<issue>`; a ZIP directly in the magazine
            # folder sits at index 3, a nested one in the issue directory
            # below it — never use the first ZIP's immediate parent (desktop
            # `cardFolderRel`).
            folder_rel = "/".join(parts[:4] if len(parts) >= 5 else parts[:3])
        else:
            folder_rel = (f"{tree}/{letter}/{folder}" if tree
                          else _rel_dir(first_rel))
        card = {
            "id": f"{letter}/{folder}",
            "name": group["display"] or folder,
            "letter": letter,
            "folder": folder,
            "_folder_rel": folder_rel,
            "display_status": display_status,
            "screenshots": preview is not None,
            "status_counts": scounts,
            "layer": layer,
            "year": group["year"],
            "preview": preview,
            "variants": variants,
            "info": _variant_info_summary(info),
        }
        _finalize_card(card, kind=kind)
        if kind == "magazine" and group["year"]:
            # _finalize_card derives the year from gameinfo only; magazine
            # years come from the file name.
            card["year"] = group["year"]
            card["_year_num"] = int(group["year"])
        cards.append(card)
        seen.add((letter.lower(), folder.lower()))

    if union_gameinfo:
        for g in games:
            key = (g.get("letter", "").lower(),
                   g.get("folder", "").lower())
            if key in seen:
                continue
            cards.append(_simple_card(g, kind, section_tree))
    return cards


def _simple_card(g, kind, section_tree=""):
    letter = g.get("letter", "")
    folder = g.get("folder", "")
    layers = g.get("layers") or []
    layer = "BOTH" if len(layers) > 1 else (layers[0] if layers else "")
    tree = section_tree or CANONICAL_SECTION_TREES.get(kind, "")
    folder_rel = f"{tree}/{letter}/{folder}" if tree and letter and folder else ""
    card = {
        "id": f"{letter}/{folder}",
        "name": folder,
        "letter": letter,
        "folder": folder,
        "_folder_rel": folder_rel,
        "display_status": "",
        "screenshots": False,
        "status_counts": {},
        "layer": layer,
        "year": "",
        "preview": None,
        "variants": [],
        "info": _variant_info_summary(g),
    }
    _finalize_card(card, kind=kind)
    return card


def _finalize_card(card, kind):
    info = card.get("info")
    years = []
    pubs, crews, crackers, langs = [], [], [], []
    raws, pastis, boxes, tos_notes = [], [], [], []
    if info:
        for v in info.get("variants") or []:
            y = extract_year(v.get("release"))
            if y:
                years.append(int(y))
            for bucket, key in ((pubs, "publisher"), (crews, "crew"),
                                (crackers, "cracked_by"),
                                (langs, "language")):
                val = (v.get(key) or "").strip()
                if val:
                    bucket.append(val)
            if kind == "cracked":
                raws.append(bool(v.get("raw_dump")))
                pastis.append(bool(v.get("pasti_dump")))
                boxes.append(bool(v.get("boxscan")))
            elif kind == "utils":
                raws.append(bool(v.get("raw_dump")))
            if (v.get("tos_bad") or "").strip():
                tos_notes.append(True)
    card["year"] = str(min(years)) if years else "unknown"
    card["_year_num"] = min(years) if years else 0
    card["_publisher"] = sorted(set(pubs), key=str.lower)
    card["_crew"] = sorted(set(crews), key=str.lower)
    card["_cracker"] = sorted(set(crackers), key=str.lower)
    card["_language"] = sorted(set(langs), key=str.lower)
    card["_raw"] = any(raws) if raws else None
    card["_pasti"] = any(pastis) if pastis else None
    card["_boxscan"] = any(boxes) if boxes else None
    card["_tos"] = bool(tos_notes)
    card["_publisher_sort"] = min(pubs, key=str.lower) if pubs else ""
    card["_crew_sort"] = min(crews, key=str.lower) if crews else ""
    card["_cracker_sort"] = min(crackers, key=str.lower) if crackers else ""
    card["_language_sort"] = min(langs, key=str.lower) if langs else ""
    parts = [card["name"], card["letter"], card["folder"]]
    parts.extend(v["name"] for v in card["variants"])
    parts.extend(v["rel"] for v in card["variants"])
    parts.append(_info_search_text(info))
    card["_search"] = " ".join(str(p) for p in parts if p).lower()


def _facets(cards, kind):
    pubs, crews, crackers, langs, years, letters = (
        set(), set(), set(), set(), set(), set())
    for c in cards:
        if c["letter"]:
            letters.add(c["letter"])
        if c.get("year") and c["year"] != "unknown":
            years.add(c["year"])
        for v in (c.get("info") or {}).get("variants") or []:
            for bucket, key in ((pubs, "publisher"), (langs, "language")):
                val = (v.get(key) or "").strip()
                if val:
                    bucket.add(val)
            if "crew" in kind_fields(kind):
                val = (v.get("crew") or "").strip()
                if val:
                    crews.add(val)
            if "cracked_by" in kind_fields(kind):
                val = (v.get("cracked_by") or "").strip()
                if val:
                    crackers.add(val)
            y = extract_year(v.get("release"))
            if y:
                years.add(y)
    return {
        "publishers": sorted(pubs, key=str.lower),
        "crews": sorted(crews, key=str.lower),
        "crackers": sorted(crackers, key=str.lower),
        "languages": sorted(langs, key=str.lower),
        "years": sorted(years),
        "letters": sorted(letters, key=lambda s: (s != "0-9", s)),
    }


def kind_fields(kind):
    return {
        "cracked": {"publisher", "crew", "cracked_by", "language", "release",
                    "raw_dump", "pasti_dump", "boxscan", "tos_bad"},
        "pd": {"publisher", "language", "release", "tos_bad"},
        "utils": {"publisher", "crew", "cracked_by", "language", "release",
                  "raw_dump", "tos_bad"},
        "magazine": set(),
        "falcon": set(),
    }[kind]


def kind_filters(kind):
    """API filter names applicable to a section (SPEC 6.8)."""
    return {
        "cracked": {"publisher", "crew", "cracker", "language", "year",
                    "raw", "pasti", "boxscan", "tos"},
        "pd": {"publisher", "language", "year", "tos"},
        "utils": {"publisher", "crew", "cracker", "language", "year", "raw",
                  "tos"},
        "magazine": {"year"},
        "falcon": set(),
    }[kind]


_CREW_STOPWORDS = frozenset({"and", "the", "co", "crew", "inc", "ltd",
                             "team", "software"})


def _norm_crew(s):
    """Normalize a group string (crew/cracker) for fuzzy matching.

    Lowercases, expands `&` / `+` to "and" and collapses whitespace so
    that e.g. gameinfo "Equinox & MDK" matches ZIP "Equinox and MDK".
    """
    s = (s or "").strip().lower()
    s = re.sub(r"\s*[&+]\s*", " and ", s)
    return re.sub(r"\s+", " ", s).strip()


def _crew_tokens(s):
    """Tokenize a group string: alphanumeric, no stopwords, length >= 2."""
    raw = re.findall(r"[a-z0-9]+", (s or "").lower())
    return [t for t in raw if t not in _CREW_STOPWORDS and len(t) >= 2]


def _focus_variant(card, value, kind):
    """Index of the ZIP variant that belongs to `value`, or -1.

    `kind` is `"crew"` or `"cracker"`. Matching is tried in increasing
    fuzziness:
      1) normalized value is a substring of the normalized ZIP name
         (`&`/`+` == "and", e.g. "Equinox & MDK" -> "Equinox and MDK");
      2) (crew only) gameinfo variant with this crew -> its cracker name
         in ZIP names;
      3) token subset: all tokens (ignoring stopwords) appear in the ZIP
         name (typos / missing connective, e.g. "Hotline & MCA" ->
         "Hotline MCA"), requiring at least one token with length >= 3.
    Among multiple matches the first with a screenshot preview wins.
    """
    value_n = _norm_crew(value)
    if not value_n:
        return -1
    variants = card["variants"]
    # 1) normalized substring match
    subs = [i for i, v in enumerate(variants)
            if value_n in _norm_crew(v["name"])]
    if subs:
        return _first_with_preview(variants, subs)
    # 2) (crew only) gameinfo variant with this crew → its cracker in names
    if kind == "crew":
        for iv in (card.get("info") or {}).get("variants") or []:
            if _norm_crew(iv.get("crew")) != value_n:
                continue
            cracker = (iv.get("cracked_by") or "").strip().lower()
            if not cracker:
                continue
            hits = [i for i, v in enumerate(variants)
                    if cracker in v["name"].lower()]
            if hits:
                return _first_with_preview(variants, hits)
    # 3) token subset match (typo / missing connective tolerant)
    ct = _crew_tokens(value)
    if ct and any(len(t) >= 3 for t in ct):
        hits = []
        for i, v in enumerate(variants):
            nt = set(re.findall(r"[a-z0-9]+", v["name"].lower()))
            if all(t in nt for t in ct):
                hits.append(i)
        if hits:
            return _first_with_preview(variants, hits)
    return -1


def _first_with_preview(variants, indices):
    """Return the first index with a preview, otherwise the first."""
    for i in indices:
        if variants[i].get("preview"):
            return i
    return indices[0]


def _apply_focus(card, value, kind):
    """Return a shallow-adjusted view of `card` focused on the group variant.

    `kind` is `"crew"` or `"cracker"`. Does not mutate the stored card.
    Sets focus_variant / preview / display_status for the public payload.
    Empty previews are allowed (placeholder) — the card is always shown
    when the group matches.
    """
    focus = _focus_variant(card, value, kind)
    out = dict(card)
    out["focus_variant"] = focus
    if focus >= 0:
        v = card["variants"][focus]
        out["preview"] = v["preview"]
        out["display_status"] = v["status"]
        out["screenshots"] = v["preview"] is not None
    else:
        # crew known at gameinfo level but no ZIP identified → empty card
        out["preview"] = None
        out["screenshots"] = False
    return out


class DataStore:
    """In-memory index + metadata with mtime-based revalidation."""

    def __init__(self, out_dir, data_dir, root_dir="", patch_dir="",
                 assets_cache_seconds=60):
        self.out = Path(out_dir)
        sub = Path(data_dir) / GAMEINFO_SUBDIR if data_dir else None
        self.data = sub if sub and sub.is_dir() else None
        self.lock = threading.Lock()
        self._mtimes = {}
        self.meta = {}
        self.cards = {sec: [] for sec in SECTION_INDEX_NAMES}
        self.facets = {}
        self.gameinfo_available = False
        self.kinds_loaded = set()
        self.manifest = {}
        self.crews = []
        self.crew_groups = {}
        self.crew_generated_at = ""
        self.crew_error = None
        self._crew_total_groups = 0
        self._crew_visible_groups = 0
        self._crew_release_count = 0
        self._crew_images = {}
        self._release_lookup = {}
        self._release_labels = {}
        self._cracked_tree = ""
        self.assets = LocalAssetsService(
            root_dir, patch_dir, assets_cache_seconds)
        self.reload(force=True)

    def _stamps(self):
        stamps = {}
        for sec, name in SECTION_INDEX_NAMES.items():
            try:
                stamps[f"index_{sec}"] = os.path.getmtime(self.out / name)
            except OSError:
                stamps[f"index_{sec}"] = None
        if self.data:
            for kind in ("cracked", "pd", "utils"):
                try:
                    stamps[f"info_{kind}"] = os.path.getmtime(
                        self.data / f"games-{kind}.json")
                except OSError:
                    stamps[f"info_{kind}"] = None
            try:
                stamps["manifest"] = os.path.getmtime(
                    self.data / "manifest.json")
            except OSError:
                stamps["manifest"] = None
            for name in (CREW_FILE, CREW_IMAGES_FILE):
                try:
                    stamps[f"crew_{name}"] = os.path.getmtime(
                        self.data / name)
                except OSError:
                    stamps[f"crew_{name}"] = None
        return stamps

    def check_changed(self):
        return self._stamps() != self._mtimes

    def reload(self, force=False):
        if not force and not self.check_changed():
            return False
        with self.lock:
            if not force and self._stamps() == self._mtimes \
                    and self.meta.get("sections") \
                    and self.meta.get("index", {}).get("cracked", {}) \
                    .get("entries"):
                return False
            t0 = time.monotonic()
            self._load()
            log(f"[data] (re)loaded in {time.monotonic() - t0:.2f}s "
                f"({self.meta.get('index', {}).get('cracked', {}).get('entries')}"
                f" index entries, {len(self.cards['cracked'])} cracked cards)")
        return True

    def _load(self):
        self._mtimes = self._stamps()
        entries = {}
        for sec, name in SECTION_INDEX_NAMES.items():
            entries[sec] = {}
            p = self.out / name
            if p.is_file():
                try:
                    with open(p, encoding="utf-8") as f:
                        entries[sec] = json.load(f).get("entries", {})
                except Exception as exc:  # noqa: BLE001
                    log(f"[warn] {name}: {exc}")

        games = {"cracked": [], "pd": [], "utils": []}
        self.kinds_loaded = set()
        self.gameinfo_available = False
        self.manifest = {}
        if self.data and self.data.is_dir():
            for kind in ("cracked", "pd", "utils"):
                p = self.data / f"games-{kind}.json"
                try:
                    with open(p, encoding="utf-8") as f:
                        games[kind] = clean_gameinfo_variants(
                            json.load(f).get("games", []))
                    self.kinds_loaded.add(kind)
                except Exception as exc:  # noqa: BLE001
                    log(f"[warn] {p.name}: {exc}")
            self.gameinfo_available = bool(self.kinds_loaded)
            try:
                with open(self.data / "manifest.json", encoding="utf-8") as f:
                    self.manifest = json.load(f)
            except Exception as exc:  # noqa: BLE001
                log(f"[warn] manifest.json: {exc}")
                self.manifest = {}

        section_trees = {
            sec: (_section_tree(entries[sec])
                  or CANONICAL_SECTION_TREES.get(sec, ""))
            for sec in SECTION_INDEX_NAMES
        }
        self.cards["cracked"] = _build_indexed_cards(
            entries["cracked"],
            games["cracked"] if "cracked" in self.kinds_loaded else [],
            "cracked", union_gameinfo=False,
            section_tree=section_trees["cracked"])
        self.cards["pd"] = _build_indexed_cards(
            entries["pd"],
            games["pd"] if "pd" in self.kinds_loaded else [],
            "pd", union_gameinfo=True,
            section_tree=section_trees["pd"])
        self.cards["utils"] = _build_indexed_cards(
            entries["utils"],
            games["utils"] if "utils" in self.kinds_loaded else [],
            "utils", union_gameinfo=True,
            section_tree=section_trees["utils"])
        self.cards["magazine"] = _build_indexed_cards(
            entries["magazine"], [], "magazine", union_gameinfo=False,
            section_tree=section_trees["magazine"])
        self.cards["falcon"] = _build_indexed_cards(
            entries["falcon"], [], "falcon", union_gameinfo=False,
            section_tree=section_trees["falcon"])
        self.facets = {kind: _facets(self.cards[kind], kind)
                       for kind in SECTION_INDEX_NAMES}
        self._cracked_tree = section_trees.get("cracked", "")
        self._load_crews()
        self._attach_release_labels()

        coverage = {}
        for src in self.manifest.get("sources") or []:
            if src.get("kind") == "cracked":
                coverage = {
                    "matched_folders": src.get("matched_folders"),
                    "unmatched_folders": src.get("unmatched_folders"),
                }

        def zip_counts(sec):
            counts = {}
            for e in entries[sec].values():
                s = e.get("status") or "unknown"
                counts[s] = counts.get(s, 0) + 1
            counts["desktop_any"] = counts.get("desktop", 0)
            counts["no_usable_shots_any"] = counts.get("no_usable_shots", 0)
            return counts

        # per-status CARD (game) counts for the statistics bar — the ZIP
        # level counts stay in `status_counts`. `pending` uses the
        # any-variant rule of `_matches` so the bar segment equals the
        # pending dropdown result count (desktop `statusLine`).
        def game_counts(sec):
            counts = {s: 0 for s in STATUS_ORDER}
            cards = self.cards[sec]
            for c in cards:
                ds = c["display_status"]
                if ds in counts:
                    counts[ds] += 1
            counts["pending"] = sum(
                1 for c in cards
                if any(v["status"] == "pending" for v in c["variants"]))
            counts["interrupted"] = sum(
                1 for c in cards
                if any(v["status"] == "interrupted" for v in c["variants"]))
            counts["skipped_disk_n"] = sum(
                1 for c in cards
                if any(v["status"] == "skipped_disk_n" for v in c["variants"]))
            counts["desktop_any"] = sum(
                1 for c in cards
                if any(v["status"] == "desktop" for v in c["variants"]))
            counts["no_usable_shots_any"] = sum(
                1 for c in cards
                if any(v["status"] == "no_usable_shots" for v in c["variants"]))
            return counts

        self.meta = {
            "gameinfo": self.gameinfo_available,
            "index": {
                sec: {
                    "entries": len(entries[sec]),
                    "mtime": self._mtimes.get(f"index_{sec}"),
                }
                for sec in SECTION_INDEX_NAMES
            },
            "status_counts": {sec: zip_counts(sec)
                              for sec in SECTION_INDEX_NAMES},
            "game_status_counts": {sec: game_counts(sec)
                                   for sec in SECTION_INDEX_NAMES},
            "sections": {
                sec: {
                    "games": len(games.get(sec, [])),
                    "cards": len(self.cards[sec]),
                    "with_screenshot": sum(
                        1 for c in self.cards[sec] if c["screenshots"]),
                    "no_info": sum(
                        1 for c in self.cards[sec] if not c["info"]),
                }
                for sec in SECTION_INDEX_NAMES
            },
            "coverage": coverage,
            "facets": self.facets,
            "generated_at": self.manifest.get("generated_at"),
            "tool_version": TOOL_VERSION,
            "local_assets": self.assets.enabled,
        }
        self.meta["sections"]["crew"] = {
            "games": 0,
            "cards": len(self.crews),
            "with_screenshot": sum(1 for c in self.crews if c["preview"]),
            "no_info": 0,
        }
        self.meta["crews"] = {
            "available": bool(self.crews),
            "groups": len(self.crews),
            "visible_groups": self._crew_visible_groups,
            "total_groups": self._crew_total_groups,
            "kinds": crew_kind_counts(self.crews),
            "releases": self._crew_release_count,
            "generated_at": self.crew_generated_at,
            "error": self.crew_error,
        }

    def _load_crews(self):
        self.crews = []
        self.crew_groups = {}
        self.crew_generated_at = ""
        self.crew_error = None
        self._crew_total_groups = 0
        self._crew_visible_groups = 0
        self._crew_release_count = 0
        self._crew_images = {}
        self._release_lookup = {}
        self._release_labels = {}
        if not self.data:
            self.crew_error = "gameinfo unavailable"
            return
        path = self.data / CREW_FILE
        if not path.is_file():
            self.crew_error = f"{CREW_FILE} not found"
            return
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except Exception as exc:  # noqa: BLE001
            self.crew_error = f"{CREW_FILE}: {exc}"
            return
        raw_groups = data.get("groups") or []
        if not isinstance(raw_groups, list):
            raw_groups = []
        self._crew_total_groups = len(raw_groups)
        groups = [g for g in raw_groups if isinstance(g, dict)]
        groups.sort(key=lambda g: (
            -int(g.get("zips") or 0),
            str(g.get("name") or "").lower(),
        ))
        self._load_crew_images()
        self._release_lookup = {}
        self._release_labels = {}
        for card in self.cards["cracked"]:
            for index, variant in enumerate(card["variants"]):
                self._release_lookup[variant["rel"]] = (card, index)
        for group in groups:
            group_id = str(group.get("id") or "").strip()
            name = str(group.get("name") or "").strip()
            if not group_id or not name or group_id in self.crew_groups:
                continue
            releases = [
                r for r in (group.get("releases") or [])
                if isinstance(r, dict) and str(r.get("rel") or "").strip()
            ]
            for release in releases:
                release["cracked_by"] = clean_group_label(
                    release.get("cracked_by"))
                release["crew"] = clean_group_label(release.get("crew"))
                if not isinstance(release.get("inferred_fields"), list):
                    release.pop("inferred_fields", None)
            normalized = dict(group)
            normalized["id"] = group_id
            normalized["name"] = name
            normalized["releases"] = releases
            preview = self._crew_preview(normalized)
            summary = {
                "id": group_id,
                "name": name,
                "kind": str(group.get("kind") or "crew"),
                "rank": int(group.get("rank") or 0),
                "zips": int(group.get("zips") or 0),
                "releases": len(releases),
                "aliases": self._crew_aliases(group),
                "preview": preview,
                "top": not bool(group.get("excluded")),
                "crew": True,
                "_search": self._crew_search_text(normalized),
            }
            self.crew_groups[group_id] = normalized
            self.crews.append(summary)
        self.crew_generated_at = str(data.get("generated_at") or "")
        self._crew_visible_groups = len(self.crew_groups)
        self._crew_release_count = sum(
            len(g.get("releases") or []) for g in self.crew_groups.values())
        for group in self.crew_groups.values():
            for release in group.get("releases") or []:
                rel = str(release.get("rel") or "").replace("\\", "/")
                if not rel:
                    continue
                label = {
                    "cracked_by": str(release.get("cracked_by") or ""),
                    "crew": str(release.get("crew") or ""),
                    "inferred_fields": list(
                        release.get("inferred_fields") or []),
                }
                keys = {rel}
                if self._cracked_tree:
                    prefix = self._cracked_tree + "/"
                    keys.add(rel[len(prefix):] if rel.startswith(prefix)
                             else prefix + rel)
                for key in keys:
                    self._release_labels[key] = label

    def _attach_release_labels(self):
        """Attach inferred release labels (from crews.json) to cracked cards."""
        for card in self.cards["cracked"]:
            labels = {}
            for variant in card.get("variants") or []:
                entry = self._release_labels.get(variant.get("rel"))
                if entry:
                    labels[variant["rel"]] = entry
            if labels:
                card["release_labels"] = labels
            else:
                card.pop("release_labels", None)

    def _load_crew_images(self):
        self._crew_images = {}
        if not self.data:
            return
        path = self.data / CREW_IMAGES_FILE
        if not path.is_file():
            return
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except Exception as exc:  # noqa: BLE001
            log(f"[warn] {CREW_IMAGES_FILE}: {exc}")
            return
        images = data.get("images") or {}
        if not isinstance(images, dict):
            return
        for key, value in images.items():
            if isinstance(value, dict):
                self._crew_images[str(key).strip().lower()] = value

    @staticmethod
    def _crew_aliases(group):
        aliases = group.get("aliases") or []
        if not isinstance(aliases, list):
            return []
        return [str(a).strip() for a in aliases if str(a).strip()]

    @staticmethod
    def _crew_search_text(group):
        parts = [str(group.get("name") or ""), str(group.get("kind") or "")]
        aliases = group.get("aliases") or []
        if isinstance(aliases, list):
            parts.extend(str(a) for a in aliases)
        for release in group.get("releases") or []:
            if not isinstance(release, dict):
                continue
            for key in ("title", "folder", "zip", "year", "publisher",
                        "cracked_by", "crew"):
                value = release.get(key)
                if value:
                    parts.append(str(value))
        return " ".join(p for p in parts if p).lower()

    def _crew_image_for(self, group):
        name = str(group.get("name") or "").strip().lower()
        group_id = str(group.get("id") or "").strip().lower()
        return self._crew_images.get(name) or self._crew_images.get(group_id)

    def _crew_image_path(self, image):
        rel = str(image.get("rel") or "").strip()
        name = str(image.get("name") or "").strip()
        if not rel or not name:
            return None
        rels = [rel]
        if self._cracked_tree and not rel.startswith(self._cracked_tree + "/"):
            rels.append(f"{self._cracked_tree}/{rel}")
        for candidate in rels:
            safe = _safe_rel(candidate)
            if not safe:
                continue
            path = _full_png(safe, name)
            if not path or ".." in path.split("/"):
                continue
            if (self.out / path).is_file():
                return path
        return None

    def _resolve_release(self, rel):
        rel = str(rel or "").replace("\\", "/")
        if not rel:
            return "", None
        hit = self._release_lookup.get(rel)
        if hit is not None:
            return rel, hit
        if self._cracked_tree and not rel.startswith(self._cracked_tree + "/"):
            full = f"{self._cracked_tree}/{rel}"
            hit = self._release_lookup.get(full)
            if hit is not None:
                return full, hit
        return rel, None

    def _crew_preview(self, group):
        image = self._crew_image_for(group)
        if image:
            path = self._crew_image_path(image)
            if path:
                return path
        best = None
        best_rank = 99
        for release in group.get("releases") or []:
            _, hit = self._resolve_release(release.get("rel"))
            if hit is None:
                continue
            card, index = hit
            variant = card["variants"][index]
            preview = variant.get("preview")
            if not preview:
                continue
            rank = _variant_rank(variant)
            if rank < best_rank:
                best = preview
                best_rank = rank
                if rank == 0:
                    break
        return best

    def crew_detail(self, group):
        out = {
            "id": group["id"],
            "name": group["name"],
            "kind": str(group.get("kind") or "crew"),
            "rank": int(group.get("rank") or 0),
            "zips": int(group.get("zips") or 0),
            "aliases": self._crew_aliases(group),
            "generated_at": self.crew_generated_at,
            "releases": [],
        }
        for release in group.get("releases") or []:
            item = {
                "rel": str(release.get("rel") or ""),
                "zip": str(release.get("zip") or ""),
                "title": str(release.get("title") or ""),
                "year": str(release.get("year") or ""),
                "publisher": str(release.get("publisher") or ""),
                "cracked_by": str(release.get("cracked_by") or ""),
                "crew": str(release.get("crew") or ""),
                "inferred_fields": list(
                    release.get("inferred_fields") or []),
                "language": str(release.get("language") or ""),
                "disks": int(release.get("disks") or 0),
                "raw_dump": release.get("raw_dump") is True,
                "pasti_dump": release.get("pasti_dump") is True,
                "boxscan": release.get("boxscan") is True,
                "tos_bad": str(release.get("tos_bad") or ""),
                "special_flag": str(release.get("special_flag") or ""),
                "special_note": str(release.get("special_note") or ""),
                "source": str(release.get("source") or ""),
                "ambiguous": release.get("ambiguous") is True,
            }
            index_rel, hit = self._resolve_release(item["rel"])
            item["index_rel"] = index_rel or item["rel"]
            item["found"] = hit is not None
            if hit is None:
                item.update({
                    "preview": None,
                    "status": "",
                    "kind": "",
                    "layer": "",
                    "size": None,
                })
            else:
                card, index = hit
                variant = card["variants"][index]
                item.update({
                    "preview": variant.get("preview"),
                    "status": variant.get("status") or "",
                    "kind": variant.get("kind") or "",
                    "layer": variant.get("layer") or "",
                    "size": variant.get("size"),
                })
            out["releases"].append(item)
        return out

    def assets_for_card(self, card):
        return self.assets.discover(card.get("_folder_rel", ""))

    def meta_payload(self, cfg=None):
        m = json.loads(json.dumps(self.meta))
        m["status_labels"] = STATUS_LABELS
        if cfg:
            m["show_candidates"] = bool(cfg.get("show_candidates", True))
            m["default_status"] = cfg.get("default_status",
                                          "with_screenshot")
        return m


def _matches(card, params, section, default_status="with_screenshot"):
    crew = (params.get("crew", "any") or "any")
    crew_active = (crew != "any" and "crew" in kind_filters(section))
    cracker = (params.get("cracker", "any") or "any")
    cracker_active = (cracker != "any"
                      and "cracker" in kind_filters(section))
    focus_active = crew_active or cracker_active
    st = params.get("status")
    if st is None:
        # all sections use the configured default preset (desktop parity)
        st = default_status
    st = st or "any"
    if st == "with_screenshot":
        # crew/cracker focus always shows the focused variant, even empty
        if not focus_active and not card["screenshots"]:
            return False
    elif st == "desktop_any":
        if not any(v["status"] == "desktop" for v in card["variants"]):
            return False
    elif st in ("desktop_text", "desktop_black"):
        # strict status+kind presets: textscreen / darkscreen desktop shots.
        # Like the desktop app, these are ZIP-level filters (a card with a
        # done ZIP still matches when it has a desktop text/black variant).
        kind = "textscreen" if st == "desktop_text" else "darkscreen"
        if not any(v["status"] == "desktop" and v.get("kind") == kind
                   for v in card["variants"]):
            return False
    elif st == "no_usable_shots_any":
        if not any(v["status"] == "no_usable_shots" for v in card["variants"]):
            return False
    elif st == "pending":
        # app parity: a card matches `pending` when ANY of its ZIPs is
        # pending (the display_status aggregate would hide pending ZIPs
        # of folders that already have a done ZIP)
        if not any(v["status"] == "pending" for v in card["variants"]):
            return False
    elif st in ("interrupted", "skipped_disk_n"):
        # ZIP-level failure/skip states: a card with a done ZIP must still be
        # reachable from the filter.
        if not any(v["status"] == st for v in card["variants"]):
            return False
    elif st != "any" and card["display_status"] != st:
        return False
    letter = params.get("letter", "any") or "any"
    if letter != "any" and card["letter"] != letter:
        return False
    q = (params.get("q") or "").strip().lower()
    if q and q not in card["_search"]:
        return False
    fields = kind_filters(section)
    for facet, attr in (("publisher", "_publisher"),
                        ("crew", "_crew"),
                        ("cracker", "_cracker"),
                        ("language", "_language")):
        val = params.get(facet, "any") or "any"
        if val != "any":
            if facet not in fields:
                return False
            if val not in card[attr]:
                return False
    year = params.get("year", "any") or "any"
    if year != "any":
        if card["year"] != year:
            return False
    for flag, attr in (("raw", "_raw"), ("pasti", "_pasti"),
                       ("boxscan", "_boxscan")):
        tri = params.get(flag, "any") or "any"
        if tri != "any":
            if flag not in fields or card[attr] is None:
                return False
            if tri == "yes" and not card[attr]:
                return False
            if tri == "no" and card[attr]:
                return False
    tos = params.get("tos", "any") or "any"
    if tos == "has" and not card["_tos"]:
        return False
    return True


def _tie(card):
    return (card["name"].lower(),
            card["variants"][0]["rel"] if card["variants"] else card["name"])


def _sort_cards(cards, sort, order):
    if sort not in SORTS:
        sort = "name"
    if sort == "name":
        cards.sort(key=_tie)
        if order == "desc":
            cards.reverse()
        return

    def prim(card):
        if sort == "year":
            return card["_year_num"]
        return card[f"_{sort}_sort"]

    known = [c for c in cards if prim(c) not in (0, "")]
    unknown = [c for c in cards if prim(c) in (0, "")]
    unknown.sort(key=_tie)
    if sort == "year":
        known.sort(key=lambda c: (-c["_year_num"], *_tie(c))
                   if order == "desc" else (c["_year_num"], *_tie(c)))
    else:
        known.sort(key=_tie)          # name asc as tie-break
        known.sort(key=lambda c: str(prim(c)).lower(),
                   reverse=(order == "desc"))  # stable → ties keep name asc
    cards[:] = known + unknown


CREW_KINDS = ("crew", "cracker")


def crew_kind_counts(cards):
    """Count crew summaries per kind (`crew`/`cracker`)."""
    return {
        "crew": sum(1 for c in cards if c.get("kind") != "cracker"),
        "cracker": sum(1 for c in cards if c.get("kind") == "cracker"),
    }


def filter_crew_cards(cards, q="", kind=""):
    """Filter crew summaries by search text and kind (`""` = any)."""
    query = (q or "").strip().lower()
    wanted = (kind or "").strip().lower()
    if wanted not in CREW_KINDS:
        wanted = ""
    out = []
    for card in cards:
        if wanted and str(card.get("kind") or "crew") != wanted:
            continue
        if query and query not in card.get("_search", ""):
            continue
        out.append(card)
    return out


def _public_crew_card(card):
    return {
        "id": card["id"],
        "name": card["name"],
        "kind": card["kind"],
        "rank": card["rank"],
        "zips": card["zips"],
        "releases": card["releases"],
        "aliases": card["aliases"],
        "preview": card["preview"],
        "top": card.get("top", True),
        "crew": True,
    }


def _public_card(card, section):
    out = {
        "id": card["id"],
        "name": card["name"],
        "letter": card["letter"],
        "folder": card["folder"],
        "display_status": card["display_status"],
        "screenshots": card["screenshots"],
        "status_counts": card["status_counts"],
        "layer": card["layer"],
        "year": card["year"],
        "preview": card["preview"],
        "variants": card["variants"],
    }
    if "focus_variant" in card:
        out["focus_variant"] = card["focus_variant"]
    if card.get("release_labels"):
        out["release_labels"] = card["release_labels"]
    if card.get("info"):
        out["info"] = card["info"]
    return out


class GalleryHandler(BaseHTTPRequestHandler):
    server_version = f"MarcerGallery/{TOOL_VERSION}"
    store: DataStore = None        # set in main()
    cfg: dict = {}                 # set in main()

    # -- helpers ----------------------------------------------------------
    def log_message(self, fmt, *args):  # quiet default access log
        if os.environ.get("GALLERY_VERBOSE"):
            sys.stderr.write("%s - %s\n" % (self.address_string(),
                                            fmt % args))

    def _json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status, message):
        self._json({"error": message}, status)

    def _params(self):
        query = parse_qs(urlparse(self.path).query)
        return {k: v[0] for k, v in query.items() if v}

    # -- routes -----------------------------------------------------------
    def do_GET(self):  # noqa: N802 - http.server API
        path = urlparse(self.path).path
        try:
            if path == "/":
                return self._file(STATIC_DIR / "index.html", "text/html")
            if path.startswith("/static/"):
                name = path[len("/static/"):]
                if name not in ("app.js", "style.css", "favicon.svg"):
                    return self._error(404, "not found")
                ctype = {"app.js": "text/javascript",
                         "style.css": "text/css",
                         "favicon.svg": "image/svg+xml"}[name]
                return self._file(STATIC_DIR / name, ctype)
            if path == "/api/meta":
                self.store.reload()
                return self._json(self.store.meta_payload(self.cfg))
            if path == "/api/entries":
                self.store.reload()
                return self._entries()
            if path == "/api/local-assets":
                self.store.reload()
                return self._local_assets()
            if path == "/api/crews":
                self.store.reload()
                return self._crews()
            if path.startswith("/img/"):
                return self._image(unquote(path[len("/img/"):]))
            return self._error(404, "not found")
        except BrokenPipeError:
            pass
        except Exception as exc:  # noqa: BLE001
            log(f"[error] {path}: {exc!r}")
            try:
                self._error(500, "internal error")
            except Exception:  # noqa: BLE001
                pass

    def _file(self, path, ctype):
        if not path.is_file():
            return self._error(404, "not found")
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", f"{ctype}; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def _image(self, rel):
        if not rel.lower().endswith(".png"):
            return self._error(404, "not found")
        base = os.path.realpath(self.store.out)
        real = os.path.realpath(os.path.join(base, rel))
        if not (real == base or real.startswith(base + os.sep)):
            return self._error(404, "not found")
        if not os.path.isfile(real):
            return self._error(404, "not found")
        with open(real, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(body)))
        max_age = int(self.cfg.get("image_cache_seconds", 86400))
        self.send_header("Cache-Control", f"public, max-age={max_age}")
        self.end_headers()
        self.wfile.write(body)

    def _crews(self):
        params = self._params()
        crew_id = (params.get("id") or "").strip()
        if crew_id.startswith("crew:"):
            crew_id = crew_id[5:]
        if crew_id:
            group = self.store.crew_groups.get(crew_id)
            if group is None:
                return self._error(404, "crew not found")
            return self._json(self.store.crew_detail(group))
        q = (params.get("q") or "").strip().lower()
        kind = (params.get("kind") or "").strip().lower()
        cards = filter_crew_cards(self.store.crews, q, kind)
        try:
            limit = int(params.get("limit", self.cfg["page_size"]))
        except ValueError:
            limit = self.cfg["page_size"]
        limit = max(1, min(200, limit))
        try:
            offset = max(0, int(params.get("offset", 0)))
        except ValueError:
            offset = 0
        page = cards[offset:offset + limit]
        return self._json({
            "total": len(cards),
            "kinds": crew_kind_counts(cards),
            "offset": offset,
            "limit": limit,
            "cards": [_public_crew_card(c) for c in page],
        })

    def _local_assets(self):
        params = self._params()
        section = params.get("section", "cracked") or "cracked"
        if section not in SECTION_INDEX_NAMES:
            return self._error(400, "invalid section")
        card_id = params.get("id", "") or ""
        if not card_id:
            return self._error(400, "id required")
        card = next((c for c in self.store.cards[section]
                     if c["id"] == card_id), None)
        if card is None:
            return self._error(404, "card not found")
        return self._json(self.store.assets_for_card(card))

    def _entries(self):
        params = self._params()
        section = params.get("section", "cracked") or "cracked"
        if section not in SECTION_INDEX_NAMES:
            return self._error(400, "invalid section")
        store = self.store

        # single-card lookup for deep links (SPEC 5.3 "entry")
        entry = params.get("entry")
        if entry:
            card = next((c for c in store.cards[section]
                         if any(v["rel"] == entry for v in c["variants"])),
                        None)
            if card is None:
                return self._error(404, "entry not found")
            entry_sort = params.get("sort", "name") or "name"
            entry_order = params.get("order", "asc") or "asc"
            if entry_order not in ("asc", "desc"):
                entry_order = "asc"
            default_status = self.cfg.get("default_status", "with_screenshot")
            filtered = [c for c in store.cards[section]
                        if _matches(c, params, section, default_status)]
            _sort_cards(filtered, entry_sort, entry_order)
            position = next(
                (i for i, c in enumerate(filtered) if c is card), None)
            payload = _public_card(card, section)
            payload["position"] = position
            return self._json({
                "total": 1, "offset": 0, "limit": 1,
                "sort": "name", "order": "asc",
                "cards": [payload],
            })

        try:
            limit = int(params.get("limit", self.cfg["page_size"]))
        except ValueError:
            limit = self.cfg["page_size"]
        limit = max(1, min(200, limit))
        try:
            offset = max(0, int(params.get("offset", 0)))
        except ValueError:
            offset = 0
        sort = params.get("sort", "name") or "name"
        order = params.get("order", "asc") or "asc"
        if order not in ("asc", "desc"):
            order = "asc"

        default_status = self.cfg.get("default_status", "with_screenshot")
        matched = [c for c in store.cards[section]
                   if _matches(c, params, section, default_status)]
        _sort_cards(matched, sort, order)
        page = matched[offset:offset + limit]

        # crew/cracker filter: focus each card on the matching ZIP variant
        # (cracker takes precedence over crew; SPEC 5.3)
        fields = kind_filters(section)
        cracker = (params.get("cracker", "any") or "any")
        crew = (params.get("crew", "any") or "any")
        if cracker != "any" and "cracker" in fields:
            page = [_apply_focus(c, cracker, "cracker") for c in page]
        elif crew != "any" and "crew" in fields:
            page = [_apply_focus(c, crew, "crew") for c in page]

        return self._json({
            "total": len(matched),
            "offset": offset,
            "limit": limit,
            "sort": sort,
            "order": order,
            "cards": [_public_card(c, section) for c in page],
        })


def main():
    ap = argparse.ArgumentParser(
        prog="gallery", description="Marcer GameDVD gallery webapp")
    ap.add_argument("--host", default=None,
                    help="bind address (default from config: 0.0.0.0)")
    ap.add_argument("--port", type=int, default=None,
                    help="port (default from config: 8764)")
    args = ap.parse_args()

    cfg = load_config()
    if args.host is not None:
        cfg["host"] = args.host
    if args.port is not None:
        cfg["port"] = args.port

    out_dir = os.environ.get("MARCER_OUT_DIR", "").strip()
    if not out_dir or not os.path.isdir(out_dir):
        log("[error] MARCER_OUT_DIR missing or not a directory "
            "(set it in local/paths.env)")
        return 1
    index_path = os.path.join(out_dir, "index.json")
    if not os.path.isfile(index_path):
        log(f"[error] index.json not found under MARCER_OUT_DIR "
            f"({out_dir!r}) — run `tools/screenshot-gen/run.sh index`")
        return 1
    data_dir = os.environ.get("MARCER_DATA_DIR", "").strip()
    if data_dir and not os.path.isdir(data_dir):
        log(f"[warn] MARCER_DATA_DIR not a directory ({data_dir!r}) — "
            f"screenshots-only mode")
        data_dir = ""
    if data_dir:
        gameinfo_dir = os.path.join(data_dir, GAMEINFO_SUBDIR)
        if not os.path.isdir(gameinfo_dir):
            log(f"[warn] {gameinfo_dir} not found under MARCER_DATA_DIR — "
                f"screenshots-only mode")
    root_dir = os.environ.get("MARCER_ROOT_DIR", "").strip()
    if root_dir and not os.path.isdir(root_dir):
        log(f"[warn] MARCER_ROOT_DIR not a directory ({root_dir!r}) — "
            f"boxscan/manual metadata disabled")
        root_dir = ""
    patch_dir = os.environ.get("MARCER_PATCH_DIR", "").strip()
    if patch_dir and not os.path.isdir(patch_dir):
        log(f"[warn] MARCER_PATCH_DIR not a directory ({patch_dir!r}) — "
            f"patch layer ignored")
        patch_dir = ""

    if not STATIC_DIR.is_dir():
        log(f"[error] static assets missing: {STATIC_DIR}")
        return 1

    host = cfg["host"]
    if host not in ("127.0.0.1", "localhost", "::1"):
        log(f"[warn] binding to {host} — no authentication is configured, "
            f"anyone who can reach this address can browse the archive")

    # SIGTERM behaves like Ctrl+C (SPEC 8.6)
    def _sigterm(_sig, _frm):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, _sigterm)

    log("[data] loading …")
    store = DataStore(
        out_dir, data_dir, root_dir=root_dir, patch_dir=patch_dir,
        assets_cache_seconds=cfg.get("local_assets_cache_seconds", 60))
    GalleryHandler.store = store
    GalleryHandler.cfg = cfg

    httpd = ThreadingHTTPServer((host, int(cfg["port"])), GalleryHandler)
    httpd.daemon_threads = True
    log(f"[serve] http://{host}:{cfg['port']}/  (Ctrl+C to stop)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("\n[serve] bye")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
