#!/bin/sh
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
# Wrapper: loads local/paths.env and runs the crew analysis with the repo venv.
set -e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "$REPO_ROOT/local/paths.env" ]; then
    set -a
    . "$REPO_ROOT/local/paths.env"
    set +a
fi
export PYTHONDONTWRITEBYTECODE=1
exec "$REPO_ROOT/.venv/bin/python" "$REPO_ROOT/tools/crew-analysis/crew_analysis.py" "$@"
