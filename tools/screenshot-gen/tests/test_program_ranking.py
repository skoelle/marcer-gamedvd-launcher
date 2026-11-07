# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for the auto-retry program ranking."""

from __future__ import annotations

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import shotgen


def files(*items):
    return [(name, size, b"") for name, size in items]


class FloppyRankingTests(unittest.TestCase):
    def test_calamus_prefers_main_program_over_auto_helper(self) -> None:
        with mock.patch.object(shotgen, "_fat12_files", return_value=files(
                ("CALAMUS.PRG", 407094),
                ("INST_CAR.PRG", 4300),
                ("AUTO/MCLOCK.PRG", 1005),
                ("GOODBLIT.PRG", 487))):
            programs = shotgen._floppy_programs(
                b"", "Calamus v1.09 - French")
        self.assertEqual(programs[0], "CALAMUS.PRG")

    def test_atabank_prefers_main_program_over_auto_helper(self) -> None:
        with mock.patch.object(shotgen, "_fat12_files", return_value=files(
                ("ATABANK.PRG", 66377),
                ("AUTO/EPSON.PRG", 3662))):
            programs = shotgen._floppy_programs(
                b"", "Atabank v92.03 - French")
        self.assertEqual(programs[0], "ATABANK.PRG")

    def test_1st_word_prefers_stem_match(self) -> None:
        with mock.patch.object(shotgen, "_fat12_files", return_value=files(
                ("1STWORD.PRG", 82858),
                ("SBASE.PRG", 17070),
                ("AUTO/LRC.PRG", 1753))):
            programs = shotgen._floppy_programs(
                b"", "1st Word Plus v2.02 - Swedish - Alpha Force")
        self.assertEqual(programs[0], "1STWORD.PRG")

    def test_helper_only_disk_still_yields_candidate(self) -> None:
        with mock.patch.object(shotgen, "_fat12_files", return_value=files(
                ("AUTO/DRIVER.PRG", 1000))):
            programs = shotgen._floppy_programs(b"", "Driver Disk")
        self.assertEqual(programs, ["AUTO/DRIVER.PRG"])

    def test_helper_is_demoted_below_smaller_main_program(self) -> None:
        with mock.patch.object(shotgen, "_fat12_files", return_value=files(
                ("MAIN.PRG", 100),
                ("DRIVER.PRG", 1000),
                ("AUTO/X.PRG", 2000))):
            programs = shotgen._floppy_programs(b"", "Disk 1")
        self.assertEqual(programs[0], "MAIN.PRG")

    def test_sfx_is_skipped(self) -> None:
        with mock.patch.object(shotgen, "_fat12_files", return_value=[
                ("SFX.PRG", 1000, b"STZip self extracting"),
                ("APP.PRG", 500, b"")]):
            programs = shotgen._floppy_programs(b"", "App")
        self.assertEqual(programs, ["APP.PRG"])


class HelperDetectionTests(unittest.TestCase):
    def test_helper_hints_do_not_demote_real_words(self) -> None:
        self.assertFalse(shotgen._is_helper_program("CLOCKWORK.PRG"))
        self.assertFalse(shotgen._is_helper_program("BOOTLEG.PRG"))
        self.assertTrue(shotgen._is_helper_program("SETUP.PRG"))
        self.assertTrue(shotgen._is_helper_program("MONO_EMU.PRG"))
        self.assertTrue(shotgen._is_helper_program("SETUP2.APP"))
        self.assertTrue(shotgen._is_helper_program("INST_CAR.PRG"))
        self.assertTrue(shotgen._is_helper_program("AUTO/X.PRG"))


class GemdosRankingTests(unittest.TestCase):
    def test_auto_helper_is_demoted_for_gemdos_too(self) -> None:
        with mock.patch.object(shotgen, "_is_stzip", return_value=False):
            programs = shotgen.boot_program_candidates(
                None,
                ["APP.PRG", "AUTO/DRIVER.PRG"],
                {"APP.PRG": 100, "AUTO/DRIVER.PRG": 5000},
                "App",
            )
        self.assertEqual(programs[0], "APP.PRG")

    def test_stem_match_wins_over_larger_helper(self) -> None:
        with mock.patch.object(shotgen, "_is_stzip", return_value=False):
            programs = shotgen.boot_program_candidates(
                None,
                ["WORD.PRG", "AUTO/SETUP.PRG"],
                {"WORD.PRG": 100, "AUTO/SETUP.PRG": 5000},
                "Word v1",
            )
        self.assertEqual(programs[0], "WORD.PRG")


class AutoPlanReasonTests(unittest.TestCase):
    def _zip(self, tmp: str, members) -> Path:
        path = Path(tmp) / "disk.zip"
        with zipfile.ZipFile(path, "w") as zf:
            for name, data in members:
                zf.writestr(name, data)
        return path

    def test_isk_image_is_not_atari(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = self._zip(tmp, [("Pagemaker.isk", b"x")])
            plan = shotgen.auto_plan(path, "Pagemaker")
        self.assertEqual(plan["mode"], None)
        self.assertEqual(plan["reason"], "not_atari")

    def test_msdos_fat_is_not_atari(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = self._zip(tmp, [("disk.st", b"x")])
            with mock.patch.object(shotgen, "_image_to_raw",
                                   return_value=b"raw"), \
                    mock.patch.object(shotgen, "_fat12_files",
                                      return_value=files(
                                          ("SETUP.EXE", 100),
                                          ("PC.EXE", 200))), \
                    mock.patch.object(shotgen, "_floppy_programs",
                                      return_value=[]):
                plan = shotgen.auto_plan(path, "PC Tools")
        self.assertEqual(plan["mode"], None)
        self.assertEqual(plan["reason"], "not_atari")

    def test_mac_disk_image_file_is_not_atari(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = self._zip(tmp, [("disk.st", b"x")])
            with mock.patch.object(shotgen, "_image_to_raw",
                                   return_value=b"raw"), \
                    mock.patch.object(shotgen, "_fat12_files",
                                      return_value=files(
                                          ("ALADIN_D.ISK", 728064))), \
                    mock.patch.object(shotgen, "_floppy_programs",
                                      return_value=[]):
                plan = shotgen.auto_plan(path, "Pagemaker")
        self.assertEqual(plan["reason"], "not_atari")

    def test_unreadable_fat_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = self._zip(tmp, [("disk.st", b"x")])
            with mock.patch.object(shotgen, "_image_to_raw",
                                   return_value=b"raw"), \
                    mock.patch.object(shotgen, "_fat12_files",
                                      return_value=[]), \
                    mock.patch.object(shotgen, "_floppy_programs",
                                      return_value=[]):
                plan = shotgen.auto_plan(path, "Broken")
        self.assertEqual(plan["reason"], "no_program")


if __name__ == "__main__":
    unittest.main()
