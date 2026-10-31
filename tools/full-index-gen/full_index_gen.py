#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Build the screenshot-independent full catalog index (`full-index.json.gz`).

The index lists every ZIP of the catalog sections (cracked, pd, utils,
magazine, falcon) with its layer, size/mtime, disk-image hashes and a stable
container fingerprint. It is generated from the game trees alone, so new ZIPs
become visible in the desktop app before screenshots exist. The screenshot
index (`index*.json`) remains the authority for screenshot state and is
merged into the full index by the app.

Output: ``<MARCER_DATA_DIR>/gameinfo/full-index.json.gz``. The file is
deterministic (no timestamp), so `asset-publish` only creates a new gameinfo
archive when the catalog actually changed.
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from _lib import catalog_sections as cs  # noqa: E402
from _lib import zip_hashes  # noqa: E402

TOOL_VERSION = "0.1.0"
SCHEMA = 1
GAMEINFO_SUBDIR = "gameinfo"
FILE_NAME = "full-index.json.gz"


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, "").strip() or default


def default_output() -> Path:
    data = env("MARCER_DATA_DIR")
    if not data:
        sys.exit("error: MARCER_DATA_DIR is not set (add it to local/paths.env)")
    return Path(data) / GAMEINFO_SUBDIR / FILE_NAME


def load_index(path: Path) -> dict:
    if not path.is_file():
        return {"entries": {}}
    try:
        with gzip.open(path, "rt", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError, gzip.BadGzipFile):
        return {"entries": {}}
    if not isinstance(data, dict):
        return {"entries": {}}
    data.setdefault("entries", {})
    return data


def write_index(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(
        data, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    blob = gzip.compress(payload, compresslevel=6, mtime=0)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "wb") as handle:
        handle.write(blob)
    os.replace(tmp, path)


def selected_scopes(cfg: dict, requested: list[str]) -> dict:
    try:
        _, scopes = cs.resolve_scopes(cfg)
    except ValueError as error:
        sys.exit(f"error: {error}")
    if not requested:
        return scopes
    unknown = [name for name in requested if name not in scopes]
    if unknown:
        sys.exit(
            f"error: unknown scope(s) {', '.join(unknown)} "
            f"(known: {', '.join(sorted(scopes))})"
        )
    return {name: scopes[name] for name in requested}


def build_scan(
    cfg: dict,
    scopes: dict,
    root: Path,
    patch: Path | None,
    only: list[str] | None = None,
) -> dict:
    """Return ``{rel: {section, name, size, mtime, layer, src_layer, src_rel}}``."""
    entries: dict[str, dict] = {}

    def on_error(message: str) -> None:
        print(message, file=sys.stderr, flush=True)

    for scope in scopes.values():
        exclude = cs.excluded_dirs(cfg, scope)
        for tree in scope["trees"]:
            print(f"scan scope[{scope['name']}]: {tree}", flush=True)
            root_map = cs.scan_tree(root, tree, exclude=exclude, on_error=on_error)
            patch_map = (
                cs.scan_tree(patch, tree, exclude=exclude, on_error=on_error)
                if patch
                else {}
            )
            merged = cs.canonical_merge(root_map, patch_map)
            for rel, item in merged.items():
                if only and not any(value.lower() in rel.lower() for value in only):
                    continue
                entry = {
                    "section": scope["name"],
                    "name": Path(rel).name,
                    "size": item["size"],
                    "mtime": item["mtime"],
                    "layer": item["layer"],
                    "src_layer": item["src_layer"],
                    "src_rel": item["src_rel"],
                }
                # A rel is unique across sections in practice; keep the first
                # section if a tree is configured twice.
                entries.setdefault(rel, entry)
    return entries


def resolve_path(root: Path, patch: Path | None, entry: dict, rel: str) -> Path:
    base = patch if entry["src_layer"] == "PATCH" and patch else root
    return base / (entry.get("src_rel") or rel)


def hash_jobs(
    jobs: list[tuple[str, Path]],
    workers: int,
    label: str,
) -> dict[str, tuple[list[dict], str]]:
    results: dict[str, tuple[list[dict], str]] = {}
    total = len(jobs)
    if total == 0:
        return results
    print(f"{label}: hashing {total} ZIP(s) with {workers} worker(s)", flush=True)
    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        futures = {
            pool.submit(zip_hashes.zip_members, path): rel
            for rel, path in jobs
        }
        done = 0
        for future in as_completed(futures):
            rel = futures[future]
            try:
                results[rel] = future.result()
            except Exception as error:  # pragma: no cover - defensive
                results[rel] = ([], str(error))
            done += 1
            if done % 200 == 0 or done == total:
                print(f"  ... {done}/{total}", flush=True)
    return results


def build_payload(
    scan: dict,
    old_entries: dict,
    full: bool,
    workers: int,
    root: Path,
    patch: Path | None,
) -> tuple[dict, dict]:
    entries: dict[str, dict] = {}
    errors: list[dict] = []
    jobs: list[tuple[str, Path]] = []
    reused = 0
    for rel in sorted(scan):
        item = scan[rel]
        old = None if full else old_entries.get(rel)
        if (
            old
            and old.get("size") == item["size"]
            and old.get("mtime") == item["mtime"]
            and old.get("section") == item["section"]
            and "members" in old
        ):
            members = old.get("members") or []
            fingerprint = old.get("fingerprint", "")
            reused += 1
        else:
            members = None
            fingerprint = ""
            jobs.append((rel, resolve_path(root, patch, item, rel)))
        entries[rel] = {
            "section": item["section"],
            "name": item["name"],
            "size": item["size"],
            "mtime": item["mtime"],
            "layer": item["layer"],
            "fingerprint": fingerprint,
            "members": members or [],
        }
        if item.get("src_rel"):
            entries[rel]["src_rel"] = item["src_rel"]

    results = hash_jobs(jobs, workers, "full-index")
    hashed = 0
    for rel in sorted(scan):
        if rel not in results:
            continue
        raw_members, error = results[rel]
        members = zip_hashes.payload(raw_members)
        entries[rel]["members"] = members
        entries[rel]["fingerprint"] = zip_hashes.fingerprint(raw_members)
        hashed += 1
        if error:
            errors.append({"rel": rel, "error": error})
        for member in raw_members:
            if member.get("error"):
                errors.append({
                    "rel": rel,
                    "member": member.get("name", ""),
                    "error": member["error"],
                })

    payload = {
        "schema": SCHEMA,
        "tool": "tools/full-index-gen",
        "tool_version": TOOL_VERSION,
        "counts": {
            "zips": len(entries),
            "members": sum(len(entry["members"]) for entry in entries.values()),
            "errors": len(errors),
        },
        "errors": errors,
        "entries": entries,
    }
    return payload, {"hashed": hashed, "reused": reused}


def command_run(args) -> int:
    cfg = cs.load_config()
    scopes = selected_scopes(cfg, args.scope)
    root = Path(args.root).expanduser()
    if not root.is_dir():
        sys.exit(f"error: root directory not found: {root}")
    patch = Path(args.patch).expanduser() if args.patch else None
    if patch and not patch.is_dir():
        sys.exit(f"error: patch directory not found: {patch}")

    if args.only and not args.out:
        sys.exit("error: --only requires an explicit --out (trial runs)")
    out = Path(args.out).expanduser() if args.out else default_output()
    if args.only:
        print(
            "warning: --only writes a filtered index; use --out for trial runs",
            file=sys.stderr,
        )
    scan = build_scan(cfg, scopes, root, patch, only=args.only)
    print(f"catalog ZIPs: {len(scan)}")
    if args.dry_run:
        return 0

    old = load_index(out)
    payload, stats = build_payload(
        scan,
        old.get("entries", {}),
        full=args.full,
        workers=args.workers,
        root=root,
        patch=patch,
    )
    write_index(out, payload)
    counts = payload["counts"]
    print(
        f"wrote {out}: {counts['zips']} zips, {counts['members']} members "
        f"(hashed {stats['hashed']}, reused {stats['reused']}, "
        f"errors {counts['errors']})"
    )
    return 0


def command_check(args) -> int:
    cfg = cs.load_config()
    scopes = selected_scopes(cfg, args.scope)
    root = Path(args.root).expanduser()
    if not root.is_dir():
        sys.exit(f"error: root directory not found: {root}")
    patch = Path(args.patch).expanduser() if args.patch else None
    out = Path(args.out).expanduser() if args.out else default_output()
    index = load_index(out)
    old_entries = index.get("entries", {})
    scan = build_scan(cfg, scopes, root, patch, only=args.only)

    missing = sorted(set(scan) - set(old_entries))
    extra = sorted(set(old_entries) - set(scan))
    changed = []
    for rel in sorted(set(scan) & set(old_entries)):
        new = scan[rel]
        old = old_entries[rel]
        if (
            old.get("size") != new["size"]
            or old.get("mtime") != new["mtime"]
            or old.get("section") != new["section"]
            or old.get("layer") != new["layer"]
        ):
            changed.append(rel)

    problems = bool(missing or extra or changed)
    print(f"index: {out}")
    print(f"entries: {len(old_entries)} (scan {len(scan)})")
    for label, values in (
        ("missing", missing),
        ("extra", extra),
        ("changed", changed),
    ):
        if values:
            print(f"{label}: {len(values)}")
            for rel in values[:20]:
                print(f"  {rel}")
            if len(values) > 20:
                print(f"  ... {len(values) - 20} more")
    if not problems:
        print("index is up to date")

    parity_ok = True
    if args.parity:
        parity_ok = check_parity(scopes, old_entries, root, patch)
    return 1 if problems or not parity_ok else 0


def check_parity(scopes: dict, entries: dict, root: Path, patch: Path | None) -> bool:
    """Compare rel/layer with the screenshot index for the same scopes."""
    screenshot_dir = env("MARCER_OUT_DIR")
    if not screenshot_dir:
        print("parity: MARCER_OUT_DIR is not set, skipped")
        return True
    ok = True
    for scope in scopes.values():
        path = Path(screenshot_dir) / scope["index"]
        if not path.is_file():
            print(f"parity[{scope['name']}]: {path} not found, skipped")
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                shot_entries = json.load(handle).get("entries", {})
        except (OSError, ValueError) as error:
            print(f"parity[{scope['name']}]: cannot read {path}: {error}")
            ok = False
            continue
        shot_rels = {
            rel
            for rel, value in shot_entries.items()
            if isinstance(value, dict)
            and (value.get("rel") or rel).startswith(
                tuple(f"{tree}/" for tree in scope["trees"])
            )
        }
        index_rels = {
            rel
            for rel, value in entries.items()
            if value.get("section") == scope["name"]
        }
        only_shot = sorted(shot_rels - index_rels)
        only_index = sorted(index_rels - shot_rels)
        layer_diff = sorted(
            rel
            for rel in shot_rels & index_rels
            if shot_entries.get(rel, {}).get("layer") != entries[rel].get("layer")
        )
        if only_shot or only_index or layer_diff:
            ok = False
            print(
                f"parity[{scope['name']}]: only screenshot {len(only_shot)}, "
                f"only full-index {len(only_index)}, layer differs "
                f"{len(layer_diff)}"
            )
            for label, values in (
                ("only screenshot", only_shot),
                ("only full-index", only_index),
                ("layer differs", layer_diff),
            ):
                for rel in values[:10]:
                    print(f"  {label}: {rel}")
        else:
            print(f"parity[{scope['name']}]: ok ({len(index_rels)} entries)")
    return ok


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build the screenshot-independent full catalog index.",
    )
    parser.add_argument(
        "command", nargs="?", default="run", choices=["run", "check"]
    )
    parser.add_argument("--root", default=env("MARCER_ROOT_DIR"))
    parser.add_argument("--patch", default=env("MARCER_PATCH_DIR"))
    parser.add_argument(
        "--out", default="", help="output path (default: <MARCER_DATA_DIR>/gameinfo/full-index.json.gz)"
    )
    parser.add_argument(
        "--scope", action="append", default=[], help="limit to a scope (repeatable)"
    )
    parser.add_argument(
        "--workers", type=int, default=int(env("MARCER_FULL_INDEX_WORKERS", "4"))
    )
    parser.add_argument("--full", action="store_true", help="re-hash every ZIP")
    parser.add_argument("--dry-run", action="store_true", help="scan only, no write")
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        help="only entries whose rel contains this text (repeatable; trial runs)",
    )
    parser.add_argument(
        "--parity",
        action="store_true",
        help="compare rel/layer with the screenshot index (check command)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.command == "check":
        return command_check(args)
    return command_run(args)


if __name__ == "__main__":
    raise SystemExit(main())
