#!/bin/sh
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
# Wrapper: loads local/paths.env and runs piratefinder-gen with the repo venv.
set -e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "$REPO_ROOT/local/paths.env" ]; then
    set -a
    . "$REPO_ROOT/local/paths.env"
    set +a
fi
if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
    PY="$REPO_ROOT/.venv/bin/python"
else
    PY="python3"
fi
export PYTHONDONTWRITEBYTECODE=1
exec "$PY" "$REPO_ROOT/tools/piratefinder-gen/piratefinder_gen.py" "$@"
