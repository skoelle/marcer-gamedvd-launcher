#!/bin/bash

# === Demo setup and run script for MarcerGameDvdLauncher ===
# Creates a structured test directory with main and patch layers,
# populates them with fake ZIPs, then launches the launcher.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$SCRIPT_DIR/.demo"
ROOT_DIR="$DEMO_DIR/root"
PATCH_DIR="$DEMO_DIR/patch"
CONFIG_FILE="$SCRIPT_DIR/launcher.config.json"

# --- Step 1: Build ---
echo "=== Building MarcerGameDvdLauncher ==="
cd "$SCRIPT_DIR"
dotnet build -c Release --verbosity quiet
echo "[OK] Build successful."

# --- Step 2: Create demo directory structure ---
echo ""
echo "=== Setting up demo directories ==="

# Clean previous demo if it exists
rm -rf "$DEMO_DIR"
mkdir -p "$ROOT_DIR" "$PATCH_DIR"

# Helper: create a fake ZIP (just an empty file with .zip extension)
fake_zip() {
    touch "$1"
}

# --- ROOT layer (main DVD content) ---
echo "Creating root layer..."

# === Folder A: TEST-ME — Atari Classics (shared with patch — rich mix + subdirs) ===
mkdir -p "$ROOT_DIR/A/TEST-ME Atari Classics"
fake_zip "$ROOT_DIR/A/TEST-ME Atari Classics/Pac-Man.zip"
fake_zip "$ROOT_DIR/A/TEST-ME Atari Classics/Donkey Kong.zip"
fake_zip "$ROOT_DIR/A/TEST-ME Atari Classics/Galaga.zip"
fake_zip "$ROOT_DIR/A/TEST-ME Atari Classics/Space Invaders.zip"
fake_zip "$ROOT_DIR/A/TEST-ME Atari Classics/Frogger.zip"
fake_zip "$ROOT_DIR/A/TEST-ME Atari Classics/Bomberman.zip"
fake_zip "$ROOT_DIR/A/TEST-ME Atari Classics/Tetris.zip"

# Subdirs: Original and Manual
mkdir -p "$ROOT_DIR/A/TEST-ME Atari Classics/Original"
fake_zip "$ROOT_DIR/A/TEST-ME Atari Classics/Original/Pac-Man (Original).zip"
fake_zip "$ROOT_DIR/A/TEST-ME Atari Classics/Original/Donkey Kong (Original).zip"
mkdir -p "$ROOT_DIR/A/TEST-ME Atari Classics/Manual"
touch "$ROOT_DIR/A/TEST-ME Atari Classics/Manual/Pac-Man.pdf"       # PDF — should NOT appear
touch "$ROOT_DIR/A/TEST-ME Atari Classics/Manual/Donkey Kong.pdf"   # PDF — should NOT appear

# === Folder B: Platformer (root only) ===
mkdir -p "$ROOT_DIR/B/Platformer"
fake_zip "$ROOT_DIR/B/Platformer/Super Mario Bros.zip"
fake_zip "$ROOT_DIR/B/Platformer/Sonic the Hedgehog.zip"
fake_zip "$ROOT_DIR/B/Platformer/Mega Man.zip"
fake_zip "$ROOT_DIR/B/Platformer/Castlevania.zip"

# === Folder C: Puzzle (root only) ===
mkdir -p "$ROOT_DIR/C/Puzzle"
fake_zip "$ROOT_DIR/C/Puzzle/Columns.zip"
fake_zip "$ROOT_DIR/C/Puzzle/Puyo Puyo.zip"
fake_zip "$ROOT_DIR/C/Puzzle/Klax.zip"

# === Folder D: Shoot'em'up (shared with patch — rich mix) ===
mkdir -p "$ROOT_DIR/D/Shoot'em'up"
fake_zip "$ROOT_DIR/D/Shoot'em'up/R-Type.zip"
fake_zip "$ROOT_DIR/D/Shoot'em'up/Gradius.zip"
fake_zip "$ROOT_DIR/D/Shoot'em'up/1942.zip"
fake_zip "$ROOT_DIR/D/Shoot'em'up/Defender.zip"
fake_zip "$ROOT_DIR/D/Shoot'em'up/Centipede.zip"
fake_zip "$ROOT_DIR/D/Shoot'em'up/Galaxian.zip"

# === Folder E: Racing (root only) ===
mkdir -p "$ROOT_DIR/E/Racing"
fake_zip "$ROOT_DIR/E/Racing/Pole Position.zip"
fake_zip "$ROOT_DIR/E/Racing/Out Run.zip"
fake_zip "$ROOT_DIR/E/Racing/Daytona USA.zip"

# --- PATCH layer (overlay/additions) ---
echo "Creating patch layer..."

# === Folder A: TEST-ME — Atari Classics — overrides + new games ===
mkdir -p "$PATCH_DIR/A/TEST-ME Atari Classics"
fake_zip "$PATCH_DIR/A/TEST-ME Atari Classics/Pac-Man.zip"              # [BOTH] override
fake_zip "$PATCH_DIR/A/TEST-ME Atari Classics/Donkey Kong.zip"         # [BOTH] override
fake_zip "$PATCH_DIR/A/TEST-ME Atari Classics/Pac-Man Championship.zip" # [PTCH] new
fake_zip "$PATCH_DIR/A/TEST-ME Atari Classics/Donkey Kong Jr.zip"       # [PTCH] new

# Subdir Original in patch — adds one more
mkdir -p "$PATCH_DIR/A/TEST-ME Atari Classics/Original"
fake_zip "$PATCH_DIR/A/TEST-ME Atari Classics/Original/Galaga (Original).zip"  # [PTCH] in subdir

# === Folder D: Shoot'em'up — overrides + new games ===
mkdir -p "$PATCH_DIR/D/Shoot'em'up"
fake_zip "$PATCH_DIR/D/Shoot'em'up/R-Type.zip"                 # [BOTH] override
fake_zip "$PATCH_DIR/D/Shoot'em'up/R-Type II.zip"              # [PTCH] new
fake_zip "$PATCH_DIR/D/Shoot'em'up/Salamander.zip"             # [PTCH] new

# === Folder F: Patch-only folder (not in root) ===
mkdir -p "$PATCH_DIR/F/Hack & Translation"
fake_zip "$PATCH_DIR/F/Hack & Translation/Pac-Man MSX.zip"
fake_zip "$PATCH_DIR/F/Hack & Translation/Donkey Kong Remix.zip"
fake_zip "$PATCH_DIR/F/Hack & Translation/Galaga Special.zip"

echo "[OK] Demo structure created."
echo ""
echo "  ROOT (DVD)                                    PATCH (Overlay)"
echo "  ──────────                                    ───────────────"
echo "  A/TEST-ME Atari Classics/                     A/TEST-ME Atari Classics/"
echo "    ├── Pac-Man.zip              [BOTH]           ├── Pac-Man.zip"
echo "    ├── Donkey Kong.zip          [BOTH]           ├── Donkey Kong.zip"
echo "    ├── Galaga.zip               [ROOT]           ├── Pac-Man Championship.zip [PTCH]"
echo "    ├── Space Invaders.zip       [ROOT]           ├── Donkey Kong Jr.zip       [PTCH]"
echo "    ├── Frogger.zip              [ROOT]           │"
echo "    ├── Bomberman.zip            [ROOT]           └── Original/"
echo "    ├── Tetris.zip               [ROOT]               └── Galaga (Original).zip [PTCH]"
echo "    ├── Original/"
echo "    │   ├── Pac-Man (Original).zip [ROOT]"
echo "    │   └── Donkey Kong (Original).zip [ROOT]"
echo "    └── Manual/ (PDFs — should NOT appear)"
echo "        ├── Pac-Man.pdf"
echo "        └── Donkey Kong.pdf"
echo "  B/Platformer/                                (no patch)"
echo "    ├── Super Mario Bros.zip     [ROOT]"
echo "    ├── Sonic.zip                [ROOT]"
echo "    ├── Mega Man.zip             [ROOT]"
echo "    └── Castlevania.zip          [ROOT]"
echo "  C/Puzzle/                                    (no patch)"
echo "    ├── Columns.zip              [ROOT]"
echo "    ├── Puyo Puyo.zip            [ROOT]"
echo "    └── Klax.zip                 [ROOT]"
echo "  D/Shoot'em'up/                               D/Shoot'em'up/"
echo "    ├── R-Type.zip               [BOTH]           ├── R-Type.zip"
echo "    ├── Gradius.zip              [ROOT]           ├── R-Type II.zip         [PTCH]"
echo "    ├── 1942.zip                 [ROOT]           └── Salamander.zip        [PTCH]"
echo "    ├── Defender.zip             [ROOT]"
echo "    ├── Centipede.zip            [ROOT]"
echo "    └── Galaxian.zip             [ROOT]"
echo "  E/Racing/                                    (no patch)"
echo "    ├── Pole Position.zip        [ROOT]"
echo "    ├── Out Run.zip          [ROOT]"
echo "    └── Daytona USA.zip      [ROOT]"
echo "                                       F/Hack & Translation/     [PTCH]"
echo "                                         ├── Pac-Man MSX.zip"
echo "                                         ├── DK Remix.zip"
echo "                                         └── Galaga Special.zip"
echo ""

# --- Step 3: Create launcher.config.json ---
echo "=== Writing launcher.config.json ==="

# Create a fake Hatari executable for demo (Linux: shell script with .exe extension)
HATARI_FAKE="$DEMO_DIR/hatari.exe"
cat > "$HATARI_FAKE" <<'HATEXEC'
#!/bin/bash
echo "[DEMO] Hatari would launch with: $@"
HATEXEC
chmod +x "$HATARI_FAKE"

cat > "$CONFIG_FILE" <<EOF
{
  "RootDirectory": "$ROOT_DIR",
  "PatchDirectory": "$PATCH_DIR",
  "Hatari": {
    "Executable": "$HATARI_FAKE",
    "ConfigFile": "",
    "ArgsTemplate": "{zip}"
  }
}
EOF
echo "[OK] Config written to $CONFIG_FILE"

# Copy config to EXE output directory (app looks for it there)
EXE_DIR="$SCRIPT_DIR/src/MarcerGameDvdLauncher/bin/Release/net10.0"
cp "$CONFIG_FILE" "$EXE_DIR/launcher.config.json"
echo "[OK] Config copied to $EXE_DIR"

# --- Step 4: Launch the application ---
echo ""
echo "=== Launching MarcerGameDvdLauncher ==="
echo "Controls: Arrow keys, Enter, Backspace, ESC to exit"
echo ""

cd "$SCRIPT_DIR"
dotnet run --project src/MarcerGameDvdLauncher -c Release
