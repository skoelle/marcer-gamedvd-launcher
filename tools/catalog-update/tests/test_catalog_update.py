# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/catalog-update (stdlib unittest)."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import catalog_update as cu

PD_TREE = "Title Sorted/PD Games - Title Sorted"
CRACKED_TREE = "Title Sorted/Cracked Games - Title Sorted"


class FakeRunner:
    def __init__(self, responses: dict | None = None) -> None:
        self.responses = {
            "asset-publish dry-run": (
                0,
                json.dumps({"status": "would-skip"}),
            )
        }
        self.responses.update(responses or {})
        self.calls: list[tuple[str, list[str], bool]] = []
        self.steps: list[cu.StepResult] = []

    def run(self, name: str, argv: list[str], capture: bool = False) -> cu.StepResult:
        self.calls.append((name, argv, capture))
        response = self.responses.get(name, (0, ""))
        if callable(response):
            rc, out = response(name, argv)
        elif isinstance(response, list):
            rc, out = response.pop(0)
        else:
            rc, out = response
        step = cu.StepResult(name, argv, rc, 0.0, out, "")
        self.steps.append(step)
        return step

    def names(self) -> list[str]:
        return [name for name, _, _ in self.calls]


def make_options(tmp: Path, **overrides) -> cu.Options:
    repo = tmp / "repo"
    root = tmp / "root"
    patch = tmp / "patch"
    data = tmp / "data"
    for path in (repo / "local" / "archive-sync", root, patch, data):
        path.mkdir(parents=True)
    values = {
        "repo_root": repo,
        "root": root,
        "patch": patch,
        "data_dir": data,
        "only": (),
        "excludes": (),
        "dry_run": False,
        "skip_publish": False,
        "no_crew": False,
        "report_dir": repo / "local" / "catalog-update",
        "sync_report_dir": repo / "local" / "archive-sync",
    }
    values.update(overrides)
    return cu.Options(**values)


def make_tree(root: Path, tree: str, *dirs: str) -> None:
    for rel in dirs:
        (root / tree / rel).mkdir(parents=True, exist_ok=True)


def write_changes(
    opts: cu.Options,
    *,
    new: tuple[str, ...] = (),
    changed: tuple[str, ...] = (),
    counts: dict | None = None,
) -> Path:
    data = {
        "counts": counts
        or {
            "new": len(new),
            "changed": len(changed),
            "in_sync": 0,
            "local_only": 0,
            "downloads": len(new) + len(changed),
            "download_errors": 0,
            "incomplete_dirs": 0,
        },
        "new": [{"path": path, "size": 1} for path in new],
        "changed": [{"path": path, "size": 1} for path in changed],
    }
    path = opts.changes_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


def write_publish_state(
    opts: cu.Options,
    *,
    uploaded: bool = True,
    dirty: bool = False,
    archive: str = "gameinfo-test.zip",
) -> None:
    output_dir, state_file = cu.asset_publish_paths(opts)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / archive).write_bytes(b"zip")
    state = {
        "schema": 1,
        "assets": {
            "gameinfo": {
                "archive": archive,
                "uploaded": uploaded,
                "manifest_dirty": dirty,
            }
        },
    }
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps(state), encoding="utf-8")


def publish_responses(status: str = "would-skip") -> dict:
    responses = {
        "asset-publish dry-run": (0, json.dumps({"status": status})),
    }
    if status != "would-skip":
        responses["asset-publish"] = (
            0,
            json.dumps({"status": "uploaded", "uploaded": True}),
        )
    return responses


class CatalogUpdateTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.opts = make_options(self.tmp)
        make_tree(self.opts.root, PD_TREE, "A")
        make_tree(self.opts.root, CRACKED_TREE, "A")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_no_changes_skips_rebuilds_and_publish(self) -> None:
        write_changes(self.opts)
        runner = FakeRunner(
            {
                "gameinfo check": (0, ""),
                "full-index check": (0, ""),
                **publish_responses(),
            }
        )
        self.assertEqual(cu.run_update(self.opts, runner), 0)
        self.assertEqual(
            runner.names(),
            [
                "archive-sync",
                "gameinfo check",
                "full-index check",
                "asset-publish dry-run",
            ],
        )
        self.assertNotIn("gameinfo extract", runner.names())
        self.assertNotIn("full-index run", runner.names())
        self.assertNotIn("crew-analysis", runner.names())
        self.assertNotIn("asset-publish", runner.names())
        reports = list((self.opts.report_dir / "runs").glob("*.json"))
        self.assertEqual(len(reports), 1)
        report = json.loads(reports[0].read_text(encoding="utf-8"))
        self.assertEqual(report["status"], "ok")
        self.assertEqual(report["actions"]["publish"], "skipped")

    def test_new_pd_dir_runs_gameinfo_full_index_and_crew(self) -> None:
        new_rel = f"{PD_TREE}/T/New Game/New Game.zip"
        write_changes(self.opts, new=(new_rel,))
        runner = FakeRunner(
            {
                "gameinfo check": (1, ""),
                "gameinfo extract": (0, ""),
                "gameinfo check (final)": (0, ""),
                "full-index run": (0, ""),
                "full-index check (final)": (0, ""),
                "crew-analysis": (0, ""),
                **publish_responses("would-create-upload"),
            }
        )
        self.assertEqual(cu.run_update(self.opts, runner), 0)
        names = runner.names()
        self.assertIn("gameinfo extract", names)
        self.assertIn("full-index run", names)
        self.assertIn("crew-analysis", names)
        self.assertIn("asset-publish", names)
        report = json.loads(
            next((self.opts.report_dir / "runs").glob("*.json")).read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(report["actions"]["gameinfo_extract"], True)
        self.assertEqual(report["actions"]["full_index_run"], True)
        self.assertEqual(report["actions"]["crew_analysis"], True)
        self.assertEqual(report["actions"]["publish"], "uploaded")
        self.assertEqual(report["sync"]["new_dirs"], [f"{PD_TREE}/T/New Game"])

    def test_new_file_in_existing_folder_skips_gameinfo(self) -> None:
        new_rel = f"{PD_TREE}/A/New Game.zip"
        write_changes(self.opts, new=(new_rel,))
        runner = FakeRunner(
            {
                "gameinfo check": (0, ""),
                "full-index run": (0, ""),
                "full-index check (final)": (0, ""),
                **publish_responses("would-create-upload"),
            }
        )
        self.assertEqual(cu.run_update(self.opts, runner), 0)
        self.assertNotIn("gameinfo extract", runner.names())
        report = json.loads(
            next((self.opts.report_dir / "runs").glob("*.json")).read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(report["sync"]["new_dirs"], [])

    def test_cracked_change_runs_full_index_and_crew_without_gameinfo(self) -> None:
        changed_rel = f"{CRACKED_TREE}/A/Game.zip"
        write_changes(self.opts, changed=(changed_rel,))
        runner = FakeRunner(
            {
                "gameinfo check": (0, ""),
                "full-index run": (0, ""),
                "full-index check (final)": (0, ""),
                "crew-analysis": (0, ""),
                **publish_responses("would-create-upload"),
            }
        )
        self.assertEqual(cu.run_update(self.opts, runner), 0)
        names = runner.names()
        self.assertNotIn("gameinfo extract", names)
        self.assertIn("full-index run", names)
        self.assertIn("crew-analysis", names)
        self.assertIn("asset-publish", names)

    def test_sync_failure_aborts_and_writes_error_report(self) -> None:
        write_changes(self.opts)
        runner = FakeRunner({"archive-sync": (1, "")})
        self.assertEqual(cu.run_update(self.opts, runner), 1)
        self.assertEqual(runner.names(), ["archive-sync"])
        report = json.loads(
            next((self.opts.report_dir / "runs").glob("*.json")).read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(report["status"], "error")
        self.assertEqual(report["error"]["stage"], "archive-sync")

    def test_dry_run_uses_plan_and_writes_nothing(self) -> None:
        self.opts.dry_run = True
        runner = FakeRunner(
            {
                "gameinfo check (dry-run)": (1, ""),
                "full-index check (dry-run)": (1, ""),
            }
        )
        self.assertEqual(cu.run_update(self.opts, runner), 0)
        self.assertEqual(
            runner.names(),
            [
                "archive-sync plan",
                "gameinfo check (dry-run)",
                "full-index check (dry-run)",
            ],
        )
        self.assertIn("plan", runner.calls[0][1])
        self.assertFalse((self.opts.report_dir / "runs").exists())

    def test_skip_publish_does_not_call_asset_publish(self) -> None:
        self.opts.skip_publish = True
        write_changes(self.opts)
        runner = FakeRunner(
            {
                "gameinfo check": (0, ""),
                "full-index check": (0, ""),
            }
        )
        self.assertEqual(cu.run_update(self.opts, runner), 0)
        self.assertNotIn("asset-publish dry-run", runner.names())
        self.assertNotIn("asset-publish", runner.names())

    def test_no_crew_skips_crew_analysis(self) -> None:
        self.opts.no_crew = True
        new_rel = f"{PD_TREE}/T/New Game/New Game.zip"
        write_changes(self.opts, new=(new_rel,))
        runner = FakeRunner(
            {
                "gameinfo check": (1, ""),
                "gameinfo extract": (0, ""),
                "gameinfo check (final)": (0, ""),
                "full-index run": (0, ""),
                "full-index check (final)": (0, ""),
                **publish_responses("would-create-upload"),
            }
        )
        self.assertEqual(cu.run_update(self.opts, runner), 0)
        self.assertNotIn("crew-analysis", runner.names())

    def test_catalog_change_with_unchanged_asset_does_not_upload(self) -> None:
        changed_rel = f"{CRACKED_TREE}/A/Game.zip"
        write_changes(self.opts, changed=(changed_rel,))
        runner = FakeRunner(
            {
                "gameinfo check": (0, ""),
                "full-index run": (0, ""),
                "full-index check (final)": (0, ""),
                "crew-analysis": (0, ""),
                **publish_responses("would-skip"),
            }
        )
        self.assertEqual(cu.run_update(self.opts, runner), 0)
        self.assertIn("asset-publish dry-run", runner.names())
        self.assertNotIn("asset-publish", runner.names())

    def test_clean_publish_state_skips_asset_publish_without_changes(self) -> None:
        write_changes(self.opts)
        write_publish_state(self.opts)
        runner = FakeRunner(
            {
                "gameinfo check": (0, ""),
                "full-index check": (0, ""),
            }
        )
        self.assertEqual(cu.run_update(self.opts, runner), 0)
        self.assertNotIn("asset-publish dry-run", runner.names())
        self.assertNotIn("asset-publish", runner.names())

    def test_pending_publish_is_retried_even_without_catalog_changes(self) -> None:
        write_changes(self.opts)
        write_publish_state(self.opts, dirty=True)
        runner = FakeRunner(
            {
                "gameinfo check": (0, ""),
                "full-index check": (0, ""),
                **publish_responses("would-update-manifest"),
            }
        )
        self.assertEqual(cu.run_update(self.opts, runner), 0)
        self.assertIn("asset-publish", runner.names())

    def test_only_and_exclude_are_passed_to_archive_sync(self) -> None:
        self.opts.only = ("Title Sorted/PD Games - Title Sorted/T",)
        self.opts.excludes = ("*.bak",)
        write_changes(self.opts)
        runner = FakeRunner(
            {
                "gameinfo check": (0, ""),
                "full-index check": (0, ""),
                **publish_responses(),
            }
        )
        self.assertEqual(cu.run_update(self.opts, runner), 0)
        argv = runner.calls[0][1]
        self.assertIn("--only", argv)
        self.assertIn("Title Sorted/PD Games - Title Sorted/T", argv)
        self.assertIn("--exclude", argv)
        self.assertIn("*.bak", argv)


if __name__ == "__main__":
    unittest.main()
