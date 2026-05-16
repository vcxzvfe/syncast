#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import passive_workflow_guard as pwg


def _readiness(workflow: str, *, verdict: str = "ready") -> dict:
    intent_by_workflow = {
        "record_baseline": "baseline_required",
        "monitor_drift": "drift_monitor",
        "locked_diagnostic": "diagnostic_locked",
        "validate_apply": "post_apply_validation",
        "apply_dry_run": "dry_run_candidate",
        "manual_validation": "manual_validation_required",
    }
    return {
        "schema": "syncast.passive_readiness.v1",
        "verdict": verdict,
        "passiveEvidenceIntent": intent_by_workflow.get(workflow),
        "passiveEvidenceIntentSource": "app_status",
        "recommendedWorkflow": workflow,
        "recommendedSessionMode": workflow,
        "nextAction": "next",
        "opensMicrophone": False,
        "emitsAudio": False,
        "appliesDelay": False,
    }


class PassiveWorkflowGuardTests(unittest.TestCase):
    def test_not_ready_does_not_block_before_preflight(self):
        result = pwg.evaluate(
            readiness=_readiness("record_baseline", verdict="not_ready"),
        )
        self.assertEqual(result["verdict"], "allowed")
        self.assertIn("not ready", result["reason"])
        self.assertFalse(result["opensMicrophone"])

    def test_record_baseline_requires_store(self):
        result = pwg.evaluate(readiness=_readiness("record_baseline"))
        self.assertEqual(result["verdict"], "blocked")
        self.assertEqual(result["reason"], "baseline_store_required_for_record_baseline")
        self.assertFalse(result["appliesDelay"])

    def test_record_baseline_allows_store_auto_mode(self):
        result = pwg.evaluate(
            readiness=_readiness("record_baseline"),
            baseline_store="/tmp/baselines.json",
            baseline_mode="auto",
        )
        self.assertEqual(result["verdict"], "allowed")
        self.assertEqual(result["reason"], "session configuration matches readiness workflow")

    def test_record_baseline_rejects_decide_mode(self):
        result = pwg.evaluate(
            readiness=_readiness("record_baseline"),
            baseline_store="/tmp/baselines.json",
            baseline_mode="decide",
        )
        self.assertEqual(result["verdict"], "blocked")
        self.assertEqual(result["reason"], "baseline_mode_must_record_for_record_baseline")

    def test_drift_monitor_requires_baseline_source(self):
        result = pwg.evaluate(readiness=_readiness("monitor_drift"))
        self.assertEqual(result["verdict"], "blocked")
        self.assertEqual(result["reason"], "baseline_source_required_for_drift_monitor")

    def test_drift_monitor_allows_store_or_report_or_offset(self):
        for kwargs in (
            {"baseline_store": "/tmp/store.json"},
            {"baseline_report": "/tmp/monitor.json"},
            {"baseline_offset_ms": "82.5"},
        ):
            with self.subTest(kwargs=kwargs):
                result = pwg.evaluate(
                    readiness=_readiness("monitor_drift"),
                    control_state="/tmp/passive-control-state.json",
                    **kwargs,
                )
            self.assertEqual(result["verdict"], "allowed")

    def test_drift_monitor_requires_control_state_for_apply_tracking(self):
        result = pwg.evaluate(
            readiness=_readiness("monitor_drift"),
            baseline_store="/tmp/store.json",
            passive_apply_mode="dry-run",
        )
        self.assertEqual(result["verdict"], "blocked")
        self.assertEqual(
            result["reason"],
            "control_state_required_for_autonomous_drift_monitor",
        )
        self.assertIn("SYNCAST_PASSIVE_CONTROL_STATE", result["nextAction"])

    def test_drift_monitor_allows_observation_without_control_state(self):
        result = pwg.evaluate(
            readiness=_readiness("monitor_drift"),
            baseline_store="/tmp/store.json",
            passive_apply_mode="off",
        )
        self.assertEqual(result["verdict"], "allowed")

    def test_apply_dry_run_blocks_mic_corpus(self):
        result = pwg.evaluate(
            readiness=_readiness("apply_dry_run"),
            baseline_store="/tmp/store.json",
            control_state="/tmp/state.json",
        )
        self.assertEqual(result["verdict"], "blocked")
        self.assertEqual(result["reason"], "apply_dry_run_requires_existing_ready_session")
        self.assertIn("passive_apply_candidate.py", result["nextAction"])

    def test_post_apply_validation_requires_apply_mode_off(self):
        result = pwg.evaluate(
            readiness=_readiness("validate_apply"),
            baseline_store="/tmp/store.json",
            passive_apply_mode="dry-run",
        )
        self.assertEqual(result["verdict"], "blocked")
        self.assertEqual(result["reason"], "post_apply_validation_should_not_run_apply_dry_run")
        allowed = pwg.evaluate(
            readiness=_readiness("validate_apply"),
            baseline_store="/tmp/store.json",
            passive_apply_mode="off",
        )
        self.assertEqual(allowed["verdict"], "allowed")

    def test_manual_validation_blocks_new_mic_corpus(self):
        result = pwg.evaluate(
            readiness=_readiness("manual_validation"),
            baseline_store="/tmp/store.json",
            control_state="/tmp/state.json",
        )
        self.assertEqual(result["verdict"], "blocked")
        self.assertEqual(result["reason"], "manual_validation_required_after_passive_dry_run")
        self.assertFalse(result["opensMicrophone"])
        self.assertFalse(result["appliesDelay"])

    def test_locked_diagnostic_allows_no_store(self):
        result = pwg.evaluate(readiness=_readiness("locked_diagnostic"))
        self.assertEqual(result["verdict"], "allowed")

    def test_warn_mode_reports_warning_but_exits_ok(self):
        result = pwg.evaluate(
            readiness=_readiness("record_baseline"),
            mode="warn",
        )
        self.assertEqual(result["verdict"], "warning")

    def test_off_mode_always_allows(self):
        result = pwg.evaluate(
            readiness=_readiness("apply_dry_run"),
            mode="off",
        )
        self.assertEqual(result["verdict"], "allowed")
        self.assertEqual(result["reason"], "workflow guard disabled")

    def test_main_writes_output_and_exit_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            readiness = Path(tmp) / "readiness.json"
            output = Path(tmp) / "guard.json"
            readiness.write_text(json.dumps(_readiness("record_baseline")))
            old_parse = pwg._parse_args
            try:
                pwg._parse_args = lambda: type(
                    "Args",
                    (),
                    {
                        "readiness_json": readiness,
                        "baseline_store": "",
                        "baseline_report": "",
                        "baseline_offset_ms": "",
                        "baseline_mode": "auto",
                        "control_state": "",
                        "passive_apply_mode": "dry-run",
                        "mode": "enforce",
                        "output": output,
                    },
                )()
                with mock.patch.object(sys, "stdout"):
                    rc = pwg.main()
            finally:
                pwg._parse_args = old_parse
            self.assertEqual(rc, pwg.EXIT_NOT_READY)
            self.assertEqual(json.loads(output.read_text())["verdict"], "blocked")


if __name__ == "__main__":
    unittest.main()
