#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Generate the desktop app icons from the committed gallery favicon.

The favicon (`tools/gallery/static/favicon.svg`) is a pixel-trace of the GEM
drawer icon; its `<rect>` elements use a 70x70 grid with 2px blocks. We render
that grid at a high integer scale (NEAREST) into a master PNG and derive the
platform icon sets:

  - Windows: windows/runner/resources/app_icon.ico (multi-size)
  - macOS:   macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png
  - Linux:   linux/runner/resources/app_icon.png
  - master:  assets/icon/app_icon.png

Requires Pillow (run via the repo `.venv`: `.venv/bin/python tool/generate_icons.py`).
"""
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SVG = ROOT.parent.parent / "tools" / "gallery" / "static" / "favicon.svg"
VIEW = 70  # SVG viewBox is 0 0 70 70 (2px pixel blocks)
MASTER = 70 * 16  # 1120, integer multiple of the grid for crisp pixels
SIZES = [16, 24, 32, 48, 64, 128, 256, 512, 1024]

assert SVG.exists(), f"favicon not found: {SVG}"
src = SVG.read_text()

view_box = re.search(r'viewBox="0 0 (\d+) (\d+)"', src)
if view_box:
    VIEW = int(view_box.group(1))

attr_re = re.compile(r'([a-zA-Z-]+)="([^"]*)"')
rects = []
for tag in re.findall(r"<rect\b[^>]*/>", src):
    a = dict(attr_re.findall(tag))
    rects.append((float(a.get("x", 0)), float(a.get("y", 0)),
                  float(a.get("width", 0)), float(a.get("height", 0)),
                  a.get("fill", "#000000"), float(a.get("rx", 0))))
assert rects, "no <rect> elements parsed from favicon.svg"

scale = MASTER / VIEW
master = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
draw = ImageDraw.Draw(master)
for x, y, w, h, fill, rx in rects:
    box = [
        round(x * scale),
        round(y * scale),
        round((x + w) * scale) - 1,
        round((y + h) * scale) - 1,
    ]
    if rx > 0:
        draw.rounded_rectangle(box, radius=round(rx * scale), fill=fill)
    else:
        draw.rectangle(box, fill=fill)

MASTER_PNG = ROOT / "assets" / "icon" / "app_icon.png"
MASTER_PNG.parent.mkdir(parents=True, exist_ok=True)
master.save(MASTER_PNG)


def resized(size: int) -> Image.Image:
    return master.resize((size, size), Image.NEAREST)


# Windows multi-size ICO
ico = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
ico.parent.mkdir(parents=True, exist_ok=True)
resized(256).save(ico, format="ICO",
                  sizes=[(s, s) for s in [16, 24, 32, 48, 64, 128, 256]])

# macOS AppIcon set
macos = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
macos.mkdir(parents=True, exist_ok=True)
for size in [16, 32, 64, 128, 256, 512, 1024]:
    resized(size).save(macos / f"app_icon_{size}.png")

# Linux window icon (256px is plenty)
linux = ROOT / "linux" / "runner" / "resources"
linux.mkdir(parents=True, exist_ok=True)
resized(256).save(linux / "app_icon.png")

print(f"master: {MASTER_PNG} ({MASTER}x{MASTER})")
print(f"parsed {len(rects)} rects, viewBox {VIEW}x{VIEW}")
print(f"ico:    {ico}")
print(f"macos:  {macos} (16..1024)")
print(f"linux:  {linux / 'app_icon.png'}")
