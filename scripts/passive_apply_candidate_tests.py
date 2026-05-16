#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import passive_apply_candidate as pac
import passive_control_report as pcr


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text("\n".join(json.dumps(row, sort_keys=True) for row in rows) + "\n")


def _row(index: int, delay: float = 2300.0) -> dict:
    return {
        "index": index,
        "verdict": "accepted",
        "delay_ms": delay,
        "current_delay_ms": 2200,
        "delay_locked": False,
        "context_signature": "ctx-a",
        "enabled_airplay_count": 1,
        "active_airplay_count": 1,
        "airplay_timing_epoch": 42,
        "sync_context_state": "suspect",
        "sync_context_revision": 7,
        "capture_backend": "tap",
        "sample": {
            "cycles": [
                {
                    "index": 1,
                    "capture": {
                        "sampleRate": 48000,
                        "microphoneFrames": 100,
                        "microphoneArmedAtNs": 1_000_000_000,
                        "microphoneFirstSampleAtNs": 1_000_000_000,
                        "microphoneStartPaddingFrames": 0,
                        "microphoneWarmupFramesDropped": 128,
                        "airplayTimingEpoch": 42,
                        "endAirplayTimingEpoch": 42,
                        "syncContextState": "suspect",
                        "syncContextRevision": 7,
                        "endSyncContextState": "suspect",
                        "endSyncContextRevision": 7,
                    },
                }
            ]
        },
    }


def _ready_session(
    root: Path,
    *,
    gate: dict | None = None,
    passive_apply_mode: str | None = None,
) -> Path:
    rows = [_row(1, 2300), _row(2, 2302), _row(3, 2301)]
    monitor = {
        "summary": {
            "verdict": "stable",
            "reason": None,
            "samples_total": 3,
            "samples_accepted": 3,
            "required_accepted": 2,
            "delay_range_ms": 2.0,
            "delay_end_to_start_ms": 1.0,
            "trailing_inconclusive_samples": 0,
            "context_gate": None,
        },
        "rows": rows,
    }
    manifest = {
        "schema": "syncast.passive_drift_session.v1",
        "emitsAudio": False,
        "appliesDelay": False,
        "opensMicrophoneOnlyAfterPreflight": True,
    }
    if passive_apply_mode is not None:
        manifest["passiveApplyMode"] = passive_apply_mode
    _write_json(root / "manifest.json", manifest)
    _write_json(root / "preflight.json", {"verdict": "preflight_ok"})
    _write_json(root / "monitor.json", monitor)
    _write_json(
        root / "summary.json",
        {
            "monitor_verdict": "stable",
            "sample_verdict_counts": {"accepted": 3},
            "samples_total": 3,
            "strong_peak_flag_count": 0,
            "multi_path_candidate_flag_count": 0,
        },
    )
    _write_json(
        root / "decision.json",
        {
            "verdict": "recommend",
            "auto_apply_eligible": True,
            "recommended_delay_ms": 2212,
        },
    )
    _write_json(
        root / "finalize.json",
        {
            "verdict": "decided",
            "auditVerdict": "ready_for_correction",
            "result": {
                "baseline": {
                    "key": "baseline-a",
                    "contextSignature": "ctx-a",
                    "captureBackend": "tap",
                    "delayLocked": False,
                    "enabledAirplayCount": 1,
                    "activeAirplayCount": 1,
                    "airplayTimingEpoch": 42,
                    "syncContextState": "suspect",
                    "syncContextRevision": 7,
                    "baselineOffsetMs": 88.0,
                },
                "decision": {
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2212,
                    "raw_correction_ms": 12.0,
                    "baseline_offset_ms": 88.0,
                    "features": {
                        "samples_accepted": 3,
                        "measured_delay_ms": 2301.0,
                        "current_delay_ms": 2200.0,
                        "delay_locked": False,
                        "observed_offset_ms": 101.0,
                        "delay_range_ms": 2.0,
                        "context_signature": "ctx-a",
                        "capture_backend": "tap",
                        "enabled_airplay_count": 1,
                        "active_airplay_count": 1,
                        "airplay_timing_epoch": 42,
                        "sync_context_state": "suspect",
                        "sync_context_revision": 7,
                    },
                },
            },
        },
    )
    _write_json(
        root / "correction_gate.json",
        gate
        or {
            "verdict": "ready_for_apply_candidate",
            "sessionRoot": str(root),
            "reason": "two passive recommendations agree",
            "baselineKey": "baseline-a",
            "recommendedDelayMs": 2212,
            "currentDelayMs": 2200,
            "contextSignature": "ctx-a",
            "delayLocked": False,
            "enabledAirplayCount": 1,
            "activeAirplayCount": 1,
            "airplayTimingEpoch": 42,
            "syncContextState": "suspect",
            "syncContextRevision": 7,
            "captureBackend": "tap",
            "emitsAudio": False,
            "appliesDelay": False,
        },
    )
    _write_jsonl(root / "samples.jsonl", rows)
    return root


class PassiveApplyCandidateTests(unittest.TestCase):
    def test_candidate_params_from_ready_session_default_dry_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            params = pac.candidate_params(_ready_session(Path(tmp)), dry_run=True)
        self.assertEqual(params["targetDelayMs"], 2212)
        self.assertEqual(params["currentDelayMs"], 2200)
        self.assertEqual(params["contextSignature"], "ctx-a")
        self.assertEqual(params["activeAirplayCount"], 1)
        self.assertEqual(params["airplayTimingEpoch"], 42)
        self.assertEqual(params["syncContextState"], "suspect")
        self.assertEqual(params["syncContextRevision"], 7)
        self.assertFalse(params["delayLocked"])
        self.assertTrue(params["dryRun"])

    def test_refuses_non_ready_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _ready_session(
                Path(tmp),
                gate={"verdict": "pending_confirmation", "recommendedDelayMs": 2212},
            )
            with self.assertRaisesRegex(RuntimeError, "not ready"):
                pac.candidate_params(root, dry_run=True)

    def test_refuses_gate_missing_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _ready_session(
                Path(tmp),
                gate={
                    "verdict": "ready_for_apply_candidate",
                    "recommendedDelayMs": 2212,
                    "currentDelayMs": 2200,
                },
            )
            with self.assertRaisesRegex(RuntimeError, "not ready"):
                pac.candidate_params(root, dry_run=True)

    def test_refuses_apply_when_dry_run_artifact_is_required_but_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _ready_session(Path(tmp), passive_apply_mode="dry-run")
            with self.assertRaisesRegex(RuntimeError, "not ready for apply"):
                pac.candidate_params(root, dry_run=False)

    def test_apply_candidate_dry_run_rpc(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _ready_session(Path(tmp))
            with mock.patch.object(
                pac,
                "_json_rpc",
                return_value={
                    "result": {
                        "applied": False,
                        "wouldApply": True,
                        "reason": "dry_run",
                        "targetDelayMs": 2212,
                        "currentDelayMs": 2200,
                        "contextSignature": "ctx-a",
                        "delayLocked": False,
                        "enabledAirplayCount": 1,
                        "activeAirplayCount": 1,
                        "airplayTimingEpoch": 42,
                        "syncContextState": "suspect",
                        "syncContextRevision": 7,
                        "captureBackend": "tap",
                    }
                },
            ) as rpc:
                result = pac.apply_candidate(
                    root,
                    socket_path=Path("/tmp/fake.sock"),
                    dry_run=True,
                )
        self.assertEqual(result["verdict"], "dry_run_ready")
        self.assertFalse(result["appliesDelay"])
        rpc.assert_called_once()
        self.assertTrue(rpc.call_args.args[2]["dryRun"])

    def test_apply_candidate_apply_rpc(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _ready_session(Path(tmp))
            with mock.patch.object(
                pac,
                "_json_rpc",
                return_value={
                    "result": {
                        "applied": True,
                        "wouldApply": True,
                        "reason": "passive_ready_candidate",
                        "targetDelayMs": 2212,
                        "currentDelayMs": 2200,
                        "contextSignature": "ctx-a",
                        "delayLocked": False,
                        "enabledAirplayCount": 1,
                        "activeAirplayCount": 1,
                        "airplayTimingEpoch": 42,
                        "syncContextState": "suspect",
                        "syncContextRevision": 7,
                        "captureBackend": "tap",
                        "appliedDelayMs": 2212,
                    }
                },
            ) as rpc:
                result = pac.apply_candidate(
                    root,
                    socket_path=Path("/tmp/fake.sock"),
                    dry_run=False,
                )
        self.assertEqual(result["verdict"], "applied")
        self.assertTrue(result["appliesDelay"])
        self.assertFalse(rpc.call_args.args[2]["dryRun"])

    def test_apply_candidate_rejects_positive_result_context_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _ready_session(Path(tmp))
            with mock.patch.object(
                pac,
                "_json_rpc",
                return_value={
                    "result": {
                        "applied": False,
                        "wouldApply": True,
                        "reason": "dry_run",
                        "targetDelayMs": 2212,
                        "currentDelayMs": 2200,
                        "contextSignature": "ctx-a",
                        "delayLocked": False,
                        "enabledAirplayCount": 1,
                        "activeAirplayCount": 1,
                        "airplayTimingEpoch": 42,
                        "syncContextState": "valid",
                        "syncContextRevision": 7,
                        "captureBackend": "tap",
                    }
                },
            ):
                with self.assertRaisesRegex(RuntimeError, "syncContextState"):
                    pac.apply_candidate(
                        root,
                        socket_path=Path("/tmp/fake.sock"),
                        dry_run=True,
                    )

    def test_apply_candidate_rejects_dry_run_result_that_applied_delay(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _ready_session(Path(tmp))
            with mock.patch.object(
                pac,
                "_json_rpc",
                return_value={
                    "result": {
                        "applied": True,
                        "wouldApply": True,
                        "reason": "dry_run",
                        "targetDelayMs": 2212,
                        "currentDelayMs": 2200,
                        "contextSignature": "ctx-a",
                        "delayLocked": False,
                        "enabledAirplayCount": 1,
                        "activeAirplayCount": 1,
                        "airplayTimingEpoch": 42,
                        "syncContextState": "suspect",
                        "syncContextRevision": 7,
                        "captureBackend": "tap",
                        "appliedDelayMs": 2212,
                    }
                },
            ):
                with self.assertRaisesRegex(RuntimeError, "applied"):
                    pac.apply_candidate(
                        root,
                        socket_path=Path("/tmp/fake.sock"),
                        dry_run=True,
                    )

    def test_apply_candidate_rejects_applied_delay_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _ready_session(Path(tmp))
            with mock.patch.object(
                pac,
                "_json_rpc",
                return_value={
                    "result": {
                        "applied": True,
                        "wouldApply": True,
                        "reason": "passive_ready_candidate",
                        "targetDelayMs": 2212,
                        "currentDelayMs": 2200,
                        "contextSignature": "ctx-a",
                        "delayLocked": False,
                        "enabledAirplayCount": 1,
                        "activeAirplayCount": 1,
                        "airplayTimingEpoch": 42,
                        "syncContextState": "suspect",
                        "syncContextRevision": 7,
                        "captureBackend": "tap",
                        "appliedDelayMs": 2213,
                    }
                },
            ):
                with self.assertRaisesRegex(RuntimeError, "appliedDelayMs"):
                    pac.apply_candidate(
                        root,
                        socket_path=Path("/tmp/fake.sock"),
                        dry_run=False,
                    )

    def test_apply_candidate_rejects_non_dry_run_would_apply_without_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _ready_session(Path(tmp))
            with mock.patch.object(
                pac,
                "_json_rpc",
                return_value={
                    "result": {
                        "applied": False,
                        "wouldApply": True,
                        "reason": "dry_run",
                        "targetDelayMs": 2212,
                        "currentDelayMs": 2200,
                        "contextSignature": "ctx-a",
                        "delayLocked": False,
                        "enabledAirplayCount": 1,
                        "activeAirplayCount": 1,
                        "airplayTimingEpoch": 42,
                        "syncContextState": "suspect",
                        "syncContextRevision": 7,
                        "captureBackend": "tap",
                    }
                },
            ):
                with self.assertRaisesRegex(RuntimeError, "wouldApply"):
                    pac.apply_candidate(
                        root,
                        socket_path=Path("/tmp/fake.sock"),
                        dry_run=False,
                    )

    def test_ready_session_to_apply_artifact_to_control_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _ready_session(Path(tmp), passive_apply_mode="dry-run")
            output = root / "passive_apply.json"
            with mock.patch.object(
                pac,
                "_json_rpc",
                return_value={
                    "result": {
                        "applied": False,
                        "wouldApply": True,
                        "reason": "dry_run",
                        "targetDelayMs": 2212,
                        "currentDelayMs": 2200,
                        "contextSignature": "ctx-a",
                        "delayLocked": False,
                        "enabledAirplayCount": 1,
                        "activeAirplayCount": 1,
                        "airplayTimingEpoch": 42,
                        "syncContextState": "suspect",
                        "syncContextRevision": 7,
                        "captureBackend": "tap",
                    }
                },
            ):
                result = pac.apply_candidate(
                    root,
                    socket_path=Path("/tmp/fake.sock"),
                    dry_run=True,
                )
            _write_json(output, result)
            report = pcr.build_report(root)
        self.assertEqual(result["verdict"], "dry_run_ready")
        self.assertEqual(report["verdict"], "dry_run_ready")
        self.assertEqual(report["phase"], "apply")
        self.assertFalse(report["appliesDelay"])


if __name__ == "__main__":
    unittest.main()
