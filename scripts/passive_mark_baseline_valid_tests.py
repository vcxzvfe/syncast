#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import passive_mark_baseline_valid as pmb


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
        "enabled_airplay_count": 2,
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


def _recorded_baseline_session(root: Path) -> Path:
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
    _write_json(
        root / "manifest.json",
        {
            "schema": "syncast.passive_drift_session.v1",
            "emitsAudio": False,
            "appliesDelay": False,
            "opensMicrophoneOnlyAfterPreflight": True,
        },
    )
    _write_json(
        root / "readiness.json",
        {
            "verdict": "ready",
            "activeAirplayCount": 2,
            "enabledAirplayCount": 2,
            "passiveEvidenceIntent": "baseline_required",
            "baselineRequired": True,
        },
    )
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
            "verdict": "initialize_baseline",
            "baseline_offset_ms": 101.0,
            "features": {
                "samples_accepted": 3,
                "measured_delay_ms": 2301.0,
                "current_delay_ms": 2200.0,
                "delay_locked": False,
                "observed_offset_ms": 101.0,
                "delay_range_ms": 2.0,
                "context_signature": "ctx-a",
                "capture_backend": "tap",
                "enabled_airplay_count": 2,
                "airplay_timing_epoch": 42,
                "sync_context_state": "suspect",
                "sync_context_revision": 7,
            },
        },
    )
    _write_json(
        root / "finalize.json",
        {
            "verdict": "recorded",
            "auditVerdict": "ready_for_baseline",
            "sessionRoot": str(root),
            "result": {
                "baseline": {
                    "key": "baseline-a",
                    "contextSignature": "ctx-a",
                    "captureBackend": "tap",
                    "delayLocked": False,
                    "enabledAirplayCount": 2,
                    "airplayTimingEpoch": 42,
                    "syncContextState": "suspect",
                    "syncContextRevision": 7,
                    "baselineOffsetMs": 101.0,
                    "measuredDelayMs": 2301.0,
                    "currentDelayMs": 2200,
                    "samplesAccepted": 3,
                    "delayRangeMs": 2.0,
                },
            },
        },
    )
    _write_jsonl(root / "samples.jsonl", rows)
    return root


def _dry_run_rpc_result(**overrides: object) -> dict:
    result = {
        "accepted": True,
        "applied": False,
        "dryRun": True,
        "reason": "ok",
        "currentDelayMs": 2200,
        "contextSignature": "ctx-a",
        "delayLocked": False,
        "enabledAirplayCount": 2,
        "activeAirplayCount": 2,
        "airplayTimingEpoch": 42,
        "captureBackend": "tap",
        "syncContextState": "suspect",
        "syncContextRevision": 7,
        "emitsAudio": False,
        "opensMicrophone": False,
        "appliesDelay": False,
    }
    result.update(overrides)
    return {"result": result}


def _marked_rpc_result(**overrides: object) -> dict:
    result = {
        "accepted": True,
        "applied": True,
        "dryRun": False,
        "reason": "passive baseline validated",
        "currentDelayMs": 2200,
        "contextSignature": "ctx-a",
        "delayLocked": False,
        "enabledAirplayCount": 2,
        "activeAirplayCount": 2,
        "airplayTimingEpoch": 42,
        "captureBackend": "tap",
        "previousSyncContextState": "suspect",
        "previousSyncContextRevision": 7,
        "syncContextState": "valid",
        "syncContextRevision": 8,
        "syncContextReason": "passive baseline validated",
        "syncContextUpdatedUnix": 1_778_924_578.0,
        "emitsAudio": False,
        "opensMicrophone": False,
        "appliesDelay": False,
    }
    result.update(overrides)
    return {"result": result}


class PassiveBaselineMarkTests(unittest.TestCase):
    def test_params_from_recorded_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _recorded_baseline_session(Path(tmp))
            params = pmb.baseline_mark_params(root, dry_run=True)
        self.assertEqual(params["currentDelayMs"], 2200)
        self.assertEqual(params["contextSignature"], "ctx-a")
        self.assertEqual(params["enabledAirplayCount"], 2)
        self.assertEqual(params["activeAirplayCount"], 2)
        self.assertEqual(params["airplayTimingEpoch"], 42)
        self.assertEqual(params["captureBackend"], "tap")
        self.assertEqual(params["syncContextState"], "suspect")
        self.assertEqual(params["syncContextRevision"], 7)
        self.assertTrue(params["dryRun"])

    def test_refuses_non_recorded_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _recorded_baseline_session(Path(tmp))
            (root / "finalize.json").unlink()
            with self.assertRaisesRegex(RuntimeError, "not ready"):
                pmb.baseline_mark_params(root, dry_run=True)

    def test_refuses_locked_recorded_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _recorded_baseline_session(Path(tmp))
            finalize = json.loads((root / "finalize.json").read_text())
            finalize["result"]["baseline"]["delayLocked"] = True
            _write_json(root / "finalize.json", finalize)
            with self.assertRaisesRegex(RuntimeError, "delay_locked"):
                pmb.baseline_mark_params(root, dry_run=True)

    def test_mark_baseline_dry_run_rpc(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _recorded_baseline_session(Path(tmp))
            with mock.patch.object(
                pmb,
                "_json_rpc",
                return_value=_dry_run_rpc_result(),
            ) as rpc:
                result = pmb.mark_baseline(
                    root,
                    socket_path=Path("/tmp/fake.sock"),
                    dry_run=True,
                )
        self.assertEqual(result["verdict"], "dry_run_ready")
        self.assertFalse(result["appliesDelay"])
        self.assertFalse(result["opensMicrophone"])
        rpc.assert_called_once()
        self.assertTrue(rpc.call_args.args[2]["dryRun"])

    def test_mark_baseline_dry_run_rejects_result_context_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _recorded_baseline_session(Path(tmp))
            with mock.patch.object(
                pmb,
                "_json_rpc",
                return_value=_dry_run_rpc_result(syncContextRevision=8),
            ):
                with self.assertRaisesRegex(RuntimeError, "syncContextRevision"):
                    pmb.mark_baseline(
                        root,
                        socket_path=Path("/tmp/fake.sock"),
                        dry_run=True,
                    )

    def test_mark_baseline_valid_rpc(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _recorded_baseline_session(Path(tmp))
            with mock.patch.object(
                pmb,
                "_json_rpc",
                return_value=_marked_rpc_result(),
            ) as rpc:
                result = pmb.mark_baseline(
                    root,
                    socket_path=Path("/tmp/fake.sock"),
                    dry_run=False,
                )
        self.assertEqual(result["verdict"], "marked_valid")
        self.assertFalse(result["appliesDelay"])
        self.assertFalse(rpc.call_args.args[2]["dryRun"])

    def test_mark_baseline_valid_rejects_previous_sync_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _recorded_baseline_session(Path(tmp))
            with mock.patch.object(
                pmb,
                "_json_rpc",
                return_value=_marked_rpc_result(previousSyncContextRevision=9),
            ):
                with self.assertRaisesRegex(
                    RuntimeError,
                    "previousSyncContextRevision",
                ):
                    pmb.mark_baseline(
                        root,
                        socket_path=Path("/tmp/fake.sock"),
                        dry_run=False,
                    )

    def test_mark_baseline_valid_rejects_non_advancing_revision(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _recorded_baseline_session(Path(tmp))
            with mock.patch.object(
                pmb,
                "_json_rpc",
                return_value=_marked_rpc_result(syncContextRevision=7),
            ):
                with self.assertRaisesRegex(RuntimeError, "syncContextRevision"):
                    pmb.mark_baseline(
                        root,
                        socket_path=Path("/tmp/fake.sock"),
                        dry_run=False,
                    )

    def test_mark_baseline_valid_rejects_applied_without_acceptance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _recorded_baseline_session(Path(tmp))
            with mock.patch.object(
                pmb,
                "_json_rpc",
                return_value=_marked_rpc_result(accepted=False),
            ):
                with self.assertRaisesRegex(RuntimeError, "accepted"):
                    pmb.mark_baseline(
                        root,
                        socket_path=Path("/tmp/fake.sock"),
                        dry_run=False,
                    )

    def test_runtime_rejection_is_recorded_not_marked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _recorded_baseline_session(Path(tmp))
            with mock.patch.object(
                pmb,
                "_json_rpc",
                return_value={
                    "result": {
                        "accepted": False,
                        "applied": False,
                        "dryRun": False,
                        "reason": "airplay_timing_epoch_changed",
                    }
                },
            ):
                result = pmb.mark_baseline(
                    root,
                    socket_path=Path("/tmp/fake.sock"),
                    dry_run=False,
                )
        self.assertEqual(result["verdict"], "not_marked")
        self.assertEqual(result["result"]["reason"], "airplay_timing_epoch_changed")


if __name__ == "__main__":
    unittest.main()
