#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import passive_session_audit as psa


def _row(index: int, delay: float = 2300.0) -> dict:
    return {
        "index": index,
        "verdict": "accepted",
        "delay_ms": delay,
        "current_delay_ms": 2200,
        "context_signature": "ctx-a",
        "enabled_airplay_count": 1,
        "airplay_timing_epoch": 1,
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
                        "airplayTimingEpoch": 1,
                        "endAirplayTimingEpoch": 1,
                        "syncContextState": "suspect",
                        "syncContextRevision": 7,
                        "endSyncContextState": "suspect",
                        "endSyncContextRevision": 7,
                    },
                }
            ]
        },
    }


def _monitor(verdict: str = "stable") -> dict:
    rows = [_row(1, 2300.0), _row(2, 2302.0), _row(3, 2299.0)]
    return {
        "summary": {
            "verdict": verdict,
            "reason": None if verdict == "stable" else "not stable",
            "samples_total": len(rows),
            "samples_accepted": len(rows) if verdict == "stable" else 1,
            "required_accepted": 2,
            "delay_range_ms": 3.0 if verdict == "stable" else None,
            "delay_end_to_start_ms": -1.0 if verdict == "stable" else None,
            "trailing_inconclusive_samples": 0,
            "context_gate": None,
        },
        "rows": rows,
    }


def _summary(**overrides) -> dict:
    result = {
        "monitor_verdict": "stable",
        "sample_verdict_counts": {"accepted": 3},
        "samples_total": 3,
        "strong_peak_flag_count": 0,
        "multi_path_candidate_flag_count": 0,
    }
    result.update(overrides)
    return result


def _write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text("\n".join(json.dumps(row, sort_keys=True) for row in rows) + "\n")


def _session(tmp: str, *, decision: dict | None = None) -> Path:
    root = Path(tmp)
    monitor = _monitor()
    _write_json(
        root / "manifest.json",
        {
            "schema": "syncast.passive_drift_session.v1",
            "emitsAudio": False,
            "appliesDelay": False,
            "opensMicrophoneOnlyAfterPreflight": True,
        },
    )
    _write_json(root / "preflight.json", {"verdict": "preflight_ok"})
    _write_json(root / "monitor.json", monitor)
    _write_json(root / "summary.json", _summary())
    _write_json(
        root / "decision.json",
        decision
        or {
            "verdict": "initialize_baseline",
            "auto_apply_eligible": False,
            "baseline_offset_ms": 100.0,
            "reason": "baseline",
        },
    )
    _write_jsonl(root / "samples.jsonl", monitor["rows"])
    return root


def _manifest_with_capture_preflight() -> dict:
    return {
        "schema": "syncast.passive_drift_session.v1",
        "emitsAudio": False,
        "appliesDelay": False,
        "opensMicrophoneOnlyAfterPreflight": True,
        "workflow": ["preflight", "capture_preflight", "monitor"],
        "artifacts": {
            "capturePreflight": "capture_preflight.json",
            "preflight": "preflight.json",
        },
    }


def _manifest_with_auto_start() -> dict:
    return {
        "schema": "syncast.passive_drift_session.v1",
        "emitsAudio": False,
        "appliesDelay": False,
        "opensMicrophoneOnlyAfterPreflight": True,
        "autoStartTargets": "display,xiaomi",
        "launchesApp": True,
        "appWasRunningBeforeAutoStart": False,
        "changesRoutes": True,
        "changesLaunchEnvironment": True,
        "mayChangeDefaultOutput": True,
        "changesDefaultOutput": False,
        "defaultOutputReport": "  default : id\tuid\tDisplay",
        "autoStartSideEffectsUpdated": True,
        "autoStartAcousticSetupCompleted": True,
        "workflow": [
            "auto_start_setup_if_requested",
            "auto_start_capture_preflight_if_requested",
            "auto_start_preflight_if_requested",
            "capture_preflight",
            "preflight",
            "monitor",
        ],
        "artifacts": {
            "autoStartSetup": "auto_start_setup.json",
            "autoStartCapturePreflight": "auto_start_capture_preflight.json",
            "autoStartPreflight": "auto_start_preflight.json",
            "capturePreflight": "capture_preflight.json",
            "preflight": "preflight.json",
        },
    }


class PassiveSessionAuditTests(unittest.TestCase):
    def test_ready_for_baseline_when_all_artifacts_agree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "ready_for_baseline")
        self.assertEqual(result["phase"], "decision")
        self.assertTrue(result["checklist"]["jsonl_matches_monitor_rows"])
        self.assertTrue(result["checklist"]["manifest_no_audio"])
        self.assertTrue(result["checklist"]["manifest_no_delay_write"])
        self.assertTrue(result["checklist"]["manifest_mic_after_preflight"])
        self.assertEqual(result["monitor_rows"], 3)

    def test_ready_for_correction_when_decision_is_eligible(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                tmp,
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2218,
                    "reason": "small correction",
                },
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "ready_for_correction")

    def test_hold_is_successful_audit_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                tmp,
                decision={
                    "verdict": "hold",
                    "auto_apply_eligible": False,
                    "reason": "inside deadband",
                },
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "hold")
        self.assertEqual(psa._exit_code(result["verdict"]), psa.EXIT_OK)

    def test_rejects_multipath_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            _write_json(root / "summary.json", _summary(strong_peak_flag_count=1))
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "not_applicable")
        self.assertIn("multi-peak", result["reason"])

    def test_allows_multipath_summary_when_decision_uses_coherent_path_pair(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                tmp,
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2218,
                    "reason": "coherent path-pair",
                    "decision_basis": "coherent_path_pair_relative",
                },
            )
            _write_json(
                root / "summary.json",
                _summary(
                    strong_peak_flag_count=1,
                    multi_path_candidate_flag_count=1,
                ),
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "ready_for_correction")

    def test_rejects_path_pair_recommendation_without_relative_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                tmp,
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2218,
                    "reason": "coherent path-pair",
                    "decision_basis": "coherent_path_pair_absolute",
                },
            )
            _write_json(
                root / "summary.json",
                _summary(
                    strong_peak_flag_count=1,
                    multi_path_candidate_flag_count=1,
                ),
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "not_applicable")
        self.assertIn("multi-peak", result["reason"])

    def test_unexpected_preflight_verdict_fails_closed_despite_stale_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            _write_json(
                root / "preflight.json",
                {"verdict": "not_ready", "reason": "router unavailable"},
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "not_applicable")
        self.assertEqual(result["phase"], "preflight")
        self.assertIn("not_ready", result["reason"])

    def test_unexpected_capture_preflight_verdict_blocks_stale_downstream(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            manifest = _manifest_with_capture_preflight()
            _write_json(root / "manifest.json", manifest)
            _write_json(
                root / "capture_preflight.json",
                {"verdict": "not_ready", "reason": "route not ready"},
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "not_applicable")
        self.assertEqual(result["phase"], "capture_preflight")
        self.assertIn("not_ready", result["reason"])

    def test_summary_monitor_verdict_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            _write_json(root / "summary.json", _summary(monitor_verdict="unstable"))
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "not_applicable")
        self.assertEqual(result["phase"], "summary")
        self.assertIn("summary monitor_verdict mismatch", result["reason"])

    def test_capture_failed_preflight_stops_at_preflight_phase(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
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
                root / "preflight.json",
                {
                    "summary": {
                        "verdict": "capture_failed",
                        "reason": "socket blocked",
                    },
                    "rows": [],
                },
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "capture_failed")
        self.assertEqual(result["phase"], "preflight")
        self.assertIn("socket blocked", result["reason"])
        self.assertFalse(any("missing monitor.json" in issue for issue in result["issues"]))
        self.assertFalse(any("missing samples.jsonl" in issue for issue in result["issues"]))

    def test_capture_failed_capture_preflight_stops_before_drift_preflight(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_json(root / "manifest.json", _manifest_with_capture_preflight())
            _write_json(
                root / "capture_preflight.json",
                {
                    "verdict": "capture_failed",
                    "error": "socket missing",
                },
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "capture_failed")
        self.assertEqual(result["phase"], "capture_preflight")
        self.assertEqual(result["capture_preflight_verdict"], "capture_failed")
        self.assertIn("socket missing", result["reason"])
        self.assertFalse(any("missing preflight.json" in issue for issue in result["issues"]))
        self.assertFalse(any("missing monitor.json" in issue for issue in result["issues"]))

    def test_missing_required_capture_preflight_is_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_json(root / "manifest.json", _manifest_with_capture_preflight())
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "incomplete")
        self.assertEqual(result["phase"], "capture_preflight")
        self.assertIn("missing capture_preflight.json", result["issues"])

    def test_auto_start_capture_failed_stops_before_normal_preflight(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_json(root / "manifest.json", _manifest_with_auto_start())
            _write_json(root / "auto_start_setup.json", {"verdict": "preflight_ok"})
            _write_json(
                root / "auto_start_capture_preflight.json",
                {
                    "verdict": "capture_failed",
                    "error": "auto-start socket missing",
                },
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "capture_failed")
        self.assertEqual(result["phase"], "auto_start_capture_preflight")
        self.assertEqual(
            result["auto_start_capture_preflight_verdict"],
            "capture_failed",
        )
        self.assertIn("auto-start socket missing", result["reason"])
        self.assertFalse(any("missing capture_preflight.json" in issue for issue in result["issues"]))
        self.assertFalse(any("missing monitor.json" in issue for issue in result["issues"]))

    def test_auto_start_drift_preflight_failed_stops_before_normal_preflight(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_json(root / "manifest.json", _manifest_with_auto_start())
            _write_json(root / "auto_start_setup.json", {"verdict": "preflight_ok"})
            _write_json(root / "auto_start_capture_preflight.json", {"verdict": "preflight_ok"})
            _write_json(
                root / "auto_start_preflight.json",
                {
                    "summary": {
                        "verdict": "capture_failed",
                        "reason": "whole-home never became ready",
                    },
                    "rows": [],
                },
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "capture_failed")
        self.assertEqual(result["phase"], "auto_start_preflight")
        self.assertEqual(result["auto_start_preflight_verdict"], "capture_failed")
        self.assertIn("whole-home never became ready", result["reason"])
        self.assertFalse(any("missing capture_preflight.json" in issue for issue in result["issues"]))

    def test_missing_auto_start_preflight_is_incomplete_before_normal_preflight(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_json(root / "manifest.json", _manifest_with_auto_start())
            _write_json(root / "auto_start_setup.json", {"verdict": "preflight_ok"})
            _write_json(root / "auto_start_capture_preflight.json", {"verdict": "preflight_ok"})
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "incomplete")
        self.assertEqual(result["phase"], "auto_start_preflight")
        self.assertIn("missing auto_start_preflight.json", result["issues"])
        self.assertFalse(any("missing capture_preflight.json" in issue for issue in result["issues"]))

    def test_auto_start_setup_failed_stops_before_app_preflight(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_json(root / "manifest.json", _manifest_with_auto_start())
            _write_json(
                root / "auto_start_setup.json",
                {
                    "verdict": "capture_failed",
                    "reason": "CoreAudio default-output setup failed",
                },
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "capture_failed")
        self.assertEqual(result["phase"], "auto_start_setup")
        self.assertEqual(result["auto_start_setup_verdict"], "capture_failed")
        self.assertIn("CoreAudio default-output setup failed", result["reason"])
        self.assertFalse(any("missing auto_start_capture_preflight.json" in issue for issue in result["issues"]))

    def test_headless_auto_start_manifest_declares_runtime_without_launchctl(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = _manifest_with_auto_start()
            manifest["launchesApp"] = False
            manifest["launchesHeadlessRuntime"] = True
            manifest["launchMethodRequested"] = "headless"
            manifest["launchMethodUsed"] = "headless"
            manifest["launchEnvironmentApplied"] = False
            manifest["changesLaunchEnvironment"] = False
            _write_json(root / "manifest.json", manifest)
            _write_json(root / "auto_start_setup.json", {"verdict": "preflight_ok"})
            _write_json(
                root / "auto_start_capture_preflight.json",
                {"verdict": "capture_failed", "error": "headless no devices"},
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "capture_failed")
        self.assertEqual(result["phase"], "auto_start_capture_preflight")
        self.assertTrue(result["checklist"]["manifest_launches_app_declared"])
        self.assertTrue(result["checklist"]["manifest_launches_headless_runtime"])
        self.assertTrue(
            result["checklist"]["manifest_changes_launch_environment_declared"]
        )

    def test_rejects_auto_start_manifest_without_side_effect_declarations(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = _manifest_with_auto_start()
            manifest.pop("launchesApp")
            _write_json(root / "manifest.json", manifest)
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "not_applicable")
        self.assertEqual(result["phase"], "manifest")
        self.assertTrue(any("launchesApp" in issue for issue in result["issues"]))

    def test_rejects_auto_start_default_output_change_without_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = _manifest_with_auto_start()
            manifest["changesDefaultOutput"] = True
            manifest["defaultOutputReport"] = None
            _write_json(root / "manifest.json", manifest)
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "not_applicable")
        self.assertEqual(result["phase"], "manifest")
        self.assertFalse(result["checklist"]["manifest_default_output_reported"])

    def test_rejects_manifest_that_can_apply_delay(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            _write_json(
                root / "manifest.json",
                {
                    "schema": "syncast.passive_drift_session.v1",
                    "emitsAudio": False,
                    "appliesDelay": True,
                    "opensMicrophoneOnlyAfterPreflight": True,
                },
            )
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "not_applicable")
        self.assertEqual(result["phase"], "manifest")
        self.assertFalse(result["checklist"]["manifest_no_delay_write"])

    def test_incomplete_when_manifest_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            (root / "manifest.json").unlink()
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "incomplete")
        self.assertEqual(result["phase"], "manifest")
        self.assertIn("missing manifest.json", result["issues"])

    def test_detects_jsonl_monitor_row_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            _write_jsonl(root / "samples.jsonl", [_row(1)])
            result = psa.audit_session(root)
        self.assertIn("row count", result["issues"][0])
        self.assertFalse(result["checklist"]["jsonl_matches_monitor_rows"])
        self.assertEqual(result["verdict"], "incomplete")
        self.assertEqual(result["phase"], "samples")

    def test_detects_same_count_jsonl_monitor_content_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            stale_rows = [_row(1, 2400.0), _row(2, 2402.0), _row(3, 2399.0)]
            _write_jsonl(root / "samples.jsonl", stale_rows)
            result = psa.audit_session(root)
        self.assertTrue(
            any("does not match monitor.json" in issue for issue in result["issues"])
        )
        self.assertFalse(result["checklist"]["jsonl_matches_monitor_rows"])
        self.assertEqual(result["verdict"], "incomplete")
        self.assertEqual(result["phase"], "samples")

    def test_incomplete_when_accepted_sample_lacks_microphone_timing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            monitor = _monitor()
            del monitor["rows"][0]["sample"]["cycles"][0]["capture"]["microphoneArmedAtNs"]
            _write_json(root / "monitor.json", monitor)
            _write_jsonl(root / "samples.jsonl", monitor["rows"])
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "incomplete")
        self.assertEqual(result["phase"], "timing")
        self.assertFalse(result["checklist"]["passive_mic_timing_metadata"])
        self.assertEqual(result["timing_gate"]["field"], "microphoneArmedAtNs")

    def test_incomplete_when_preflight_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            (root / "preflight.json").unlink()
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "incomplete")
        self.assertEqual(result["phase"], "preflight")

    def test_incomplete_when_samples_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            (root / "samples.jsonl").unlink()
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "incomplete")
        self.assertEqual(result["phase"], "samples")

    def test_incomplete_when_samples_malformed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            (root / "samples.jsonl").write_text("{not json}\n")
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "incomplete")
        self.assertEqual(result["phase"], "samples")

    def test_incomplete_when_decision_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(tmp)
            (root / "decision.json").unlink()
            result = psa.audit_session(root)
        self.assertEqual(result["verdict"], "incomplete")
        self.assertIn("missing decision.json", result["issues"])

    def test_main_bad_input_for_missing_directory(self):
        old_parse = psa._parse_args
        try:
            psa._parse_args = lambda: type(
                "Args",
                (),
                {"session_root": Path("/tmp/definitely-not-syncast-session")},
            )()
            with mock.patch.object(sys, "stderr"):
                rc = psa.main()
        finally:
            psa._parse_args = old_parse
        self.assertEqual(rc, psa.EXIT_BAD_INPUT)


if __name__ == "__main__":
    unittest.main()
