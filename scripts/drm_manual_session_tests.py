#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import drm_manual_session as session
import drm_path_audit_tests as audit_fixtures


class DrmManualSessionTests(unittest.TestCase):
    def test_start_writes_passive_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "session"
            log = Path(tmp) / "launch.log"
            log.write_text("old\n")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                rc = session.main(
                    [
                        "start",
                        "--session-root",
                        str(root),
                        "--log",
                        str(log),
                        "--mode",
                        "direct-stereo",
                    ]
                )
            payload = json.loads(stdout.getvalue())
            manifest = json.loads((root / "manifest.json").read_text())
        self.assertEqual(rc, session.EXIT_OK)
        self.assertEqual(payload["verdict"], "started")
        self.assertEqual(manifest["schema"], session.SCHEMA)
        self.assertFalse(manifest["emitsAudio"])
        self.assertFalse(manifest["opensMicrophone"])
        self.assertFalse(manifest["changesRoutes"])
        self.assertFalse(manifest["appliesDelay"])

    def test_finish_audits_only_new_log_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "session"
            log = Path(tmp) / "launch.log"
            old = audit_fixtures.SCK_LOG
            log.write_text(old)
            with contextlib.redirect_stdout(io.StringIO()):
                session.main(
                    [
                        "start",
                        "--session-root",
                        str(root),
                        "--log",
                        str(log),
                        "--mode",
                        "direct-stereo",
                    ]
                )
            log.write_text(old + audit_fixtures.DIRECT_LOG)
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                rc = session.main(["finish", str(root)])
            payload = json.loads(stdout.getvalue())
            audit_path_exists = (root / "drm_audit.json").exists()
        self.assertEqual(rc, session.EXIT_OK)
        self.assertEqual(payload["verdict"], "pass")
        self.assertFalse(payload["forbidden"])
        self.assertTrue(audit_path_exists)

    def test_finish_is_inconclusive_without_new_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "session"
            log = Path(tmp) / "launch.log"
            log.write_text("old\n")
            with contextlib.redirect_stdout(io.StringIO()):
                session.main(
                    [
                        "start",
                        "--session-root",
                        str(root),
                        "--log",
                        str(log),
                        "--mode",
                        "direct-stereo",
                    ]
                )
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                rc = session.main(["finish", str(root)])
            payload = json.loads(stdout.getvalue())
        self.assertEqual(rc, session.EXIT_INCONCLUSIVE)
        self.assertEqual(payload["verdict"], "inconclusive")

    def test_finish_rejects_missing_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                rc = session.main(["finish", tmp])
        self.assertEqual(rc, session.EXIT_BAD_INPUT)
        self.assertIn("manifest.json", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
