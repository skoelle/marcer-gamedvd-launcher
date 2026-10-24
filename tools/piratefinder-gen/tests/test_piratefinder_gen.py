# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/piratefinder-gen (stdlib unittest)."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import piratefinder_gen as pf

SECTOR = 512


def pack_track(raw: bytes) -> bytes:
    out = bytearray()
    index = 0
    while index < len(raw):
        value = raw[index]
        run = 1
        while index + run < len(raw) and raw[index + run] == value and run < 0xFFFF:
            run += 1
        if run >= 4 or value == pf.MSA_RUN:
            out += bytes((pf.MSA_RUN, value)) + run.to_bytes(2, "big")
        else:
            out += bytes((value,)) * run
        index += run
    return bytes(out)


def build_msa(raw: bytes, sectors: int, sides: int, tracks: int) -> bytes:
    track_size = sectors * SECTOR
    header = (
        pf.MSA_MAGIC
        + sectors.to_bytes(2, "big")
        + (sides - 1).to_bytes(2, "big")
        + (0).to_bytes(2, "big")
        + (tracks - 1).to_bytes(2, "big")
    )
    body = bytearray()
    for track in range(tracks):
        for side in range(sides):
            offset = (track * sides + side) * track_size
            chunk = raw[offset : offset + track_size]
            packed = pack_track(chunk)
            chosen = packed if len(packed) < len(chunk) else chunk
            body += len(chosen).to_bytes(2, "big") + chosen
    return header + bytes(body)


class MSATests(unittest.TestCase):
    def test_roundtrip_with_compressed_and_literal_tracks(self) -> None:
        tracks, sides, sectors = 3, 2, 9
        track_size = sectors * SECTOR
        raw = bytearray(tracks * sides * track_size)
        # Track 0/0: zeros, compresses well.
        # Track 1/1: a byte pattern, stays literal.
        start = (1 * sides + 1) * track_size
        raw[start : start + track_size] = bytes(range(256)) * (track_size // 256)
        archive = build_msa(bytes(raw), sectors, sides, tracks)
        self.assertEqual(pf.decode_msa(archive), bytes(raw))

    def test_trailing_bytes_are_ignored(self) -> None:
        raw = bytes(SECTOR * 9 * 2)
        archive = build_msa(raw, 9, 2, 1)
        self.assertEqual(pf.decode_msa(archive + b"junk"), raw)

    def test_partial_archive_is_zero_filled_before_first_track(self) -> None:
        tracks, sides, sectors = 3, 2, 9
        raw = bytearray(tracks * sides * sectors * SECTOR)
        start_track = 1
        header = (
            pf.MSA_MAGIC
            + sectors.to_bytes(2, "big")
            + (sides - 1).to_bytes(2, "big")
            + start_track.to_bytes(2, "big")
            + (tracks - 1).to_bytes(2, "big")
        )
        body = bytearray()
        for track in range(start_track, tracks):
            for side in range(sides):
                offset = (track * sides + side) * sectors * SECTOR
                body += (sectors * SECTOR).to_bytes(2, "big")
                body += bytes(raw[offset : offset + sectors * SECTOR])
        decoded = pf.decode_msa(header + body)
        self.assertEqual(decoded, bytes(raw))

    def test_truncated_archive_raises(self) -> None:
        archive = build_msa(bytes(SECTOR * 9 * 2), 9, 2, 1)
        with self.assertRaises(pf.MSAError):
            pf.decode_msa(archive[:-1])

    def test_bad_magic_raises(self) -> None:
        with self.assertRaises(pf.MSAError):
            pf.decode_msa(b"not an msa")


class NormalizationTests(unittest.TestCase):
    def test_title_key_strips_article_and_fields(self) -> None:
        self.assertEqual(pf.title_key("Chaos Engine, The (Europe)"), "chaos engine")
        self.assertEqual(pf.title_key("The Chaos Engine [cr Cynix]"), "chaos engine")
        self.assertEqual(pf.title_key("Xenon 2 v1.2"), "xenon 2")
        self.assertEqual(pf.title_key("A-Ha"), "a ha")

    def test_normalize_name(self) -> None:
        self.assertEqual(pf.normalize_name("The Medway Boys"), "medway boys")
        self.assertEqual(pf.normalize_name("MCA & Hotline"), "mca and hotline")
        self.assertEqual(
            pf.normalize_name("International Cracking Service - ICS"),
            "international cracking service ics",
        )

    def test_title_from_zip(self) -> None:
        self.assertEqual(pf.title_from_zip("10th Frame - Pedro.zip"), "10th Frame")


class GroupParsingTests(unittest.TestCase):
    def test_parse_groups(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "groups.toml"
            path.write_text(
                '[[group]]\nname = "SKR"\nplatforms = ["atari-st"]\nabbreviations = ["SKR"]\naliases = ["Skull"]\n',
                encoding="utf-8",
            )
            payload = pf.parse_groups(path)
            self.assertEqual(payload["groups"][0]["name"], "SKR")
            self.assertEqual(payload["groups"][0]["aliases"], ["Skull"])

    def test_platform_is_st(self) -> None:
        self.assertTrue(pf.platform_is_st("atari-st"))
        self.assertTrue(pf.platform_is_st("Atari ST"))
        self.assertFalse(pf.platform_is_st("amiga"))


class TitleFallbackTests(unittest.TestCase):
    def make_matcher(self, disks):
        return pf.Matcher(disks, [], {})

    def disk(self, disk_id, title, cracker="", part="", year=1987):
        return {
            "id": disk_id,
            "kind": "single",
            "title": title,
            "label": title,
            "cracker": cracker,
            "crew": cracker,
            "part": part,
            "year": year,
            "contents": [{"title": title, "kind": "game"}],
        }

    def test_zip_cracker_wins_over_game_variants(self):
        matcher = self.make_matcher(
            [
                self.disk(1, "Arkanoid (1987)(Imagine)[cr Cobra]", "The Cobra"),
                self.disk(2, "Arkanoid (1987)(Imagine)[cr Klapauzius]", "Klapauzius"),
            ]
        )
        game = {"variants": [{"cracked_by": "Cobra"}, {"cracked_by": "Klapauzius"}]}
        disk, reason, candidates = pf.title_fallback(
            matcher, "Arkanoid", game, "Arkanoid - Tr - Cobra.zip"
        )
        self.assertEqual(disk["id"], 1)
        self.assertEqual(reason, "title")
        self.assertEqual(len(candidates), 1)

    def test_prefix_title_and_part_number(self):
        matcher = self.make_matcher(
            [
                self.disk(
                    1, "Ween - The Prophecy (Disk 1 of 3) [cr Cynix]", "Cynix", "1 of 3"
                ),
                self.disk(
                    2, "Ween - The Prophecy (Disk 2 of 3) [cr Cynix]", "Cynix", "2 of 3"
                ),
            ]
        )
        disk, reason, _ = pf.title_fallback(
            matcher, "Ween", None, "Ween - Cynix - Disk 2.zip"
        )
        self.assertEqual(disk["id"], 2)
        self.assertEqual(reason, "title")

    def test_unresolved_title_is_ambiguous(self):
        matcher = self.make_matcher(
            [
                self.disk(1, "Arkanoid (1987)(Imagine)[cr Cobra]", "Cobra"),
                self.disk(2, "Arkanoid (1987)(Imagine)[cr Klapauzius]", "Klapauzius"),
            ]
        )
        disk, reason, candidates = pf.title_fallback(
            matcher, "Arkanoid", None, "Arkanoid - Unknown Cracker.zip"
        )
        self.assertIsNone(disk)
        self.assertEqual(reason, "ambiguous-title")
        self.assertEqual(len(candidates), 2)


if __name__ == "__main__":
    unittest.main()
