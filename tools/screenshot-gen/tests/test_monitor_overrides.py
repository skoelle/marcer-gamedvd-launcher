# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for screenshot-gen monitor overrides."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import shotgen


SCOPE = {
    "name": "pd",
    "trees": ["Title Sorted/PD Games - Title Sorted"],
}
BASE = "Title Sorted/PD Games - Title Sorted/T"


def config(**overrides):
    cfg = {
        "mono_dir_suffix": "Mono",
        "monitor_overrides": {},
        "screen_format_monitor": {},
    }
    cfg.update(overrides)
    return cfg


class AtariPathTests(unittest.TestCase):
    def test_umlaut_is_passed_as_single_atari_byte(self) -> None:
        value = shotgen._atari_cli_path("A:\\TI_MÄUSE\\TI_MÄUSE.PRG")
        self.assertEqual(
            value.encode("utf-8", "surrogateescape"),
            b"A:\\TI_M\x8eUSE\\TI_M\x8eUSE.PRG",
        )


class MonitorOverrideTests(unittest.TestCase):
    def test_exact_folder_override_wins(self) -> None:
        cfg = config(monitor_overrides={"pd:Tartan - Col and Mon": "mono"})
        rel = f"{BASE}/Tartan - Col and Mon/Tartan v1.1 PD.zip"
        self.assertEqual(
            shotgen.resolve_monitor(cfg, SCOPE, rel, {}),
            ("mono", "override"),
        )

    def test_glob_below_tree_matches_single_file(self) -> None:
        cfg = config(
            monitor_overrides={"pd:Tiny quest/Tiny Quest v2*": "mono"}
        )
        rel = f"{BASE}/Tiny quest/Tiny Quest v2.zip"
        self.assertEqual(
            shotgen.resolve_monitor(cfg, SCOPE, rel, {}),
            ("mono", "override"),
        )

    def test_invalid_override_falls_back_to_color(self) -> None:
        cfg = config(monitor_overrides={"pd:Tartan - Col and Mon": "please"})
        rel = f"{BASE}/Tartan - Col and Mon/Tartan v1.1 PD.zip"
        self.assertEqual(
            shotgen.resolve_monitor(cfg, SCOPE, rel, {}),
            ("color", "default"),
        )

    def test_override_beats_gameinfo_rule(self) -> None:
        cfg = config(
            monitor_overrides={"pd:Tartan - Col and Mon": "mono"},
            screen_format_monitor={"pd": {"mono_if_all": ["high"]}},
        )
        key = ("t", "tartan - col and mon")
        rel = f"{BASE}/Tartan - Col and Mon/Tartan v1.1 PD.zip"
        self.assertEqual(
            shotgen.resolve_monitor(cfg, SCOPE, rel, {key: ["low"]}),
            ("mono", "override"),
        )


if __name__ == "__main__":
    unittest.main()
