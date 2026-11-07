# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for the plain/failure/valid pHash screen classification."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import shotgen


PLAIN_MONO_1 = "fe9ffc9c80808cb8"
PLAIN_MONO_2 = "ffbebe9c8088809c"
PLAIN_MONO_3 = "ffbf9c9c9c888088"
DRIVE_B_DIALOG = "dfbc34938aaca093"
# Exact valid app menu; a no_usable cluster is 4 bits away.
VALID_GEM_APP = "a6a6a6a6a6a6a6a6"
# Exact no_usable "Program starts but hangs" cluster.
HANG_SCREEN = "b3a3a3a3b3a3a2a2"
# Exact no_usable cluster with a valid cluster 6 bits away.
FAILURE_WITH_DISTANT_VALID = "99a2668699b3e6c6"
# no_usable at distance 2, valid cluster at distance 4.
FAILURE_BEATS_VALID = "9aa065c39ab0e7c7"



class ScreenHashTests(unittest.TestCase):
    def setUp(self) -> None:
        self.cfg = shotgen.load_config()

    def test_all_known_plain_desktops_match(self) -> None:
        for phash in (PLAIN_MONO_1, PLAIN_MONO_2, PLAIN_MONO_3):
            self.assertTrue(
                shotgen.is_plain_desktop(phash, self.cfg), phash
            )

    def test_app_screen_is_not_a_plain_desktop(self) -> None:
        self.assertFalse(shotgen.is_plain_desktop(VALID_GEM_APP, self.cfg))

    def test_drive_b_dialog_is_a_failure_screen(self) -> None:
        self.assertTrue(shotgen.is_failure_screen(DRIVE_B_DIALOG, self.cfg))
        self.assertFalse(shotgen.is_plain_desktop(DRIVE_B_DIALOG, self.cfg))

    def test_valid_app_beats_distant_failure_cluster(self) -> None:
        self.assertTrue(shotgen.is_failure_screen(VALID_GEM_APP, self.cfg))
        match = shotgen.marked_valid_match(VALID_GEM_APP, self.cfg)
        self.assertIsNotNone(match)
        self.assertEqual(match[0], 0)
        self.assertIn("gem program", match[2]["label"].lower())

    def test_exact_or_nearer_failure_is_never_marked_valid(self) -> None:
        for phash in (HANG_SCREEN, FAILURE_WITH_DISTANT_VALID,
                      FAILURE_BEATS_VALID):
            self.assertIsNone(
                shotgen.marked_valid_match(phash, self.cfg), phash
            )

    def test_drive_b_dialog_detection(self) -> None:
        self.assertTrue(
            shotgen.is_drive_b_dialog(DRIVE_B_DIALOG, self.cfg)
        )
        self.assertFalse(
            shotgen.is_drive_b_dialog(PLAIN_MONO_1, self.cfg)
        )

    def test_config_failure_hash_is_recognized(self) -> None:
        cfg = json.loads(json.dumps(self.cfg))
        cfg["filters"]["failure_phashes"] = ["1111111111111111"]
        cfg["filters"]["failure_phash_max_distance"] = 0
        with tempfile.TemporaryDirectory() as tmp:
            registry = Path(tmp) / "screens.json"
            registry.write_text('{"screens": {}}', encoding="utf-8")
            cfg["filters"]["audit_registry"] = str(registry)
            self.assertTrue(
                shotgen.is_failure_screen("1111111111111111", cfg)
            )
            self.assertFalse(
                shotgen.is_failure_screen(DRIVE_B_DIALOG, cfg)
            )

    def test_reviewed_gem_app_matches_valid_cluster(self) -> None:
        match = shotgen.marked_valid_match(VALID_GEM_APP, self.cfg)
        self.assertIsNotNone(match)
        self.assertEqual(match[1], VALID_GEM_APP)
        self.assertIn("gem program", match[2]["label"].lower())

    def test_unknown_or_plain_screen_is_not_marked_valid(self) -> None:
        self.assertIsNone(shotgen.marked_valid_match(PLAIN_MONO_1, self.cfg))
        self.assertIsNone(shotgen.marked_valid_match(DRIVE_B_DIALOG, self.cfg))

    def test_label_hints_filter_registry(self) -> None:
        screens = {
            "b3a2a6a2b3b3a2a6": {
                "action": "valid",
                "label": "GEM program with real menu bar (done/game)",
            },
            "9999999999999999": {
                "action": "valid",
                "label": "LAPD bootsector cracktro",
            },
        }
        with tempfile.TemporaryDirectory() as tmp:
            registry = Path(tmp) / "screens.json"
            registry.write_text(
                json.dumps({"screens": screens}), encoding="utf-8"
            )
            cfg = json.loads(json.dumps(self.cfg))
            cfg["filters"]["audit_registry"] = str(registry)
            self.assertIsNotNone(
                shotgen.marked_valid_match(HANG_SCREEN, cfg)
            )
            self.assertIsNone(
                shotgen.marked_valid_match("9999999999999999", cfg),
                "cracktro clusters are not app/textscreen hints",
            )


if __name__ == "__main__":
    unittest.main()
