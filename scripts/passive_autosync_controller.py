#!/usr/bin/env python3
"""Plan the next no-probe passive autosync step.

The lower-level passive helpers are intentionally conservative and mostly
one-shot. This controller turns the app's no-mic readiness recommendation into
one concrete, reproducible command while preserving the product safety rules:
no emitted audio, no automatic delay write, and microphone access only inside
the passive drift session after its preflight gates pass.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any

import passive_readiness_report as readiness_report


EXIT_OK = 0
EXIT_NOT_READY = 3
EXIT_BAD_INPUT = 2
SCHEMA = "syncast.passive_autosync_plan.v1"


def _default_state_root() -> Path:
    return Path.home() / "Library/Application Support/SyncCast/Passive"


def _default_socket_path() -> Path:
    return Path(f"/tmp/syncast-{os.getuid()}.calibration.sock")


def _read_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text())
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected JSON object")
    return payload


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def _read_json_optional(
    path: Path,
    issues: list[str] | None = None,
) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        return _read_json(path)
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as exc:
        if issues is not None:
            issues.append(f"{path}: invalid JSON: {exc}")
        return None
    except ValueError as exc:
        if issues is not None:
            issues.append(str(exc))
        return None


def _read_execution_json_optional(
    path: Path,
    started_unix: float | None,
    stale_artifacts: list[str],
    artifact_issues: list[str],
) -> dict[str, Any] | None:
    if started_unix is not None and path.exists():
        try:
            if path.stat().st_mtime < started_unix:
                stale_artifacts.append(str(path))
                return None
        except OSError as exc:
            artifact_issues.append(f"{path}: stat failed: {exc}")
            return None
    return _read_json_optional(path, artifact_issues)


def _session_root(state_root: Path, now: float | None = None) -> Path:
    when = time.time() if now is None else now
    stamp = time.strftime(
        "%Y%m%d-%H%M%S",
        time.localtime(when),
    )
    if now is None:
        suffix = f"{time.time_ns() % 1_000_000:06d}"
    else:
        suffix = f"{int((when - int(when)) * 1_000_000):06d}"
    return state_root / "sessions" / f"passive-{stamp}-{suffix}"


def _load_readiness(args: argparse.Namespace) -> dict[str, Any]:
    if args.readiness_json is not None:
        return _read_json(args.readiness_json)
    payload = readiness_report.wait_for_report(
        socket_path=args.socket,
        app_path=args.app,
        process_name=args.process_name,
        timeout_sec=args.timeout_sec,
        wait_sec=args.wait_sec,
        interval_sec=args.interval_sec,
    )
    return payload


def _candidate_apply_artifact_issue(candidate: Path) -> str | None:
    issues: list[str] = []
    _read_json_optional(candidate / "passive_apply.json", issues)
    return issues[0] if issues else None


def _latest_candidate_session(state_root: Path) -> tuple[Path | None, str | None]:
    sessions = state_root / "sessions"
    if not sessions.exists():
        return (None, None)
    candidates: list[tuple[float, Path]] = []
    corrupt_candidate_issue: str | None = None
    latest_corrupt_report: tuple[float, str] | None = None
    for report in sessions.glob("*/control_report.json"):
        try:
            report_mtime = report.stat().st_mtime
        except OSError:
            report_mtime = 0
        try:
            payload = _read_json(report)
        except Exception as exc:
            latest_corrupt_report = max(
                latest_corrupt_report or (float("-inf"), ""),
                (report_mtime, f"{report}: invalid candidate control_report JSON: {exc}"),
                key=lambda item: item[0],
            )
            continue
        if payload.get("verdict") != "ready_for_apply_candidate":
            continue
        passive_apply_issues: list[str] = []
        passive_apply = _read_json_optional(
            report.parent / "passive_apply.json",
            passive_apply_issues,
        )
        if passive_apply_issues:
            corrupt_candidate_issue = passive_apply_issues[0]
            continue
        if passive_apply is not None and passive_apply.get("verdict") in {
                "dry_run_ready",
                "applied",
        }:
            continue
        candidates.append((report_mtime, report.parent))
    if not candidates:
        if latest_corrupt_report is not None:
            return (None, latest_corrupt_report[1])
        return (None, corrupt_candidate_issue)
    latest_candidate = sorted(candidates)[-1]
    if latest_corrupt_report is not None and latest_corrupt_report[0] >= latest_candidate[0]:
        return (None, latest_corrupt_report[1])
    return (latest_candidate[1], None)


def _base_plan(
    *,
    readiness: dict[str, Any],
    state_root: Path,
    socket: Path,
) -> dict[str, Any]:
    workflow = readiness.get("recommendedWorkflow")
    intent = readiness.get("passiveEvidenceIntent")
    return {
        "schema": SCHEMA,
        "createdUnix": round(time.time(), 3),
        "verdict": "blocked",
        "reason": readiness.get("reason") or "passive readiness is not ready",
        "readinessVerdict": readiness.get("verdict"),
        "readinessStage": readiness.get("stage"),
        "recommendedWorkflow": workflow,
        "recommendedSessionMode": readiness.get("recommendedSessionMode"),
        "passiveEvidenceIntent": intent,
        "passiveEvidenceIntentSource": readiness.get("passiveEvidenceIntentSource"),
        "stateRoot": str(state_root),
        "socket": str(socket),
        "command": None,
        "environment": {},
        "opensMicrophone": False,
        "emitsAudio": False,
        "appliesDelay": False,
        "allowAcceptedDelayApply": False,
        "nextAction": readiness.get("nextAction"),
    }


def _session_command(
    *,
    samples: int,
    interval_sec: float,
    duration_sec: float,
    session_root: Path,
) -> list[str]:
    return [
        "bash",
        "scripts/passive_drift_session.sh",
        str(samples),
        str(interval_sec),
        str(duration_sec),
        str(session_root),
    ]


def _session_parameters_from_plan(plan: dict[str, Any]) -> tuple[int, float, float]:
    command = plan.get("command")
    if not isinstance(command, list) or len(command) < 5:
        return (6, 60.0, 4.0)
    try:
        return (int(command[2]), float(command[3]), float(command[4]))
    except (TypeError, ValueError):
        return (6, 60.0, 4.0)


def _common_session_env(
    *,
    socket: Path,
    auto_start_targets: str,
    auto_capture_backend: str,
    auto_launch_mode: str,
) -> dict[str, str]:
    env = {
        "SYNCAST_PASSIVE_SOCKET": str(socket),
        "SYNCAST_PASSIVE_WORKFLOW_GUARD": "enforce",
    }
    if auto_start_targets:
        env["SYNCAST_PASSIVE_AUTO_START_TARGETS"] = auto_start_targets
    if auto_capture_backend:
        env["SYNCAST_PASSIVE_AUTO_CAPTURE_BACKEND"] = auto_capture_backend
    if auto_launch_mode:
        env["SYNCAST_PASSIVE_AUTO_LAUNCH_MODE"] = auto_launch_mode
    return env


def _session_plan_from_parts(
    *,
    state_root: Path,
    socket: Path,
    session_root: Path,
    samples: int,
    interval_sec: float,
    duration_sec: float,
    reason: str,
    next_action: str,
    baseline_mode: str,
    baseline_mark_mode: str,
    passive_apply_mode: str,
    auto_start_targets: str = "",
    auto_capture_backend: str = "",
    auto_launch_mode: str = "",
    allow_accepted_delay_apply: bool = False,
) -> dict[str, Any]:
    baseline_store = state_root / "baselines.json"
    control_state = state_root / "control_state.json"
    env = _common_session_env(
        socket=socket,
        auto_start_targets=auto_start_targets,
        auto_capture_backend=auto_capture_backend,
        auto_launch_mode=auto_launch_mode,
    )
    env.update(
        {
            "SYNCAST_PASSIVE_BASELINE_STORE": str(baseline_store),
            "SYNCAST_PASSIVE_BASELINE_MODE": baseline_mode,
            "SYNCAST_PASSIVE_BASELINE_MARK_MODE": baseline_mark_mode,
            "SYNCAST_PASSIVE_CONTROL_STATE": str(control_state),
            "SYNCAST_PASSIVE_APPLY_MODE": passive_apply_mode,
        }
    )
    return {
        "schema": SCHEMA,
        "createdUnix": round(time.time(), 3),
        "verdict": "ready_to_run_session",
        "reason": reason,
        "stateRoot": str(state_root),
        "socket": str(socket),
        "sessionRoot": str(session_root),
        "baselineStore": str(baseline_store),
        "controlState": str(control_state),
        "command": _session_command(
            samples=samples,
            interval_sec=interval_sec,
            duration_sec=duration_sec,
            session_root=session_root,
        ),
        "environment": env,
        "opensMicrophone": True,
        "emitsAudio": False,
        "appliesDelay": False,
        "allowAcceptedDelayApply": bool(allow_accepted_delay_apply),
        "nextAction": next_action,
    }


def _apply_dry_run_plan_from_candidate(
    *,
    state_root: Path,
    socket: Path,
    candidate: Path,
    reason: str = "run app-side passive apply dry-run for the existing candidate",
    allow_accepted_delay_apply: bool = False,
) -> dict[str, Any]:
    apply_json = candidate / "passive_apply.json"
    return {
        "schema": SCHEMA,
        "createdUnix": round(time.time(), 3),
        "verdict": "ready_to_run_apply_dry_run",
        "reason": reason,
        "stateRoot": str(state_root),
        "socket": str(socket),
        "sessionRoot": str(candidate),
        "command": [
            "python3",
            "scripts/passive_apply_candidate.py",
            str(candidate),
            "--socket",
            str(socket),
            "--output",
            str(apply_json),
        ],
        "environment": {"SYNCAST_PASSIVE_SOCKET": str(socket)},
        "opensMicrophone": False,
        "emitsAudio": False,
        "appliesDelay": False,
        "allowAcceptedDelayApply": bool(allow_accepted_delay_apply),
        "nextAction": "run the planned app-side dry-run; it must not write delay",
    }


def _accepted_candidate_plan(
    *,
    state_root: Path,
    socket: Path,
    readiness: dict[str, Any],
    apply: bool = False,
) -> dict[str, Any]:
    session_root_raw = readiness.get("passiveDryRunSessionRoot")
    session_root = (
        Path(str(session_root_raw))
        if session_root_raw
        else state_root / "accepted-candidate"
    )
    output = session_root / "passive_accepted_apply.json"
    command = [
        "python3",
        "scripts/passive_apply_accepted_candidate.py",
        "--socket",
        str(socket),
        "--output",
        str(output),
    ]
    _append_expected_accepted_candidate_args(command, readiness)
    if apply:
        command.append("--apply")
    return {
        "schema": SCHEMA,
        "createdUnix": round(time.time(), 3),
        "verdict": "ready_to_run_accepted_candidate_apply"
        if apply
        else "ready_to_run_accepted_candidate_dry_run",
        "reason": "apply the app-accepted passive candidate through the guarded RPC"
        if apply
        else "re-run the app-side guard against the accepted passive candidate",
        "stateRoot": str(state_root),
        "socket": str(socket),
        "sessionRoot": str(session_root),
        "acceptedApply": str(output),
        "command": command,
        "environment": {"SYNCAST_PASSIVE_SOCKET": str(socket)},
        "opensMicrophone": False,
        "emitsAudio": False,
        "appliesDelay": bool(apply),
        "allowAcceptedDelayApply": bool(apply),
        "nextAction": (
            "run guarded accepted-candidate apply, then validate with a no-apply passive session"
            if apply
            else "run the accepted-candidate guard dry-run; it must not write delay"
        ),
    }


def _append_expected_accepted_candidate_args(
    command: list[str],
    readiness: dict[str, Any],
) -> None:
    field_flags = [
        ("passiveDryRunSessionRoot", "--expected-session-root"),
        ("passiveDryRunControlReport", "--expected-control-report"),
        ("passiveDryRunTargetDelayMs", "--expected-target-delay-ms"),
        ("passiveDryRunCurrentDelayMs", "--expected-current-delay-ms"),
        ("passiveDryRunContextSignature", "--expected-context-signature"),
        ("passiveDryRunCaptureBackend", "--expected-capture-backend"),
        ("passiveDryRunEnabledAirplayCount", "--expected-enabled-airplay-count"),
        ("passiveDryRunActiveAirplayCount", "--expected-active-airplay-count"),
        ("passiveDryRunAirplayTimingEpoch", "--expected-airplay-timing-epoch"),
        (
            "passiveDryRunAcceptedSyncContextRevision",
            "--expected-accepted-sync-context-revision",
        ),
        ("passiveDryRunAcceptedUnix", "--expected-accepted-unix"),
    ]
    for field, flag in field_flags:
        value = readiness.get(field)
        if value is None:
            continue
        text = str(value).strip()
        if not text:
            continue
        command.extend([flag, text])


def _accepted_candidate_readiness_from_summary(
    plan: dict[str, Any],
    summary: dict[str, Any],
) -> dict[str, Any]:
    readiness: dict[str, Any] = {}
    session_root_raw = summary.get("sessionRoot") or plan.get("sessionRoot")
    if session_root_raw:
        readiness["passiveDryRunSessionRoot"] = str(session_root_raw)
    control_report = summary.get("controlReport")
    if control_report:
        readiness["passiveDryRunControlReport"] = str(control_report)
    result = summary.get("passiveApplyResult")
    if not isinstance(result, dict):
        result = summary.get("passiveAcceptedApplyResult")
    if not isinstance(result, dict):
        return readiness
    field_map = {
        "targetDelayMs": "passiveDryRunTargetDelayMs",
        "currentDelayMs": "passiveDryRunCurrentDelayMs",
        "contextSignature": "passiveDryRunContextSignature",
        "captureBackend": "passiveDryRunCaptureBackend",
        "enabledAirplayCount": "passiveDryRunEnabledAirplayCount",
        "activeAirplayCount": "passiveDryRunActiveAirplayCount",
        "airplayTimingEpoch": "passiveDryRunAirplayTimingEpoch",
        "syncContextRevision": "passiveDryRunAcceptedSyncContextRevision",
        "acceptedUnix": "passiveDryRunAcceptedUnix",
    }
    for result_field, readiness_field in field_map.items():
        value = result.get(result_field)
        if value is not None:
            readiness[readiness_field] = value
    return readiness


def _rollback_delay_plan(
    *,
    state_root: Path,
    socket: Path,
    session_root: Path,
    target_delay_ms: int,
    expected_current_delay_ms: int,
    allow_accepted_delay_apply: bool,
    expected_context: dict[str, Any] | None = None,
    reason: str = "post-apply validation did not hold; restore the previous delay",
) -> dict[str, Any]:
    output = session_root / "passive_rollback.json"
    command = [
        "python3",
        "scripts/passive_rollback_delay.py",
        "--socket",
        str(socket),
        "--target-delay-ms",
        str(int(target_delay_ms)),
        "--expected-current-delay-ms",
        str(int(expected_current_delay_ms)),
        "--output",
        str(output),
    ]
    _append_expected_rollback_args(command, expected_context or {})
    return {
        "schema": SCHEMA,
        "createdUnix": round(time.time(), 3),
        "verdict": "ready_to_run_delay_rollback",
        "reason": reason,
        "stateRoot": str(state_root),
        "socket": str(socket),
        "sessionRoot": str(session_root),
        "passiveRollback": str(output),
        "command": command,
        "environment": {"SYNCAST_PASSIVE_SOCKET": str(socket)},
        "opensMicrophone": False,
        "emitsAudio": False,
        "appliesDelay": True,
        "allowAcceptedDelayApply": bool(allow_accepted_delay_apply),
        "rollbackDelayMs": int(target_delay_ms),
        "rollbackExpectedCurrentDelayMs": int(expected_current_delay_ms),
        "rollbackExpectedContext": expected_context or {},
        "nextAction": (
            "run guarded rollback; it will only write if the app is still on "
            "the same applied delay and route context"
        ),
    }


def _append_expected_rollback_args(
    command: list[str],
    expected_context: dict[str, Any],
) -> None:
    field_flags = [
        ("contextSignature", "--expected-context-signature"),
        ("captureBackend", "--expected-capture-backend"),
        ("enabledAirplayCount", "--expected-enabled-airplay-count"),
        ("activeAirplayCount", "--expected-active-airplay-count"),
        ("airplayTimingEpoch", "--expected-airplay-timing-epoch"),
        ("syncContextRevision", "--expected-sync-context-revision"),
    ]
    for field, flag in field_flags:
        value = expected_context.get(field)
        if value is None:
            continue
        text = str(value).strip()
        if not text:
            continue
        command.extend([flag, text])


def _readiness_bootstrap_plan_from_parts(
    *,
    state_root: Path,
    socket: Path,
    session_root: Path,
    samples: int,
    interval_sec: float,
    duration_sec: float,
    readiness: dict[str, Any],
    auto_start_targets: str,
    auto_capture_backend: str = "",
    auto_launch_mode: str = "",
    allow_accepted_delay_apply: bool = False,
) -> dict[str, Any]:
    env = _common_session_env(
        socket=socket,
        auto_start_targets=auto_start_targets,
        auto_capture_backend=auto_capture_backend,
        auto_launch_mode=auto_launch_mode,
    )
    env.update(
        {
            "SYNCAST_PASSIVE_READINESS_ONLY": "1",
            "SYNCAST_PASSIVE_APPLY_MODE": "off",
        }
    )
    return {
        "schema": SCHEMA,
        "createdUnix": round(time.time(), 3),
        "verdict": "ready_to_run_readiness_bootstrap",
        "reason": (
            "bootstrap passive readiness with auto-start before opening the microphone"
        ),
        "readinessVerdict": readiness.get("verdict"),
        "readinessStage": readiness.get("stage"),
        "stateRoot": str(state_root),
        "socket": str(socket),
        "sessionRoot": str(session_root),
        "command": _session_command(
            samples=samples,
            interval_sec=interval_sec,
            duration_sec=duration_sec,
            session_root=session_root,
        ),
        "environment": env,
        "opensMicrophone": False,
        "emitsAudio": False,
        "appliesDelay": False,
        "allowAcceptedDelayApply": bool(allow_accepted_delay_apply),
        "changesRoutes": True,
        "nextAction": (
            "run readiness-only passive auto-start; inspect readiness/control_report "
            "before collecting a microphone corpus"
        ),
    }


def build_plan(
    *,
    readiness: dict[str, Any],
    state_root: Path,
    session_root: Path,
    socket: Path,
    samples: int,
    interval_sec: float,
    duration_sec: float,
    auto_start_targets: str = "",
    auto_capture_backend: str = "",
    auto_launch_mode: str = "",
    candidate_session: Path | None = None,
    allow_accepted_delay_apply: bool = False,
) -> dict[str, Any]:
    plan = _base_plan(readiness=readiness, state_root=state_root, socket=socket)
    plan["allowAcceptedDelayApply"] = bool(allow_accepted_delay_apply)
    if readiness.get("verdict") != "ready":
        if auto_start_targets:
            plan.update(
                _readiness_bootstrap_plan_from_parts(
                    state_root=state_root,
                    socket=socket,
                    session_root=session_root,
                    samples=samples,
                    interval_sec=interval_sec,
                    duration_sec=duration_sec,
                    readiness=readiness,
                    auto_start_targets=auto_start_targets,
                    auto_capture_backend=auto_capture_backend,
                    auto_launch_mode=auto_launch_mode,
                    allow_accepted_delay_apply=allow_accepted_delay_apply,
                )
            )
            return plan
        plan["reason"] = readiness.get("reason") or "passive readiness is not ready"
        plan["nextAction"] = readiness.get(
            "nextAction",
            "start SyncCast in Whole-home and rerun passive readiness",
        )
        return plan

    workflow = str(readiness.get("recommendedWorkflow") or "").strip()

    if workflow == "record_baseline":
        plan.update(
            _session_plan_from_parts(
                state_root=state_root,
                socket=socket,
                session_root=session_root,
                samples=samples,
                interval_sec=interval_sec,
                duration_sec=duration_sec,
                reason="record a safe no-probe baseline for the current route",
                next_action="run the planned passive baseline session",
                baseline_mode="auto",
                baseline_mark_mode="mark",
                passive_apply_mode="dry-run",
                auto_start_targets=auto_start_targets,
                auto_capture_backend=auto_capture_backend,
                auto_launch_mode=auto_launch_mode,
                allow_accepted_delay_apply=allow_accepted_delay_apply,
            )
        )
        return plan

    if workflow == "monitor_drift":
        plan.update(
            _session_plan_from_parts(
                state_root=state_root,
                socket=socket,
                session_root=session_root,
                samples=samples,
                interval_sec=interval_sec,
                duration_sec=duration_sec,
                reason="monitor no-probe drift against the stored route baseline",
                next_action="run the planned passive drift session",
                baseline_mode="decide",
                baseline_mark_mode="off",
                passive_apply_mode="dry-run",
                auto_start_targets=auto_start_targets,
                auto_capture_backend=auto_capture_backend,
                auto_launch_mode=auto_launch_mode,
                allow_accepted_delay_apply=allow_accepted_delay_apply,
            )
        )
        return plan

    if workflow == "validate_apply":
        plan.update(
            _session_plan_from_parts(
                state_root=state_root,
                socket=socket,
                session_root=session_root,
                samples=samples,
                interval_sec=interval_sec,
                duration_sec=duration_sec,
                reason="validate the recently applied delay without another dry-run/apply step",
                next_action="run the planned post-apply validation session",
                baseline_mode="decide",
                baseline_mark_mode="off",
                passive_apply_mode="off",
                auto_start_targets=auto_start_targets,
                auto_capture_backend=auto_capture_backend,
                auto_launch_mode=auto_launch_mode,
                allow_accepted_delay_apply=allow_accepted_delay_apply,
            )
        )
        return plan

    if workflow == "locked_diagnostic":
        env = _common_session_env(
            socket=socket,
            auto_start_targets=auto_start_targets,
            auto_capture_backend=auto_capture_backend,
            auto_launch_mode=auto_launch_mode,
        )
        env.update(
            {
                "SYNCAST_PASSIVE_BASELINE_MARK_MODE": "off",
                "SYNCAST_PASSIVE_APPLY_MODE": "off",
            }
        )
        plan.update(
            {
                "verdict": "ready_to_run_session",
                "reason": "collect locked-delay diagnostics without any apply path",
                "sessionRoot": str(session_root),
                "command": _session_command(
                    samples=samples,
                    interval_sec=interval_sec,
                    duration_sec=duration_sec,
                    session_root=session_root,
                ),
                "environment": env,
                "opensMicrophone": True,
                "emitsAudio": False,
                "appliesDelay": False,
                "allowAcceptedDelayApply": bool(allow_accepted_delay_apply),
                "nextAction": "run the planned locked diagnostic session",
            }
        )
        return plan

    if workflow == "apply_dry_run":
        candidate_issue: str | None = None
        if candidate_session is None:
            candidate, candidate_issue = _latest_candidate_session(state_root)
        else:
            candidate = candidate_session
            candidate_issue = _candidate_apply_artifact_issue(candidate)
        if candidate_issue is not None:
            plan.update(
                {
                    "reason": candidate_issue,
                    "nextAction": (
                        "repair or rerun the passive candidate session so corrupt "
                        "apply artifacts are replaced before dry-run"
                    ),
                }
            )
            return plan
        if candidate is None:
            plan.update(
                {
                    "reason": "apply_dry_run requires an existing ready passive session",
                    "nextAction": (
                        "pass --candidate-session pointing at the session with "
                        "correction_gate.json, or rerun the drift session that produced it"
                    ),
                }
            )
            return plan
        plan.update(
            _apply_dry_run_plan_from_candidate(
                state_root=state_root,
                socket=socket,
                candidate=candidate,
                allow_accepted_delay_apply=allow_accepted_delay_apply,
            )
        )
        return plan

    if workflow == "manual_validation":
        plan.update(
            _accepted_candidate_plan(
                state_root=state_root,
                socket=socket,
                readiness=readiness,
                apply=allow_accepted_delay_apply,
            )
        )
        return plan

    plan.update(
        {
            "reason": f"unsupported passive readiness workflow: {workflow or '<missing>'}",
            "nextAction": "inspect readiness.json before opening microphone",
        }
    )
    return plan


def _command_is_accepted_apply(command: Any) -> bool:
    return (
        isinstance(command, list)
        and len(command) > 1
        and str(command[1]).endswith("passive_apply_accepted_candidate.py")
        and "--apply" in command
    )


def _command_is_rollback_delay(command: Any) -> bool:
    return (
        isinstance(command, list)
        and len(command) > 1
        and str(command[1]).endswith("passive_rollback_delay.py")
    )


def _command_is_allowed_delay_apply(command: Any) -> bool:
    return _command_is_accepted_apply(command) or _command_is_rollback_delay(command)


def _plan_allows_delay_apply(plan: dict[str, Any]) -> bool:
    return bool(plan.get("allowAcceptedDelayApply")) and _command_is_allowed_delay_apply(
        plan.get("command")
    )


def _int_or_none(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    try:
        text = str(value).strip()
        if not text:
            return None
        return int(float(text))
    except (TypeError, ValueError):
        return None


def _rollback_pair_from_summary(summary: dict[str, Any]) -> tuple[int, int] | None:
    for key in ("passiveAcceptedApplyResult", "passiveApplyResult"):
        result = summary.get(key)
        if not isinstance(result, dict):
            continue
        previous_delay = _int_or_none(result.get("previousDelayMs"))
        applied_delay = _int_or_none(result.get("appliedDelayMs"))
        if applied_delay is None:
            applied_delay = _int_or_none(result.get("targetDelayMs"))
        if previous_delay is not None and applied_delay is not None:
            return (previous_delay, applied_delay)
    return None


def _rollback_expected_context_from_summary(
    summary: dict[str, Any],
) -> dict[str, Any]:
    for key in ("passiveAcceptedApplyResult", "passiveApplyResult"):
        result = summary.get(key)
        if not isinstance(result, dict):
            continue
        expected: dict[str, Any] = {}
        for field in (
            "contextSignature",
            "captureBackend",
            "enabledAirplayCount",
            "activeAirplayCount",
            "airplayTimingEpoch",
            "syncContextRevision",
        ):
            value = result.get(field)
            if value is not None:
                expected[field] = value
        if expected:
            return expected
    return {}


def summarize_execution(
    plan: dict[str, Any],
    exit_code: int,
    *,
    started_unix: float | None = None,
) -> dict[str, Any]:
    """Bind a finished command back to its passive artifacts."""

    session_root_raw = plan.get("sessionRoot")
    session_root = Path(str(session_root_raw)) if session_root_raw else None
    command = plan.get("command")
    delay_apply_allowed = _plan_allows_delay_apply(plan)
    is_apply_dry_run = plan.get("verdict") == "ready_to_run_apply_dry_run" or (
        isinstance(command, list)
        and len(command) > 1
        and str(command[1]).endswith("passive_apply_candidate.py")
    )
    is_accepted_dry_run = (
        plan.get("verdict") == "ready_to_run_accepted_candidate_dry_run"
        or (
            isinstance(command, list)
            and len(command) > 1
            and str(command[1]).endswith("passive_apply_accepted_candidate.py")
        )
    )
    is_rollback_delay = _command_is_rollback_delay(command)
    summary: dict[str, Any] = {
        "exitCode": exit_code,
        "verdict": "command_succeeded" if exit_code == 0 else "command_failed",
        "reason": "command exited successfully"
        if exit_code == 0
        else f"command exited with {exit_code}",
        "opensMicrophone": bool(plan.get("opensMicrophone")),
        "emitsAudio": False,
        "appliesDelay": False,
        "nextAction": plan.get("nextAction"),
    }
    stale_artifacts: list[str] = []
    artifact_issues: list[str] = []
    command_succeeded = exit_code == EXIT_OK
    if session_root is not None:
        summary["sessionRoot"] = str(session_root)
        control_report = _read_execution_json_optional(
            session_root / "control_report.json",
            started_unix,
            stale_artifacts,
            artifact_issues,
        )
        passive_apply = _read_execution_json_optional(
            session_root / "passive_apply.json",
            started_unix,
            stale_artifacts,
            artifact_issues,
        )
        accepted_apply_path = (
            Path(str(plan["acceptedApply"]))
            if plan.get("acceptedApply")
            else session_root / "passive_accepted_apply.json"
        )
        accepted_apply = _read_execution_json_optional(
            accepted_apply_path,
            started_unix,
            stale_artifacts,
            artifact_issues,
        )
        rollback_path = (
            Path(str(plan["passiveRollback"]))
            if plan.get("passiveRollback")
            else session_root / "passive_rollback.json"
        )
        passive_rollback = _read_execution_json_optional(
            rollback_path,
            started_unix,
            stale_artifacts,
            artifact_issues,
        )
        audit = _read_execution_json_optional(
            session_root / "audit.json",
            started_unix,
            stale_artifacts,
            artifact_issues,
        )
        if control_report is not None:
            summary.update(
                {
                    "phase": control_report.get("phase"),
                    "nextAction": control_report.get("nextAction"),
                    "blockingStage": control_report.get("blockingStage"),
                    "controlReport": str(session_root / "control_report.json"),
                    "controlReportVerdict": control_report.get("verdict"),
                    "controlReportPhase": control_report.get("phase"),
                    "controlReportReason": control_report.get("reason"),
                    "readinessVerdict": control_report.get("readinessVerdict"),
                    "readinessStage": control_report.get("readinessStage"),
                    "readinessRecommendedWorkflow": control_report.get(
                        "readinessRecommendedWorkflow"
                    ),
                    "readinessRecommendedSessionMode": control_report.get(
                        "readinessRecommendedSessionMode"
                    ),
                    "readinessPassiveEvidenceIntent": control_report.get(
                        "readinessPassiveEvidenceIntent"
                    ),
                    "readinessPassiveEvidenceIntentSource": control_report.get(
                        "readinessPassiveEvidenceIntentSource"
                    ),
                    "appliesDelay": control_report.get("appliesDelay") is True,
                }
            )
            if control_report.get("emitsAudio") is True:
                summary["emitsAudio"] = True
            if command_succeeded:
                summary.update(
                    {
                        "verdict": str(
                            control_report.get("verdict") or summary["verdict"]
                        ),
                        "reason": str(control_report.get("reason") or summary["reason"]),
                    }
                )
            elif control_report.get("reason"):
                summary["reason"] = (
                    f"{summary['reason']}: {control_report.get('reason')}"
                )
        if passive_apply is not None:
            summary.update(
                {
                    "passiveApply": str(session_root / "passive_apply.json"),
                    "passiveApplyVerdict": passive_apply.get("verdict"),
                    "passiveApplyResult": passive_apply.get("result"),
                    "appliesDelay": summary.get("appliesDelay") is True
                    or passive_apply.get("appliesDelay") is True,
                }
            )
            if passive_apply.get("emitsAudio") is True:
                summary["emitsAudio"] = True
            if passive_apply.get("opensMicrophone") is True:
                summary["opensMicrophone"] = True
            if command_succeeded and (is_apply_dry_run or control_report is None):
                summary.update(
                    {
                        "verdict": str(passive_apply.get("verdict") or summary["verdict"]),
                        "reason": str(
                            passive_apply.get("error")
                            or (passive_apply.get("result") or {}).get("reason")
                            or summary["reason"]
                        ),
                    }
                )
        if audit is not None:
            summary["audit"] = str(session_root / "audit.json")
            summary["auditVerdict"] = audit.get("verdict")
        if accepted_apply is not None:
            summary.update(
                {
                    "passiveAcceptedApply": str(accepted_apply_path),
                    "passiveAcceptedApplyVerdict": accepted_apply.get("verdict"),
                    "passiveAcceptedApplyResult": accepted_apply.get("result"),
                    "appliesDelay": summary.get("appliesDelay") is True
                    or accepted_apply.get("appliesDelay") is True,
                }
            )
            if accepted_apply.get("emitsAudio") is True:
                summary["emitsAudio"] = True
            if accepted_apply.get("opensMicrophone") is True:
                summary["opensMicrophone"] = True
            if command_succeeded and (is_accepted_dry_run or control_report is None):
                summary.update(
                    {
                        "verdict": str(
                            accepted_apply.get("verdict") or summary["verdict"]
                        ),
                        "reason": str(
                            accepted_apply.get("error")
                            or (accepted_apply.get("result") or {}).get("reason")
                            or summary["reason"]
                        ),
                    }
                )
        if passive_rollback is not None:
            summary.update(
                {
                    "passiveRollback": str(rollback_path),
                    "passiveRollbackVerdict": passive_rollback.get("verdict"),
                    "passiveRollbackResult": passive_rollback.get("result"),
                    "appliesDelay": summary.get("appliesDelay") is True
                    or passive_rollback.get("appliesDelay") is True,
                }
            )
            if passive_rollback.get("emitsAudio") is True:
                summary["emitsAudio"] = True
            if passive_rollback.get("opensMicrophone") is True:
                summary["opensMicrophone"] = True
            if command_succeeded and (is_rollback_delay or control_report is None):
                summary.update(
                    {
                        "verdict": str(
                            passive_rollback.get("verdict") or summary["verdict"]
                        ),
                        "reason": str(
                            passive_rollback.get("error")
                            or (passive_rollback.get("result") or {}).get("reason")
                            or summary["reason"]
                        ),
                    }
                )
    if stale_artifacts:
        summary["staleArtifacts"] = stale_artifacts
    if artifact_issues:
        summary.update(
            {
                "verdict": "incomplete",
                "phase": "artifact_json",
                "reason": artifact_issues[0],
                "blockingStage": "artifact_json",
                "nextAction": (
                    "repair or rerun the passive autosync step so corrupt JSON "
                    "artifacts are replaced"
                ),
                "artifactIssues": artifact_issues,
            }
        )
    safety_issues: list[str] = []
    if artifact_issues:
        safety_issues.append(
            "corrupt JSON artifact observed; autosync execution cannot be trusted"
        )
    if summary.get("appliesDelay") is True and not delay_apply_allowed:
        safety_issues.append(
            "unexpected delay write observed; autosync controller plans dry-run/no-write steps"
        )
    if summary.get("emitsAudio") is True:
        safety_issues.append("unexpected emitted audio observed in passive autosync step")
    if (
        is_apply_dry_run or is_accepted_dry_run or is_rollback_delay
    ) and summary.get("opensMicrophone") is True:
        safety_issues.append("unexpected microphone access observed during app-side guard step")
    if safety_issues:
        summary["safetyIssues"] = safety_issues
        summary["safetyIssue"] = "; ".join(safety_issues)
    return summary


def follow_up_plan(plan: dict[str, Any], summary: dict[str, Any]) -> dict[str, Any]:
    """Plan the next safe step after one executed autosync command."""

    state_root = Path(str(plan.get("stateRoot") or _default_state_root()))
    socket = Path(str(plan.get("socket") or _default_socket_path()))
    samples, interval_sec, duration_sec = _session_parameters_from_plan(plan)
    command = plan.get("command")
    env = plan.get("environment") if isinstance(plan.get("environment"), dict) else {}
    auto_start_targets = str(env.get("SYNCAST_PASSIVE_AUTO_START_TARGETS") or "")
    auto_capture_backend = str(env.get("SYNCAST_PASSIVE_AUTO_CAPTURE_BACKEND") or "")
    auto_launch_mode = str(env.get("SYNCAST_PASSIVE_AUTO_LAUNCH_MODE") or "")
    allow_accepted_delay_apply = bool(plan.get("allowAcceptedDelayApply"))
    verdict = str(summary.get("verdict") or "")
    is_rollback_plan = _command_is_rollback_delay(command)
    readiness_only = str(env.get("SYNCAST_PASSIVE_READINESS_ONLY") or "") == "1"

    def blocked(reason: str, next_action: str | None = None) -> dict[str, Any]:
        return {
            "schema": SCHEMA,
            "createdUnix": round(time.time(), 3),
            "verdict": "blocked",
            "reason": reason,
            "stateRoot": str(state_root),
            "socket": str(socket),
            "command": None,
            "environment": {},
            "opensMicrophone": False,
            "emitsAudio": False,
            "appliesDelay": False,
            "allowAcceptedDelayApply": allow_accepted_delay_apply,
            "nextAction": next_action or summary.get("nextAction"),
        }

    if readiness_only:
        if summary.get("readinessVerdict") == "ready" and summary.get(
            "readinessRecommendedWorkflow"
        ):
            readiness = {
                "verdict": "ready",
                "recommendedWorkflow": summary.get("readinessRecommendedWorkflow"),
                "recommendedSessionMode": summary.get("readinessRecommendedSessionMode"),
                "passiveEvidenceIntent": summary.get("readinessPassiveEvidenceIntent"),
                "passiveEvidenceIntentSource": summary.get(
                    "readinessPassiveEvidenceIntentSource"
                ),
                "opensMicrophone": False,
                "emitsAudio": False,
                "appliesDelay": False,
            }
            return build_plan(
                readiness=readiness,
                state_root=state_root,
                session_root=_session_root(state_root),
                socket=socket,
                samples=samples,
                interval_sec=interval_sec,
                duration_sec=duration_sec,
                auto_start_targets=auto_start_targets,
                auto_capture_backend=auto_capture_backend,
                auto_launch_mode=auto_launch_mode,
                allow_accepted_delay_apply=allow_accepted_delay_apply,
            )
        return blocked(
            str(
                summary.get("reason")
                or "readiness-only bootstrap did not reach passive readiness"
            ),
            summary.get("nextAction"),
        )

    if summary.get("appliesDelay") is True and not _plan_allows_delay_apply(plan):
        return blocked(
            "unexpected delay write observed; require manual inspection before continuing",
            "inspect passive_apply.json/control_report.json before collecting more evidence",
        )

    if is_rollback_plan:
        if verdict == "rolled_back":
            return blocked(
                "rolled back after failed post-apply validation",
                "rerun passive autosync after the route is stable again",
            )
        return blocked(
            str(summary.get("reason") or "rollback did not complete"),
            "inspect passive_rollback.json before continuing",
        )

    rollback_delay = _int_or_none(plan.get("rollbackDelayMs"))
    rollback_expected_current = _int_or_none(plan.get("rollbackExpectedCurrentDelayMs"))
    rollback_expected_context = plan.get("rollbackExpectedContext")
    if not isinstance(rollback_expected_context, dict):
        rollback_expected_context = {}
    if (
        allow_accepted_delay_apply
        and rollback_delay is not None
        and rollback_expected_current is not None
        and verdict != "hold"
    ):
        return _rollback_delay_plan(
            state_root=state_root,
            socket=socket,
            session_root=_session_root(state_root),
            target_delay_ms=rollback_delay,
            expected_current_delay_ms=rollback_expected_current,
            allow_accepted_delay_apply=allow_accepted_delay_apply,
            expected_context=rollback_expected_context,
        )

    if verdict in {"baseline_recorded", "pending_confirmation"}:
        return _session_plan_from_parts(
            state_root=state_root,
            socket=socket,
            session_root=_session_root(state_root),
            samples=samples,
            interval_sec=interval_sec,
            duration_sec=duration_sec,
            reason="collect the next same-context passive drift session",
            next_action="run the follow-up passive drift session",
            baseline_mode="decide",
            baseline_mark_mode="off",
            passive_apply_mode="dry-run",
            auto_start_targets=auto_start_targets,
            auto_capture_backend=auto_capture_backend,
            auto_launch_mode=auto_launch_mode,
            allow_accepted_delay_apply=allow_accepted_delay_apply,
        )

    if verdict == "ready_for_apply_candidate":
        session_root_raw = summary.get("sessionRoot") or plan.get("sessionRoot")
        if not session_root_raw:
            return blocked(
                "ready_for_apply_candidate has no session root",
                "rerun autosync with --candidate-session",
            )
        return _apply_dry_run_plan_from_candidate(
            state_root=state_root,
            socket=socket,
            candidate=Path(str(session_root_raw)),
            reason="run app-side passive apply dry-run for the repeat-confirmed candidate",
            allow_accepted_delay_apply=allow_accepted_delay_apply,
        )

    if verdict == "applied":
        validation_plan = _session_plan_from_parts(
            state_root=state_root,
            socket=socket,
            session_root=_session_root(state_root),
            samples=samples,
            interval_sec=interval_sec,
            duration_sec=duration_sec,
            reason="validate the just-applied passive delay without another apply path",
            next_action="run the follow-up post-apply validation session",
            baseline_mode="decide",
            baseline_mark_mode="off",
            passive_apply_mode="off",
            auto_start_targets=auto_start_targets,
            auto_capture_backend=auto_capture_backend,
            auto_launch_mode=auto_launch_mode,
            allow_accepted_delay_apply=allow_accepted_delay_apply,
        )
        rollback_pair = _rollback_pair_from_summary(summary)
        if allow_accepted_delay_apply and rollback_pair is not None:
            rollback_delay, rollback_expected_current = rollback_pair
            rollback_expected_context = _rollback_expected_context_from_summary(summary)
            validation_plan["rollbackDelayMs"] = rollback_delay
            validation_plan["rollbackExpectedCurrentDelayMs"] = rollback_expected_current
            validation_plan["rollbackExpectedContext"] = rollback_expected_context
            validation_plan["rollbackSource"] = (
                summary.get("passiveAcceptedApply")
                or summary.get("passiveApply")
                or summary.get("sessionRoot")
            )
        return validation_plan

    if verdict == "dry_run_ready":
        return blocked(
            "app-side dry-run accepted the candidate; wait for the app to promote dryRunReady before accepted-candidate apply",
            (
                "rerun with explicit accepted apply only after passive readiness "
                "reports manual_validation_required"
            )
            if allow_accepted_delay_apply
            else "use listening validation or an explicit manual apply workflow before changing delay",
        )

    if verdict == "hold":
        return blocked(
            "route is stable; no immediate correction is required",
            "rerun passive autosync after a route, volume, wake, or listening-change event",
        )

    return blocked(
        str(summary.get("reason") or f"cannot safely continue after verdict {verdict}"),
        summary.get("nextAction"),
    )


def execute_plan(plan: dict[str, Any]) -> dict[str, Any]:
    command = plan.get("command")
    if not isinstance(command, list) or not command:
        executed = dict(plan)
        executed["execution"] = summarize_execution(plan, EXIT_NOT_READY)
        executed["execution"]["reason"] = "plan has no executable command"
        executed["followUpPlan"] = follow_up_plan(plan, executed["execution"])
        return executed
    env = {
        **os.environ,
        **{str(k): str(v) for k, v in plan.get("environment", {}).items()},
    }
    if plan.get("sessionRoot"):
        Path(str(plan["sessionRoot"])).mkdir(parents=True, exist_ok=True)
    started_unix = time.time()
    result = subprocess.run(command, env=env, check=False)
    executed = dict(plan)
    executed["execution"] = summarize_execution(
        plan,
        result.returncode,
        started_unix=started_unix,
    )
    executed["followUpPlan"] = follow_up_plan(plan, executed["execution"])
    return executed


def _chain_stop_reason(executed: dict[str, Any]) -> tuple[bool, str]:
    command = executed.get("command")
    if not isinstance(command, list) or not command:
        return (True, "plan_not_executable")
    execution = executed.get("execution")
    if not isinstance(execution, dict):
        return (True, "missing_execution_summary")
    follow_up = executed.get("followUpPlan")
    exit_code = execution.get("exitCode")
    if isinstance(exit_code, int) and exit_code != EXIT_OK:
        if execution.get("safetyIssue") or (
            execution.get("appliesDelay") is True
            and not _plan_allows_delay_apply(executed)
        ):
            return (True, "safety_issue")
        if execution.get("emitsAudio") is True:
            return (True, "unexpected_emitted_audio")
        if isinstance(follow_up, dict) and _plan_allows_delay_apply(follow_up):
            return (False, "ready")
        return (True, "command_failed")
    if execution.get("safetyIssue") or (
        execution.get("appliesDelay") is True
        and not _plan_allows_delay_apply(executed)
    ):
        return (True, "safety_issue")
    if execution.get("emitsAudio") is True:
        return (True, "unexpected_emitted_audio")
    if not isinstance(follow_up, dict):
        return (True, "missing_follow_up_plan")
    verdict = str(follow_up.get("verdict") or "")
    follow_up_command = follow_up.get("command")
    if not verdict.startswith("ready_to_run"):
        return (True, "follow_up_blocked")
    if not isinstance(follow_up_command, list) or not follow_up_command:
        return (True, "follow_up_has_no_command")
    if follow_up.get("appliesDelay") is True and not _plan_allows_delay_apply(follow_up):
        return (True, "unsafe_follow_up_applies_delay")
    if follow_up.get("emitsAudio") is True:
        return (True, "unsafe_follow_up_emits_audio")
    return (False, "ready")


def _chain_record(step: int, executed: dict[str, Any]) -> dict[str, Any]:
    return {
        "step": step,
        "planVerdict": executed.get("verdict"),
        "sessionRoot": executed.get("sessionRoot"),
        "command": executed.get("command"),
        "opensMicrophone": bool(executed.get("opensMicrophone")),
        "emitsAudio": bool(executed.get("emitsAudio")),
        "appliesDelay": bool(executed.get("appliesDelay")),
        "execution": executed.get("execution"),
        "followUpPlan": executed.get("followUpPlan"),
    }


def _chain_flag(chain: list[dict[str, Any]], key: str) -> bool:
    for step in chain:
        if step.get(key) is True:
            return True
        execution = step.get("execution")
        if isinstance(execution, dict) and execution.get(key) is True:
            return True
    return False


def execute_chain(plan: dict[str, Any], max_steps: int) -> dict[str, Any]:
    if max_steps < 1:
        raise ValueError("--max-steps must be >= 1")

    current = plan
    executed_steps: list[dict[str, Any]] = []
    stop_reason = "max_steps_reached"
    for step in range(1, max_steps + 1):
        executed = execute_plan(current)
        executed_steps.append(executed)

        should_stop, reason = _chain_stop_reason(executed)
        if should_stop:
            stop_reason = reason
            break
        if step >= max_steps:
            stop_reason = "max_steps_reached"
            break

        follow_up = executed["followUpPlan"]
        current = follow_up

    result = dict(executed_steps[-1]) if executed_steps else dict(plan)
    final_execution = result.get("execution") if isinstance(result.get("execution"), dict) else {}
    chain = [
        _chain_record(step=index + 1, executed=executed)
        for index, executed in enumerate(executed_steps)
    ]
    result["chain"] = chain
    result["chainSummary"] = {
        "maxSteps": max_steps,
        "stepsExecuted": len(executed_steps),
        "stopReason": stop_reason,
        "finalVerdict": final_execution.get("verdict"),
        "finalNextAction": final_execution.get("nextAction"),
        "opensMicrophone": _chain_flag(chain, "opensMicrophone"),
        "emitsAudio": _chain_flag(chain, "emitsAudio"),
        "appliesDelay": _chain_flag(chain, "appliesDelay"),
    }
    return result


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plan or run the next passive no-probe autosync step."
    )
    parser.add_argument("--readiness-json", type=Path)
    parser.add_argument("--state-root", type=Path, default=_default_state_root())
    parser.add_argument("--session-root", type=Path)
    parser.add_argument("--candidate-session", type=Path)
    parser.add_argument("--socket", type=Path, default=_default_socket_path())
    parser.add_argument("--app", type=Path, default=Path("/Applications/SyncCast.app"))
    parser.add_argument("--process-name", default="SyncCastMenuBar")
    parser.add_argument("--timeout-sec", type=float, default=2.0)
    parser.add_argument("--wait-sec", type=float, default=0.0)
    parser.add_argument("--interval-sec", type=float, default=2.0)
    parser.add_argument("--samples", type=int, default=6)
    parser.add_argument("--sample-interval-sec", type=float, default=60.0)
    parser.add_argument("--duration-sec", type=float, default=4.0)
    parser.add_argument("--auto-start-targets", default="")
    parser.add_argument("--auto-capture-backend", choices=("", "tap", "sck"), default="")
    parser.add_argument(
        "--auto-launch-mode",
        choices=("", "auto", "open", "exec", "headless"),
        default="",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument(
        "--allow-accepted-delay-apply",
        action="store_true",
        help=(
            "after an app-side dry-run accepts a passive candidate, allow the "
            "guarded accepted-candidate RPC to write the delay and then plan "
            "post-apply validation"
        ),
    )
    parser.add_argument(
        "--max-steps",
        type=int,
        default=1,
        help="with --execute, run at most this many safe follow-up steps",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        state_root = args.state_root.expanduser()
        session_root = (
            args.session_root.expanduser()
            if args.session_root is not None
            else _session_root(state_root)
        )
        readiness = _load_readiness(args)
        plan = build_plan(
            readiness=readiness,
            state_root=state_root,
            session_root=session_root,
            socket=args.socket,
            samples=args.samples,
            interval_sec=args.sample_interval_sec,
            duration_sec=args.duration_sec,
            auto_start_targets=args.auto_start_targets,
            auto_capture_backend=args.auto_capture_backend,
            auto_launch_mode=args.auto_launch_mode,
            candidate_session=args.candidate_session,
            allow_accepted_delay_apply=args.allow_accepted_delay_apply,
        )
        if args.execute:
            plan = execute_chain(plan, args.max_steps)
        if args.output is not None:
            _write_json(args.output, plan)
        print(json.dumps(plan, indent=2, sort_keys=True))
        if args.execute:
            exit_code = (plan.get("execution") or {}).get("exitCode")
            return int(exit_code) if isinstance(exit_code, int) else EXIT_NOT_READY
        return EXIT_OK if plan["verdict"].startswith("ready_to_run") else EXIT_NOT_READY
    except Exception as exc:
        payload = {"schema": SCHEMA, "verdict": "bad_input", "error": str(exc)}
        if args.output is not None:
            _write_json(args.output, payload)
        print(json.dumps(payload, indent=2, sort_keys=True), file=sys.stderr)
        return EXIT_BAD_INPUT


if __name__ == "__main__":
    raise SystemExit(main())
