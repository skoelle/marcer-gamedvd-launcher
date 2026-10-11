#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Marcer GameDVD Screenshot Generator.

Implements SPEC-screenshot-generator.md:
  index   build/refresh the ZIP index for the scope trees
  run     process pending entries (interruptible, resumable)
  detect  find the program icon in existing desktop previews (offline)

The static HTML gallery (formerly 'html') has been replaced by the
gallery webapp in tools/gallery/ — see SPEC-gallery-webapp.md.

Paths come exclusively from environment variables (see run.sh and
local/paths.env). This file contains no real data paths.
"""
import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from collections import deque
from pathlib import Path

TOOL_VERSION = "0.1.0"
STOP_EVENT = None  # set in main


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------

DEFAULT_CONFIG = {
    "scope_trees": [
        "Title Sorted/Cracked Games - Title Sorted",
    ],
    "timepoints": [10, 25, 45],
    "entry_timeout_s": 90,
    "keep_candidates": True,
    "disk_skip_regex": (
        r"(?i)(?:^|[\s\-_.])(?:disk|side|disc)[\s\-_.]*"
        r"(?:[2-9]|b|ii|iii)(?:$|[\s\-_.])"
    ),
    "filters": {
        "black_mean_max": 0.02,
        "black_std_max": 1.0,
        "desktop_max_colors": 5,
        "desktop_min_mean": 0.5,
        "desktop_green_frac_min": 0.02,
        "phash_max_distance": 6,
    },
    "score_weights": {"entropy": 0.4, "colors": 0.3, "edges": 0.3},
    "click_retry": {
        "probe_time": 10,
        "timepoints_after_click": [10, 25, 45],
        "entry_timeout_s": 120,
        "icon_min_score": 0.5,
        "step_wait": 2.0,
    },
    "tmp_dir": "/tmp/marcer-shotgen",
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


def require_env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        sys.exit(f"error: environment variable {name} is not set "
                 f"(add it to local/paths.env)")
    return v


def paths() -> dict:
    return {
        "root": require_env("MARCER_ROOT_DIR"),
        "patch": os.environ.get("MARCER_PATCH_DIR", "").strip(),
        "out": require_env("MARCER_OUT_DIR"),
        "tos": require_env("MARCER_TOS_IMG"),
        "hatari": os.environ.get("MARCER_HATARI_BIN", "").strip() or "hatari",
        "display": os.environ.get("MARCER_DISPLAY", "").strip() or ":99",
    }


# --------------------------------------------------------------------------
# index
# --------------------------------------------------------------------------

INDEX_NAME = "index.json"
LOCK_NAME = "shotgen.lock"


def index_path(out: Path) -> Path:
    return out / INDEX_NAME


def load_index(out: Path) -> dict:
    p = index_path(out)
    if p.exists():
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    return {"version": 1, "entries": {}}


def save_index(out: Path, idx: dict) -> None:
    p = index_path(out)
    tmp = p.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(idx, f, indent=1, sort_keys=True)
    os.replace(tmp, p)


def _is_ignored(name: str) -> bool:
    return name.startswith(".") or name.startswith("@")


def scan_tree(layer_base: Path, scope: str, disk_re) -> dict:
    """Return {relpath: {size, mtime}} for zips under layer_base/scope."""
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


def build_index(cfg: dict, P: dict, full: bool) -> dict:
    disk_re = re.compile(cfg["disk_skip_regex"])
    root, patch = Path(P["root"]), Path(P["patch"]) if P["patch"] else None
    out = Path(P["out"])
    idx = load_index(out)
    entries = idx.setdefault("entries", {})
    seen = set()
    stats = {"new": 0, "kept": 0, "gone": 0}

    for scope in cfg["scope_trees"]:
        print(f"scan scope: {scope}", flush=True)
        r_map = scan_tree(root, scope, disk_re)
        p_map = scan_tree(patch, scope, disk_re) if patch else {}
        names = set(r_map) | set(p_map)
        for rel in sorted(names):
            seen.add(rel)
            name = Path(rel).name
            layer = ("BOTH" if rel in r_map and rel in p_map
                     else "PATCH" if rel in p_map else "ROOT")
            src = p_map.get(rel) or r_map.get(rel)
            old = entries.get(rel)
            if (old and not full
                    and old.get("size") == src["size"]
                    and old.get("mtime") == src["mtime"]):
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
            stats["new"] += 1
        save_index(out, idx)

    gone = [k for k in entries if k not in seen]
    for k in gone:
        del entries[k]
    stats["gone"] = len(gone)
    save_index(out, idx)
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

def analyze_image(path: Path, cfg: dict) -> dict:
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

    f = cfg["filters"]
    if mean <= f["black_mean_max"] or std <= f["black_std_max"]:
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
    return {"kind": kind, "mean": round(mean, 4), "std": round(std, 2),
            "entropy": round(entropy, 3), "unique_colors": n_colors,
            "edges": round(edges, 2), "green_frac": round(green / n, 4),
            "phash": phash, "score": round(score, 4)}


def phash_distance(a: str, b: str) -> int:
    import imagehash
    return imagehash.hex_to_hash(a) - imagehash.hex_to_hash(b)


# --------------------------------------------------------------------------
# click retry: icon detection and mouse control via XTest (xdotool)
# --------------------------------------------------------------------------

ASSETS_DIR = Path(__file__).resolve().parent / "assets"

# X pointer operations are global per display; serialize them across
# parallel workers so one worker's click cannot land in another
# worker's Hatari window.
CLICK_LOCK = threading.Lock()


def fifo_write(fifo: Path, cmd: str) -> None:
    with open(fifo, "w") as fh:
        fh.write(cmd + "\n")


def _xdotool(args, display: str, timeout: int = 10):
    return subprocess.run(["xdotool"] + args, capture_output=True,
                          text=True, timeout=timeout, check=True,
                          env={**os.environ, "DISPLAY": display})


def find_hatari_window(P: dict, grab_png: Path):
    """Locate Hatari's SDL window via xdotool, matched by screenshot size.

    Returns (wid, kv) where kv holds X/Y/WIDTH/HEIGHT from the window
    geometry. Raises RuntimeError when no window can be found.
    """
    from PIL import Image
    with Image.open(grab_png) as im:
        shot_w, shot_h = im.size

    disp = P["display"]
    with CLICK_LOCK:
        res = _xdotool(["search", "--all", "--class", "hatari"], disp)
        ids = [line for line in res.stdout.splitlines() if line.strip()]
        best = None
        for wid in ids:
            geo = _xdotool(["getwindowgeometry", "--shell", wid], disp)
            kv = dict(line.split("=", 1)
                      for line in geo.stdout.splitlines() if "=" in line)
            w, h = int(kv["WIDTH"]), int(kv["HEIGHT"])
            dist = abs(w - shot_w) + abs(h - shot_h)
            if best is None or dist < best[0]:
                best = (dist, wid, kv)
    if best is None:
        raise RuntimeError("no hatari window found via xdotool")
    return best[1], best[2]


def click_window_xy(P: dict, wid: str, kv: dict, shot_w: int, shot_h: int,
                    icon_sx: int, icon_sy: int, log) -> None:
    """Double-click a screenshot pixel on a known Hatari window.

    Serialized under CLICK_LOCK (X pointers are global per display). The
    30ms doubleclick delay is required so GEM opens the icon instead of
    just selecting it (verified live; Hatari 2.4.1 has no mousemove
    control command, so the real X pointer via XTest is used).
    """
    disp = P["display"]
    wx, wy = int(kv["X"]), int(kv["Y"])
    ww, wh = int(kv["WIDTH"]), int(kv["HEIGHT"])
    x = wx + round(icon_sx * ww / shot_w)
    y = wy + round(icon_sy * wh / shot_h)
    with CLICK_LOCK:
        # raise first: parallel workers share one display and their
        # windows overlap
        _xdotool(["windowraise", wid], disp)
        _xdotool(["mousemove", "--sync", str(x), str(y)], disp)
        _xdotool(["click", "--repeat", "2", "--delay", "30", "1"], disp)
    log(f"xdotool doubleclick window={wid} at ({x},{y}) "
        f"[icon ({icon_sx},{icon_sy}) in {shot_w}x{shot_h}]")


def click_icon(P: dict, grab_png: Path, icon_sx: int, icon_sy: int,
               log) -> None:
    """Double-click the detected icon on Hatari's SDL window.

    The grab screenshot provides the window content size so that the
    icon's screenshot pixel maps onto the X window.
    """
    from PIL import Image
    with Image.open(grab_png) as im:
        shot_w, shot_h = im.size
    wid, kv = find_hatari_window(P, grab_png)
    click_window_xy(P, wid, kv, shot_w, shot_h, icon_sx, icon_sy, log)


def find_template(img_path: Path, template, min_score: float):
    """Zero-mean normalized cross correlation (FFT) against a template.

    Also tries the inverted template so that inverted (selected) GEM icons
    still match. Returns (cx, cy, score) at the template center, or None.
    """
    import numpy as np
    from PIL import Image
    from scipy.signal import fftconvolve

    img = np.asarray(Image.open(img_path).convert("L"), dtype=np.float64)
    t_base = np.asarray(template, dtype=np.float64)
    best = None
    for t_img in (t_base, 255.0 - t_base):
        t = t_img - t_img.mean()
        th, tw = t.shape
        if img.shape[0] < th or img.shape[1] < tw:
            continue
        num = fftconvolve(img, t[::-1, ::-1], mode="valid")
        ones = np.ones_like(t)
        s1 = fftconvolve(img ** 2, ones, mode="valid")
        s2 = fftconvolve(img, ones, mode="valid")
        n = t.size
        var = s1 - (s2 ** 2) / n
        t_energy = float((t ** 2).sum())
        # flat/low-contrast windows make den tiny and amplify noise into
        # spurious mid scores: require at least 5% of the template contrast
        # energy, otherwise force invalid
        contrast = var >= 0.05 * t_energy
        den = np.sqrt(np.maximum(var, 1e-9) * t_energy)
        ncc = np.where(contrast, num / den, -1.0)
        ncc = np.nan_to_num(ncc, nan=-1.0, posinf=-1.0, neginf=-1.0)
        iy, ix = np.unravel_index(int(np.argmax(ncc)), ncc.shape)
        score = float(np.clip(ncc[iy, ix], -1.0, 1.0))
        if best is None or score > best[2]:
            best = (int(ix + tw // 2), int(iy + th // 2), score)
    if best is None or best[2] < min_score:
        return None
    return best


ICON_TEMPLATE_FILES = {
    "prg": "icon-prg.png",
    "drive": "icon-drive.png",
}


def find_icon(path: Path, cfg: dict, template: str = "prg"):
    """Locate a GEM icon in a screenshot via NCC.

    template: "prg" (program icon) or "drive" (disk drive icon).
    Returns {"sx", "sy", "score"} (screenshot pixel, template center)
    or None.
    """
    tpl_name = ICON_TEMPLATE_FILES.get(template)
    if tpl_name is None:
        return None
    tpl_path = ASSETS_DIR / tpl_name
    if not tpl_path.exists():
        return None
    from PIL import Image
    with Image.open(tpl_path) as tpl:
        grayscale = tpl.convert("L")
        res = find_template(path, grayscale,
                            cfg["click_retry"]["icon_min_score"])
    if res is None:
        return None
    cx, cy, score = res
    return {"sx": cx, "sy": cy, "score": round(score, 3)}


def find_desktop_click(path: Path, cfg: dict):
    """Pick the click strategy and icon for a desktop screenshot.

    prefers a program icon (single click, game starts directly). If no
    program icon is found (or only a weak false-positive), falls back to
    the disk drive icon ("drive" strategy: open DISKSTATION A first, then
    click the PRG that appears in the opened window).

    Returns {"strategy": "prg"|"drive", "sx", "sy", "score"} or None.
    """
    min_score = cfg["click_retry"]["icon_min_score"]
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


def perform_click_chain(P, cfg, click_cfg, click_info, fifo, outdir,
                        grabs, log):
    """Execute the click sequence for a desktop retry.

    prg: one double click on the program icon (game starts directly).
    drive: double click DISKSTATION A, wait for the window to open, take a
           screenshot and double click the program icon that appeared in it
           (depth 1; a later stage may recurse into subfolders).

    returns (clicked, last_grab): clicked is True when the final program
    double click was sent; last_grab is the most recent screenshot path
    (used to size the window for coordinate mapping).
    """
    strategy = click_info.get("strategy", "prg")

    if strategy == "prg":
        click_icon(P, grabs[-1], click_info["sx"], click_info["sy"], log)
        return True, grabs[-1]

    # strategy == "drive": open DISKSTATION A first
    click_icon(P, grabs[-1], click_info["sx"], click_info["sy"], log)
    step_wait = float(click_cfg.get("step_wait", 2.0))
    log(f"drive click done, waiting {step_wait}s for the window")
    if not sleep_until(time.monotonic() + step_wait):
        return False, grabs[-1]

    # fresh screenshot of the opened window
    fifo_write(fifo, "hatari-shortcut screenshot")
    if not sleep_until(time.monotonic() + 2):
        return False, grabs[-1]
    all_grabs = sorted(outdir.glob("*.png"))
    if not all_grabs:
        return False, grabs[-1]
    win_shot = all_grabs[-1]
    win_icon = find_icon(win_shot, cfg, "prg")
    if not win_icon:
        log("drive opened but no program icon in the window")
        return False, win_shot
    click_icon(P, win_shot, win_icon["sx"], win_icon["sy"], log)
    return True, win_shot


def process_entry(cfg: dict, P: dict, entry: dict, log,
                  state_lock=None, click_retry: bool = False,
                  force: bool = False) -> None:
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

    if layer in ("PATCH", "BOTH"):
        src_zip = Path(P["patch"]) / rel
    else:
        src_zip = Path(P["root"]) / rel

    mirror_dir = out / rel_path.parent
    base = safe_filename(rel_path.stem)
    preview_name = f"{base}.png"
    meta_path = mirror_dir / f"{base}.json"
    mirror_dir.mkdir(parents=True, exist_ok=True)

    tmp_root = Path(cfg["tmp_dir"])
    stage = Path(tempfile.mkdtemp(prefix="entry-", dir=tmp_root))
    outdir = stage / "out"
    outdir.mkdir()
    staged = stage / "disk.zip"
    fifo = stage / "hatari.fifo"
    hatari_log = stage / "hatari.log"

    t_start = time.time()
    status, kind = "error", None
    shots_meta, preview, candidates = [], None, []

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

        prof = cfg["profile"]
        cmd = [
            P["hatari"],
            "--tos", P["tos"],
            "--machine", prof["machine"],
            "--memsize", prof["memsize"],
            "--sound", "off",
            "--statusbar", "off",
            "--crop", "on",
            "--fast-boot", "on",
            "--confirm-quit", "off",
            "--zoom", prof["zoom"],
            "--disk-a", str(staged),
            "--screenshot-dir", str(outdir),
            "--cmd-fifo", str(fifo),
            "--log-file", str(hatari_log),
            "--log-level", "info",
        ] + prof.get("extra_args", [])

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
        schedule = [click_cfg.get("probe_time", 10)] if do_click else list(
            cfg["timepoints"])
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
                        clicked, last_grab = perform_click_chain(
                            P, cfg, click_cfg, click_info, fifo, outdir,
                            grabs, log)
                    except Exception as ex:
                        log(f"click chain failed ({strategy}): {ex}")
                        clicked = False

                    def _mark_click():
                        entry["click_retried"] = True
                        entry["click"] = {**click_info, "clicked": clicked}
                    commit(_mark_click)
                    if clicked:
                        t0 = time.monotonic()
                        deadline = t0 + entry_timeout
                        schedule = list(click_cfg.get(
                            "timepoints_after_click", cfg["timepoints"]))
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
                        def _mark_no_click():
                            entry["click_retried"] = True
                        commit(_mark_no_click)
                    schedule = [t for t in cfg["timepoints"] if t > tp]
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
                    m = analyze_image(g, cfg)
                except Exception as ex:
                    log(f"analyze failed {g.name}: {ex}")
                    continue
                m["file"] = g.name
                shots_meta.append(m)
                log(f"{g.name}: kind={m['kind']} colors={m['unique_colors']} "
                    f"score={m['score']}")

            # drop black
            survivors = [m for m in shots_meta if m["kind"] != "black"]

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
            else:
                status = "desktop" if pick["kind"] == "desktop" else "done"
                kind = pick["kind"]
                # copy files to mirror
                preview = preview_name
                target = mirror_dir / preview_name
                others = [m for m in deduped if m is not pick]
                if cfg["keep_candidates"]:
                    for i, m in enumerate(others, 1):
                        cname = f"{base}_c{i:02d}.png"
                        shutil.copy2(outdir / m["file"], mirror_dir / cname)
                        candidates.append(cname)
                    if target.exists():
                        # keep the previous preview (e.g. an old desktop
                        # shot) as an additional candidate instead of
                        # silently overwriting it
                        old = f"{base}_c{len(candidates) + 1:02d}.png"
                        os.replace(target, mirror_dir / old)
                        candidates.append(old)
                shutil.copy2(outdir / pick["file"], target)

        def _commit():
            entry["status"] = status
            entry["kind"] = kind
            entry["preview"] = preview
            entry["candidates"] = candidates
            entry["last_run"] = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                              time.gmtime())
            entry["duration_s"] = round(time.time() - t_start, 1)
            entry["zip_contents"] = zip_contents
            entry["capture_method"] = "cmd-fifo"

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
            "status": status,
            "kind": kind,
            "preview_is_desktop": bool(kind == "desktop"),
            "preview": preview,
            "candidates": candidates,
            "click": entry.get("click"),
            "click_retried": bool(entry.get("click_retried")),
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
    except Exception as ex:
        def _commit_error():
            entry["status"] = "error"
            entry["last_run"] = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                              time.gmtime())

        commit(_commit_error)
        log(f"ERROR: {ex}")
    finally:
        shutil.rmtree(stage, ignore_errors=True)


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
                  done_counts: dict):
    """Worker pool: claim entries from a shared queue, process, save index.

    Entry mutation and index saves are serialized under one lock, so
    parallel workers never overwrite each other's updates. Returns
    (interrupted, processed).
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
                process_entry(cfg, P, e, make_log(e, wid),
                              state_lock=state_lock,
                              click_retry=args.retry_desktop,
                              force=args.force)
                with state_lock:
                    save_index(out, idx)
                    done_counts[e["status"]] = (done_counts.get(e["status"], 0)
                                                + 1)
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


def cmd_run(cfg: dict, P: dict, args) -> int:
    if args.retry_desktop and shutil.which("xdotool") is None:
        sys.exit("error: --retry-desktop needs xdotool in PATH")
    out = Path(P["out"])
    out.mkdir(parents=True, exist_ok=True)
    lock = acquire_lock(out)
    xvfb = ensure_xvfb(P["display"], cfg["xvfb_screen"])
    if xvfb:
        print(f"Xvfb started on {P['display']} (pid {xvfb.pid})", flush=True)

    idx = load_index(out)
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
        elif e["status"] in ("done", "desktop") and not args.force:
            continue
        if args.only and args.only.lower() not in rel.lower():
            continue
        pending.append(e)

    jobs = max(1, args.jobs)
    print(f"pending entries: {len(pending)}", flush=True)
    if jobs > 1:
        print(f"parallel jobs: {jobs}", flush=True)
    t_start = time.monotonic()
    done_counts = {}
    processed = 0
    interrupted = False

    try:
        if jobs > 1:
            interrupted, processed = _run_parallel(
                cfg, P, args, out, idx, pending, jobs, t_start, done_counts)
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
                              force=args.force)
                save_index(out, idx)
                done_counts[e["status"]] = done_counts.get(e["status"], 0) + 1
                if STOP_EVENT.is_set():
                    interrupted = True
                    break
    except KeyboardInterrupt:
        interrupted = True
    finally:
        save_index(out, idx)
        release_lock(lock)
        if xvfb:
            kill_group(xvfb.pid)
        elapsed = time.monotonic() - t_start
        print(f"\nprocessed {processed} entries in {elapsed/60:.1f} min",
              flush=True)
        for k in sorted(done_counts):
            print(f"  {k}: {done_counts[k]}", flush=True)
    return 130 if interrupted else 0


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def cmd_index(cfg: dict, P: dict, args) -> int:
    global STOP_EVENT
    stats, idx = build_index(cfg, P, args.full)
    entries = idx["entries"]
    by_status = {}
    for e in entries.values():
        by_status[e["status"]] = by_status.get(e["status"], 0) + 1
    print(f"\nindex: {len(entries)} entries "
          f"(new {stats['new']}, unchanged {stats['kept']}, "
          f"gone {stats['gone']})")
    for k in sorted(by_status):
        print(f"  {k}: {by_status[k]}")
    return 0


def cmd_detect(cfg: dict, P: dict, args) -> int:
    """Offline icon detection on existing desktop previews (no Hatari)."""
    out = Path(P["out"])
    out.mkdir(parents=True, exist_ok=True)
    idx = load_index(out)
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
                save_index(out, idx)
        save_index(out, idx)
    finally:
        release_lock(lock)
    print(f"detect: checked {stats['checked']}, icons {stats['found']} "
          f"(prg {stats['strategy']['prg']}, "
          f"drive {stats['strategy']['drive']}), "
          f"no icon {stats['no_icon']}, skipped {stats['skipped']}")
    return 0


def main() -> int:
    global STOP_EVENT
    STOP_EVENT = threading.Event()

    # 'html' was removed: point users at the gallery webapp (M6).
    if len(sys.argv) > 1 and sys.argv[1] == "html":
        print("shotgen html was removed and replaced by the gallery "
              "webapp:\n  tools/gallery/run.sh   "
              "(see SPEC-gallery-webapp.md)", file=sys.stderr)
        return 2

    def _stop(signum, frame):
        STOP_EVENT.set()
        print("\ninterrupt: finishing up (Ctrl+C again to force)",
              flush=True)

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    ap = argparse.ArgumentParser(prog="shotgen",
                                 description="Marcer GameDVD screenshot "
                                             "generator")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_index = sub.add_parser("index", help="build/refresh the zip index")
    p_index.add_argument("--full", action="store_true",
                         help="rescan metadata of all entries")

    p_run = sub.add_parser("run", help="process pending entries")
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

    p_detect = sub.add_parser(
        "detect",
        help="find the program icon in existing desktop previews "
             "(offline, no Hatari)")
    p_detect.add_argument("--force", action="store_true",
                          help="redetect even if a result already exists")
    p_detect.add_argument("--only", type=str, default="",
                          help="only paths containing this substring")

    args = ap.parse_args()
    if args.cmd == "run" and args.jobs < 1:
        ap.error("--jobs must be >= 1")
    cfg = load_config()
    P = paths()

    if args.cmd == "index":
        return cmd_index(cfg, P, args)
    if args.cmd == "run":
        return cmd_run(cfg, P, args)
    if args.cmd == "detect":
        return cmd_detect(cfg, P, args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
