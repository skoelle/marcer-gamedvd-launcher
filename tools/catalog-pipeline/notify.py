#!/usr/bin/env python3
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Optional e-mail notification when a catalog sync downloaded changes.

The notifier is deliberately independent of the scheduler and the web layer.
It is disabled unless ``MARCER_SMTP_HOST``, ``MARCER_MAIL_FROM`` and
``MARCER_MAIL_TO`` are set. A notification is only sent when a successful
full run reports at least one ``new`` or ``changed`` file.
"""
from __future__ import annotations

import os
import smtplib
from email.message import EmailMessage


def _env(environ: dict, name: str, default: str = "") -> str:
    return str(environ.get(name, default) or "").strip()


def _bool(value: str, default: bool = False) -> bool:
    if not value:
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


def smtp_settings(environ: dict | None = None) -> dict | None:
    env = os.environ if environ is None else environ
    host = _env(env, "MARCER_SMTP_HOST")
    if not host:
        return None
    user = _env(env, "MARCER_SMTP_USER")
    from_addr = _env(env, "MARCER_MAIL_FROM") or user
    to_addr = _env(env, "MARCER_MAIL_TO")
    if not from_addr or not to_addr:
        return None
    try:
        port = int(_env(env, "MARCER_SMTP_PORT", "587") or "587")
    except ValueError:
        port = 587
    use_ssl = _bool(_env(env, "MARCER_SMTP_SSL"), False)
    starttls = _bool(_env(env, "MARCER_SMTP_STARTTLS"), True) and not use_ssl
    return {
        "host": host,
        "port": port,
        "user": user,
        "password": _env(env, "MARCER_SMTP_PASS"),
        "from": from_addr,
        "to": to_addr,
        "ssl": use_ssl,
        "starttls": starttls,
    }


def _sync_counts(report: dict) -> tuple[int, int, dict]:
    sync = report.get("sync") if isinstance(report, dict) else None
    counts = sync.get("counts") if isinstance(sync, dict) else None
    if not isinstance(counts, dict):
        return 0, 0, {}
    try:
        new = int(counts.get("new", 0) or 0)
        changed = int(counts.get("changed", 0) or 0)
    except (TypeError, ValueError):
        return 0, 0, counts
    return new, changed, counts


def _body(report: dict, counts: dict) -> str:
    actions = report.get("actions") if isinstance(report, dict) else None
    if not isinstance(actions, dict):
        actions = {}
    publish = report.get("publish") if isinstance(report, dict) else None
    if not isinstance(publish, dict):
        publish = {}
    lines = [
        "Marcer catalog sync downloaded changes.",
        "",
        f"new:             {counts.get('new', 0)}",
        f"changed:         {counts.get('changed', 0)}",
        f"in sync:         {counts.get('in_sync', 0)}",
        f"local only:      {counts.get('local_only', 0)}",
        f"download errors: {counts.get('download_errors', 0)}",
        f"incomplete dirs: {counts.get('incomplete_dirs', 0)}",
        "",
        "steps:",
        f"  gameinfo:     {actions.get('gameinfo_extract')}",
        f"  full index:   {actions.get('full_index_run')}",
        f"  crews:        {actions.get('crew_analysis')}",
        f"  publish:      {publish.get('status', actions.get('publish'))}",
    ]
    started = report.get("started_at")
    finished = report.get("finished_at")
    if started or finished:
        lines.extend(["", f"started:  {started or '-'}", f"finished: {finished or '-'}"])
    return "\n".join(lines) + "\n"


def notify_sync_changes(
    report: dict | None, environ: dict | None = None
) -> str | None:
    """Send one notification if the report contains sync changes.

    Returns a short status string for the job log, or ``None`` when the
    notifier is disabled or there is nothing to report. Notification errors
    never fail the pipeline job.
    """
    settings = smtp_settings(environ)
    if settings is None or not isinstance(report, dict):
        return None
    new, changed, counts = _sync_counts(report)
    if new + changed <= 0:
        return None

    message = EmailMessage()
    message["From"] = settings["from"]
    message["To"] = settings["to"]
    message["Subject"] = f"Marcer catalog sync: {new} new, {changed} changed"
    message.set_content(_body(report, counts))

    try:
        if settings["ssl"]:
            server = smtplib.SMTP_SSL(
                settings["host"], settings["port"], timeout=30
            )
        else:
            server = smtplib.SMTP(
                settings["host"], settings["port"], timeout=30
            )
        with server:
            if settings["starttls"]:
                server.starttls()
            if settings["user"]:
                server.login(settings["user"], settings["password"])
            server.send_message(message)
    except (OSError, smtplib.SMTPException) as exc:
        return f"e-mail notification failed: {exc}"
    return f"e-mail notification sent to {settings['to']}"
