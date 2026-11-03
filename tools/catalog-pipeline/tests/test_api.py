# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Integration tests for the catalog pipeline HTTP API."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import jobs
import pipeline
import status


def script_factory(code: str):
    def factory(mode: str, options: dict) -> list[str]:
        return [sys.executable, "-u", "-c", code]

    return factory


def wait_for(predicate, timeout: float = 8.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


class ApiTest(unittest.TestCase):
    command = "import time; time.sleep(30)\n"

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.state = root / "state"
        self.manager = jobs.JobManager(
            state_dir=self.state,
            repo_root=root,
            command_factory=script_factory(self.command),
        )
        self.collector = status.StatusCollector(environ={}, repo_root=root)
        self.server = pipeline.ThreadingHTTPServer(
            ("127.0.0.1", 0), pipeline.StatusHandler
        )
        self.server.collector = self.collector
        self.server.manager = self.manager
        self.thread = threading.Thread(
            target=self.server.serve_forever, daemon=True
        )
        self.thread.start()
        host, port = self.server.server_address
        self.base = f"http://{host}:{port}"

    def tearDown(self) -> None:
        self.manager.shutdown()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.temp.cleanup()

    def request(self, method: str, path: str, body=None, headers=None):
        data = None
        request_headers = dict(headers or {})
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            request_headers.setdefault("Content-Type", "application/json")
        request = urllib.request.Request(
            self.base + path,
            data=data,
            headers=request_headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                raw = response.read()
                return response.status, json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            return exc.code, json.loads(raw) if raw else {}

    def test_run_busy_jobs_detail_log_and_cancel(self) -> None:
        code, payload = self.request("POST", "/api/run", {"mode": "full"})
        self.assertEqual(code, 202)
        job_id = payload["job"]["id"]

        code, payload = self.request("POST", "/api/run", {"mode": "full"})
        self.assertEqual(code, 409)

        code, payload = self.request("GET", "/api/jobs")
        self.assertEqual(code, 200)
        self.assertEqual(payload["current"]["id"], job_id)

        code, payload = self.request("GET", f"/api/jobs/{job_id}")
        self.assertEqual(code, 200)
        self.assertEqual(payload["job"]["mode"], "full")

        code, payload = self.request("GET", f"/api/jobs/{job_id}/log")
        self.assertEqual(code, 200)
        self.assertEqual(payload["id"], job_id)

        code, payload = self.request(
            "POST", "/api/cancel", {"id": job_id}
        )
        self.assertEqual(code, 202)
        self.assertTrue(wait_for(lambda: self.manager.current() is None))
        code, payload = self.request("GET", f"/api/jobs/{job_id}")
        self.assertEqual(payload["job"]["status"], "cancelled")

    def test_run_rejects_wrong_content_type(self) -> None:
        request = urllib.request.Request(
            self.base + "/api/run",
            data=b'{"mode": "full"}',
            headers={"Content-Type": "text/plain"},
            method="POST",
        )
        try:
            urllib.request.urlopen(request, timeout=5)
            self.fail("expected HTTP error")
        except urllib.error.HTTPError as exc:
            self.assertEqual(exc.code, 415)

    def test_token_is_required_when_configured(self) -> None:
        with mock.patch.dict(
            os.environ, {"MARCER_PIPELINE_TOKEN": "secret"}, clear=False
        ):
            code, _ = self.request("POST", "/api/run", {"mode": "full"})
            self.assertEqual(code, 401)
            code, _ = self.request(
                "POST",
                "/api/run",
                {"mode": "full"},
                {"Authorization": "Bearer wrong"},
            )
            self.assertEqual(code, 401)
            code, payload = self.request(
                "POST",
                "/api/run",
                {"mode": "full"},
                {"Authorization": "Bearer secret"},
            )
            self.assertEqual(code, 202)
            job_id = payload["job"]["id"]
            code, _ = self.request(
                "POST",
                "/api/cancel",
                {"id": job_id},
                {"Authorization": "Bearer secret"},
            )
            self.assertEqual(code, 202)
            self.assertTrue(wait_for(lambda: self.manager.current() is None))


if __name__ == "__main__":
    unittest.main()
