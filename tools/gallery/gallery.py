#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Marcer GameDVD gallery webapp — stdlib-only local server.

Serves the screenshot archive (MARCER_OUT_DIR/index.json + PNG tree) joined
with the game metadata (MARCER_DATA_DIR/games-*.json) as an interactive
gallery. See SPEC-gallery-webapp.md for the behavioral specification.
"""
import argparse
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

TOOL_VERSION = "0.1.0"
BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

DEFAULTS = {
    "host": "127.0.0.1",
    "port": 8764,
    "page_size": 60,
    "show_candidates": True,
    "default_status": "with_screenshot",
    "image_cache_seconds": 86400,
}

# display order for status aggregation (SPEC-gallery-webapp.md 4.4)
STATUS_ORDER = ["done", "desktop", "no_usable_shots", "interrupted",
                "pending", "skipped_disk_n"]
STATUS_LABELS = {
    "done": "done (game)",
    "desktop": "desktop",
    "no_usable_shots": "no usable shots",
    "interrupted": "interrupted",
    "pending": "pending",
    "skipped_disk_n": "skipped (disk 2+)",
    "any": "any status",
    "with_screenshot": "with screenshot",
}
YEAR_RE = re.compile(r"\d{4}")
SORTS = ("name", "year", "publisher", "cracker", "crew")


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


def _build_cracked_cards(entries, cracked_games):
    info_by_key = {(g.get("letter", ""), g.get("folder", "")): g
                   for g in cracked_games}
    groups = {}
    for rel, e in entries.items():
        parts = rel.split("/")
        letter = parts[2] if len(parts) > 2 else ""
        folder = parts[3] if len(parts) > 3 else Path(parts[-1]).stem
        groups.setdefault((letter, folder), []).append((rel, e))

    cards = []
    for (letter, folder), items in groups.items():
        items.sort(key=lambda t: t[0])
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
                "layer": e.get("layer") or "",
                "preview": _full_png(rel, e.get("preview")),
                "candidates": [_full_png(rel, c)
                               for c in (e.get("candidates") or [])],
                "size": e.get("size"),
            })
        display_status = next((s for s in STATUS_ORDER if scounts.get(s)),
                              "pending")
        preview = next((v["preview"] for v in variants
                        if v["status"] == "done" and v["preview"]), None)
        if preview is None:
            preview = next((v["preview"] for v in variants
                            if v["status"] == "desktop" and v["preview"]),
                           None)
        layer = next(iter(layers)) if len(layers) == 1 else "BOTH"
        info = info_by_key.get((letter, folder))
        card = {
            "id": f"{letter}/{folder}",
            "name": folder,
            "letter": letter,
            "folder": folder,
            "display_status": display_status,
            "screenshots": preview is not None,
            "status_counts": scounts,
            "layer": layer,
            "year": "",
            "preview": preview,
            "variants": variants,
            "info": _variant_info_summary(info),
        }
        _finalize_card(card, kind="cracked")
        cards.append(card)
    return cards


def _build_simple_cards(games, kind):
    cards = []
    for g in games:
        letter = g.get("letter", "")
        folder = g.get("folder", "")
        layers = g.get("layers") or []
        layer = "BOTH" if len(layers) > 1 else (layers[0] if layers else "")
        card = {
            "id": f"{letter}/{folder}",
            "name": folder,
            "letter": letter,
            "folder": folder,
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
        cards.append(card)
    return cards


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
    pubs, crews, langs, years, letters = set(), set(), set(), set(), set()
    for c in cards:
        if c["letter"]:
            letters.add(c["letter"])
        for v in (c.get("info") or {}).get("variants") or []:
            for bucket, key in ((pubs, "publisher"), (langs, "language")):
                val = (v.get(key) or "").strip()
                if val:
                    bucket.add(val)
            if "crew" in kind_fields(kind):
                val = (v.get("crew") or "").strip()
                if val:
                    crews.add(val)
            y = extract_year(v.get("release"))
            if y:
                years.add(y)
    return {
        "publishers": sorted(pubs, key=str.lower),
        "crews": sorted(crews, key=str.lower),
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
    }[kind]


def kind_filters(kind):
    """API filter names applicable to a section (SPEC 6.8)."""
    return {
        "cracked": {"publisher", "crew", "language", "year",
                    "raw", "pasti", "boxscan", "tos"},
        "pd": {"publisher", "language", "year", "tos"},
        "utils": {"publisher", "crew", "language", "year", "raw", "tos"},
    }[kind]


class DataStore:
    """In-memory index + metadata with mtime-based revalidation."""

    def __init__(self, out_dir, data_dir):
        self.out = Path(out_dir)
        self.data = Path(data_dir) if data_dir and os.path.isdir(data_dir) \
            else None
        self.lock = threading.Lock()
        self.index_path = self.out / "index.json"
        self._mtimes = {}
        self.meta = {}
        self.cards = {"cracked": [], "pd": [], "utils": []}
        self.facets = {}
        self.gameinfo_available = False
        self.kinds_loaded = set()
        self.manifest = {}
        self.reload(force=True)

    def _stamps(self):
        stamps = {"index": None, "cracked": None, "pd": None,
                  "utils": None, "manifest": None}
        try:
            stamps["index"] = os.path.getmtime(self.index_path)
        except OSError:
            pass
        if self.data:
            for kind in ("cracked", "pd", "utils"):
                try:
                    stamps[kind] = os.path.getmtime(
                        self.data / f"games-{kind}.json")
                except OSError:
                    pass
            try:
                stamps["manifest"] = os.path.getmtime(
                    self.data / "manifest.json")
            except OSError:
                pass
        return stamps

    def check_changed(self):
        return self._stamps() != self._mtimes

    def reload(self, force=False):
        if not force and not self.check_changed():
            return False
        with self.lock:
            if not force and self._stamps() == self._mtimes \
                    and self.meta.get("entries_total"):
                return False
            t0 = time.monotonic()
            self._load()
            log(f"[data] (re)loaded in {time.monotonic() - t0:.2f}s "
                f"({self.meta.get('entries_total')} index entries, "
                f"{len(self.cards['cracked'])} cracked cards)")
        return True

    def _load(self):
        self._mtimes = self._stamps()
        entries = {}
        if self.index_path.is_file():
            with open(self.index_path, encoding="utf-8") as f:
                entries = json.load(f).get("entries", {})
        status_counts = {}
        for e in entries.values():
            s = e.get("status") or "unknown"
            status_counts[s] = status_counts.get(s, 0) + 1

        games = {"cracked": [], "pd": [], "utils": []}
        self.kinds_loaded = set()
        self.gameinfo_available = False
        self.manifest = {}
        if self.data and self.data.is_dir():
            for kind in ("cracked", "pd", "utils"):
                p = self.data / f"games-{kind}.json"
                try:
                    with open(p, encoding="utf-8") as f:
                        games[kind] = json.load(f).get("games", [])
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

        self.cards["cracked"] = _build_cracked_cards(
            entries, games["cracked"] if "cracked" in self.kinds_loaded
            else [])
        self.cards["pd"] = _build_simple_cards(
            games["pd"] if "pd" in self.kinds_loaded else [], "pd")
        self.cards["utils"] = _build_simple_cards(
            games["utils"] if "utils" in self.kinds_loaded else [], "utils")
        self.facets = {kind: _facets(self.cards[kind], kind)
                       for kind in ("cracked", "pd", "utils")}

        coverage = {}
        for src in self.manifest.get("sources") or []:
            if src.get("kind") == "cracked":
                coverage = {
                    "matched_folders": src.get("matched_folders"),
                    "unmatched_folders": src.get("unmatched_folders"),
                }
        self.meta = {
            "gameinfo": self.gameinfo_available,
            "index": {
                "entries": len(entries),
                "mtime": self._mtimes.get("index"),
            },
            "status_counts": status_counts,
            "sections": {
                "cracked": {
                    "games": len(games["cracked"]),
                    "cards": len(self.cards["cracked"]),
                    "with_screenshot": sum(
                        1 for c in self.cards["cracked"] if c["screenshots"]),
                    "no_info": sum(
                        1 for c in self.cards["cracked"] if not c["info"]),
                },
                "pd": {"games": len(games["pd"])},
                "utils": {"games": len(games["utils"])},
            },
            "coverage": coverage,
            "facets": self.facets,
            "generated_at": self.manifest.get("generated_at"),
            "tool_version": TOOL_VERSION,
        }

    def meta_payload(self):
        m = json.loads(json.dumps(self.meta))
        m["status_labels"] = STATUS_LABELS
        return m


def _matches(card, params, section):
    if section == "cracked":
        st = params.get("status", "with_screenshot") or "with_screenshot"
        if st == "with_screenshot":
            if not card["screenshots"]:
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
                if name not in ("app.js", "style.css"):
                    return self._error(404, "not found")
                ctype = ("text/javascript" if name.endswith(".js")
                         else "text/css")
                return self._file(STATIC_DIR / name, ctype)
            if path == "/api/meta":
                self.store.reload()
                return self._json(self.store.meta_payload())
            if path == "/api/entries":
                self.store.reload()
                return self._entries()
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

    def _entries(self):
        params = self._params()
        section = params.get("section", "cracked") or "cracked"
        if section not in ("cracked", "pd", "utils"):
            return self._error(400, "invalid section")
        store = self.store

        # single-card lookup for deep links (SPEC 5.3 "entry")
        entry = params.get("entry")
        if entry:
            card = next((c for c in store.cards["cracked"]
                         if any(v["rel"] == entry for v in c["variants"])),
                        None)
            if card is None:
                return self._error(404, "entry not found")
            filtered = [c for c in store.cards["cracked"]
                        if _matches(c, params, "cracked")]
            position = next(
                (i for i, c in enumerate(filtered) if c is card), None)
            payload = _public_card(card, "cracked")
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

        matched = [c for c in store.cards[section]
                   if _matches(c, params, section)]
        _sort_cards(matched, sort, order)
        page = matched[offset:offset + limit]
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
                    help="bind address (default from config: 127.0.0.1)")
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

    if not STATIC_DIR.is_dir():
        log(f"[error] static assets missing: {STATIC_DIR}")
        return 1

    host = cfg["host"]
    if host not in ("127.0.0.1", "localhost", "::1"):
        log(f"[warn] binding to {host} — no authentication is configured, "
            f"anyone who can reach this address can browse the archive")

    log("[data] loading …")
    store = DataStore(out_dir, data_dir)
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
