# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for the gallery server's filter/card helpers.

Run with the repo venv:
    .venv/bin/python -m unittest discover -s tools/gallery -p 'test_*.py'
"""
import json
import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import gallery


def make_card(**overrides):
    card = {
        "display_status": "desktop",
        "screenshots": True,
        "variants": [],
        "letter": "A",
        "year": "1986",
        "_search": "buggy boy",
        "_publisher": [],
        "_crew": [],
        "_cracker": [],
        "_language": [],
        "_raw": None,
        "_pasti": None,
        "_boxscan": None,
        "_tos": False,
    }
    card.update(overrides)
    return card


class StrictStatusFilterTest(unittest.TestCase):
    def test_desktop_text_matches_a_textscreen_zip_even_with_a_done_zip(self):
        card = make_card(
            display_status="done",
            variants=[
                {"status": "done", "kind": "game"},
                {"status": "desktop", "kind": "textscreen"},
            ],
        )
        self.assertTrue(gallery._matches(
            card, {"status": "desktop_text"}, "cracked"))
        self.assertFalse(gallery._matches(
            card, {"status": "desktop_black"}, "cracked"))

    def test_desktop_black_matches_only_darkscreen(self):
        card = make_card(
            display_status="desktop",
            variants=[{"status": "desktop", "kind": "darkscreen"}],
        )
        self.assertTrue(gallery._matches(
            card, {"status": "desktop_black"}, "cracked"))
        self.assertFalse(gallery._matches(
            card, {"status": "desktop_text"}, "cracked"))

    def test_strict_filters_ignore_a_plain_game_kind(self):
        card = make_card(
            display_status="desktop",
            variants=[{"status": "desktop", "kind": "game"}],
        )
        self.assertFalse(gallery._matches(
            card, {"status": "desktop_text"}, "cracked"))
        self.assertFalse(gallery._matches(
            card, {"status": "desktop_black"}, "cracked"))

    def test_status_labels_include_the_strict_presets(self):
        self.assertEqual(gallery.STATUS_LABELS["desktop_text"],
                         "desktop text")
        self.assertEqual(gallery.STATUS_LABELS["desktop_black"],
                         "desktop black")


class PdTosFilterTest(unittest.TestCase):
    def test_pd_supports_the_tos_filter(self):
        self.assertIn("tos", gallery.kind_filters("pd"))

    def test_pd_tos_has_matches_only_cards_with_a_tos_note(self):
        with_note = make_card(_tos=True)
        without_note = make_card(_tos=False)
        self.assertTrue(gallery._matches(
            with_note, {"status": "any", "tos": "has"}, "pd"))
        self.assertFalse(gallery._matches(
            without_note, {"status": "any", "tos": "has"}, "pd"))


class VariantPayloadTest(unittest.TestCase):
    def test_variant_payload_keeps_kind_for_the_this_zip_table(self):
        rel = "Title Sorted/Cracked Games - Title Sorted/A/Buggy Boy/" \
              "Buggy Boy.zip"
        entries = {
            rel: {
                "status": "desktop",
                "kind": "textscreen",
                "layer": "ROOT",
                "preview": "Buggy Boy.png",
                "candidates": [],
            },
        }
        cards = gallery._build_indexed_cards(entries, [], "cracked", False)
        self.assertEqual(len(cards), 1)
        self.assertEqual(cards[0]["variants"][0]["kind"], "textscreen")

    def test_direct_folder_zip_sorts_before_subfolder_zips(self):
        tree = "Title Sorted/Cracked Games - Title Sorted"
        direct = f"{tree}/A/Alpha/z_direct.zip"
        nested = f"{tree}/A/Alpha/Original/a.zip"
        stx = f"{tree}/A/Alpha/STX/a_stx.zip"
        entries = {
            direct: {"status": "done", "kind": "game"},
            nested: {"status": "done", "kind": "game"},
            stx: {"status": "done", "kind": "game"},
        }
        cards = gallery._build_indexed_cards(entries, [], "cracked", False)
        self.assertEqual(
            [v["name"] for v in cards[0]["variants"]],
            ["z_direct.zip", "a.zip", "a_stx.zip"])


class CardFolderTest(unittest.TestCase):
    def test_indexed_card_folder_rel(self):
        rel = "Title Sorted/Cracked Games - Title Sorted/A/Buggy Boy/" \
              "Buggy Boy.zip"
        entries = {rel: {"status": "done", "kind": "game"}}
        cards = gallery._build_indexed_cards(entries, [], "cracked", False)
        self.assertEqual(
            cards[0]["_folder_rel"],
            "Title Sorted/Cracked Games - Title Sorted/A/Buggy Boy")

    def test_metadata_only_card_uses_section_tree(self):
        card = gallery._simple_card(
            {"letter": "A", "folder": "Alpha", "layers": ["ROOT"]},
            "pd", "Title Sorted/PD Games - Title Sorted")
        self.assertEqual(
            card["_folder_rel"],
            "Title Sorted/PD Games - Title Sorted/A/Alpha")

    def test_magazine_folder_rel_is_the_issue_dir_not_the_first_zip_dir(self):
        rel = "Bonus/Magazine Cover Disks/ST Computer/1990-01/Disk1/st.zip"
        entries = {rel: {"status": "done", "kind": "game"}}
        cards = gallery._build_indexed_cards(
            entries, [], "magazine", False)
        self.assertEqual(
            cards[0]["_folder_rel"],
            "Bonus/Magazine Cover Disks/ST Computer/1990-01")

    def test_flat_magazine_folder_rel_uses_the_magazine_folder(self):
        rel = "Bonus/Magazine Cover Disks/ST Action/ST Action 17 - Disk 1.zip"
        entries = {rel: {"status": "done", "kind": "game"}}
        cards = gallery._build_indexed_cards(
            entries, [], "magazine", False)
        self.assertEqual(
            cards[0]["_folder_rel"],
            "Bonus/Magazine Cover Disks/ST Action")


class LocalAssetsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "root")
        self.patch = os.path.join(self.tmp.name, "patch")
        self.folder = os.path.join(
            "Title Sorted", "Cracked Games - Title Sorted", "A", "Buggy Boy")
        for base in (self.root, self.patch):
            os.makedirs(base, exist_ok=True)
        self.root_game = os.path.join(self.root, self.folder)
        self.patch_game = os.path.join(self.patch, self.folder)

    def tearDown(self):
        self.tmp.cleanup()

    def _write(self, base, rel, data=b"x"):
        path = os.path.join(base, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)

    def _zip(self, base, rel, members):
        path = os.path.join(base, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with zipfile.ZipFile(path, "w") as zf:
            for name in members:
                zf.writestr(name, b"x")

    def test_boxscan_metadata_merges_loose_and_zip_images(self):
        self._write(self.root_game, "Boxscan/loose1.jpg")
        self._write(self.root_game, "Boxscan/Edition/loose2.png")
        self._write(self.patch_game, "Boxscan/loose1.jpg")
        self._write(self.patch_game, "Boxscan/patch.png")
        self._zip(self.root_game, "Boxscan/Edition Zip.zip", [
            "img1.jpg", "folder/img2.png", "readme.txt"])
        service = gallery.LocalAssetsService(
            self.root, self.patch, cache_seconds=0)
        assets = service.discover(self.folder)
        box = assets["boxscans"]
        self.assertEqual(box["edition_count"], 3)
        self.assertEqual(box["image_count"], 5)
        editions = {e["label"]: e["image_count"] for e in box["editions"]}
        self.assertEqual(editions["Boxscan"], 2)
        self.assertEqual(editions["Edition"], 1)
        self.assertEqual(editions["Edition Zip"], 2)

    def test_manual_metadata_groups_variants_and_skips_unknown(self):
        self._zip(self.root_game, "Manual/Alien Syndrome.zip",
                  ["Alien Syndrome.pdf"])
        self._zip(self.root_game, "Manual/Alien Syndrome_text.zip",
                  ["Alien Syndrome_text.pdf"])
        self._write(self.root_game, "Manual/Loose.pdf")
        self._zip(self.root_game, "manual/Docs.zip", [
            "readme.txt", "manual.doc", "page1.jpg", "page2.jpg",
            "disk.msa", "unknown.rar"])
        self._write(self.patch_game, "Manuals/Patch.pdf")
        service = gallery.LocalAssetsService(
            self.root, self.patch, cache_seconds=0)
        assets = service.discover(self.folder)
        manuals = assets["manuals"]
        self.assertEqual(manuals["title_count"], 4)
        self.assertEqual(manuals["file_count"], 9)
        items = {item["label"]: item for item in manuals["items"]}
        alien = {v["label"]: v for v in items["Alien Syndrome"]["variants"]}
        self.assertEqual(alien["Scan"]["format"], "PDF")
        self.assertEqual(alien["Text"]["format"], "PDF")
        docs = {v["label"]: v for v in items["Docs"]["variants"]}
        self.assertEqual(docs["Document"]["file_count"], 2)
        self.assertEqual(docs["Image pages"]["file_count"], 2)
        self.assertEqual(docs["Original disk"]["format"], "MSA")
        self.assertEqual(docs["Original disk"]["file_count"], 1)

    def test_manual_image_pages_and_msa_are_metadata_only(self):
        self._zip(self.root_game, "Manual/Pics.zip", [
            "one.jpg", "two.png", "disk.msa", "notes.txt"])
        service = gallery.LocalAssetsService(self.root, "", cache_seconds=0)
        assets = service.discover(self.folder)
        item = assets["manuals"]["items"][0]
        variants = {v["label"]: v for v in item["variants"]}
        self.assertEqual(variants["Image pages"]["file_count"], 2)
        self.assertEqual(variants["Original disk"]["kind"], "diskImage")
        self.assertEqual(variants["Document"]["format"], "TXT")

    def test_discovery_never_opens_zip_members(self):
        self._zip(self.root_game, "Manual/Test.zip", ["Test.pdf"])
        service = gallery.LocalAssetsService(self.root, "", cache_seconds=0)
        with mock.patch.object(
                zipfile.ZipFile, "open",
                side_effect=AssertionError("zip member opened")):
            assets = service.discover(self.folder)
        self.assertEqual(assets["manuals"]["title_count"], 1)

    def test_no_root_returns_empty_metadata(self):
        service = gallery.LocalAssetsService("", "", cache_seconds=0)
        self.assertFalse(service.enabled)
        assets = service.discover(self.folder)
        self.assertEqual(assets["boxscans"]["edition_count"], 0)
        self.assertEqual(assets["manuals"]["title_count"], 0)

    def test_missing_assets_returns_empty_metadata(self):
        service = gallery.LocalAssetsService(self.root, "", cache_seconds=0)
        assets = service.discover(self.folder)
        self.assertFalse(assets["boxscans"]["editions"])
        self.assertFalse(assets["manuals"]["items"])


class CrewDataTest(unittest.TestCase):
    tree = "Title Sorted/Cracked Games - Title Sorted"
    rel_a = f"{tree}/A/Alpha/a.zip"
    rel_a2 = f"{tree}/A/Alpha/a_v2.zip"
    rel_b = f"{tree}/B/Beta/b.zip"

    def _write_json(self, path, data):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data), encoding="utf-8")

    def _store(self, groups, cracked_variants=None, clusters=None):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        out = os.path.join(self.tmp.name, "out")
        data_root = os.path.join(self.tmp.name, "data")
        data = os.path.join(data_root, "gameinfo")
        os.makedirs(out)
        os.makedirs(data)
        index = {
            self.rel_a: {
                "status": "done", "kind": "game", "layer": "ROOT",
                "preview": "a.png", "candidates": [],
            },
            self.rel_a2: {
                "status": "done", "kind": "game", "layer": "ROOT",
                "preview": None, "candidates": [],
            },
            self.rel_b: {
                "status": "done", "kind": "game", "layer": "ROOT",
                "preview": "b.png", "candidates": [],
            },
        }
        self._write_json(os.path.join(out, "index.json"),
                         {"version": 1, "entries": index})
        self._write_json(os.path.join(data, "games-cracked.json"), {
            "games": [
                {"letter": "A", "folder": "Alpha", "layers": ["ROOT"],
                 "variants": cracked_variants or [
                     {"title": "Alpha", "release": "1990"},
                 ]},
                {"letter": "B", "folder": "Beta", "layers": ["ROOT"],
                 "variants": [{"title": "Beta", "release": "1991"}]},
            ],
        })
        for name in ("games-pd.json", "games-utils.json"):
            self._write_json(os.path.join(data, name), {"games": []})
        self._write_json(os.path.join(data, "manifest.json"), {"sources": []})
        self._write_json(os.path.join(data, "crews.json"), {
            "schema": 1,
            "generated_at": "2026-10-24T00:00:00Z",
            "groups": groups,
        })
        curated = os.path.join(out, self.rel_a.rsplit("/", 1)[0],
                               "curated.png")
        os.makedirs(os.path.dirname(curated), exist_ok=True)
        with open(curated, "wb") as f:
            f.write(b"x")
        self._write_json(os.path.join(data, "crew-images.json"), {
            "schema": 1,
            "images": {
                "Alpha Crew": {
                    "rel": self.rel_a, "name": "curated.png",
                    "source": "manual",
                },
            },
        })
        if clusters is not None:
            self._write_json(os.path.join(data, "crew-cluster.json"), clusters)
        return gallery.DataStore(out, data_root)

    @staticmethod
    def _group(group_id, name, kind, zips, releases, excluded=False):
        return {
            "id": group_id, "name": name, "kind": kind, "rank": 1,
            "zips": zips, "excluded": excluded, "aliases": [name],
            "releases": releases,
        }

    def test_loads_all_groups_search_and_previews(self):
        groups = [
            self._group("alpha-crew", "Alpha Crew", "crew", 2, [
                {"rel": self.rel_a, "zip": "a.zip", "title": "Alpha",
                 "year": "1990"},
                {"rel": self.rel_a2, "zip": "a_v2.zip", "title": "Alpha v2",
                 "year": "1991"},
            ]),
            self._group("beta-crackers", "Beta Crackers", "cracker", 1, [
                {"rel": self.rel_b, "zip": "b.zip", "title": "Beta",
                 "year": "1991"},
            ]),
            self._group("hidden", "Hidden", "crew", 0, [], excluded=True),
        ]
        store = self._store(groups)
        self.assertEqual(len(store.crews), 3)
        self.assertIn("hidden", store.crew_groups)
        self.assertEqual(store.crews[0]["name"], "Alpha Crew")
        self.assertEqual(store.crews[0]["preview"],
                         f"{self.tree}/A/Alpha/curated.png")
        self.assertEqual(store.crews[1]["preview"],
                         f"{self.tree}/B/Beta/b.png")
        self.assertEqual(store.crews[2]["name"], "Hidden")
        self.assertTrue(store.crews[0]["top"])
        self.assertFalse(store.crews[2]["top"])
        self.assertFalse(gallery._public_crew_card(store.crews[2])["top"])
        self.assertIn("beta crackers", store.crews[1]["_search"])
        self.assertEqual(store.meta["crews"]["groups"], 3)
        self.assertEqual(store.meta["crews"]["visible_groups"], 3)
        self.assertEqual(store.meta["crews"]["kinds"],
                         {"crew": 2, "cracker": 1})
        self.assertEqual(store.meta["crews"]["releases"], 3)
        self.assertEqual(store.meta["sections"]["crew"]["cards"], 3)

    def test_excluded_group_detail_is_accessible(self):
        store = self._store([
            self._group("hidden", "Hidden", "crew", 1, [
                {"rel": self.rel_a, "zip": "a.zip", "title": "Alpha",
                 "year": "1990"},
            ], excluded=True),
        ])
        group = store.crew_groups["hidden"]
        detail = store.crew_detail(group)
        self.assertEqual(len(detail["releases"]), 1)
        self.assertEqual(detail["releases"][0]["preview"],
                         f"{self.tree}/A/Alpha/a.png")

    def test_crew_detail_joins_release_preview_and_legacy_rel(self):
        store = self._store([
            self._group("alpha-crew", "Alpha Crew", "crew", 2, [
                {"rel": self.rel_a, "zip": "a.zip", "title": "Alpha",
                 "year": "1990"},
                {"rel": "A/Alpha/a_v2.zip", "zip": "a_v2.zip",
                 "title": "Alpha v2", "year": "1991"},
            ]),
        ])
        group = store.crew_groups["alpha-crew"]
        detail = store.crew_detail(group)
        self.assertEqual(len(detail["releases"]), 2)
        first = detail["releases"][0]
        self.assertEqual(first["preview"],
                         f"{self.tree}/A/Alpha/a.png")
        self.assertEqual(first["status"], "done")
        self.assertEqual(first["kind"], "game")
        legacy = detail["releases"][1]
        self.assertEqual(legacy["index_rel"], self.rel_a2)
        self.assertIsNone(legacy["preview"])

    def test_gameinfo_placeholders_are_removed_everywhere(self):
        store = self._store([], cracked_variants=[
            {"title": "Alpha", "cracked_by": "Original"},
            {"title": "Alpha", "cracked_by": "Unknown", "crew": "Unknown"},
            {"title": "Alpha", "cracked_by": "Cameo", "crew": "Replicants"},
        ])
        card = next(c for c in store.cards["cracked"]
                    if c["letter"] == "A" and c["folder"] == "Alpha")
        self.assertEqual(card["info"]["variants"][0]["cracked_by"], "")
        self.assertEqual(card["info"]["variants"][1]["cracked_by"], "")
        self.assertEqual(card["info"]["variants"][1]["crew"], "")
        self.assertEqual(card["info"]["variants"][2]["cracked_by"], "Cameo")
        self.assertNotIn("original", card["_search"])
        self.assertNotIn("Unknown", store.facets["cracked"]["crackers"])
        self.assertNotIn("Unknown", store.facets["cracked"]["crews"])

    def test_release_labels_are_attached_to_cards(self):
        store = self._store([
            self._group("alpha-crew", "Alpha Crew", "crew", 1, [
                {"rel": self.rel_a, "zip": "a.zip", "title": "Alpha",
                 "cracked_by": "Cameo", "crew": "Replicants",
                 "inferred_fields": ["crew"]},
            ]),
        ], cracked_variants=[{"title": "Alpha", "release": "1990"}])
        card = next(c for c in store.cards["cracked"]
                    if c["letter"] == "A" and c["folder"] == "Alpha")
        self.assertEqual(
            card["release_labels"][self.rel_a]["crew"], "Replicants")
        self.assertEqual(
            card["release_labels"][self.rel_a]["inferred_fields"], ["crew"])
        public = gallery._public_card(card, "cracked")
        self.assertIn("release_labels", public)
        detail = store.crew_detail(store.crew_groups["alpha-crew"])
        self.assertEqual(detail["releases"][0]["inferred_fields"], ["crew"])

    def test_all_groups_without_limit(self):
        groups = [
            self._group(f"crew-{i}", f"Crew {i:03d}", "crew", 1000 - i, [])
            for i in range(130)
        ]
        store = self._store(groups)
        self.assertEqual(len(store.crews), 130)
        self.assertEqual(store.meta["crews"]["groups"], 130)
        self.assertEqual(store.meta["crews"]["visible_groups"], 130)
        self.assertEqual(store.meta["sections"]["crew"]["cards"], 130)

    def test_kind_filter_applies_before_pagination(self):
        groups = [
            self._group("alpha-crew", "Alpha Crew", "crew", 2, []),
            self._group("beta-cracker", "Beta Cracker", "cracker", 1, []),
        ]
        store = self._store(groups)

        def fetch(kind):
            handler = object.__new__(gallery.GalleryHandler)
            query = "limit=1"
            if kind:
                query += f"&kind={kind}"
            handler.path = "/api/crews?" + query
            handler.store = store
            handler.cfg = {"page_size": 60}
            out = {}
            handler._json = lambda obj, status=200: out.update(obj)
            handler._error = lambda status, message: out.update(error=message)
            handler._crews()
            return out

        self.assertEqual(fetch("crew")["total"], 1)
        self.assertEqual(fetch("crew")["kinds"],
                         {"crew": 1, "cracker": 0})
        self.assertEqual([c["name"] for c in fetch("crew")["cards"]],
                         ["Alpha Crew"])
        self.assertEqual(fetch("cracker")["total"], 1)
        self.assertEqual(fetch("cracker")["kinds"],
                         {"crew": 0, "cracker": 1})
        self.assertEqual([c["name"] for c in fetch("cracker")["cards"]],
                         ["Beta Cracker"])
        # unknown/empty kind means "any" and still paginates; the kinds
        # breakdown covers all matches, not just the current page
        self.assertEqual(fetch("")["total"], 2)
        self.assertEqual(fetch("")["kinds"],
                         {"crew": 1, "cracker": 1})
        self.assertEqual(fetch("nope")["total"], 2)
        self.assertEqual(fetch("nope")["kinds"],
                         {"crew": 1, "cracker": 1})
        self.assertEqual(len(fetch("")["cards"]), 1)

    def test_top_filter_applies_before_pagination(self):
        groups = [
            self._group("alpha-crew", "Alpha Crew", "crew", 3, []),
            self._group("beta-crew", "Beta Crew", "crew", 2, []),
            self._group("hidden", "Hidden", "crew", 1, [], excluded=True),
        ]
        store = self._store(groups)

        def fetch(top):
            handler = object.__new__(gallery.GalleryHandler)
            query = "limit=1"
            if top:
                query += f"&top={top}"
            handler.path = "/api/crews?" + query
            handler.store = store
            handler.cfg = {"page_size": 60}
            out = {}
            handler._json = lambda obj, status=200: out.update(obj)
            handler._error = lambda status, message: out.update(error=message)
            handler._crews()
            return out

        self.assertEqual(fetch("only")["total"], 2)
        self.assertEqual(fetch("only")["kinds"], {"crew": 2, "cracker": 0})
        self.assertEqual([c["name"] for c in fetch("only")["cards"]],
                         ["Alpha Crew"])
        self.assertEqual(fetch("none")["total"], 1)
        self.assertEqual(fetch("none")["kinds"], {"crew": 1, "cracker": 0})
        self.assertEqual([c["name"] for c in fetch("none")["cards"]],
                         ["Hidden"])
        # unknown/empty top means "any" and still paginates
        for value in ("", "nope"):
            self.assertEqual(fetch(value)["total"], 3)
            self.assertEqual(fetch(value)["kinds"],
                             {"crew": 3, "cracker": 0})
            self.assertEqual(len(fetch(value)["cards"]), 1)
        self.assertEqual(
            [c["name"] for c in gallery.filter_crew_cards(
                store.crews, top="only")],
            ["Alpha Crew", "Beta Crew"])


    def test_loads_cluster_file_and_joins_root_preview(self):
        groups = [
            self._group("alpha-crew", "Alpha Crew", "crew", 2, [
                {"rel": self.rel_a, "zip": "a.zip", "title": "Alpha",
                 "year": "1990"},
            ]),
            self._group("hidden", "Hidden", "crew", 0, [], excluded=True),
        ]
        clusters = {
            "schema": 1,
            "generated_at": "2026-10-30T00:00:00Z",
            "clusters": [{
                "id": "alpha",
                "name": "Alpha Cluster",
                "roots": [{"name": "Alpha Crew"}],
                "counts": {"groups": 3, "top": 1, "excluded": 1,
                           "ambiguous": 0, "external": 1},
                "groups": [
                    {"name": "Alpha Crew", "local_id": "alpha-crew",
                     "status": "top", "zips": 2, "clusters": ["alpha"]},
                    {"name": "Hidden", "local_id": "hidden",
                     "status": "excluded", "zips": 0,
                     "clusters": ["alpha", "other"]},
                    {"name": "External Group", "status": "external",
                     "clusters": ["alpha"]},
                ],
            }],
            "edges": [{
                "from": "Hidden", "to": "Alpha Crew",
                "type": "subgroup_of", "current": False,
                "clusters": ["alpha", "other"],
                "cross_cluster": True,
            }],
            "trees": {
                "alpha": {
                    "name": "Alpha Crew", "local_id": "alpha-crew",
                    "status": "top", "children": [{
                        "name": "Hidden", "local_id": "hidden",
                        "status": "excluded",
                    }, {
                        "name": "External Group", "status": "external",
                    }],
                },
            },
        }
        store = self._store(groups, clusters=clusters)

        self.assertEqual(len(store.clusters), 1)
        summary = store.clusters[0]
        self.assertEqual(summary["id"], "alpha")
        self.assertEqual(summary["groups"], 3)
        self.assertEqual(summary["cross_edges"], 1)
        self.assertEqual(summary["preview"],
                         f"{self.tree}/A/Alpha/curated.png")
        self.assertEqual(store.meta["clusters"]["available"], True)
        self.assertEqual(store.meta["clusters"]["count"], 1)
        self.assertEqual(store.meta["clusters"]["groups"], 3)
        self.assertEqual(store.meta["clusters"]["edges"], 1)
        self.assertEqual(store.meta["clusters"]["cross_edges"], 1)
        self.assertEqual(store.meta["sections"]["cluster"]["cards"], 1)
        cluster = store.cluster_by_id["alpha"]
        self.assertEqual(cluster["tree"]["name"], "Alpha Crew")
        self.assertEqual(cluster["tree"]["preview"],
                         f"{self.tree}/A/Alpha/curated.png")
        self.assertIsNone(cluster["tree"]["children"][0]["preview"])
        self.assertIsNone(cluster["tree"]["children"][1]["preview"])
        groups_by_name = {g["name"]: g for g in cluster["groups"]}
        self.assertEqual(groups_by_name["Alpha Crew"]["preview"],
                         f"{self.tree}/A/Alpha/curated.png")
        self.assertIsNone(groups_by_name["Hidden"]["preview"])
        self.assertIsNone(groups_by_name["External Group"]["preview"])
        self.assertEqual(cluster["overlaps"][0]["name"], "Hidden")
        self.assertEqual(cluster["overlaps"][0]["clusters"],
                         ["alpha", "other"])

    def test_missing_cluster_file_keeps_gallery_available(self):
        store = self._store([])
        self.assertFalse(store.meta["clusters"]["available"])
        self.assertEqual(store.meta["clusters"]["count"], 0)
        self.assertIn("crew-cluster.json not found",
                      store.meta["clusters"]["error"])
        self.assertEqual(store.meta["sections"]["cluster"]["cards"], 0)

    def test_external_cluster_root_uses_first_local_descendant_preview(self):
        groups = [
            self._group("alpha-crew", "Alpha Crew", "crew", 1, [
                {"rel": self.rel_a, "zip": "a.zip", "title": "Alpha"},
            ]),
        ]
        clusters = {
            "schema": 1,
            "generated_at": "2026-10-30T00:00:00Z",
            "clusters": [{
                "id": "external-root",
                "name": "External Root",
                "roots": [{"name": "External Root"}],
                "counts": {"groups": 2, "top": 1, "external": 1},
                "groups": [
                    {"name": "External Root", "status": "external",
                     "clusters": ["external-root"]},
                    {"name": "Alpha Crew", "local_id": "alpha-crew",
                     "status": "top", "clusters": ["external-root"]},
                ],
            }],
            "edges": [{
                "from": "Alpha Crew", "to": "External Root",
                "type": "subgroup_of", "current": False,
                "clusters": ["external-root"], "cross_cluster": False,
            }],
            "trees": {
                "external-root": {
                    "name": "External Root", "status": "external",
                    "children": [{
                        "name": "Alpha Crew", "local_id": "alpha-crew",
                        "status": "top",
                    }],
                },
            },
        }
        store = self._store(groups, clusters=clusters)
        summary = store.clusters[0]
        self.assertIsNone(store.cluster_by_id["external-root"]["tree"].get("preview"))
        self.assertEqual(summary["preview"], f"{self.tree}/A/Alpha/curated.png")
        self.assertEqual(
            store.cluster_by_id["external-root"]["tree"]["children"][0]["preview"],
            f"{self.tree}/A/Alpha/curated.png")

    def test_invalid_cluster_file_has_clean_error(self):
        store = self._store([])
        path = Path(self.tmp.name) / "data" / "gameinfo" / "crew-cluster.json"
        path.write_text("{not json", encoding="utf-8")
        store.reload(force=True)
        self.assertFalse(store.meta["clusters"]["available"])
        self.assertIn("crew-cluster.json:", store.meta["clusters"]["error"])

    def test_cluster_api_list_detail_and_missing_id(self):
        groups = [
            self._group("alpha-crew", "Alpha Crew", "crew", 1, [
                {"rel": self.rel_a, "zip": "a.zip", "title": "Alpha"},
            ]),
        ]
        clusters = {
            "schema": 1,
            "generated_at": "2026-10-30T00:00:00Z",
            "clusters": [{
                "id": "alpha", "name": "Alpha Cluster",
                "roots": [{"name": "Alpha Crew"}],
                "counts": {"groups": 1, "top": 1},
                "groups": [{"name": "Alpha Crew",
                            "local_id": "alpha-crew", "status": "top"}],
                "edges": [],
            }],
            "trees": {"alpha": {"name": "Alpha Crew",
                                "local_id": "alpha-crew", "status": "top"}},
        }
        store = self._store(groups, clusters=clusters)

        def fetch(query=""):
            handler = object.__new__(gallery.GalleryHandler)
            handler.path = "/api/clusters" + query
            handler.store = store
            handler.cfg = {"page_size": 60}
            out = {}
            handler._json = lambda obj, status=200: out.update(obj)
            handler._error = lambda status, message: out.update(error=message)
            handler._clusters()
            return out

        listing = fetch()
        self.assertEqual(listing["total"], 1)
        self.assertEqual(listing["clusters"][0]["name"], "Alpha Cluster")
        detail = fetch("?id=alpha")
        self.assertEqual(detail["name"], "Alpha Cluster")
        self.assertEqual(detail["tree"]["name"], "Alpha Crew")
        self.assertEqual(detail["tree"]["preview"],
                         f"{self.tree}/A/Alpha/curated.png")
        self.assertEqual(detail["groups"][0]["preview"],
                         f"{self.tree}/A/Alpha/curated.png")
        self.assertEqual(detail["generated_at"], "2026-10-30T00:00:00Z")
        self.assertEqual(fetch("?id=nope")["error"], "cluster not found")


class DataDirPathTest(unittest.TestCase):
    """Gameinfo data is read only from <MARCER_DATA_DIR>/gameinfo (no fallback)."""

    def _store(self, layout):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        out = Path(tmp.name) / "out"
        data_root = Path(tmp.name) / "data"
        out.mkdir()
        data_root.mkdir()
        target = data_root / "gameinfo" if layout == "subdir" else data_root
        target.mkdir(exist_ok=True)
        (out / "index.json").write_text(
            json.dumps({"version": 1, "entries": {}}), encoding="utf-8")
        (target / "games-cracked.json").write_text(
            json.dumps({"games": []}), encoding="utf-8")
        return gallery.DataStore(str(out), str(data_root))

    def test_reads_gameinfo_subdir(self):
        store = self._store("subdir")
        self.assertIsNotNone(store.data)
        self.assertTrue(store.gameinfo_available)

    def test_root_layout_is_ignored(self):
        store = self._store("root")
        self.assertIsNone(store.data)
        self.assertFalse(store.gameinfo_available)


if __name__ == "__main__":
    unittest.main()
