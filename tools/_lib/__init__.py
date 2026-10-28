# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Shared, stdlib-only helpers for the Marcer catalog tools.

The modules here are imported by the pipeline tools (`gameinfo-gen`,
`full-index-gen`, `crew-analysis`, `screenshot-gen`). They must not import
third-party packages so the pipeline container only needs the standard
library (plus `olefile` for the XLS reader).
"""
