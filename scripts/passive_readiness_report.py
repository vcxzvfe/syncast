#!/usr/bin/env python3
"""Report no-mic passive readiness for SyncCast live diagnostics."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any

import passive_capture_estimate as pce


EXIT_READY = 0
EXIT_NOT_READY = 3
EXIT_BAD_INPUT = 2
ACCEPTED_DRY_RUN_MAX_AGE_SEC = 120.0
ACCEPTED_DRY_RUN_FUTURE_SKEW_SEC = 5.0


def _default_socket_path() -> Path:
    return Path(f"/tmp/syncast-{os.getuid()}.calibration.sock")


def _process_pids(process_name: str) -> list[int]:
    try:
        result = subprocess.run(
            ["pgrep", "-x", process_name],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return []
    if result.returncode not in (0, 1):
        return []
    pids = []
    for line in result.stdout.splitlines():
        try:
            pids.append(int(line.strip()))
        except ValueError:
            continue
    return pids


def _base_payload(
    *,
    socket_path: Path,
    app_path: Path,
    process_name: str,
    pids: list[int],
) -> dict[str, Any]:
    return {
        "schema": "syncast.passive_readiness.v1",
        "createdUnix": round(time.time(), 3),
        "socket": str(socket_path),
        "appPath": str(app_path),
        "appExists": app_path.exists(),
        "processName": process_name,
        "processRunning": bool(pids),
        "processPids": pids,
        "socketExists": socket_path.exists(),
        "opensMicrophone": False,
        "emitsAudio": False,
        "appliesDelay": False,
    }


def _not_ready(
    payload: dict[str, Any],
    *,
    stage: str,
    reason: str,
    next_action: str,
) -> dict[str, Any]:
    payload.update(
        {
            "verdict": "not_ready",
            "stage": stage,
            "reason": reason,
            "nextAction": next_action,
            "passiveReady": False,
        }
    )
    return payload


def _copy_sync_context(payload: dict[str, Any], status: dict[str, Any]) -> None:
    for key in (
        "syncContextState",
        "syncContextReason",
        "syncContextRevision",
        "syncContextUpdatedUnix",
        "passiveDryRunTargetDelayMs",
        "passiveDryRunCurrentDelayMs",
        "passiveDryRunContextSignature",
        "passiveDryRunCaptureBackend",
        "passiveDryRunEnabledAirplayCount",
        "passiveDryRunActiveAirplayCount",
        "passiveDryRunAirplayTimingEpoch",
        "passiveDryRunAcceptedFromSyncContextState",
        "passiveDryRunAcceptedFromSyncContextRevision",
        "passiveDryRunAcceptedSyncContextRevision",
        "passiveDryRunSessionRoot",
        "passiveDryRunControlReport",
        "passiveDryRunAcceptedUnix",
    ):
        if key in status:
            payload[key] = status[key]


def _accepted_dry_run_age_issue(
    status: dict[str, Any],
    *,
    now_unix: float | None = None,
) -> str | None:
    raw = status.get("passiveDryRunAcceptedUnix")
    if isinstance(raw, bool):
        return "accepted passive dry-run candidate timestamp is invalid"
    try:
        accepted_unix = float(raw)
    except (TypeError, ValueError):
        return "accepted passive dry-run candidate timestamp is missing"
    if not accepted_unix or not math.isfinite(accepted_unix):
        return "accepted passive dry-run candidate timestamp is invalid"
    now = time.time() if now_unix is None else now_unix
    age_sec = now - accepted_unix
    if age_sec < -ACCEPTED_DRY_RUN_FUTURE_SKEW_SEC:
        return (
            "accepted passive dry-run candidate timestamp is in the future: "
            f"ageSec={age_sec:.3f}"
        )
    if age_sec > ACCEPTED_DRY_RUN_MAX_AGE_SEC:
        return (
            "accepted passive dry-run candidate expired: "
            f"ageSec={age_sec:.3f} maxAgeSec={ACCEPTED_DRY_RUN_MAX_AGE_SEC:g}"
        )
    return None


def _passive_evidence_intent(status: dict[str, Any]) -> dict[str, Any]:
    """Classify the next passive action without opening the microphone."""

    state = str(status.get("syncContextState") or "").strip()
    reason = str(status.get("syncContextReason") or "").strip()
    if state == "dryRunReady":
        age_issue = _accepted_dry_run_age_issue(status)
        if age_issue:
            raise ValueError(age_issue)

    app_intent = str(status.get("passiveEvidenceIntent") or "").strip()
    if app_intent:
        if app_intent not in _known_intents():
            raise ValueError(f"unknown passiveEvidenceIntent from app: {app_intent}")
        baseline_required = status.get("baselineRequired")
        passive_can_apply = status.get("passiveCanApply")
        workflow = _workflow_for_intent(app_intent)
        return {
            "passiveEvidenceIntent": app_intent,
            "passiveEvidenceIntentSource": "app_status",
            **workflow,
            "passiveCanApply": (
                passive_can_apply
                if isinstance(passive_can_apply, bool)
                else app_intent == "drift_monitor"
            ),
            "baselineRequired": (
                baseline_required
                if isinstance(baseline_required, bool)
                else app_intent == "baseline_required"
            ),
            "nextAction": str(
                status.get("passiveNextAction")
                or "run the no-probe passive drift session"
            ),
            "reason": str(
                status.get("passiveEvidenceReason")
                or status.get("syncContextReason")
                or "passive capture readiness gate passed"
            ),
        }

    delay_locked = status.get("delayLocked")
    known_states = {
        "valid",
        "suspect",
        "measuring",
        "readyToDryRun",
        "dryRunReady",
        "applied",
        "locked",
    }

    if delay_locked is True or state == "locked":
        return {
            "passiveEvidenceIntent": "diagnostic_locked",
            "passiveEvidenceIntentSource": "derived",
            **_workflow_for_intent("diagnostic_locked"),
            "passiveCanApply": False,
            "baselineRequired": False,
            "nextAction": (
                "run a no-probe passive drift session for diagnostics only; "
                "automatic delay apply is blocked while the delay is locked"
            ),
            "reason": reason or "delay is locked",
        }
    if state in {"suspect", ""}:
        return {
            "passiveEvidenceIntent": "baseline_required",
            "passiveEvidenceIntentSource": "derived",
            **_workflow_for_intent("baseline_required"),
            "passiveCanApply": False,
            "baselineRequired": True,
            "nextAction": (
                "record a no-probe passive baseline for the current Local+AirPlay "
                "route before considering any correction"
            ),
            "reason": reason or "Local+AirPlay sync context is suspect",
        }
    if state == "applied":
        return {
            "passiveEvidenceIntent": "post_apply_validation",
            "passiveEvidenceIntentSource": "derived",
            **_workflow_for_intent("post_apply_validation"),
            "passiveCanApply": False,
            "baselineRequired": False,
            "nextAction": (
                "run a no-probe passive drift session to validate the recently "
                "applied delay before trusting further corrections"
            ),
            "reason": reason or "recent passive/diagnostic delay apply",
        }
    if state == "readyToDryRun":
        return {
            "passiveEvidenceIntent": "dry_run_candidate",
            "passiveEvidenceIntentSource": "derived",
            **_workflow_for_intent("dry_run_candidate"),
            "passiveCanApply": False,
            "baselineRequired": False,
            "nextAction": (
                "run the app-side passive apply dry-run guard; do not write delay "
                "unless a separate apply step is explicitly enabled"
            ),
            "reason": reason or "repeat-confirmed passive correction candidate",
        }
    if state == "dryRunReady":
        return {
            "passiveEvidenceIntent": "manual_validation_required",
            "passiveEvidenceIntentSource": "derived",
            **_workflow_for_intent("manual_validation_required"),
            "passiveCanApply": False,
            "baselineRequired": False,
            "nextAction": (
                "manual listening validation or an explicit apply workflow is "
                "required before changing delay"
            ),
            "reason": reason or "app-side passive dry-run accepted a correction candidate",
        }
    if state not in known_states:
        raise ValueError(
            "unknown syncContextState from app: "
            f"{state or '<missing>'}"
        )
    return {
        "passiveEvidenceIntent": "drift_monitor",
        "passiveEvidenceIntentSource": "derived",
        **_workflow_for_intent("drift_monitor"),
        "passiveCanApply": True,
        "baselineRequired": False,
        "nextAction": "run the no-probe passive drift session",
        "reason": reason or "passive capture readiness gate passed",
    }

def _known_intents() -> set[str]:
    return set(_workflow_mapping().keys())


def _workflow_mapping() -> dict[str, dict[str, Any]]:
    return {
        "baseline_required": {
            "recommendedWorkflow": "record_baseline",
            "recommendedSessionMode": "baseline",
            "requiresBaselineStore": True,
            "allowsPassiveApply": False,
        },
        "drift_monitor": {
            "recommendedWorkflow": "monitor_drift",
            "recommendedSessionMode": "correction",
            "requiresBaselineStore": True,
            "allowsPassiveApply": True,
        },
        "diagnostic_locked": {
            "recommendedWorkflow": "locked_diagnostic",
            "recommendedSessionMode": "diagnostic",
            "requiresBaselineStore": False,
            "allowsPassiveApply": False,
        },
        "post_apply_validation": {
            "recommendedWorkflow": "validate_apply",
            "recommendedSessionMode": "validation",
            "requiresBaselineStore": True,
            "allowsPassiveApply": False,
        },
        "dry_run_candidate": {
            "recommendedWorkflow": "apply_dry_run",
            "recommendedSessionMode": "apply_dry_run",
            "requiresBaselineStore": True,
            "allowsPassiveApply": False,
        },
        "manual_validation_required": {
            "recommendedWorkflow": "manual_validation",
            "recommendedSessionMode": "manual_validation",
            "requiresBaselineStore": True,
            "allowsPassiveApply": False,
        },
    }


def _workflow_for_intent(intent: str) -> dict[str, Any]:
    mapping = _workflow_mapping()
    return mapping.get(
        intent,
        {
            "recommendedWorkflow": "monitor_drift",
            "recommendedSessionMode": "correction",
            "requiresBaselineStore": True,
            "allowsPassiveApply": False,
        },
    )


def build_report(
    *,
    socket_path: Path,
    app_path: Path,
    process_name: str,
    timeout_sec: float,
) -> dict[str, Any]:
    pids = _process_pids(process_name)
    payload = _base_payload(
        socket_path=socket_path,
        app_path=app_path,
        process_name=process_name,
        pids=pids,
    )

    if not payload["appExists"]:
        return _not_ready(
            payload,
            stage="app",
            reason=f"SyncCast app is not installed at {app_path}",
            next_action="install SyncCast.app before running passive diagnostics",
        )
    if not payload["processRunning"]:
        if process_name == "SyncCastPassiveHeadless":
            next_action = (
                "start SyncCastPassiveHeadless with local+AirPlay targets and "
                "wait for its passive diagnostic socket"
            )
        else:
            next_action = (
                "start SyncCast in Whole-home with at least one local CoreAudio "
                "output and one or more connected AirPlay outputs"
            )
        return _not_ready(
            payload,
            stage="process",
            reason=f"{process_name} is not running",
            next_action=next_action,
        )
    if not payload["socketExists"]:
        return _not_ready(
            payload,
            stage="socket",
            reason=f"diagnostic socket is missing at {socket_path}",
            next_action=(
                "switch SyncCast to Whole-home or wait for the calibration "
                "diagnostic socket to be installed"
            ),
        )

    try:
        ping = pce._json_rpc(socket_path, "ping", {}, timeout_sec=timeout_sec)
    except Exception as exc:
        return _not_ready(
            payload,
            stage="ping",
            reason=f"diagnostic socket ping failed: {exc}",
            next_action=(
                "restart SyncCast or remove stale diagnostic socket before "
                "running passive diagnostics"
            ),
        )
    payload["ping"] = ping
    if ping.get("ok") is not True:
        return _not_ready(
            payload,
            stage="ping",
            reason=f"diagnostic socket ping returned unexpected result: {ping!r}",
            next_action="restart SyncCast before running passive diagnostics",
        )

    try:
        status = pce._passive_status(socket_path)
        _copy_sync_context(payload, status)
        pce._check_passive_status_ready(status)
    except Exception as exc:
        if "status" in locals() and isinstance(status, dict):
            payload["status"] = status
            _copy_sync_context(payload, status)
        return _not_ready(
            payload,
            stage="passive_status",
            reason=str(exc),
            next_action=(
                "ensure Whole-home has at least one local output, every enabled "
                "AirPlay receiver is connected, and the capture backend is sck or tap"
            ),
        )

    try:
        intent = _passive_evidence_intent(status)
    except ValueError as exc:
        return _not_ready(
            payload,
            stage="passive_status",
            reason=str(exc),
            next_action=(
                "update SyncCast and the bundled passive tools together before "
                "running passive diagnostics"
            ),
        )
    payload.update(
        {
            "verdict": "ready",
            "stage": "ready",
            "reason": intent["reason"],
            "nextAction": intent["nextAction"],
            "passiveReady": True,
            "status": status,
        }
    )
    payload.update(intent)
    return payload


def wait_for_report(
    *,
    socket_path: Path,
    app_path: Path,
    process_name: str,
    timeout_sec: float,
    wait_sec: float,
    interval_sec: float,
    time_fn=time.monotonic,
    sleep_fn=time.sleep,
) -> dict[str, Any]:
    if wait_sec < 0:
        raise ValueError("--wait-sec must be >= 0")
    if interval_sec <= 0:
        raise ValueError("--interval-sec must be > 0")
    started = time_fn()
    deadline = started + wait_sec
    attempts: list[dict[str, Any]] = []
    report: dict[str, Any] | None = None
    while True:
        report = build_report(
            socket_path=socket_path,
            app_path=app_path,
            process_name=process_name,
            timeout_sec=timeout_sec,
        )
        attempts.append(
            {
                "index": len(attempts) + 1,
                "elapsedSec": round(max(0.0, time_fn() - started), 3),
                "verdict": report.get("verdict"),
                "stage": report.get("stage"),
                "reason": report.get("reason"),
                "syncContextState": report.get("syncContextState"),
                "passiveEvidenceIntent": report.get("passiveEvidenceIntent"),
                "passiveEvidenceIntentSource": report.get(
                    "passiveEvidenceIntentSource"
                ),
                "recommendedWorkflow": report.get("recommendedWorkflow"),
            }
        )
        if report.get("verdict") == "ready" or wait_sec == 0:
            break
        now = time_fn()
        if now >= deadline:
            break
        sleep_fn(min(interval_sec, max(0.0, deadline - now)))

    assert report is not None
    report = dict(report)
    report["waitSec"] = wait_sec
    report["intervalSec"] = interval_sec
    report["attemptCount"] = len(attempts)
    report["waitedSec"] = round(max(0.0, time_fn() - started), 3)
    report["attempts"] = attempts[-10:]
    return report


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Summarize SyncCast passive diagnostic readiness without opening "
            "the microphone, emitting audio, changing routes, or applying delay."
        )
    )
    parser.add_argument("--socket", type=Path, default=_default_socket_path())
    parser.add_argument(
        "--app",
        type=Path,
        default=Path("/Applications/SyncCast.app"),
    )
    parser.add_argument("--process-name", default="SyncCastMenuBar")
    parser.add_argument("--timeout-sec", type=float, default=2.0)
    parser.add_argument(
        "--wait-sec",
        type=float,
        default=0.0,
        help="poll until ready for up to this many seconds without opening the mic",
    )
    parser.add_argument(
        "--interval-sec",
        type=float,
        default=2.0,
        help="poll interval used with --wait-sec",
    )
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        report = wait_for_report(
            socket_path=args.socket,
            app_path=args.app,
            process_name=args.process_name,
            timeout_sec=args.timeout_sec,
            wait_sec=args.wait_sec,
            interval_sec=args.interval_sec,
        )
        if args.output is not None:
            _write_json(args.output, report)
        print(json.dumps(report, indent=2, sort_keys=True))
        return EXIT_READY if report.get("verdict") == "ready" else EXIT_NOT_READY
    except Exception as exc:
        print(
            json.dumps({"verdict": "bad_input", "error": str(exc)}, indent=2),
            file=sys.stderr,
        )
        return EXIT_BAD_INPUT


if __name__ == "__main__":
    raise SystemExit(main())
