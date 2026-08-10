#!/bin/bash

# Starts MarcerGameDvdLauncher from the correct folder
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXE_PATH="$SCRIPT_DIR/MarcerGameDvdLauncher/bin/Release/net10.0/MarcerGameDvdLauncher"

if [ ! -f "$EXE_PATH" ]; then
  echo "[ERROR] Application not built. Please run build.sh first."
  exit 1
fi

cd "$SCRIPT_DIR/MarcerGameDvdLauncher/bin/Release/net10.0"
./MarcerGameDvdLauncher
