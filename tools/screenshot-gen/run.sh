#!/bin/sh
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
# Wrapper: loads local/paths.env and runs shotgen with the repo venv.
set -e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "$REPO_ROOT/local/paths.env" ]; then
    set -a
    . "$REPO_ROOT/local/paths.env"
    set +a
fi
# Cap glibc malloc arenas before the interpreter starts (must be set here,
# not from Python). The parallel run's per-thread arenas otherwise fragment
# and grow without bound until the OOM killer reaps the process.
: "${MALLOC_ARENA_MAX:=2}"
export MALLOC_ARENA_MAX
exec "$REPO_ROOT/.venv/bin/python" "$REPO_ROOT/tools/screenshot-gen/shotgen.py" "$@"
