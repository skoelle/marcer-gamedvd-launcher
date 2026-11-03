#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Shared state path resolution for the catalog pipeline tools.

Pipeline state lives in ``$MARCER_DATA_DIR/state`` by default. An explicit
``MARCER_STATE_DIR`` still overrides that location (the Docker container uses
``/state``, mounted from ``$HOST_DATA_DIR/state``).
"""
from __future__ import annotations

import os
from pathlib import Path


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def data_dir() -> Path | None:
    value = env("MARCER_DATA_DIR")
    return Path(value).expanduser() if value else None


def state_dir_for(data: Path) -> Path:
    """Return the state root for ``data``, honouring MARCER_STATE_DIR."""
    explicit = env("MARCER_STATE_DIR")
    if explicit:
        return Path(explicit).expanduser()
    return Path(data).expanduser() / "state"


def state_dir() -> Path | None:
    data = data_dir()
    if data is not None:
        return state_dir_for(data)
    explicit = env("MARCER_STATE_DIR")
    return Path(explicit).expanduser() if explicit else None


def state_root(repo_root: Path) -> Path:
    """Return the state root, with a repo-local fallback for standalone tools."""
    resolved = state_dir()
    if resolved is not None:
        return resolved
    return Path(repo_root).expanduser() / "local"


def asset_state_file_for(data: Path) -> Path:
    return state_dir_for(data) / "asset-publish" / "state.json"


def legacy_asset_state_file_for(data: Path) -> Path:
    return Path(data).expanduser() / ".asset-publish-state.json"
