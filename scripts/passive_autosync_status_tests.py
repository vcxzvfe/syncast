#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

import passive_autosync_status as pas


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


class PassiveAutosyncStatusTests(unittest.TestCase):
    def test_empty_state_root_reports_no_runs(self):
        with tempfile.TemporaryDirectory() as tmp:
            status = pas.build_status(Path(tmp) / "PassiveAutosync", limit=5)
        self.assertFalse(status["exists"])
        self.assertEqual(status["runsTotal"], 0)
        self.assertIsNone(status["latest"])

    def test_summarizes_latest_run_with_control_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "PassiveAutosync"
            session = root / "sessions" / "passive-a"
            control = session / "control_report.json"
            _write_json(
                control,
                {
                    "verdict": "baseline_recorded",
                    "phase": "finalize",
                    "reason": "baseline recorded",
                    "nextAction": "collect the next same-context passive drift session",
                    "opensMicrophone": True,
                    "emitsAudio": False,
                    "appliesDelay": False,
                    "readinessRecommendedWorkflow": "record_baseline",
                },
            )
            run = root / "runs" / "autosync-1.json"
            _write_json(
                run,
                {
                    "verdict": "ready_to_run_session",
                    "execution": {
                        "verdict": "baseline_recorded",
                        "reason": "baseline recorded",
                        "sessionRoot": str(session),
                        "controlReport": str(control),
                        "opensMicrophone": True,
                        "emitsAudio": False,
                        "appliesDelay": False,
                    },
                },
            )
            status = pas.build_status(root, limit=5)
        self.assertEqual(status["runsTotal"], 1)
        self.assertEqual(status["latestVerdict"], "baseline_recorded")
        self.assertEqual(status["microphoneRunCount"], 1)
        self.assertEqual(status["safetyIssueCount"], 0)
        latest = status["latest"]
        self.assertEqual(latest["controlReportVerdict"], "baseline_recorded")
        self.assertEqual(latest["readinessWorkflow"], "record_baseline")
        self.assertTrue(latest["jsonExists"])

    def test_recent_stdout_stderr_without_json_reports_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "PassiveAutosync"
            runs = root / "runs"
            runs.mkdir(parents=True)
            stdout = runs / "autosync-42.stdout"
            stderr = runs / "autosync-42.stderr"
            stdout.write_text("controller starting\n")
            stderr.write_text("still running\n")
            latest_mtime = max(stdout.stat().st_mtime, stderr.stat().st_mtime)
            status = pas.build_status(root, limit=5, now=latest_mtime + 10)
        self.assertEqual(status["runsTotal"], 1)
        self.assertEqual(status["partialRunCount"], 1)
        self.assertEqual(status["stalePartialRunCount"], 0)
        self.assertEqual(status["latestVerdict"], "report_pending")
        latest = status["latest"]
        self.assertFalse(latest["jsonExists"])
        self.assertEqual(latest["blockingStage"], "controller_report_pending")
        self.assertIn("still running", latest["stderrTail"])

    def test_stale_orphan_stdout_stderr_reports_missing_json_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "PassiveAutosync"
            runs = root / "runs"
            runs.mkdir(parents=True)
            stdout = runs / "autosync-42.stdout"
            stderr = runs / "autosync-42.stderr"
            stdout.write_text("controller starting\n")
            stderr.write_text("Traceback: missing module\n")
            latest_mtime = max(stdout.stat().st_mtime, stderr.stat().st_mtime)
            status = pas.build_status(
                root,
                limit=5,
                now=latest_mtime + pas.DEFAULT_PARTIAL_STALE_SEC + 1,
            )
        self.assertEqual(status["runsTotal"], 1)
        self.assertEqual(status["partialRunCount"], 1)
        self.assertEqual(status["stalePartialRunCount"], 1)
        self.assertEqual(status["latestVerdict"], "missing_json")
        latest = status["latest"]
        self.assertFalse(latest["jsonExists"])
        self.assertEqual(latest["blockingStage"], "controller_report")
        self.assertIn("missing module", latest["stderrTail"])

    def test_json_and_process_logs_count_as_one_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "PassiveAutosync"
            runs = root / "runs"
            _write_json(
                runs / "autosync-7.json",
                {
                    "execution": {
                        "verdict": "blocked",
                        "reason": "not ready",
                    }
                },
            )
            (runs / "autosync-7.stderr").write_text("warning only\n")
            status = pas.build_status(root, limit=5)
        self.assertEqual(status["runsTotal"], 1)
        self.assertEqual(status["partialRunCount"], 0)
        latest = status["latest"]
        self.assertTrue(latest["jsonExists"])
        self.assertTrue(latest["stderrExists"])
        self.assertIn("warning only", latest["stderrTail"])

    def test_malformed_json_with_logs_does_not_abort_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "PassiveAutosync"
            runs = root / "runs"
            runs.mkdir(parents=True)
            run = runs / "autosync-8.json"
            run.write_text("{")
            (runs / "autosync-8.stderr").write_text("crashed while writing\n")
            status = pas.build_status(
                root,
                limit=5,
                now=run.stat().st_mtime + pas.DEFAULT_PARTIAL_STALE_SEC + 1,
            )
        self.assertEqual(status["runsTotal"], 1)
        self.assertEqual(status["partialRunCount"], 1)
        self.assertEqual(status["stalePartialRunCount"], 1)
        self.assertEqual(status["latestVerdict"], "unreadable_json")
        latest = status["latest"]
        self.assertTrue(latest["jsonExists"])
        self.assertFalse(latest["jsonReadable"])
        self.assertIn("crashed while writing", latest["stderrTail"])

    def test_safety_issue_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "PassiveAutosync"
            _write_json(
                root / "runs" / "autosync-1.json",
                {
                    "execution": {
                        "verdict": "applied",
                        "reason": "unexpected",
                        "opensMicrophone": False,
                        "emitsAudio": False,
                        "appliesDelay": True,
                        "safetyIssue": "unexpected delay write",
                    }
                },
            )
            status = pas.build_status(root, limit=5)
        self.assertEqual(status["safetyIssueCount"], 1)
        self.assertEqual(status["delayWriteCount"], 1)
        self.assertTrue(status["latest"]["appliesDelay"])

    def test_allowed_delay_write_counts_separately_from_safety_issue(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "PassiveAutosync"
            _write_json(
                root / "runs" / "autosync-1.json",
                {
                    "execution": {
                        "verdict": "rolled_back",
                        "reason": "rollback_after_validation_failure",
                        "opensMicrophone": False,
                        "emitsAudio": False,
                        "appliesDelay": True,
                    },
                    "chainSummary": {
                        "finalVerdict": "rolled_back",
                        "stepsExecuted": 5,
                        "appliesDelay": True,
                    },
                },
            )
            status = pas.build_status(root, limit=5)
        self.assertEqual(status["safetyIssueCount"], 0)
        self.assertEqual(status["delayWriteCount"], 1)
        self.assertEqual(status["latestVerdict"], "rolled_back")

    def test_rollback_run_surfaces_apply_and_rollback_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "PassiveAutosync"
            rollback = root / "sessions" / "rollback" / "passive_rollback.json"
            _write_json(
                root / "runs" / "autosync-1.json",
                {
                    "execution": {
                        "verdict": "rolled_back",
                        "reason": "rollback_after_validation_failure",
                        "opensMicrophone": False,
                        "emitsAudio": False,
                        "appliesDelay": True,
                        "passiveAcceptedApply": "/tmp/passive_accepted_apply.json",
                        "passiveAcceptedApplyVerdict": "applied",
                        "passiveAcceptedApplyResult": {
                            "previousDelayMs": 2145,
                            "appliedDelayMs": 2165,
                        },
                        "passiveRollback": str(rollback),
                        "passiveRollbackVerdict": "rolled_back",
                        "passiveRollbackResult": {
                            "previousDelayMs": 2165,
                            "appliedDelayMs": 2145,
                        },
                    },
                },
            )
            status = pas.build_status(root, limit=5)
        latest = status["latest"]
        self.assertEqual(latest["passiveAcceptedApplyVerdict"], "applied")
        self.assertEqual(latest["passiveAcceptedAppliedDelayMs"], 2165)
        self.assertEqual(latest["passiveRollbackVerdict"], "rolled_back")
        self.assertEqual(latest["passiveRollbackPreviousDelayMs"], 2165)
        self.assertEqual(latest["passiveRollbackAppliedDelayMs"], 2145)
        text = pas._format_text(status)
        self.assertIn("accepted", text)
        self.assertIn("rollback", text)

    def test_can_include_launch_log_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "PassiveAutosync"
            launch_log = Path(tmp) / "launch.log"
            launch_log.write_text(
                "\n".join(
                    [
                        "2026-05-16 [ActiveCalib] old run before restart",
                        "2026-05-16 === SyncCast process starting (pid 1) ===",
                        "ordinary line",
                        "2026-05-16 passiveAutosync: finished exit=0 verdict=baseline_recorded stage=finalize next=collect drift",
                        "2026-05-16 active acoustic diagnostics: disabled; passive no-probe diagnostics only",
                        "2026-05-16 [ActiveCalib] phase=local_CODED tones=[19050]",
                    ]
                )
                + "\n"
            )
            status = pas.build_status(
                root,
                limit=5,
                include_launch_log=True,
                launch_log=launch_log,
            )
        launch = status["launchLog"]
        self.assertTrue(launch["readable"])
        self.assertEqual(launch["scope"], "since_latest_process_start")
        self.assertEqual(launch["matchedLineCount"], 3)
        self.assertEqual(launch["activeProbeLineCount"], 1)
        self.assertIn("passiveAutosync: finished", launch["recentLines"][0])
        self.assertIn("[ActiveCalib]", launch["recentActiveProbeLines"][0])

    def test_text_output_mentions_no_runs(self):
        status = {
            "stateRoot": "/tmp/missing",
            "exists": False,
            "runsTotal": 0,
            "runsReported": 0,
            "latest": None,
        }
        text = pas._format_text(status)
        self.assertIn("latest     : none", text)


if __name__ == "__main__":
    unittest.main()
