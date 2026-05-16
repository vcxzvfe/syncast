#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import passive_correction_gate as pcg


def _finalize(
    *,
    verdict: str = "decided",
    decision_verdict: str = "recommend",
    eligible: bool = True,
    recommended: int = 2218,
    correction: float = 18.0,
    current_delay: float = 2200.0,
    key: str = "baseline-a",
    session_root: str = "/tmp/session",
    context_signature: str = "ctx-a",
    capture_backend: str = "tap",
    delay_locked: bool = False,
    enabled_airplay_count: int = 1,
    active_airplay_count: int = 1,
    airplay_timing_epoch: int = 42,
    sync_context_state: str = "valid",
    sync_context_revision: int = 8,
    decision_sync_context_state: str | None = None,
    decision_sync_context_revision: int | None = None,
) -> dict:
    if decision_sync_context_state is None:
        decision_sync_context_state = sync_context_state
    if decision_sync_context_revision is None:
        decision_sync_context_revision = sync_context_revision
    return {
        "verdict": verdict,
        "sessionRoot": session_root,
        "result": {
            "baseline": {
                "key": key,
                "contextSignature": context_signature,
                "captureBackend": capture_backend,
                "delayLocked": delay_locked,
                "enabledAirplayCount": enabled_airplay_count,
                "activeAirplayCount": active_airplay_count,
                "airplayTimingEpoch": airplay_timing_epoch,
                "syncContextState": sync_context_state,
                "syncContextRevision": sync_context_revision,
            },
            "decision": {
                "verdict": decision_verdict,
                "auto_apply_eligible": eligible,
                "recommended_delay_ms": recommended,
                "raw_correction_ms": correction,
                "features": {
                    "current_delay_ms": current_delay,
                    "context_signature": context_signature,
                    "capture_backend": capture_backend,
                    "delay_locked": delay_locked,
                    "enabled_airplay_count": enabled_airplay_count,
                    "active_airplay_count": active_airplay_count,
                    "airplay_timing_epoch": airplay_timing_epoch,
                    "sync_context_state": decision_sync_context_state,
                    "sync_context_revision": decision_sync_context_revision,
                },
            },
        },
    }


class PassiveCorrectionGateTests(unittest.TestCase):
    def test_first_recommendation_records_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            result = pcg.evaluate(
                finalize_payload=_finalize(),
                state_path=state,
            )
            payload = json.loads(state.read_text())
        self.assertEqual(result["verdict"], "pending_confirmation")
        self.assertIn("baseline-a", payload["pending"])
        self.assertFalse(result["appliesDelay"])

    def test_second_matching_recommendation_is_apply_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2218,
                    session_root="/tmp/session-a",
                ),
                state_path=state,
            )
            result = pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2221,
                    session_root="/tmp/session-b",
                ),
                state_path=state,
                max_repeat_delta_ms=8,
            )
            payload = json.loads(state.read_text())
        self.assertEqual(result["verdict"], "ready_for_apply_candidate")
        self.assertEqual(result["recommendedDelayMs"], 2221)
        self.assertEqual(result["repeatDeltaMs"], 3)
        self.assertEqual(result["activeAirplayCount"], 1)
        self.assertEqual(result["airplayTimingEpoch"], 42)
        self.assertFalse(result["delayLocked"])
        self.assertNotIn("baseline-a", payload["pending"])

    def test_gate_uses_current_decision_sync_context_not_recorded_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2218,
                    session_root="/tmp/session-a",
                    sync_context_state="suspect",
                    sync_context_revision=7,
                    decision_sync_context_state="valid",
                    decision_sync_context_revision=8,
                ),
                state_path=state,
            )
            result = pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2221,
                    session_root="/tmp/session-b",
                    sync_context_state="suspect",
                    sync_context_revision=7,
                    decision_sync_context_state="valid",
                    decision_sync_context_revision=8,
                ),
                state_path=state,
                max_repeat_delta_ms=8,
            )
        self.assertEqual(result["verdict"], "ready_for_apply_candidate")
        self.assertEqual(result["syncContextState"], "valid")
        self.assertEqual(result["syncContextRevision"], 8)

    def test_suspect_sync_context_is_not_apply_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            result = pcg.evaluate(
                finalize_payload=_finalize(
                    sync_context_state="suspect",
                    sync_context_revision=7,
                    decision_sync_context_state="suspect",
                    decision_sync_context_revision=7,
                ),
                state_path=state,
            )
        self.assertEqual(result["verdict"], "not_applicable")
        self.assertFalse(state.exists())

    def test_replaying_same_finalize_does_not_confirm(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            payload = _finalize(recommended=2218, session_root="/tmp/session-a")
            pcg.evaluate(finalize_payload=payload, state_path=state)
            result = pcg.evaluate(
                finalize_payload=payload,
                state_path=state,
                max_repeat_delta_ms=8,
            )
            state_payload = json.loads(state.read_text())
        self.assertEqual(result["verdict"], "pending_confirmation")
        self.assertIn("baseline-a", state_payload["pending"])

    def test_different_direction_replaces_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2218,
                    correction=18,
                    session_root="/tmp/session-a",
                ),
                state_path=state,
            )
            result = pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2184,
                    correction=-16,
                    session_root="/tmp/session-b",
                ),
                state_path=state,
            )
            payload = json.loads(state.read_text())
        self.assertEqual(result["verdict"], "pending_confirmation")
        self.assertEqual(payload["pending"]["baseline-a"]["direction"], -1)

    def test_too_far_recommendation_stays_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2218,
                    session_root="/tmp/session-a",
                ),
                state_path=state,
            )
            result = pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2250,
                    session_root="/tmp/session-b",
                ),
                state_path=state,
                max_repeat_delta_ms=8,
            )
        self.assertEqual(result["verdict"], "pending_confirmation")
        self.assertEqual(result["recommendedDelayMs"], 2250)

    def test_changed_current_delay_replaces_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            pcg.evaluate(
                finalize_payload=_finalize(
                    current_delay=2200,
                    recommended=2218,
                    session_root="/tmp/session-a",
                ),
                state_path=state,
            )
            result = pcg.evaluate(
                finalize_payload=_finalize(
                    current_delay=2210,
                    recommended=2219,
                    session_root="/tmp/session-b",
                ),
                state_path=state,
            )
            payload = json.loads(state.read_text())
        self.assertEqual(result["verdict"], "pending_confirmation")
        self.assertEqual(payload["pending"]["baseline-a"]["currentDelayMs"], 2210)

    def test_changed_context_replaces_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2218,
                    session_root="/tmp/session-a",
                    airplay_timing_epoch=42,
                ),
                state_path=state,
            )
            result = pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2220,
                    session_root="/tmp/session-b",
                    airplay_timing_epoch=43,
                ),
                state_path=state,
                max_repeat_delta_ms=8,
            )
            payload = json.loads(state.read_text())
        self.assertEqual(result["verdict"], "pending_confirmation")
        self.assertEqual(payload["pending"]["baseline-a"]["airplayTimingEpoch"], 43)

    def test_changed_active_airplay_count_replaces_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2218,
                    session_root="/tmp/session-a",
                    enabled_airplay_count=2,
                    active_airplay_count=2,
                ),
                state_path=state,
            )
            result = pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2220,
                    session_root="/tmp/session-b",
                    enabled_airplay_count=1,
                    active_airplay_count=1,
                ),
                state_path=state,
                max_repeat_delta_ms=8,
            )
            payload = json.loads(state.read_text())
        self.assertEqual(result["verdict"], "pending_confirmation")
        self.assertEqual(payload["pending"]["baseline-a"]["activeAirplayCount"], 1)

    def test_inactive_airplay_finalize_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            with self.assertRaisesRegex(ValueError, "AirPlay receivers are inactive"):
                pcg.evaluate(
                    finalize_payload=_finalize(
                        enabled_airplay_count=2,
                        active_airplay_count=1,
                    ),
                    state_path=state,
                )

    def test_locked_delay_finalize_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2218,
                    session_root="/tmp/session-a",
                    delay_locked=False,
                ),
                state_path=state,
            )
            with self.assertRaisesRegex(ValueError, "delay lock"):
                pcg.evaluate(
                    finalize_payload=_finalize(
                        recommended=2220,
                        session_root="/tmp/session-b",
                        delay_locked=True,
                    ),
                    state_path=state,
                    max_repeat_delta_ms=8,
                )

    def test_expired_pending_is_not_apply_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2218,
                    session_root="/tmp/session-a",
                ),
                state_path=state,
            )
            payload = json.loads(state.read_text())
            payload["pending"]["baseline-a"]["createdUnix"] = 1
            state.write_text(json.dumps(payload))
            result = pcg.evaluate(
                finalize_payload=_finalize(
                    recommended=2220,
                    session_root="/tmp/session-b",
                ),
                state_path=state,
                max_pending_age_sec=0.0,
            )
        self.assertEqual(result["verdict"], "pending_confirmation")

    def test_ineligible_finalize_clears_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            pcg.evaluate(finalize_payload=_finalize(), state_path=state)
            result = pcg.evaluate(
                finalize_payload=_finalize(decision_verdict="hold", eligible=False),
                state_path=state,
            )
            payload = json.loads(state.read_text())
        self.assertEqual(result["verdict"], "not_applicable")
        self.assertEqual(payload["pending"], {})

    def test_not_applicable_finalize_clears_all_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            pcg.evaluate(finalize_payload=_finalize(), state_path=state)
            result = pcg.evaluate(
                finalize_payload={
                    "verdict": "not_applicable",
                    "error": "passive delay decision refuses locked manual delay state",
                },
                state_path=state,
            )
            payload = json.loads(state.read_text())
        self.assertEqual(result["verdict"], "not_applicable")
        self.assertEqual(payload["pending"], {})

    def test_cli_output_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            finalize = Path(tmp) / "finalize.json"
            state = Path(tmp) / "state.json"
            output = Path(tmp) / "gate.json"
            finalize.write_text(json.dumps(_finalize()))
            old_parse = pcg._parse_args
            try:
                pcg._parse_args = lambda: type(
                    "Args",
                    (),
                    {
                        "finalize_json": finalize,
                        "state": state,
                        "output": output,
                        "max_repeat_delta_ms": 8,
                        "max_pending_age_sec": 1800,
                    },
                )()
                with mock.patch.object(sys, "stdout"):
                    rc = pcg.main()
            finally:
                pcg._parse_args = old_parse
            self.assertEqual(rc, pcg.EXIT_NOT_READY)
            self.assertEqual(
                json.loads(output.read_text())["verdict"],
                "pending_confirmation",
            )


if __name__ == "__main__":
    unittest.main()
