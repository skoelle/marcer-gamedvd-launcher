#!/bin/sh
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
# Universal screenshot pipeline (same steps as pd.sh) for any scope.
# Usage: full.sh <scope>
set -e
cd "$(dirname "$0")"

REPO_ROOT="$(cd ../.. && pwd)"
SCOPES="$("$REPO_ROOT/.venv/bin/python" - <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(".").resolve()))
import shotgen
_, scopes = shotgen.resolve_scopes(shotgen.load_config())
print(" ".join(sorted(scopes)))
PY
)"

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <scope>" >&2
    echo "available scopes: $SCOPES" >&2
    exit 2
fi

SCOPE="$1"
case " $SCOPES " in
    *" $SCOPE "*) ;;
    *) echo "error: unknown scope '$SCOPE'" >&2
       echo "available scopes: $SCOPES" >&2
       exit 2 ;;
esac

./run.sh index --scope "$SCOPE"
./run.sh run --scope "$SCOPE" --jobs 4
./run.sh detect --scope "$SCOPE"
./run.sh run --scope "$SCOPE" --retry-desktop --jobs 4
./run.sh run --scope "$SCOPE" --retry-desktop-auto --jobs 8
./run.sh run --scope "$SCOPE" --retry-no-usable --tos 1.02 --jobs 4

# Retry known error screens before the final index/audit pass.
../screenshot-audit/run.sh retry --section "$SCOPE" --jobs 4

./run.sh cleanup-duplicates --scope "$SCOPE"
./run.sh index --scope "$SCOPE"

# Final read-only report for the next review.
../screenshot-audit/run.sh scan --section "$SCOPE" --limit-clusters 120
