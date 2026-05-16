#!/usr/bin/env python3
"""Guard passive live sessions against wasting microphone corpus.

The no-mic readiness artifact can now say which passive workflow should run
next. This helper checks that recommendation against the session configuration
before the wrapper opens the microphone.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


EXIT_OK = 0
EXIT_BAD_INPUT = 2
EXIT_NOT_READY = 3

SCHEMA = "syncast.passive_workflow_guard.v1"


def _read_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text())
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected JSON object")
    return payload


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def _has_text(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def evaluate(
    *,
    readiness: dict[str, Any],
    baseline_store: str | None = None,
    baseline_report: str | None = None,
    baseline_offset_ms: str | None = None,
    baseline_mode: str = "auto",
    control_state: str | None = None,
    passive_apply_mode: str = "dry-run",
    mode: str = "enforce",
) -> dict[str, Any]:
    if mode not in {"enforce", "warn", "off"}:
        raise ValueError("--mode must be enforce, warn, or off")
    if passive_apply_mode not in {"dry-run", "off"}:
        raise ValueError("--passive-apply-mode must be dry-run or off")
    if baseline_mode not in {"auto", "record", "decide"}:
        raise ValueError("--baseline-mode must be auto, record, or decide")

    verdict = readiness.get("verdict")
    workflow = readiness.get("recommendedWorkflow")
    intent = readiness.get("passiveEvidenceIntent")
    source = readiness.get("passiveEvidenceIntentSource")
    baseline_source = any(
        _has_text(value)
        for value in (baseline_store, baseline_report, baseline_offset_ms)
    )
    result: dict[str, Any] = {
        "schema": SCHEMA,
        "mode": mode,
        "verdict": "allowed",
        "reason": "readiness is not ready; normal preflight will report the blocker",
        "readinessVerdict": verdict,
        "passiveEvidenceIntent": intent,
        "passiveEvidenceIntentSource": source,
        "recommendedWorkflow": workflow,
        "recommendedSessionMode": readiness.get("recommendedSessionMode"),
        "baselineStoreConfigured": _has_text(baseline_store),
        "baselineReportConfigured": _has_text(baseline_report),
        "baselineOffsetConfigured": _has_text(baseline_offset_ms),
        "baselineMode": baseline_mode,
        "controlStateConfigured": _has_text(control_state),
        "passiveApplyMode": passive_apply_mode,
        "opensMicrophone": False,
        "emitsAudio": False,
        "appliesDelay": False,
    }
    if mode == "off":
        result.update(
            {
                "verdict": "allowed",
                "reason": "workflow guard disabled",
            }
        )
        return result
    if verdict != "ready":
        return result

    issue: str | None = None
    next_action: str | None = None
    if workflow == "record_baseline":
        if not _has_text(baseline_store):
            issue = "baseline_store_required_for_record_baseline"
            next_action = (
                "set SYNCAST_PASSIVE_BASELINE_STORE before collecting this "
                "baseline corpus, or disable the workflow guard for a one-off "
                "diagnostic run"
            )
        elif baseline_mode not in {"auto", "record"}:
            issue = "baseline_mode_must_record_for_record_baseline"
            next_action = "use SYNCAST_PASSIVE_BASELINE_MODE=auto or record"
    elif workflow == "monitor_drift":
        if not baseline_source:
            issue = "baseline_source_required_for_drift_monitor"
            next_action = (
                "provide SYNCAST_PASSIVE_BASELINE_STORE, "
                "SYNCAST_PASSIVE_BASELINE_REPORT, or "
                "SYNCAST_PASSIVE_BASELINE_OFFSET_MS before collecting drift evidence"
            )
        elif passive_apply_mode != "off" and not _has_text(control_state):
            issue = "control_state_required_for_autonomous_drift_monitor"
            next_action = (
                "set SYNCAST_PASSIVE_CONTROL_STATE so repeat-confirmed "
                "corrections can be tracked, or set SYNCAST_PASSIVE_APPLY_MODE=off "
                "for an observation-only drift session"
            )
    elif workflow == "apply_dry_run":
        issue = "apply_dry_run_requires_existing_ready_session"
        next_action = (
            "run scripts/passive_apply_candidate.py on the session that already "
            "contains correction_gate.json instead of collecting another mic corpus"
        )
    elif workflow == "validate_apply":
        if passive_apply_mode != "off":
            issue = "post_apply_validation_should_not_run_apply_dry_run"
            next_action = (
                "set SYNCAST_PASSIVE_APPLY_MODE=off while collecting a "
                "post-apply validation corpus"
            )
    elif workflow == "manual_validation":
        issue = "manual_validation_required_after_passive_dry_run"
        next_action = (
            "review the dry-run accepted candidate before collecting another "
            "microphone corpus or enabling any explicit apply workflow"
        )
    elif workflow == "locked_diagnostic":
        pass

    if issue is None:
        result.update(
            {
                "verdict": "allowed",
                "reason": "session configuration matches readiness workflow",
                "nextAction": readiness.get("nextAction"),
            }
        )
        return result

    result.update(
        {
            "verdict": "blocked" if mode == "enforce" else "warning",
            "reason": issue,
            "nextAction": next_action,
        }
    )
    return result


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate passive session config against readiness workflow."
    )
    parser.add_argument("readiness_json", type=Path)
    parser.add_argument("--baseline-store", default="")
    parser.add_argument("--baseline-report", default="")
    parser.add_argument("--baseline-offset-ms", default="")
    parser.add_argument("--baseline-mode", default="auto")
    parser.add_argument("--control-state", default="")
    parser.add_argument("--passive-apply-mode", default="dry-run")
    parser.add_argument("--mode", choices=("enforce", "warn", "off"), default="enforce")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        result = evaluate(
            readiness=_read_json(args.readiness_json),
            baseline_store=args.baseline_store,
            baseline_report=args.baseline_report,
            baseline_offset_ms=args.baseline_offset_ms,
            baseline_mode=args.baseline_mode,
            control_state=args.control_state,
            passive_apply_mode=args.passive_apply_mode,
            mode=args.mode,
        )
        if args.output is not None:
            _write_json(args.output, result)
        print(json.dumps(result, indent=2, sort_keys=True))
        return EXIT_NOT_READY if result["verdict"] == "blocked" else EXIT_OK
    except Exception as exc:
        payload = {"verdict": "bad_input", "error": str(exc)}
        if args.output is not None:
            _write_json(args.output, payload)
        print(json.dumps(payload, indent=2), file=sys.stderr)
        return EXIT_BAD_INPUT


if __name__ == "__main__":
    raise SystemExit(main())
