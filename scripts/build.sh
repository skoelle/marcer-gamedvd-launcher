#!/bin/bash

# === Build script for MarcerGameDvdLauncher (requires .NET SDK 6 or newer) ===
echo "Building MarcerGameDvdLauncher..."

if ! command -v dotnet &> /dev/null; then
    echo "[ERROR] .NET SDK not found. Please install from https://dotnet.microsoft.com/download"
    exit 1
fi

# Build in MarcerGameDvdLauncher subdirectory (script is in scripts/, code in src/)
cd "$(dirname "$0")"
cd "../src/MarcerGameDvdLauncher"

dotnet build -c Release
if [ $? -ne 0 ]; then
    echo "[ERROR] Build failed!"
    exit 2
fi

# Check for the built binary
BINPATH=$(find "bin/Release" \( -name "MarcerGameDvdLauncher" -o -name "MarcerGameDvdLauncher.exe" \) -print -quit 2>/dev/null)
if [ -n "$BINPATH" ] && [ -f "$BINPATH" ]; then
    echo "[OK] Build complete. Binary: \"$BINPATH\""
else
    echo "[WARNING] Build appears successful but binary not found!"
fi
