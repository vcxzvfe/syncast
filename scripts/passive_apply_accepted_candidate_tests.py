#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import time
import unittest
from unittest import mock

import passive_apply_accepted_candidate as paac


def _readiness(**overrides) -> dict:
    payload = {
        "verdict": "ready",
        "syncContextState": "dryRunReady",
        "passiveEvidenceIntent": "manual_validation_required",
        "passiveDryRunTargetDelayMs": 2165,
        "passiveDryRunCurrentDelayMs": 2145,
        "passiveDryRunContextSignature": "ctx-a",
        "passiveDryRunCaptureBackend": "tap",
        "passiveDryRunEnabledAirplayCount": 1,
        "passiveDryRunActiveAirplayCount": 1,
        "passiveDryRunAirplayTimingEpoch": 42,
        "passiveDryRunAcceptedSyncContextRevision": 8,
        "passiveDryRunAcceptedUnix": time.time(),
        "passiveDryRunSessionRoot": "/tmp/passive-session",
        "passiveDryRunControlReport": "/tmp/passive-session/control_report.json",
    }
    payload.update(overrides)
    return payload


def _positive_result(**overrides) -> dict:
    payload = {
        "wouldApply": True,
        "applied": False,
        "targetDelayMs": 2165,
        "currentDelayMs": 2145,
        "contextSignature": "ctx-a",
        "captureBackend": "tap",
        "enabledAirplayCount": 1,
        "activeAirplayCount": 1,
        "airplayTimingEpoch": 42,
        "syncContextRevision": 8,
        "reason": "accepted_candidate_dry_run",
    }
    payload.update(overrides)
    return payload


class PassiveApplyAcceptedCandidateTests(unittest.TestCase):
    def test_build_params_binds_full_accepted_candidate_context(self):
        params = paac.build_params(_readiness(), dry_run=True)
        self.assertEqual(params["targetDelayMs"], 2165)
        self.assertEqual(params["currentDelayMs"], 2145)
        self.assertEqual(params["contextSignature"], "ctx-a")
        self.assertEqual(params["captureBackend"], "tap")
        self.assertEqual(params["enabledAirplayCount"], 1)
        self.assertEqual(params["activeAirplayCount"], 1)
        self.assertEqual(params["airplayTimingEpoch"], 42)
        self.assertEqual(params["acceptedSyncContextRevision"], 8)
        self.assertIn("acceptedUnix", params)
        self.assertTrue(params["dryRun"])

    def test_build_params_requires_dry_run_ready_context(self):
        with self.assertRaisesRegex(RuntimeError, "syncContextState=dryRunReady"):
            paac.build_params(_readiness(syncContextState="valid"), dry_run=True)

    def test_build_params_requires_manual_validation_intent(self):
        with self.assertRaisesRegex(RuntimeError, "manual_validation_required"):
            paac.build_params(
                _readiness(passiveEvidenceIntent="drift_monitor"),
                dry_run=True,
            )

    def test_build_params_requires_active_airplay_count(self):
        with self.assertRaisesRegex(ValueError, "passiveDryRunActiveAirplayCount"):
            paac.build_params(
                _readiness(passiveDryRunActiveAirplayCount=None),
                dry_run=True,
            )

    def test_build_params_requires_accepted_timestamp(self):
        with self.assertRaisesRegex(ValueError, "passiveDryRunAcceptedUnix"):
            paac.build_params(
                _readiness(passiveDryRunAcceptedUnix=None),
                dry_run=True,
            )

    def test_build_params_rejects_expired_accepted_candidate(self):
        stale = time.time() - paac.ACCEPTED_DRY_RUN_MAX_AGE_SEC - 1
        with self.assertRaisesRegex(RuntimeError, "expired"):
            paac.build_params(
                _readiness(passiveDryRunAcceptedUnix=stale),
                dry_run=True,
            )

    def test_dry_run_calls_accepted_candidate_rpc_without_delay_write(self):
        with mock.patch.object(
            paac.pce,
            "_json_rpc",
            return_value={"result": _positive_result()},
        ) as rpc:
            payload = paac.apply_accepted_candidate(
                readiness=_readiness(),
                socket_path=Path("/tmp/sock"),
                dry_run=True,
            )
        self.assertEqual(payload["verdict"], "dry_run_ready")
        self.assertFalse(payload["appliesDelay"])
        rpc.assert_called_once()
        self.assertEqual(rpc.call_args.args[1], "passive_apply_accepted_candidate")
        self.assertTrue(rpc.call_args.args[2]["dryRun"])
        self.assertEqual(rpc.call_args.args[2]["activeAirplayCount"], 1)

    def test_expected_readiness_identity_blocks_stale_candidate(self):
        with mock.patch.object(
            paac.pce,
            "_json_rpc",
            return_value={"result": _positive_result()},
        ) as rpc:
            with self.assertRaisesRegex(RuntimeError, "passiveDryRunSessionRoot"):
                paac.apply_accepted_candidate(
                    readiness=_readiness(
                        passiveDryRunSessionRoot="/tmp/other-session",
                    ),
                    socket_path=Path("/tmp/sock"),
                    dry_run=False,
                    expected={
                        "passiveDryRunSessionRoot": "/tmp/passive-session",
                        "passiveDryRunControlReport": (
                            "/tmp/passive-session/control_report.json"
                        ),
                        "passiveDryRunTargetDelayMs": 2165,
                        "passiveDryRunCurrentDelayMs": 2145,
                        "passiveDryRunContextSignature": "ctx-a",
                        "passiveDryRunCaptureBackend": "tap",
                        "passiveDryRunEnabledAirplayCount": 1,
                        "passiveDryRunActiveAirplayCount": 1,
                        "passiveDryRunAirplayTimingEpoch": 42,
                        "passiveDryRunAcceptedSyncContextRevision": 8,
                        "passiveDryRunAcceptedUnix": _readiness()[
                            "passiveDryRunAcceptedUnix"
                        ],
                    },
                )
        rpc.assert_not_called()

    def test_apply_mode_marks_delay_write_only_when_rpc_applied(self):
        with mock.patch.object(
            paac.pce,
            "_json_rpc",
            return_value={
                "result": _positive_result(
                    applied=True,
                    appliedDelayMs=2165,
                    reason="accepted_passive_candidate",
                )
            },
        ):
            payload = paac.apply_accepted_candidate(
                readiness=_readiness(),
                socket_path=Path("/tmp/sock"),
                dry_run=False,
            )
        self.assertEqual(payload["verdict"], "applied")
        self.assertTrue(payload["appliesDelay"])
        self.assertFalse(payload["emitsAudio"])
        self.assertFalse(payload["opensMicrophone"])

    def test_positive_result_mismatch_rejects_active_airplay_count(self):
        with mock.patch.object(
            paac.pce,
            "_json_rpc",
            return_value={"result": _positive_result(activeAirplayCount=0)},
        ):
            with self.assertRaisesRegex(RuntimeError, "activeAirplayCount"):
                paac.apply_accepted_candidate(
                    readiness=_readiness(),
                    socket_path=Path("/tmp/sock"),
                    dry_run=True,
                )


if __name__ == "__main__":
    unittest.main()
