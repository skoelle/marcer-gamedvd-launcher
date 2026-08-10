#!/bin/bash

# === Build script for HatariZipLauncher (requires .NET SDK 6 or newer) ===
echo "Building HatariZipLauncher..."

if ! command -v dotnet &> /dev/null; then
    echo "[ERROR] .NET SDK not found. Please install from https://dotnet.microsoft.com/download"
    exit 1
fi

# Build in current directory (where build.sh is located)
cd "$(dirname "$0")"

# Change to HatariZipLauncher subdirectory
cd "HatariZipLauncher"

dotnet build -c Release
if [ $? -ne 0 ]; then
    echo "[ERROR] Build failed!"
    exit 2
fi

# Check for the built .exe file
EXEPATH=$(find "bin/Release" -name "HatariZipLauncher*.exe" -print -quit 2>/dev/null)
if [ -n "$EXEPATH" ] && [ -f "$EXEPATH" ]; then
    echo "[OK] Build complete. EXE: \"$EXEPATH\""
else
    echo "[WARNING] Build appears successful but .exe not found!"
fi
