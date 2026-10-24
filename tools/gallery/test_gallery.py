# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for the gallery server's filter/card helpers.

Run with the repo venv:
    .venv/bin/python -m unittest discover -s tools/gallery -p 'test_*.py'
"""
import unittest

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


if __name__ == "__main__":
    unittest.main()
