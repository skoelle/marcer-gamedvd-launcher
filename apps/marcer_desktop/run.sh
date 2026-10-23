#!/bin/sh
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
# Wrapper: (re)generates desktop.config.json from local/paths.env on every run
# (developer convenience — overwrites manual edits; the app itself only reads
# the config file), then starts the Flutter desktop app (linux).
set -e
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$APP_DIR/../.." && pwd)"

export PATH="$HOME/flutter/bin:$PATH"

CONFIG="$APP_DIR/desktop.config.json"
if [ -f "$REPO_ROOT/local/paths.env" ]; then
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
  "Falcon": {
    "ExtraArgs": "--vdi off"
  },
  "Ftp": {
    "Host": "${MARCER_FTP_HOST:-}",
    "User": "${MARCER_FTP_USER:-}",
    "Password": "${MARCER_FTP_PASS:-}",
    "RemoteBase": "${MARCER_FTP_REMOTE_BASE:-/GameDVD/}",
    "AssetsRemote": "${MARCER_FTP_ASSETS_REMOTE:-/Uploads/MarcerGameDVDLauncher-assets/}"
  },
  "ShowCandidates": true,
  "DefaultStatus": "with_screenshot",
  "Window": { "width": 1280, "height": 800, "maximized": true }
}
EOF
    echo "Wrote $CONFIG from local/paths.env"
fi

cd "$APP_DIR"
exec flutter run -d linux "$@"
