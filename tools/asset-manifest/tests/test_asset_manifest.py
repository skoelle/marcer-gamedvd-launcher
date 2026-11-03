# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/asset-manifest (stdlib unittest)."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import asset_manifest as am


class ManifestTests(unittest.TestCase):
    def test_pick_newest_per_kind(self) -> None:
        entries = [
            ("gameinfo-20260101-000000.zip", 1, None),
            ("gameinfo-20260102-000000.zip", 2, None),
            ("screenshots-20260101-000000.zip", 3, None),
            ("notes.txt", 4, None),
            ("gameinfo-20260102-000000.zip.part", 5, None),
        ]
        found = am.pick_newest(entries)
        self.assertEqual(found["gameinfo"][0], "gameinfo-20260102-000000.zip")
        self.assertEqual(
            found["screenshots"][0], "screenshots-20260101-000000.zip"
        )

    def test_repo_slug_prefers_env_with_token(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"MARCER_REPO": "owner/repo", "MARCER_GITHUB_TOKEN": "token"},
            clear=True,
        ):
            self.assertEqual(am.repo_slug(None), "owner/repo")

    def test_repo_slug_uses_git_remote_with_token(self) -> None:
        with mock.patch.dict(
            os.environ, {"MARCER_GITHUB_TOKEN": "token"}, clear=True
        ), mock.patch.object(am, "repo_from_git", return_value="owner/repo"):
            self.assertEqual(am.repo_slug(None, "token"), "owner/repo")

    def test_token_release_exists(self) -> None:
        with mock.patch.object(
            am, "api_request", return_value=(200, b"{}")
        ) as request:
            self.assertTrue(am.release_exists("catalog-latest", "o/r", "t"))
        request.assert_called_once_with(
            "GET", "/repos/o/r/releases/tags/catalog-latest", "t"
        )
        with mock.patch.object(am, "api_request", return_value=(404, b"{}")):
            self.assertFalse(am.release_exists("catalog-latest", "o/r", "t"))

    def test_token_upload_replaces_existing_asset(self) -> None:
        release = {
            "assets": [{"id": 7, "name": "latest.json"}],
            "upload_url": "https://uploads.github.com/repos/o/r/releases/1/assets{?name,label}",
        }
        calls = []

        def fake_request(method, path, token, body=None, content_type="application/json"):
            calls.append((method, path, body, content_type))
            if method == "GET":
                return 200, json.dumps(release).encode()
            if method == "DELETE":
                return 204, b""
            if method == "POST":
                return 201, b"{}"
            return 500, b""

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "latest.json"
            path.write_text('{"schema": 1}\n', encoding="utf-8")
            with mock.patch.object(am, "api_request", side_effect=fake_request):
                am.upload_asset("catalog-latest", path, "o/r", False, "t")

        self.assertIn(("DELETE", "/repos/o/r/releases/assets/7", None, "application/json"), calls)
        upload = next(call for call in calls if call[0] == "POST")
        self.assertIn("?name=latest.json", upload[1])
        self.assertEqual(upload[2], b'{"schema": 1}\n')
        self.assertEqual(upload[3], "application/octet-stream")


if __name__ == "__main__":
    unittest.main()
