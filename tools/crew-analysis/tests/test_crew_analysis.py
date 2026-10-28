# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/crew-analysis (stdlib unittest)."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import crew_analysis as ca

ZIP = "A/Alpha/Alpha - Crew.zip"
DISK2 = "A/Alpha/Alpha - Crew - Disk 2.zip"
BETA = "B/Beta/Beta - Crew.zip"
SUB_ZIP = "C/Gamma/sub/Gamma - Crew.zip"
SUB_DISK3 = "C/Gamma/sub/Gamma - Crew - Disk 3.zip"
NO_STATUS = "D/Delta/Delta - Crew.zip"
OTHER_TREE = "Title Sorted/PD Games - Title Sorted/A/Alpha/Alpha.zip"


def entry(name: str, status: str | None = "done", size: int = 1) -> dict:
    value = {"name": name, "size": size}
    if status is not None:
        value["status"] = status
    return value


class LoadZipsFromIndexTest(unittest.TestCase):
    def write_index(self, root: Path, entries: dict[str, dict]) -> Path:
        payload = {
            "entries": {
                ca.INDEX_PREFIX + rel: value for rel, value in entries.items()
            }
        }
        payload["entries"][OTHER_TREE] = entry("Alpha.zip")
        path = root / "index.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def test_excludes_skipped_disks_in_direct_layer(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write_index(Path(tmp), {
                ZIP: entry(Path(ZIP).name),
                DISK2: entry(Path(DISK2).name, "skipped_disk_n"),
                BETA: entry(Path(BETA).name, "desktop"),
                SUB_ZIP: entry(Path(SUB_ZIP).name),
                SUB_DISK3: entry(Path(SUB_DISK3).name, "skipped_disk_n"),
                NO_STATUS: entry(Path(NO_STATUS).name, None),
            })

            zips, skipped = ca.load_zips_from_index(path, include_subdirs=False)

        rels = {item[0] for item in zips}
        self.assertEqual(rels, {ZIP, BETA, NO_STATUS})
        self.assertEqual(skipped, 1)
        self.assertNotIn(DISK2, rels)
        self.assertNotIn(SUB_DISK3, rels)

    def test_include_subdirs_keeps_disk1_and_excludes_disk2plus(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write_index(Path(tmp), {
                ZIP: entry(Path(ZIP).name),
                DISK2: entry(Path(DISK2).name, "skipped_disk_n"),
                BETA: entry(Path(BETA).name, "desktop"),
                SUB_ZIP: entry(Path(SUB_ZIP).name),
                SUB_DISK3: entry(Path(SUB_DISK3).name, "skipped_disk_n"),
                NO_STATUS: entry(Path(NO_STATUS).name, None),
            })

            zips, skipped = ca.load_zips_from_index(path, include_subdirs=True)

        rels = {item[0] for item in zips}
        self.assertEqual(rels, {ZIP, BETA, SUB_ZIP, NO_STATUS})
        self.assertEqual(skipped, 2)

    def test_preserves_index_metadata_and_ignores_other_trees(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write_index(Path(tmp), {
                ZIP: entry(Path(ZIP).name, size=1234),
            })

            zips, _skipped = ca.load_zips_from_index(path, include_subdirs=False)

        self.assertEqual(len(zips), 1)
        rel, letter, folder, name, size, direct = zips[0]
        self.assertEqual(rel, ZIP)
        self.assertEqual((letter, folder), ("A", "Alpha"))
        self.assertEqual(name, Path(ZIP).name)
        self.assertEqual(size, 1234)
        self.assertTrue(direct)


class TabSelectionFlagsTest(unittest.TestCase):
    def test_normalized_name_collision_keeps_independent_visibility(self):
        selection = {
            "include_until": ca.norm("Arthur Dent"),
            "keep": set(),
            "exclude": set(),
        }
        names = ["Replicants / Union", "Arthur Dent", "Replicants/Union"]

        flags = ca.tab_selection_flags(names, selection)

        self.assertFalse(flags["Replicants / Union"])
        self.assertFalse(flags["Arthur Dent"])
        self.assertTrue(flags["Replicants/Union"])

    def test_exclude_uses_normalized_names_but_returns_original_keys(self):
        selection = {
            "include_until": ca.norm("Arthur Dent"),
            "keep": {ca.norm("Genesis Inc")},
            "exclude": {ca.norm("A-HA")},
        }
        names = ["A-HA", "Arthur Dent", "Ator", "Genesis Inc"]

        flags = ca.tab_selection_flags(names, selection)

        self.assertTrue(flags["A-HA"])
        self.assertFalse(flags["Arthur Dent"])
        self.assertTrue(flags["Ator"])
        self.assertFalse(flags["Genesis Inc"])

    def test_keep_collision_only_keeps_configured_spelling(self):
        selection = {
            "include_until": ca.norm("Arthur Dent"),
            "keep": {ca.norm("Replicants / Masters")},
            "keep_exact": {"Replicants / Masters"},
            "exclude": set(),
            "exclude_exact": set(),
        }
        names = ["Arthur Dent", "Replicants / Masters", "Replicants/Masters"]

        flags = ca.tab_selection_flags(names, selection)

        self.assertFalse(flags["Replicants / Masters"])
        self.assertTrue(flags["Replicants/Masters"])


if __name__ == "__main__":
    unittest.main()
