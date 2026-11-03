#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Read-only web service for the Marcer catalog pipeline status.

Phase 1 deliberately has no write endpoints: it only serves the aggregated
status JSON and the static dashboard. Manual runs, the scheduler, Docker and
screenshot publishing are later phases (see docs/plans/PLAN-docker-pipeline.md).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))

from status import DEFAULT_RUN_LIMIT, TOOL_VERSION, StatusCollector  # noqa: E402

STATIC_DIR = Path(__file__).resolve().parent / "web"


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
        elif path in ("/", "/index.html"):
            self._send_file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
        elif path.startswith("/static/"):
            rel = path[len("/static/") :]
            self._send_static(rel)
        else:
            self._send_json({"error": "not found"}, status=404)

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
        description="Read-only catalog pipeline status web service.",
    )
    parser.add_argument(
        "--version", action="version", version=f"catalog-pipeline {TOOL_VERSION}"
    )
    subparsers = parser.add_subparsers(dest="command")
    serve = subparsers.add_parser("serve", help="start the status web service")
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
    server = ThreadingHTTPServer((host, port), StatusHandler)
    server.collector = collector
    print(
        f"catalog-pipeline {TOOL_VERSION} read-only status: "
        f"http://{host}:{port}/",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\ncatalog-pipeline: stopped", file=sys.stderr)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
