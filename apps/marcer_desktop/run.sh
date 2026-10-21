#!/bin/sh
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
# Wrapper: seeds desktop.config.json from local/paths.env on first run,
# then starts the Flutter desktop app (linux).
set -e
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$APP_DIR/../.." && pwd)"

export PATH="$HOME/flutter/bin:$PATH"

CONFIG="$APP_DIR/desktop.config.json"
if [ ! -f "$CONFIG" ] && [ -f "$REPO_ROOT/local/paths.env" ]; then
    set -a
    . "$REPO_ROOT/local/paths.env"
    set +a
    cat > "$CONFIG" <<EOF
{
  "RootDirectory": "${MARCER_ROOT_DIR:-}",
  "PatchDirectory": "${MARCER_PATCH_DIR:-}",
  "ScreenshotDirectory": "${MARCER_OUT_DIR:-}",
  "GameinfoDirectory": "${MARCER_DATA_DIR:-}",
  "AtariLegendDirectory": "${MARCER_ATARILEGEND_DIR:-}",
  "Hatari": {
    "Executable": "${MARCER_HATARI_BIN:-/usr/bin/hatari}",
    "ConfigFile": "",
    "ArgsTemplate": "-c \"{cfg}\" --disk-a \"{zip}\""
  },
  "Window": { "width": 1280, "height": 800 }
}
EOF
    echo "Seeded $CONFIG from local/paths.env"
fi

cd "$APP_DIR"
exec flutter run -d linux "$@"
