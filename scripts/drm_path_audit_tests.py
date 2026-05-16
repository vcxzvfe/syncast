#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import drm_path_audit as audit


DIRECT_LOG = """\
screen-recording preflight skipped: Direct Stereo active
INITIAL_MODE env: stereo
AUTO_TEST: selected display,mbp
reconcile: starting router (Direct Stereo)
reconcile: router.start OK
capture report @ 1.0s driver=directStereo directStereo=aggregate uids=2
"""

TAP_LOG = """\
screen-recording status: not required (Process Tap capture)
screen-recording preflight skipped: capture=tap
reconcile: starting router (Process Tap capture)
reconcile: router.start OK
capture report @ 1.0s backend=tap seen=12 written=12 ticks=12 peak=0.001/0.004
"""

SCK_LOG = """\
screen-recording preflight: checking permission
requesting screen-recording access
reconcile: starting router (SCK capture)
SCKCapture started
"""

SCK_BACKEND_ONLY_LOG = """\
reconcile: router.start OK
capture report @ 4.0s backend=sck seen=120 written=120 ticks=120 peak=0.002/0.003
"""


class DrmPathAuditTests(unittest.TestCase):
    def test_direct_stereo_passes_without_sck(self):
        result = audit.audit_log(
            DIRECT_LOG,
            mode="direct-stereo",
            require_tap_audio=False,
        )
        self.assertEqual(result["verdict"], "pass")
        self.assertTrue(result["direct"]["direct_driver"])
        self.assertFalse(result["forbidden"])

    def test_tap_passes_with_audio_counters_when_required(self):
        result = audit.audit_log(TAP_LOG, mode="tap", require_tap_audio=True)
        self.assertEqual(result["verdict"], "pass")
        self.assertEqual(result["tap_counters"]["seen"], 12)
        self.assertGreater(result["tap_counters"]["peak"], 0)

    def test_forbidden_sck_evidence_fails_even_with_direct_evidence(self):
        result = audit.audit_log(
            DIRECT_LOG + SCK_LOG,
            mode="direct-stereo",
            require_tap_audio=False,
        )
        self.assertEqual(result["verdict"], "fail")
        self.assertIn("sck_start", result["forbidden"])
        self.assertIn("screen_recording_request", result["forbidden"])

    def test_backend_sck_capture_report_is_forbidden(self):
        result = audit.audit_log(
            DIRECT_LOG + SCK_BACKEND_ONLY_LOG,
            mode="direct-stereo",
            require_tap_audio=False,
        )
        self.assertEqual(result["verdict"], "fail")
        self.assertIn("sck_backend", result["forbidden"])

    def test_no_evidence_is_inconclusive(self):
        result = audit.audit_log("hello\n", mode="no-sck", require_tap_audio=False)
        self.assertEqual(result["verdict"], "inconclusive")
        self.assertIn("no complete", result["reason"])

    def test_since_offset_ignores_old_forbidden_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "launch.log"
            old = SCK_LOG
            path.write_text(old + DIRECT_LOG)
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                rc = audit.main(
                    [
                        "--log",
                        str(path),
                        "--since-offset",
                        str(len(old.encode("utf-8"))),
                        "--mode",
                        "direct-stereo",
                        "--json",
                    ]
                )
        self.assertEqual(rc, audit.EXIT_OK)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["verdict"], "pass")
        self.assertFalse(payload["forbidden"])


if __name__ == "__main__":
    unittest.main()
