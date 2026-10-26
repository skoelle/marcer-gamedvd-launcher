#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Marcer GameDVD Screenshot Generator.

Implements SPEC-screenshot-generator.md:
  index                build/refresh the ZIP index for one scope's trees
  run                  process pending entries (interruptible, resumable)
  detect               find the program icon in existing desktop previews
  cleanup-duplicates   remove pixel-exact duplicate candidates (offline)
  cleanup-boot-logo    remove static Falcon boot-logo candidates (offline)
  promote-app-screens  promote an open-window candidate to the preview

Scopes (config ``scope_default`` + ``scopes``): every subcommand works
on exactly one scope per invocation, selected with ``--scope`` (default:
the configured ``scope_default``). Each scope has its own tree list and
its own index file: the default scope maps to ``index.json`` (what the
gallery and desktop app read), every other scope to ``index-<name>.json``
(overridable per scope via an explicit ``index`` key). There is
deliberately no "all scopes" mode.

The static HTML gallery (formerly 'html') has been replaced by the
gallery webapp in tools/gallery/ — see SPEC-gallery-webapp.md.

Paths come exclusively from environment variables (see run.sh and
local/paths.env). This file contains no real data paths.
"""
import argparse
import gc
import hashlib
import json
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from collections import deque
from pathlib import Path

TOOL_VERSION = "0.1.1"
GAMEINFO_SUBDIR = "gameinfo"
STOP_EVENT = None  # set in main
PROGRESS_INTERVAL_S = 10.0


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------

DEFAULT_CONFIG = {
    # Scope selection: every invocation works on exactly one scope
    # (--scope overrides the default). The default scope's index is
    # index.json; every other scope uses index-<name>.json unless the
    # scope spec sets an explicit "index" key.
    "scope_default": "cracked",
    "scopes": {
        "cracked": {
            "trees": [
                "Title Sorted/Cracked Games - Title Sorted",
            ],
        },
        "utils": {
            "trees": [
                "Title Sorted/Utilitys - Title Sorted",
            ],
        },
        "pd": {
            "trees": [
                "Title Sorted/PD Games - Title Sorted",
            ],
        },
        "magazine": {
            "trees": [
                "Bonus/Magazine Cover Disks",
            ],
            "exclude_dirs": [
                "dupes",
            ],
            "boot": "auto",
        },
        "falcon": {
            "trees": [
                "Falcon 030/Title Sorted",
            ],
            "index": "index-falcon.json",
            "tos_default": "4.04",
            "timepoints": [15, 30, 60],
            "profile": {
                "name": "falcon",
                "machine": "falcon",
                "memsize": "14",
                "zoom": "1",
                "monitor": "rgb",
                "extra_args": ["--dsp", "emu", "--cpuclock", "16"],
            },
        },
    },
    # Directory names ending with this suffix (case-insensitive, matched
    # against the entry's game folder, e.g. "Abalone - Mono") are booted
    # with --mono --tos-res high (ST high res, 640x400). Empty = disabled.
    "mono_dir_suffix": "Mono",
    # Monitor selection from the gameinfo XLS export (MARCER_DATA_DIR/
    # gameinfo/games-<scope>.json, read-only). Rules are per scope:
    #   mono_if_all   - mono when every variant's screen_format equals one
    #                   of these values (pd: pure "High" folders)
    #   color_hints   - any variant value containing one of these substrings
    #                   forces color (checked before mono_hints)
    #   mono_hints    - any variant value containing one of these substrings
    #                   forces mono
    #   default       - mode when no hint matched (e.g. utils blank/notes)
    #                   and for entries missing from a loaded gameinfo file
    # A gameinfo rule wins over the folder suffix. A completely missing or
    # unreadable gameinfo file falls back to the suffix rule. See SPEC
    # section 4.6.
    "screen_format_monitor": {
        "utils": {
            "default": "mono",
            "color_hints": ["not mono", "low", "mid", "medium",
                            "color", "colour"],
            "mono_hints": ["mono", "high"],
        },
        "pd": {
            "mono_if_all": ["high"],
        },
    },
    # Legacy (pre-scopes) single-scope configuration: used only when the
    # merged config carries no "scopes" entry at all.
    "scope_trees": [
        "Title Sorted/Cracked Games - Title Sorted",
    ],
    # Sub-directory names that never contain Hatari disk images (box scans,
    # manuals, Kryoflux flux dumps). Matched case-insensitively, ignoring
    # spaces/underscores/dashes, at any depth below the scope tree.
    "exclude_dirs": ["kryoflux", "boxscan", "manual"],
    "timepoints": [10, 25, 45],
    "entry_timeout_s": 90,
    "keep_candidates": True,
    # TOS selection (section 7.5): the version used for a normal run is
    # `tos_default`; `tos_images` maps a version label to the environment
    # variable holding its ROM image. `run --tos <version>` boots with that
    # version instead, used to retry `no_usable_shots` entries that hang on
    # the default TOS (e.g. old titles that require TOS 1.02).
    "tos_default": "1.04",
    "tos_images": {
        "1.04": "MARCER_TOS_IMG",
        "1.02": "MARCER_TOS102_IMG",
        "4.04": "MARCER_TOS404_IMG",
    },
    "disk_skip_regex": (
        r"(?i)(?:^|[\s\-_.])(?:disk|side|disc)[\s\-_.]*"
        r"(?:[2-9]|b|ii|iii)(?:$|[\s\-_.])"
    ),
    "filters": {
        "black_mean_max": 0.02,
        "black_std_max": 1.0,
        "black_std_content_min": 6.0,
        "desktop_max_colors": 5,
        "desktop_min_mean": 0.5,
        "desktop_green_frac_min": 0.02,
        "textscreen_min_white": 0.5,
        "white_pixel_min": 230,
        "phash_max_distance": 6,
        # Falcon TOS 4.04 boot screens: the white screen with the black
        # Atari logo top-left (matched by pHash, with a geometry fallback
        # when crop/zoom changes the hash) and the plain green Videl
        # stage (2 colours, no dark content). Both are static, identical
        # on every capture and useless for the catalog.
        "falcon_boot_logo_phash": "870703f8f8f8f807",
        "falcon_boot_logo_max_distance": 2,
        "falcon_boot_logo_green_min": 0.20,
        "falcon_boot_logo_stage_white_min": 0.20,
        "falcon_boot_logo_white_min": 0.98,
        "falcon_boot_logo_max_colors": 2,
        "falcon_boot_logo_max_x": 0.30,
        "falcon_boot_logo_max_y": 0.45
    },
    "score_weights": {"entropy": 0.4, "colors": 0.3, "edges": 0.3},
    "click_retry": {
        "probe_time": 10,
        "timepoints_after_click": [10, 25, 45],
        "entry_timeout_s": 120,
        "icon_min_score": 0.5,
        "window_icon_min_score": 0.80,
        "step_wait": 5.0,
        "drive_max_depth": 2,
        "drive_attempts": 3,
        "prg_attempts": 3,
        "folder_attempts": 3,
        "enlarge_window": True,
        "scroll_attempts": 4,
        "max_icon_attempts": 8,
        "ttp_cancel_attempts": 2,
    },
    "tmp_dir": "/tmp/marcer-shotgen",
    # Resource guards for run: per-worker RAM estimate and how much RAM/disk
    # must remain free. jobs are capped from MemAvailable + SwapFree (a
    # worker settles at 0.6-0.8 GB during the click retry, so a too-low
    # per_job_mb lets --jobs overcommit and the OOM-killer reaps the whole
    # process); staging dirs older than stale_stage_hours are treated as
    # leftovers from a crashed run.
    "resource_limits": {
        "per_job_mb": 800,
        "min_free_mb": 2000,
        "min_disk_free_mb": 2048,
        "stale_stage_hours": 1,
        "mem_guard_fraction": 1.5,
    },
    "xvfb_screen": "1024x768x24",
    "profile": {
        "name": "st",
        "machine": "st",
        "memsize": "1",
        "zoom": "1",
        "extra_args": [],
    },
}


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def load_config() -> dict:
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    root = repo_root() / "tools" / "screenshot-gen"
    for name in ("config.example.json", "config.local.json"):
        p = root / name
        if p.exists():
            with open(p, encoding="utf-8") as f:
                over = json.load(f)
            _deep_merge(cfg, over)
    return cfg


def _deep_merge(base: dict, over: dict) -> None:
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _deep_merge(base[k], v)
        else:
            base[k] = v


def resolve_scopes(cfg: dict) -> tuple:
    """Return ``(default_scope, {name: {"name", "trees", "index"}})``.

    New configs use ``scope_default`` + ``scopes``. A config without any
    ``scopes`` entry falls back to the legacy ``scope_trees`` list (one
    implicit scope ``cracked`` writing index.json). The default scope's
    index file is always ``index.json`` (what the gallery and desktop
    app read); every other scope uses ``index-<name>.json``, overridable
    per scope via an explicit ``index`` key. Note: when switching
    ``scope_default`` away from a section the UIs display, keep that
    section on ``index.json`` via an explicit ``index`` entry.
    """
    default = (cfg.get("scope_default") or "cracked").strip()
    raw = cfg.get("scopes") or {}
    if not raw:
        # legacy single-scope config (pre-scopes)
        raw = {"cracked": {"trees": cfg.get("scope_trees")
                           or DEFAULT_CONFIG["scope_trees"]}}
        default = "cracked"
    scopes = {}
    for name, spec in raw.items():
        if isinstance(spec, dict):
            trees = [str(t) for t in (spec.get("trees") or [])]
            index = spec.get("index")
            exclude = [str(d) for d in (spec.get("exclude_dirs") or [])]
            profile = spec.get("profile") or {}
            tos_default = spec.get("tos_default")
            timepoints = spec.get("timepoints")
            boot = spec.get("boot")
        else:
            sys.exit(f"error: scopes.{name} must be an object with a "
                     f"trees list")
        if not trees:
            sys.exit(f"error: scope {name!r} has no trees")
        if not index:
            index = "index.json" if name == default else f"index-{name}.json"
        scopes[name] = {"name": name, "trees": trees, "index": index,
                        "exclude_dirs": exclude, "profile": profile,
                        "tos_default": tos_default,
                        "timepoints": timepoints, "boot": boot}
    if default not in scopes:
        sys.exit(f"error: scope_default {default!r} is not defined in "
                 f"scopes ({', '.join(sorted(scopes))})")
    return default, scopes


def require_env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        sys.exit(f"error: environment variable {name} is not set "
                 f"(add it to local/paths.env)")
    return v


def gameinfo_dir() -> str:
    """The gameinfo directory: ``<MARCER_DATA_DIR>/gameinfo``."""
    data = os.environ.get("MARCER_DATA_DIR", "").strip()
    return os.path.join(data, GAMEINFO_SUBDIR) if data else ""


def paths() -> dict:
    return {
        "root": require_env("MARCER_ROOT_DIR"),
        "patch": os.environ.get("MARCER_PATCH_DIR", "").strip(),
        "out": require_env("MARCER_OUT_DIR"),
        "data": gameinfo_dir(),
        "tos": require_env("MARCER_TOS_IMG"),
        "hatari": os.environ.get("MARCER_HATARI_BIN", "").strip() or "hatari",
        "display": os.environ.get("MARCER_DISPLAY", "").strip() or ":99",
    }


def tos_image_for(cfg: dict, P: dict, version: str) -> str:
    """Resolve the ROM image path for a TOS [version] label (section 7.5).

    The default version's image is the already-resolved ``MARCER_TOS_IMG``;
    every other version is read lazily from its configured environment
    variable, so a missing alternative TOS only aborts a run that uses it.
    """
    images = cfg.get("tos_images") or {}
    if version not in images:
        sys.exit(f"error: unknown TOS version {version!r} "
                 f"(known: {', '.join(sorted(images))})")
    if version == (cfg.get("tos_default") or "1.04"):
        return P["tos"]
    return require_env(images[version])


# --------------------------------------------------------------------------
# monitor selection (gameinfo screen_format + folder suffix)
# --------------------------------------------------------------------------

def _norm_screen_format(value) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def entry_card_key(rel: str, scope: dict):
    """Return the lower-case ``(letter, folder)`` key of an entry.

    The key is derived from the path *below the scope tree*, so it also
    works for ZIPs in sub-directories such as ``Original/`` (where the
    ZIP's immediate parent is not the game folder). Matches the
    ``(letter, folder)`` grouping used by the gallery/desktop gameinfo
    join.
    """
    for tree in scope.get("trees") or []:
        prefix = tree.rstrip("/") + "/"
        if rel[:len(prefix)].lower() == prefix.lower():
            parts = Path(rel[len(prefix):]).parts
            if len(parts) >= 2:
                return parts[0].lower(), parts[1].lower()
    return None


def load_screen_formats(P: dict, scope_name: str):
    """Load ``games-<scope>.json`` into a ``(letter, folder)`` mapping.

    Returns ``(formats, source_description)``. Missing data is not an
    error: the caller falls back to the folder-suffix rule.
    """
    data = (P.get("data") or "").strip()
    if not data:
        return {}, "MARCER_DATA_DIR is not set"
    path = Path(data) / f"games-{scope_name}.json"
    if not path.is_file():
        return {}, f"{path} not found"
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception as ex:
        return {}, f"cannot read {path}: {ex}"
    formats = {}
    for game in doc.get("games") or []:
        if not isinstance(game, dict):
            continue
        key = (str(game.get("letter") or "").lower(),
               str(game.get("folder") or "").lower())
        formats[key] = [
            _norm_screen_format(v.get("screen_format"))
            for v in (game.get("variants") or [])
            if isinstance(v, dict)
        ]
    return formats, str(path)


def _hint_match(values, hints) -> bool:
    return any(any(h in value for h in hints) for value in values)


def resolve_monitor(cfg: dict, scope: dict, rel: str, screen_formats: dict):
    """Return ``(mode, source)`` for one entry.

    Precedence: explicit gameinfo rule > folder suffix > color. The
    gameinfo mapping is optional; without it the historic suffix rule
    applies unchanged.
    """
    scope_name = scope["name"]
    rule_sets = cfg.get("screen_format_monitor") or {}
    if not isinstance(rule_sets, dict):
        rule_sets = {}
    rules = rule_sets.get(scope_name) or {}
    if not isinstance(rules, dict):
        rules = {}
    key = entry_card_key(rel, scope)
    folder = key[1] if key else Path(rel).parent.name
    fmt_vals = screen_formats.get(key) if key else None

    if fmt_vals is not None and rules:
        mono_if_all = [_norm_screen_format(v)
                       for v in (rules.get("mono_if_all") or [])]
        if mono_if_all and fmt_vals and all(v in mono_if_all
                                            for v in fmt_vals):
            return "mono", "screen_format:" + ",".join(
                sorted(set(mono_if_all)))
        color_hints = [_norm_screen_format(v)
                       for v in (rules.get("color_hints") or [])]
        mono_hints = [_norm_screen_format(v)
                      for v in (rules.get("mono_hints") or [])]
        nonempty = [v for v in fmt_vals if v]
        if color_hints and _hint_match(nonempty, color_hints):
            return "color", "screen_format:color"
        if mono_hints and _hint_match(nonempty, mono_hints):
            return "mono", "screen_format:mono"
        default = str(rules.get("default") or "").strip().lower()
        if default in ("mono", "color"):
            return default, "screen_format:default"

    # A missing folder in an otherwise loaded gameinfo file uses the scope
    # default too (utils: mono). A completely missing/unreadable gameinfo
    # file keeps the historic suffix fallback.
    if (fmt_vals is None and key is not None and rules and screen_formats
            and str(rules.get("default") or "").strip().lower() == "mono"):
        return "mono", "screen_format:missing-default"

    suffix = (cfg.get("mono_dir_suffix") or "").strip()
    if suffix and folder.strip().lower().endswith(suffix.lower()):
        return "mono", "folder-suffix"
    return "color", "default"


def build_monitor_map(cfg: dict, P: dict, scope: dict, entries):
    """Resolve the monitor mode for every pending entry of one run."""
    rule_sets = cfg.get("screen_format_monitor") or {}
    if not isinstance(rule_sets, dict):
        rule_sets = {}
    has_rules = scope["name"] in rule_sets
    formats, source = ({}, "")
    if has_rules:
        formats, source = load_screen_formats(P, scope["name"])
    mapping = {}
    counts = {"mono": 0, "color": 0, "rules": 0, "suffix": 0, "default": 0}
    for entry in entries:
        mode, why = resolve_monitor(cfg, scope, entry["rel"], formats)
        mapping[entry["rel"]] = (mode, why)
        counts[mode] += 1
        if why.startswith("screen_format"):
            counts["rules"] += 1
        elif why == "folder-suffix":
            counts["suffix"] += 1
        else:
            counts["default"] += 1
    if not has_rules:
        return mapping, ""
    if not formats:
        return mapping, (f"screen_format monitor[{scope['name']}]: {source}; "
                         f"using folder suffix only")
    return mapping, (
        f"screen_format monitor[{scope['name']}] from {source}: "
        f"{counts['mono']} mono, {counts['color']} color "
        f"(rules {counts['rules']}, suffix {counts['suffix']}, "
        f"default {counts['default']})")


# --------------------------------------------------------------------------
# falcon / GEMDOS boot preparation
# --------------------------------------------------------------------------

# Floppy disk images Hatari can read from inside a ZIP.
FLOPPY_EXTS = {".st", ".msa", ".stx", ".ipf", ".ctr", ".raw"}
# GEMDOS programs that can be autostarted with `--auto`.
BOOT_EXTS = {".prg", ".tos", ".ttp", ".app", ".gtp"}


def scope_profile(cfg: dict, scope: dict) -> dict:
    """Return the effective Hatari profile of a scope.

    The global ``profile`` is the base; a scope may override individual
    keys via ``scopes.<name>.profile`` (deep-merged, e.g. machine falcon).
    """
    prof = json.loads(json.dumps(cfg.get("profile") or {}))
    _deep_merge(prof, scope.get("profile") or {})
    return prof


def _norm_prog(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", str(name).lower())


def _zip_entries(zip_path):
    """Return ``(names, sizes)`` for the file entries of a ZIP."""
    names, sizes = [], {}
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            names.append(info.filename)
            sizes[info.filename] = info.file_size
    return names, sizes


def _read_head(zf, name: str, n: int = 16) -> bytes:
    try:
        with zf.open(name) as fh:
            return fh.read(n)
    except Exception:
        return b""


def _is_stzip(zf, name: str) -> bool:
    """True for Atari STZip self-extracting archives (they only unpack)."""
    return _read_head(zf, name, 5).lower().startswith(b"stzip")


def _disk_index(name: str) -> int:
    """Sort key that prefers disk 1 / A over 2 / B (`..._a.st`, `disk1`)."""
    base = _norm_prog(Path(name).stem)
    m = re.search(r"(\d+)$", base)
    if m:
        return int(m.group(1))
    if base.endswith("a"):
        return 1
    if base.endswith("b"):
        return 2
    return 99


def _part_number(name: str):
    """Return ``(part, prefix)`` for a disk-like boot name, else ``(None, base)``.

    ``AAZOHM1`` -> ``(1, "aazohm")``, ``GameA`` -> ``(1, "game")``; a name
    without a trailing number/letter keeps ``part=None``.
    """
    base = _norm_prog(Path(name).stem)
    m = re.search(r"(\d+)$", base)
    if m:
        return int(m.group(1)), base[:m.start()]
    if base.endswith("a"):
        return 1, base[:-1]
    if base.endswith("b"):
        return 2, base[:-1]
    return None, base


def pick_boot_program(zf, names, sizes, stem):
    """Pick the program to autostart from a GEMDOS ZIP.

    Prefers a boot file whose normalized stem matches the ZIP stem, then a
    stem containment match (skipping STZip self-extractors), then the only
    boot file. Among several candidates a numbered multi-part set
    (`AAZOHM1/2/3.TOS`) picks its lowest part; otherwise the largest file
    wins. Returns the ZIP-relative name or ``None``.
    """
    boots = [n for n in names if Path(n).suffix.lower() in BOOT_EXTS]
    if not boots:
        return None
    target = _norm_prog(stem)
    for n in boots:
        if _norm_prog(Path(n).stem) == target and not _is_stzip(zf, n):
            return n
    contain = []
    if target:
        for n in boots:
            ns = _norm_prog(Path(n).stem)
            if ns and (target in ns or ns in target) and not _is_stzip(zf, n):
                contain.append(n)
    if len(contain) == 1:
        return contain[0]
    real = [n for n in boots if not _is_stzip(zf, n)]
    pool = contain or real or boots
    if len(pool) == 1:
        return pool[0]
    # Numbered multi-part sets: a group only counts when at least two of its
    # members carry a part number (so `FPATCH` + `FPATCH2` is not a set);
    # then the lowest part wins.
    groups = {}
    for n in pool:
        part, prefix = _part_number(n)
        groups.setdefault(prefix, []).append((part, n))
    best = None
    best_part = None
    for items in groups.values():
        numbered = [(p, n) for p, n in items if p is not None]
        if len(numbered) >= 2:
            part, name = min(numbered, key=lambda t: t[0])
            if best_part is None or part < best_part:
                best, best_part = name, part
    if best is not None:
        return best
    pool.sort(key=lambda n: -sizes.get(n, 0))
    return pool[0]


def _extract_member(zf, name: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with zf.open(name) as src, open(dest, "wb") as out:
        shutil.copyfileobj(src, out)


def _floppy_args(zf, stage: Path, staged_zip: Path, images) -> list:
    """Mount the floppy image(s) of a ZIP.

    One image → let Hatari read the ZIP directly; several (disk A/B) →
    extract the first two and mount them as drive A and B.
    """
    ordered = sorted(images, key=lambda n: (_disk_index(n), n.lower()))
    if len(ordered) == 1:
        return ["--disk-a", str(staged_zip)]
    args = []
    for label, name in (("a", ordered[0]), ("b", ordered[1])):
        ext = Path(name).suffix or ".st"
        dest = Path(stage) / f"disk_{label}{ext}"
        _extract_member(zf, name, dest)
        args += [f"--disk-{label}", str(dest)]
    return args


def _safe_extract(zf, dest: Path) -> None:
    """Extract a ZIP, rejecting absolute/traversal member paths."""
    dest = dest.resolve()
    for info in zf.infolist():
        if info.is_dir():
            continue
        target = (dest / info.filename).resolve()
        if dest != target and dest not in target.parents:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        with zf.open(info) as src, open(target, "wb") as out:
            shutil.copyfileobj(src, out)


def prepare_boot(stage: Path, staged_zip: Path, stem: str):
    """Return ``(mode, args)`` for one bootable ZIP.

    ``mode`` is ``"floppy"`` (disk image(s) inside the ZIP) or ``"gemdos"``
    (the ZIP is extracted and the picked program autostarted). GEMDOS boots
    disable the floppy drives: Falcon TOS 4.04 would otherwise raise a modal
    "Drive A: is not responding" dialog that blocks the autostart (harmless
    for ST, where it also avoids probing an empty drive).
    """
    names, sizes = _zip_entries(staged_zip)
    images = [n for n in names if Path(n).suffix.lower() in FLOPPY_EXTS]
    no_floppy = ["--drive-a", "off", "--drive-b", "off"]
    with zipfile.ZipFile(staged_zip) as zf:
        boot = pick_boot_program(zf, names, sizes, stem)
        if images and not boot:
            return "floppy", _floppy_args(zf, stage, staged_zip, images)
        if boot is None:
            return "gemdos", list(no_floppy)
        extract = Path(stage) / "gemdos"
        extract.mkdir(parents=True, exist_ok=True)
        _safe_extract(zf, extract)
    atari_path = "C:\\" + boot.replace("/", "\\")
    return "gemdos", no_floppy + ["-d", str(extract), "--auto", atari_path]


# --------------------------------------------------------------------------
# floppy image scan for --retry-desktop-auto
# --------------------------------------------------------------------------

# Floppy images whose FAT12 directory can be read. `.ipf` has no plain
# logical sectors; `.stx` (Pasti) usually does, and its sector payloads are
# reconstructed by `_stx_to_raw` (copy-protected images without a usable
# boot sector simply yield no program).
FAT_FLOPPY_EXTS = {".msa", ".st", ".stx"}


def _msa_to_raw(msa: bytes) -> bytes:
    """Decode an MSA image to a raw ST sector dump (or pass `.st` through)."""
    if len(msa) < 10 or msa[:2] != b"\x0e\x0f":
        return msa
    spt, sides_flag, start, end = struct.unpack(">HHHH", msa[2:10])
    sides = sides_flag + 1
    pos = 10
    raw = bytearray()
    for _track in range(start, end + 1):
        for _side in range(sides):
            if STOP_EVENT is not None and STOP_EVENT.is_set():
                return bytes(raw)
            if pos + 2 > len(msa):
                return bytes(raw)
            length = struct.unpack(">H", msa[pos:pos + 2])[0]
            pos += 2
            chunk = msa[pos:pos + length]
            pos += length
            if length == 512 * spt:
                raw += chunk
                continue
            i = 0
            out = bytearray()
            while i < len(chunk):
                b = chunk[i]
                if b == 0xE5 and i + 3 < len(chunk):
                    val = chunk[i + 1]
                    run = struct.unpack(">H", chunk[i + 2:i + 4])[0]
                    i += 4
                    out += bytes([val]) * run
                else:
                    out.append(b)
                    i += 1
            raw += out
            # Guard against a malformed MSA whose RLE runs expand far beyond
            # any real floppy (same 16 MB ceiling as `_stx_to_raw`).
            if len(raw) > 16 * 1024 * 1024:
                return bytes(raw[:16 * 1024 * 1024])
    return bytes(raw)


def _stx_to_raw(stx: bytes) -> bytes:
    """Reconstruct a raw ST sector dump from a Pasti (`.stx`) image.

    Pasti stores per-track sector headers plus optional fuzzy masks and a
    track image. The FAT12 filesystem behind ``--retry-desktop-auto`` only
    needs the sector payloads: the boot sector supplies the geometry
    (sectors/track, sides), tracks are placed by their track-header number
    (bit 7 = side B) and sectors by their address-block number. Returns an
    empty byte string when the container is invalid or has no usable boot
    sector (e.g. a copy-protected disk with no plain FAT).
    """
    if len(stx) < 16 or stx[:4] != b"RSY\x00":
        return b""
    if struct.unpack_from("<H", stx, 4)[0] != 3:
        return b""
    track_count = stx[0x0A]
    pos = 16
    sectors = []  # (track_header_number, sector_number, size, payload)
    for _ in range(track_count):
        if STOP_EVENT is not None and STOP_EVENT.is_set():
            return b""
        if pos + 16 > len(stx):
            break
        track_start = pos
        block_len, fuzzy_len, nsect, flags, _img_len, trknum, _res = \
            struct.unpack_from("<LLHHHBB", stx, pos)
        if block_len < 16 or pos + block_len > len(stx):
            break
        pos += 16
        shdrs = []
        if flags & 0x01:
            for _s in range(nsect):
                if pos + 16 > len(stx):
                    return b""
                (off, _timing, _rtime, _rtrack, _side, sec, ssize,
                 _crc1, _crc2, _status, _sflags) = \
                    struct.unpack_from("<LHHBBBBBBBB", stx, pos)
                pos += 16
                size = {2: 512, 3: 1024}.get(ssize, 0)
                if size:
                    shdrs.append((off, sec, size))
        else:
            # unprotected track without sector headers: plain 512-byte
            # sectors follow the track header in logical order
            shdrs = [(s * 512, s + 1, 512) for s in range(nsect)]
        tdata = pos + fuzzy_len
        for off, sec, size in shdrs:
            start = tdata + off
            if start + size > len(stx):
                continue
            sectors.append((trknum, sec, size, stx[start:start + size]))
        pos = track_start + block_len

    boot = next((payload for trknum, sec, size, payload in sectors
                 if (trknum & 0x7F) == 0 and not (trknum & 0x80)
                 and sec == 1 and size == 512), None)
    if boot is None:
        return b""
    bps = struct.unpack_from("<H", boot, 11)[0]
    spt = struct.unpack_from("<H", boot, 24)[0]
    sides = struct.unpack_from("<H", boot, 26)[0]
    total = struct.unpack_from("<H", boot, 19)[0]
    if bps != 512 or spt == 0 or sides not in (1, 2):
        return b""
    if total == 0:
        max_track = max((trknum & 0x7F) for trknum, _s, _z, _p in sectors)
        total = (max_track + 1) * sides * spt
    if total * bps > 16 * 1024 * 1024:
        return b""
    raw = bytearray(total * bps)
    for trknum, sec, size, payload in sectors:
        if size != bps or sec < 1:
            continue
        side = 1 if trknum & 0x80 else 0
        track = trknum & 0x7F
        if side >= sides:
            continue
        off = ((track * sides + side) * spt + (sec - 1)) * bps
        if off + size <= len(raw):
            raw[off:off + size] = payload
    return bytes(raw)


def _image_to_raw(name: str, data: bytes) -> bytes:
    """Decode a supported floppy container to a raw ST sector dump."""
    if Path(name).suffix.lower() == ".stx":
        return _stx_to_raw(data)
    return _msa_to_raw(data)


def _fat12_files(raw: bytes):
    """Return ``[(path, size)]`` from the FAT12 root/sub-directories."""
    if len(raw) < 512:
        return []
    bps = struct.unpack_from("<H", raw, 11)[0]
    spc = raw[13]
    reserved = struct.unpack_from("<H", raw, 14)[0]
    nfats = raw[16]
    root_entries = struct.unpack_from("<H", raw, 17)[0]
    spf = struct.unpack_from("<H", raw, 22)[0]
    if bps != 512 or spc == 0 or spf == 0 or root_entries == 0:
        return []
    if reserved == 0:
        # Many MSA images produced by old formatters/crack tools store 0
        # here even though the FAT still starts after the boot sector
        # (TOS/GEMDOS reads them normally). Treating 0 as the usual one
        # reserved sector keeps FAT/root lookup aligned instead of one
        # sector early, which otherwise hides every directory entry.
        reserved = 1
    root_secs = (root_entries * 32 + bps - 1) // bps
    fat_start = reserved * bps
    root_start = (reserved + nfats * spf) * bps
    data_start = root_start + root_secs * bps
    fat = raw[fat_start:fat_start + spf * bps]

    def chain(cluster):
        # Follow the FAT12 cluster chain. Some damaged/patched disks contain
        # a cyclic chain (a cluster whose next pointer loops back into the
        # chain); without a visited-set guard this loop would append forever,
        # ignore STOP_EVENT and grow the process until the OOM killer reaps
        # it (observed with the STX-decoded "Fleetstreet Publisher Fonts"
        # disk: WES60.FNT cluster 22 -> cycle at 44). Stop at the first
        # repeat and at a hard cap far above any real floppy cluster count.
        out = []
        seen = set()
        while 2 <= cluster < 0xFF8:
            if cluster in seen or len(out) >= 4096:
                break
            seen.add(cluster)
            out.append(cluster)
            off = cluster + cluster // 2
            if off + 1 >= len(fat):
                break
            value = fat[off] | (fat[off + 1] << 8)
            cluster = (value >> 4) if (cluster & 1) else (value & 0xFFF)
        return out

    def cluster_bytes(cluster):
        start = data_start + (cluster - 2) * spc * bps
        return raw[start:start + spc * bps]

    def head_bytes(cluster):
        out = bytearray()
        for c in chain(cluster):
            out += cluster_bytes(c)
            if len(out) >= 4096:
                break
        return bytes(out[:4096])

    files = []
    visited_dirs = set()

    def parse(blob, prefix, depth=0):
        # Directory recursion is also guarded: a damaged sub-directory entry
        # can point back to an ancestor cluster and would otherwise recurse
        # forever (each level rebuilding ``sub``), so bound the depth and
        # skip directories already visited.
        if depth > 32:
            return
        for off in range(0, len(blob) - 31, 32):
            if STOP_EVENT is not None and STOP_EVENT.is_set():
                return
            e = blob[off:off + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                continue
            attr = e[11]
            if attr & 0x08:
                continue
            name = e[0:8].decode("latin1").rstrip()
            ext = e[8:11].decode("latin1").rstrip()
            if not name or name in (".", ".."):
                continue
            full = name + ("." + ext if ext else "")
            start_cluster = struct.unpack_from("<H", e, 26)[0]
            size = struct.unpack_from("<I", e, 28)[0]
            if attr & 0x10:
                if start_cluster == 0 or start_cluster in visited_dirs:
                    continue
                visited_dirs.add(start_cluster)
                sub = b"".join(cluster_bytes(c)
                               for c in chain(start_cluster))
                parse(sub, prefix + full + "/", depth + 1)
            else:
                files.append((prefix + full, size,
                              head_bytes(start_cluster)))

    parse(raw[root_start:root_start + root_entries * 32], "")
    return files


def _is_sfx(head: bytes) -> bool:
    """True for self-extracting archives (LZH/STZip/ZIP SFX).

    Those only unpack files (often onto the write-protected floppy) and are
    not a playable program, so the floppy program pick skips them.
    """
    hl = head.lower()
    return (b"sfx" in hl[:64] or b"self extracting" in hl
            or b"stzip" in hl)


def _floppy_program(raw: bytes):
    """Largest launchable program on a floppy image (AUTO/ preferred).

    Self-extracting archives are skipped; a disk with only SFX packs has no
    launchable program and the entry stays on the desktop.
    """
    progs = [(n, s, h) for n, s, h in _fat12_files(raw)
             if Path(n).suffix.lower() in BOOT_EXTS and not _is_sfx(h)]
    if not progs:
        return None
    auto = [p for p in progs if p[0].lower().startswith("auto/")]
    pool = auto or progs
    pool.sort(key=lambda t: -t[1])
    return pool[0][0]


def prepare_auto_retry(stage: Path, staged_zip: Path, stem: str):
    """Return ``(mode, args, program)`` for ``--retry-desktop-auto``.

    GEMDOS archives reuse the normal extract + ``-d``/``--auto`` path.
    Floppy ZIPs are scanned through their FAT12 directory: the disk's
    ``AUTO/`` program wins, else the largest launchable program. `.stx`
    images are reconstructed to a raw sector dump first (`_stx_to_raw`);
    images without a readable FAT (`.ipf`, non-DOS/copy-protected disks)
    yield no candidate (the click retry remains for those).
    """
    names, _sizes = _zip_entries(staged_zip)
    boots = [n for n in names if Path(n).suffix.lower() in BOOT_EXTS]
    if boots:
        mode, args = prepare_boot(stage, staged_zip, stem)
        program = args[args.index("--auto") + 1] if "--auto" in args else None
        return mode, args, program

    images = [n for n in names if Path(n).suffix.lower() in FLOPPY_EXTS]
    readable = [n for n in images
                if Path(n).suffix.lower() in FAT_FLOPPY_EXTS]
    if not readable:
        return None, None, None
    readable.sort(key=lambda n: (_disk_index(n), n.lower()))
    a_name = readable[0]
    ordered = sorted(images, key=lambda n: (_disk_index(n), n.lower()))
    b_name = next((n for n in ordered if n != a_name), None)
    with zipfile.ZipFile(staged_zip) as zf:
        raw = _image_to_raw(a_name, zf.read(a_name))
        program = _floppy_program(raw)
        if not program:
            return None, None, None
        args = []
        for label, name in (("a", a_name), ("b", b_name)):
            if name is None:
                continue
            ext = Path(name).suffix or ".st"
            dest = Path(stage) / f"disk_{label}{ext}"
            _extract_member(zf, name, dest)
            args += [f"--disk-{label}", str(dest)]
    atari_path = "A:\\" + program.replace("/", "\\")
    return "floppy", args + ["--auto", atari_path], atari_path


# --------------------------------------------------------------------------
# index
# --------------------------------------------------------------------------

INDEX_NAME = "index.json"
LOCK_NAME = "shotgen.lock"


def index_path(out: Path, index_name: str = INDEX_NAME) -> Path:
    return out / index_name


def load_index(out: Path, index_name: str = INDEX_NAME) -> dict:
    p = index_path(out, index_name)
    if p.exists():
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    return {"version": 1, "entries": {}}


def save_index(out: Path, idx: dict, index_name: str = INDEX_NAME) -> None:
    p = index_path(out, index_name)
    tmp = p.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(idx, f, indent=1, sort_keys=True)
    os.replace(tmp, p)


def write_json_atomic(path: Path, data: dict) -> None:
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)


def _is_ignored(name: str) -> bool:
    return name.startswith(".") or name.startswith("@")


def _norm_dir(name: str) -> str:
    """Lowercase a directory name without spaces/underscores/dashes."""
    return re.sub(r"[\s_-]", "", name.lower())


def _excluded_dirs(cfg: dict, scope: dict = None) -> set:
    """Normalized directory names never entered by the scan.

    The global ``exclude_dirs`` list is always applied; a scope may add
    its own via the ``exclude_dirs`` key (e.g. the magazine scope skips
    the ``Dupes`` sub-folders).
    """
    names = list(cfg.get("exclude_dirs") or [])
    if scope:
        names += list(scope.get("exclude_dirs") or [])
    return {_norm_dir(n) for n in names}


def scan_tree(layer_base: Path, scope: str, disk_re, exclude=None) -> dict:
    """Return {relpath: {size, mtime}} for zips under layer_base/scope.

    Directories whose normalized name is in ``exclude`` are never entered,
    so their contents never appear in the index.
    """
    exclude = exclude or set()
    found = {}
    base = layer_base / scope
    if not base.is_dir():
        return found
    stack = [base]
    n_dirs = 0
    while stack:
        if STOP_EVENT is not None and STOP_EVENT.is_set():
            break
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                for e in it:
                    if _is_ignored(e.name):
                        continue
                    if e.is_dir(follow_symlinks=False):
                        if _norm_dir(e.name) in exclude:
                            continue
                        stack.append(e.path)
                        n_dirs += 1
                        if n_dirs % 200 == 0:
                            print(f"  ... {n_dirs} dirs, {len(found)} zips",
                                  flush=True)
                    elif e.name.lower().endswith(".zip"):
                        rel = Path(e.path).relative_to(layer_base).as_posix()
                        try:
                            st = e.stat(follow_symlinks=False)
                        except OSError:
                            continue
                        found[rel] = {"size": st.st_size,
                                      "mtime": int(st.st_mtime)}
        except OSError as ex:
            print(f"  scan error {d}: {ex}", file=sys.stderr, flush=True)
    return found


def build_index(cfg: dict, P: dict, full: bool, scope: dict) -> dict:
    """Scan one scope's trees and refresh its own index file.

    Entries of other scopes live in other index files and are never
    touched here; within this file, entries not seen by the scan are
    removed (rescoping/exclusions).
    """
    disk_re = re.compile(cfg["disk_skip_regex"])
    exclude = _excluded_dirs(cfg, scope)
    root, patch = Path(P["root"]), Path(P["patch"]) if P["patch"] else None
    out = Path(P["out"])
    idx = load_index(out, scope["index"])
    entries = idx.setdefault("entries", {})
    seen = set()
    stats = {"new": 0, "kept": 0, "gone": 0}

    for scope_tree in scope["trees"]:
        print(f"scan scope[{scope['name']}]: {scope_tree}", flush=True)
        r_map = scan_tree(root, scope_tree, disk_re, exclude)
        p_map = scan_tree(patch, scope_tree, disk_re, exclude) \
            if patch else {}
        # Overlay merge case-insensitively (SPEC §7): a patch file whose
        # name differs only in case from a root file overrides it, and the
        # patch spelling becomes the canonical rel — the same rule as the
        # console launcher's OrdinalIgnoreCase merge. Case-sensitive
        # merging created duplicate entries per game whose second capture
        # was then renamed by a case-insensitive NAS (…CaseConflict).
        merged = {}  # rel.lower() -> [rel, src, layer]
        for rel, info in r_map.items():
            merged[rel.lower()] = [rel, info, "ROOT"]
        for rel, info in p_map.items():
            key = rel.lower()
            if key in merged:
                merged[key] = [rel, info, "BOTH"]
            else:
                merged[key] = [rel, info, "PATCH"]
        # Directory-level canonical spelling (SPEC §7, launcher merge):
        # when the same directory exists in both layers under a spelling
        # that differs only in case, the patch spelling wins for EVERY
        # file below it — including root-only files. Without this, a
        # root-only zip kept its root folder spelling next to patch-only
        # zips under the patch spelling, producing two case-variant
        # output directories that a case-insensitive NAS/Dropbox sync
        # renames into …CaseConflict siblings mid-run.
        canon_dirs = {}  # dir path (lower) -> winning spelling
        for rel in r_map:
            d = str(Path(rel).parent)
            canon_dirs.setdefault(d.lower(), d)
        for rel in p_map:
            d = str(Path(rel).parent)
            canon_dirs[d.lower()] = d
        low_entries = {k.lower(): k for k in entries}
        for key in sorted(merged):
            rel, src, layer = merged[key]
            orig_rel = rel  # layer's own spelling, used to read the source
            parent = canon_dirs.get(str(Path(rel).parent).lower())
            if parent:
                rel = (str(Path(parent) / Path(rel).name) if parent != "."
                       else Path(rel).name)
            # src_rel keeps the spelling the file actually has under its
            # own layer root; only differs from rel when the canonical
            # (patch) folder spelling wins over a root-only folder.
            src_rel = orig_rel if orig_rel != rel else None
            key = rel.lower()
            seen.add(rel)
            name = Path(rel).name
            old_key = rel if rel in entries else low_entries.get(key)
            old = entries.get(old_key) if old_key else None
            if (old and not full
                    and old.get("size") == src["size"]
                    and old.get("mtime") == src["mtime"]):
                if old_key != rel:
                    # entry found under the losing spelling only: keep its
                    # curated state, re-keyed to the winning (patch) name
                    del entries[old_key]
                    entries[rel] = old
                # refresh canonical fields (e.g. layer PATCH -> BOTH)
                old.update({"rel": rel, "name": name, "layer": layer})
                if src_rel:
                    old["src_rel"] = src_rel
                else:
                    old.pop("src_rel", None)
                stats["kept"] += 1
                continue
            if disk_re.search(name):
                status = "skipped_disk_n"
            else:
                status = "pending"
            entries[rel] = {
                "rel": rel,
                "name": name,
                "layer": layer,
                "size": src["size"],
                "mtime": src["mtime"],
                "status": status,
                "kind": None,
                "preview": None,
                "candidates": [],
                "last_run": None,
            }
            if src_rel:
                entries[rel]["src_rel"] = src_rel
            stats["new"] += 1
        save_index(out, idx, scope["index"])

    gone = [k for k in entries if k not in seen]
    for k in gone:
        del entries[k]
    stats["gone"] = len(gone)
    save_index(out, idx, scope["index"])
    return stats, idx


# --------------------------------------------------------------------------
# hatari / xvfb
# --------------------------------------------------------------------------

def xvfb_alive(display: str) -> bool:
    try:
        subprocess.run(["xdpyinfo"], env={**os.environ, "DISPLAY": display},
                       capture_output=True, timeout=5, check=True)
        return True
    except Exception:
        return False


def ensure_xvfb(display: str, screen: str):
    if xvfb_alive(display):
        return None
    p = subprocess.Popen(
        ["Xvfb", display, "-screen", "0", screen],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)
    time.sleep(1.5)
    if p.poll() is not None:
        sys.exit("error: Xvfb failed to start")
    return p


def kill_group(pid: int) -> None:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pid, sig)
        except (ProcessLookupError, PermissionError):
            return
        time.sleep(1.0)


def _proc_cmdline(pid: int) -> list:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
        return [part.decode(errors="replace")
                for part in raw.split(b"\0") if part]
    except OSError:
        return []


def _terminate_orphan(pid: int) -> None:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pid, sig)
        except (ProcessLookupError, PermissionError):
            return
        except OSError:
            try:
                os.kill(pid, sig)
            except (ProcessLookupError, PermissionError):
                return
        time.sleep(0.3)


def _cleanup_orphaned_helpers(tmp_root: Path, display_base: str,
                              screen: str = "") -> None:
    try:
        base_num = int(display_base.lstrip(":"))
    except ValueError:
        base_num = 99
    tool_displays = {f":{base_num + i}" for i in range(32)}
    killed_hatari = 0
    killed_xvfb = 0
    try:
        proc_entries = list(Path("/proc").iterdir())
    except OSError:
        return
    tmp_marker = str(tmp_root)
    for entry in proc_entries:
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        if pid == os.getpid():
            continue
        args = _proc_cmdline(pid)
        if not args:
            continue
        name = Path(args[0]).name.lower()
        cmdline = " ".join(args)
        # Hatari helpers are identified by their staging path (tmp_dir) in
        # the command line; Xvfb helpers by the tool's display range. The
        # earlier ppid==1 check missed helpers re-parented to a subreaper
        # (e.g. under a desktop session) or still attached to a parent that
        # was itself killed, which is exactly what happens after the kernel
        # OOM-kills a parallel run: the orphaned Hatari/Xvfb keep the
        # displays busy and the next run then fails to grab screenshots.
        # This runs before any worker starts, so matching only the tool's
        # own tmp_dir/displays cannot touch unrelated processes.
        if name == "hatari" and tmp_marker in cmdline:
            _terminate_orphan(pid)
            killed_hatari += 1
        elif (name == "xvfb" and len(args) >= 5 and args[1] in tool_displays
              and args[2] == "-screen" and args[4] == screen):
            _terminate_orphan(pid)
            killed_xvfb += 1
    if killed_hatari or killed_xvfb:
        print(f"cleaned orphaned helpers: {killed_hatari} hatari, "
              f"{killed_xvfb} Xvfb", flush=True)


def _ensure_tmp_dir(cfg: dict) -> Path:
    root = Path(str(cfg.get("tmp_dir") or "/tmp/marcer-shotgen"))
    try:
        root.mkdir(parents=True, exist_ok=True)
    except OSError as ex:
        sys.exit(f"error: cannot create tmp_dir {root}: {ex}")
    if not os.access(root, os.W_OK):
        sys.exit(f"error: tmp_dir is not writable: {root}")
    return root


def _cleanup_stale_stages(tmp_root: Path, cfg: dict) -> None:
    limits = cfg.get("resource_limits") or {}
    try:
        hours = float(limits.get("stale_stage_hours", 1))
    except (TypeError, ValueError):
        hours = 1.0
    cutoff = time.time() - max(0.0, hours) * 3600
    removed = 0
    for child in tmp_root.iterdir():
        if not child.is_dir() or not child.name.startswith("entry-"):
            continue
        try:
            if child.stat().st_mtime >= cutoff:
                continue
            shutil.rmtree(child, ignore_errors=True)
            if not child.exists():
                removed += 1
        except OSError:
            continue
    if removed:
        print(f"removed {removed} stale staging dirs", flush=True)


def _meminfo_mb(field: str) -> float:
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith(field + ":"):
                return float(line.split()[1]) / 1024.0
    except OSError:
        pass
    return 0.0


def _available_ram_mb() -> float:
    value = _meminfo_mb("MemAvailable")
    if value > 0:
        return value
    try:
        pages = os.sysconf("SC_AVPHYS_PAGES")
        page_size = os.sysconf("SC_PAGE_SIZE")
        return pages * page_size / (1024.0 * 1024.0)
    except (ValueError, OSError):
        return 0.0


def _effective_jobs(requested: int, cfg: dict, out_dir: Path,
                    tmp_root: Path):
    """Return ``(jobs, per_process_budget_mb)`` for the parallel run.

    The job count is capped from the RAM that has to stay free *plus* the
    swap headroom: a worker (Python thread + its Hatari child) settles at
    0.6-0.8 GB during the click retry, so an earlier 500 MB estimate let
    ``--jobs 8`` overcommit a small machine and the kernel OOM-killer
    reaped the whole process. ``SwapFree`` is added to the available RAM so
    a machine with a large swap file is not capped to a single worker, but
    ``min_free_mb`` still reserves enough for the rest of the system.
    Returns the resolved job count and the per-process RSS ceiling handed
    to ``configure_mem_guard`` (a share of the budget for one worker).
    """
    limits = cfg.get("resource_limits") or {}
    try:
        per_job = float(limits.get("per_job_mb", 800))
        min_free = float(limits.get("min_free_mb", 2000))
        min_disk = float(limits.get("min_disk_free_mb", 2048))
        guard_frac = float(limits.get("mem_guard_fraction", 1.5))
    except (TypeError, ValueError):
        per_job, min_free, min_disk, guard_frac = 800.0, 2000.0, 2048.0, 1.5
    available = _available_ram_mb()
    swap_free = _meminfo_mb("SwapFree")
    budget = available + swap_free
    try:
        disk_free = min(shutil.disk_usage(out_dir).free,
                        shutil.disk_usage(tmp_root).free) / (1024.0 * 1024.0)
    except OSError:
        disk_free = 0.0
    if disk_free < min_disk:
        sys.exit(f"error: not enough disk space ({disk_free:.0f} MB free, "
                 f"need {min_disk:.0f} MB)")
    if available < min_free:
        sys.exit(f"error: not enough free RAM ({available:.0f} MB available, "
                 f"need {min_free:.0f} MB)")
    if per_job <= 0:
        return max(1, requested), 0.0
    cap = max(1, int((budget - min_free) // per_job))
    jobs = min(max(1, requested), cap)
    if jobs < requested:
        print(f"jobs capped: requested {requested}, using {jobs} "
              f"({available:.0f} MB RAM + {swap_free:.0f} MB swap, "
              f"{per_job:.0f} MB per worker, {min_free:.0f} MB reserve)",
              flush=True)
    # Per-worker RSS ceiling for the correlation guard: half the estimated
    # worker footprint by default. The guard only trips on a genuine runaway
    # (a stalled FFT loop), so it is deliberately generous.
    guard_mb = max(per_job, per_job * guard_frac)
    return jobs, guard_mb


def sleep_until(t_target: float) -> bool:
    """Sleep in small steps, return False if STOP_EVENT fires."""
    while True:
        if STOP_EVENT is not None and STOP_EVENT.is_set():
            return False
        left = t_target - time.monotonic()
        if left <= 0:
            return True
        time.sleep(min(0.25, left))


# --------------------------------------------------------------------------
# image analysis
# --------------------------------------------------------------------------

def has_drive_led(rgb) -> bool:
    """Detect Hatari's floppy drive LED overlay.

    When the statusbar is hidden, Hatari paints a small green drive-LED
    rectangle in the top-right corner over an otherwise blank (white)
    screen. Such shots (documentation/manuals and some data disks) carry no
    game content.
    """
    import numpy as np
    a = np.asarray(rgb.convert("RGB"))
    h, w = a.shape[:2]
    if h < 20 or w < 40:
        return False
    ai = a.astype(int)
    white = (np.abs(ai - 238) < 12).all(axis=2).mean()
    if white < 0.9:
        return False
    green = (a[:, :, 1] > 150) & (a[:, :, 0] < 120) & (a[:, :, 2] < 120)
    if not green.any():
        return False
    ys, xs = np.where(green)
    return bool(xs.min() >= w * 0.9 and ys.max() <= h * 0.1)


def is_falcon_boot_logo(rgb, metrics: dict, cfg: dict) -> bool:
    """True for a Falcon TOS 4.04 boot screen.

    Two static stages are recognized: the white screen with the black
    Atari logo in the upper-left corner, and the plain Videl boot stage
    (solid green area plus white, no dark pixels). Both carry no
    information about the ZIP, but TOS keeps them visible long enough that
    they land on the early screenshot timepoints. The logo is matched by
    pHash (primary) with a geometry fallback for a changed crop/zoom:
    almost all white, at most two colours, and dark pixels confined to the
    top-left corner.
    """
    import numpy as np

    if metrics.get("kind") != "desktop":
        return False
    f = cfg.get("filters") or {}
    ref = str(f.get("falcon_boot_logo_phash") or "").strip()
    maxd = int(f.get("falcon_boot_logo_max_distance", 2))
    if ref:
        try:
            if phash_distance(metrics["phash"], ref) <= maxd:
                return True
        except Exception:
            pass
    # plain Videl boot stage: only pure green and white, no dark content
    if metrics.get("unique_colors", 99) <= 2:
        gf = metrics.get("green_frac", 0.0)
        wf = metrics.get("white_frac", 0.0)
        if (gf >= f.get("falcon_boot_logo_green_min", 0.20)
                and wf >= f.get("falcon_boot_logo_stage_white_min", 0.20)
                and gf + wf >= 0.95):
            a = np.asarray(rgb.convert("RGB")).astype(int)
            if not (a.sum(axis=2) < 200).any():
                return True
    if metrics.get("white_frac", 0.0) < f.get(
            "falcon_boot_logo_white_min", 0.98):
        return False
    if metrics.get("unique_colors", 1 << 30) > f.get(
            "falcon_boot_logo_max_colors", 2):
        return False
    a = np.asarray(rgb.convert("RGB")).astype(int)
    h, w = a.shape[:2]
    dark = a.sum(axis=2) < 200
    if not dark.any() or dark.mean() > 0.02:
        return False
    ys, xs = np.where(dark)
    return bool(xs.max() < w * f.get("falcon_boot_logo_max_x", 0.30)
                and ys.max() < h * f.get("falcon_boot_logo_max_y", 0.45))


def analyze_image(path: Path, cfg: dict,
                  detect_boot_logo: bool = False) -> dict:
    from PIL import Image, ImageFilter, ImageStat
    import imagehash

    img = Image.open(path)
    rgb = img.convert("RGB")
    small = rgb.resize((64, 64))
    raw = small.tobytes()
    n = len(raw) // 3
    green = 0
    for i in range(0, len(raw), 3):
        r, g, b = raw[i], raw[i + 1], raw[i + 2]
        if g > 160 and r < 120 and b < 120:
            green += 1
    colors_raw = rgb.getcolors(maxcolors=100000)
    n_colors = len(colors_raw) if colors_raw is not None else 100000
    gray = img.convert("L")
    stat = ImageStat.Stat(gray)
    mean = stat.mean[0] / 255.0
    std = stat.stddev[0]
    entropy = gray.entropy()
    edges = ImageStat.Stat(gray.filter(ImageFilter.FIND_EDGES)).mean[0]
    phash = str(imagehash.phash(rgb))
    drive_led = has_drive_led(rgb)

    f = cfg["filters"]
    # fraction of fully bright pixels (near-white background). Only the
    # desktop sub-classification (refine_desktop_kind) uses it; a
    # multi-color image (colors_raw is None) can never be textscreen.
    white_min = int(f.get("white_pixel_min", 230))
    if colors_raw is None:
        white_frac = 0.0
    else:
        white_px = sum(cnt for cnt, (r, g, b) in colors_raw
                       if r >= white_min and g >= white_min and b >= white_min)
        white_frac = white_px / (rgb.width * rgb.height)
    # A uniform image (any brightness: black boot screen, blank white
    # screen) is empty. A very dark shot only counts as empty while it
    # also lacks contrast — dark cracktros/intros with visible structure
    # (mean <= 0.02 but std well above the content threshold) must
    # survive as `game` shots (SPEC 8.1).
    if (std <= f["black_std_max"]
            or (mean <= f["black_mean_max"]
                and std <= f["black_std_content_min"])):
        kind = "black"
    elif (n_colors <= f["desktop_max_colors"]
          and (mean >= f["desktop_min_mean"]
               or green / n >= f["desktop_green_frac_min"])):
        kind = "desktop"
    else:
        kind = "game"

    w = cfg["score_weights"]
    score = (w["entropy"] * min(entropy / 8.0, 1.0)
             + w["colors"] * min(n_colors / 64.0, 1.0)
             + w["edges"] * min(edges / 64.0, 1.0))
    result = {"kind": kind, "mean": round(mean, 4), "std": round(std, 2),
              "entropy": round(entropy, 3), "unique_colors": n_colors,
              "edges": round(edges, 2), "green_frac": round(green / n, 4),
              "white_frac": round(white_frac, 4),
              "phash": phash, "score": round(score, 4),
              "drive_led": drive_led}
    if detect_boot_logo:
        result["boot_logo"] = is_falcon_boot_logo(rgb, result, cfg)
    return result


def refine_desktop_kind(kind: str, metrics: dict, cfg: dict) -> str:
    """Split the coarse ``desktop`` kind into finer entry categories.

    A shot classified ``desktop`` by analyze_image is either a real TOS
    desktop (green work surface), a crack intro / text screen on a light
    background, or one on a darker/colored background. Thresholds verified
    against the live index (SPEC section 8.4).

    Other kinds (``game``, ``black``) are returned unchanged.
    """
    if kind != "desktop":
        return kind
    f = cfg["filters"]
    if metrics.get("green_frac", 0.0) >= f["desktop_green_frac_min"]:
        return "desktop"
    if metrics.get("white_frac", 0.0) >= f["textscreen_min_white"]:
        return "textscreen"
    return "darkscreen"


def phash_distance(a: str, b: str) -> int:
    import imagehash
    return imagehash.hex_to_hash(a) - imagehash.hex_to_hash(b)


def pixel_signature(path: Path):
    """Return a pixel-exact signature of a PNG, or None if unreadable.

    The signature is ``(width, height, sha256(rgba_pixels))``: two files
    with the same signature show exactly the same pixels, even when their
    PNG compression or ancillary chunks differ. Used by
    ``cleanup-duplicates`` to remove only genuinely identical candidates.
    """
    try:
        from PIL import Image
        with Image.open(path) as im:
            im.load()
            rgba = im.convert("RGBA")
            return (rgba.size,
                    hashlib.sha256(rgba.tobytes()).hexdigest())
    except Exception:
        return None


# --------------------------------------------------------------------------
# click retry: icon detection and mouse control via XTest (xdotool)
# --------------------------------------------------------------------------

ASSETS_DIR = Path(__file__).resolve().parent / "assets"

# X pointer operations are global per display; serialize them across
# parallel workers so one worker's click cannot land in another
# worker's Hatari window.
CLICK_LOCK = threading.Lock()


def fifo_write(fifo: Path, cmd: str) -> None:
    # Non-blocking: a dead Hatari (crashed/exited) leaves no FIFO reader,
    # and a plain open("w") would block the worker forever. Raise OSError
    # (ENXIO) instead so the caller can mark the entry and stop on Ctrl+C.
    fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    try:
        os.write(fd, (cmd + "\n").encode("utf-8"))
    finally:
        os.close(fd)


def _xdotool(args, display: str, timeout: int = 10):
    return subprocess.run(["xdotool"] + args, capture_output=True,
                          text=True, timeout=timeout, check=True,
                          env={**os.environ, "DISPLAY": display})


def find_hatari_window(P: dict, grab_png: Path, pid: int = None):
    """Locate Hatari's SDL window via xdotool, matched by screenshot size.

    When ``pid`` is given (the running Hatari process), the window is
    resolved by process id so that parallel workers click into their own
    window instead of whichever window is found first. Returns (wid, kv)
    where kv holds X/Y/WIDTH/HEIGHT from the window geometry. Raises
    RuntimeError when no window can be found.
    """
    from PIL import Image
    with Image.open(grab_png) as im:
        shot_w, shot_h = im.size

    disp = P["display"]

    def _geometry(wid):
        geo = _xdotool(["getwindowgeometry", "--shell", wid], disp)
        return dict(line.split("=", 1)
                    for line in geo.stdout.splitlines() if "=" in line)

    with CLICK_LOCK:
        # preferred: ask xdotool for the windows of our own Hatari process
        if pid is not None:
            try:
                res = _xdotool(["search", "--all", "--class", "hatari",
                                "--pid", str(pid)], disp)
            except subprocess.CalledProcessError:
                res = None
            if res is not None:
                ids = [ln for ln in res.stdout.splitlines() if ln.strip()]
                best = None
                for wid in ids:
                    kv = _geometry(wid)
                    w, h = int(kv["WIDTH"]), int(kv["HEIGHT"])
                    dist = abs(w - shot_w) + abs(h - shot_h)
                    if best is None or dist < best[0]:
                        best = (dist, wid, kv)
                if best is not None:
                    return best[1], best[2]

        # fallback: scan all hatari windows, match by size, and prefer the
        # one whose _NET_WM_PID equals our pid
        res = _xdotool(["search", "--all", "--class", "hatari"], disp)
        ids = [line for line in res.stdout.splitlines() if line.strip()]
        best = None
        for wid in ids:
            kv = _geometry(wid)
            w, h = int(kv["WIDTH"]), int(kv["HEIGHT"])
            dist = abs(w - shot_w) + abs(h - shot_h)
            try:
                wp = _xdotool(["getwindowpid", wid], disp).stdout.strip()
                wp = int(wp) if wp else None
            except (subprocess.CalledProcessError, ValueError):
                wp = None
            same = (pid is not None and wp == pid)
            key = (0 if same else 1, dist)
            if best is None or key < best[0]:
                best = (key, wid, kv)
    if best is None:
        raise RuntimeError("no hatari window found via xdotool")
    return best[1], best[2]


def click_window_xy(P: dict, wid: str, kv: dict, shot_w: int, shot_h: int,
                    icon_sx: int, icon_sy: int, log, fifo: Path = None,
                    double: bool = True) -> None:
    """Click a screenshot pixel on a known Hatari window.

    The real X pointer is positioned via XTest (xdotool mousemove), then
    Hatari's own ``hatari-event doubleclick`` command is used for a double
    click: sending it through the emulator's input path is far more
    reliable than XTest clicks, which GEM often only registers as a single
    selection (verified live). A single click (``double=False``, needed for
    GEM gadgets such as the window "full size" box) has no FIFO control
    command in Hatari 2.4.1 and goes through XTest. The pointer is
    serialized under CLICK_LOCK across parallel workers because it is global
    per display.
    """
    disp = P["display"]
    wx, wy = int(kv["X"]), int(kv["Y"])
    ww, wh = int(kv["WIDTH"]), int(kv["HEIGHT"])
    x = wx + round(icon_sx * ww / shot_w)
    y = wy + round(icon_sy * wh / shot_h)
    with CLICK_LOCK:
        # raise and focus first: parallel workers share one display and
        # their windows overlap. Hatari's SDL only processes mouse motion
        # when its window has input focus, so focus must be set explicitly
        # (windowfocus uses XSetInputFocus and works without a WM).
        _xdotool(["windowraise", wid], disp)
        try:
            _xdotool(["windowfocus", wid], disp)
        except subprocess.CalledProcessError:
            pass
        # move with --sync so the pointer is guaranteed to be in place
        # before the click, but fall back to a plain move: --sync can block
        # indefinitely under Xvfb when the target equals the current pixel
        try:
            _xdotool(["mousemove", "--sync", str(x), str(y)], disp,
                     timeout=5)
        except subprocess.TimeoutExpired:
            _xdotool(["mousemove", str(x), str(y)], disp)
        time.sleep(0.4)
        if double and fifo is not None:
            fifo_write(fifo, "hatari-event doubleclick")
        elif not double:
            # no single-click control command in Hatari 2.4.1 (section 7.4):
            # a GEM gadget (full size box, scrollbar arrow) needs a single
            # XTest click
            _xdotool(["click", "1"], disp)
        else:
            _xdotool(["click", "--repeat", "2", "--delay", "30", "1"], disp)
        # GEM draws its mouse arrow into the framebuffer and it stays
        # where the click happened. Park the pointer on the empty part of
        # the window title bar before the next screenshot: otherwise the
        # arrow sits on the icon of the following window (the same grid
        # cell, e.g. the program icon below a folder icon) and destroys
        # the template match. The title bar row (screenshot y 182) is
        # outside every icon grid, so the arrow cannot cover an icon there.
        # Do NOT park near the screen/window edge: a warp to the border
        # (e.g. the bottom-right corner) makes Hatari's relative mouse
        # handling drift, after which every later click misses its icon
        # (verified live: tens of pixels of drift after such a warp).
        time.sleep(0.5)
        try:
            park_x = wx + round(400 * ww / shot_w)
            park_y = wy + round(182 * wh / shot_h)
            _xdotool(["mousemove", str(park_x), str(park_y)], disp,
                     timeout=5)
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
            pass
    log(f"doubleclick window={wid} at ({x},{y}) "
        f"[icon ({icon_sx},{icon_sy}) in {shot_w}x{shot_h}]")


def click_icon(P: dict, grab_png: Path, icon_sx: int, icon_sy: int,
               log, fifo: Path = None, pid: int = None,
               double: bool = True) -> None:
    """Double-click the detected icon on Hatari's SDL window.

    The grab screenshot provides the window content size so that the
    icon's screenshot pixel maps onto the X window.
    """
    from PIL import Image
    with Image.open(grab_png) as im:
        shot_w, shot_h = im.size
    wid, kv = find_hatari_window(P, grab_png, pid=pid)
    click_window_xy(P, wid, kv, shot_w, shot_h, icon_sx, icon_sy, log,
                    fifo=fifo, double=double)


def find_fullsize_xy(img_path: Path):
    """Screenshot pixel at the centre of the active window's "full size" box.

    The box sits in the title bar at the window's top right. Its glyph
    rendering differs between GEM modes (mono high res vs colour medium/low
    res), so it is not matched as a template, but its centre is detected from
    the window frame (position independent): the rightmost long vertical dark
    line is the window's right border; the box glyph is the rightmost compact
    dark block in the title bar band just left of that border. The click must
    land on the glyph centre — a few pixels to the right (near the border)
    misses the gadget. Returns (x, y) or None when no box glyph is found.
    """
    arr = load_gray(img_path)
    dark = arr < 128
    height, width = dark.shape
    min_run = max(60, height // 6)

    def longest(vec):
        best = best_start = cur = start = 0
        for i, v in enumerate(vec):
            if v:
                if cur == 0:
                    start = i
                cur += 1
                if cur > best:
                    best, best_start = cur, start
            else:
                cur = 0
        return best, best_start

    right_x = right_top = None
    for x in range(width - 1, -1, -1):
        length, start = longest(dark[:, x])
        if length >= min_run:
            right_x, right_top = x, start
            break
    if right_x is None:
        return None
    x_hi = max(0, right_x - 6)
    x_lo = max(0, right_x - 34)
    y_lo = min(height - 1, right_top + 4)
    y_hi = min(height, right_top + 16)
    colsum = dark[y_lo:y_hi, x_lo:x_hi + 1].sum(axis=0)
    cols = [i for i, c in enumerate(colsum) if c >= 3]
    if not cols:
        return None
    colset = set(cols)
    end = cols[-1]
    start = end
    while (start - 1) in colset:
        start -= 1
    return (x_lo + (start + end) // 2, (y_lo + y_hi) // 2)


def enlarge_window(P: dict, grab_png: Path, log, fifo: Path = None,
                   pid: int = None) -> bool:
    """Grow a too narrow GEM window by clicking its "full size" box.

    A folder view that shows more icons than fit its default width cuts
    the rightmost ones off (behind a horizontal scrollbar); the program to
    start can be among them, so the window is grown to the full work area
    to reveal every icon before the scan gives up. The box reacts to a
    *single* click; its position is detected from the window frame
    (find_fullsize_xy). Returns True when a click was sent.
    """
    from PIL import Image
    xy = find_fullsize_xy(grab_png)
    if xy is None:
        log("full size box not found, not enlarging")
        return False
    with Image.open(grab_png) as im:
        shot_w, shot_h = im.size
    wid, kv = find_hatari_window(P, grab_png, pid=pid)
    click_window_xy(P, wid, kv, shot_w, shot_h, xy[0], xy[1], log,
                    fifo=fifo, double=False)
    return True


def find_scroll_down_xy(img_path: Path):
    """Screenshot pixel of the active window's vertical scrollbar down arrow.

    A folder view shows far fewer icons than it contains, the rest hidden
    below behind a vertical scrollbar; the program to start can be among
    them. The down arrow sits in the innermost right column, one arrow
    height above the window bottom border. Detected from the window frame
    (position independent). Returns (x, y) or None.
    """
    arr = load_gray(img_path)
    dark = arr < 128
    height, width = dark.shape
    min_run = max(60, height // 6)

    def longest(vec):
        best = best_start = cur = start = 0
        for i, v in enumerate(vec):
            if v:
                if cur == 0:
                    start = i
                cur += 1
                if cur > best:
                    best, best_start = cur, start
            else:
                cur = 0
        return best, best_start

    right_x = right_top = None
    for x in range(width - 1, -1, -1):
        length, start = longest(dark[:, x])
        if length >= min_run:
            right_x, right_top = x, start
            break
    if right_x is None:
        return None
    bottom_y = None
    for y in range(height - 1, right_top, -1):
        length, start = longest(dark[y])
        if length >= min_run and right_x - 8 <= start + length - 1 <= right_x + 2:
            bottom_y = y
            break
    if bottom_y is None:
        return None
    return (max(1, right_x - 15), max(1, bottom_y - 30))


def scroll_window_down(P: dict, grab_png: Path, log, fifo: Path = None,
                       pid: int = None) -> bool:
    """Scroll the active window one step down via its scrollbar down arrow.

    Returns True when a click was sent.
    """
    from PIL import Image
    xy = find_scroll_down_xy(grab_png)
    if xy is None:
        log("scrollbar down arrow not found, not scrolling")
        return False
    with Image.open(grab_png) as im:
        shot_w, shot_h = im.size
    wid, kv = find_hatari_window(P, grab_png, pid=pid)
    click_window_xy(P, wid, kv, shot_w, shot_h, xy[0], xy[1], log,
                    fifo=fifo, double=False)
    return True


def find_menubar_xy(img_path: Path):
    """Screenshot pixel on the GEM menu bar (topmost row with menu text).

    Used to activate the front window before clicking its "full size" box:
    in some (headless SDL) setups the box only reacts once the window has
    been activated by a menu bar click. Returns (x, y) or None.
    """
    import numpy as np
    arr = load_gray(img_path)
    dark = arr < 128
    height, width = dark.shape
    for y in range(2, min(height, 130)):
        xs = np.nonzero(dark[y])[0]
        if len(xs) >= 40:
            return (int((int(xs.min()) + int(xs.max())) // 2), y)
    return None


def force_grow(P: dict, grab_png: Path, log, fifo: Path = None,
               pid: int = None) -> bool:
    """Grow the window when a plain box click was ignored by GEM.

    Fallback for setups where the "full size" box only reacts after the GEM
    window has been activated: click the menu bar to activate, then the box
    twice (the first click dismisses the menu, the second grows). Returns
    True when clicks were sent.
    """
    menu = find_menubar_xy(grab_png)
    box = find_fullsize_xy(grab_png)
    if menu is None or box is None:
        return False
    from PIL import Image
    with Image.open(grab_png) as im:
        shot_w, shot_h = im.size
    wid, kv = find_hatari_window(P, grab_png, pid=pid)
    log("box click had no effect, activating via menu bar and retrying")
    for sx, sy in (menu, box, box):
        click_window_xy(P, wid, kv, shot_w, shot_h, sx, sy, log,
                        fifo=fifo, double=False)
        time.sleep(1.0)
    return True


_GRAY_CACHE: dict = {}
_GRAY_CACHE_ORDER: deque = deque()
# The decoded arrays are float32 (~2.4 MB at 900x700) instead of float64
# (~5 MB): the templates only need a single-precision image and float32
# halves the retained cache. The cache is small because every parallel
# worker has its own process-global cache; 4 images is enough to cover the
# probe/timepoint revisits of one entry.
_GRAY_CACHE_MAX = 4

# Hard self-guard for the FFT correlation working set. ``process_entry``
# bails out of a stalled entry when tools.screenshot-gen's own RSS would
# otherwise grow into the machine OOM-killer; the limit is set per run via
# configure_mem_guard() from the effective RAM budget.
_MEM_GUARD_BYTES = 0


class MemoryGuardTripped(RuntimeError):
    """Raised when a worker's RSS exceeds the configured ceiling."""


def configure_mem_guard(budget_mb: float) -> None:
    """Set the per-process RSS ceiling for the FFT correlation guard."""
    global _MEM_GUARD_BYTES
    _MEM_GUARD_BYTES = max(0, int(budget_mb * 1024 * 1024))


def _self_rss_bytes() -> int:
    try:
        with open("/proc/self/statm") as fh:
            return int(fh.read().split()[1]) * os.sysconf("SC_PAGE_SIZE")
    except (OSError, IndexError, ValueError):
        return 0


def _mem_guard_tripped() -> bool:
    return _MEM_GUARD_BYTES > 0 and _self_rss_bytes() > _MEM_GUARD_BYTES


# glibc keeps freed memory in per-thread arenas; a long parallel run that
# allocates image-sized blocks in a dozen worker threads lets those arenas
# (each an mmap'd region, up to 8 by default) ratchet up as new size classes
# appear, so RSS climbs for hours even though the Python objects are gone
# (tracemalloc shows flat tracked memory and a flat gc-object count while
# RSS grows). Two mitigations: cap the arena count (env, set in main before
# the worker threads start) and return freed blocks to the OS with
# malloc_trim(0), which must run in the allocating thread.
_LIBC = None
_MALLOC_TRIM = None


def _init_malloc_trim() -> None:
    global _LIBC, _MALLOC_TRIM
    if _MALLOC_TRIM is not None:
        return
    try:
        import ctypes
        import ctypes.util
        _LIBC = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
        _MALLOC_TRIM = _LIBC.malloc_trim
        _MALLOC_TRIM.argtypes = [ctypes.c_size_t]
        _MALLOC_TRIM.restype = ctypes.c_int
    except Exception:
        _MALLOC_TRIM = None


def _malloc_trim() -> None:
    """Return freed heap blocks to the OS (call from the allocating thread)."""
    if _MALLOC_TRIM is None:
        _init_malloc_trim()
    if _MALLOC_TRIM is not None:
        try:
            _MALLOC_TRIM(0)
        except Exception:
            pass


# Optional leak diagnostics: with SHOTGEN_TRACEMALLOC=1 the tool starts
# tracemalloc and, every SHOTGEN_TRACEMALLOC_EVERY processed entries, logs
# the top allocation sites and the cumulative RSS. Used to locate the
# per-entry growth that pushes a long parallel run into the OOM killer.
_TRACEMALLOC_ON = os.environ.get("SHOTGEN_TRACEMALLOC") == "1"
_TRACEMALLOC_EVERY = int(os.environ.get("SHOTGEN_TRACEMALLOC_EVERY", "20") or 20)
_TRACEMALLOC_N = 0


def _maybe_trace_memory(tag: str) -> None:
    global _TRACEMALLOC_N
    if not _TRACEMALLOC_ON:
        return
    import tracemalloc
    _TRACEMALLOC_N += 1
    if _TRACEMALLOC_N % _TRACEMALLOC_EVERY != 0:
        return
    _dump_memory(tag)


def _dump_memory(tag: str) -> None:
    import gc
    import tracemalloc
    snap = tracemalloc.take_snapshot()
    total = sum(s.size for s in snap.statistics("filename"))
    counts: dict = {}
    for obj in gc.get_objects():
        counts[type(obj).__name__] = counts.get(type(obj).__name__, 0) + 1
    top_types = sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[:12]
    print(f"[memtrace] {tag} RSS={_self_rss_bytes() / 1048576:.0f} MB "
          f"traced={total / 1048576:.0f} MB "
          f"gc_objects={sum(counts.values())}", flush=True)
    print("[memtrace]   top types: " + ", ".join(
        f"{n}={c}" for n, c in top_types), flush=True)
    for stat in snap.statistics("lineno")[:8]:
        fr = stat.traceback[0]
        print(f"[memtrace]   {stat.size / 1048576:8.1f} MB "
              f"{fr.filename}:{fr.lineno}", flush=True)


def _install_memtrace_signal() -> None:
    """Dump a tracemalloc/gc snapshot on SIGUSR1 (diagnostic)."""
    if not _TRACEMALLOC_ON:
        return
    import signal as _signal

    def _handler(_sig, _frm):
        _dump_memory("SIGUSR1")

    _signal.signal(_signal.SIGUSR1, _handler)


# Leak hunt instrumentation (SHOTGEN_DIAG=1). A watchdog thread samples RSS,
# and every time it crosses a threshold it writes the top tracemalloc sites,
# the gc object-type counts and the stacks of *all* threads to SHOTGEN_DIAG_LOG
# (default /tmp/shotgen-diag.log). At SHOTGEN_DIAG_TRIPWIRE_MB it does a final
# dump and sets STOP_EVENT so the process shuts down cleanly instead of being
# reaped by the kernel OOM killer (which would lose the evidence). All thread
# stacks are the key data: they show which line a worker is stuck in while the
# memory climbs.
_DIAG_ON = os.environ.get("SHOTGEN_DIAG") == "1"
_DIAG_LOG = os.environ.get("SHOTGEN_DIAG_LOG", "/tmp/shotgen-diag.log")
try:
    _DIAG_TRIPWIRE_MB = float(
        os.environ.get("SHOTGEN_DIAG_TRIPWIRE_MB", "3500") or 3500)
    _DIAG_EVERY_S = float(os.environ.get("SHOTGEN_DIAG_EVERY", "10") or 10)
except ValueError:
    _DIAG_TRIPWIRE_MB, _DIAG_EVERY_S = 3500.0, 10.0
_DIAG_THRESHOLDS = [600, 900, 1200, 1600, 2000, 2500, 3000, 3500, 4000]


def _diag_write(text: str) -> None:
    try:
        with open(_DIAG_LOG, "a", encoding="utf-8") as fh:
            fh.write(text.rstrip("\n") + "\n")
    except OSError:
        pass


def _diag_dump(tag: str) -> None:
    import faulthandler
    import gc
    import tracemalloc
    rss = _self_rss_bytes() / 1048576
    stamp = time.strftime("%H:%M:%S")
    _diag_write(f"\n===== {stamp} {tag} RSS={rss:.0f} MB =====")
    try:
        snap = tracemalloc.take_snapshot()
        for st in snap.statistics("lineno")[:15]:
            fr = st.traceback[0]
            _diag_write(f"  ALLOC {st.size / 1048576:9.1f} MB  "
                        f"{fr.filename}:{fr.lineno}")
    except Exception as ex:
        _diag_write(f"  alloc snapshot failed: {ex}")
    try:
        counts: dict = {}
        for obj in gc.get_objects():
            counts[type(obj).__name__] = counts.get(type(obj).__name__, 0) + 1
        top = sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[:15]
        _diag_write("  OBJECTS " + ", ".join(f"{n}={c}" for n, c in top))
    except Exception as ex:
        _diag_write(f"  gc count failed: {ex}")
    try:
        with open(_DIAG_LOG, "a", encoding="utf-8") as fh:
            fh.write(f"----- {stamp} {tag} THREAD STACKS -----\n")
            faulthandler.dump_traceback(file=fh, all_threads=True)
    except Exception as ex:
        _diag_write(f"  thread dump failed: {ex}")


def _start_diagnostics() -> None:
    if not _DIAG_ON:
        return
    import faulthandler
    # NOTE: tracemalloc is intentionally NOT started here. It slows every
    # allocation in the run by ~6x, which would push the growth region hours
    # away. The cheap faulthandler all-thread stack dumps run from the start;
    # tracemalloc is started lazily at the first RSS threshold (see watchdog),
    # so it only records from the point the leak becomes visible.
    try:
        fh = open(_DIAG_LOG, "a", encoding="utf-8")
        fh.write(f"\n### diagnostics started {time.strftime('%H:%M:%S')} "
                 f"tripwire={_DIAG_TRIPWIRE_MB:.0f}MB\n")
        fh.flush()
        faulthandler.dump_traceback_later(
            float(os.environ.get("SHOTGEN_DIAG_STACKS_EVERY", "30")),
            repeat=True, file=fh)
    except Exception:
        pass

    def watchdog():
        import tracemalloc
        i = 0
        while True:
            if STOP_EVENT is not None and STOP_EVENT.is_set():
                _diag_dump("stop-event")
                return
            rss = _self_rss_bytes() / 1048576
            if i < len(_DIAG_THRESHOLDS) and rss >= _DIAG_THRESHOLDS[i]:
                if not tracemalloc.is_tracing():
                    tracemalloc.start(25)
                    _diag_write(f"### tracemalloc started at "
                                f"{rss:.0f}MB")
                tag = f"cross {_DIAG_THRESHOLDS[i]}MB"
                i += 1
                _diag_dump(tag)
            if rss >= _DIAG_TRIPWIRE_MB:
                _diag_write(f"### tripwire {rss:.0f}MB >= "
                            f"{_DIAG_TRIPWIRE_MB:.0f}MB -> STOP")
                _diag_dump("tripwire")
                if STOP_EVENT is not None:
                    STOP_EVENT.set()
                return
            time.sleep(_DIAG_EVERY_S)

    threading.Thread(target=watchdog, name="diag-watchdog",
                     daemon=True).start()


def load_gray(img_path: Path):
    """Load a screenshot as a float32 grayscale array, cached by mtime/size.

    find_icon probes several templates/variants against the same image and a
    retry run revisits one preview across timepoints; re-decoding a ~832x552
    PNG from the (often network) archive for every call dominated the detect
    runtime, so the last few decoded images are kept (LRU, bounded).
    """
    import numpy as np
    from PIL import Image

    key = str(img_path)
    try:
        st = os.stat(key)
        sig = (st.st_mtime_ns, st.st_size)
    except OSError:
        sig = None
    cached = _GRAY_CACHE.get(key)
    if cached is not None and cached[0] == sig:
        return cached[1]
    with Image.open(img_path) as im:
        arr = np.asarray(im.convert("L"), dtype=np.float32)
    _GRAY_CACHE[key] = (sig, arr)
    _GRAY_CACHE_ORDER.append(key)
    while len(_GRAY_CACHE_ORDER) > _GRAY_CACHE_MAX:
        _GRAY_CACHE.pop(_GRAY_CACHE_ORDER.popleft(), None)
    return arr


def _box_sums(img):
    """Return ``(s1, s2)`` boundary arrays for the running sums of the image.

    ``s1`` is the 2-D cumulative sum of the image and ``s2`` of its square,
    padded with a leading zero row/column so a box sum at any position is a
    four-corner lookup (``s[y+h, x+w] - s[y, x+w] - s[y+h, x] + s[y, x]``).
    Computing the window sums from these prefix arrays instead of via two
    additional ``fftconvolve`` calls with a full-size ``ones`` kernel keeps
    the peak memory at a fraction of the previous implementation: the
    convolution engine materialised several float64 arrays the size of the
    image (plus the FFT working set) for every template variant, which
    pushed a worker's RSS to 0.6-0.8 GB and let the OOM-killer reap the
    whole parallel run.
    """
    import numpy as np

    work = np.empty(img.shape, dtype=np.float64)
    s1 = np.zeros((img.shape[0] + 1, img.shape[1] + 1), dtype=np.float64)
    np.cumsum(img, axis=0, out=work)
    np.cumsum(work, axis=1, out=work)
    s1[1:, 1:] = work
    np.square(img, out=work)
    np.cumsum(work, axis=0, out=work)
    np.cumsum(work, axis=1, out=work)
    s2 = np.zeros((img.shape[0] + 1, img.shape[1] + 1), dtype=np.float64)
    s2[1:, 1:] = work
    return s1, s2


def _template_ncc_maps(img, t_base):
    """Yield ``(ncc, th, tw)`` maps for the template and its inverse.

    Memory-conscious implementation: one real FFT of the image is cached
    and reused for both the forward and the inverse template (only the
    small kernel transform is redone), the local mean/variance come from
    prefix sums instead of ``ones``-kernel convolutions and every full-size
    intermediate is reused in place. The caller iterates further (several
    templates per position), so the yielded map is the only new allocation.
    """
    import numpy as np

    fh, fw = img.shape
    fft_shape = (fh, fw)
    img_f = np.fft.rfft2(img.astype(np.float64, copy=False), s=fft_shape)
    s1, s2 = _box_sums(img)

    for t_img in (t_base, 255.0 - t_base):
        # Abort the match (and let the entry finish as click-failed) before
        # the FFT working set can drive the process into the kernel OOM
        # killer. The check is cheap (one /proc read per template variant).
        if _mem_guard_tripped():
            raise MemoryGuardTripped(
                f"RSS {_self_rss_bytes() / 1048576:.0f} MB exceeds "
                f"{_MEM_GUARD_BYTES / 1048576:.0f} MB guard")
        th, tw = t_img.shape
        if fh < th or fw < tw:
            continue
        t = t_img.astype(np.float64, copy=True)
        t -= t.mean()
        t_energy = float(np.square(t).sum())
        # convolve with the reversed template, exactly like the previous
        # ``fftconvolve(img, t[::-1, ::-1], mode="valid")``
        kern = t[::-1, ::-1]
        kern_f = np.fft.rfft2(kern, s=fft_shape)
        num = np.fft.irfft2(img_f * kern_f, s=fft_shape)
        num = num[th - 1:fh, tw - 1:fw]

        n = th * tw
        # windowed sums via the prefix arrays, then reuse ``num`` for var
        sums = (s1[th:, tw:] - s1[:-th, tw:] - s1[th:, :-tw] + s1[:-th, :-tw])
        sumsq = (s2[th:, tw:] - s2[:-th, tw:] - s2[th:, :-tw] + s2[:-th, :-tw])
        var = sums * sums
        var /= n
        np.subtract(sumsq, var, out=var)
        # flat/low-contrast windows make den tiny and amplify noise into
        # spurious mid scores: require at least 5% of the template contrast
        # energy, otherwise force invalid
        contrast = var >= 0.05 * t_energy
        np.maximum(var, 1e-9, out=var)
        var *= t_energy
        np.sqrt(var, out=var)
        np.divide(num, var, out=num, where=contrast)
        num[~contrast] = -1.0
        np.nan_to_num(num, copy=False, nan=-1.0, posinf=-1.0, neginf=-1.0)
        del sums, sumsq, var, kern_f, kern, t
        yield num, th, tw


def find_template(img_path: Path, template, min_score: float):
    """Zero-mean normalized cross correlation (FFT) against a template.

    Also tries the inverted template so that inverted (selected) GEM icons
    still match. Returns (cx, cy, score) at the template center, or None.
    """
    import numpy as np

    img = load_gray(img_path)
    t_base = np.asarray(template, dtype=np.float64)
    best = None
    for ncc, th, tw in _template_ncc_maps(img, t_base):
        iy, ix = np.unravel_index(int(np.argmax(ncc)), ncc.shape)
        score = float(np.clip(ncc[iy, ix], -1.0, 1.0))
        if best is None or score > best[2]:
            best = (int(ix + tw // 2), int(iy + th // 2), score)
    if best is None or best[2] < min_score:
        return None
    return best


def find_template_peaks(img_path: Path, template, min_score: float,
                        max_peaks: int = 12, min_distance: int = 12):
    """Find multiple template matches, suppressing neighbours of a hit.

    Returns ``[(cx, cy, score)]`` sorted by score (best first).
    """
    import numpy as np

    img = load_gray(img_path)
    t_base = np.asarray(template, dtype=np.float64)
    hits = []
    for ncc, th, tw in _template_ncc_maps(img, t_base):
        ys, xs = np.where(ncc >= min_score)
        if len(xs) == 0:
            continue
        scores = ncc[ys, xs]
        accepted = []
        for idx in np.argsort(scores)[::-1]:
            if len(accepted) >= max_peaks:
                break
            cx = int(xs[idx] + tw // 2)
            cy = int(ys[idx] + th // 2)
            if all(abs(cx - a[0]) > min_distance
                   or abs(cy - a[1]) > min_distance for a in accepted):
                accepted.append((cx, cy, float(scores[idx])))
        hits.extend(accepted)
    hits.sort(key=lambda h: h[2], reverse=True)
    return hits[:max_peaks]


def find_icons(path: Path, cfg: dict, template: str, limit: int = 8,
               min_score: float = None):
    """Find multiple icons of one template, best scale per position.

    Returns ``[{"sx", "sy", "score", "scale"}]`` sorted by score.
    """
    if min_score is None:
        min_score = cfg["click_retry"]["icon_min_score"]
    merged = []
    for scale, tpl in icon_variants(template):
        for cx, cy, score in find_template_peaks(
                path, tpl, min_score, max_peaks=limit * 2,
                min_distance=12):
            hit = {"sx": cx, "sy": cy, "score": score, "scale": scale}
            for i, old in enumerate(merged):
                if (abs(cx - old["sx"]) <= 12
                        and abs(cy - old["sy"]) <= 12):
                    if score > old["score"] + _VARIANT_MARGIN:
                        merged[i] = hit
                    break
            else:
                merged.append(hit)
    merged.sort(key=lambda h: h["score"], reverse=True)
    return merged[:limit]


ICON_TEMPLATE_FILES = {
    "prg": "icon-prg.png",          # program icon (desktop and in a window)
    "drive": "icon-drive.png",      # DISKSTATION drive icon on the desktop
    "folder": "icon-folder.png",    # folder icon inside a window
}

# Icon template variants, built once per process. Color screenshots render
# the GEM screen at 2x (the templates were cut from them), so their icons
# are twice the size of those in native mono high-res screenshots
# (`--mono --tos-res high`, 640x400 at 1x). The 0.5x variant is binarized
# so only the black/white structure matches: the drive template's green fill
# (0,238,0 -> grey ~140) would otherwise correlate poorly against the
# dithered mono background (binarizing maps it to white).
_ICON_VARIANTS: dict = {}

# A smaller-scale variant must beat the 1x match by this margin before it
# takes over: on color screenshots the 0.5x binarized template can tie a
# weak 1x false positive (~0.66) at a different pixel, which would silently
# shift an established click point. A genuine mono icon wins by a wide
# margin because its 1x match stays below icon_min_score.
_VARIANT_MARGIN = 0.02


def icon_variants(template: str):
    """Return [(scale, PIL.Image)] candidates for a named icon template."""
    if template not in _ICON_VARIANTS:
        variants = []
        tpl_name = ICON_TEMPLATE_FILES.get(template)
        tpl_path = ASSETS_DIR / tpl_name if tpl_name else None
        if tpl_path is not None and tpl_path.exists():
            import numpy as np
            from PIL import Image
            with Image.open(tpl_path) as tpl:
                gray = tpl.convert("L")
                full = np.asarray(gray, dtype=np.float64)
                half = np.asarray(gray.resize(
                    (max(1, gray.width // 2), max(1, gray.height // 2)),
                    Image.LANCZOS), dtype=np.float64)
            variants.append((1.0, Image.fromarray(full.astype(np.uint8))))
            variants.append((
                0.5, Image.fromarray(
                    np.where(half >= 128, 255.0, 0.0).astype(np.uint8))))
        _ICON_VARIANTS[template] = variants
    return _ICON_VARIANTS[template]


def find_icon(path: Path, cfg: dict, template: str = "prg"):
    """Locate a GEM icon in a screenshot via NCC.

    template: "prg" (program icon), "drive" (DISKSTATION drive icon) or
    "folder" (folder icon inside a window). Every template is tried at the
    1x color scale and as a 0.5x binarized variant (mono high-res); the
    best-scoring variant wins, but a smaller scale must beat the larger one
    by _VARIANT_MARGIN. Returns {"sx", "sy", "score", "scale"} (screenshot
    pixel, template center) or None.
    """
    min_score = cfg["click_retry"]["icon_min_score"]
    best = None
    for scale, tpl in icon_variants(template):
        res = find_template(path, tpl, min_score)
        if res is None:
            continue
        cx, cy, score = res
        if best is None or score > best[2] + _VARIANT_MARGIN:
            best = (cx, cy, score, scale)
    if best is None:
        return None
    cx, cy, score, scale = best
    return {"sx": cx, "sy": cy, "score": round(score, 3), "scale": scale}


TTP_TEMPLATE_FILES = (
    "ttp-dialog-title.png",    # "ANWENDUNG ÖFFNEN" title row
    "ttp-dialog-buttons.png",  # OK / ABBRUCH button row
)
TTP_TEMPLATE_MIN_SCORE = 0.90
_TTP_TEMPLATES: list = []


def ttp_templates():
    """Return the cached grayscale templates of the TTP command dialog."""
    if not _TTP_TEMPLATES:
        from PIL import Image
        for name in TTP_TEMPLATE_FILES:
            path = ASSETS_DIR / name
            if not path.exists():
                continue
            with Image.open(path) as tpl:
                _TTP_TEMPLATES.append(tpl.convert("L").copy())
    return _TTP_TEMPLATES


def is_ttp_dialog(path: Path) -> bool:
    """True when the screenshot shows GEM's TTP command-line dialog.

    Double-clicking a ``.TTP`` program opens GEM's "ANWENDUNG ÖFFNEN"
    dialog (Name/Parameter/OK/ABBRUCH). The dialog is an open window, so
    the generic open-window rule would mistake it for an application
    screen. The title and button rows are fixed (only the Name/Parameter
    values vary), so template matching identifies it reliably.
    """
    for template in ttp_templates():
        if find_template(path, template, TTP_TEMPLATE_MIN_SCORE) is not None:
            return True
    return False


TTP_ABORT_TEMPLATE_FILE = "ttp-dialog-abort.png"
_TTP_ABORT_TEMPLATE: list = []


def ttp_abort_template():
    """Return the cached template of the TTP dialog's ABBRUCH button."""
    if not _TTP_ABORT_TEMPLATE:
        from PIL import Image
        path = ASSETS_DIR / TTP_ABORT_TEMPLATE_FILE
        if path.exists():
            with Image.open(path) as tpl:
                _TTP_ABORT_TEMPLATE.append(tpl.convert("L").copy())
    return _TTP_ABORT_TEMPLATE


def find_ttp_abort_xy(path: Path):
    """Screenshot pixel of the ABBRUCH button in a TTP dialog, or None."""
    for template in ttp_abort_template():
        res = find_template(path, template, TTP_TEMPLATE_MIN_SCORE)
        if res is not None:
            return res[0], res[1]
    return None


GEM_FILE_WINDOW_TEMPLATE = "gem-file-window.png"
GEM_FILE_WINDOW_MIN_SCORE = 0.90
_GEM_FILE_WINDOW: list = []
# pHash of the plain mono TOS 1.04 desktop (no window). It is stable across
# entries; candidates with this hash are the old preview / plain desktop.
PLAIN_DESKTOP_PHASHES = {"ffbf9c9c9c888088"}


def gem_file_window_template():
    """Return the cached title-path template of a GEM file window."""
    if not _GEM_FILE_WINDOW:
        from PIL import Image
        path = ASSETS_DIR / GEM_FILE_WINDOW_TEMPLATE
        if path.exists():
            with Image.open(path) as tpl:
                _GEM_FILE_WINDOW.append(tpl.convert("L").copy())
    return _GEM_FILE_WINDOW


def is_gem_file_window(path: Path) -> bool:
    """True for a GEM drive/folder (file) window.

    The window title contains the ``A:\\`` drive path; the crop is fixed
    across drive/folder windows and does not match application windows or
    the TTP dialog. Used to avoid promoting the drive/folder window that
    the click retry opened instead of the application screen.
    """
    for template in gem_file_window_template():
        if find_template(path, template,
                         GEM_FILE_WINDOW_MIN_SCORE) is not None:
            return True
    return False


def find_desktop_click(path: Path, cfg: dict):
    """Pick the click strategy and icon for a desktop screenshot.

    prefers a program icon (single click, game starts directly). If no
    program icon is found (or only a weak false-positive), falls back to
    the disk drive icon ("drive" strategy: open DISKSTATION A first, then
    click the PRG that appears in the opened window).

    Returns {"strategy": "prg"|"drive", "sx", "sy", "score"} or None.
    """
    prg = find_icon(path, cfg, "prg")
    drv = find_icon(path, cfg, "drive")
    # a real program icon scores ~1.0 and always wins; a lone drive beats
    # a weak prg false-positive (flat-region peaks ~0.66)
    if prg and drv:
        if prg["score"] >= drv["score"]:
            return {"strategy": "prg", **prg}
        return {"strategy": "drive", **drv}
    if prg:
        return {"strategy": "prg", **prg}
    if drv:
        return {"strategy": "drive", **drv}
    return None


# --------------------------------------------------------------------------
# entry processing
# --------------------------------------------------------------------------

def safe_filename(name: str) -> str:
    return re.sub(r'[:?*"\x00-\x1f]', "_", name)


def metadata_path(mirror: Path, base: str):
    """Locate the per-entry metadata JSON for a mirror directory.

    The canonical name is ``<base>.json``. On a case-insensitive mirror
    (e.g. a Synology SMB share) that name is impossible when a sibling
    entry differs only in case: the NAS silently renames the written file
    to ``<base>_DiskStation_…CaseConflict.json``. Those conflict files
    carry the same metadata, so fall back to the single one of them.
    """
    canonical = mirror / f"{base}.json"
    if canonical.is_file():
        return canonical
    conflicts = sorted(mirror.glob(f"{base}*CaseConflict.json"))
    if len(conflicts) == 1:
        return conflicts[0]
    return None


def drop_case_variants(mirror_dir: Path, names) -> None:
    """Delete mirror files that differ from ``names`` only in case.

    After the case-insensitive overlay merge (SPEC §7) every entry owns
    exactly one spelling; a file under the other spelling belongs to a
    merged-away entry. Writing a differently-cased sibling would make a
    case-insensitive NAS rename the new file (…CaseConflict), so remove
    the stale one first. Exact-name files are left to the caller (they
    are handled by the keep-candidates logic).
    """
    wanted = {n.lower() for n in names}
    exact = set(names)
    try:
        for f in mirror_dir.iterdir():
            if f.name.lower() in wanted and f.name not in exact:
                f.unlink(missing_ok=True)
    except OSError:
        pass


def find_window_icons(path: Path, cfg: dict, template: str,
                      limit: int = 12):
    """Find all GEM window icons of one template with the window threshold.

    Window icons match their templates near 1.0, so a dedicated higher
    threshold rejects the flat-region false positives (~0.55) that appear
    on white window areas; the same bar applies to the 0.5x mono variant,
    whose genuine icons still score ~1.0 (a folder lightly matching the
    program template only reaches ~0.73 and must not override its own
    stronger folder match).
    """
    min_score = cfg["click_retry"].get("window_icon_min_score", 0.80)
    return find_icons(path, cfg, template, limit=limit, min_score=min_score)


def find_window_icon(path: Path, cfg: dict, template: str):
    """Find the best GEM window icon (first of :func:`find_window_icons`)."""
    hits = find_window_icons(path, cfg, template)
    return hits[0] if hits else None


def find_window_target(path: Path, cfg: dict):
    """Find the next double-click target inside an opened GEM window.

    The program icon (icon-prg, the same icon as on the desktop) is
    searched first and double clicked right away when it is present. Only
    when no program icon is found is the folder icon (icon-folder) looked
    up; after descending into the folder the window is scanned again for
    a program icon. Returns ("prg"|"folder", {sx, sy, score}) or None.
    """
    prg = find_window_icon(path, cfg, "prg")
    if prg is not None:
        return "prg", prg
    fo = find_window_icon(path, cfg, "folder")
    if fo is not None:
        return "folder", fo
    return None


def window_is_open(path: Path) -> bool:
    """True when the screenshot shows an open GEM window.

    A window is recognized by its title-bar "full size" gadget or, as a
    fallback for unusual window frames, by its vertical scrollbar. Plain
    desktop icon grids (drive/program icons on the work surface) do not
    match either detector.
    """
    return find_fullsize_xy(path) is not None \
        or find_scroll_down_xy(path) is not None


def _grab_now(fifo: Path, outdir: Path, wait: float = 2.0):
    """Request a fresh Hatari screenshot and return its path (or None)."""
    before = sorted(outdir.glob("*.png"))
    try:
        fifo_write(fifo, "hatari-shortcut screenshot")
    except OSError:
        return None
    if not sleep_until(time.monotonic() + wait):
        return None
    after = sorted(outdir.glob("*.png"))
    if len(after) > len(before):
        return after[-1]
    return after[-1] if after else None


def _screen_changed(a: Path, b: Path, frac: float = 0.02) -> bool:
    """True when two screenshots differ by more than ``frac`` of pixels."""
    if a is None or b is None or a == b:
        return False
    import numpy as np
    from PIL import Image
    try:
        ia = np.asarray(Image.open(a).convert("L"), dtype=np.int16)
        ib = np.asarray(Image.open(b).convert("L"), dtype=np.int16)
    except Exception:
        return False
    if ia.shape != ib.shape:
        return True
    return float((np.abs(ia - ib) > 30).mean()) > frac


def _folder_click_state(before: Path, after: Path, cfg: dict,
                        clicked_sx: int, clicked_sy: int) -> str:
    """Classify what a folder double click did.

    GEM sometimes registers the double click only as a selection (the
    folder icon inverts, the window content stays the same) and a second
    double click is needed to actually open it. A plain global pixel diff
    is not enough to tell the two apart: opening a folder changes only a
    few percent of the screen when the folder window looks similar to its
    parent (both are white GEM windows), which is the same order as a mere
    selection. The icon templates do distinguish them though: after a real
    open a genuine program icon (~1.0) appears at the clicked spot, while
    a selection leaves the (inverted) folder there, which only scores as a
    weak program match (~0.86).

    Returns "program" (the game started directly, no GEM icon is left),
    "opened" (the window descended) or "not-opened" (only a selection).
    """
    if _screen_changed(before, after):
        # the whole window changed: either the folder opened (a program or
        # folder icon is visible) or the game started (no GEM icon left)
        return ("program" if find_window_target(after, cfg) is None
                else "opened")
    target = find_window_target(after, cfg)
    if target is None:
        return "not-opened"
    kind, hit = target
    same_spot = (abs(hit["sx"] - clicked_sx) <= 8
                 and abs(hit["sy"] - clicked_sy) <= 8)
    if kind == "prg" and hit["score"] >= 0.95:
        # a genuine program icon appeared where the folder was
        return "opened"
    if same_spot:
        # only a selection: the folder icon is still at the clicked spot
        # (inverted, so it may score as a weak program match)
        return "not-opened"
    # an icon at a different position: the window content changed
    return "opened"


def cancel_ttp_dialog(P, cfg, shot, log, fifo, outdir, pid: int = None):
    """Click ABBRUCH in the TTP command dialog.

    Returns ``(cancelled, last_screenshot)``. Retries up to
    ``click_retry.ttp_cancel_attempts`` times; a missing button or a dialog
    that stays open returns False so the caller can abort the chain.
    """
    attempts = int(cfg.get("click_retry", {}).get(
        "ttp_cancel_attempts", 2))
    current = shot
    for attempt in range(1, attempts + 1):
        xy = find_ttp_abort_xy(current)
        if xy is None:
            log("TTP ABBRUCH button not found")
            return False, current
        log(f"TTP ABBRUCH click attempt {attempt}")
        click_icon(P, current, xy[0], xy[1], log, fifo=fifo, pid=pid,
                   double=False)
        if not sleep_until(time.monotonic() + 2.0):
            return False, current
        new_shot = _grab_now(fifo, outdir, 2.0) or current
        if not is_ttp_dialog(new_shot):
            log("TTP dialog cancelled")
            return True, new_shot
        current = new_shot
    log("TTP dialog did not close")
    return False, current


def perform_click_chain(P, cfg, click_cfg, click_info, fifo, outdir,
                        grabs, log, pid: int = None,
                        allow_enlarge: bool = False):
    """Execute the click sequence for a desktop retry.

    prg: one double click on the program icon (game starts directly).
    drive: double click DISKSTATION A, verify the window opened, then
           descend into the window: click the program icon if present, or
           open a folder and look again (bounded by drive_max_depth).

    ``pid`` is the running Hatari process, used to resolve its own window
    when parallel workers share one X display. ``allow_enlarge`` enables the
    "full size" fallback: when an opened window shows no usable icon, the
    window is grown once so icons cut off at its right edge become visible
    (section 7.4).

    returns (clicked, last_grab, chain_shots, result):
      clicked     - True when a program start was confirmed
      last_grab   - most recent screenshot path (window sizing)
      chain_shots - every screenshot taken during the chain, in order
                    (for candidate retention)
      result      - "click-icon-prg" | "click-icon-drive" | "click-failed"
    """
    strategy = click_info.get("strategy", "prg")
    chain_shots = list(grabs)

    step_wait = float(click_cfg.get("step_wait", 2.0))
    max_depth = int(click_cfg.get("drive_max_depth", 2))
    do_enlarge = bool(allow_enlarge and click_cfg.get("enlarge_window", True))
    scroll_attempts = int(click_cfg.get("scroll_attempts", 4))
    grew = [False]

    def _reveal_rescan(shot):
        """Reveal hidden icons and rescan for a program/folder icon.

        First grow a too narrow window (the mono high-res profile opens at
        half width, pushing the program behind a horizontal scrollbar), then
        scroll a window that hides icons below (the colour profile shows far
        fewer icons than it contains behind a vertical scrollbar).
        """
        def grab(prev):
            if not sleep_until(time.monotonic() + step_wait):
                return prev, None
            grown = _grab_now(fifo, outdir, 2.0) or prev
            chain_shots.append(grown)
            return grown, find_window_target(grown, cfg)

        # GEM's "full size" box toggles, so it must be clicked exactly once
        # per entry: a second grow click would restore the window.
        if do_enlarge and not grew[0]:
            grew[0] = True
            before = shot
            if enlarge_window(P, shot, log, fifo=fifo, pid=pid):
                shot, target = grab(shot)
                if target is not None:
                    return shot, target
                # some setups ignore the first box click until the window is
                # activated: retry via the menu bar when nothing changed
                if not _screen_changed(before, shot) \
                        and force_grow(P, shot, log, fifo=fifo, pid=pid):
                    shot, target = grab(shot)
                    if target is not None:
                        return shot, target
        for _ in range(scroll_attempts):
            if not scroll_window_down(P, shot, log, fifo=fifo, pid=pid):
                break
            shot, target = grab(shot)
            if target is not None:
                return shot, target
        return shot, None

    def _try_prgs(shot, depth):
        """Try every program icon in the current window.

        TTP launchers open GEM's command-line dialog: click ABBRUCH, mark
        that icon as tried and continue with the next program icon.
        Returns (started, last_shot, result).
        """
        max_icons = int(click_cfg.get("max_icon_attempts", 8))
        prg_attempts = int(click_cfg.get("prg_attempts", 3))
        hits = find_window_icons(shot, cfg, "prg", limit=max_icons)
        hits.sort(key=lambda h: (h["sy"], h["sx"]))
        tried = []
        for idx, hit in enumerate(hits[:max_icons], 1):
            if any(abs(hit["sx"] - x) <= 8 and abs(hit["sy"] - y) <= 8
                   for x, y in tried):
                continue
            tried.append((hit["sx"], hit["sy"]))
            for pa in range(1, prg_attempts + 1):
                before = shot
                click_icon(P, shot, hit["sx"], hit["sy"], log,
                           fifo=fifo, pid=pid)
                if not sleep_until(time.monotonic() + step_wait):
                    return False, shot, "click-failed"
                new_shot = _grab_now(fifo, outdir, 2.0) or shot
                chain_shots.append(new_shot)
                if is_ttp_dialog(new_shot):
                    log(f"TTP dialog after program icon {idx} at depth "
                        f"{depth}; cancelling")
                    cancelled, new_shot = cancel_ttp_dialog(
                        P, cfg, new_shot, log, fifo, outdir, pid=pid)
                    chain_shots.append(new_shot)
                    if not cancelled:
                        log("TTP ABBRUCH failed; aborting click chain")
                        return False, new_shot, "click-failed"
                    shot = new_shot
                    break
                if _screen_changed(before, new_shot):
                    log(f"program started at depth {depth} "
                        f"(icon {idx}, attempt {pa})")
                    return True, new_shot, "click-icon-drive"
                log(f"program icon {idx} did not start (attempt {pa}), "
                    f"retrying")
        return False, shot, None

    if strategy == "prg":
        before = grabs[-1]
        attempts = int(click_cfg.get("prg_attempts", 3))
        for pa in range(1, attempts + 1):
            click_icon(P, before, click_info["sx"], click_info["sy"], log,
                       fifo=fifo, pid=pid)
            if not sleep_until(time.monotonic() + 2.0):
                return False, before, chain_shots, "click-failed"
            new_shot = _grab_now(fifo, outdir, 2.0) or before
            chain_shots.append(new_shot)
            if is_ttp_dialog(new_shot):
                log("TTP dialog after desktop program icon; cancelling")
                cancelled, new_shot = cancel_ttp_dialog(
                    P, cfg, new_shot, log, fifo, outdir, pid=pid)
                chain_shots.append(new_shot)
                if not cancelled:
                    log("TTP ABBRUCH failed; aborting click chain")
                return False, new_shot, chain_shots, "click-failed"
            if _screen_changed(before, new_shot):
                log(f"program started (prg, attempt {pa})")
                return True, new_shot, chain_shots, "click-icon-prg"
            log(f"program icon did not start (attempt {pa}), retrying")
        log("program icon never started (prg)")
        return False, chain_shots[-1], chain_shots, "click-failed"

    # strategy == "drive": use an already-open window, otherwise open
    # DISKSTATION A first. Standard path:
    #   window open? -> enlarge -> PRG -> folder -> scroll
    #   else -> drive click -> PRG? -> else enlarge -> PRG -> folder -> scroll
    probe = grabs[-1]
    win_shot = probe
    target = None
    if window_is_open(probe):
        log("GEM window already open, skipping drive click")
        win_shot, target = _reveal_rescan(probe)
        if target is None:
            log("open window has no usable program or folder icon")
            return False, win_shot, chain_shots, "click-failed"
    else:
        attempts = int(click_cfg.get("drive_attempts", 3))
        for attempt in range(1, attempts + 1):
            click_icon(P, win_shot, click_info["sx"], click_info["sy"], log,
                       fifo=fifo, pid=pid)
            log(f"drive click attempt {attempt}, waiting {step_wait}s")
            if not sleep_until(time.monotonic() + step_wait):
                return False, win_shot, chain_shots, "click-failed"
            win_shot = _grab_now(fifo, outdir, 2.0) or win_shot
            chain_shots.append(win_shot)
            # A program icon is the strongest signal; click it directly.
            # Otherwise enlarge first and then scan PRG -> folder -> scroll.
            prg = find_window_icon(win_shot, cfg, "prg")
            if prg is not None:
                target = ("prg", prg)
                log("PRG icon visible after drive click")
                break
            # a program or folder icon only appears once the window is
            # open; on the plain desktop neither template matches, so the
            # screen change/window frame is a reliable "window open" signal
            if _screen_changed(probe, win_shot) or window_is_open(win_shot):
                log("no PRG after drive click, enlarging window")
                win_shot, target = _reveal_rescan(win_shot)
                if target is not None:
                    break
                log("window opened but no program or folder icon matched")
                break
            log("drive click had no effect, retrying")
        if target is None:
            log("drive window did not open with a usable icon")
            return False, win_shot, chain_shots, "click-failed"

    for depth in range(1, max_depth + 1):
        enlarged = False
        kind, hit = target
        if kind == "prg":
            started, win_shot, result = _try_prgs(win_shot, depth)
            if started:
                return True, win_shot, chain_shots, result
            if result == "click-failed":
                return False, win_shot, chain_shots, "click-failed"
            # All program icons were unusable (TTP dialogs, no response).
            # Fall back to a folder icon in the same window.
            folders = find_window_icons(win_shot, cfg, "folder", limit=1)
            if not folders:
                log(f"no further program or folder icon at depth {depth}")
                return False, win_shot, chain_shots, "click-failed"
            kind, hit = "folder", folders[0]
        # GEM occasionally registers the double click as a mere selection
        # (verified live); verify that the folder actually opened and retry
        # the click otherwise
        folder_attempts = int(click_cfg.get("folder_attempts", 3))
        opened = False
        new_shot = win_shot
        for fa in range(1, folder_attempts + 1):
            click_icon(P, win_shot, hit["sx"], hit["sy"], log,
                       fifo=fifo, pid=pid)
            if not sleep_until(time.monotonic() + step_wait):
                return False, win_shot, chain_shots, "click-failed"
            new_shot = _grab_now(fifo, outdir, 2.0) or win_shot
            chain_shots.append(new_shot)
            state = _folder_click_state(win_shot, new_shot, cfg,
                                        hit["sx"], hit["sy"])
            if state != "opened" and do_enlarge and not enlarged \
                    and find_window_target(new_shot, cfg) is None:
                # No matchable icon at all: the opened folder window may
                # just look like its parent (small pixel diff) and hide the
                # program behind a scrollbar, so the click was misjudged as
                # a mere selection or as an auto-started game. Grow the
                # window once and rescan before retrying or believing it.
                enlarged = True
                log(f"depth {depth}: no icon after folder click, enlarging "
                    f"to check for hidden icons")
                new_shot, hidden = _reveal_rescan(new_shot)
                if hidden is not None:
                    state = "opened"
            if state == "program":
                # the game started directly from the double click (the
                # folder icon was already the program, or the click landed
                # on the program icon of the newly opened window)
                log(f"program started at depth {depth} (attempt {fa})")
                return True, new_shot, chain_shots, "click-icon-drive"
            if state == "opened":
                opened = True
                log(f"folder opened at depth {depth} (attempt {fa}), "
                    f"descending")
                break
            log(f"folder icon did not open (attempt {fa}), retrying")
        if not opened:
            log(f"folder icon never opened at depth {depth}")
            return False, win_shot, chain_shots, "click-failed"
        win_shot = new_shot
        target = find_window_target(win_shot, cfg)
        if target is None and do_enlarge and not enlarged:
            enlarged = True
            log(f"depth {depth}: no icon in window, enlarging to reveal "
                f"hidden icons")
            win_shot, target = _reveal_rescan(win_shot)
        if target is None:
            log(f"window depth {depth}: no further program or folder icon")
            return False, win_shot, chain_shots, "click-failed"
    log(f"max depth {max_depth} reached without a program icon")
    return False, win_shot, chain_shots, "click-failed"


def process_entry(cfg: dict, P: dict, entry: dict, log,
                  state_lock=None, click_retry: bool = False,
                  force: bool = False, tos_version: str = "",
                  tos_image: str = "", monitor_info=None,
                  profile: dict = None, boot_mode: str = "",
                  timepoints: list = None, auto_retry: bool = False) -> None:
    def commit(fn):
        # With parallel jobs, entry mutation must be serialized against
        # index saves performed by other workers (avoids torn index state).
        if state_lock is not None:
            with state_lock:
                fn()
        else:
            fn()
    out = Path(P["out"])
    rel = entry["rel"]
    layer = entry["layer"]
    rel_path = Path(rel)
    parts = rel_path.parts
    tp_list = list(timepoints or cfg["timepoints"])

    # Monitor selection: gameinfo screen_format rules are resolved once per
    # run and passed in; without a rule the historic folder-suffix check
    # (e.g. "Abalone - Mono") applies. Mono boots ST high res (640x400).
    if monitor_info:
        monitor, monitor_source = monitor_info
        is_mono = monitor == "mono"
    else:
        mono_suffix = (cfg.get("mono_dir_suffix") or "").strip()
        parent_name = rel_path.parent.name if len(parts) > 1 else ""
        is_mono = bool(mono_suffix) and \
            parent_name.strip().lower().endswith(mono_suffix.lower())
        monitor = "mono" if is_mono else "color"
        monitor_source = "folder-suffix" if is_mono else "default"

    # src_rel carries the folder spelling the file actually has under its
    # own layer root when the canonical output spelling differs (case-only
    # patch-folder win). Fall back to rel for legacy entries.
    src_root = P["patch"] if layer in ("PATCH", "BOTH") else P["root"]
    src_zip = Path(src_root) / entry.get("src_rel", rel)
    if not src_zip.exists():
        src_zip = Path(src_root) / rel

    mirror_dir = out / rel_path.parent
    base = safe_filename(rel_path.stem)
    preview_name = f"{base}.png"
    # keep writing to an existing case-conflict metadata file instead of
    # triggering a second NAS rename
    meta_path = metadata_path(mirror_dir, base) \
        or (mirror_dir / f"{base}.json")
    mirror_dir.mkdir(parents=True, exist_ok=True)

    tmp_root = Path(cfg["tmp_dir"])
    try:
        tmp_root.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix="entry-", dir=tmp_root))
    except OSError as ex:
        raise RuntimeError(f"cannot create staging dir below {tmp_root}: {ex}")
    outdir = stage / "out"
    outdir.mkdir()
    staged = stage / "disk.zip"
    fifo = stage / "hatari.fifo"
    hatari_log = stage / "hatari.log"

    t_start = time.time()
    status, kind = "error", None
    shots_meta, preview, candidates = [], None, []
    click_result = None
    auto_program = None
    chain_shots = []

    click_cfg = cfg.get("click_retry") or {}
    click_info = entry.get("click")
    do_click = bool(click_retry and click_info and click_cfg
                    and (force or not entry.get("click_retried")))

    try:
        log(f"copy {src_zip} -> staging")
        shutil.copy2(src_zip, staged)

        try:
            with zipfile.ZipFile(staged) as zf:
                zip_contents = [i.filename for i in zf.infolist()][:20]
        except zipfile.BadZipFile:
            zip_contents = []

        prof = profile or cfg["profile"]
        machine = prof.get("machine", "st")
        prof_monitor = str(prof.get("monitor") or "").strip().lower()
        tos_version = (tos_version or cfg.get("tos_default") or "1.04").strip()
        tos_image = tos_image or P["tos"]
        log(f"tos {tos_version}: {tos_image}")

        # Boot medium: Falcon and magazine cover disks may be GEMDOS
        # hard-disk archives (not floppy images), so they are extracted and
        # autostarted with `-d` + `--auto`; floppy ZIPs keep `--disk-a`.
        if auto_retry:
            auto_mode, auto_args, auto_program = prepare_auto_retry(
                stage, staged, Path(rel).stem)
            if auto_args is None:
                def _no_program():
                    entry["auto_retried"] = True
                    entry["auto_result"] = "no_program"
                    entry["last_run"] = time.strftime(
                        "%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                commit(_no_program)
                log("auto retry: no launchable program found")
                return
            boot_kind, boot_args = auto_mode, auto_args
            log(f"auto retry: {boot_kind} {boot_args}")
        elif machine == "falcon" or boot_mode in ("auto", "gemdos"):
            boot_kind, boot_args = prepare_boot(
                stage, staged, Path(rel).stem)
            log(f"boot: {boot_kind} {boot_args}")
        else:
            boot_args = ["--disk-a", str(staged)]

        cmd = [
            P["hatari"],
            "--tos", tos_image,
            "--machine", machine,
            "--memsize", prof["memsize"],
            "--sound", "off",
            "--statusbar", "off",
            "--drive-led", "false",
            "--crop", "on",
            "--fast-boot", "on",
            "--confirm-quit", "off",
            "--zoom", prof["zoom"],
        ] + boot_args + [
            "--screenshot-dir", str(outdir),
            "--cmd-fifo", str(fifo),
            "--log-file", str(hatari_log),
            "--log-level", "info",
        ] + prof.get("extra_args", [])
        if prof_monitor in ("rgb", "vga", "tv", "mono"):
            # Falcon Videl monitor from the scope profile (no ST mono logic).
            cmd += ["--monitor", prof_monitor]
            monitor, monitor_source = prof_monitor, "profile"
            log(f"monitor {monitor} ({monitor_source})")
        elif is_mono:
            # --mono selects the monochrome monitor (TOS then boots to
            # high res); --tos-res high forces 640x400 explicitly.
            cmd += ["--mono", "--tos-res", "high"]
        if monitor_source != "default" and not prof_monitor:
            log(f"monitor {monitor} ({monitor_source})"
                + (" --mono --tos-res high" if is_mono else ""))

        env = {**os.environ, "DISPLAY": P["display"]}
        log(f"hatari start ({' '.join(cmd[:6])} ...)")
        proc = subprocess.Popen(cmd, cwd=stage, env=env,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL,
                                start_new_session=True)
        t0 = time.monotonic()
        entry_timeout = (click_cfg.get("entry_timeout_s", 120)
                         if do_click else cfg["entry_timeout_s"])
        deadline = t0 + entry_timeout
        schedule = [click_cfg.get("probe_time", 10)] if do_click else list(tp_list)
        tp_i = 0
        probe_done = False
        clicked = False

        while tp_i < len(schedule):
            tp = schedule[tp_i]
            tp_i += 1
            if not sleep_until(t0 + tp):
                break
            if time.monotonic() > deadline:
                log(f"entry timeout after {entry_timeout}s")
                status = "timeout"
                break
            try:
                fifo_write(fifo, "hatari-shortcut screenshot")
                log(f"screenshot requested at {tp}s")
            except OSError as ex:
                log(f"fifo write failed at {tp}s: {ex}")

            if do_click and not probe_done:
                # let hatari write the PNG, then inspect the probe shot
                if not sleep_until(time.monotonic() + 2):
                    break
                kind_at = None
                grabs = sorted(outdir.glob("*.png"))
                if grabs:
                    try:
                        kind_at = analyze_image(grabs[-1], cfg)["kind"]
                    except Exception as ex:
                        log(f"probe analyze failed: {ex}")
                log(f"probe at {tp}s: kind={kind_at}")
                probe_done = True
                if kind_at == "desktop":
                    strategy = click_info.get("strategy", "prg")
                    try:
                        clicked, last_grab, chain_shots, click_result = \
                            perform_click_chain(
                                P, cfg, click_cfg, click_info, fifo, outdir,
                                grabs, log, pid=proc.pid,
                                allow_enlarge=True)
                    except Exception as ex:
                        log(f"click chain failed ({strategy}): {ex}")
                        clicked = False
                        click_result = "click-failed"

                    def _mark_click():
                        entry["click_retried"] = True
                        entry["click"] = {**click_info, "clicked": clicked}
                        entry["click_result"] = click_result
                    commit(_mark_click)
                    if clicked:
                        t0 = time.monotonic()
                        deadline = t0 + entry_timeout
                        schedule = list(click_cfg.get(
                            "timepoints_after_click", tp_list))
                        tp_i = 0
                    else:
                        # chain failed (no program icon in the opened
                        # window, or xdotool error): keep the latest shot
                        # as the preview but do not retry automatically
                        log(f"click chain did not start a game ({strategy})")
                else:
                    if kind_at is not None:
                        # game (or black) at probe: no click, this shot
                        # already covers the timepoint it was taken at
                        click_result = "click-not-needed"

                        def _mark_no_click():
                            entry["click_retried"] = True
                            entry["click_result"] = click_result
                        commit(_mark_no_click)
                    schedule = [t for t in tp_list if t > tp]
                    tp_i = 0

        sleep_until(time.monotonic() + 2)
        if proc.poll() is None:
            kill_group(proc.pid)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass

        if STOP_EVENT is not None and STOP_EVENT.is_set():
            status = "interrupted"
        else:
            # analyze shots
            grabs = sorted(outdir.glob("*.png"))
            for g in grabs:
                try:
                    m = analyze_image(g, cfg,
                                      detect_boot_logo=(machine == "falcon"))
                except Exception as ex:
                    log(f"analyze failed {g.name}: {ex}")
                    continue
                m["file"] = g.name
                shots_meta.append(m)
                log(f"{g.name}: kind={m['kind']} colors={m['unique_colors']} "
                    f"score={m['score']} mean={m['mean']} std={m['std']}"
                    + (" boot_logo" if m.get("boot_logo") else ""))

            # drop black and the leading Falcon boot screens (no ZIP
            # content). Only the first non-black captures can be boot
            # stages; a later 2-colour green/white look-alike is kept as
            # real content.
            leading_boot = True
            for m in shots_meta:
                if m["kind"] == "black":
                    continue
                if leading_boot and m.get("boot_logo"):
                    m["dropped"] = "boot_logo"
                    continue
                leading_boot = False
                m.pop("boot_logo", None)
            survivors = [m for m in shots_meta
                         if m["kind"] != "black" and not m.get("boot_logo")]
            logo_files = {m["file"] for m in shots_meta
                          if m.get("boot_logo")}
            usable_grabs = [g for g in grabs if g.name not in logo_files]

            # phash dedup (keep first occurrence in time order)
            deduped = []
            maxd = cfg["filters"]["phash_max_distance"]
            for m in survivors:
                if any(phash_distance(m["phash"], d["phash"]) <= maxd
                       for d in deduped):
                    m["dropped"] = "duplicate"
                    continue
                deduped.append(m)

            games = [m for m in deduped if m["kind"] == "game"]
            desks = [m for m in deduped if m["kind"] == "desktop"]
            pick = max(games, key=lambda m: m["score"],
                       default=None) or max(
                desks, key=lambda m: m["score"], default=None)

            if pick is None:
                status = "no_usable_shots"
                # Keep every captured shot for manual review: nothing was
                # usable, so the raw grabs (black screens included — they
                # are exactly what needs checking) stay visible as `_cNN`
                # candidates (SPEC 8.5/8.6). The last capture in time
                # order also becomes the preview, copied to the canonical
                # `<base>.png`, so the entry shows an image instead of an
                # empty placeholder; the chosen grab is not duplicated as
                # a candidate (preview and candidates stay disjoint, as in
                # the success branch). The static Falcon boot logo is not
                # a reviewable shot and is never stored.
                if usable_grabs:
                    if cfg["keep_candidates"]:
                        ci = 0
                        for g in usable_grabs[:-1]:
                            ci += 1
                            cname = f"{base}_c{ci:02d}.png"
                            drop_case_variants(mirror_dir, (cname,))
                            shutil.copy2(g, mirror_dir / cname)
                            candidates.append(cname)
                        old_preview = mirror_dir / preview_name
                        if old_preview.exists():
                            # a previous run's preview (e.g. a forced
                            # rerun of a done entry) becomes a candidate
                            # instead of an unreferenced orphan file; a
                            # stale Falcon boot logo is dropped instead
                            old_is_logo = False
                            if machine == "falcon":
                                try:
                                    old_is_logo = bool(analyze_image(
                                        old_preview, cfg,
                                        detect_boot_logo=True).get(
                                            "boot_logo"))
                                except Exception:
                                    pass
                            if old_is_logo:
                                old_preview.unlink(missing_ok=True)
                            else:
                                ci += 1
                                old = f"{base}_c{ci:02d}.png"
                                drop_case_variants(mirror_dir, (old,))
                                os.replace(old_preview, mirror_dir / old)
                                candidates.append(old)
                    # the preview gate is independent of keep_candidates
                    # (the success branch writes a preview either way)
                    drop_case_variants(mirror_dir, (preview_name,))
                    shutil.copy2(usable_grabs[-1], mirror_dir / preview_name)
                    preview = preview_name
                elif (mirror_dir / preview_name).exists():
                    # no capture at all: keep the existing preview rather
                    # than leaving the entry without an image
                    preview = preview_name
                # no metadata JSON is written for no_usable_shots (SPEC
                # 10.3), so a JSON from an earlier done/desktop run would
                # keep a stale status/preview reference — drop it
                meta_path.unlink(missing_ok=True)
            else:
                kind = refine_desktop_kind(pick["kind"], pick, cfg)
                status = ("desktop" if kind in
                          ("desktop", "textscreen", "darkscreen") else "done")
                # copy files to mirror
                preview = preview_name
                target = mirror_dir / preview_name
                # a stale sibling under the merged-away spelling would
                # trigger a NAS case-conflict rename of the new file
                drop_case_variants(mirror_dir, (preview_name, f"{base}.json"))
                others = [m for m in deduped if m is not pick]
                if cfg["keep_candidates"]:
                    added = {pick["file"]}
                    ci = 0

                    def _add_candidate(src_file, src_dir):
                        nonlocal ci
                        if src_file in added:
                            return
                        added.add(src_file)
                        ci += 1
                        cname = f"{base}_c{ci:02d}.png"
                        drop_case_variants(mirror_dir, (cname,))
                        shutil.copy2(src_dir / src_file, mirror_dir / cname)
                        candidates.append(cname)

                    for m in others:
                        _add_candidate(m["file"], outdir)
                    # keep every intermediate click-chain screenshot too
                    # (drive window, folder window, program window), so the
                    # path to a successful click stays traceable
                    for sp in chain_shots:
                        if isinstance(sp, Path) and sp.name not in logo_files:
                            _add_candidate(sp.name, outdir)
                    if target.exists():
                        # keep the previous preview (e.g. an old desktop
                        # shot) as an additional candidate instead of
                        # silently overwriting it; a stale Falcon boot
                        # logo is worthless and is dropped instead
                        old_is_logo = False
                        if machine == "falcon":
                            try:
                                old_is_logo = bool(analyze_image(
                                    target, cfg,
                                    detect_boot_logo=True).get("boot_logo"))
                            except Exception:
                                pass
                        if old_is_logo:
                            target.unlink(missing_ok=True)
                        else:
                            ci += 1
                            old = f"{base}_c{ci:02d}.png"
                            drop_case_variants(mirror_dir, (old,))
                            os.replace(target, mirror_dir / old)
                            candidates.append(old)
                shutil.copy2(outdir / pick["file"], target)

        def _commit():
            entry["status"] = status
            entry["kind"] = kind
            entry["preview"] = preview
            entry["candidates"] = candidates
            entry["click_result"] = click_result
            entry["last_run"] = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                              time.gmtime())
            entry["duration_s"] = round(time.time() - t_start, 1)
            entry["zip_contents"] = zip_contents
            entry["capture_method"] = "cmd-fifo"
            entry["monitor"] = monitor
            if auto_retry:
                entry["auto_retried"] = True
                entry["auto_result"] = status
                if auto_program:
                    entry["auto_program"] = auto_program
                else:
                    entry.pop("auto_program", None)
            # TOS marker (section 7.5/10.4): only a successful capture with a
            # non-default TOS is recorded (sparse; absent = the default TOS).
            # A failed attempt remembers its version in `tos_tried` so a
            # later `--retry-no-usable --tos <version>` skips it.
            default_tos = cfg.get("tos_default") or "1.04"
            if status in ("done", "desktop") and tos_version != default_tos:
                entry["tos"] = tos_version
                entry.pop("tos_tried", None)
            else:
                entry.pop("tos", None)
                if tos_version != default_tos:
                    tried = list(entry.get("tos_tried") or [])
                    if tos_version not in tried:
                        tried.append(tos_version)
                    entry["tos_tried"] = tried
            if preview:
                # a fresh preview supersedes the drive-LED reset state
                entry.pop("drive_led", None)
                entry.pop("drive_led_refetch", None)

        commit(_commit)

        meta = {
            "spec_version": "1",
            "tool_version": TOOL_VERSION,
            "entry": rel,
            "name": entry["name"],
            "source_layer": layer,
            "source_size": entry["size"],
            "profile": prof["name"],
            "machine": prof["machine"],
            "monitor": monitor,
            "tos": tos_version,
            "status": status,
            "kind": kind,
            "preview_is_desktop": bool(kind in
                                       ("desktop", "textscreen", "darkscreen")),
            "preview": preview,
            "candidates": candidates,
            "click": entry.get("click"),
            "click_retried": bool(entry.get("click_retried")),
            "click_result": click_result,
            "auto_retried": bool(entry.get("auto_retried")),
            "auto_result": entry.get("auto_result"),
            "auto_program": entry.get("auto_program"),
            "capture_method": "cmd-fifo",
            "shots": shots_meta,
            "zip_contents": zip_contents,
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                        time.gmtime(t_start)),
            "duration_s": entry["duration_s"],
            "tool_version": TOOL_VERSION,
        }
        if status in ("done", "desktop"):
            with open(meta_path, "w", encoding="utf-8") as fh:
                json.dump(meta, fh, indent=1)
        log(f"status={status}")
    except MemoryGuardTripped as ex:
        def _commit_guard():
            entry["status"] = "error"
            entry["last_run"] = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                              time.gmtime())

        commit(_commit_guard)
        log(f"ERROR: memory guard tripped: {ex}")
    except Exception as ex:
        def _commit_error():
            entry["status"] = "error"
            entry["last_run"] = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                              time.gmtime())

        commit(_commit_error)
        log(f"ERROR: {ex}")
    finally:
        if os.environ.get("SHOTGEN_KEEP_STAGE"):
            log(f"stage kept at {stage}")
        else:
            shutil.rmtree(stage, ignore_errors=True)
        gc.collect()


def acquire_lock(out: Path) -> Path:
    lock = out / LOCK_NAME
    if lock.exists():
        try:
            pid = int(lock.read_text().strip())
            os.kill(pid, 0)
            sys.exit(f"error: another run is active (pid {pid}), "
                     f"remove {lock} if that is wrong")
        except (ValueError, ProcessLookupError, PermissionError):
            pass
    lock.write_text(str(os.getpid()))
    return lock


def release_lock(lock: Path) -> None:
    try:
        lock.unlink()
    except FileNotFoundError:
        pass


def _run_parallel(cfg: dict, P: dict, args, out: Path, idx: dict,
                  pending: list, jobs: int, t_start: float,
                  done_counts: dict, displays: list,
                  index_name: str = INDEX_NAME, tos_version: str = "",
                  tos_image: str = "", monitor_map: dict = None,
                  profile: dict = None, boot_mode: str = "",
                  timepoints: list = None, auto_retry: bool = False):
    """Worker pool: claim entries from a shared queue, process, save index.

    Entry mutation and index saves are serialized under one lock, so
    parallel workers never overwrite each other's updates. Each worker gets
    its own Xvfb display: Hatari's SDL only processes mouse motion when its
    window has input focus, and two instances sharing one display would
    steal each other's pointer. Returns (interrupted, processed).
    """
    state_lock = threading.Lock()
    queue = deque(pending)
    processed = 0
    interrupted = False
    total_shown = min(len(pending), args.limit or len(pending))
    limit_reported = False
    hours_reported = False

    def make_log(e, wid):
        logdir = out / "logs" / Path(e["rel"]).parent
        logdir.mkdir(parents=True, exist_ok=True)
        logfile = logdir / (safe_filename(Path(e["rel"]).stem) + ".log")

        def log(msg, _f=logfile, _wid=wid):
            line = f"{time.strftime('%H:%M:%S')} [w{_wid}] {msg}"
            print(f"  {line}", flush=True)
            with open(_f, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")

        return log

    def worker(wid):
        nonlocal processed, interrupted, limit_reported, hours_reported
        # each worker runs on its own display
        Pw = {**P, "display": displays[(wid - 1) % len(displays)]}
        try:
            while True:
                with state_lock:
                    if args.limit and processed >= args.limit:
                        if not limit_reported:
                            limit_reported = True
                            print(f"limit {args.limit} reached", flush=True)
                        return
                    if (args.hours
                            and time.monotonic() - t_start
                            >= args.hours * 3600):
                        if not hours_reported:
                            hours_reported = True
                            print(f"hour budget {args.hours}h reached",
                                  flush=True)
                        return
                    if STOP_EVENT.is_set():
                        interrupted = True
                        return
                    if not queue:
                        return
                    e = queue.popleft()
                    processed += 1
                    cur = processed

                print(f"[w{wid}][{cur}/{total_shown}] {e['rel']}", flush=True)
                process_entry(cfg, Pw, e, make_log(e, wid),
                              state_lock=state_lock,
                              click_retry=args.retry_desktop,
                              force=args.force,
                              tos_version=tos_version, tos_image=tos_image,
                              monitor_info=(monitor_map or {}).get(e["rel"]),
                              profile=profile, boot_mode=boot_mode,
                              timepoints=timepoints,
                              auto_retry=auto_retry)
                with state_lock:
                    save_index(out, idx, index_name)
                    done_counts[e["status"]] = (done_counts.get(e["status"], 0)
                                                + 1)
                _maybe_trace_memory(f"w{wid} {e['rel'][-40:]}")
                # The FFT correlation allocates several image-sized arrays
                # per template; CPython/the numpy allocator keep freed
                # blocks cached by size class, so a long-lived worker's RSS
                # creeps up even though the objects are gone. A cheap
                # collect per entry plus malloc_trim (which must run in this
                # worker thread) hands the released blocks back to the OS
                # before the next entry starts and keeps the parallel run
                # inside its RAM budget.
                gc.collect()
                _malloc_trim()
        except Exception as ex:
            print(f"[w{wid}] worker failed: {ex}", file=sys.stderr,
                  flush=True)

    threads = [threading.Thread(target=worker, args=(wid,),
                                name=f"shotgen-w{wid}")
               for wid in range(1, jobs + 1)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return interrupted, processed


def _display_list(base: str, jobs: int):
    """Return ``jobs`` display names starting at ``base`` (e.g. :99, :100)."""
    try:
        base_num = int(base.lstrip(":"))
    except ValueError:
        base_num = 99
    return [f":{base_num + i}" for i in range(jobs)]


def cmd_run(cfg: dict, P: dict, args, scope: dict) -> int:
    if args.retry_desktop and shutil.which("xdotool") is None:
        sys.exit("error: --retry-desktop needs xdotool in PATH")
    out = Path(P["out"])
    out.mkdir(parents=True, exist_ok=True)
    lock = acquire_lock(out)

    tmp_root = _ensure_tmp_dir(cfg)
    _cleanup_orphaned_helpers(tmp_root, P["display"], cfg["xvfb_screen"])
    _cleanup_stale_stages(tmp_root, cfg)

    jobs, guard_mb = _effective_jobs(max(1, args.jobs), cfg, out, tmp_root)
    configure_mem_guard(guard_mb)
    displays = _display_list(P["display"], jobs)
    xvfbs = []
    for disp in displays:
        xv = ensure_xvfb(disp, cfg["xvfb_screen"])
        if xv:
            print(f"Xvfb started on {disp} (pid {xv.pid})", flush=True)
            xvfbs.append(xv)

    tos_version = (args.tos or scope.get("tos_default")
                   or cfg.get("tos_default") or "1.04").strip()
    tos_image = tos_image_for(cfg, P, tos_version)
    scope_prof = scope_profile(cfg, scope)
    boot_mode = scope.get("boot", "")
    if tos_version != (cfg.get("tos_default") or "1.04"):
        print(f"TOS override: {tos_version}", flush=True)

    idx = load_index(out, scope["index"])
    entries = idx["entries"]
    pending = []
    for rel in sorted(entries):
        e = entries[rel]
        if e["status"] == "skipped_disk_n":
            continue
        if args.retry_desktop:
            if e["status"] != "desktop":
                continue
            if not e.get("click"):
                continue
            if e.get("click_retried") and not args.force:
                continue
        elif args.retry_desktop_auto:
            # scan the image/archive for a launchable program and start it
            # with --auto (no GEM desktop clicks)
            if e["status"] != "desktop":
                continue
            if e.get("auto_retried") and not args.force:
                continue
        elif args.retry_no_usable:
            if e["status"] != "no_usable_shots":
                continue
            # skip versions already attempted on this entry (e.g. a 1.02
            # pass that did not help), unless --force
            if not args.force and tos_version in (e.get("tos_tried") or []):
                continue
        elif args.retry_drive_led:
            # drive-LED resets (section 8.7): re-capture the bootable ones
            # with --drive-led false; the non-bootable ones are marked
            # kind=no_game_image and skipped here too
            if e["status"] != "desktop":
                continue
            if not e.get("drive_led_refetch"):
                continue
            if e.get("kind") == "no_game_image":
                continue
        elif e["status"] in ("done", "desktop", "no_usable_shots") \
                and not args.force:
            continue
        if args.only and args.only.lower() not in rel.lower():
            continue
        pending.append(e)

    print(f"pending entries: {len(pending)} "
          f"(scope {scope['name']}, index {scope['index']})", flush=True)
    monitor_map, monitor_info = build_monitor_map(cfg, P, scope, pending)
    if monitor_info:
        print(monitor_info, flush=True)
    if jobs > 1:
        print(f"parallel jobs: {jobs} on displays {', '.join(displays)}",
              flush=True)
    t_start = time.monotonic()
    done_counts = {}
    processed = 0
    interrupted = False
    if _TRACEMALLOC_ON:
        import tracemalloc
        tracemalloc.start(25)
        _install_memtrace_signal()
        print("[memtrace] tracemalloc started", flush=True)
    if _DIAG_ON:
        _start_diagnostics()
        print(f"[diag] instrumented, log={_DIAG_LOG} "
              f"tripwire={_DIAG_TRIPWIRE_MB:.0f}MB", flush=True)

    try:
        if jobs > 1:
            interrupted, processed = _run_parallel(
                cfg, P, args, out, idx, pending, jobs, t_start, done_counts,
                displays, index_name=scope["index"],
                tos_version=tos_version, tos_image=tos_image,
                monitor_map=monitor_map,
                profile=scope_prof, boot_mode=boot_mode,
                timepoints=scope.get("timepoints"),
                auto_retry=args.retry_desktop_auto)
        else:
            for e in pending:
                if args.limit and processed >= args.limit:
                    print(f"limit {args.limit} reached", flush=True)
                    break
                if (args.hours
                        and time.monotonic() - t_start >= args.hours * 3600):
                    print(f"hour budget {args.hours}h reached", flush=True)
                    break
                if STOP_EVENT.is_set():
                    interrupted = True
                    break

                logdir = out / "logs" / Path(e["rel"]).parent
                logdir.mkdir(parents=True, exist_ok=True)
                logfile = logdir / (
                    safe_filename(Path(e["rel"]).stem) + ".log")

                def log(msg, _f=logfile):
                    line = f"{time.strftime('%H:%M:%S')} {msg}"
                    print(f"  {line}", flush=True)
                    with open(_f, "a", encoding="utf-8") as fh:
                        fh.write(line + "\n")

                processed += 1
                print(f"[{processed}/{min(len(pending), args.limit or len(pending))}] "
                      f"{e['rel']}", flush=True)
                process_entry(cfg, P, e, log,
                              click_retry=args.retry_desktop,
                              force=args.force,
                              tos_version=tos_version, tos_image=tos_image,
                              monitor_info=monitor_map.get(e["rel"]),
                              profile=scope_prof, boot_mode=boot_mode,
                              timepoints=scope.get("timepoints"),
                              auto_retry=args.retry_desktop_auto)
                save_index(out, idx, scope["index"])
                done_counts[e["status"]] = done_counts.get(e["status"], 0) + 1
                if STOP_EVENT.is_set():
                    interrupted = True
                    break
    except KeyboardInterrupt:
        interrupted = True
    finally:
        save_index(out, idx, scope["index"])
        release_lock(lock)
        for xv in xvfbs:
            kill_group(xv.pid)
        elapsed = time.monotonic() - t_start
        print(f"\nprocessed {processed} entries in {elapsed/60:.1f} min",
              flush=True)
        for k in sorted(done_counts):
            print(f"  {k}: {done_counts[k]}", flush=True)
    return 130 if interrupted else 0


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def cmd_index(cfg: dict, P: dict, args, scope: dict) -> int:
    global STOP_EVENT
    stats, idx = build_index(cfg, P, args.full, scope)
    entries = idx["entries"]
    by_status = {}
    for e in entries.values():
        by_status[e["status"]] = by_status.get(e["status"], 0) + 1
    print(f"\nindex[{scope['name']}] {scope['index']}: "
          f"{len(entries)} entries "
          f"(new {stats['new']}, unchanged {stats['kept']}, "
          f"gone {stats['gone']})")
    for k in sorted(by_status):
        print(f"  {k}: {by_status[k]}")

    # kind breakdown (game/desktop/textscreen/darkscreen); counts only the
    # entries that have a kind at all
    by_kind = {}
    for e in entries.values():
        k = e.get("kind")
        if k:
            by_kind[k] = by_kind.get(k, 0) + 1
    if by_kind:
        kinds = ", ".join(f"{k} {by_kind[k]}" for k in sorted(by_kind))
        print(f"  kinds: {kinds}")
    return 0


def cmd_detect(cfg: dict, P: dict, args, scope: dict) -> int:
    """Offline icon detection on existing desktop previews (no Hatari)."""
    out = Path(P["out"])
    out.mkdir(parents=True, exist_ok=True)
    idx = load_index(out, scope["index"])
    entries = idx["entries"]
    lock = acquire_lock(out)
    stats = {"checked": 0, "found": 0, "no_icon": 0, "skipped": 0,
             "strategy": {"prg": 0, "drive": 0}}
    try:
        desktops = [rel for rel in sorted(entries)
                    if entries[rel]["status"] == "desktop"
                    and (not args.only
                         or args.only.lower() in rel.lower())]
        print(f"desktop entries: {len(desktops)}", flush=True)
        for i, rel in enumerate(desktops, 1):
            if STOP_EVENT.is_set():
                print("interrupted", flush=True)
                break
            e = entries[rel]
            if e.get("click") and not args.force:
                # current entries carry a strategy; legacy entries store
                # only coordinates and cannot be executed (the run would
                # fall back to the prg strategy), so re-detect those even
                # without --force
                if e["click"].get("strategy"):
                    stats["skipped"] += 1
                    continue
            if e.get("icon_found") is False and not args.force:
                stats["skipped"] += 1
                continue
            stats["checked"] += 1
            mirror = out / Path(rel).parent
            names = [n for n in [e.get("preview")]
                     + (e.get("candidates") or []) if n]
            found = None
            for name in names:
                p = mirror / name
                if not p.is_file():
                    continue
                try:
                    res = find_desktop_click(p, cfg)
                except Exception as ex:
                    print(f"  detect error {rel}: {ex}",
                          file=sys.stderr, flush=True)
                    res = None
                if res:
                    found = {**res, "source": name}
                    break
            if found:
                e["click"] = found
                e["icon_found"] = True
                stats["found"] += 1
                stats["strategy"][found["strategy"]] += 1
            else:
                e["icon_found"] = False
                stats["no_icon"] += 1
            if i % 200 == 0:
                print(f"  ... {i}/{len(desktops)} "
                      f"({stats['found']} icons)", flush=True)
                save_index(out, idx, scope["index"])
        save_index(out, idx, scope["index"])
    finally:
        release_lock(lock)
    print(f"detect[{scope['name']}]: checked {stats['checked']}, "
          f"icons {stats['found']} "
          f"(prg {stats['strategy']['prg']}, "
          f"drive {stats['strategy']['drive']}), "
          f"no icon {stats['no_icon']}, skipped {stats['skipped']}")
    return 0


BOOTABLE_EXTS = {".stx", ".msa", ".st", ".dim", ".ipf", ".prg", ".stt",
                 ".pckd", ".pkd"}


def _is_bootable(zip_contents) -> bool:
    """True when the archive contains a bootable disk/program image."""
    for name in zip_contents or []:
        if Path(name).suffix.lower() in BOOTABLE_EXTS:
            return True
    return False


def cmd_cleanup_drive_led(cfg: dict, P: dict, args, scope: dict) -> int:
    """Remove previews that only show Hatari's drive LED overlay.

    Such screenshots (documentation/manuals and some data disks) are a
    blank white screen with the green drive LED in the top-right corner;
    they carry no game content. Affected preview/candidate PNGs and their
    metadata JSON are deleted, the index entry is reset and flagged with
    ``drive_led: true``. Bootable entries additionally get
    ``drive_led_refetch: true`` so a later pass can re-capture them with
    ``--drive-led false``.

    Entries whose status is ``done`` are skipped entirely: those are final
    (manual curation or a real game shot) and must not be reset.
    """
    out = Path(P["out"])
    idx = load_index(out, scope["index"])
    entries = idx["entries"]
    lock = acquire_lock(out)
    stats = {"scanned": 0, "entries": 0, "previews": 0, "candidates": 0,
             "jsons": 0, "refetch": 0, "bootable": 0}

    def _is_led(path: Path) -> bool:
        try:
            from PIL import Image
            with Image.open(path) as im:
                return has_drive_led(im)
        except Exception:
            return False

    try:
        targets = [rel for rel in sorted(entries)
                   if (not args.only
                       or args.only.lower() in rel.lower())]
        for rel in targets:
            e = entries[rel]
            # manual curation: an entry the desktop app marked as `done`
            # is final (SPEC 10.5) and is never reset or stripped here
            if e.get("status") == "done":
                continue
            prev = e.get("preview")
            cands = list(e.get("candidates") or [])
            if not prev and not cands:
                continue
            mirror = out / Path(rel).parent
            preview_led = bool(prev) and _is_led(mirror / prev)
            led_cands = [c for c in cands if _is_led(mirror / c)]
            if not preview_led and not led_cands:
                continue
            base = safe_filename(Path(rel).stem)
            meta = metadata_path(mirror, base)

            if not preview_led:
                # the preview is fine; only drop the LED-white candidates
                # (intermediate white shots) and leave everything else
                stats["entries"] += 1
                stats["candidates"] += len(led_cands)
                if not args.dry_run:
                    for c in led_cands:
                        (mirror / c).unlink(missing_ok=True)
                    e["candidates"] = [c for c in cands
                                       if c not in set(led_cands)]
                stats["scanned"] += 1
                continue

            # the preview itself is a blank LED screen: reset the entry
            stats["entries"] += 1
            bootable = _is_bootable(e.get("zip_contents"))
            if bootable:
                stats["bootable"] += 1
                stats["refetch"] += 1
            stats["previews"] += 1
            stats["candidates"] += len(led_cands)
            if meta is not None:
                stats["jsons"] += 1

            if not args.dry_run:
                if prev:
                    (mirror / prev).unlink(missing_ok=True)
                for c in led_cands:
                    (mirror / c).unlink(missing_ok=True)
                if meta is not None:
                    meta.unlink()

                # reset the index entry to a clean, re-fetchable state
                e["preview"] = None
                e["candidates"] = []
                e["kind"] = None
                e["status"] = "desktop"
                e["last_run"] = None
                e.pop("click", None)
                e.pop("click_result", None)
                e.pop("click_retried", None)
                e.pop("icon_found", None)
                e.pop("duration_s", None)
                e["drive_led"] = True
                if bootable:
                    e["drive_led_refetch"] = True
            stats["scanned"] += 1

        if not args.dry_run:
            save_index(out, idx, scope["index"])
    finally:
        release_lock(lock)

    print(f"cleanup-drive-led[{scope['name']}]: entries {stats['entries']} "
          f"(bootable {stats['bootable']}, refetch {stats['refetch']}), "
          f"previews {stats['previews']}, candidates {stats['candidates']}, "
          f"jsons {stats['jsons']}"
          + (" [dry-run, nothing changed]" if args.dry_run else ""))
    return 0


def cmd_cleanup_duplicates(cfg: dict, P: dict, args, scope: dict) -> int:
    """Remove pixel-exact duplicate candidate PNGs of every entry.

    Offline pass (no Hatari). For every index entry with candidates the
    preview (unless ``--candidates-only``) and the ``_cNN`` candidates are
    decoded and compared by their pixel-exact signature
    (:func:`pixel_signature`): the first occurrence in the list is kept,
    every later file that shows exactly the same pixels is deleted. This
    removes the exact duplicates that repeated captures and the click
    chain leave behind without touching perceptually similar but distinct
    shots.

    The preview is always the first image in the comparison order, so it
    is never deleted; only candidates can be removed. ``status: done`` is
    not a blocker here (unlike ``cleanup-drive-led``): preview, status and
    kind stay untouched. The index entry's ``candidates`` list and the
    per-entry metadata JSON are updated; candidate names are not
    renumbered, so gaps in the ``_cNN`` series are fine for consumers.

    Missing or unreadable files are skipped and reported, never deleted.
    """
    out = Path(P["out"])
    idx = load_index(out, scope["index"])
    entries = idx["entries"]
    lock = acquire_lock(out)
    stats = {"scanned": 0, "entries": 0, "removed": 0, "bytes": 0,
             "missing": 0, "unreadable": 0, "metadata": 0, "errors": 0}
    dirty = False
    candidates_only = bool(getattr(args, "candidates_only", False))

    try:
        targets = [rel for rel in sorted(entries)
                   if entries[rel].get("candidates")
                   and (not args.only
                        or args.only.lower() in rel.lower())]
        print(f"entries with candidates: {len(targets)}", flush=True)
        last_progress = time.monotonic()

        def progress(current: str) -> None:
            nonlocal last_progress
            now = time.monotonic()
            if now - last_progress < PROGRESS_INTERVAL_S:
                return
            last_progress = now
            total = len(targets)
            pct = 100.0 * stats["scanned"] / total if total else 100.0
            action = "would remove" if args.dry_run else "removed"
            print(f"  [progress] {time.strftime('%H:%M:%S')} "
                  f"{stats['scanned']}/{total} ({pct:.1f}%) — "
                  f"{stats['entries']} entries, {action} "
                  f"{stats['removed']} files "
                  f"({stats['bytes'] / (1024 * 1024):.1f} MiB) — "
                  f"current: {current}", flush=True)

        for rel in targets:
            if STOP_EVENT.is_set():
                print("interrupted", flush=True)
                break
            e = entries[rel]
            stats["scanned"] += 1
            progress(rel)
            cands = list(e.get("candidates") or [])
            mirror = out / Path(rel).parent
            base = safe_filename(Path(rel).stem)
            meta = metadata_path(mirror, base)

            ordered = list(cands)
            if not candidates_only and e.get("preview"):
                ordered = [e["preview"]] + ordered

            seen = {}
            sizes = {}
            remove = []
            for name in ordered:
                p = mirror / name
                st = None
                try:
                    st = p.stat()
                    sig = pixel_signature(p)
                except OSError:
                    sig = None
                if sig is None:
                    if st is None:
                        stats["missing"] += 1
                    else:
                        stats["unreadable"] += 1
                    continue
                sizes[name] = st.st_size
                if sig in seen:
                    remove.append(name)
                else:
                    seen[sig] = name
                progress(rel)

            removed = list(dict.fromkeys(remove))
            if not removed:
                continue

            stats["entries"] += 1
            stats["removed"] += len(removed)
            stats["bytes"] += sum(sizes.get(n, 0) for n in removed)
            if getattr(args, "list", False):
                print(f"  {rel}: -{', '.join(removed)}", flush=True)

            if args.dry_run:
                continue

            removed_set = set(removed)
            for name in removed:
                try:
                    (mirror / name).unlink(missing_ok=True)
                except OSError as ex:
                    stats["errors"] += 1
                    print(f"  unlink error {rel}/{name}: {ex}",
                          file=sys.stderr, flush=True)
            new_cands = [c for c in cands if c not in removed_set]
            e["candidates"] = new_cands
            if meta is not None:
                try:
                    with open(meta, "r", encoding="utf-8") as fh:
                        md = json.load(fh)
                    md["candidates"] = new_cands
                    write_json_atomic(meta, md)
                    stats["metadata"] += 1
                except Exception as ex:
                    stats["errors"] += 1
                    print(f"  metadata error {rel}: {ex}",
                          file=sys.stderr, flush=True)
            dirty = True
            if stats["entries"] % 500 == 0:
                save_index(out, idx, scope["index"])
                dirty = False
    finally:
        try:
            if dirty and not args.dry_run:
                save_index(out, idx, scope["index"])
        finally:
            release_lock(lock)

    mib = stats["bytes"] / (1024 * 1024)
    print(f"cleanup-duplicates[{scope['name']}]: scanned {stats['scanned']}, "
          f"entries {stats['entries']}, removed {stats['removed']} files "
          f"({mib:.1f} MiB), metadata {stats['metadata']}, missing "
          f"{stats['missing']}, unreadable {stats['unreadable']}, errors "
          f"{stats['errors']}"
          + (" [dry-run, nothing changed]" if args.dry_run else ""))
    return 0


def cmd_cleanup_boot_logo(cfg: dict, P: dict, args, scope: dict) -> int:
    """Remove the static Falcon boot screens from the index (offline).

    Falcon TOS 4.04 keeps its Atari-logo and plain green Videl boot
    screens visible at the early screenshot timepoints. New captures
    already filter them out (SPEC 8.1); this pass cleans shots captured
    before that rule existed: every candidate that matches a boot screen
    is deleted and removed from the index and the per-entry metadata JSON.

    The preview is normally never a boot screen (a real shot outranks it).
    If it is, the best non-boot candidate is promoted and
    ``status``/``kind`` are recomputed; with no other candidate the boot
    preview is kept and reported instead of leaving the entry without an
    image.
    """
    prof = scope_profile(cfg, scope)
    if prof.get("machine") != "falcon":
        print(f"cleanup-boot-logo[{scope['name']}]: not a Falcon scope "
              f"(machine {prof.get('machine')!r}), nothing to do")
        return 0

    out = Path(P["out"])
    idx = load_index(out, scope["index"])
    entries = idx["entries"]
    lock = acquire_lock(out)
    stats = {"scanned": 0, "entries": 0, "removed": 0, "promoted": 0,
             "keep_preview": 0, "missing": 0, "unreadable": 0,
             "metadata": 0, "errors": 0}

    def _analyze(path: Path):
        try:
            return analyze_image(path, cfg, detect_boot_logo=True)
        except Exception:
            return None

    try:
        targets = [rel for rel in sorted(entries)
                   if (not args.only
                       or args.only.lower() in rel.lower())]
        for rel in targets:
            if STOP_EVENT.is_set():
                print("interrupted", flush=True)
                break
            e = entries[rel]
            prev = e.get("preview")
            cands = list(e.get("candidates") or [])
            if not prev and not cands:
                continue
            stats["scanned"] += 1
            mirror = out / Path(rel).parent
            base = safe_filename(Path(rel).stem)
            meta = metadata_path(mirror, base)

            preview_metrics = None
            if prev:
                pp = mirror / prev
                if not pp.exists():
                    stats["missing"] += 1
                else:
                    preview_metrics = _analyze(pp)
                    if preview_metrics is None:
                        stats["unreadable"] += 1
            preview_logo = bool(preview_metrics
                                and preview_metrics.get("boot_logo"))

            cand_metrics = {}
            logo_cands = []
            for c in cands:
                cp = mirror / c
                if not cp.exists():
                    stats["missing"] += 1
                    continue
                m = _analyze(cp)
                if m is None:
                    stats["unreadable"] += 1
                    continue
                cand_metrics[c] = m
                if m.get("boot_logo"):
                    logo_cands.append(c)

            if not preview_logo and not logo_cands:
                continue

            keep_preview = bool(preview_logo)
            promoted = None
            if preview_logo:
                non_logo = [(c, m) for c, m in cand_metrics.items()
                            if not m.get("boot_logo")]
                if non_logo:
                    promoted = max(non_logo,
                                   key=lambda cm: cm[1].get("score", 0))[0]
                    keep_preview = False

            removed = list(dict.fromkeys(
                logo_cands + ([promoted] if promoted else [])))
            stats["entries"] += 1
            stats["removed"] += len(removed)
            if promoted:
                stats["promoted"] += 1
            if keep_preview:
                stats["keep_preview"] += 1
            if getattr(args, "list", False):
                print(f"  {rel}: -{', '.join(removed) if removed else '-'}"
                      + (f" promote {promoted}" if promoted else "")
                      + (" (preview is boot logo)" if keep_preview else ""),
                      flush=True)
            if args.dry_run:
                continue

            if promoted:
                shutil.copy2(mirror / promoted, mirror / prev)
                m = cand_metrics[promoted]
                kind = refine_desktop_kind(m["kind"], m, cfg)
                e["kind"] = kind
                e["status"] = ("desktop" if kind in
                               ("desktop", "textscreen", "darkscreen")
                               else "done")
            for name in removed:
                try:
                    (mirror / name).unlink(missing_ok=True)
                except OSError as ex:
                    stats["errors"] += 1
                    print(f"  unlink error {rel}/{name}: {ex}",
                          file=sys.stderr, flush=True)

            remove_set = set(removed)
            e["candidates"] = [c for c in cands if c not in remove_set]
            if meta is not None:
                try:
                    with open(meta, "r", encoding="utf-8") as fh:
                        md = json.load(fh)
                    md["candidates"] = e["candidates"]
                    if promoted:
                        md["status"] = e["status"]
                        md["kind"] = e["kind"]
                        md["preview_is_desktop"] = bool(
                            e["kind"] in ("desktop", "textscreen",
                                          "darkscreen"))
                    write_json_atomic(meta, md)
                    stats["metadata"] += 1
                except Exception as ex:
                    stats["errors"] += 1
                    print(f"  metadata error {rel}: {ex}",
                          file=sys.stderr, flush=True)

        if not args.dry_run:
            save_index(out, idx, scope["index"])
    finally:
        release_lock(lock)

    print(f"cleanup-boot-logo[{scope['name']}]: scanned {stats['scanned']}, "
          f"entries {stats['entries']}, removed {stats['removed']} files, "
          f"promoted {stats['promoted']}, kept preview "
          f"{stats['keep_preview']}, metadata {stats['metadata']}, missing "
          f"{stats['missing']}, unreadable {stats['unreadable']}, errors "
          f"{stats['errors']}"
          + (" [dry-run, nothing changed]" if args.dry_run else ""))
    return 0


def cmd_promote_app_screens(cfg: dict, P: dict, args, scope: dict) -> int:
    """Promote an application-window candidate to the preview.

    Utils often boot into a GEM desktop and only show the application in a
    window (or full-screen text screen) after the desktop click retry. The
    mono classifier still calls such a screen ``desktop``/``textscreen``
    because it has only two colors. This offline pass (no Hatari) looks at
    every ``desktop`` entry with candidates and scans them backwards,
    skipping TTP dialogs (:func:`is_ttp_dialog`), GEM drive/folder windows
    (:func:`is_gem_file_window`), blank/black screens and the plain TOS
    desktop (known pHash). The last remaining candidate is the application.

    TTP programs show GEM's "ANWENDUNG ÖFFNEN" command-line dialog rather
    than an application screen. An entry with only a TTP dialog is reset to
    ``status: desktop`` / ``kind: desktop`` (no longer textscreen).

    The chosen image and the old preview are swapped exactly like the app's
    ``M`` curation: the chosen candidate becomes ``<base>.png`` and the old
    preview takes its candidate name. The index and metadata become
    ``status: done`` / ``kind: game`` (or ``--kind``).
    """
    out = Path(P["out"])
    idx = load_index(out, scope["index"])
    entries = idx["entries"]
    lock = acquire_lock(out)
    stats = {"scanned": 0, "promoted": 0, "ttp": 0, "no_app": 0,
             "missing": 0, "metadata": 0, "errors": 0,
             "skip_file": 0, "skip_blank": 0, "skip_desktop": 0}
    dirty = False

    try:
        targets = [
            rel for rel in sorted(entries)
            if entries[rel].get("status") == "desktop"
            and entries[rel].get("candidates")
            and (not args.only or args.only.lower() in rel.lower())
        ]
        print(f"desktop entries with candidates: {len(targets)}", flush=True)
        for rel in targets:
            if STOP_EVENT.is_set():
                print("interrupted", flush=True)
                break
            e = entries[rel]
            stats["scanned"] += 1
            preview = e.get("preview")
            cands = list(e.get("candidates") or [])
            mirror = out / Path(rel).parent
            base = safe_filename(Path(rel).stem)
            if not preview or not (mirror / preview).is_file():
                stats["missing"] += 1
                continue

            chosen = None
            if args.candidate:
                if 1 <= args.candidate <= len(cands):
                    name = cands[args.candidate - 1]
                    if (mirror / name).is_file():
                        chosen = name
            else:
                # Walk the candidates backwards and skip everything that is
                # not an application screen: TTP command dialog, GEM file
                # window, blank/black screen, plain TOS desktop. The last
                # remaining candidate is the application (window or
                # full-screen text screen).
                ttp_name = None
                for name in reversed(cands):
                    path = mirror / name
                    if not path.is_file():
                        continue
                    try:
                        if is_ttp_dialog(path):
                            ttp_name = ttp_name or name
                            continue
                        if is_gem_file_window(path):
                            stats["skip_file"] += 1
                            continue
                        metrics = analyze_image(path, cfg)
                        if metrics["kind"] == "black":
                            stats["skip_blank"] += 1
                            continue
                        if metrics["phash"] in PLAIN_DESKTOP_PHASHES:
                            stats["skip_desktop"] += 1
                            continue
                        chosen = name
                        break
                    except Exception as ex:
                        stats["errors"] += 1
                        print(f"  candidate check error {rel}/{name}: {ex}",
                              file=sys.stderr, flush=True)

                if chosen is None and ttp_name is not None:
                    # A TTP program only opened GEM's command-line dialog,
                    # not an application. Keep the desktop preview and mark
                    # the entry as plain desktop instead of textscreen.
                    stats["ttp"] += 1
                    if args.list:
                        print(f"  {rel}: TTP dialog {ttp_name} -> reset to "
                              f"desktop/desktop")
                    if args.dry_run:
                        continue
                    e["status"] = "desktop"
                    e["kind"] = "desktop"
                    meta = metadata_path(mirror, base)
                    if meta is not None:
                        try:
                            with open(meta, "r", encoding="utf-8") as fh:
                                md = json.load(fh)
                            md["status"] = "desktop"
                            md["kind"] = "desktop"
                            md["preview_is_desktop"] = True
                            write_json_atomic(meta, md)
                            stats["metadata"] += 1
                        except Exception as ex:
                            stats["errors"] += 1
                            print(f"  metadata error {rel}: {ex}",
                                  file=sys.stderr, flush=True)
                    dirty = True
                    if (stats["promoted"] + stats["ttp"]) % 500 == 0:
                        save_index(out, idx, scope["index"])
                        dirty = False
                    continue

            if chosen is None:
                stats["no_app"] += 1
                if args.list:
                    print(f"  skip {rel}: no application candidate")
                continue

            if args.list:
                print(f"  {rel}: {preview} <= {chosen}")
            if args.dry_run:
                stats["promoted"] += 1
                continue

            preview_path = mirror / preview
            candidate_path = mirror / chosen
            tmp = mirror / f".{base}.promote.tmp.png"
            try:
                tmp.unlink(missing_ok=True)
                os.replace(preview_path, tmp)
                try:
                    os.replace(candidate_path, preview_path)
                    os.replace(tmp, candidate_path)
                except OSError:
                    if tmp.exists():
                        if not preview_path.exists():
                            os.replace(tmp, preview_path)
                        elif not candidate_path.exists():
                            os.replace(tmp, candidate_path)
                    raise
            except OSError as ex:
                stats["errors"] += 1
                print(f"  swap error {rel}: {ex}", file=sys.stderr,
                      flush=True)
                continue

            e["status"] = "done"
            e["kind"] = args.kind
            meta = metadata_path(mirror, base)
            if meta is not None:
                try:
                    with open(meta, "r", encoding="utf-8") as fh:
                        md = json.load(fh)
                    md["status"] = "done"
                    md["kind"] = args.kind
                    md["preview_is_desktop"] = False
                    write_json_atomic(meta, md)
                    stats["metadata"] += 1
                except Exception as ex:
                    stats["errors"] += 1
                    print(f"  metadata error {rel}: {ex}",
                          file=sys.stderr, flush=True)
            stats["promoted"] += 1
            dirty = True
            if (stats["promoted"] + stats["ttp"]) % 500 == 0:
                print(f"  ... {stats['promoted']} promoted, "
                      f"{stats['ttp']} TTP reset", flush=True)
                save_index(out, idx, scope["index"])
                dirty = False
    finally:
        try:
            if dirty and not args.dry_run:
                save_index(out, idx, scope["index"])
        finally:
            release_lock(lock)

    print(f"promote-app-screens[{scope['name']}]: scanned "
          f"{stats['scanned']}, promoted {stats['promoted']}, TTP reset "
          f"{stats['ttp']}, no app {stats['no_app']}, skipped file "
          f"{stats['skip_file']}/blank {stats['skip_blank']}/desktop "
          f"{stats['skip_desktop']}, missing {stats['missing']}, metadata "
          f"{stats['metadata']}, errors {stats['errors']}"
          + (" [dry-run, nothing changed]" if args.dry_run else ""))
    return 0


def cmd_reclassify(cfg: dict, P: dict, args, scope: dict) -> int:
    """Offline pass: split coarse ``desktop`` kinds into finer categories.

    Walks index entries with ``status == "desktop"``, re-analyzes their
    preview and refines the entry ``kind`` (SPEC section 8.4.1):

    - ``desktop``   - real TOS desktop (green work surface)
    - ``textscreen``- crack intro / text screen on a light background
    - ``darkscreen``- text screen on a darker/colored background

    The ``status`` stays ``desktop``, so detect/retry/desktop-app/gallery
    behavior is unchanged. Only the index ``kind`` and the per-entry
    metadata JSON are updated. Entries without a preview PNG (e.g. the
    drive-LED resets) are skipped and reported.
    """
    out = Path(P["out"])
    idx = load_index(out, scope["index"])
    entries = idx["entries"]
    lock = acquire_lock(out)
    stats = {"scanned": 0, "updated": 0, "no_preview": 0,
             "errors": 0, "kinds": {}}
    try:
        targets = [rel for rel in sorted(entries)
                   if entries[rel].get("status") == "desktop"
                   and (not args.only
                        or args.only.lower() in rel.lower())]
        print(f"desktop entries: {len(targets)}", flush=True)
        for i, rel in enumerate(targets, 1):
            if STOP_EVENT.is_set():
                print("interrupted", flush=True)
                break
            e = entries[rel]
            stats["scanned"] += 1
            prev = e.get("preview")
            mirror = out / Path(rel).parent
            if not prev or not (mirror / prev).is_file():
                stats["no_preview"] += 1
                continue
            try:
                metrics = analyze_image(mirror / prev, cfg)
            except Exception as ex:
                stats["errors"] += 1
                print(f"  analyze error {rel}: {ex}",
                      file=sys.stderr, flush=True)
                continue
            new_kind = refine_desktop_kind(metrics["kind"], metrics, cfg)
            stats["kinds"][new_kind] = stats["kinds"].get(new_kind, 0) + 1
            if new_kind == e.get("kind"):
                continue
            if args.dry_run:
                stats["updated"] += 1
                continue
            e["kind"] = new_kind
            meta = metadata_path(mirror, safe_filename(Path(rel).stem))
            if meta is not None:
                try:
                    with open(meta, "r", encoding="utf-8") as fh:
                        md = json.load(fh)
                    md["kind"] = new_kind
                    md["preview_is_desktop"] = True
                    with open(meta, "w", encoding="utf-8") as fh:
                        json.dump(md, fh, indent=1)
                except Exception as ex:
                    print(f"  metadata error {rel}: {ex}",
                          file=sys.stderr, flush=True)
            stats["updated"] += 1
            if i % 500 == 0:
                print(f"  ... {i}/{len(targets)}", flush=True)
                save_index(out, idx, scope["index"])
        if not args.dry_run:
            save_index(out, idx, scope["index"])
    finally:
        release_lock(lock)

    kinds = ", ".join(f"{k} {v}" for k, v in sorted(stats["kinds"].items()))
    listed = ""
    if getattr(args, "list", ""):
        listed = f" [list '{args.list}']"
    print(f"reclassify[{scope['name']}]: scanned {stats['scanned']}, "
          f"updated "
          f"{stats['updated']}, kinds ({kinds or '-'}), "
          f"no preview {stats['no_preview']}, errors {stats['errors']}"
          + (" [dry-run, nothing changed]" if args.dry_run else "")
          + listed)
    if args.list:
        sel = [rel for rel in sorted(entries)
               if entries[rel].get("kind") == args.list
               and (not args.only or args.only.lower() in rel.lower())]
        print(f"\nkind '{args.list}': {len(sel)}")
        for rel in sel:
            print(f"  {rel}")
    return 0


def cmd_prune(cfg: dict, P: dict, args, scope: dict) -> int:
    """Remove output left behind by index entries that no longer exist.

    Deletes per-entry ``logs/<rel>.log`` files whose index entry is gone and
    any mirror directories that became empty (bottom-up, only truly empty
    directories are removed, never ones that still hold files). Useful after
    excluding directories (section 4.4) or rescoping. Only this scope's
    trees and index are considered; other scopes' files are never touched.
    """
    out = Path(P["out"])
    idx = load_index(out, scope["index"])
    entries = idx["entries"]
    lock = acquire_lock(out)
    stats = {"logs": 0, "dirs": 0}
    scope_roots = [out / s for s in scope["trees"]]

    def _in_scope(rel: str) -> bool:
        return any(rel == t or rel.startswith(t + "/")
                   for t in scope["trees"])

    try:
        # 1. logs/<rel>.log  ->  drop when <rel> is not in the index.
        # Walk only this scope's log subtrees (never the whole logs/ tree,
        # which holds every scope's logs and is slow on the NAS).
        logs_root = out / "logs"
        if logs_root.is_dir():
            expected = {
                (Path(rel).parent / safe_filename(Path(rel).stem)).as_posix()
                for rel in entries
            }
            for tree in scope["trees"]:
                sub = logs_root / tree
                if not sub.is_dir():
                    continue
                for log in sub.rglob("*.log"):
                    if STOP_EVENT is not None and STOP_EVENT.is_set():
                        break
                    rel = log.relative_to(logs_root).with_suffix("").as_posix()
                    if not _in_scope(rel):
                        continue
                    if rel in expected:
                        continue
                    stats["logs"] += 1
                    if not args.dry_run:
                        log.unlink(missing_ok=True)

        # 2. empty mirror directories under each scope root (bottom-up).
        # Directory collection uses os.walk so Ctrl+C is honoured even on
        # a slow NAS (a single rglob().sorted() would only be interruptible
        # after the whole subtree was listed).
        for root in scope_roots:
            if not root.is_dir():
                continue
            dirs = []
            for dp, dns, _fns in os.walk(root):
                if STOP_EVENT is not None and STOP_EVENT.is_set():
                    break
                dirs.extend(Path(dp) / d for d in dns)
            dirs.sort(key=lambda p: len(p.parts), reverse=True)
            for d in dirs:
                if STOP_EVENT is not None and STOP_EVENT.is_set():
                    break
                try:
                    if any(d.iterdir()):
                        continue
                except OSError:
                    continue
                stats["dirs"] += 1
                if not args.dry_run:
                    try:
                        d.rmdir()
                    except OSError:
                        pass
    finally:
        release_lock(lock)

    print(f"prune[{scope['name']}]: logs {stats['logs']}, "
          f"empty dirs {stats['dirs']}"
          + (" [dry-run, nothing changed]" if args.dry_run else ""))
    return 0


def main() -> int:
    global STOP_EVENT
    STOP_EVENT = threading.Event()

    # Cap the glibc arena count before any worker thread is created. glibc
    # creates one arena per thread (up to 8 by default); a long parallel run
    # fragmented those mmap'd arenas until the process hit the OOM killer
    # even though the Python heap stayed flat. Two arenas suffice for this
    # workload and keep the footprint bounded (the per-entry malloc_trim in
    # the worker loop then returns the freed blocks).
    os.environ.setdefault("MALLOC_ARENA_MAX", "2")

    # 'html' was removed: point users at the gallery webapp (M6).
    if len(sys.argv) > 1 and sys.argv[1] == "html":
        print("shotgen html was removed and replaced by the gallery "
              "webapp:\n  tools/gallery/run.sh   "
              "(see SPEC-gallery-webapp.md)", file=sys.stderr)
        return 2

    def _stop(signum, frame):
        if STOP_EVENT.is_set():
            print("\nforce exit", flush=True)
            os._exit(130)
        STOP_EVENT.set()
        print("\ninterrupt: finishing up (Ctrl+C again to force)",
              flush=True)

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    ap = argparse.ArgumentParser(prog="shotgen",
                                 description="Marcer GameDVD screenshot "
                                             "generator")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def _scope_arg(p):
        p.add_argument("--scope", type=str, default="",
                       help="config scope to work on (default: the "
                            "configured scope_default)")

    p_index = sub.add_parser("index", help="build/refresh the zip index")
    _scope_arg(p_index)
    p_index.add_argument("--full", action="store_true",
                         help="rescan metadata of all entries")

    p_run = sub.add_parser("run", help="process pending entries")
    _scope_arg(p_run)
    p_run.add_argument("--limit", type=int, default=0,
                       help="max entries this invocation")
    p_run.add_argument("--hours", type=float, default=0,
                       help="stop starting new entries after N hours")
    p_run.add_argument("--force", action="store_true",
                       help="reprocess done/desktop entries too")
    p_run.add_argument("--only", type=str, default="",
                       help="only entries whose path contains this string")
    p_run.add_argument("--jobs", type=int, default=1,
                       help="parallel workers, each runs one Hatari instance "
                            "in the shared Xvfb display (default: 1 = "
                            "serial)")
    p_run.add_argument("--retry-desktop", action="store_true",
                       help="retry desktop-only entries with a detected icon: "
                            "click it once after boot, then capture "
                            "(requires a prior 'detect' run)")
    p_run.add_argument("--retry-desktop-auto", action="store_true",
                       help="retry desktop-only entries by scanning the image/"
                            "archive for a launchable program and starting it "
                            "with --auto (no GEM desktop clicks)")
    p_run.add_argument("--retry-no-usable", action="store_true",
                       help="retry only entries that ended as no_usable_shots "
                            "(not reprocessed by a normal run)")
    p_run.add_argument("--tos", type=str, default="",
                       help="TOS version label to boot with (default: config "
                            "tos_default, e.g. 1.04). Use e.g. "
                            "'--retry-no-usable --tos 1.02' for old titles "
                            "that hang on TOS 1.04")
    p_run.add_argument("--retry-drive-led", action="store_true",
                       help="retry the bootable drive-LED resets "
                            "(status desktop + drive_led_refetch): capture "
                            "them again with --drive-led false")

    p_detect = sub.add_parser(
        "detect",
        help="find the program icon in existing desktop previews "
             "(offline, no Hatari)")
    _scope_arg(p_detect)
    p_detect.add_argument("--force", action="store_true",
                          help="redetect even if a result already exists")
    p_detect.add_argument("--only", type=str, default="",
                          help="only paths containing this substring")

    p_clean = sub.add_parser(
        "cleanup-drive-led",
        help="delete previews that only show Hatari's drive-LED overlay "
             "and clean the index")
    _scope_arg(p_clean)
    p_clean.add_argument("--dry-run", action="store_true",
                         help="report what would be removed, change nothing")
    p_clean.add_argument("--only", type=str, default="",
                         help="only paths containing this substring")

    p_dedup = sub.add_parser(
        "cleanup-duplicates",
        help="delete pixel-exact duplicate candidate PNGs and clean the "
             "index (offline, no Hatari)")
    _scope_arg(p_dedup)
    p_dedup.add_argument("--dry-run", action="store_true",
                         help="report what would be removed, change nothing")
    p_dedup.add_argument("--only", type=str, default="",
                         help="only paths containing this substring")
    p_dedup.add_argument("--candidates-only", action="store_true",
                         help="compare candidates only, ignore the preview")
    p_dedup.add_argument("--list", action="store_true",
                         help="print the removed candidate names per entry")

    p_blogo = sub.add_parser(
        "cleanup-boot-logo",
        help="delete the static Falcon boot-logo candidates and clean the "
             "index (offline, no Hatari)")
    _scope_arg(p_blogo)
    p_blogo.add_argument("--dry-run", action="store_true",
                         help="report what would be removed, change nothing")
    p_blogo.add_argument("--only", type=str, default="",
                         help="only paths containing this substring")
    p_blogo.add_argument("--list", action="store_true",
                         help="print the removed candidate names per entry")

    p_promote = sub.add_parser(
        "promote-app-screens",
        help="offline: promote the app-screen candidate of desktop entries "
             "(skips TTP/file/blank/desktop candidates; no Hatari)")
    _scope_arg(p_promote)
    p_promote.add_argument("--dry-run", action="store_true",
                           help="report what would be promoted, change nothing")
    p_promote.add_argument("--only", type=str, default="",
                           help="only paths containing this substring")
    p_promote.add_argument("--list", action="store_true",
                           help="print preview and chosen candidate per entry")
    p_promote.add_argument("--candidate", type=int, default=0,
                           help="use this 1-based candidate instead of the "
                                "open-window rule")
    p_promote.add_argument("--kind", type=str, default="game",
                           choices=("game", "textscreen", "darkscreen"),
                           help="kind to set on promoted entries (default: "
                                "game)")

    p_recl = sub.add_parser(
        "reclassify",
        help="offline: split coarse desktop kinds into desktop/textscreen/"
             "darkscreen (no Hatari)")
    _scope_arg(p_recl)
    p_recl.add_argument("--dry-run", action="store_true",
                        help="report the kind counts, change nothing")
    p_recl.add_argument("--only", type=str, default="",
                        help="only paths containing this substring")
    p_recl.add_argument("--list", type=str, default="",
                        help="print the paths of this kind after the pass "
                             "(desktop|textscreen|darkscreen)")

    p_prune = sub.add_parser(
        "prune",
        help="remove logs and empty output directories of removed entries")
    _scope_arg(p_prune)
    p_prune.add_argument("--dry-run", action="store_true",
                         help="report what would be removed, change nothing")

    args = ap.parse_args()
    if args.cmd == "run" and args.jobs < 1:
        ap.error("--jobs must be >= 1")
    retry_flags = [getattr(args, f, False) for f in
                   ("retry_desktop", "retry_desktop_auto", "retry_no_usable",
                    "retry_drive_led")]
    if sum(1 for v in retry_flags if v) > 1:
        ap.error("--retry-desktop, --retry-desktop-auto, --retry-no-usable "
                 "and --retry-drive-led are mutually exclusive")
    cfg = load_config()
    scope_default, scopes = resolve_scopes(cfg)
    scope_name = (args.scope or scope_default).strip()
    if scope_name not in scopes:
        ap.error(f"unknown scope {scope_name!r} "
                 f"(available: {', '.join(sorted(scopes))})")
    scope = scopes[scope_name]
    P = paths()

    if args.cmd == "index":
        return cmd_index(cfg, P, args, scope)
    if args.cmd == "run":
        return cmd_run(cfg, P, args, scope)
    if args.cmd == "detect":
        return cmd_detect(cfg, P, args, scope)
    if args.cmd == "cleanup-drive-led":
        return cmd_cleanup_drive_led(cfg, P, args, scope)
    if args.cmd == "cleanup-duplicates":
        return cmd_cleanup_duplicates(cfg, P, args, scope)
    if args.cmd == "cleanup-boot-logo":
        return cmd_cleanup_boot_logo(cfg, P, args, scope)
    if args.cmd == "promote-app-screens":
        return cmd_promote_app_screens(cfg, P, args, scope)
    if args.cmd == "reclassify":
        return cmd_reclassify(cfg, P, args, scope)
    if args.cmd == "prune":
        return cmd_prune(cfg, P, args, scope)
    return 2


if __name__ == "__main__":
    sys.exit(main())
