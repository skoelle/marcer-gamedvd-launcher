#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Web service for the Marcer catalog pipeline.

Serves the aggregated read-only status plus manual job control:
``POST /api/run``, ``POST /api/cancel`` and the job/log endpoints. Docker,
the scheduler and screenshot publishing are later phases (see
docs/plans/PLAN-docker-pipeline.md).
"""
from __future__ import annotations

import argparse
import hmac
import json
import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))

from jobs import (  # noqa: E402
    BusyError,
    InvalidJobError,
    JobError,
    JobManager,
    NotFoundError,
)
from scheduler import Scheduler, SchedulerError  # noqa: E402
from status import DEFAULT_RUN_LIMIT, TOOL_VERSION, StatusCollector  # noqa: E402

STATIC_DIR = Path(__file__).resolve().parent / "web"
MAX_BODY_BYTES = 64 * 1024


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def json_bytes(payload: dict | list) -> bytes:
    return (
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")


class StatusHandler(BaseHTTPRequestHandler):
    server_version = f"MarcerCatalogPipeline/{TOOL_VERSION}"

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/healthz":
            self._send_json(self.server.collector.health())
        elif path == "/api/status":
            self._send_json(self.server.collector.collect())
        elif path == "/api/runs":
            params = parse_qs(parsed.query)
            try:
                limit = int(params.get("limit", [DEFAULT_RUN_LIMIT])[0])
            except ValueError:
                limit = DEFAULT_RUN_LIMIT
            limit = max(0, min(limit, 100))
            self._send_json({"runs": self.server.collector.runs(limit)})
        elif path == "/api/jobs":
            params = parse_qs(parsed.query)
            try:
                limit = int(params.get("limit", [10])[0])
            except ValueError:
                limit = 10
            limit = max(0, min(limit, 100))
            self._send_json(
                {
                    "current": self.server.manager.current(),
                    "jobs": self.server.manager.list_jobs(limit),
                }
            )
        elif path.startswith("/api/jobs/"):
            self._get_job(path, parsed)
        elif path in ("/", "/index.html"):
            self._send_file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
        elif path.startswith("/static/"):
            rel = path[len("/static/") :]
            self._send_static(rel)
        else:
            self._send_json({"error": "not found"}, status=404)

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path = urlparse(self.path).path
        if not self._authorized():
            return
        if path == "/api/run":
            body = self._read_json_body(allow_empty=True)
            if body is None:
                return
            mode = str(body.get("mode") or "full")
            try:
                job = self.server.manager.start(mode, body)
            except BusyError as exc:
                self._send_json({"error": str(exc)}, status=409)
            except InvalidJobError as exc:
                self._send_json({"error": str(exc)}, status=400)
            except JobError as exc:
                self._send_json({"error": str(exc)}, status=500)
            else:
                self._send_json({"job": job}, status=202)
        elif path == "/api/cancel":
            body = self._read_json_body(allow_empty=True)
            if body is None:
                return
            job_id = body.get("id")
            try:
                job = self.server.manager.cancel(
                    str(job_id) if job_id else None
                )
            except NotFoundError as exc:
                self._send_json({"error": str(exc)}, status=404)
            else:
                self._send_json({"job": job}, status=202)
        else:
            self._send_json({"error": "not found"}, status=404)

    def _get_job(self, path: str, parsed) -> None:
        rest = path[len("/api/jobs/") :].strip("/")
        if not rest:
            self._send_json({"error": "not found"}, status=404)
            return
        is_log = rest.endswith("/log")
        job_id = rest[:-4].strip("/") if is_log else rest
        try:
            if is_log:
                params = parse_qs(parsed.query)
                try:
                    lines = int(params.get("tail", [200])[0])
                except ValueError:
                    lines = 200
                self._send_json(self.server.manager.log_tail(job_id, lines))
            else:
                self._send_json({"job": self.server.manager.get_job(job_id)})
        except NotFoundError:
            self._send_json({"error": "job not found"}, status=404)

    def _authorized(self) -> bool:
        token = env("MARCER_PIPELINE_TOKEN")
        if not token:
            return True
        header = self.headers.get("Authorization", "")
        if hmac.compare_digest(header, f"Bearer {token}"):
            return True
        self._send_json({"error": "unauthorized"}, status=401)
        return False

    def _read_json_body(self, allow_empty: bool = False) -> dict | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0:
            self._send_json({"error": "invalid content length"}, status=400)
            return None
        if length > MAX_BODY_BYTES:
            self._send_json({"error": "request body too large"}, status=413)
            return None
        if length == 0:
            if allow_empty:
                return {}
            self._send_json({"error": "JSON body required"}, status=400)
            return None
        content_type = self.headers.get("Content-Type", "")
        if not content_type.lower().startswith("application/json"):
            self._send_json(
                {"error": "Content-Type must be application/json"}, status=415
            )
            return None
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            self._send_json({"error": "invalid JSON body"}, status=400)
            return None
        if not isinstance(body, dict):
            self._send_json({"error": "JSON body must be an object"}, status=400)
            return None
        return body

    def _send_static(self, rel: str) -> None:
        candidate = (STATIC_DIR / rel).resolve()
        try:
            candidate.relative_to(STATIC_DIR.resolve())
        except ValueError:
            self._send_json({"error": "not found"}, status=404)
            return
        if not candidate.is_file():
            self._send_json({"error": "not found"}, status=404)
            return
        content_type = {
            ".css": "text/css; charset=utf-8",
            ".js": "text/javascript; charset=utf-8",
            ".html": "text/html; charset=utf-8",
            ".svg": "image/svg+xml",
        }.get(candidate.suffix.lower(), "application/octet-stream")
        self._send_file(candidate, content_type)

    def _send_file(self, path: Path, content_type: str) -> None:
        try:
            body = path.read_bytes()
        except OSError:
            self._send_json({"error": "not found"}, status=404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, payload: dict | list, status: int = 200) -> None:
        body = json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        if os.environ.get("PIPELINE_VERBOSE"):
            super().log_message(fmt, *args)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="catalog-pipeline",
        description="Catalog pipeline status and manual job control.",
    )
    parser.add_argument(
        "--version", action="version", version=f"catalog-pipeline {TOOL_VERSION}"
    )
    subparsers = parser.add_subparsers(dest="command")
    serve = subparsers.add_parser("serve", help="start the pipeline web service")
    serve.add_argument(
        "--host",
        default=env("MARCER_PIPELINE_HOST", "0.0.0.0"),
        help="bind address (default: MARCER_PIPELINE_HOST or 0.0.0.0)",
    )
    serve.add_argument(
        "--port",
        type=int,
        default=int(env("MARCER_PIPELINE_PORT", "8080") or "8080"),
        help="bind port (default: MARCER_PIPELINE_PORT or 8080)",
    )
    subparsers.add_parser("status", help="print the aggregated status as JSON")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    command = args.command or "serve"
    collector = StatusCollector()
    if command == "status":
        sys.stdout.buffer.write(json_bytes(collector.collect()))
        return 0

    host = getattr(args, "host", None) or env("MARCER_PIPELINE_HOST", "0.0.0.0")
    port = getattr(args, "port", None)
    if port is None:
        try:
            port = int(env("MARCER_PIPELINE_PORT", "8080") or "8080")
        except ValueError:
            port = 8080

    manager = JobManager()
    scheduler = None
    try:
        scheduler = Scheduler(manager)
        scheduler.start()
    except SchedulerError as exc:
        print(
            f"catalog-pipeline: scheduler disabled: {exc}",
            file=sys.stderr,
        )
        scheduler = None
    server = ThreadingHTTPServer((host, port), StatusHandler)
    server.collector = collector
    server.manager = manager

    def _stop(signum, frame):  # noqa: ARG001 - signal handler signature
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, _stop)

    print(
        f"catalog-pipeline {TOOL_VERSION} status/control: "
        f"http://{host}:{port}/",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\ncatalog-pipeline: stopped", file=sys.stderr)
    finally:
        if scheduler is not None:
            scheduler.stop()
        manager.shutdown()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
