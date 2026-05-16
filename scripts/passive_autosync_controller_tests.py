#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import passive_autosync_controller as pac


def _ready(workflow: str) -> dict:
    intent_by_workflow = {
        "record_baseline": "baseline_required",
        "monitor_drift": "drift_monitor",
        "validate_apply": "post_apply_validation",
        "locked_diagnostic": "diagnostic_locked",
        "apply_dry_run": "dry_run_candidate",
        "manual_validation": "manual_validation_required",
    }
    return {
        "schema": "syncast.passive_readiness.v1",
        "verdict": "ready",
        "recommendedWorkflow": workflow,
        "recommendedSessionMode": workflow,
        "passiveEvidenceIntent": intent_by_workflow[workflow],
        "passiveEvidenceIntentSource": "app_status",
        "opensMicrophone": False,
        "emitsAudio": False,
        "appliesDelay": False,
    }


def _plan(
    readiness: dict,
    root: Path,
    *,
    candidate_session: Path | None = None,
    allow_accepted_delay_apply: bool = False,
) -> dict:
    return pac.build_plan(
        readiness=readiness,
        state_root=root / "state",
        session_root=root / "session",
        socket=Path("/tmp/syncast-test.sock"),
        samples=3,
        interval_sec=10,
        duration_sec=2,
        candidate_session=candidate_session,
        allow_accepted_delay_apply=allow_accepted_delay_apply,
    )


class PassiveAutosyncControllerTests(unittest.TestCase):
    def test_not_ready_blocks_without_microphone_or_delay(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = _plan(
                {
                    "verdict": "not_ready",
                    "stage": "process",
                    "reason": "SyncCastMenuBar is not running",
                    "nextAction": "start SyncCast",
                },
                Path(tmp),
            )
        self.assertEqual(plan["verdict"], "blocked")
        self.assertFalse(plan["opensMicrophone"])
        self.assertFalse(plan["emitsAudio"])
        self.assertFalse(plan["appliesDelay"])
        self.assertIsNone(plan["command"])

    def test_not_ready_with_auto_start_targets_plans_readiness_bootstrap(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = pac.build_plan(
                readiness={
                    "verdict": "not_ready",
                    "stage": "process",
                    "reason": "SyncCastMenuBar is not running",
                },
                state_root=root / "state",
                session_root=root / "session",
                socket=Path("/tmp/syncast-test.sock"),
                samples=3,
                interval_sec=10,
                duration_sec=2,
                auto_start_targets="display,xiaomi",
                auto_capture_backend="tap",
                auto_launch_mode="headless",
            )

        self.assertEqual(plan["verdict"], "ready_to_run_readiness_bootstrap")
        self.assertFalse(plan["opensMicrophone"])
        self.assertFalse(plan["emitsAudio"])
        self.assertFalse(plan["appliesDelay"])
        self.assertTrue(plan["changesRoutes"])
        self.assertEqual(plan["environment"]["SYNCAST_PASSIVE_READINESS_ONLY"], "1")
        self.assertEqual(
            plan["environment"]["SYNCAST_PASSIVE_AUTO_START_TARGETS"],
            "display,xiaomi",
        )
        self.assertEqual(plan["environment"]["SYNCAST_PASSIVE_AUTO_CAPTURE_BACKEND"], "tap")
        self.assertEqual(plan["environment"]["SYNCAST_PASSIVE_AUTO_LAUNCH_MODE"], "headless")

    def test_record_baseline_plans_marked_no_apply_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = _plan(_ready("record_baseline"), Path(tmp))
        self.assertEqual(plan["verdict"], "ready_to_run_session")
        self.assertTrue(plan["opensMicrophone"])
        self.assertFalse(plan["appliesDelay"])
        self.assertEqual(plan["environment"]["SYNCAST_PASSIVE_BASELINE_MODE"], "auto")
        self.assertEqual(plan["environment"]["SYNCAST_PASSIVE_BASELINE_MARK_MODE"], "mark")
        self.assertEqual(plan["environment"]["SYNCAST_PASSIVE_APPLY_MODE"], "dry-run")
        self.assertIn("SYNCAST_PASSIVE_CONTROL_STATE", plan["environment"])

    def test_monitor_drift_plans_repeat_confirmed_dry_run_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = _plan(_ready("monitor_drift"), Path(tmp))
        self.assertEqual(plan["verdict"], "ready_to_run_session")
        self.assertEqual(plan["environment"]["SYNCAST_PASSIVE_BASELINE_MODE"], "decide")
        self.assertEqual(plan["environment"]["SYNCAST_PASSIVE_BASELINE_MARK_MODE"], "off")
        self.assertEqual(plan["environment"]["SYNCAST_PASSIVE_APPLY_MODE"], "dry-run")
        self.assertIn("SYNCAST_PASSIVE_CONTROL_STATE", plan["environment"])
        self.assertFalse(plan["emitsAudio"])
        self.assertFalse(plan["appliesDelay"])

    def test_validate_apply_disables_apply_dry_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = _plan(_ready("validate_apply"), Path(tmp))
        self.assertEqual(plan["verdict"], "ready_to_run_session")
        self.assertEqual(plan["environment"]["SYNCAST_PASSIVE_APPLY_MODE"], "off")
        self.assertIn("validate", plan["reason"])

    def test_locked_diagnostic_has_no_apply_or_baseline_mark(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = _plan(_ready("locked_diagnostic"), Path(tmp))
        self.assertEqual(plan["verdict"], "ready_to_run_session")
        self.assertEqual(plan["environment"]["SYNCAST_PASSIVE_APPLY_MODE"], "off")
        self.assertEqual(plan["environment"]["SYNCAST_PASSIVE_BASELINE_MARK_MODE"], "off")

    def test_apply_dry_run_requires_existing_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = _plan(_ready("apply_dry_run"), Path(tmp))
        self.assertEqual(plan["verdict"], "blocked")
        self.assertFalse(plan["opensMicrophone"])
        self.assertIsNone(plan["command"])

    def test_apply_dry_run_uses_explicit_candidate_without_apply_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            candidate = Path(tmp) / "candidate"
            candidate.mkdir()
            plan = _plan(
                _ready("apply_dry_run"),
                Path(tmp),
                candidate_session=candidate,
            )
        self.assertEqual(plan["verdict"], "ready_to_run_apply_dry_run")
        self.assertFalse(plan["opensMicrophone"])
        self.assertFalse(plan["appliesDelay"])
        self.assertNotIn("--apply", plan["command"])
        self.assertEqual(plan["command"][1], "scripts/passive_apply_candidate.py")

    def test_apply_dry_run_finds_latest_candidate_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = root / "state" / "sessions" / "old"
            new = root / "state" / "sessions" / "new"
            old.mkdir(parents=True)
            new.mkdir(parents=True)
            for session in (old, new):
                (session / "control_report.json").write_text(
                    json.dumps({"verdict": "ready_for_apply_candidate"})
                )
            os.utime(old / "control_report.json", (100, 100))
            os.utime(new / "control_report.json", (200, 200))

            plan = _plan(_ready("apply_dry_run"), root)

        self.assertEqual(plan["verdict"], "ready_to_run_apply_dry_run")
        self.assertTrue(plan["sessionRoot"].endswith("/new"))

    def test_apply_dry_run_skips_already_dry_run_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            candidate = root / "state" / "sessions" / "candidate"
            candidate.mkdir(parents=True)
            (candidate / "control_report.json").write_text(
                json.dumps({"verdict": "ready_for_apply_candidate"})
            )
            (candidate / "passive_apply.json").write_text(
                json.dumps({"verdict": "dry_run_ready", "appliesDelay": False})
            )

            plan = _plan(_ready("apply_dry_run"), root)

        self.assertEqual(plan["verdict"], "blocked")
        self.assertIsNone(plan["command"])
        self.assertFalse(plan["opensMicrophone"])

    def test_apply_dry_run_blocks_corrupt_candidate_apply_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            candidate = root / "state" / "sessions" / "candidate"
            candidate.mkdir(parents=True)
            (candidate / "control_report.json").write_text(
                json.dumps({"verdict": "ready_for_apply_candidate"})
            )
            (candidate / "passive_apply.json").write_text("{not json")

            plan = _plan(_ready("apply_dry_run"), root)

        self.assertEqual(plan["verdict"], "blocked")
        self.assertIsNone(plan["command"])
        self.assertFalse(plan["opensMicrophone"])
        self.assertIn("passive_apply.json", plan["reason"])
        self.assertIn("invalid JSON", plan["reason"])

    def test_apply_dry_run_blocks_newer_corrupt_candidate_control_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = root / "state" / "sessions" / "old"
            new = root / "state" / "sessions" / "new"
            old.mkdir(parents=True)
            new.mkdir(parents=True)
            (old / "control_report.json").write_text(
                json.dumps({"verdict": "ready_for_apply_candidate"})
            )
            (new / "control_report.json").write_text("{not json")
            os.utime(old / "control_report.json", (100, 100))
            os.utime(new / "control_report.json", (200, 200))

            plan = _plan(_ready("apply_dry_run"), root)

        self.assertEqual(plan["verdict"], "blocked")
        self.assertIsNone(plan["command"])
        self.assertFalse(plan["opensMicrophone"])
        self.assertIn("control_report.json", plan["reason"])
        self.assertIn("invalid candidate control_report JSON", plan["reason"])

    def test_apply_dry_run_ignores_older_corrupt_control_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = root / "state" / "sessions" / "old"
            new = root / "state" / "sessions" / "new"
            old.mkdir(parents=True)
            new.mkdir(parents=True)
            (old / "control_report.json").write_text("{not json")
            (new / "control_report.json").write_text(
                json.dumps({"verdict": "ready_for_apply_candidate"})
            )
            os.utime(old / "control_report.json", (100, 100))
            os.utime(new / "control_report.json", (200, 200))

            plan = _plan(_ready("apply_dry_run"), root)

        self.assertEqual(plan["verdict"], "ready_to_run_apply_dry_run")
        self.assertTrue(plan["sessionRoot"].endswith("/new"))

    def test_apply_dry_run_blocks_explicit_corrupt_candidate_apply_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            candidate = root / "candidate"
            candidate.mkdir()
            (candidate / "passive_apply.json").write_text("{not json")

            plan = _plan(
                _ready("apply_dry_run"),
                root,
                candidate_session=candidate,
            )

        self.assertEqual(plan["verdict"], "blocked")
        self.assertIsNone(plan["command"])
        self.assertIn("passive_apply.json", plan["reason"])

    def test_manual_validation_rechecks_accepted_candidate_without_mic(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            readiness = _ready("manual_validation")
            readiness.update(
                {
                    "passiveDryRunSessionRoot": str(root / "candidate"),
                    "passiveDryRunTargetDelayMs": 2165,
                    "passiveDryRunCurrentDelayMs": 2145,
                    "passiveDryRunContextSignature": "ctx-a",
                    "passiveDryRunCaptureBackend": "tap",
                    "passiveDryRunEnabledAirplayCount": 1,
                    "passiveDryRunActiveAirplayCount": 1,
                    "passiveDryRunAirplayTimingEpoch": 42,
                    "passiveDryRunAcceptedSyncContextRevision": 8,
                }
            )
            plan = _plan(readiness, root)

        self.assertEqual(plan["verdict"], "ready_to_run_accepted_candidate_dry_run")
        self.assertEqual(plan["command"][1], "scripts/passive_apply_accepted_candidate.py")
        self.assertEqual(plan["sessionRoot"], str(root / "candidate"))
        self.assertIn("--expected-session-root", plan["command"])
        self.assertIn("--expected-active-airplay-count", plan["command"])
        self.assertEqual(
            plan["command"][plan["command"].index("--expected-session-root") + 1],
            str(root / "candidate"),
        )
        self.assertFalse(plan["opensMicrophone"])
        self.assertFalse(plan["appliesDelay"])

    def test_manual_validation_can_plan_explicit_guarded_apply_when_allowed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            readiness = _ready("manual_validation")
            readiness.update(
                {
                    "passiveDryRunSessionRoot": str(root / "candidate"),
                    "passiveDryRunTargetDelayMs": 2165,
                    "passiveDryRunCurrentDelayMs": 2145,
                    "passiveDryRunContextSignature": "ctx-a",
                    "passiveDryRunCaptureBackend": "tap",
                    "passiveDryRunEnabledAirplayCount": 1,
                    "passiveDryRunActiveAirplayCount": 1,
                    "passiveDryRunAirplayTimingEpoch": 42,
                    "passiveDryRunAcceptedSyncContextRevision": 8,
                }
            )
            plan = _plan(
                readiness,
                root,
                allow_accepted_delay_apply=True,
            )

        self.assertEqual(plan["verdict"], "ready_to_run_accepted_candidate_apply")
        self.assertEqual(plan["command"][1], "scripts/passive_apply_accepted_candidate.py")
        self.assertIn("--apply", plan["command"])
        self.assertIn("--expected-session-root", plan["command"])
        self.assertIn("--expected-context-signature", plan["command"])
        self.assertTrue(plan["appliesDelay"])
        self.assertTrue(plan["allowAcceptedDelayApply"])
        self.assertFalse(plan["opensMicrophone"])
        self.assertFalse(plan["emitsAudio"])

    def test_summarize_execution_binds_control_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session = root / "session"
            session.mkdir()
            (session / "control_report.json").write_text(
                json.dumps(
                    {
                        "verdict": "pending_confirmation",
                        "phase": "gate",
                        "reason": "repeat confirmation required",
                        "nextAction": "collect one more session",
                        "appliesDelay": False,
                        "emitsAudio": False,
                    }
                )
            )
            plan = _plan(_ready("monitor_drift"), root)
            plan["sessionRoot"] = str(session)

            summary = pac.summarize_execution(plan, 0)

        self.assertEqual(summary["verdict"], "pending_confirmation")
        self.assertEqual(summary["phase"], "gate")
        self.assertEqual(summary["nextAction"], "collect one more session")
        self.assertFalse(summary["appliesDelay"])
        self.assertFalse(summary["emitsAudio"])

    def test_summarize_execution_flags_unexpected_delay_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session = root / "session"
            session.mkdir()
            (session / "passive_apply.json").write_text(
                json.dumps(
                    {
                        "verdict": "applied",
                        "appliesDelay": True,
                        "result": {"reason": "applied"},
                    }
                )
            )
            plan = _plan(_ready("apply_dry_run"), root, candidate_session=session)

            summary = pac.summarize_execution(plan, 0)

        self.assertEqual(summary["verdict"], "applied")
        self.assertTrue(summary["appliesDelay"])
        self.assertIn("safetyIssue", summary)

    def test_summarize_apply_dry_run_prefers_fresh_apply_result(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session = root / "session"
            session.mkdir()
            (session / "control_report.json").write_text(
                json.dumps(
                    {
                        "verdict": "ready_for_apply_candidate",
                        "phase": "decision",
                        "reason": "stale candidate report",
                        "appliesDelay": False,
                    }
                )
            )
            (session / "passive_apply.json").write_text(
                json.dumps(
                    {
                        "verdict": "dry_run_ready",
                        "appliesDelay": False,
                        "result": {"reason": "fresh dry-run accepted"},
                    }
                )
            )
            plan = _plan(_ready("apply_dry_run"), root, candidate_session=session)

            summary = pac.summarize_execution(plan, 0)

        self.assertEqual(summary["verdict"], "dry_run_ready")
        self.assertEqual(summary["passiveApplyVerdict"], "dry_run_ready")
        self.assertFalse(summary["appliesDelay"])

    def test_summarize_execution_flags_corrupt_execution_artifacts(self):
        artifact_names = [
            "control_report.json",
            "passive_apply.json",
            "passive_accepted_apply.json",
            "passive_rollback.json",
        ]
        for artifact_name in artifact_names:
            with self.subTest(artifact_name=artifact_name):
                with tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    session = root / "session"
                    session.mkdir()
                    (session / artifact_name).write_text("{not json")
                    plan = _plan(_ready("monitor_drift"), root)
                    plan["sessionRoot"] = str(session)

                    summary = pac.summarize_execution(plan, 0, started_unix=0)

                self.assertEqual(summary["verdict"], "incomplete")
                self.assertEqual(summary["phase"], "artifact_json")
                self.assertEqual(summary["blockingStage"], "artifact_json")
                self.assertIn(artifact_name, summary["reason"])
                self.assertIn("invalid JSON", summary["reason"])
                self.assertIn("artifactIssues", summary)
                self.assertIn("safetyIssue", summary)

    def test_execute_plan_attaches_summary_after_subprocess(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session = root / "session"
            plan = _plan(_ready("monitor_drift"), root)
            plan["sessionRoot"] = str(session)
            completed = type("Completed", (), {"returncode": 0})()

            def fake_run(command, env, check):
                session.mkdir(parents=True, exist_ok=True)
                (session / "control_report.json").write_text(
                    json.dumps(
                        {
                            "verdict": "hold",
                            "phase": "decision",
                            "reason": "stable",
                            "appliesDelay": False,
                        }
                    )
                )
                return completed

            with mock.patch.object(pac.subprocess, "run", side_effect=fake_run) as run:
                executed = pac.execute_plan(plan)

        self.assertEqual(executed["execution"]["verdict"], "hold")
        self.assertEqual(run.call_args.args[0], plan["command"])
        self.assertFalse(executed["execution"]["appliesDelay"])
        self.assertEqual(executed["followUpPlan"]["verdict"], "blocked")
        self.assertIsNone(executed["followUpPlan"]["command"])

    def test_follow_up_after_baseline_recorded_collects_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(_ready("record_baseline"), root)
            summary = {
                "verdict": "baseline_recorded",
                "sessionRoot": plan["sessionRoot"],
                "appliesDelay": False,
            }

            follow_up = pac.follow_up_plan(plan, summary)

        self.assertEqual(follow_up["verdict"], "ready_to_run_session")
        self.assertEqual(follow_up["environment"]["SYNCAST_PASSIVE_BASELINE_MODE"], "decide")
        self.assertEqual(follow_up["environment"]["SYNCAST_PASSIVE_APPLY_MODE"], "dry-run")
        self.assertTrue(follow_up["opensMicrophone"])

    def test_follow_up_after_pending_confirmation_collects_repeat(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(_ready("monitor_drift"), root)
            summary = {
                "verdict": "pending_confirmation",
                "sessionRoot": plan["sessionRoot"],
                "appliesDelay": False,
            }

            follow_up = pac.follow_up_plan(plan, summary)

        self.assertEqual(follow_up["verdict"], "ready_to_run_session")
        self.assertEqual(follow_up["environment"]["SYNCAST_PASSIVE_BASELINE_MODE"], "decide")
        self.assertEqual(follow_up["environment"]["SYNCAST_PASSIVE_APPLY_MODE"], "dry-run")

    def test_follow_up_after_ready_candidate_runs_dry_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session = root / "session"
            session.mkdir()
            plan = _plan(_ready("monitor_drift"), root)
            plan["sessionRoot"] = str(session)
            summary = {
                "verdict": "ready_for_apply_candidate",
                "sessionRoot": str(session),
                "appliesDelay": False,
            }

            follow_up = pac.follow_up_plan(plan, summary)

        self.assertEqual(follow_up["verdict"], "ready_to_run_apply_dry_run")
        self.assertFalse(follow_up["opensMicrophone"])
        self.assertNotIn("--apply", follow_up["command"])

    def test_follow_up_after_dry_run_ready_stops_before_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(_ready("apply_dry_run"), root, candidate_session=root / "session")

            follow_up = pac.follow_up_plan(
                plan,
                {"verdict": "dry_run_ready", "appliesDelay": False},
            )

        self.assertEqual(follow_up["verdict"], "blocked")
        self.assertIsNone(follow_up["command"])
        self.assertFalse(follow_up["appliesDelay"])

    def test_follow_up_after_dry_run_ready_waits_for_app_promotion_when_allowed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(
                _ready("apply_dry_run"),
                root,
                candidate_session=root / "session",
                allow_accepted_delay_apply=True,
            )

            follow_up = pac.follow_up_plan(
                plan,
                {
                    "verdict": "dry_run_ready",
                    "sessionRoot": str(root / "session"),
                    "controlReport": str(root / "session" / "control_report.json"),
                    "appliesDelay": False,
                    "passiveApplyResult": {
                        "targetDelayMs": 2165,
                        "currentDelayMs": 2145,
                        "contextSignature": "ctx-a",
                        "captureBackend": "tap",
                        "enabledAirplayCount": 1,
                        "activeAirplayCount": 1,
                        "airplayTimingEpoch": 42,
                        "syncContextRevision": 8,
                    },
                },
            )

        self.assertEqual(follow_up["verdict"], "blocked")
        self.assertIsNone(follow_up["command"])
        self.assertIn("promote dryRunReady", follow_up["reason"])
        self.assertFalse(follow_up["appliesDelay"])
        self.assertTrue(follow_up["allowAcceptedDelayApply"])
        self.assertFalse(follow_up["opensMicrophone"])

    def test_follow_up_after_applied_validation_failure_plans_rollback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(
                _ready("manual_validation"),
                root,
                allow_accepted_delay_apply=True,
            )

            validation = pac.follow_up_plan(
                plan,
                {
                    "verdict": "applied",
                    "sessionRoot": str(root / "session"),
                    "appliesDelay": True,
                    "passiveAcceptedApply": str(
                        root / "session" / "passive_accepted_apply.json"
                    ),
                    "passiveAcceptedApplyResult": {
                        "previousDelayMs": 2145,
                        "appliedDelayMs": 2165,
                        "contextSignature": "ctx-a",
                        "captureBackend": "tap",
                        "enabledAirplayCount": 1,
                        "activeAirplayCount": 1,
                        "airplayTimingEpoch": 42,
                        "syncContextRevision": 9,
                        "reason": "accepted_passive_candidate",
                    },
                },
            )
            rollback = pac.follow_up_plan(
                validation,
                {
                    "verdict": "command_failed",
                    "exitCode": 4,
                    "reason": "post-apply validation failed",
                    "appliesDelay": False,
                },
            )

        self.assertEqual(validation["rollbackDelayMs"], 2145)
        self.assertEqual(validation["rollbackExpectedCurrentDelayMs"], 2165)
        self.assertEqual(rollback["verdict"], "ready_to_run_delay_rollback")
        self.assertEqual(rollback["command"][1], "scripts/passive_rollback_delay.py")
        self.assertIn("--target-delay-ms", rollback["command"])
        self.assertIn("--expected-current-delay-ms", rollback["command"])
        self.assertEqual(
            rollback["command"][rollback["command"].index("--expected-context-signature") + 1],
            "ctx-a",
        )
        self.assertEqual(
            rollback["command"][rollback["command"].index("--expected-sync-context-revision") + 1],
            "9",
        )
        self.assertTrue(rollback["appliesDelay"])
        self.assertTrue(rollback["allowAcceptedDelayApply"])
        self.assertFalse(rollback["opensMicrophone"])

    def test_follow_up_after_readiness_bootstrap_ready_plans_real_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bootstrap = pac.build_plan(
                readiness={"verdict": "not_ready", "stage": "process"},
                state_root=root / "state",
                session_root=root / "bootstrap",
                socket=Path("/tmp/syncast-test.sock"),
                samples=3,
                interval_sec=10,
                duration_sec=2,
                auto_start_targets="display,xiaomi",
                auto_capture_backend="tap",
                auto_launch_mode="headless",
            )

            follow_up = pac.follow_up_plan(
                bootstrap,
                {
                    "verdict": "capture_failed",
                    "readinessVerdict": "ready",
                    "readinessRecommendedWorkflow": "record_baseline",
                    "readinessRecommendedSessionMode": "baseline",
                    "readinessPassiveEvidenceIntent": "baseline_required",
                    "readinessPassiveEvidenceIntentSource": "app_status",
                    "appliesDelay": False,
                },
            )

        self.assertEqual(follow_up["verdict"], "ready_to_run_session")
        self.assertTrue(follow_up["opensMicrophone"])
        self.assertNotIn("SYNCAST_PASSIVE_READINESS_ONLY", follow_up["environment"])
        self.assertEqual(follow_up["environment"]["SYNCAST_PASSIVE_BASELINE_MODE"], "auto")
        self.assertEqual(
            follow_up["environment"]["SYNCAST_PASSIVE_AUTO_START_TARGETS"],
            "display,xiaomi",
        )

    def test_follow_up_after_readiness_bootstrap_not_ready_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bootstrap = pac.build_plan(
                readiness={"verdict": "not_ready", "stage": "process"},
                state_root=root / "state",
                session_root=root / "bootstrap",
                socket=Path("/tmp/syncast-test.sock"),
                samples=3,
                interval_sec=10,
                duration_sec=2,
                auto_start_targets="display,xiaomi",
            )

            follow_up = pac.follow_up_plan(
                bootstrap,
                {
                    "verdict": "capture_failed",
                    "reason": "socket missing",
                    "readinessVerdict": "not_ready",
                    "appliesDelay": False,
                },
            )

        self.assertEqual(follow_up["verdict"], "blocked")
        self.assertIsNone(follow_up["command"])
        self.assertFalse(follow_up["opensMicrophone"])

    def test_execute_chain_stops_without_subprocess_for_blocked_plan(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(
                {
                    "verdict": "not_ready",
                    "stage": "process",
                    "reason": "SyncCastMenuBar is not running",
                },
                root,
            )

            with mock.patch.object(pac.subprocess, "run") as run:
                result = pac.execute_chain(plan, max_steps=3)

        run.assert_not_called()
        self.assertEqual(result["chainSummary"]["stepsExecuted"], 1)
        self.assertEqual(result["chainSummary"]["stopReason"], "plan_not_executable")
        self.assertEqual(result["execution"]["exitCode"], pac.EXIT_NOT_READY)

    def test_execute_chain_collects_baseline_then_follow_up_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(_ready("record_baseline"), root)
            completed = type("Completed", (), {"returncode": 0})()
            calls = {"count": 0}

            def fake_run(command, env, check):
                session = Path(command[5])
                session.mkdir(parents=True, exist_ok=True)
                verdict = "baseline_recorded" if calls["count"] == 0 else "hold"
                (session / "control_report.json").write_text(
                    json.dumps(
                        {
                            "verdict": verdict,
                            "phase": "decision",
                            "reason": verdict,
                            "appliesDelay": False,
                            "emitsAudio": False,
                        }
                    )
                )
                calls["count"] += 1
                return completed

            with mock.patch.object(pac.subprocess, "run", side_effect=fake_run) as run:
                result = pac.execute_chain(plan, max_steps=3)

        self.assertEqual(run.call_count, 2)
        self.assertEqual(result["chainSummary"]["stepsExecuted"], 2)
        self.assertEqual(result["chain"][0]["execution"]["verdict"], "baseline_recorded")
        self.assertEqual(result["execution"]["verdict"], "hold")
        self.assertEqual(result["chainSummary"]["stopReason"], "follow_up_blocked")
        self.assertFalse(result["chainSummary"]["appliesDelay"])

    def test_execute_chain_stops_on_command_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(_ready("monitor_drift"), root)
            completed = type("Completed", (), {"returncode": 4})()

            with mock.patch.object(pac.subprocess, "run", return_value=completed) as run:
                result = pac.execute_chain(plan, max_steps=3)

        self.assertEqual(run.call_count, 1)
        self.assertEqual(result["chainSummary"]["stepsExecuted"], 1)
        self.assertEqual(result["chainSummary"]["stopReason"], "command_failed")
        self.assertEqual(result["execution"]["exitCode"], 4)

    def test_execute_chain_nonzero_exit_ignores_stale_ready_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(_ready("monitor_drift"), root)
            session = Path(plan["sessionRoot"])
            session.mkdir()
            (session / "control_report.json").write_text(
                json.dumps(
                    {
                        "verdict": "ready_for_apply_candidate",
                        "reason": "old ready artifact",
                        "appliesDelay": False,
                    }
                )
            )
            completed = type("Completed", (), {"returncode": 4})()

            with mock.patch.object(pac.subprocess, "run", return_value=completed) as run:
                result = pac.execute_chain(plan, max_steps=3)

        self.assertEqual(run.call_count, 1)
        self.assertEqual(result["execution"]["verdict"], "command_failed")
        self.assertIn(str(session / "control_report.json"), result["execution"]["staleArtifacts"])
        self.assertEqual(result["chainSummary"]["stopReason"], "command_failed")

    def test_execute_chain_nonzero_exit_preserves_fresh_artifact_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(_ready("monitor_drift"), root)
            session = Path(plan["sessionRoot"])
            completed = type("Completed", (), {"returncode": 4})()

            def fake_run(command, env, check):
                session.mkdir(parents=True, exist_ok=True)
                (session / "control_report.json").write_text(
                    json.dumps(
                        {
                            "verdict": "capture_failed",
                            "phase": "auto_start_setup",
                            "reason": "CoreAudio default-output setup failed",
                            "appliesDelay": False,
                        }
                    )
                )
                return completed

            with mock.patch.object(pac.subprocess, "run", side_effect=fake_run):
                result = pac.execute_chain(plan, max_steps=3)

        self.assertEqual(result["execution"]["verdict"], "command_failed")
        self.assertEqual(
            result["execution"]["controlReportReason"],
            "CoreAudio default-output setup failed",
        )
        self.assertIn(
            "CoreAudio default-output setup failed",
            result["execution"]["reason"],
        )
        self.assertEqual(result["chainSummary"]["stopReason"], "command_failed")

    def test_execute_chain_success_ignores_stale_ready_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(_ready("monitor_drift"), root)
            session = Path(plan["sessionRoot"])
            session.mkdir()
            (session / "control_report.json").write_text(
                json.dumps(
                    {
                        "verdict": "ready_for_apply_candidate",
                        "reason": "old ready artifact",
                        "appliesDelay": False,
                    }
                )
            )
            completed = type("Completed", (), {"returncode": 0})()

            with mock.patch.object(pac.subprocess, "run", return_value=completed) as run:
                result = pac.execute_chain(plan, max_steps=3)

        self.assertEqual(run.call_count, 1)
        self.assertEqual(result["execution"]["verdict"], "command_succeeded")
        self.assertIn(str(session / "control_report.json"), result["execution"]["staleArtifacts"])
        self.assertEqual(result["chainSummary"]["stopReason"], "follow_up_blocked")

    def test_execute_chain_runs_candidate_dry_run_then_stops_before_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(_ready("monitor_drift"), root)
            completed = type("Completed", (), {"returncode": 0})()

            def fake_run(command, env, check):
                if command[1] == "scripts/passive_drift_session.sh":
                    session = Path(command[5])
                    session.mkdir(parents=True, exist_ok=True)
                    (session / "control_report.json").write_text(
                        json.dumps(
                            {
                                "verdict": "ready_for_apply_candidate",
                                "phase": "decision",
                                "reason": "repeat-confirmed",
                                "appliesDelay": False,
                                "emitsAudio": False,
                            }
                        )
                    )
                    return completed

                self.assertEqual(command[1], "scripts/passive_apply_candidate.py")
                self.assertNotIn("--apply", command)
                session = Path(command[2])
                (session / "passive_apply.json").write_text(
                    json.dumps(
                        {
                            "verdict": "dry_run_ready",
                            "appliesDelay": False,
                            "result": {"reason": "candidate accepted"},
                        }
                    )
                )
                return completed

            with mock.patch.object(pac.subprocess, "run", side_effect=fake_run) as run:
                result = pac.execute_chain(plan, max_steps=3)

        self.assertEqual(run.call_count, 2)
        self.assertEqual(result["execution"]["verdict"], "dry_run_ready")
        self.assertEqual(result["chainSummary"]["stopReason"], "follow_up_blocked")
        self.assertFalse(result["chainSummary"]["appliesDelay"])
        self.assertIsNone(result["followUpPlan"]["command"])

    def test_execute_chain_baseline_repeat_candidate_dry_run_full_safe_loop(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(_ready("record_baseline"), root)
            completed = type("Completed", (), {"returncode": 0})()
            verdicts = [
                "baseline_recorded",
                "pending_confirmation",
                "ready_for_apply_candidate",
                "dry_run_ready",
            ]

            def fake_run(command, env, check):
                if command[1] == "scripts/passive_drift_session.sh":
                    session = Path(command[5])
                    session.mkdir(parents=True, exist_ok=True)
                    verdict = verdicts.pop(0)
                    self.assertIn(
                        verdict,
                        {
                            "baseline_recorded",
                            "pending_confirmation",
                            "ready_for_apply_candidate",
                        },
                    )
                    (session / "control_report.json").write_text(
                        json.dumps(
                            {
                                "verdict": verdict,
                                "phase": "decision",
                                "reason": verdict,
                                "appliesDelay": False,
                                "emitsAudio": False,
                            }
                        )
                    )
                    return completed

                self.assertEqual(command[1], "scripts/passive_apply_candidate.py")
                self.assertNotIn("--apply", command)
                session = Path(command[2])
                self.assertEqual(verdicts.pop(0), "dry_run_ready")
                (session / "passive_apply.json").write_text(
                    json.dumps(
                        {
                            "verdict": "dry_run_ready",
                            "appliesDelay": False,
                            "emitsAudio": False,
                            "opensMicrophone": False,
                            "result": {"reason": "candidate accepted"},
                        }
                    )
                )
                return completed

            with mock.patch.object(pac.subprocess, "run", side_effect=fake_run) as run:
                result = pac.execute_chain(plan, max_steps=4)

        self.assertEqual(run.call_count, 4)
        self.assertEqual(result["chainSummary"]["stepsExecuted"], 4)
        self.assertEqual(result["execution"]["verdict"], "dry_run_ready")
        self.assertEqual(result["chainSummary"]["stopReason"], "follow_up_blocked")
        self.assertFalse(result["chainSummary"]["appliesDelay"])
        self.assertFalse(result["chainSummary"]["emitsAudio"])
        self.assertIsNone(result["followUpPlan"]["command"])

    def test_execute_chain_allowed_apply_waits_for_app_dry_run_ready_promotion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(
                _ready("monitor_drift"),
                root,
                allow_accepted_delay_apply=True,
            )
            completed = type("Completed", (), {"returncode": 0})()
            commands: list[list[str]] = []

            def fake_run(command, env, check):
                commands.append(command)
                if command[1] == "scripts/passive_drift_session.sh":
                    session = Path(command[5])
                    session.mkdir(parents=True, exist_ok=True)
                    verdict = "ready_for_apply_candidate" if len(commands) == 1 else "hold"
                    (session / "control_report.json").write_text(
                        json.dumps(
                            {
                                "verdict": verdict,
                                "phase": "decision",
                                "reason": verdict,
                                "appliesDelay": False,
                                "emitsAudio": False,
                            }
                        )
                    )
                    return completed

                if command[1] == "scripts/passive_apply_candidate.py":
                    self.assertNotIn("--apply", command)
                    session = Path(command[2])
                    (session / "passive_apply.json").write_text(
                        json.dumps(
                            {
                                "verdict": "dry_run_ready",
                                "appliesDelay": False,
                                "emitsAudio": False,
                                "opensMicrophone": False,
                                "result": {"reason": "candidate accepted"},
                            }
                        )
                    )
                    return completed

                self.fail(f"unexpected command after dry-run ready: {command}")

            with mock.patch.object(pac.subprocess, "run", side_effect=fake_run) as run:
                result = pac.execute_chain(plan, max_steps=4)

        self.assertEqual(run.call_count, 2)
        self.assertEqual(commands[1][1], "scripts/passive_apply_candidate.py")
        self.assertEqual(result["execution"]["verdict"], "dry_run_ready")
        self.assertEqual(result["chainSummary"]["stopReason"], "follow_up_blocked")
        self.assertIn("promote dryRunReady", result["followUpPlan"]["reason"])
        self.assertFalse(result["chainSummary"]["appliesDelay"])
        self.assertFalse(result["chainSummary"]["emitsAudio"])

    def test_execute_chain_allowed_apply_does_not_inline_accepted_apply_or_rollback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = _plan(
                _ready("monitor_drift"),
                root,
                allow_accepted_delay_apply=True,
            )
            completed_ok = type("Completed", (), {"returncode": 0})()
            completed_failed = type("Completed", (), {"returncode": 4})()
            commands: list[list[str]] = []

            def fake_run(command, env, check):
                commands.append(command)
                if command[1] == "scripts/passive_drift_session.sh":
                    session = Path(command[5])
                    session.mkdir(parents=True, exist_ok=True)
                    if len(commands) == 1:
                        (session / "control_report.json").write_text(
                            json.dumps(
                                {
                                    "verdict": "ready_for_apply_candidate",
                                    "phase": "decision",
                                    "reason": "repeat-confirmed",
                                    "appliesDelay": False,
                                    "emitsAudio": False,
                                }
                            )
                        )
                        return completed_ok
                    (session / "control_report.json").write_text(
                        json.dumps(
                            {
                                "verdict": "capture_failed",
                                "phase": "capture",
                                "reason": "post-apply validation failed",
                                "appliesDelay": False,
                                "emitsAudio": False,
                            }
                        )
                    )
                    return completed_failed

                if command[1] == "scripts/passive_apply_candidate.py":
                    session = Path(command[2])
                    (session / "passive_apply.json").write_text(
                        json.dumps(
                            {
                                "verdict": "dry_run_ready",
                                "appliesDelay": False,
                                "emitsAudio": False,
                                "opensMicrophone": False,
                                "result": {"reason": "candidate accepted"},
                            }
                        )
                    )
                    return completed_ok

                self.fail(f"unexpected command after dry-run ready: {command}")

            with mock.patch.object(pac.subprocess, "run", side_effect=fake_run) as run:
                result = pac.execute_chain(plan, max_steps=5)

        self.assertEqual(run.call_count, 2)
        self.assertEqual(commands[1][1], "scripts/passive_apply_candidate.py")
        self.assertEqual(result["execution"]["verdict"], "dry_run_ready")
        self.assertEqual(result["chainSummary"]["stepsExecuted"], 2)
        self.assertEqual(result["chainSummary"]["stopReason"], "follow_up_blocked")
        self.assertIn("promote dryRunReady", result["followUpPlan"]["reason"])
        self.assertFalse(result["chainSummary"]["appliesDelay"])
        self.assertFalse(result["chainSummary"]["emitsAudio"])

    def test_execute_chain_does_not_rollback_after_validation_audio_side_effect(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            validation = _plan(
                _ready("validate_apply"),
                root,
                allow_accepted_delay_apply=True,
            )
            validation["rollbackDelayMs"] = 2145
            validation["rollbackExpectedCurrentDelayMs"] = 2165
            completed_failed = type("Completed", (), {"returncode": 4})()

            def fake_run(command, env, check):
                session = Path(command[5])
                session.mkdir(parents=True, exist_ok=True)
                (session / "control_report.json").write_text(
                    json.dumps(
                        {
                            "verdict": "capture_failed",
                            "phase": "capture",
                            "reason": "validation unexpectedly emitted audio",
                            "appliesDelay": False,
                            "emitsAudio": True,
                        }
                    )
                )
                return completed_failed

            with mock.patch.object(pac.subprocess, "run", side_effect=fake_run) as run:
                result = pac.execute_chain(validation, max_steps=2)

        self.assertEqual(run.call_count, 1)
        self.assertEqual(result["chainSummary"]["stopReason"], "safety_issue")
        self.assertTrue(result["execution"]["emitsAudio"])
        self.assertIsNotNone(result["followUpPlan"]["command"])
        self.assertEqual(
            result["followUpPlan"]["command"][1],
            "scripts/passive_rollback_delay.py",
        )

    def test_execute_chain_stops_on_unexpected_delay_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session = root / "candidate"
            session.mkdir()
            plan = _plan(_ready("apply_dry_run"), root, candidate_session=session)
            completed = type("Completed", (), {"returncode": 0})()

            def fake_run(command, env, check):
                (session / "passive_apply.json").write_text(
                    json.dumps(
                        {
                            "verdict": "applied",
                            "appliesDelay": True,
                            "result": {"reason": "unexpected write"},
                        }
                    )
                )
                return completed

            with mock.patch.object(pac.subprocess, "run", side_effect=fake_run) as run:
                result = pac.execute_chain(plan, max_steps=3)

        self.assertEqual(run.call_count, 1)
        self.assertEqual(result["chainSummary"]["stopReason"], "safety_issue")
        self.assertTrue(result["execution"]["appliesDelay"])
        self.assertTrue(result["chainSummary"]["appliesDelay"])

    def test_execute_chain_stops_when_apply_dry_run_reports_audio_or_mic(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session = root / "candidate"
            session.mkdir()
            plan = _plan(_ready("apply_dry_run"), root, candidate_session=session)
            completed = type("Completed", (), {"returncode": 0})()

            def fake_run(command, env, check):
                (session / "passive_apply.json").write_text(
                    json.dumps(
                        {
                            "verdict": "dry_run_ready",
                            "appliesDelay": False,
                            "emitsAudio": True,
                            "opensMicrophone": True,
                            "result": {"reason": "bad dry-run side effects"},
                        }
                    )
                )
                return completed

            with mock.patch.object(pac.subprocess, "run", side_effect=fake_run) as run:
                result = pac.execute_chain(plan, max_steps=3)

        self.assertEqual(run.call_count, 1)
        self.assertEqual(result["chainSummary"]["stopReason"], "safety_issue")
        self.assertTrue(result["execution"]["emitsAudio"])
        self.assertTrue(result["execution"]["opensMicrophone"])
        self.assertIn("safetyIssue", result["execution"])


if __name__ == "__main__":
    unittest.main()
