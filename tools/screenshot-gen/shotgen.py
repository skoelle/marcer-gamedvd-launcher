#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Marcer GameDVD Screenshot Generator.

Implements SPEC-screenshot-generator.md:
  index   build/refresh the ZIP index for the scope trees
  run     process pending entries (interruptible, resumable)
  html    build a static gallery from the output tree

Paths come exclusively from environment variables (see run.sh and
local/paths.env). This file contains no real data paths.
"""
import argparse
import html as html_mod
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
    px = list(small.getdata())
    n = len(px)
    green = sum(1 for r, g, b in px if g > 160 and r < 120 and b < 120)
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
# entry processing
# --------------------------------------------------------------------------

def safe_filename(name: str) -> str:
    return re.sub(r'[:?*"\x00-\x1f]', "_", name)


def process_entry(cfg: dict, P: dict, entry: dict, log,
                  state_lock=None) -> None:
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
        deadline = t0 + cfg["entry_timeout_s"]

        for tp in cfg["timepoints"]:
            if not sleep_until(t0 + tp):
                break
            if time.monotonic() > deadline:
                log(f"entry timeout after {cfg['entry_timeout_s']}s")
                status = "timeout"
                break
            try:
                with open(fifo, "w") as fh:
                    fh.write("hatari-shortcut screenshot\n")
                log(f"screenshot requested at {tp}s")
            except OSError as ex:
                log(f"fifo write failed at {tp}s: {ex}")

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
                shutil.copy2(outdir / pick["file"], mirror_dir / preview_name)
                others = [m for m in deduped if m is not pick]
                if cfg["keep_candidates"]:
                    for i, m in enumerate(others, 1):
                        cname = f"{base}_c{i:02d}.png"
                        shutil.copy2(outdir / m["file"], mirror_dir / cname)
                        candidates.append(cname)
                else:
                    candidates = []

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
                              state_lock=state_lock)
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
        if e["status"] in ("done", "desktop") and not args.force:
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
                process_entry(cfg, P, e, log)
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
# html gallery
# --------------------------------------------------------------------------

GALLERY_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Marcer GameDVD Screenshots</title>
<style>
  body {{ font-family: sans-serif; background: #14181c; color: #dde; margin: 20px; }}
  h1 {{ font-size: 1.3em; }}
  h2 {{ font-size: 1.1em; margin-top: 2em; color: #9ad; }}
  .bar {{ position: sticky; top: 0; background: #14181c; padding: 10px 0;
          border-bottom: 1px solid #333; z-index: 1; }}
  .bar button {{ background: #233; color: #dde; border: 1px solid #456;
                 padding: 6px 12px; margin-right: 6px; border-radius: 4px;
                 cursor: pointer; }}
  .bar button.active {{ background: #365; }}
  .grid {{ display: flex; flex-wrap: wrap; gap: 14px; }}
  .card {{ background: #1c2228; border-radius: 6px; padding: 8px;
           width: 220px; }}
  .card img {{ width: 100%; height: auto; border-radius: 3px;
               image-rendering: pixelated; background: #000; }}
  .card .cands {{ display: flex; gap: 4px; margin-top: 4px; }}
  .card .cands img {{ width: 48px; image-rendering: pixelated; }}
  .name {{ font-size: 0.8em; margin: 6px 0 2px; word-break: break-all; }}
  .badge {{ display: inline-block; font-size: 0.7em; padding: 1px 6px;
            border-radius: 3px; margin-right: 4px; }}
  .b-game {{ background: #173; color: #cfc; }}
  .b-desktop {{ background: #331; color: #fd6; }}
  .b-failed {{ background: #411; color: #f88; }}
  .b-missing {{ background: #333; color: #aaa; }}
  .ph {{ width: 100%; padding-top: 60%; background: #101418;
         border-radius: 3px; }}
</style>
</head>
<body>
<h1>Marcer GameDVD Screenshots</h1>
<div class="bar">
  <button data-f="all" class="active">All</button>
  <button data-f="game">Games</button>
  <button data-f="desktop">Desktop</button>
  <button data-f="failed">Failed</button>
</div>
{sections}
<script>
document.querySelectorAll('.bar button').forEach(b => b.addEventListener('click', () => {{
  document.querySelectorAll('.bar button').forEach(x => x.classList.remove('active'));
  b.classList.add('active');
  const f = b.dataset.f;
  document.querySelectorAll('.card').forEach(c => {{
    c.style.display = (f === 'all' || c.dataset.kind === f) ? '' : 'none';
  }});
}}));
</script>
</body>
</html>
"""


def cmd_html(cfg: dict, P: dict, args) -> int:
    out = Path(P["out"])
    idx = load_index(out)
    entries = idx["entries"]

    def esc(s):
        return html_mod.escape(str(s), quote=True)

    by_tree = {}
    for rel, e in entries.items():
        parts = Path(rel).parts
        tree = "/".join(parts[:2]) if len(parts) >= 2 else parts[0]
        letter = parts[2] if len(parts) >= 3 else ""
        by_tree.setdefault(tree, {}).setdefault(letter, []).append(e)

    sections = []
    total = {"game": 0, "desktop": 0, "failed": 0}
    for tree in sorted(by_tree):
        cards = []
        for letter in sorted(by_tree[tree]):
            for e in sorted(by_tree[tree][letter],
                            key=lambda x: x["rel"]):
                st, kind = e.get("status"), e.get("kind")
                if st in ("done", "desktop") and e.get("preview"):
                    fkind = "game" if st == "done" else "desktop"
                    total[fkind] += 1
                    badge = f'<span class="badge b-{fkind}">{fkind}</span>'
                    src_dir = Path(e["rel"]).parent.as_posix()
                    img = (f'<img loading="lazy" '
                           f'src="{esc(src_dir)}/{esc(e["preview"])}" '
                           f'alt="">')
                    cands = ""
                    if e.get("candidates"):
                        cimgs = "".join(
                            f'<img loading="lazy" '
                            f'src="{esc(src_dir)}/{esc(c)}" alt="">'
                            for c in e["candidates"])
                        cands = f'<div class="cands">{cimgs}</div>'
                    body = img + cands
                    kind_attr = fkind
                else:
                    total["failed"] += 1
                    badge = (f'<span class="badge b-failed">'
                             f'{esc(st or "missing")}</span>')
                    body = '<div class="ph"></div>'
                    kind_attr = "failed"
                name = Path(e["rel"]).stem
                cards.append(
                    f'<div class="card" data-kind="{kind_attr}">{badge}'
                    f'<div class="name">{esc(name)}</div>{body}</div>')
        if not cards:
            continue
        n_game = sum(1 for e in entries.values()
                     if e["rel"].startswith(tree) and e["status"] == "done")
        sections.append(
            f"<h2>{esc(tree)} ({len(cards)} entries, "
            f"{n_game} game)</h2><div class='grid'>" + "".join(cards)
            + "</div>")

    page = GALLERY_TEMPLATE.format(sections="\n".join(sections))
    target = out / "index.html"
    with open(target, "w", encoding="utf-8") as f:
        f.write(page)
    print(f"gallery written: {target}")
    print(f"  game: {total['game']}  desktop: {total['desktop']}  "
          f"failed: {total['failed']}")
    return 0


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


def main() -> int:
    global STOP_EVENT
    STOP_EVENT = threading.Event()

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

    p_html = sub.add_parser("html", help="build static gallery index.html")

    args = ap.parse_args()
    if args.cmd == "run" and args.jobs < 1:
        ap.error("--jobs must be >= 1")
    cfg = load_config()
    P = paths()

    if args.cmd == "index":
        return cmd_index(cfg, P, args)
    if args.cmd == "run":
        return cmd_run(cfg, P, args)
    if args.cmd == "html":
        return cmd_html(cfg, P, args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
