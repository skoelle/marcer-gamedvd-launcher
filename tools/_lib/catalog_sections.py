# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Section trees, layer overlay and ZIP scanning shared by the catalog tools.

`shotgen` owns the canonical definition of the catalog sections (cracked, pd,
utils, magazine, falcon). The pipeline tools before the screenshot step
(`full-index-gen`, `crew-analysis`) must produce the same relative paths and
layer flags without reading the screenshot index, so the section/scan/overlay
rules live here.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

DEFAULT_SCOPE = "cracked"

DEFAULT_SCOPES = {
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
}

DEFAULT_EXCLUDE_DIRS = ["kryoflux", "boxscan", "manual"]

DEFAULT_DISK_SKIP_REGEX = (
    r"(?i)(?:^|[\s\-_.])(?:disk|side|disc)[\s\-_.]*"
    r"(?:[2-9]|b|ii|iii)(?:$|[\s\-_.])"
)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def shotgen_config_dir() -> Path:
    return repo_root() / "tools" / "screenshot-gen"


def deep_merge(base: dict, over: dict) -> None:
    for key, value in over.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            deep_merge(base[key], value)
        else:
            base[key] = value


def load_config() -> dict:
    """Load the section-related shotgen config (defaults + local overrides).

    Only the keys needed by the pipeline tools are returned; `shotgen` keeps
    the full config for Hatari/monitor/capture settings.
    """
    cfg = {
        "scope_default": DEFAULT_SCOPE,
        "scopes": json.loads(json.dumps(DEFAULT_SCOPES)),
        "exclude_dirs": list(DEFAULT_EXCLUDE_DIRS),
        "disk_skip_regex": DEFAULT_DISK_SKIP_REGEX,
    }
    root = shotgen_config_dir()
    for name in ("config.example.json", "config.local.json"):
        path = root / name
        if not path.exists():
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                over = json.load(handle)
        except (OSError, ValueError):
            continue
        deep_merge(cfg, over)
    return cfg


def resolve_scopes(cfg: dict) -> tuple[str, dict]:
    """Return ``(default_scope, {name: scope})`` for the configured scopes."""
    default = (cfg.get("scope_default") or DEFAULT_SCOPE).strip()
    raw = cfg.get("scopes") or {}
    if not raw:
        raw = {
            "cracked": {
                "trees": cfg.get("scope_trees") or DEFAULT_SCOPES["cracked"]["trees"]
            }
        }
        default = "cracked"
    scopes = {}
    for name, spec in raw.items():
        if not isinstance(spec, dict):
            raise ValueError(f"scopes.{name} must be an object with a trees list")
        trees = [str(tree) for tree in (spec.get("trees") or [])]
        if not trees:
            raise ValueError(f"scope {name!r} has no trees")
        index = spec.get("index")
        if not index:
            index = "index.json" if name == default else f"index-{name}.json"
        scopes[name] = {
            "name": name,
            "trees": trees,
            "index": index,
            "exclude_dirs": [str(d) for d in (spec.get("exclude_dirs") or [])],
            "profile": spec.get("profile") or {},
            "tos_default": spec.get("tos_default"),
            "timepoints": spec.get("timepoints"),
            "boot": spec.get("boot"),
        }
    if default not in scopes:
        raise ValueError(
            f"scope_default {default!r} is not defined in scopes "
            f"({', '.join(sorted(scopes))})"
        )
    return default, scopes


def is_ignored(name: str) -> bool:
    return name.startswith(".") or name.startswith("@")


def norm_dir(name: str) -> str:
    """Lowercase a directory name without spaces/underscores/dashes."""
    return re.sub(r"[\s_-]", "", name.lower())


def excluded_dirs(cfg: dict, scope: dict | None = None) -> set[str]:
    """Normalized directory names never entered by the scan."""
    names = list(cfg.get("exclude_dirs") or [])
    if scope:
        names += list(scope.get("exclude_dirs") or [])
    return {norm_dir(name) for name in names}


def scan_tree(
    layer_base: Path,
    tree: str,
    disk_re=None,
    exclude: set[str] | None = None,
    should_stop=None,
    on_error=None,
) -> dict[str, dict]:
    """Return ``{relpath: {size, mtime}}`` for ZIPs under ``layer_base/tree``.

    ``disk_re`` is accepted for signature compatibility with `shotgen`; disk
    classification happens after the merge. ``should_stop`` is an optional
    callable used by long-running tools to abort early.
    """
    exclude = exclude or set()
    found: dict[str, dict] = {}
    base = layer_base / tree
    if not base.is_dir():
        return found
    stack = [base]
    while stack:
        if should_stop is not None and should_stop():
            break
        directory = stack.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    if is_ignored(entry.name):
                        continue
                    if entry.is_dir(follow_symlinks=False):
                        if norm_dir(entry.name) in exclude:
                            continue
                        stack.append(entry.path)
                    elif entry.name.lower().endswith(".zip"):
                        rel = Path(entry.path).relative_to(layer_base).as_posix()
                        try:
                            stat = entry.stat(follow_symlinks=False)
                        except OSError:
                            continue
                        found[rel] = {
                            "size": stat.st_size,
                            "mtime": int(stat.st_mtime),
                        }
        except OSError as error:
            if on_error is not None:
                on_error(f"scan error {directory}: {error}")
            continue
    return found


def canonical_merge(root_map: dict[str, dict], patch_map: dict[str, dict]) -> dict:
    """Overlay two layer scans with the launcher's case-insensitive rules.

    A patch file whose name differs only in case from a root file overrides
    it, and the patch spelling becomes the canonical ``rel``. A directory
    that exists in both layers under different spellings uses the patch
    spelling for every file below it (SPEC §7).

    Returns ``{rel: {size, mtime, layer, src_layer, src_rel}}`` where
    ``src_layer`` is the layer holding the winning bytes and ``src_rel`` is
    that layer's own path spelling (only set when it differs from ``rel``).
    """
    merged: dict[str, list] = {}
    for rel, info in root_map.items():
        merged[rel.lower()] = [rel, info, "ROOT"]
    for rel, info in patch_map.items():
        key = rel.lower()
        if key in merged:
            merged[key] = [rel, info, "BOTH"]
        else:
            merged[key] = [rel, info, "PATCH"]

    canon_dirs: dict[str, str] = {}
    for rel in root_map:
        parent = str(Path(rel).parent)
        canon_dirs.setdefault(parent.lower(), parent)
    for rel in patch_map:
        parent = str(Path(rel).parent)
        canon_dirs[parent.lower()] = parent

    result: dict[str, dict] = {}
    for key in sorted(merged):
        rel, info, layer = merged[key]
        original_rel = rel
        parent = canon_dirs.get(str(Path(rel).parent).lower())
        if parent:
            rel = (
                str(Path(parent) / Path(rel).name)
                if parent != "."
                else Path(rel).name
            )
        src_layer = "PATCH" if layer in ("PATCH", "BOTH") else "ROOT"
        result[rel] = {
            "size": int(info.get("size") or 0),
            "mtime": int(info.get("mtime") or 0),
            "layer": layer,
            "src_layer": src_layer,
            "src_rel": original_rel if original_rel != rel else None,
        }
    return result


def is_skipped_disk(name: str, regex: str | None = None) -> bool:
    pattern = regex or DEFAULT_DISK_SKIP_REGEX
    return re.search(pattern, name) is not None
