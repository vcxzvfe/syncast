#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

import passive_readiness_report as prr


def _ready_status(**overrides) -> dict:
    status = {
        "ok": True,
        "passiveCaptureAvailable": True,
        "inProgress": False,
        "captureBackend": "tap",
        "enabledAirplayCount": 1,
        "activeAirplayCount": 1,
        "currentDelayMs": 2145,
        "delayLocked": False,
        "contextSignature": "ctx-a",
        "airplayTimingEpoch": 2,
        "syncContextState": "suspect",
        "syncContextReason": "AirPlay connection changed",
        "syncContextRevision": 4,
        "syncContextUpdatedUnix": 1778887421.0,
    }
    status.update(overrides)
    return status


class PassiveReadinessReportTests(unittest.TestCase):
    def test_missing_app_is_not_ready_without_socket_probe(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Missing.app"
            socket = Path(tmp) / "sock"
            with mock.patch.object(prr, "_process_pids", return_value=[]), \
                 mock.patch.object(prr.pce, "_json_rpc") as rpc:
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "not_ready")
        self.assertEqual(report["stage"], "app")
        self.assertFalse(report["opensMicrophone"])
        self.assertFalse(report["emitsAudio"])
        self.assertFalse(report["appliesDelay"])
        rpc.assert_not_called()

    def test_not_running_is_process_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            with mock.patch.object(prr, "_process_pids", return_value=[]):
                report = prr.build_report(
                    socket_path=Path(tmp) / "sock",
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "not_ready")
        self.assertEqual(report["stage"], "process")
        self.assertIn("start SyncCast", report["nextAction"])

    def test_headless_not_running_names_headless_runtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "SyncCastPassiveHeadless"
            binary.touch()
            with mock.patch.object(prr, "_process_pids", return_value=[]):
                report = prr.build_report(
                    socket_path=Path(tmp) / "sock",
                    app_path=binary,
                    process_name="SyncCastPassiveHeadless",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "not_ready")
        self.assertEqual(report["stage"], "process")
        self.assertIn("SyncCastPassiveHeadless", report["nextAction"])

    def test_running_without_socket_is_socket_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            with mock.patch.object(prr, "_process_pids", return_value=[123]):
                report = prr.build_report(
                    socket_path=Path(tmp) / "missing.sock",
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "not_ready")
        self.assertEqual(report["stage"], "socket")
        self.assertTrue(report["processRunning"])
        self.assertFalse(report["socketExists"])

    def test_ping_failure_is_ping_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            socket = Path(tmp) / "sock"
            socket.touch()
            with mock.patch.object(prr, "_process_pids", return_value=[123]), \
                 mock.patch.object(prr.pce, "_json_rpc", side_effect=RuntimeError("stale")):
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "not_ready")
        self.assertEqual(report["stage"], "ping")
        self.assertIn("stale", report["reason"])

    def test_passive_status_not_ready_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            socket = Path(tmp) / "sock"
            socket.touch()
            bad_status = _ready_status(activeAirplayCount=0)
            with mock.patch.object(prr, "_process_pids", return_value=[123]), \
                 mock.patch.object(prr.pce, "_json_rpc", return_value={"ok": True}), \
                 mock.patch.object(prr.pce, "_passive_status", return_value=bad_status):
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "not_ready")
        self.assertEqual(report["stage"], "passive_status")
        self.assertEqual(report["status"], bad_status)
        self.assertIn("AirPlay", report["reason"])

    def test_ready_status_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            socket = Path(tmp) / "sock"
            socket.touch()
            status = _ready_status()
            with mock.patch.object(prr, "_process_pids", return_value=[123]), \
                 mock.patch.object(prr.pce, "_json_rpc", return_value={"ok": True}), \
                 mock.patch.object(prr.pce, "_passive_status", return_value=status):
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "ready")
        self.assertEqual(report["stage"], "ready")
        self.assertTrue(report["passiveReady"])
        self.assertEqual(report["status"], status)
        self.assertEqual(report["syncContextState"], "suspect")
        self.assertEqual(report["syncContextReason"], "AirPlay connection changed")
        self.assertEqual(report["passiveEvidenceIntent"], "baseline_required")
        self.assertEqual(report["passiveEvidenceIntentSource"], "derived")
        self.assertEqual(report["recommendedWorkflow"], "record_baseline")
        self.assertEqual(report["recommendedSessionMode"], "baseline")
        self.assertTrue(report["requiresBaselineStore"])
        self.assertFalse(report["allowsPassiveApply"])
        self.assertTrue(report["baselineRequired"])
        self.assertFalse(report["passiveCanApply"])
        self.assertIn("baseline", report["nextAction"])

    def test_ready_locked_status_is_diagnostic_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            socket = Path(tmp) / "sock"
            socket.touch()
            status = _ready_status(delayLocked=True, syncContextState="locked")
            with mock.patch.object(prr, "_process_pids", return_value=[123]), \
                 mock.patch.object(prr.pce, "_json_rpc", return_value={"ok": True}), \
                 mock.patch.object(prr.pce, "_passive_status", return_value=status):
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "ready")
        self.assertEqual(report["passiveEvidenceIntent"], "diagnostic_locked")
        self.assertEqual(report["recommendedWorkflow"], "locked_diagnostic")
        self.assertEqual(report["recommendedSessionMode"], "diagnostic")
        self.assertFalse(report["requiresBaselineStore"])
        self.assertFalse(report["allowsPassiveApply"])
        self.assertFalse(report["baselineRequired"])
        self.assertFalse(report["passiveCanApply"])
        self.assertIn("diagnostics only", report["nextAction"])

    def test_ready_applied_status_requests_post_apply_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            socket = Path(tmp) / "sock"
            socket.touch()
            status = _ready_status(
                syncContextState="applied",
                syncContextReason="diagnostic passive/app RPC applied delay",
            )
            with mock.patch.object(prr, "_process_pids", return_value=[123]), \
                 mock.patch.object(prr.pce, "_json_rpc", return_value={"ok": True}), \
                 mock.patch.object(prr.pce, "_passive_status", return_value=status):
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "ready")
        self.assertEqual(report["passiveEvidenceIntent"], "post_apply_validation")
        self.assertEqual(report["recommendedWorkflow"], "validate_apply")
        self.assertEqual(report["recommendedSessionMode"], "validation")
        self.assertTrue(report["requiresBaselineStore"])
        self.assertFalse(report["allowsPassiveApply"])
        self.assertFalse(report["passiveCanApply"])
        self.assertIn("validate", report["nextAction"])

    def test_ready_valid_status_is_drift_monitor(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            socket = Path(tmp) / "sock"
            socket.touch()
            status = _ready_status(
                syncContextState="valid",
                syncContextReason="baseline verified",
            )
            with mock.patch.object(prr, "_process_pids", return_value=[123]), \
                 mock.patch.object(prr.pce, "_json_rpc", return_value={"ok": True}), \
                 mock.patch.object(prr.pce, "_passive_status", return_value=status):
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "ready")
        self.assertEqual(report["passiveEvidenceIntent"], "drift_monitor")
        self.assertEqual(report["recommendedWorkflow"], "monitor_drift")
        self.assertEqual(report["recommendedSessionMode"], "correction")
        self.assertTrue(report["requiresBaselineStore"])
        self.assertTrue(report["allowsPassiveApply"])
        self.assertTrue(report["passiveCanApply"])
        self.assertIn("drift session", report["nextAction"])

    def test_ready_to_dry_run_status_is_apply_dry_run_workflow(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            socket = Path(tmp) / "sock"
            socket.touch()
            status = _ready_status(
                syncContextState="readyToDryRun",
                syncContextReason="repeat-confirmed correction",
            )
            with mock.patch.object(prr, "_process_pids", return_value=[123]), \
                 mock.patch.object(prr.pce, "_json_rpc", return_value={"ok": True}), \
                 mock.patch.object(prr.pce, "_passive_status", return_value=status):
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "ready")
        self.assertEqual(report["passiveEvidenceIntent"], "dry_run_candidate")
        self.assertEqual(report["recommendedWorkflow"], "apply_dry_run")
        self.assertEqual(report["recommendedSessionMode"], "apply_dry_run")
        self.assertTrue(report["requiresBaselineStore"])
        self.assertFalse(report["allowsPassiveApply"])
        self.assertFalse(report["passiveCanApply"])

    def test_dry_run_ready_status_blocks_automatic_workflow(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            socket = Path(tmp) / "sock"
            socket.touch()
            status = _ready_status(
                syncContextState="dryRunReady",
                syncContextReason="dry-run accepted candidate",
                passiveDryRunTargetDelayMs=2165,
                passiveDryRunCurrentDelayMs=2145,
                passiveDryRunContextSignature="ctx-a",
                passiveDryRunCaptureBackend="tap",
                passiveDryRunEnabledAirplayCount=1,
                passiveDryRunActiveAirplayCount=1,
                passiveDryRunAirplayTimingEpoch=2,
                passiveDryRunAcceptedFromSyncContextState="valid",
                passiveDryRunAcceptedFromSyncContextRevision=7,
                passiveDryRunAcceptedSyncContextRevision=8,
                passiveDryRunSessionRoot="/tmp/passive-session",
                passiveDryRunControlReport="/tmp/passive-session/control_report.json",
                passiveDryRunAcceptedUnix=time.time(),
            )
            with mock.patch.object(prr, "_process_pids", return_value=[123]), \
                 mock.patch.object(prr.pce, "_json_rpc", return_value={"ok": True}), \
                 mock.patch.object(prr.pce, "_passive_status", return_value=status):
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "ready")
        self.assertEqual(report["passiveEvidenceIntent"], "manual_validation_required")
        self.assertEqual(report["recommendedWorkflow"], "manual_validation")
        self.assertEqual(report["recommendedSessionMode"], "manual_validation")
        self.assertTrue(report["requiresBaselineStore"])
        self.assertFalse(report["allowsPassiveApply"])
        self.assertFalse(report["passiveCanApply"])
        self.assertEqual(report["passiveDryRunTargetDelayMs"], 2165)
        self.assertEqual(report["passiveDryRunCurrentDelayMs"], 2145)
        self.assertEqual(report["passiveDryRunContextSignature"], "ctx-a")
        self.assertEqual(report["passiveDryRunCaptureBackend"], "tap")
        self.assertEqual(report["passiveDryRunEnabledAirplayCount"], 1)
        self.assertEqual(report["passiveDryRunActiveAirplayCount"], 1)
        self.assertEqual(report["passiveDryRunAirplayTimingEpoch"], 2)
        self.assertEqual(report["passiveDryRunAcceptedFromSyncContextState"], "valid")
        self.assertEqual(report["passiveDryRunAcceptedFromSyncContextRevision"], 7)
        self.assertEqual(report["passiveDryRunAcceptedSyncContextRevision"], 8)
        self.assertEqual(report["passiveDryRunSessionRoot"], "/tmp/passive-session")

    def test_dry_run_ready_expired_candidate_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            socket = Path(tmp) / "sock"
            socket.touch()
            status = _ready_status(
                syncContextState="dryRunReady",
                syncContextReason="dry-run accepted candidate",
                passiveDryRunTargetDelayMs=2165,
                passiveDryRunCurrentDelayMs=2145,
                passiveDryRunContextSignature="ctx-a",
                passiveDryRunCaptureBackend="tap",
                passiveDryRunEnabledAirplayCount=1,
                passiveDryRunActiveAirplayCount=1,
                passiveDryRunAirplayTimingEpoch=2,
                passiveDryRunAcceptedSyncContextRevision=8,
                passiveDryRunAcceptedUnix=(
                    time.time() - prr.ACCEPTED_DRY_RUN_MAX_AGE_SEC - 1
                ),
            )
            with mock.patch.object(prr, "_process_pids", return_value=[123]), \
                 mock.patch.object(prr.pce, "_json_rpc", return_value={"ok": True}), \
                 mock.patch.object(prr.pce, "_passive_status", return_value=status):
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "not_ready")
        self.assertEqual(report["stage"], "passive_status")
        self.assertIn("expired", report["reason"])

    def test_unknown_app_passive_evidence_intent_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            socket = Path(tmp) / "sock"
            socket.touch()
            status = _ready_status(
                passiveEvidenceIntent="future_runtime_intent",
                baselineRequired=False,
                passiveCanApply=True,
            )
            with mock.patch.object(prr, "_process_pids", return_value=[123]), \
                 mock.patch.object(prr.pce, "_json_rpc", return_value={"ok": True}), \
                 mock.patch.object(prr.pce, "_passive_status", return_value=status):
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "not_ready")
        self.assertEqual(report["stage"], "passive_status")
        self.assertFalse(report["passiveReady"])
        self.assertIn("unknown passiveEvidenceIntent", report["reason"])
        self.assertIn("update SyncCast", report["nextAction"])

    def test_unknown_sync_context_state_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            socket = Path(tmp) / "sock"
            socket.touch()
            status = _ready_status(syncContextState="futureState")
            with mock.patch.object(prr, "_process_pids", return_value=[123]), \
                 mock.patch.object(prr.pce, "_json_rpc", return_value={"ok": True}), \
                 mock.patch.object(prr.pce, "_passive_status", return_value=status):
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "not_ready")
        self.assertEqual(report["stage"], "passive_status")
        self.assertFalse(report["passiveReady"])
        self.assertIn("sync context state is unknown", report["reason"])

    def test_ready_prefers_app_provided_passive_evidence_intent(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "SyncCast.app"
            app.mkdir()
            socket = Path(tmp) / "sock"
            socket.touch()
            status = _ready_status(
                syncContextState="valid",
                passiveEvidenceIntent="baseline_required",
                baselineRequired=True,
                passiveCanApply=False,
                passiveNextAction="record app-classified baseline",
                passiveEvidenceReason="runtime classified route as suspect",
            )
            with mock.patch.object(prr, "_process_pids", return_value=[123]), \
                 mock.patch.object(prr.pce, "_json_rpc", return_value={"ok": True}), \
                 mock.patch.object(prr.pce, "_passive_status", return_value=status):
                report = prr.build_report(
                    socket_path=socket,
                    app_path=app,
                    process_name="SyncCastMenuBar",
                    timeout_sec=0.1,
                )
        self.assertEqual(report["verdict"], "ready")
        self.assertEqual(report["passiveEvidenceIntent"], "baseline_required")
        self.assertEqual(report["passiveEvidenceIntentSource"], "app_status")
        self.assertEqual(report["recommendedWorkflow"], "record_baseline")
        self.assertEqual(report["recommendedSessionMode"], "baseline")
        self.assertTrue(report["baselineRequired"])
        self.assertFalse(report["passiveCanApply"])
        self.assertEqual(report["nextAction"], "record app-classified baseline")
        self.assertEqual(report["reason"], "runtime classified route as suspect")

    def test_wait_for_report_retries_until_ready(self):
        now = {"value": 0.0}

        def time_fn() -> float:
            return now["value"]

        def sleep_fn(duration: float) -> None:
            now["value"] += duration

        with mock.patch.object(
            prr,
            "build_report",
            side_effect=[
                {"verdict": "not_ready", "stage": "process", "reason": "not running"},
                {"verdict": "ready", "stage": "ready", "reason": "ok"},
            ],
        ):
            report = prr.wait_for_report(
                socket_path=Path("/tmp/fake.sock"),
                app_path=Path("/tmp/SyncCast.app"),
                process_name="SyncCastMenuBar",
                timeout_sec=0.1,
                wait_sec=1.0,
                interval_sec=0.25,
                time_fn=time_fn,
                sleep_fn=sleep_fn,
            )
        self.assertEqual(report["verdict"], "ready")
        self.assertEqual(report["attemptCount"], 2)
        self.assertEqual(report["attempts"][0]["stage"], "process")
        self.assertEqual(report["attempts"][1]["stage"], "ready")
        self.assertIn("passiveEvidenceIntent", report["attempts"][1])
        self.assertIn("passiveEvidenceIntentSource", report["attempts"][1])
        self.assertIn("recommendedWorkflow", report["attempts"][1])
        self.assertEqual(report["waitedSec"], 0.25)

    def test_wait_for_report_stops_at_timeout(self):
        now = {"value": 0.0}

        def time_fn() -> float:
            return now["value"]

        def sleep_fn(duration: float) -> None:
            now["value"] += duration

        with mock.patch.object(
            prr,
            "build_report",
            return_value={
                "verdict": "not_ready",
                "stage": "socket",
                "reason": "missing socket",
            },
        ):
            report = prr.wait_for_report(
                socket_path=Path("/tmp/fake.sock"),
                app_path=Path("/tmp/SyncCast.app"),
                process_name="SyncCastMenuBar",
                timeout_sec=0.1,
                wait_sec=0.5,
                interval_sec=0.2,
                time_fn=time_fn,
                sleep_fn=sleep_fn,
            )
        self.assertEqual(report["verdict"], "not_ready")
        self.assertEqual(report["stage"], "socket")
        self.assertGreaterEqual(report["attemptCount"], 3)
        self.assertEqual(report["waitedSec"], 0.5)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
