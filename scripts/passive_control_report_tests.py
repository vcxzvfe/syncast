#!/usr/bin/env python3
from __future__ import annotations

import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import passive_control_report as pcr


def _row(
    index: int,
    delay: float = 2300.0,
    *,
    sync_state: str = "suspect",
    sync_revision: int = 7,
) -> dict:
    return {
        "index": index,
        "verdict": "accepted",
        "delay_ms": delay,
        "current_delay_ms": 2200,
        "delay_locked": False,
        "context_signature": "ctx-a",
        "enabled_airplay_count": 1,
        "active_airplay_count": 1,
        "airplay_timing_epoch": 1,
        "sync_context_state": sync_state,
        "sync_context_revision": sync_revision,
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
                        "syncContextState": sync_state,
                        "syncContextRevision": sync_revision,
                        "endSyncContextState": sync_state,
                        "endSyncContextRevision": sync_revision,
                    },
                }
            ]
        },
    }


def _monitor(
    *,
    sync_state: str = "suspect",
    sync_revision: int = 7,
) -> dict:
    rows = [
        _row(1, 2300.0, sync_state=sync_state, sync_revision=sync_revision),
        _row(2, 2302.0, sync_state=sync_state, sync_revision=sync_revision),
        _row(3, 2299.0, sync_state=sync_state, sync_revision=sync_revision),
    ]
    return {
        "summary": {
            "verdict": "stable",
            "reason": None,
            "samples_total": len(rows),
            "samples_accepted": len(rows),
            "required_accepted": 2,
            "delay_range_ms": 3.0,
            "delay_end_to_start_ms": -1.0,
            "trailing_inconclusive_samples": 0,
            "context_gate": None,
        },
        "rows": rows,
    }


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(row, sort_keys=True) for row in rows) + "\n")


def _session(
    root: Path,
    *,
    decision: dict | None = None,
    passive_apply_mode: str | None = None,
    baseline_mark_mode: str | None = None,
    sync_state: str = "suspect",
    sync_revision: int = 7,
) -> Path:
    monitor = _monitor(sync_state=sync_state, sync_revision=sync_revision)
    manifest = {
        "schema": "syncast.passive_drift_session.v1",
        "emitsAudio": False,
        "appliesDelay": False,
        "opensMicrophoneOnlyAfterPreflight": True,
    }
    if passive_apply_mode is not None:
        manifest["passiveApplyMode"] = passive_apply_mode
    if baseline_mark_mode is not None:
        manifest["baselineMarkMode"] = baseline_mark_mode
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
        decision
        or {
            "verdict": "initialize_baseline",
            "auto_apply_eligible": False,
            "baseline_offset_ms": 100.0,
        },
    )
    _write_jsonl(root / "samples.jsonl", monitor["rows"])
    return root


def _finalize_decided(
    decision_verdict: str = "recommend",
    *,
    baseline_sync_state: str = "suspect",
    baseline_sync_revision: int = 7,
    decision_sync_state: str = "suspect",
    decision_sync_revision: int = 7,
) -> dict:
    features = {
        "samples_accepted": 3,
        "measured_delay_ms": 2300.0,
        "current_delay_ms": 2200.0,
        "delay_locked": False,
        "observed_offset_ms": 100.0,
        "delay_range_ms": 3.0,
        "context_signature": "ctx-a",
        "capture_backend": "tap",
        "enabled_airplay_count": 1,
        "active_airplay_count": 1,
        "airplay_timing_epoch": 1,
        "sync_context_state": decision_sync_state,
        "sync_context_revision": decision_sync_revision,
    }
    return {
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
                "airplayTimingEpoch": 1,
                "syncContextState": baseline_sync_state,
                "syncContextRevision": baseline_sync_revision,
                "baselineOffsetMs": 82.0,
            },
            "decision": {
                "verdict": decision_verdict,
                "reason": "inside deadband" if decision_verdict == "hold" else None,
                "auto_apply_eligible": decision_verdict == "recommend",
                "recommended_delay_ms": 2221,
                "raw_correction_ms": 21.0,
                "features": features,
                "baseline_offset_ms": 82.0,
            },
        },
    }


def _finalize_recorded() -> dict:
    return {
        "verdict": "recorded",
        "auditVerdict": "ready_for_baseline",
        "result": {
            "baseline": {
                "key": "baseline-a",
                "contextSignature": "ctx-a",
                "captureBackend": "tap",
                "delayLocked": False,
                "enabledAirplayCount": 1,
                "airplayTimingEpoch": 1,
                "syncContextState": "suspect",
                "syncContextRevision": 7,
                "baselineOffsetMs": 100.0,
                "measuredDelayMs": 2300.0,
                "currentDelayMs": 2200.0,
                "samplesAccepted": 3,
                "delayRangeMs": 3.0,
            },
        },
    }


def _baseline_mark_artifact(
    root: Path,
    *,
    verdict: str = "marked_valid",
    dry_run: bool = False,
    context_signature: str = "ctx-a",
) -> dict:
    applied = verdict == "marked_valid"
    return {
        "verdict": verdict,
        "sessionRoot": str(root),
        "socket": "/tmp/fake.sock",
        "dryRun": dry_run,
        "request": {
            "currentDelayMs": 2200,
            "contextSignature": context_signature,
            "delayLocked": False,
            "enabledAirplayCount": 1,
            "activeAirplayCount": 1,
            "airplayTimingEpoch": 1,
            "captureBackend": "tap",
            "syncContextState": "suspect",
            "syncContextRevision": 7,
            "baselineKey": "baseline-a",
            "dryRun": dry_run,
        },
        "result": {
            "accepted": verdict != "not_marked",
            "applied": applied,
            "dryRun": dry_run,
            "reason": "ok" if verdict != "not_marked" else "context_changed",
            "currentDelayMs": 2200,
            "contextSignature": context_signature,
            "delayLocked": False,
            "enabledAirplayCount": 1,
            "activeAirplayCount": 1,
            "airplayTimingEpoch": 1,
            "captureBackend": "tap",
            "previousSyncContextState": "suspect" if applied else None,
            "previousSyncContextRevision": 7 if applied else None,
            "syncContextState": "valid" if applied else "suspect",
            "syncContextRevision": 8 if applied else 7,
            "emitsAudio": False,
            "opensMicrophone": False,
            "appliesDelay": False,
        },
        "emitsAudio": False,
        "opensMicrophone": False,
        "appliesDelay": False,
    }


def _ready_gate(
    session_root: Path,
    *,
    recommended_delay_ms: int = 2221,
    sync_state: str = "suspect",
    sync_revision: int = 7,
) -> dict:
    return {
        "verdict": "ready_for_apply_candidate",
        "sessionRoot": str(session_root),
        "reason": "two passive recommendations agree",
        "baselineKey": "baseline-a",
        "recommendedDelayMs": recommended_delay_ms,
        "currentDelayMs": 2200,
        "contextSignature": "ctx-a",
        "delayLocked": False,
        "enabledAirplayCount": 1,
        "activeAirplayCount": 1,
        "airplayTimingEpoch": 1,
        "syncContextState": sync_state,
        "syncContextRevision": sync_revision,
        "captureBackend": "tap",
    }


def _passive_apply_artifact(
    root: Path,
    *,
    verdict: str,
    dry_run: bool,
    target_delay_ms: int = 2221,
    applies_delay: bool | None = None,
    result: dict | None = None,
) -> dict:
    if applies_delay is None:
        applies_delay = verdict == "applied"
    runtime_result = {
        "targetDelayMs": target_delay_ms,
        "currentDelayMs": 2200,
        "contextSignature": "ctx-a",
        "delayLocked": False,
        "enabledAirplayCount": 1,
        "activeAirplayCount": 1,
        "airplayTimingEpoch": 1,
        "syncContextState": "suspect",
        "syncContextRevision": 7,
        "captureBackend": "tap",
    }
    if result is None:
        if verdict == "dry_run_ready":
            result = {
                **runtime_result,
                "reason": "dry_run",
                "applied": False,
                "wouldApply": True,
            }
        elif verdict == "applied":
            result = {
                **runtime_result,
                "reason": "passive_ready_candidate",
                "applied": True,
                "wouldApply": True,
                "appliedDelayMs": target_delay_ms,
            }
        else:
            result = {
                **runtime_result,
                "reason": "airplay_timing_epoch_changed",
                "applied": False,
                "wouldApply": False,
            }
    return {
        "verdict": verdict,
        "sessionRoot": str(root),
        "socket": "/tmp/fake.sock",
        "dryRun": dry_run,
        "request": {
            "targetDelayMs": target_delay_ms,
            "currentDelayMs": 2200,
            "contextSignature": "ctx-a",
            "delayLocked": False,
            "enabledAirplayCount": 1,
            "activeAirplayCount": 1,
            "airplayTimingEpoch": 1,
            "syncContextState": "suspect",
            "syncContextRevision": 7,
            "captureBackend": "tap",
            "baselineKey": "baseline-a",
            "dryRun": dry_run,
        },
        "result": result,
        "emitsAudio": False,
        "appliesDelay": applies_delay,
    }


class PassiveControlReportTests(unittest.TestCase):
    def test_ready_for_baseline_without_store_is_explicit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp))
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "ready_for_baseline")
        self.assertEqual(report["phase"], "decision")
        self.assertFalse(report["emitsAudio"])
        self.assertFalse(report["appliesDelay"])
        self.assertTrue(report["manifestNoAudio"])

    def test_corrupt_finalize_artifact_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp))
            (root / "finalize.json").write_text("{not json")
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "incomplete")
        self.assertEqual(report["phase"], "artifact_json")
        self.assertEqual(report["blockingStage"], "artifact_json")
        self.assertIn("finalize.json: invalid JSON", report["reason"])
        self.assertIn("finalize.json: invalid JSON", " ".join(report["issues"]))
        self.assertIn("corrupt JSON artifacts", report["nextAction"])

    def test_corrupt_passive_apply_artifact_cannot_be_treated_as_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
                passive_apply_mode="dry-run",
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(root / "correction_gate.json", _ready_gate(root))
            (root / "passive_apply.json").write_text("{not json")
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "incomplete")
        self.assertEqual(report["phase"], "artifact_json")
        self.assertEqual(report["blockingStage"], "artifact_json")
        self.assertIn("passive_apply.json: invalid JSON", report["reason"])
        self.assertIn("passive_apply.json: invalid JSON", " ".join(report["issues"]))

    def test_capture_failed_safe_fail_is_preserved(self):
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
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "capture_failed")
        self.assertEqual(report["phase"], "preflight")
        self.assertIn("socket blocked", report["reason"])
        self.assertEqual(report["blockingStage"], "preflight")
        self.assertIn("start SyncCast in Whole-home", report["nextAction"])
        self.assertFalse(report["capturePreflightJson"])
        self.assertIsNone(report["capturePreflightVerdict"])

    def test_capture_failed_capture_preflight_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_json(
                root / "manifest.json",
                {
                    "schema": "syncast.passive_drift_session.v1",
                    "emitsAudio": False,
                    "appliesDelay": False,
                    "opensMicrophoneOnlyAfterPreflight": True,
                    "workflow": ["preflight", "capture_preflight", "monitor"],
                    "artifacts": {
                        "capturePreflight": "capture_preflight.json",
                        "preflight": "preflight.json",
                    },
                },
            )
            _write_json(
                root / "capture_preflight.json",
                {
                    "verdict": "capture_failed",
                    "error": "socket missing",
                },
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "capture_failed")
        self.assertEqual(report["capturePreflightVerdict"], "capture_failed")
        self.assertTrue(report["capturePreflightJson"])
        self.assertEqual(report["blockingStage"], "capture_preflight")
        self.assertIn("start SyncCast in Whole-home", report["nextAction"])
        self.assertIn("socket missing", report["reason"])

    def test_capture_failed_uses_readiness_stage_and_action_when_available(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_json(
                root / "manifest.json",
                {
                    "schema": "syncast.passive_drift_session.v1",
                    "emitsAudio": False,
                    "appliesDelay": False,
                    "opensMicrophoneOnlyAfterPreflight": True,
                    "workflow": ["readiness_report", "capture_preflight", "preflight"],
                    "artifacts": {
                        "readiness": "readiness.json",
                        "capturePreflight": "capture_preflight.json",
                        "preflight": "preflight.json",
                    },
                },
            )
            _write_json(
                root / "readiness.json",
                {
                    "schema": "syncast.passive_readiness.v1",
                    "verdict": "not_ready",
                    "stage": "process",
                    "nextAction": "start SyncCast in Whole-home",
                    "syncContextState": "suspect",
                    "syncContextReason": "AirPlay volume changed",
                    "syncContextRevision": 9,
                    "passiveEvidenceIntent": "baseline_required",
                    "passiveEvidenceIntentSource": "derived",
                    "baselineRequired": True,
                    "passiveCanApply": False,
                    "recommendedWorkflow": "record_baseline",
                    "recommendedSessionMode": "baseline",
                    "requiresBaselineStore": True,
                    "allowsPassiveApply": False,
                    "opensMicrophone": False,
                    "emitsAudio": False,
                    "appliesDelay": False,
                },
            )
            _write_json(
                root / "capture_preflight.json",
                {
                    "verdict": "capture_failed",
                    "error": "socket missing",
                },
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "capture_failed")
        self.assertTrue(report["readinessJson"])
        self.assertEqual(report["readinessVerdict"], "not_ready")
        self.assertEqual(report["readinessStage"], "process")
        self.assertEqual(report["blockingStage"], "process")
        self.assertEqual(report["nextAction"], "start SyncCast in Whole-home")
        self.assertEqual(report["syncContextState"], "suspect")
        self.assertEqual(report["syncContextReason"], "AirPlay volume changed")
        self.assertEqual(report["syncContextRevision"], 9)
        self.assertEqual(report["readinessPassiveEvidenceIntent"], "baseline_required")
        self.assertEqual(report["readinessPassiveEvidenceIntentSource"], "derived")
        self.assertTrue(report["readinessBaselineRequired"])
        self.assertFalse(report["readinessPassiveCanApply"])
        self.assertEqual(report["readinessRecommendedWorkflow"], "record_baseline")
        self.assertEqual(report["readinessRecommendedSessionMode"], "baseline")
        self.assertTrue(report["readinessRequiresBaselineStore"])
        self.assertFalse(report["readinessAllowsPassiveApply"])

    def test_workflow_guard_block_is_reported_before_mic_corpus(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp))
            _write_json(
                root / "workflow_guard.json",
                {
                    "schema": "syncast.passive_workflow_guard.v1",
                    "mode": "enforce",
                    "verdict": "blocked",
                    "reason": "baseline_store_required_for_record_baseline",
                    "nextAction": "set SYNCAST_PASSIVE_BASELINE_STORE",
                    "opensMicrophone": False,
                    "emitsAudio": False,
                    "appliesDelay": False,
                },
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "workflow_guard")
        self.assertEqual(report["blockingStage"], "workflow_guard")
        self.assertEqual(
            report["workflowGuardReason"],
            "baseline_store_required_for_record_baseline",
        )
        self.assertIn("SYNCAST_PASSIVE_BASELINE_STORE", report["nextAction"])

    def test_auto_start_capture_preflight_failure_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_json(
                root / "manifest.json",
                {
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
                        "autoStartCapturePreflight": (
                            "auto_start_capture_preflight.json"
                        ),
                        "autoStartPreflight": "auto_start_preflight.json",
                        "capturePreflight": "capture_preflight.json",
                        "preflight": "preflight.json",
                    },
                },
            )
            _write_json(root / "auto_start_setup.json", {"verdict": "preflight_ok"})
            _write_json(
                root / "auto_start_capture_preflight.json",
                {
                    "verdict": "capture_failed",
                    "error": "auto-start socket missing",
                },
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "capture_failed")
        self.assertEqual(
            report["autoStartCapturePreflightVerdict"],
            "capture_failed",
        )
        self.assertTrue(report["autoStartCapturePreflightJson"])
        self.assertFalse(report["capturePreflightJson"])
        self.assertEqual(report["blockingStage"], "auto_start_capture_preflight")
        self.assertIn("auto-start did not reach passive capture readiness", report["nextAction"])
        self.assertIn("auto-start socket missing", report["reason"])
        self.assertTrue(report["manifestLaunchesAppDeclared"])
        self.assertTrue(report["manifestChangesRoutesDeclared"])
        self.assertTrue(report["manifestChangesLaunchEnvironmentDeclared"])
        self.assertTrue(report["manifestDefaultOutputSideEffectDeclared"])
        self.assertTrue(report["manifestDefaultOutputReported"])
        self.assertTrue(report["launchesApp"])
        self.assertFalse(report["appLaunchAttempted"])
        self.assertFalse(report["appLaunched"])
        self.assertTrue(report["changesRoutes"])
        self.assertFalse(report["changesDefaultOutput"])

    def test_auto_start_setup_failure_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_json(
                root / "manifest.json",
                {
                    "schema": "syncast.passive_drift_session.v1",
                    "emitsAudio": False,
                    "appliesDelay": False,
                    "opensMicrophoneOnlyAfterPreflight": True,
                    "autoStartTargets": "display,xiaomi",
                    "launchesApp": True,
                    "appLaunchAttempted": False,
                    "appLaunched": False,
                    "appWasRunningBeforeAutoStart": False,
                    "changesRoutes": True,
                    "changesLaunchEnvironment": True,
                    "mayChangeDefaultOutput": True,
                    "changesDefaultOutput": False,
                    "defaultOutputReport": (
                        "  default-read-error: ERROR: default output read failed OSStatus=0"
                    ),
                    "autoStartSideEffectsUpdated": True,
                    "autoStartAcousticSetupCompleted": False,
                    "workflow": ["auto_start_setup_if_requested"],
                    "artifacts": {"autoStartSetup": "auto_start_setup.json"},
                },
            )
            _write_json(
                root / "auto_start_setup.json",
                {
                    "verdict": "capture_failed",
                    "reason": "CoreAudio default-output setup failed",
                },
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "capture_failed")
        self.assertEqual(report["blockingStage"], "auto_start_setup")
        self.assertEqual(report["autoStartSetupVerdict"], "capture_failed")
        self.assertTrue(report["autoStartSetupJson"])
        self.assertFalse(report["appLaunchAttempted"])
        self.assertIn("CoreAudio/default-output", report["nextAction"])

    def test_headless_auto_start_setup_failure_exposes_stderr(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_json(
                root / "manifest.json",
                {
                    "schema": "syncast.passive_drift_session.v1",
                    "emitsAudio": False,
                    "appliesDelay": False,
                    "opensMicrophoneOnlyAfterPreflight": True,
                    "autoStartTargets": "display,xiaomi",
                    "launchesApp": False,
                    "launchesHeadlessRuntime": True,
                    "appLaunchAttempted": True,
                    "appLaunched": False,
                    "headlessRuntimeLaunched": False,
                    "appWasRunningBeforeAutoStart": False,
                    "launchMethodRequested": "headless",
                    "launchMethodUsed": "headless",
                    "launchEnvironmentApplied": False,
                    "changesRoutes": True,
                    "changesLaunchEnvironment": False,
                    "mayChangeDefaultOutput": True,
                    "changesDefaultOutput": False,
                    "defaultOutputReport": "before=display after=display",
                    "autoStartSideEffectsUpdated": True,
                    "autoStartAcousticSetupCompleted": True,
                    "workflow": ["auto_start_setup_if_requested"],
                    "artifacts": {"autoStartSetup": "auto_start_setup.json"},
                },
            )
            _write_json(
                root / "auto_start_setup.json",
                {
                    "verdict": "capture_failed",
                    "reason": "failed to launch SyncCast before passive readiness",
                    "headlessLaunchStderr": str(root / "syncast_headless_launch.stderr"),
                    "headlessLaunchStderrTail": "ServiceNotRunning",
                },
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "capture_failed")
        self.assertEqual(report["blockingStage"], "auto_start_setup")
        self.assertTrue(report["launchesHeadlessRuntime"])
        self.assertFalse(report["appLaunched"])
        self.assertFalse(report["headlessRuntimeLaunched"])
        self.assertFalse(report["changesLaunchEnvironment"])
        self.assertEqual(report["headlessLaunchStderrTail"], "ServiceNotRunning")

    def test_baseline_recorded_from_finalize(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp))
            _write_json(root / "finalize.json", _finalize_recorded())
            _write_json(
                root / "passive_baseline_mark.json",
                _baseline_mark_artifact(root),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "baseline_recorded")
        self.assertEqual(report["finalizeVerdict"], "recorded")
        self.assertEqual(report["passiveBaselineMarkVerdict"], "marked_valid")
        self.assertEqual(
            report["passiveBaselineMarkResult"]["syncContextState"],
            "valid",
        )
        self.assertIsNone(report["blockingStage"])
        self.assertIn("later same-route passive session", report["nextAction"])

    def test_recorded_baseline_missing_required_mark_artifact_is_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp), baseline_mark_mode="mark")
            _write_json(root / "finalize.json", _finalize_recorded())
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "incomplete")
        self.assertEqual(report["phase"], "baseline_mark")
        self.assertEqual(report["blockingStage"], "baseline_mark")
        self.assertIn("missing app-side baseline mark", report["reason"])
        self.assertIn("SYNCAST_PASSIVE_BASELINE_MARK_MODE=mark", report["nextAction"])

    def test_recorded_baseline_marked_valid_satisfies_required_mark_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp), baseline_mark_mode="mark")
            _write_json(root / "finalize.json", _finalize_recorded())
            _write_json(
                root / "passive_baseline_mark.json",
                _baseline_mark_artifact(root, verdict="marked_valid", dry_run=False),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "baseline_recorded")
        self.assertEqual(report["phase"], "baseline_mark")
        self.assertEqual(pcr._exit_code(report["verdict"]), pcr.EXIT_OK)
        self.assertIsNone(report["blockingStage"])
        self.assertIn("later same-route passive session", report["nextAction"])

    def test_recorded_baseline_mark_dry_run_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp), baseline_mark_mode="dry-run")
            _write_json(root / "finalize.json", _finalize_recorded())
            _write_json(
                root / "passive_baseline_mark.json",
                _baseline_mark_artifact(root, verdict="dry_run_ready", dry_run=True),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "baseline_mark_dry_run_ready")
        self.assertEqual(report["phase"], "baseline_mark")
        self.assertEqual(pcr._exit_code(report["verdict"]), pcr.EXIT_OK)
        self.assertIsNone(report["blockingStage"])
        self.assertIn("rerun baseline mark in mark mode", report["nextAction"])
        self.assertFalse(report["appliesDelay"])

    def test_stale_recorded_baseline_mark_artifact_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp))
            _write_json(root / "finalize.json", _finalize_recorded())
            _write_json(
                root / "passive_baseline_mark.json",
                _baseline_mark_artifact(root, context_signature="ctx-b"),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "baseline_mark")
        self.assertIn("contextSignature", report["reason"])

    def test_stale_recorded_baseline_sync_context_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp))
            finalize = _finalize_recorded()
            finalize["result"]["baseline"]["syncContextRevision"] = 8
            _write_json(root / "finalize.json", finalize)
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "finalize")
        self.assertIn("sync_context_revision", report["reason"])

    def test_marked_baseline_must_echo_previous_sync_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp))
            _write_json(root / "finalize.json", _finalize_recorded())
            artifact = _baseline_mark_artifact(root, verdict="marked_valid", dry_run=False)
            artifact["result"]["previousSyncContextRevision"] = 8
            _write_json(root / "passive_baseline_mark.json", artifact)
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "baseline_mark")
        self.assertIn("previousSyncContextRevision", report["reason"])

    def test_marked_baseline_must_advance_non_valid_sync_revision(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp))
            _write_json(root / "finalize.json", _finalize_recorded())
            artifact = _baseline_mark_artifact(root, verdict="marked_valid", dry_run=False)
            artifact["result"]["syncContextRevision"] = 7
            _write_json(root / "passive_baseline_mark.json", artifact)
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "baseline_mark")
        self.assertIn("advance syncContextRevision", report["reason"])

    def test_baseline_mark_result_must_match_request_runtime_context(self):
        cases = [
            (
                "currentDelayMs",
                lambda artifact: artifact["result"].update({"currentDelayMs": 2199}),
                "currentDelayMs",
            ),
            (
                "contextSignature",
                lambda artifact: artifact["result"].update({"contextSignature": "ctx-b"}),
                "contextSignature",
            ),
            (
                "enabledAirplayCount",
                lambda artifact: artifact["result"].update({"enabledAirplayCount": 2}),
                "enabledAirplayCount",
            ),
            (
                "activeAirplayCount",
                lambda artifact: artifact["result"].update({"activeAirplayCount": 0}),
                "activeAirplayCount",
            ),
            (
                "airplayTimingEpoch",
                lambda artifact: artifact["result"].update({"airplayTimingEpoch": 2}),
                "airplayTimingEpoch",
            ),
            (
                "captureBackend",
                lambda artifact: artifact["result"].update({"captureBackend": "sck"}),
                "captureBackend",
            ),
            (
                "delayLocked",
                lambda artifact: artifact["result"].update({"delayLocked": True}),
                "delayLocked",
            ),
            (
                "resultDryRun",
                lambda artifact: artifact["result"].update({"dryRun": True}),
                "dry-run state",
            ),
            (
                "safetyFlag",
                lambda artifact: artifact["result"].update({"opensMicrophone": True}),
                "opened the microphone",
            ),
        ]
        for name, mutate, expected_reason in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = _session(Path(tmp))
                _write_json(root / "finalize.json", _finalize_recorded())
                artifact = _baseline_mark_artifact(root, verdict="marked_valid", dry_run=False)
                mutate(artifact)
                _write_json(root / "passive_baseline_mark.json", artifact)
                report = pcr.build_report(root)
            self.assertEqual(report["verdict"], "not_applicable")
            self.assertEqual(report["phase"], "baseline_mark")
            self.assertIn(expected_reason, report["reason"])

    def test_baseline_mark_dry_run_result_must_echo_request_sync_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp), baseline_mark_mode="dry-run")
            _write_json(root / "finalize.json", _finalize_recorded())
            artifact = _baseline_mark_artifact(root, verdict="dry_run_ready", dry_run=True)
            artifact["result"]["syncContextRevision"] = 8
            _write_json(root / "passive_baseline_mark.json", artifact)
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "baseline_mark")
        self.assertIn("syncContextRevision", report["reason"])

    def test_pending_confirmation_from_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2218,
                },
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(
                root / "correction_gate.json",
                {
                    "verdict": "pending_confirmation",
                    "reason": "repeat required",
                    "baselineKey": "baseline-a",
                    "recommendedDelayMs": 2218,
                },
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "pending_confirmation")
        self.assertEqual(report["recommendedDelayMs"], 2218)
        self.assertEqual(report["baselineKey"], "baseline-a")
        self.assertIsNone(report["blockingStage"])
        self.assertIn("one more independent", report["nextAction"])

    def test_ready_apply_candidate_from_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(
                root / "correction_gate.json",
                _ready_gate(root),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "ready_for_apply_candidate")
        self.assertEqual(pcr._exit_code(report["verdict"]), pcr.EXIT_OK)
        self.assertIsNone(report["blockingStage"])
        self.assertIn("app-side passive apply dry-run", report["nextAction"])

    def test_ready_gate_uses_current_decision_sync_context_after_mark(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
                sync_state="valid",
                sync_revision=8,
            )
            _write_json(
                root / "finalize.json",
                _finalize_decided(
                    baseline_sync_state="suspect",
                    baseline_sync_revision=7,
                    decision_sync_state="valid",
                    decision_sync_revision=8,
                ),
            )
            _write_json(
                root / "correction_gate.json",
                _ready_gate(root, sync_state="valid", sync_revision=8),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "ready_for_apply_candidate")
        self.assertEqual(report["syncContextState"], "valid")
        self.assertEqual(report["syncContextRevision"], 8)

    def test_stale_gate_with_recorded_baseline_sync_context_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
                sync_state="valid",
                sync_revision=8,
            )
            _write_json(
                root / "finalize.json",
                _finalize_decided(
                    baseline_sync_state="suspect",
                    baseline_sync_revision=7,
                    decision_sync_state="valid",
                    decision_sync_revision=8,
                ),
            )
            _write_json(
                root / "correction_gate.json",
                _ready_gate(root, sync_state="suspect", sync_revision=7),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "gate")
        self.assertIn("syncContextState", report["reason"])

    def test_stale_finalize_cannot_override_current_hold_decision(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "hold",
                    "auto_apply_eligible": False,
                    "recommended_delay_ms": 2200,
                },
            )
            stale_finalize = _finalize_decided()
            stale_finalize["auditVerdict"] = "ready_for_correction"
            _write_json(root / "finalize.json", stale_finalize)
            _write_json(root / "correction_gate.json", _ready_gate(root))
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "finalize")
        self.assertIn("audit verdict", report["reason"])

    def test_stale_finalize_sync_context_revision_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
            )
            stale_finalize = _finalize_decided()
            stale_finalize["result"]["decision"]["features"][
                "sync_context_revision"
            ] = 8
            _write_json(root / "finalize.json", stale_finalize)
            _write_json(root / "correction_gate.json", _ready_gate(root))
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "finalize")
        self.assertIn("sync_context_revision", report["reason"])

    def test_stale_gate_cannot_override_current_finalize_decision(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
            )
            finalize = _finalize_decided()
            finalize["result"]["decision"]["recommended_delay_ms"] = 2221
            _write_json(root / "finalize.json", finalize)
            stale_gate = _ready_gate(root, recommended_delay_ms=2250)
            _write_json(root / "correction_gate.json", stale_gate)
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "gate")
        self.assertIn("recommendedDelayMs", report["reason"])

    def test_gate_must_belong_to_current_session_root(self):
        cases = [
            (
                "missing",
                lambda gate, root: gate.pop("sessionRoot"),
                "missing session root",
            ),
            (
                "different",
                lambda gate, root: gate.update(
                    {"sessionRoot": str(root / "other-session")}
                ),
                "different session root",
            ),
        ]
        for name, mutate, expected_reason in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = _session(
                    Path(tmp),
                    decision={
                        "verdict": "recommend",
                        "auto_apply_eligible": True,
                        "recommended_delay_ms": 2221,
                    },
                )
                _write_json(root / "finalize.json", _finalize_decided())
                gate = _ready_gate(root)
                mutate(gate, root)
                _write_json(root / "correction_gate.json", gate)
                report = pcr.build_report(root)
            self.assertEqual(report["verdict"], "not_applicable")
            self.assertEqual(report["phase"], "gate")
            self.assertIn(expected_reason, report["reason"])

    def test_missing_dry_run_artifact_is_incomplete_when_manifest_requires_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
                passive_apply_mode="dry-run",
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(
                root / "correction_gate.json",
                _ready_gate(root),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "incomplete")
        self.assertEqual(report["phase"], "apply")
        self.assertIn("dry-run artifact is missing", report["reason"])

    def test_dry_run_ready_from_passive_apply(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(
                root / "correction_gate.json",
                _ready_gate(root),
            )
            _write_json(
                root / "passive_apply.json",
                _passive_apply_artifact(
                    root,
                    verdict="dry_run_ready",
                    dry_run=True,
                ),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "dry_run_ready")
        self.assertEqual(report["phase"], "apply")
        self.assertFalse(report["appliesDelay"])
        self.assertEqual(report["passiveApplyVerdict"], "dry_run_ready")
        self.assertEqual(pcr._exit_code(report["verdict"]), pcr.EXIT_OK)

    def test_applied_from_passive_apply_marks_delay_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(
                root / "correction_gate.json",
                _ready_gate(root),
            )
            _write_json(
                root / "passive_apply.json",
                _passive_apply_artifact(root, verdict="applied", dry_run=False),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "applied")
        self.assertEqual(report["phase"], "apply")
        self.assertTrue(report["appliesDelay"])
        self.assertEqual(pcr._exit_code(report["verdict"]), pcr.EXIT_OK)

    def test_applied_artifact_must_match_gate_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(root / "correction_gate.json", _ready_gate(root))
            artifact = _passive_apply_artifact(
                root,
                verdict="applied",
                dry_run=False,
                result={
                    "targetDelayMs": 2221,
                    "currentDelayMs": 2200,
                    "contextSignature": "ctx-a",
                    "delayLocked": False,
                    "enabledAirplayCount": 1,
                    "activeAirplayCount": 1,
                    "airplayTimingEpoch": 1,
                    "syncContextState": "suspect",
                    "syncContextRevision": 7,
                    "captureBackend": "tap",
                    "reason": "passive_ready_candidate",
                    "applied": True,
                    "wouldApply": True,
                    "appliedDelayMs": 2220,
                },
            )
            _write_json(root / "passive_apply.json", artifact)
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "apply")
        self.assertIn("different delay", report["reason"])

    def test_manifest_dry_run_mode_rejects_applied_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
                passive_apply_mode="dry-run",
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(root / "correction_gate.json", _ready_gate(root))
            _write_json(
                root / "passive_apply.json",
                _passive_apply_artifact(root, verdict="applied", dry_run=False),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "apply")
        self.assertIn("manifest dry-run mode", report["reason"])

    def test_not_applied_from_passive_apply_is_not_applicable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(
                root / "correction_gate.json",
                _ready_gate(root),
            )
            _write_json(
                root / "passive_apply.json",
                _passive_apply_artifact(
                    root,
                    verdict="not_applied",
                    dry_run=True,
                ),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "apply")
        self.assertIn("airplay_timing_epoch_changed", report["reason"])

    def test_stale_passive_apply_artifact_is_not_ready(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(root / "correction_gate.json", _ready_gate(root))
            _write_json(
                root / "passive_apply.json",
                _passive_apply_artifact(
                    root,
                    verdict="dry_run_ready",
                    dry_run=True,
                    target_delay_ms=2250,
                ),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "apply")
        self.assertIn("targetDelayMs", report["reason"])

    def test_stale_passive_apply_result_sync_context_is_not_ready(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(root / "correction_gate.json", _ready_gate(root))
            artifact = _passive_apply_artifact(
                root,
                verdict="dry_run_ready",
                dry_run=True,
            )
            artifact["result"]["syncContextState"] = "valid"
            _write_json(root / "passive_apply.json", artifact)
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "apply")
        self.assertIn("syncContextState", report["reason"])

    def test_stale_passive_apply_result_sync_revision_is_not_ready(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(root / "correction_gate.json", _ready_gate(root))
            artifact = _passive_apply_artifact(
                root,
                verdict="dry_run_ready",
                dry_run=True,
            )
            artifact["result"]["syncContextRevision"] = 8
            _write_json(root / "passive_apply.json", artifact)
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "apply")
        self.assertIn("syncContextRevision", report["reason"])

    def test_passive_apply_artifact_must_match_full_gate_context(self):
        cases = [
            (
                "sessionRoot",
                lambda artifact, root: artifact.update(
                    {"sessionRoot": str(root / "other-session")}
                ),
                "different session root",
            ),
            (
                "currentDelayMs",
                lambda artifact, root: artifact["request"].update(
                    {"currentDelayMs": 2199}
                ),
                "currentDelayMs",
            ),
            (
                "contextSignature",
                lambda artifact, root: artifact["request"].update(
                    {"contextSignature": "ctx-b"}
                ),
                "contextSignature",
            ),
            (
                "enabledAirplayCount",
                lambda artifact, root: artifact["request"].update(
                    {"enabledAirplayCount": 2}
                ),
                "enabledAirplayCount",
            ),
            (
                "activeAirplayCount",
                lambda artifact, root: artifact["request"].update(
                    {"activeAirplayCount": 0}
                ),
                "activeAirplayCount",
            ),
            (
                "airplayTimingEpoch",
                lambda artifact, root: artifact["request"].update(
                    {"airplayTimingEpoch": 2}
                ),
                "airplayTimingEpoch",
            ),
            (
                "captureBackend",
                lambda artifact, root: artifact["request"].update(
                    {"captureBackend": "sck"}
                ),
                "captureBackend",
            ),
            (
                "baselineKey",
                lambda artifact, root: artifact["request"].update(
                    {"baselineKey": "baseline-b"}
                ),
                "baselineKey",
            ),
            (
                "dryRun",
                lambda artifact, root: artifact.update({"dryRun": False}),
                "inconsistent dry-run state",
            ),
            (
                "requestDryRun",
                lambda artifact, root: artifact["request"].update({"dryRun": False}),
                "inconsistent dry-run state",
            ),
        ]
        for name, mutate, expected_reason in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = _session(
                    Path(tmp),
                    decision={
                        "verdict": "recommend",
                        "auto_apply_eligible": True,
                        "recommended_delay_ms": 2221,
                    },
                )
                _write_json(root / "finalize.json", _finalize_decided())
                _write_json(root / "correction_gate.json", _ready_gate(root))
                artifact = _passive_apply_artifact(
                    root,
                    verdict="dry_run_ready",
                    dry_run=True,
                )
                mutate(artifact, root)
                _write_json(root / "passive_apply.json", artifact)
                report = pcr.build_report(root)
            self.assertEqual(report["verdict"], "not_applicable")
            self.assertEqual(report["phase"], "apply")
            self.assertIn(expected_reason, report["reason"])

    def test_gate_missing_required_apply_binding_field_is_not_ready(self):
        cases = [
            ("currentDelayMs", "currentDelayMs"),
            ("contextSignature", "contextSignature"),
            ("enabledAirplayCount", "enabledAirplayCount"),
            ("airplayTimingEpoch", "airplayTimingEpoch"),
            ("syncContextState", "syncContextState"),
            ("syncContextRevision", "syncContextRevision"),
        ]
        for gate_field, expected_reason in cases:
            with self.subTest(gate_field=gate_field), tempfile.TemporaryDirectory() as tmp:
                root = _session(
                    Path(tmp),
                    decision={
                        "verdict": "recommend",
                        "auto_apply_eligible": True,
                        "recommended_delay_ms": 2221,
                    },
                )
                _write_json(root / "finalize.json", _finalize_decided())
                gate = copy.deepcopy(_ready_gate(root))
                gate.pop(gate_field)
                _write_json(root / "correction_gate.json", gate)
                _write_json(
                    root / "passive_apply.json",
                    _passive_apply_artifact(
                        root,
                        verdict="dry_run_ready",
                        dry_run=True,
                    ),
                )
                report = pcr.build_report(root)
            self.assertEqual(report["verdict"], "not_applicable")
            self.assertEqual(report["phase"], "gate")
            self.assertIn(expected_reason, report["reason"])

    def test_contradictory_dry_run_artifact_is_not_ready(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2221,
                },
            )
            _write_json(root / "finalize.json", _finalize_decided())
            _write_json(root / "correction_gate.json", _ready_gate(root))
            _write_json(
                root / "passive_apply.json",
                _passive_apply_artifact(
                    root,
                    verdict="dry_run_ready",
                    dry_run=True,
                    applies_delay=True,
                ),
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertEqual(report["phase"], "apply")
        self.assertIn("claims it applied delay", report["reason"])

    def test_missing_gate_for_recommendation_is_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(
                Path(tmp),
                decision={
                    "verdict": "recommend",
                    "auto_apply_eligible": True,
                    "recommended_delay_ms": 2218,
                },
            )
            _write_json(root / "finalize.json", _finalize_decided())
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "incomplete")
        self.assertEqual(report["phase"], "gate")

    def test_unsafe_manifest_stays_not_applicable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp))
            _write_json(
                root / "manifest.json",
                {
                    "schema": "syncast.passive_drift_session.v1",
                    "emitsAudio": False,
                    "appliesDelay": True,
                    "opensMicrophoneOnlyAfterPreflight": True,
                },
            )
            report = pcr.build_report(root)
        self.assertEqual(report["verdict"], "not_applicable")
        self.assertFalse(report["manifestNoDelayWrite"])

    def test_cli_writes_output_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _session(Path(tmp) / "session")
            output = Path(tmp) / "control_report.json"
            old_parse = pcr._parse_args
            try:
                pcr._parse_args = lambda: type(
                    "Args",
                    (),
                    {"session_root": root, "output": output},
                )()
                with mock.patch.object(sys, "stdout"):
                    rc = pcr.main()
            finally:
                pcr._parse_args = old_parse
            self.assertEqual(rc, pcr.EXIT_OK)
            self.assertEqual(json.loads(output.read_text())["verdict"], "ready_for_baseline")


if __name__ == "__main__":
    unittest.main()
