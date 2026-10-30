# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/crew-analysis (stdlib unittest)."""

from __future__ import annotations

import gzip
import json
import sys
import tempfile
import unittest
from collections import Counter
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


class LoadZipsFromFullIndexTest(unittest.TestCase):
    PREFIX = "Title Sorted/Cracked Games - Title Sorted/"

    def write_full_index(self, root: Path, entries: dict) -> Path:
        path = root / "full-index.json.gz"
        with gzip.open(path, "wt", encoding="utf-8") as handle:
            json.dump({"entries": entries}, handle)
        return path

    def test_uses_section_and_derives_skipped_disks(self):
        values = {
            self.PREFIX + ZIP: {"section": "cracked", "name": Path(ZIP).name},
            self.PREFIX + DISK2: {"section": "cracked", "name": Path(DISK2).name},
            self.PREFIX + BETA: {"section": "cracked", "name": Path(BETA).name},
            self.PREFIX + SUB_ZIP: {"section": "cracked", "name": Path(SUB_ZIP).name},
            self.PREFIX + SUB_DISK3: {
                "section": "cracked", "name": Path(SUB_DISK3).name},
            self.PREFIX + "P/Other/Other.zip": {
                "section": "pd", "name": "Other.zip"},
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write_full_index(Path(tmp), values)
            zips, skipped = ca.load_zips_from_full_index(
                path, include_subdirs=False)
            all_zips, all_skipped = ca.load_zips_from_full_index(
                path, include_subdirs=True)

        rels = {item[0] for item in zips}
        self.assertEqual(rels, {self.PREFIX + ZIP, self.PREFIX + BETA})
        self.assertEqual(skipped, 1)
        all_rels = {item[0] for item in all_zips}
        self.assertIn(self.PREFIX + SUB_ZIP, all_rels)
        self.assertEqual(all_skipped, 2)
        self.assertNotIn(self.PREFIX + "P/Other/Other.zip", all_rels)

    def test_metadata_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write_full_index(Path(tmp), {
                self.PREFIX + ZIP: {
                    "section": "cracked", "name": Path(ZIP).name, "size": 1234},
            })
            zips, _skipped = ca.load_zips_from_full_index(
                path, include_subdirs=False)
        rel, letter, folder, name, size, direct = zips[0]
        self.assertEqual(rel, self.PREFIX + ZIP)
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


class RegistryAliasesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = Path(ca.__file__).with_name("aliases.json")
        cls.explicit = ca.load_aliases(cls.path)

    def test_duplicate_group_alias_is_merged(self):
        self.assertEqual(self.explicit[ca.norm("SFX")], "Special FX")

    def test_typo_and_spelling_aliases_are_canonicalized(self):
        expected = {
            "Klapauziuz": "Klapauzius",
            "Bergerdorf Atari Clan": "Bergerdor Atari Clan - BAC",
            "14th July Band": "14th Julys Band",
            "14th July's Band": "14th Julys Band",
            "Corpotation": "Corporation - TCR",
            "Auto 494": "Automation",
            "D_079_B": "D-Bug",
            "Vectroyd": "Vectoryd",
            "Supergau": "SuperGAU",
            "Beverly Hills Cop - Hal": "Bad Brew Crew - BBC",
            "TNT": "TNT Crew",
            "SJ": "SJ Crew",
        }
        for alias, canonical in expected.items():
            self.assertEqual(self.explicit[ca.norm(alias)], canonical, alias)

    def test_tnt_label_merges_into_tnt_crew(self):
        raw, aliases, _abbrev, labels = ca.build_registry(
            ["TNT Crew", "SJ Crew"], {"TNT": {"crew"}},
            self.explicit, set())
        self.assertEqual(raw["TNT Crew"], "TNT Crew")
        self.assertEqual(labels["TNT"], "TNT Crew")
        self.assertIn("TNT Crew", aliases[ca.norm("TNT")])
        self.assertIn("SJ Crew", aliases[ca.norm("SJ")])

    def test_piratefinder_spelling_variants_are_aliases(self):
        expected = {
            "The Lemmings": "Lemmings",
            "The Flying Knights": "Flying Knights",
            "The Public Enemies": "Public Enemys",
            "Public Enemies": "Public Enemys",
            "Dirty Tricks Brigade": "Dirty Tricks",
        }
        for alias, canonical in expected.items():
            self.assertEqual(self.explicit[ca.norm(alias)], canonical, alias)

    def test_gameinfo_label_merges_into_crew_sorted_group(self):
        raw, _aliases, _abbrev, labels = ca.build_registry(
            ["Special FX"], {"SFX": {"crew"}}, self.explicit, set())
        self.assertEqual(raw["Special FX"], "Special FX")
        self.assertEqual(labels["SFX"], "Special FX")

    def test_new_aliases_match_unmatched_zip_names(self):
        _raw, aliases, abbrev, _labels = ca.build_registry(
            [], {}, self.explicit, set())
        expected = {
            "Hotshot - 14th July Band.zip": "14th Julys Band",
            "North and South - 68010 version - Klapauziuz.zip": "Klapauzius",
            "Mickeys Runaway Zoo - Auto 494.zip": "Automation",
            "Welltris - Corpotation.zip": "Corporation - TCR",
            "Adventures of Snatch and Crunch - D_079_B.zip": "D-Bug",
            "Crimson Crown - Supergau.zip": "SuperGAU",
            "Transworld - German - Vectroyd.zip": "Vectoryd",
            "Beverly Hills Cop - Hal.zip": "Bad Brew Crew - BBC",
        }
        for name, group in expected.items():
            suffix = name.split(" - ", 1)[1] if " - " in name else name
            hits = ca.alias_hits(
                set(ca.tokens(name)),
                ca.compact(name),
                set(ca.tokens(suffix)),
                aliases,
                abbrev,
            )
            self.assertIn(group, {hit[2] for hit in hits}, name)


class ExactCrewLookupTest(unittest.TestCase):
    def test_strips_trailing_bad_marker(self):
        exact = {"tnt - sj crew.zip": [("SJ Crew", 155471)]}
        self.assertEqual(
            ca.exact_crew_entries("TNT - SJ Crew - BAD.zip", exact),
            [("SJ Crew", 155471)],
        )

    def test_does_not_strip_stopword_or_real_segments(self):
        exact = {"game": [("Wrong Crew", 1)]}
        self.assertEqual(
            ca.exact_crew_entries("Game - Crew - BAD.zip", exact), [])
        self.assertEqual(
            ca.exact_crew_entries("TNT - SJ Crew - Extra.zip", exact), [])

    def test_never_falls_back_to_a_bare_title(self):
        exact = {"predator.zip": [("Galaxy Rangers", 1)]}
        self.assertEqual(
            ca.exact_crew_entries("Predator - Unknown.zip", exact), [])

    def test_strips_marker_after_a_credit_segment(self):
        exact = {
            "space shuttle v1.0 - rottweiller crew.zip": [
                ("Rottenweiller Crew", 1),
            ],
        }
        self.assertEqual(
            ca.exact_crew_entries(
                "Space Shuttle v1.0 - Rottweiller Crew - Disk 1.zip", exact),
            [("Rottenweiller Crew", 1)],
        )


class AliasSuffixTest(unittest.TestCase):
    def test_title_abbreviation_does_not_beat_credit_suffix(self):
        aliases = {"tnt": {"TNT Crew"}, "sj": {"SJ Crew"}}
        hits = ca.alias_hits(
            set(ca.tokens("TNT - SJ Crew - BAD.zip")),
            ca.compact("TNT - SJ Crew - BAD.zip"),
            set(ca.tokens("SJ Crew - BAD")),
            aliases,
            {"tnt", "sj"},
        )
        self.assertEqual({hit[2] for hit in hits}, {"SJ Crew"})

    def test_credit_abbreviation_still_matches(self):
        aliases = {"tnt": {"TNT Crew"}, "sj": {"SJ Crew"}}
        hits = ca.alias_hits(
            set(ca.tokens("In Eighty Days - TNT Crew.zip")),
            ca.compact("In Eighty Days - TNT Crew.zip"),
            set(ca.tokens("TNT Crew")),
            aliases,
            {"tnt", "sj"},
        )
        self.assertEqual({hit[2] for hit in hits}, {"TNT Crew"})


class PickVariantTest(unittest.TestCase):
    """The release row must not silently inherit the first (Original) variant."""

    ZIPS = [
        {"title": "F15 Strike Eagle 2", "cracked_by": "Cyrano Jones",
         "crew": "D-Bug", "release": "1990"},
        {"title": "F15 Strike Eagle 2", "cracked_by": "Cameo",
         "crew": "Replicants", "release": ""},
        {"title": "F15 Strike Eagle 2 v2.07.1991",
         "cracked_by": "Dr Trap / Empire", "crew": "Elite", "release": ""},
    ]
    ZIP_NAME = ("F15 Strike Eagle 2 v2.7.91 - Dr Trap - Empire - Elite "
                "- Disk 1.zip")

    def test_group_label_wins(self):
        canon = {"Dr Trap / Empire": "Dr Trap / Empire"}
        self.assertIs(
            ca.pick_variant(self.ZIPS, "Dr Trap / Empire", canon, "other.zip"),
            self.ZIPS[2],
        )

    def test_zip_name_fallback_matches_label_tokens(self):
        self.assertIs(
            ca.pick_variant(self.ZIPS, "Dr Trap / Empire", {}, self.ZIP_NAME),
            self.ZIPS[2],
        )

    def test_ambiguous_zip_returns_none(self):
        variants = self.ZIPS[:2]
        self.assertIsNone(
            ca.pick_variant(variants, "Dr Trap / Empire", {}, self.ZIP_NAME)
        )

    def test_single_variant_is_used(self):
        self.assertIs(
            ca.pick_variant(self.ZIPS[:1], "Unknown", {}, "anything.zip"),
            self.ZIPS[0],
        )

    def test_make_release_omits_group_fields_when_unresolved(self):
        release = ca.make_release(
            "F/F15/F15 - Dr Trap.zip", "F", "F15", self.ZIP_NAME,
            1, "exact", "Dr Trap / Empire", self.ZIPS[:2], False, {},
        )
        self.assertEqual(release["cracked_by"], "")
        self.assertEqual(release["crew"], "")
        self.assertEqual(release["title"], "F15 Strike Eagle 2")


class PlaceholderLabelTest(unittest.TestCase):
    def test_placeholders_are_cleaned(self):
        for value in ("Original", "unknown", "????", "No 1 & No 2"):
            self.assertEqual(ca.clean_group_label(value), "", value)
        self.assertEqual(ca.clean_group_label("Unknown Man"), "Unknown Man")
        self.assertEqual(ca.clean_group_label("Dr Trap / Empire"),
                         "Dr Trap / Empire")


class LabelInferenceTest(unittest.TestCase):
    @staticmethod
    def release(zip_name, title, cracked_by="", crew=""):
        return {
            "zip": zip_name,
            "title": title,
            "folder": title,
            "cracked_by": cracked_by,
            "crew": crew,
        }

    def test_title_words_are_not_used_as_labels(self):
        rows = {"Elite": [
            self.release("Gauntlet - Elite.zip", "Gauntlet"),
            self.release("Hotshots - Elite.zip", "Hotshots"),
            self.release("Elite v1.01 - Cracked.zip", "Elite v1.01"),
        ]}
        ca.infer_release_labels(rows, {"Elite": {"Elite"}}, {"Elite"})
        self.assertEqual(rows["Elite"][2]["cracked_by"], "")
        self.assertEqual(rows["Elite"][2]["crew"], "")
        self.assertEqual(rows["Elite"][0]["crew"], "Elite")

    def test_group_side_and_known_cracker_are_filled(self):
        rows = {
            "Replicants": [
                self.release("AGE - Cameo - Replicants.zip", "AGE",
                             cracked_by="Cameo", crew="Replicants"),
                self.release("Sensible - Snake - Replicants.zip", "Sensible",
                             cracked_by="Snake", crew="Replicants"),
                self.release("Rodland - Snake - Replicants.zip", "Rodland"),
            ],
        }
        ca.infer_release_labels(
            rows, {"Replicants": {"Replicants"}}, {"Replicants"})
        release = rows["Replicants"][2]
        self.assertEqual(release["cracked_by"], "Snake")
        self.assertEqual(release["crew"], "Replicants")
        self.assertEqual(release["inferred_fields"], ["cracked_by", "crew"])

    def test_joint_group_does_not_mask_its_own_crew(self):
        rows = {
            "Dr Trap / Empire": [
                self.release(
                    "F15 Strike Eagle 2 v2.7.91 - Dr Trap - Empire - Elite "
                    "- Disk 1.zip",
                    "F15 Strike Eagle 2",
                ),
            ],
            "Elite": [
                self.release("Gauntlet - Elite.zip", "Gauntlet"),
                self.release("Hotshots - Elite.zip", "Hotshots"),
            ],
            "Empire": [
                self.release("Gods - Empire.zip", "Gods"),
                self.release("Elf - Empire.zip", "Elf"),
            ],
        }
        ca.infer_release_labels(
            rows,
            {
                "Dr Trap / Empire": {"Dr Trap / Empire"},
                "Elite": {"Elite"},
                "Empire": {"Empire"},
            },
            {"Elite", "Empire"},
        )
        release = rows["Dr Trap / Empire"][0]
        self.assertEqual(release["cracked_by"], "Dr Trap / Empire")
        self.assertEqual(release["crew"], "Elite")

    def test_short_group_crew_alignment(self):
        rows = {"V8": [{
            "zip": "Falcon v1.1 - Mission Disk 1 v1.0 - V8.zip",
            "title": "Falcon",
            "folder": "Falcon",
            "cracked_by": "",
            "crew": "",
        }]}
        ca.infer_release_labels(rows, {"V8": {"V8"}}, {"V8"})
        self.assertEqual(rows["V8"][0]["crew"], "V8")

    def test_exact_match_fills_short_group_name(self):
        rows = {"SJ Crew": [{
            "zip": "TNT - SJ Crew - BAD.zip",
            "title": "TNT",
            "folder": "TNT",
            "cracked_by": "",
            "crew": "",
            "source": "exact",
        }]}
        ca.infer_release_labels(rows, {"SJ Crew": {"SJ Crew"}}, {"SJ Crew"})
        release = rows["SJ Crew"][0]
        self.assertEqual(release["crew"], "SJ Crew")
        self.assertEqual(release["inferred_fields"], ["crew"])

    def test_ambiguous_credit_is_not_guessed(self):
        rows = {
            "Foo": [
                self.release("Game A - Empire - Elite.zip", "Game A"),
                self.release("Game B - Empire - Elite.zip", "Game B"),
            ],
            "Elite": [
                self.release("Gauntlet - Elite.zip", "Gauntlet"),
                self.release("Hotshots - Elite.zip", "Hotshots"),
            ],
            "Empire": [
                self.release("Gods - Empire.zip", "Gods"),
                self.release("Elf - Empire.zip", "Elf"),
            ],
        }
        ca.infer_release_labels(
            rows,
            {"Foo": {"Foo"}, "Elite": {"Elite"}, "Empire": {"Empire"}},
            {"Foo", "Elite", "Empire"},
        )
        for release in rows["Foo"]:
            self.assertEqual(release["crew"], "")


class UnmatchedInferenceTest(unittest.TestCase):
    @staticmethod
    def release(zip_name, title):
        return {
            "zip": zip_name,
            "title": title,
            "folder": title,
            "cracked_by": "",
            "crew": "",
        }

    def setUp(self):
        self.rows = {
            "Jao": [
                self.release("Game A - Jao.zip", "Game A"),
                self.release("Game B - Jao.zip", "Game B"),
            ],
            "Elite": [
                self.release("Game C - Elite.zip", "Game C"),
                self.release("Game D - Elite.zip", "Game D"),
            ],
        }
        self.aliases = {"Jao": {"Jao"}, "Elite": {"Elite"}}

    def test_unique_group_name_is_high_confidence(self):
        proposals = ca.infer_unmatched_candidates(
            [("A/Arkanoid/a.zip", "A", "Arkanoid",
              "Arkanoid - Tr - Jao Poland.zip", 1)],
            self.rows, self.aliases,
        )
        self.assertEqual(proposals[0]["group"], "Jao")
        self.assertEqual(proposals[0]["confidence"], "high")

    def test_game_title_word_does_not_match_group(self):
        proposals = ca.infer_unmatched_candidates(
            [("E/Elite/e.zip", "E", "Elite v1.01",
              "Elite v1.01 - Cracked.zip", 1)],
            self.rows, self.aliases,
        )
        self.assertEqual(proposals[0]["group"], "")

    def test_two_equally_specific_groups_are_ambiguous(self):
        proposals = ca.infer_unmatched_candidates(
            [("A/Alpha/a.zip", "A", "Alpha", "Alpha - Elite - Jao.zip", 1)],
            self.rows, self.aliases,
        )
        self.assertEqual(proposals[0]["group"], "")
        self.assertEqual(proposals[0]["confidence"], "ambiguous")


class CodeAndNameInferenceTest(unittest.TestCase):
    @staticmethod
    def release(zip_name, title):
        return {
            "zip": zip_name,
            "title": title,
            "folder": title,
            "cracked_by": "",
            "crew": "",
        }

    def setUp(self):
        specs = {
            "D-Bug": ["D-Bug"],
            "Serenade": ["Serenade"],
            "G Force": ["G Force"],
            "FOFT": ["FOFT"],
            "Special FX": ["Special FX", "SFX"],
            "Automation": ["Automation"],
            "Deadeye": ["Deadeye"],
            "Rockyone": ["Rockyone"],
            "Euroconnectors": ["Euroconnectors"],
            "Euroswap": ["Euroswap"],
        }
        self.rows, self.aliases = {}, {}
        for group, aliases in specs.items():
            self.rows[group] = [
                self.release(f"{group} A.zip", f"{group} A"),
                self.release(f"{group} B.zip", f"{group} B"),
            ]
            self.aliases[group] = set(aliases)

    def _proposal(self, folder, name):
        return ca.infer_unmatched_candidates(
            [(f"A/{folder}/x.zip", "A", folder, name, 1)],
            self.rows, self.aliases,
        )[0]

    def test_release_code_prefixes(self):
        cases = {
            "Dragonflight - dbug192a.zip": ("D-Bug", "code:dbug"),
            "Anarchy Academy - SERE17.zip": ("Serenade", "code:sere"),
            "Backgammon - GFOR30.zip": ("G Force", "code:gfor"),
            "Bridge - FOFT11.zip": ("FOFT", "code:foft"),
            "Eaglestar - SFX098.zip": ("Special FX", "code:sfx"),
            "To Be on Top - auto306v3.zip": ("Automation", "code:auto"),
        }
        for name, (group, evidence) in cases.items():
            proposal = self._proposal("Game", name)
            self.assertEqual(proposal["group"], group, name)
            self.assertEqual(proposal["confidence"], "high", name)
            self.assertEqual(proposal["match_type"], "code_prefix", name)
            self.assertEqual(proposal["evidence"], evidence, name)

    def test_compact_contiguous_names(self):
        deadeye = self._proposal("Dark Castle", "Dark Castle - Dead Eye.zip")
        self.assertEqual(deadeye["group"], "Deadeye")
        self.assertEqual(deadeye["match_type"], "compact_name")
        rocky = self._proposal(
            "Cougar Force", "Gougar Force+Loader - Rocky One.zip")
        self.assertEqual(rocky["group"], "Rockyone")
        self.assertEqual(rocky["match_type"], "compact_name")

    def test_ambiguous_code_stays_unmatched(self):
        proposal = self._proposal("Moonlord", "Moonlord - EURO0981.zip")
        self.assertEqual(proposal["group"], "")
        self.assertEqual(proposal["confidence"], "ambiguous")

    def test_novel_tokens_are_kept_for_review(self):
        proposal = self._proposal(
            "Arkanoid 2", "Arkanoid 2 - Revenge of Doh - Sob.zip")
        self.assertEqual(proposal["group"], "")
        self.assertIn("sob", proposal["tokens"])


class GroupNormalizationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = Path(ca.__file__).resolve().parent

    def test_joint_names_use_ampersand(self):
        cases = {
            "Hotline and MCA": "Hotline & MCA",
            "Replicants / Union": "Replicants & Union",
            "Replicants/Union": "Replicants & Union",
            "Banzai + MCA": "Banzai & MCA",
            "Dr Trap / Empire": "Dr Trap & Empire",
            "V8": "V8",
        }
        for value, expected in cases.items():
            self.assertEqual(ca.unify_group_name(value), expected, value)

    def test_joint_overrides_are_loaded(self):
        overrides = ca.load_joint_overrides(
            self.dir / "joint-groups.json")
        self.assertIn("Lethal & Hotline", overrides)
        self.assertIn("Yoda & Arioch", overrides)

    def test_delta_force_and_vmax_merges(self):
        explicit = ca.load_aliases(self.dir / "aliases.json")
        self.assertEqual(
            explicit[ca.norm("Delta Force & Union")], "Delta Force")
        self.assertEqual(explicit[ca.norm("Vmax Impact")], "Vmax")

    def test_non_joint_main_crew_wins_by_strength(self):
        names = {"Delight", "Steve C"}
        strengths = Counter({"Delight": 130, "Steve C": 1})
        delight = ca.candidate_rank(
            "Delight", "alias", 1, 7, names, strengths, set())
        steve = ca.candidate_rank(
            "Steve C", "alias", 1, 7, names, strengths, set())
        self.assertGreater(delight, steve)

    def test_protected_joint_wins_over_main_crew(self):
        names = {"Elite"}
        strengths = Counter({"Elite": 1085})
        joint = ca.candidate_rank(
            "Dr Trap & Empire", "alias", 3, 15, names, strengths, set())
        crew = ca.candidate_rank(
            "Elite", "alias", 1, 5, names, strengths, set())
        self.assertGreater(joint, crew)

    def test_allowlisted_joint_loses_to_crew(self):
        overrides = {"Lethal & Hotline"}
        names = {"Hotline"}
        strengths = Counter({"Hotline": 96})
        joint = ca.candidate_rank(
            "Lethal & Hotline", "alias", 2, 16, names, strengths, overrides)
        crew = ca.candidate_rank(
            "Hotline", "alias", 1, 7, names, strengths, overrides)
        self.assertGreater(crew, joint)

    def test_non_groups_are_excluded(self):
        exclude = ca.load_exclude(self.dir / "exclude.txt")
        raw, _aliases, _abbrev, _labels = ca.build_registry(
            ["Game", "Delight"], {}, ca.load_aliases(self.dir / "aliases.json"),
            exclude)
        self.assertNotIn("Game", raw)
        self.assertIn("Delight", raw)
        for value in ("Game", "Guide", "Me"):
            self.assertIn(ca.norm(value), exclude)


class CrewsSourceSummaryTest(unittest.TestCase):
    def test_is_path_free_and_uses_logical_names(self):
        source = ca.crews_source_summary("/mnt/nas/x/Screenshots/index.json")
        self.assertEqual(
            source,
            {
                "crew_tree": ca.DEFAULT_CREW_TREE,
                "gameinfo": "games-cracked.json",
                "zips": "index.json",
                "crews": "crews.json",
            },
        )
        for value in source.values():
            self.assertFalse(Path(value).is_absolute(), value)
            self.assertNotIn("/mnt/", value)

    def test_full_index_name_is_used(self):
        source = ca.crews_source_summary("/data/gameinfo/full-index.json.gz")
        self.assertEqual(source["zips"], "full-index.json.gz")


if __name__ == "__main__":
    unittest.main()
