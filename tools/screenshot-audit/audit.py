#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Audit screenshot indexes for false classifications and shared bad screens.

The audit is read-only by default. It uses the per-entry sidecar JSON files
(written by ``screenshot-gen``) to cluster shot pHashes across unrelated game
folders. Known cracktros/menus are whitelisted in ``screens.json``; error
screens are flagged and can be retried with TOS 1.02/1.00 via ``retry``.
"""
from __future__ import annotations

import argparse
import csv
import html
import json
import os
import shutil
import subprocess
import sys
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools" / "screenshot-gen"))

import shotgen  # noqa: E402

TOOL_VERSION = "0.1.0"
DEFAULT_REPORT_DIR = REPO_ROOT / "local" / "screenshot-audit"
DEFAULT_REGISTRY = Path(__file__).with_name("screens.json")
SECTION_INDEXES = {
    "cracked": "index.json",
    "pd": "index-pd.json",
    "utils": "index-utils.json",
    "magazine": "index-magazine.json",
    "falcon": "index-falcon.json",
}
ERROR_STATUSES = {"error", "interrupted", "pending"}


class AuditError(Exception):
    def __init__(self, stage: str, message: str) -> None:
        super().__init__(message)
        self.stage = stage


@dataclass
class Entry:
    section: str
    rel: str
    status: str
    kind: str | None
    monitor: str | None
    preview: str | None
    preview_path: Path | None
    sidecar_path: Path | None
    sidecar: dict | None = None
    shots: list[dict] = field(default_factory=list)
    preview_metrics: dict | None = None

    @property
    def folder(self) -> str:
        return Path(self.rel).parent.as_posix()


@dataclass
class HashItem:
    entry: Entry
    shot: dict


def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def out_dir() -> Path:
    value = env("MARCER_OUT_DIR")
    if not value:
        raise AuditError("config", "MARCER_OUT_DIR is not set (local/paths.env)")
    path = Path(value).expanduser()
    if not path.is_dir():
        raise AuditError("config", f"MARCER_OUT_DIR not found: {path}")
    return path


def load_registry(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise AuditError("registry", f"cannot read {path}: {exc}") from exc
    except ValueError as exc:
        raise AuditError("registry", f"invalid JSON in {path}: {exc}") from exc
    screens = data.get("screens")
    if not isinstance(screens, dict):
        raise AuditError("registry", f"{path}: missing 'screens' object")
    return screens


def registry_match(
    phash: str,
    registry: dict,
    max_dist: int = 2,
) -> tuple[str, dict] | None:
    best = None
    for value, info in registry.items():
        if not isinstance(info, dict):
            continue
        try:
            dist = shotgen.phash_distance(phash, value)
        except Exception:
            continue
        if dist <= max_dist and (best is None or dist < best[0]):
            best = (dist, info)
    return (str(best[1].get("action") or ""), best[1]) if best else None


def entry_preview_hash(entry: Entry, cfg: dict) -> str | None:
    if not entry.preview_path or not entry.preview_path.is_file():
        return None
    try:
        return str(shotgen.analyze_image(entry.preview_path, cfg)["phash"])
    except Exception:
        return None


def load_section(
    section: str,
    index_name: str,
    out: Path,
    workers: int,
    only: set[str] | None = None,
    cfg: dict | None = None,
) -> list[Entry]:
    idx = shotgen.load_index(out, index_name)
    raw = idx.get("entries") or {}
    entries = []
    for rel, data in raw.items():
        if only is not None and rel.casefold() not in only:
            continue
        preview = data.get("preview")
        mirror = out / Path(rel).parent
        sidecar_path = shotgen.metadata_path(
            mirror, shotgen.safe_filename(Path(rel).stem)
        )
        entries.append(
            Entry(
                section=section,
                rel=rel,
                status=str(data.get("status") or ""),
                kind=data.get("kind"),
                monitor=data.get("monitor"),
                preview=preview,
                preview_path=(mirror / preview) if preview else None,
                sidecar_path=sidecar_path,
            )
        )

    def load_one(entry: Entry) -> Entry:
        if cfg is not None and entry.preview_path and entry.preview_path.is_file():
            try:
                entry.preview_metrics = shotgen.analyze_image(entry.preview_path, cfg)
            except Exception:
                entry.preview_metrics = None
        if entry.sidecar_path is None:
            return entry
        try:
            with open(entry.sidecar_path, encoding="utf-8") as handle:
                entry.sidecar = json.load(handle)
            entry.shots = list(entry.sidecar.get("shots") or [])
        except (OSError, ValueError):
            entry.sidecar = None
        return entry

    if workers <= 1:
        return [load_one(entry) for entry in entries]
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(load_one, entry) for entry in entries]
        done = 0
        for future in as_completed(futures):
            future.result()
            done += 1
            if done % 2000 == 0:
                print(f"  {section}: {done}/{len(entries)} sidecars", flush=True)
    return entries


def collect_entries(
    sections: list[str],
    out: Path,
    workers: int,
    cfg: dict | None = None,
) -> list[Entry]:
    entries: list[Entry] = []
    for section in sections:
        print(f"scan section[{section}]", flush=True)
        entries.extend(
            load_section(
                section, SECTION_INDEXES[section], out, workers, cfg=cfg
            )
        )
    return entries


def build_hash_items(entries: list[Entry]) -> dict[str, list[HashItem]]:
    items: dict[str, list[HashItem]] = defaultdict(list)
    for entry in entries:
        metrics = entry.preview_metrics
        phash = str((metrics or {}).get("phash") or "").strip()
        if phash:
            items[phash].append(HashItem(entry, metrics or {}))
    return dict(items)


def cluster_hashes(hashes: list[str], max_dist: int) -> list[list[str]]:
    """Return pHash clusters (exact, or near via 16-bit bands)."""
    if not hashes:
        return []
    parent = list(range(len(hashes)))

    def find(a: int) -> int:
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    if max_dist <= 0:
        exact: dict[str, int] = {}
        for i, value in enumerate(hashes):
            if value in exact:
                union(i, exact[value])
            else:
                exact[value] = i
    else:
        buckets: dict[tuple[int, int], list[int]] = defaultdict(list)
        for i, value in enumerate(hashes):
            number = int(value, 16)
            for band in range(4):
                buckets[(band, (number >> (16 * band)) & 0xFFFF)].append(i)
        for bucket in buckets.values():
            if len(bucket) < 2:
                continue
            # A 64-bit distance <= 3 must share at least one exact 16-bit band.
            for x in range(len(bucket)):
                a = bucket[x]
                for y in range(x + 1, len(bucket)):
                    b = bucket[y]
                    if find(a) == find(b):
                        continue
                    if shotgen.phash_distance(hashes[a], hashes[b]) <= max_dist:
                        union(a, b)

    groups: dict[int, list[str]] = defaultdict(list)
    for i, value in enumerate(hashes):
        groups[find(i)].append(value)
    return list(groups.values())


def cluster_info(
    cluster: list[str],
    items: dict[str, list[HashItem]],
    registry: dict,
    min_folders: int,
    registry_dist: int,
) -> dict | None:
    by_hash = {value: items.get(value, []) for value in cluster}
    all_items = [item for values in by_hash.values() for item in values]
    entries = {item.entry.rel: item.entry for item in all_items}
    folders = {item.entry.folder for item in all_items}
    if not entries:
        return None
    matched_action = None
    matched_info = None
    matched_hash = None
    for value in cluster:
        match = registry_match(value, registry, registry_dist)
        if match and match[0]:
            matched_action, matched_info = match
            matched_hash = value
            if matched_action == "error":
                break
    status_counts = Counter(item.entry.status for item in all_items)
    if matched_action not in ("error", "valid"):
        if len(folders) < min_folders:
            return None
        if not any(
            status_counts.get(status, 0)
            for status in ("done", "error", "interrupted")
        ):
            return None
    representative = next(
        (
            item.entry
            for item in all_items
            if item.entry.status == "done"
            and item.entry.preview_path
            and item.entry.preview_path.is_file()
        ),
        None,
    ) or next(
        (
            item.entry
            for item in all_items
            if item.entry.preview_path and item.entry.preview_path.is_file()
        ),
        None,
    ) or next(
        (item.entry for item in all_items if item.entry.preview_path),
        None,
    )
    return {
        "hashes": sorted(cluster),
        "matched_hash": matched_hash,
        "action": matched_action or "review",
        "label": (matched_info or {}).get("label", ""),
        "notes": (matched_info or {}).get("notes", ""),
        "entries": sorted(entries),
        "entry_count": len(entries),
        "folders": sorted(folders),
        "folder_count": len(folders),
        "sections": sorted({item.entry.section for item in all_items}),
        "shot_kinds": dict(Counter(str(item.shot.get("kind")) for item in all_items)),
        "status_counts": dict(status_counts),
        "representative": representative,
        "items": all_items,
    }


def blank_entry(entry: Entry) -> bool:
    metrics = entry.preview_metrics
    if not metrics:
        return False
    return (
        float(metrics.get("std") or 0) < 5
        or int(metrics.get("unique_colors") or 99) <= 1
    )


def entry_flags(
    entries: list[Entry],
    registry: dict,
    registry_dist: int,
) -> list[dict]:
    flags: list[dict] = []
    for entry in entries:
        reasons: list[str] = []
        if entry.status in ERROR_STATUSES:
            reasons.append(f"status:{entry.status}")
        if entry.status in ("done", "desktop") and not entry.preview:
            reasons.append("preview:missing")
        if entry.status == "no_usable_shots" and entry.preview:
            reasons.append("no_usable:has_preview")
        if entry.monitor in (None, "") and entry.preview:
            reasons.append("monitor:unknown")
        if entry.status == "done" and entry.kind not in (
            "game", "textscreen", "darkscreen",
        ):
            reasons.append(f"done:kind:{entry.kind}")
        if entry.status == "desktop" and entry.kind in (
            "game", "textscreen", "darkscreen",
        ):
            reasons.append(f"desktop:kind:{entry.kind}")
        if entry.sidecar is None:
            reasons.append("sidecar:missing")
        error_hash = None
        preview_hash = str((entry.preview_metrics or {}).get("phash") or "")
        if preview_hash:
            match = registry_match(preview_hash, registry, registry_dist)
            if match and match[0] == "error":
                reasons.append("known_error_screen")
                error_hash = preview_hash
        if entry.status in ("done", "desktop") and blank_entry(entry):
            reasons.append("blank")
        if reasons:
            flags.append(
                {
                    "section": entry.section,
                    "rel": entry.rel,
                    "status": entry.status,
                    "kind": entry.kind,
                    "monitor": entry.monitor,
                    "reasons": sorted(set(reasons)),
                    "phash": error_hash,
                    "preview": str(entry.preview_path) if entry.preview_path else "",
                }
            )
    return flags


def make_contact_sheet(images: list[Path], target: Path, columns: int = 4) -> bool:
    from PIL import Image, ImageDraw

    usable = [path for path in images if path.is_file()][:24]
    if not usable:
        return False
    thumb_w, thumb_h = 320, 220
    label_h = 18
    rows = (len(usable) + columns - 1) // columns
    sheet = Image.new("RGB", (columns * thumb_w, rows * (thumb_h + label_h)), "white")
    draw = ImageDraw.Draw(sheet)
    for index, path in enumerate(usable):
        try:
            with Image.open(path) as img:
                img = img.convert("RGB")
                img.thumbnail((thumb_w, thumb_h))
                x = (index % columns) * thumb_w
                y = (index // columns) * (thumb_h + label_h)
                sheet.paste(img, (x + (thumb_w - img.width) // 2, y))
                draw.text((x + 4, y + thumb_h + 2), path.parent.name[:44], fill="black")
        except OSError:
            continue
    target.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(target)
    return True


def write_csv(path: Path, rows: list[dict]) -> None:
    fields = [
        "section", "rel", "status", "kind", "monitor", "reasons", "phash", "preview",
    ]
    with open(path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fields})


def write_report(
    path: Path,
    summary: dict,
    clusters: list[dict],
    flags: list[dict],
    sheets: dict[int, Path],
) -> None:
    def esc(value) -> str:
        return html.escape(str(value))

    parts = [
        "<!doctype html><meta charset='utf-8'>",
        "<title>Screenshot audit</title>",
        "<style>body{font-family:sans-serif;margin:2rem;}"
        "table{border-collapse:collapse;margin:1rem 0;}"
        "td,th{border:1px solid #ccc;padding:.3rem .5rem;}"
        "img{max-width:100%;border:1px solid #ddd;}"
        ".bad{color:#b00}.ok{color:#080}</style>",
        "<h1>Screenshot audit</h1>",
        f"<p>Generated {esc(summary['generated_at'])}</p>",
        "<h2>Summary</h2><table>",
    ]
    for key, value in summary.items():
        if key != "generated_at":
            parts.append(f"<tr><th>{esc(key)}</th><td>{esc(value)}</td></tr>")
    parts.append("</table>")

    for index, cluster in enumerate(clusters):
        cls = "bad" if cluster["action"] == "error" else "ok"
        parts.append(
            f"<h2 class='{cls}'>Cluster: {esc(cluster['action'])} "
            f"({cluster['folder_count']} folders, {cluster['entry_count']} entries)</h2>"
        )
        if cluster["label"]:
            parts.append(f"<p><b>{esc(cluster['label'])}</b> {esc(cluster['notes'])}</p>")
        parts.append("<p>Hashes: " + ", ".join(
            f"<code>{esc(value)}</code>" for value in cluster["hashes"][:8]
        ) + "</p>")
        sheet = sheets.get(index)
        if sheet:
            parts.append(
                f"<p><a href='{esc(sheet.as_uri())}'>Contact sheet</a></p>"
                f"<img src='{esc(sheet.as_uri())}'>"
            )
        parts.append("<table><tr><th>Section</th><th>Entry</th><th>Status</th>"
                     "<th>Kind</th></tr>")
        for item in cluster["items"][:80]:
            entry = item.entry
            parts.append(
                f"<tr><td>{esc(entry.section)}</td><td>{esc(entry.rel)}</td>"
                f"<td>{esc(entry.status)}</td><td>{esc(entry.kind)}</td></tr>"
            )
        parts.append("</table>")

    parts.append("<h2>Flagged entries</h2><table>"
                 "<tr><th>Section</th><th>Entry</th><th>Status</th><th>Kind</th>"
                 "<th>Reasons</th></tr>")
    for row in flags[:500]:
        parts.append(
            f"<tr><td>{esc(row['section'])}</td><td>{esc(row['rel'])}</td>"
            f"<td>{esc(row['status'])}</td><td>{esc(row['kind'])}</td>"
            f"<td>{esc(', '.join(row['reasons']))}</td></tr>"
        )
    if len(flags) > 500:
        parts.append(f"<tr><td colspan='5'>… {len(flags) - 500} more</td></tr>")
    parts.append("</table>")
    path.write_text("\n".join(parts), encoding="utf-8")


def scan(args) -> int:
    registry = load_registry(Path(args.registry).expanduser())
    out = out_dir()
    cfg = shotgen.load_config()
    sections = args.section or list(SECTION_INDEXES)
    entries = collect_entries(sections, out, args.workers, cfg)
    print(f"entries: {len(entries)}", flush=True)
    items = build_hash_items(entries)
    print(f"unique pHashes: {len(items)}", flush=True)
    hashes = sorted(items)
    clusters = cluster_hashes(hashes, args.phash_distance)
    print(f"pHash clusters: {len(clusters)}", flush=True)
    infos = []
    for cluster in clusters:
        info = cluster_info(
            cluster, items, registry, args.min_folders, args.registry_distance
        )
        if info:
            infos.append(info)
    infos.sort(key=lambda value: (
        {"error": 0, "review": 1, "valid": 2}.get(value["action"], 3),
        -value["folder_count"],
        -value["entry_count"],
    ))
    shown = infos[: args.limit_clusters]
    flags = entry_flags(entries, registry, args.registry_distance)
    report_dir = Path(args.report_dir).expanduser() / stamp()
    report_dir.mkdir(parents=True, exist_ok=True)
    sheets: dict[int, Path] = {}
    for index, info in enumerate(shown):
        if info["action"] == "valid":
            continue
        images = [
            item.entry.preview_path
            for item in info["items"]
            if item.entry.preview_path and item.entry.preview_path.is_file()
        ]
        if images:
            sheet = report_dir / "contact-sheets" / f"cluster-{index:02d}.png"
            if make_contact_sheet(images, sheet):
                sheets[index] = sheet
    summary = {
        "generated_at": iso_now(),
        "sections": ", ".join(sections),
        "entries": len(entries),
        "hash_clusters": len(clusters),
        "error_clusters": sum(1 for value in infos if value["action"] == "error"),
        "review_clusters": sum(1 for value in infos if value["action"] == "review"),
        "valid_clusters": sum(1 for value in infos if value["action"] == "valid"),
        "flagged_entries": len(flags),
        "reported_clusters": len(shown),
    }
    payload = {
        "schema": 1,
        "tool": "tools/screenshot-audit",
        "tool_version": TOOL_VERSION,
        "summary": summary,
        "clusters": [
            {
                **{key: value for key, value in info.items()
                   if key not in ("items", "representative")},
                "representative": (
                    info["representative"].rel if info["representative"] else None
                ),
            }
            for info in shown
        ],
        "flags": flags,
    }
    (report_dir / "audit.json").write_text(
        json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    write_csv(report_dir / "worklist.csv", flags)
    write_report(report_dir / "report.html", summary, shown, flags, sheets)
    print(f"\nreport: {report_dir / 'report.html'}", flush=True)
    for key, value in summary.items():
        if key != "generated_at":
            print(f"  {key}: {value}", flush=True)
    return 0


def targets_from_error_clusters(
    entries: list[Entry],
    registry: dict,
    cfg: dict,
    registry_dist: int,
    include_no_usable: bool = False,
) -> dict[str, list[Entry]]:
    grouped: dict[str, list[Entry]] = defaultdict(list)
    for entry in entries:
        if not entry.preview_path:
            continue
        if entry.status == "no_usable_shots" and not include_no_usable:
            continue
        preview_hash = str((entry.preview_metrics or {}).get("phash") or "")
        if not preview_hash:
            preview_hash = entry_preview_hash(entry, cfg)
        match = registry_match(preview_hash, registry, registry_dist) if preview_hash else None
        if match and match[0] == "error":
            grouped[entry.section].append(entry)
    return grouped


def needs_retry(entry: Entry, registry: dict, registry_dist: int) -> bool:
    """True when another TOS attempt is worthwhile.

    Error, interrupted, pending, no_usable, desktop and blank previews
    continue with the next TOS. Only a real game/cracktro result (`done`)
    stops the retry chain; otherwise the entry is marked no_usable at the
    end.
    """
    if entry.status in ERROR_STATUSES or entry.status in (
        "no_usable_shots", "desktop",
    ):
        return True
    if entry.status == "skipped_disk_n":
        return False
    metrics = entry.preview_metrics or {}
    phash = str(metrics.get("phash") or "")
    match = registry_match(phash, registry, registry_dist) if phash else None
    if match and match[0] == "error":
        return True
    if metrics and (
        float(metrics.get("std") or 0) < 5
        or int(metrics.get("unique_colors") or 99) <= 1
    ):
        return True
    return False


def reload_entries(
    out: Path,
    section: str,
    rels: list[str],
    cfg: dict,
    workers: int = 8,
) -> dict[str, Entry]:
    wanted = {rel.casefold() for rel in rels}
    entries = load_section(
        section, SECTION_INDEXES[section], out, workers, only=wanted, cfg=cfg
    )
    return {entry.rel: entry for entry in entries}


def run_shotgen(
    section: str,
    rels: list[str],
    report_dir: Path,
    tos: str,
    jobs: int,
    mode: str,
    click: bool,
) -> None:
    target_file = report_dir / f"targets-{section}-tos{tos}-{mode}.txt"
    target_file.write_text("\n".join(rels) + "\n", encoding="utf-8")
    argv = [
        str(REPO_ROOT / "tools" / "screenshot-gen" / "run.sh"),
        "run",
        "--scope",
        section,
        "--only-file",
        str(target_file),
        "--force",
        "--tos",
        tos,
        "--jobs",
        str(jobs),
    ]
    if mode == "auto":
        argv.append("--retry-desktop-auto")
    elif mode == "click":
        if not click or not shutil.which("xdotool"):
            return
        argv.append("--retry-desktop")
    print(f"\n==> {section}: {mode} TOS {tos} ({len(rels)} entries)", flush=True)
    print("    " + " ".join(argv), flush=True)
    proc = subprocess.run(argv, cwd=REPO_ROOT)
    if proc.returncode != 0:
        raise AuditError(
            "retry",
            f"{section} {mode} TOS {tos} failed with exit code {proc.returncode}",
        )


def mark_no_usable(out: Path, section: str, rels: list[str]) -> int:
    if not rels:
        return 0
    lock = shotgen.acquire_lock(out)
    changed = 0
    try:
        index_name = SECTION_INDEXES[section]
        idx = shotgen.load_index(out, index_name)
        entries = idx.get("entries") or {}
        wanted = {rel.casefold() for rel in rels}
        for rel, entry in entries.items():
            if rel.casefold() not in wanted:
                continue
            entry["status"] = "no_usable_shots"
            entry["kind"] = None
            changed += 1
            mirror = out / Path(rel).parent
            meta = shotgen.metadata_path(
                mirror, shotgen.safe_filename(Path(rel).stem)
            )
            if meta is not None and meta.is_file():
                try:
                    data = json.loads(meta.read_text(encoding="utf-8"))
                    data["status"] = "no_usable_shots"
                    data["kind"] = None
                    shotgen.write_json_atomic(meta, data)
                except (OSError, ValueError):
                    pass
        if changed:
            shotgen.save_index(out, idx, index_name)
    finally:
        shotgen.release_lock(lock)
    return changed


def retry(args) -> int:
    registry = load_registry(Path(args.registry).expanduser())
    out = out_dir()
    cfg = shotgen.load_config()
    sections = args.section or list(SECTION_INDEXES)
    entries = collect_entries(sections, out, args.workers, cfg)
    grouped = targets_from_error_clusters(
        entries,
        registry,
        cfg,
        args.registry_distance,
        include_no_usable=args.include_no_usable,
    )
    if args.limit:
        for section in grouped:
            grouped[section] = grouped[section][: args.limit]
    total = sum(len(value) for value in grouped.values())
    if not total:
        print("no known error-screen entries found", flush=True)
        return 0
    print(f"known error-screen entries: {total}", flush=True)
    report_dir = Path(args.report_dir).expanduser() / stamp()
    report_dir.mkdir(parents=True, exist_ok=True)
    remaining = {section: [entry.rel for entry in values]
                 for section, values in grouped.items()}
    for tos in args.tos:
        for section in list(remaining):
            rels = remaining[section]
            if not rels:
                continue
            if args.dry_run:
                print(f"would retry {len(rels)} {section} entries with TOS {tos}", flush=True)
                continue
            for mode in ("plain", "auto", "click"):
                run_shotgen(
                    section, rels, report_dir, tos, args.jobs, mode, not args.no_click
                )
            reloaded = reload_entries(out, section, rels, cfg, args.workers)
            remaining[section] = [
                rel for rel in rels
                if rel in reloaded
                and needs_retry(reloaded[rel], registry, args.registry_distance)
            ]
    if args.dry_run:
        return 0
    marked = 0
    for section, rels in remaining.items():
        if rels:
            print(f"marking {len(rels)} {section} entries as no_usable_shots", flush=True)
            marked += mark_no_usable(out, section, rels)
    print(f"\nmarked no_usable_shots: {marked}", flush=True)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="screenshot-audit",
        description="Audit screenshot indexes and retry known error screens.",
    )
    parser.add_argument("--version", action="version", version=f"screenshot-audit {TOOL_VERSION}")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("scan", "retry"):
        cmd = sub.add_parser(name)
        cmd.add_argument(
            "--section", action="append", choices=list(SECTION_INDEXES), default=[],
            help="limit to one or more sections (default: all)",
        )
        cmd.add_argument(
            "--registry", default=str(DEFAULT_REGISTRY),
            help="screen classification registry",
        )
        cmd.add_argument(
            "--registry-distance", type=int, default=2,
            help="max pHash distance for registry matching (default: 2)",
        )
        cmd.add_argument(
            "--workers", type=int, default=8,
            help="parallel sidecar readers (default: 8)",
        )
        cmd.add_argument(
            "--report-dir", default=str(DEFAULT_REPORT_DIR),
            help="audit output directory (default: local/screenshot-audit)",
        )
    scan_cmd = sub.choices["scan"]
    scan_cmd.add_argument("--min-folders", type=int, default=3)
    scan_cmd.add_argument("--phash-distance", type=int, default=0)
    scan_cmd.add_argument("--limit-clusters", type=int, default=50)
    retry_cmd = sub.choices["retry"]
    retry_cmd.add_argument("--tos", default="1.02,1.00")
    retry_cmd.add_argument("--jobs", type=int, default=4)
    retry_cmd.add_argument("--limit", type=int, default=0)
    retry_cmd.add_argument("--dry-run", action="store_true")
    retry_cmd.add_argument("--no-click", action="store_true")
    retry_cmd.add_argument(
        "--include-no-usable",
        action="store_true",
        help="also retry entries already marked no_usable_shots",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "retry":
        args.tos = [part.strip() for part in str(args.tos).split(",") if part.strip()]
    try:
        return scan(args) if args.command == "scan" else retry(args)
    except AuditError as exc:
        print(f"screenshot-audit error [{exc.stage}]: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
