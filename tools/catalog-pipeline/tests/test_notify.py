# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
"""Unit tests for tools/catalog-pipeline/notify.py."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import notify

ENV = {
    "MARCER_SMTP_HOST": "smtp.example",
    "MARCER_SMTP_PORT": "587",
    "MARCER_SMTP_USER": "user",
    "MARCER_SMTP_PASS": "pass",
    "MARCER_MAIL_FROM": "pipeline@example",
    "MARCER_MAIL_TO": "admin@example",
}


class FakeSMTP:
    instances = []

    def __init__(self, host, port, timeout=None):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.started_tls = False
        self.logged_in = None
        self.message = None
        FakeSMTP.instances.append(self)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def starttls(self):
        self.started_tls = True

    def login(self, user, password):
        self.logged_in = (user, password)

    def send_message(self, message):
        self.message = message


class NotifyTests(unittest.TestCase):
    def setUp(self) -> None:
        FakeSMTP.instances.clear()

    def test_disabled_without_smtp_config(self) -> None:
        report = {"sync": {"counts": {"new": 1}}}
        self.assertIsNone(notify.notify_sync_changes(report, {}))

    def test_no_mail_without_changes(self) -> None:
        report = {"sync": {"counts": {"new": 0, "changed": 0}}}
        with mock.patch.object(notify.smtplib, "SMTP", FakeSMTP):
            self.assertIsNone(notify.notify_sync_changes(report, ENV))

    def test_mail_for_new_and_changed_files(self) -> None:
        report = {
            "sync": {"counts": {"new": 2, "changed": 1, "in_sync": 9}},
            "actions": {
                "gameinfo_extract": True,
                "full_index_run": True,
                "crew_analysis": False,
            },
            "publish": {"status": "uploaded"},
        }
        with mock.patch.object(notify.smtplib, "SMTP", FakeSMTP):
            result = notify.notify_sync_changes(report, ENV)
        self.assertIn("sent", result)
        smtp = FakeSMTP.instances[0]
        self.assertTrue(smtp.started_tls)
        self.assertEqual(smtp.logged_in, ("user", "pass"))
        self.assertIn("2 new", smtp.message["Subject"])
        self.assertIn("1 changed", smtp.message["Subject"])
        body = smtp.message.get_content()
        self.assertIn("new:             2", body)
        self.assertIn("publish:      uploaded", body)

    def test_smtp_error_is_reported_but_not_raised(self) -> None:
        class BrokenSMTP(FakeSMTP):
            def send_message(self, message):
                raise OSError("connection reset")

        report = {"sync": {"counts": {"new": 1}}}
        with mock.patch.object(notify.smtplib, "SMTP", BrokenSMTP):
            result = notify.notify_sync_changes(report, ENV)
        self.assertIn("failed", result)


if __name__ == "__main__":
    unittest.main()
