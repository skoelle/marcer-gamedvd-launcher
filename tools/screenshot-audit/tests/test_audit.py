# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/screenshot-audit."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import audit as a


def entry(section: str, rel: str, **overrides) -> a.Entry:
    values = {
        "section": section,
        "rel": rel,
        "status": "done",
        "kind": "game",
        "monitor": "color",
        "preview": "x.png",
        "preview_path": Path("/tmp/x.png"),
        "sidecar_path": Path("/tmp/x.json"),
        "shots": [{"phash": "cdc93236cdc93236", "kind": "game"}],
        "preview_metrics": {
            "phash": "cdc93236cdc93236",
            "kind": "game",
            "std": 50.0,
            "unique_colors": 16,
        },
    }
    values.update(overrides)
    return a.Entry(**values)


class HashTests(unittest.TestCase):
    def test_exact_clusters(self) -> None:
        groups = a.cluster_hashes(["aa", "aa", "bb"], 0)
        self.assertEqual(sorted(sorted(group) for group in groups), [["aa", "aa"], ["bb"]])

    def test_near_clusters(self) -> None:
        groups = a.cluster_hashes(
            ["0000000000000000", "0000000000000001", "ffffffffffffffff"], 2
        )
        self.assertEqual(len(groups), 2)
        self.assertIn(
            ["0000000000000000", "0000000000000001"],
            [sorted(group) for group in groups],
        )


class RegistryTests(unittest.TestCase):
    def test_exact_and_near_match(self) -> None:
        registry = {"cdc93236cdc93236": {"action": "error", "label": "error"}}
        self.assertEqual(a.registry_match("cdc93236cdc93236", registry)[0], "error")
        self.assertEqual(a.registry_match("cdc93236cdc93237", registry, 2)[0], "error")
        self.assertIsNone(a.registry_match("0000000000000000", registry, 0))


class ClusterTests(unittest.TestCase):
    def test_error_cluster_wins_and_keeps_representative(self) -> None:
        e1 = entry("pd", "T/A/A.zip")
        e2 = entry("pd", "T/B/B.zip")
        items = {
            "cdc93236cdc93236": [
                a.HashItem(e1, e1.shots[0]),
                a.HashItem(e2, e2.shots[0]),
            ]
        }
        info = a.cluster_info(
            ["cdc93236cdc93236"],
            items,
            {"cdc93236cdc93236": {"action": "error", "label": "bad"}},
            min_folders=2,
            registry_dist=2,
        )
        self.assertIsNotNone(info)
        self.assertEqual(info["action"], "error")
        self.assertEqual(info["folder_count"], 2)
        self.assertEqual(info["representative"], e1)

    def test_unmatched_small_cluster_is_ignored(self) -> None:
        e1 = entry("pd", "T/A/A.zip")
        items = {"abcd": [a.HashItem(e1, e1.shots[0])]}
        self.assertIsNone(
            a.cluster_info(["abcd"], items, {}, min_folders=2, registry_dist=2)
        )

    def test_no_usable_cluster_is_kept_without_done_entries(self) -> None:
        e1 = entry("pd", "T/A/A.zip", status="desktop")
        e2 = entry("pd", "T/B/B.zip", status="desktop")
        items = {
            "cdc93236cdc93236": [
                a.HashItem(e1, e1.shots[0]),
                a.HashItem(e2, e2.shots[0]),
            ]
        }
        info = a.cluster_info(
            ["cdc93236cdc93236"],
            items,
            {"cdc93236cdc93236": {"action": "no_usable", "label": "bad"}},
            min_folders=3,
            registry_dist=2,
        )
        self.assertIsNotNone(info)
        self.assertEqual(info["action"], "no_usable")


class FlagTests(unittest.TestCase):
    def test_blank_and_known_error_flags(self) -> None:
        e = entry(
            "pd",
            "T/A/A.zip",
            status="done",
            kind="game",
            preview_metrics={
                "phash": "cdc93236cdc93236",
                "kind": "game",
                "std": 1.0,
                "unique_colors": 1,
            },
        )
        flags = a.entry_flags(
            [e],
            {"cdc93236cdc93236": {"action": "error"}},
            2,
        )
        self.assertEqual(len(flags), 1)
        self.assertIn("known_error_screen", flags[0]["reasons"])
        self.assertIn("blank", flags[0]["reasons"])

    def test_metadata_flags(self) -> None:
        e = entry("pd", "T/A/A.zip", status="desktop", kind="game", monitor=None)
        flags = a.entry_flags([e], {}, 2)
        reasons = flags[0]["reasons"]
        self.assertIn("desktop:kind:game", reasons)
        self.assertIn("monitor:unknown", reasons)


class RetryTests(unittest.TestCase):
    def test_desktop_and_no_usable_need_retry(self) -> None:
        registry = {"cdc93236cdc93236": {"action": "error"}}
        self.assertTrue(a.needs_retry(entry("pd", "A.zip", status="desktop"), registry, 2))
        self.assertTrue(a.needs_retry(entry("pd", "A.zip", status="no_usable_shots"), registry, 2))
        good = entry(
            "pd", "A.zip", status="done",
            preview_metrics={"phash": "0000000000000000", "std": 60.0,
                             "unique_colors": 16},
        )
        self.assertFalse(a.needs_retry(good, registry, 2))

    def test_no_usable_targets_need_explicit_try_options(self) -> None:
        e = entry("pd", "A.zip", status="done")
        registry = {
            "cdc93236cdc93236": {
                "action": "no_usable",
                "try": {"tos": ["1.02"]},
            }
        }
        cfg = {"filters": {}}
        groups = a.target_groups([e], registry, cfg, 2)
        self.assertEqual(sum(len(value) for value in groups.values()), 1)
        registry["cdc93236cdc93236"] = {"action": "no_usable"}
        self.assertFalse(a.target_groups([e], registry, cfg, 2))

    def test_apply_matches_no_usable_without_try(self) -> None:
        e = entry("pd", "A.zip", status="desktop")
        registry = {"cdc93236cdc93236": {"action": "no_usable"}}
        matches = a.collect_registry_matches(
            [e], registry, {"filters": {}}, 2, ("no_usable",)
        )
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0][1], "no_usable")

    def test_no_usable_marks_desktop_but_keeps_fixed_done(self) -> None:
        registry = {"cdc93236cdc93236": {"action": "no_usable"}}
        desktop = entry("pd", "A.zip", status="desktop")
        self.assertTrue(a.needs_mark(desktop, registry, 2, "no_usable"))
        fixed = entry(
            "pd", "A.zip", status="done",
            preview_metrics={"phash": "0000000000000000", "std": 60.0,
                             "unique_colors": 16},
        )
        self.assertFalse(a.needs_mark(fixed, registry, 2, "no_usable"))


class RetryStateTests(unittest.TestCase):
    def test_state_roundtrip_and_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            a.save_retry_state(path, {"one", "two"})
            self.assertEqual(a.load_retry_state(path), {"one", "two"})
        key = a.attempt_key(
            "pd", "T/A.zip", "abcd", "1.02", "0", "mono", "high",
            "space", 1, "auto", True, True,
        )
        self.assertIn("T/A.zip", key)
        self.assertIn("space", key)
        self.assertIn("auto", key)

    def test_require_try_skips_clusters_without_try(self) -> None:
        e = entry("pd", "A.zip", status="no_usable_shots")
        registry = {"cdc93236cdc93236": {"action": "no_usable"}}
        groups = a.target_groups(
            [e], registry, {"filters": {}}, 2,
            include_no_usable=True, require_try=True,
        )
        self.assertFalse(groups)


class ApplyStateTests(unittest.TestCase):
    def test_valid_status_and_kind_are_written_to_index_and_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            rel = "T/A/Game.zip"
            index = {
                "entries": {
                    rel: {
                        "status": "desktop",
                        "kind": "desktop",
                        "preview": "Game.png",
                    }
                }
            }
            (out / "index-pd.json").write_text(json.dumps(index), encoding="utf-8")
            meta_dir = out / "T/A"
            meta_dir.mkdir(parents=True)
            (meta_dir / "Game.json").write_text(
                json.dumps({"status": "desktop", "kind": "desktop"}),
                encoding="utf-8",
            )
            changed = a.apply_entry_state(out, "pd", [rel], "done", "game")
            self.assertEqual(changed, 1)
            data = json.loads((out / "index-pd.json").read_text(encoding="utf-8"))
            entry = data["entries"][rel]
            self.assertEqual((entry["status"], entry["kind"]), ("done", "game"))
            sidecar = json.loads((meta_dir / "Game.json").read_text(encoding="utf-8"))
            self.assertEqual((sidecar["status"], sidecar["kind"]), ("done", "game"))


class OnlyFileTests(unittest.TestCase):
    def test_only_file_is_casefolded_and_skips_comments(self) -> None:
        import shotgen

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "list.txt"
            path.write_text("# comment\nA/B/C.zip\n\n", encoding="utf-8")
            self.assertEqual(shotgen.load_only_file(str(path)), {"a/b/c.zip"})


if __name__ == "__main__":
    unittest.main()
