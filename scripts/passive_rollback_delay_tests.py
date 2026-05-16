#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import unittest
from unittest import mock

import passive_rollback_delay as prd


def _status(**overrides) -> dict:
    payload = {
        "ok": True,
        "currentDelayMs": 2165,
        "contextSignature": "ctx-a",
        "delayLocked": False,
        "enabledAirplayCount": 1,
        "activeAirplayCount": 1,
        "airplayTimingEpoch": 42,
        "captureBackend": "tap",
        "syncContextState": "applied",
        "syncContextRevision": 9,
    }
    payload.update(overrides)
    return payload


def _result(**overrides) -> dict:
    payload = {
        "applied": True,
        "wouldApply": True,
        "targetDelayMs": 2145,
        "currentDelayMs": 2165,
        "contextSignature": "ctx-a",
        "delayLocked": False,
        "enabledAirplayCount": 1,
        "activeAirplayCount": 1,
        "airplayTimingEpoch": 42,
        "captureBackend": "tap",
        "syncContextState": "applied",
        "syncContextRevision": 9,
        "appliedDelayMs": 2145,
        "previousDelayMs": 2165,
        "reason": "passive_ready_candidate",
    }
    payload.update(overrides)
    return payload


class PassiveRollbackDelayTests(unittest.TestCase):
    def test_rollback_params_bind_current_applied_runtime(self):
        params = prd.rollback_params(
            _status(),
            target_delay_ms=2145,
            expected_current_delay_ms=2165,
            expected={
                "contextSignature": "ctx-a",
                "captureBackend": "tap",
                "enabledAirplayCount": 1,
                "activeAirplayCount": 1,
                "airplayTimingEpoch": 42,
                "syncContextRevision": 9,
            },
        )
        self.assertEqual(params["targetDelayMs"], 2145)
        self.assertEqual(params["currentDelayMs"], 2165)
        self.assertEqual(params["syncContextState"], "applied")
        self.assertEqual(params["syncContextRevision"], 9)
        self.assertEqual(params["activeAirplayCount"], 1)
        self.assertFalse(params["dryRun"])

    def test_rollback_rejects_changed_current_delay(self):
        with self.assertRaisesRegex(RuntimeError, "current delay mismatch"):
            prd.rollback_params(
                _status(currentDelayMs=2200),
                target_delay_ms=2145,
                expected_current_delay_ms=2165,
            )

    def test_rollback_rejects_non_applied_sync_context(self):
        with self.assertRaisesRegex(RuntimeError, "syncContextState=applied"):
            prd.rollback_params(
                _status(syncContextState="suspect"),
                target_delay_ms=2145,
                expected_current_delay_ms=2165,
            )

    def test_rollback_rejects_inactive_airplay(self):
        with self.assertRaisesRegex(RuntimeError, "AirPlay"):
            prd.rollback_params(
                _status(activeAirplayCount=0),
                target_delay_ms=2145,
                expected_current_delay_ms=2165,
            )

    def test_rollback_rejects_same_delay_changed_context(self):
        with self.assertRaisesRegex(RuntimeError, "contextSignature"):
            prd.rollback_params(
                _status(contextSignature="ctx-b"),
                target_delay_ms=2145,
                expected_current_delay_ms=2165,
                expected={
                    "contextSignature": "ctx-a",
                    "captureBackend": "tap",
                    "enabledAirplayCount": 1,
                    "activeAirplayCount": 1,
                    "airplayTimingEpoch": 42,
                    "syncContextRevision": 9,
                },
            )

    def test_rollback_rejects_same_delay_changed_epoch(self):
        with self.assertRaisesRegex(RuntimeError, "airplayTimingEpoch"):
            prd.rollback_params(
                _status(airplayTimingEpoch=43),
                target_delay_ms=2145,
                expected_current_delay_ms=2165,
                expected={
                    "contextSignature": "ctx-a",
                    "captureBackend": "tap",
                    "enabledAirplayCount": 1,
                    "activeAirplayCount": 1,
                    "airplayTimingEpoch": 42,
                    "syncContextRevision": 9,
                },
            )

    def test_rollback_calls_guarded_passive_apply_candidate(self):
        with mock.patch.object(
            prd.pce,
            "_json_rpc",
            return_value=_status(),
        ) as status_rpc, mock.patch.object(
            prd.pac,
            "_json_rpc",
            return_value={"result": _result()},
        ) as apply_rpc:
            payload = prd.rollback_delay(
                socket_path=Path("/tmp/sock"),
                target_delay_ms=2145,
                expected_current_delay_ms=2165,
                expected={
                    "contextSignature": "ctx-a",
                    "captureBackend": "tap",
                    "enabledAirplayCount": 1,
                    "activeAirplayCount": 1,
                    "airplayTimingEpoch": 42,
                    "syncContextRevision": 9,
                },
            )
        self.assertEqual(payload["verdict"], "rolled_back")
        self.assertTrue(payload["appliesDelay"])
        status_rpc.assert_called_once()
        self.assertEqual(apply_rpc.call_args.args[1], "passive_apply_candidate")
        self.assertFalse(apply_rpc.call_args.args[2]["dryRun"])

    def test_rollback_rejects_result_context_mismatch(self):
        with mock.patch.object(
            prd.pce,
            "_json_rpc",
            return_value=_status(),
        ), mock.patch.object(
            prd.pac,
            "_json_rpc",
            return_value={"result": _result(activeAirplayCount=0)},
        ):
            with self.assertRaisesRegex(RuntimeError, "activeAirplayCount"):
                prd.rollback_delay(
                    socket_path=Path("/tmp/sock"),
                    target_delay_ms=2145,
                    expected_current_delay_ms=2165,
                )


if __name__ == "__main__":
    unittest.main()
