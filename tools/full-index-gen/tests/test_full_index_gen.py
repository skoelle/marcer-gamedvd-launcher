# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/full-index-gen (stdlib unittest)."""

from __future__ import annotations

import gzip
import json
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import full_index_gen as fig  # noqa: E402
from _lib import catalog_sections as cs  # noqa: E402
from _lib import zip_hashes  # noqa: E402

CRACKED = "Title Sorted/Cracked Games - Title Sorted"


def pack_track(raw: bytes) -> bytes:
    out = bytearray()
    index = 0
    while index < len(raw):
        value = raw[index]
        run = 1
        while (
            index + run < len(raw)
            and raw[index + run] == value
            and run < 0xFFFF
        ):
            run += 1
        if run >= 4 or value == 0xE5:
            out.extend([0xE5, value, (run >> 8) & 0xFF, run & 0xFF])
        else:
            out.extend(bytes([value]) * run)
        index += run
    return bytes(out)


def build_msa(raw: bytes, sectors: int, sides: int, tracks: int) -> bytes:
    track_size = sectors * 512
    header = bytes([
        0x0E, 0x0F,
        (sectors >> 8) & 0xFF, sectors & 0xFF,
        0, sides - 1,
        0, 0,
        (tracks - 1) >> 8, (tracks - 1) & 0xFF,
    ])
    body = bytearray()
    for track in range(tracks):
        for side in range(sides):
            offset = (track * sides + side) * track_size
            chunk = raw[offset:offset + track_size]
            packed = pack_track(chunk)
            chosen = packed if len(packed) < len(chunk) else chunk
            body.extend([(len(chosen) >> 8) & 0xFF, len(chosen) & 0xFF])
            body.extend(chosen)
    return header + bytes(body)


def raw_image(seed: int) -> bytes:
    raw = bytearray(9 * 512)
    raw[0] = seed & 0xFF
    raw[1] = (seed >> 8) & 0xFF
    return bytes(raw)


def write_zip(path: Path, members: dict[str, bytes]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in members.items():
            archive.writestr(name, data)


class ZipHashTests(unittest.TestCase):
    def test_decode_msa_roundtrip(self) -> None:
        raw = raw_image(7)
        msa = build_msa(raw, 9, 1, 1)
        self.assertEqual(zip_hashes.decode_msa(msa), raw)

    def test_zip_members_hashes_and_fingerprint(self) -> None:
        raw = raw_image(3)
        msa = build_msa(raw, 9, 1, 1)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "game.zip"
            write_zip(path, {"game.msa": msa, "game.st": raw, "readme.txt": b"x"})
            members, error = zip_hashes.zip_members(path)
        self.assertEqual(error, "")
        self.assertEqual(len(members), 2)
        names = {member["name"] for member in members}
        self.assertEqual(names, {"game.msa", "game.st"})
        by_name = {member["name"]: member for member in members}
        self.assertEqual(by_name["game.msa"]["raw"]["sha1"], by_name["game.st"]["raw"]["sha1"])
        self.assertEqual(by_name["game.msa"]["file"]["size"], len(msa))
        self.assertTrue(zip_hashes.fingerprint(members))


class SectionTests(unittest.TestCase):
    def test_canonical_merge_case_and_layer(self) -> None:
        root = {
            "T/A/Game/Game.zip": {"size": 1, "mtime": 1},
            "T/A/Game/Root Only.zip": {"size": 2, "mtime": 1},
        }
        patch = {
            "T/A/GAME/Game.zip": {"size": 3, "mtime": 2},
        }
        merged = cs.canonical_merge(root, patch)
        self.assertIn("T/A/GAME/Game.zip", merged)
        self.assertEqual(merged["T/A/GAME/Game.zip"]["layer"], "BOTH")
        self.assertEqual(merged["T/A/GAME/Game.zip"]["src_layer"], "PATCH")
        self.assertIn("T/A/GAME/Root Only.zip", merged)
        self.assertEqual(merged["T/A/GAME/Root Only.zip"]["layer"], "ROOT")
        self.assertEqual(merged["T/A/GAME/Root Only.zip"]["src_rel"], "T/A/Game/Root Only.zip")

    def test_scan_skips_excluded_dirs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            write_zip(base / "T" / "A" / "Game" / "Game.zip", {"x.st": b"1"})
            write_zip(base / "T" / "Boxscan" / "Cover.zip", {"x.st": b"1"})
            found = cs.scan_tree(base, "T", exclude={"boxscan"})
        self.assertEqual(list(found), ["T/A/Game/Game.zip"])


class FullIndexTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.root = base / "root"
        self.patch = base / "patch"
        self.data = base / "data"
        self.out = self.data / "gameinfo" / fig.FILE_NAME
        write_zip(
            self.root / CRACKED / "A" / "Alpha" / "Alpha - Crew.zip",
            {"alpha.msa": build_msa(raw_image(1), 9, 1, 1)},
        )
        write_zip(
            self.root / CRACKED / "A" / "Alpha" / "Alpha - Crew - Disk 2.zip",
            {"alpha2.st": raw_image(2)},
        )
        write_zip(
            self.root / CRACKED / "B" / "Beta" / "Beta.zip",
            {"beta.st": raw_image(3)},
        )
        write_zip(
            self.patch / CRACKED / "A" / "Alpha" / "Alpha - Crew.zip",
            {"alpha.msa": build_msa(raw_image(9), 9, 1, 1)},
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_tool(self, *extra: str) -> int:
        return fig.main([
            "run",
            "--root", str(self.root),
            "--patch", str(self.patch),
            "--out", str(self.out),
            "--scope", "cracked",
            *extra,
        ])

    def load(self) -> dict:
        with gzip.open(self.out, "rt", encoding="utf-8") as handle:
            return json.load(handle)

    def write_inventory(self, files: dict, name: str = "inventory.json.gz") -> Path:
        path = Path(self.tmp.name) / name
        payload = {
            "schema": 1,
            "tool": "archive-sync",
            "complete": True,
            "remote": "/GameDVD/",
            "generated_at": "2026-11-05T00:00:00Z",
            "files": files,
        }
        with gzip.open(path, "wt", encoding="utf-8") as handle:
            json.dump(payload, handle)
        return path

    def test_run_writes_layer_hashes_and_section(self) -> None:
        self.assertEqual(self.run_tool(), 0)
        data = self.load()
        entries = data["entries"]
        alpha = f"{CRACKED}/A/Alpha/Alpha - Crew.zip"
        self.assertEqual(entries[alpha]["layer"], "BOTH")
        self.assertEqual(entries[alpha]["section"], "cracked")
        self.assertEqual(len(entries[alpha]["members"]), 1)
        self.assertTrue(entries[alpha]["members"][0]["raw"]["sha1"])
        self.assertTrue(entries[alpha]["fingerprint"])
        disk2 = f"{CRACKED}/A/Alpha/Alpha - Crew - Disk 2.zip"
        self.assertEqual(entries[disk2]["layer"], "ROOT")
        self.assertEqual(data["counts"]["zips"], 3)

    def test_incremental_reuses_and_is_deterministic(self) -> None:
        self.assertEqual(self.run_tool(), 0)
        first = self.out.read_bytes()
        calls = []
        real = zip_hashes.zip_members

        def counting(path):
            calls.append(path)
            return real(path)

        zip_hashes.zip_members = counting
        try:
            self.assertEqual(self.run_tool(), 0)
        finally:
            zip_hashes.zip_members = real
        second = self.out.read_bytes()
        self.assertEqual(first, second)
        self.assertEqual(calls, [])

    def test_ftp_status_from_inventory(self) -> None:
        write_zip(
            self.patch / CRACKED / "Z" / "Zeta" / "Zeta.zip",
            {"zeta.st": raw_image(5)},
        )
        alpha = f"{CRACKED}/A/Alpha/Alpha - Crew.zip"
        disk2 = f"{CRACKED}/A/Alpha/Alpha - Crew - Disk 2.zip"
        beta = f"{CRACKED}/B/Beta/Beta.zip"
        zeta = f"{CRACKED}/Z/Zeta/Zeta.zip"
        inventory = self.write_inventory(
            {alpha: {"size": 1, "mtime": None}}
        )
        self.assertEqual(
            self.run_tool("--ftp-inventory", str(inventory)), 0
        )
        data = self.load()
        entries = data["entries"]
        self.assertEqual(entries[alpha]["ftp_status"], "on_ftp")
        self.assertEqual(entries[disk2]["ftp_status"], "physical_dvd")
        self.assertEqual(entries[beta]["ftp_status"], "physical_dvd")
        self.assertEqual(entries[zeta]["ftp_status"], "ftp_deleted")
        self.assertEqual(data["counts"]["ftp_on"], 1)
        self.assertEqual(data["counts"]["ftp_physical_dvd"], 2)
        self.assertEqual(data["counts"]["ftp_deleted"], 1)
        self.assertEqual(data["counts"]["ftp_unknown"], 0)
        self.assertEqual(data["schema"], 2)

    def test_ftp_status_inventory_is_case_insensitive(self) -> None:
        alpha = f"{CRACKED}/A/Alpha/Alpha - Crew.zip"
        inventory = self.write_inventory(
            {alpha.upper(): {"size": 1, "mtime": None}}
        )
        self.assertEqual(self.run_tool("--ftp-inventory", str(inventory)), 0)
        entries = self.load()["entries"]
        self.assertEqual(entries[alpha]["ftp_status"], "on_ftp")

    def test_ftp_status_is_preserved_without_inventory(self) -> None:
        alpha = f"{CRACKED}/A/Alpha/Alpha - Crew.zip"
        inventory = self.write_inventory(
            {alpha: {"size": 1, "mtime": None}}
        )
        self.assertEqual(self.run_tool("--ftp-inventory", str(inventory)), 0)
        first = {
            rel: value.get("ftp_status")
            for rel, value in self.load()["entries"].items()
        }
        missing = Path(self.tmp.name) / "does-not-exist.json.gz"
        self.assertEqual(self.run_tool("--ftp-inventory", str(missing)), 0)
        second = {
            rel: value.get("ftp_status")
            for rel, value in self.load()["entries"].items()
        }
        self.assertEqual(first, second)
        empty = self.write_inventory({}, name="keep.json.gz")
        self.assertEqual(
            self.run_tool(
                "--ftp-inventory", str(empty), "--keep-ftp-status"
            ),
            0,
        )
        kept = {
            rel: value.get("ftp_status")
            for rel, value in self.load()["entries"].items()
        }
        self.assertEqual(first, kept)
        self.assertEqual(self.run_tool("--no-ftp-status"), 0)
        cleared = self.load()["entries"]
        self.assertFalse(any("ftp_status" in value for value in cleared.values()))

    def test_check_detects_ftp_status_change(self) -> None:
        alpha = f"{CRACKED}/A/Alpha/Alpha - Crew.zip"
        inventory = self.write_inventory(
            {alpha: {"size": 1, "mtime": None}}
        )
        self.assertEqual(self.run_tool("--ftp-inventory", str(inventory)), 0)
        empty = self.write_inventory({}, name="empty.json.gz")
        status = fig.main([
            "check",
            "--root", str(self.root),
            "--patch", str(self.patch),
            "--out", str(self.out),
            "--scope", "cracked",
            "--ftp-inventory", str(empty),
        ])
        self.assertEqual(status, 1)

    def test_check_ignores_ftp_without_inventory(self) -> None:
        alpha = f"{CRACKED}/A/Alpha/Alpha - Crew.zip"
        inventory = self.write_inventory(
            {alpha: {"size": 1, "mtime": None}}
        )
        self.assertEqual(self.run_tool("--ftp-inventory", str(inventory)), 0)
        missing = Path(self.tmp.name) / "does-not-exist.json.gz"
        status = fig.main([
            "check",
            "--root", str(self.root),
            "--patch", str(self.patch),
            "--out", str(self.out),
            "--scope", "cracked",
            "--ftp-inventory", str(missing),
        ])
        self.assertEqual(status, 0)

    def test_check_detects_change(self) -> None:
        self.assertEqual(self.run_tool(), 0)
        changed = self.root / CRACKED / "B" / "Beta" / "Beta.zip"
        write_zip(changed, {"beta.st": raw_image(4), "extra.bin": b"changed"})
        status = fig.main([
            "check",
            "--root", str(self.root),
            "--patch", str(self.patch),
            "--out", str(self.out),
            "--scope", "cracked",
        ])
        self.assertEqual(status, 1)

    def test_check_parity_with_screenshot_index(self) -> None:
        self.assertEqual(self.run_tool(), 0)
        shot = Path(self.tmp.name) / "shots"
        shot.mkdir()
        entries = self.load()["entries"]
        index = {
            "entries": {
                rel: {"rel": rel, "name": value["name"], "layer": value["layer"]}
                for rel, value in entries.items()
            }
        }
        (shot / "index.json").write_text(json.dumps(index), encoding="utf-8")
        old = os.environ.get("MARCER_OUT_DIR")
        os.environ["MARCER_OUT_DIR"] = str(shot)
        try:
            status = fig.main([
                "check",
                "--root", str(self.root),
                "--patch", str(self.patch),
                "--out", str(self.out),
                "--scope", "cracked",
                "--parity",
            ])
        finally:
            if old is None:
                os.environ.pop("MARCER_OUT_DIR", None)
            else:
                os.environ["MARCER_OUT_DIR"] = old
        self.assertEqual(status, 0)


if __name__ == "__main__":
    unittest.main()
