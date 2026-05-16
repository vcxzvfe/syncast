#!/usr/bin/env python3
"""Summarize app-owned passive autosync runs.

This is a read-only helper for the menubar app's
~/Library/Application Support/SyncCast/PassiveAutosync tree. It never launches
SyncCast, opens the microphone, emits audio, or applies delay.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Any


EXIT_OK = 0
EXIT_BAD_INPUT = 2
EXIT_NO_RUNS = 3
TAIL_LIMIT = 2000
DEFAULT_PARTIAL_STALE_SEC = 900.0
DEFAULT_LAUNCH_LOG_TAIL_BYTES = 120_000
LAUNCH_LOG_MATCH_PATTERNS = (
    re.compile(r"passiveAutosync", re.IGNORECASE),
    re.compile(r"active acoustic diagnostics", re.IGNORECASE),
    re.compile(r"\[ActiveCalib\]"),
    re.compile(r"\bautoCalib\b"),
    re.compile(r"Diagnostic Calibrate", re.IGNORECASE),
    re.compile(r"audible", re.IGNORECASE),
    re.compile(r"probe", re.IGNORECASE),
)
ACTIVE_PROBE_PATTERNS = (
    re.compile(r"\[ActiveCalib\]"),
    re.compile(r"active acoustic diagnostics:\s*enabled", re.IGNORECASE),
    re.compile(r"\bautoCalib\b.*running", re.IGNORECASE),
)


@dataclass(frozen=True)
class RunArtifacts:
    directory: Path
    stem: str
    json_path: Path | None = None
    stdout_path: Path | None = None
    stderr_path: Path | None = None

    @property
    def expected_json_path(self) -> Path:
        return self.directory / f"{self.stem}.json"

    @property
    def latest_mtime(self) -> float:
        return max(
            _mtime(path)
            for path in (self.json_path, self.stdout_path, self.stderr_path)
            if path is not None
        )


def _default_state_root() -> Path:
    return Path.home() / "Library/Application Support/SyncCast/PassiveAutosync"


def _default_launch_log() -> Path:
    return Path.home() / "Library/Logs/SyncCast/launch.log"


def _read_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text())
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected JSON object")
    return payload


def _read_json_optional(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    try:
        return _read_json(path)
    except (OSError, json.JSONDecodeError, ValueError):
        return None


def _string(payload: dict[str, Any] | None, key: str) -> str | None:
    if not isinstance(payload, dict) or key not in payload:
        return None
    value = payload.get(key)
    if value is None:
        return None
    return str(value)


def _bool_any(*values: Any) -> bool:
    return any(value is True for value in values)


def _mtime(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0


def _read_tail(path: Path | None, *, limit: int = TAIL_LIMIT) -> str | None:
    if path is None:
        return None
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - limit))
            return handle.read().decode("utf-8", errors="replace")
    except OSError:
        return None


def _matching_lines(text: str, patterns: tuple[re.Pattern[str], ...]) -> list[str]:
    return [
        line
        for line in text.splitlines()
        if any(pattern.search(line) for pattern in patterns)
    ]


def _scope_to_latest_process(lines: list[str]) -> tuple[list[str], str]:
    for index in range(len(lines) - 1, -1, -1):
        if "=== SyncCast process starting" in lines[index]:
            return (lines[index:], "since_latest_process_start")
    return (lines, "tail")


def summarize_launch_log(
    path: Path,
    *,
    tail_bytes: int = DEFAULT_LAUNCH_LOG_TAIL_BYTES,
    max_lines: int = 40,
) -> dict[str, Any]:
    tail = _read_tail(path, limit=max(1, tail_bytes))
    if tail is None:
        return {
            "path": str(path),
            "exists": path.exists(),
            "readable": False,
            "matchedLineCount": 0,
            "recentLines": [],
            "latestLine": None,
            "activeProbeLineCount": 0,
            "recentActiveProbeLines": [],
        }
    scoped_lines, scope = _scope_to_latest_process(tail.splitlines())
    scoped_text = "\n".join(scoped_lines)
    matches = _matching_lines(scoped_text, LAUNCH_LOG_MATCH_PATTERNS)
    active_matches = _matching_lines(scoped_text, ACTIVE_PROBE_PATTERNS)
    return {
        "path": str(path),
        "exists": path.exists(),
        "readable": True,
        "mtimeUnix": round(_mtime(path), 3),
        "tailBytes": tail_bytes,
        "scope": scope,
        "matchedLineCount": len(matches),
        "recentLines": matches[-max_lines:],
        "latestLine": matches[-1] if matches else None,
        "activeProbeLineCount": len(active_matches),
        "recentActiveProbeLines": active_matches[-max_lines:],
    }


def _run_stem(path: Path) -> str | None:
    if not path.name.startswith("autosync-"):
        return None
    if path.suffix not in {".json", ".stdout", ".stderr"}:
        return None
    return path.stem


def _artifact_age_sec(artifacts: RunArtifacts, now: float) -> float:
    return max(0.0, now - artifacts.latest_mtime)


def _control_report_path(
    payload: dict[str, Any],
    execution: dict[str, Any] | None,
) -> Path | None:
    explicit = _string(execution, "controlReport")
    if explicit:
        return Path(explicit)
    session_root = _string(execution, "sessionRoot") or _string(payload, "sessionRoot")
    if session_root:
        return Path(session_root) / "control_report.json"
    return None


def summarize_run(path: Path) -> dict[str, Any]:
    payload = _read_json(path)
    execution = payload.get("execution")
    if not isinstance(execution, dict):
        execution = None
    chain_summary = payload.get("chainSummary")
    if not isinstance(chain_summary, dict):
        chain_summary = None
    control_path = _control_report_path(payload, execution)
    control_report = _read_json_optional(control_path)
    verdict = (
        _string(execution, "verdict")
        or _string(chain_summary, "finalVerdict")
        or _string(control_report, "verdict")
        or _string(payload, "verdict")
        or "unknown"
    )
    reason = (
        _string(execution, "reason")
        or _string(control_report, "reason")
        or _string(payload, "reason")
        or ""
    )
    next_action = (
        _string(execution, "nextAction")
        or _string(chain_summary, "finalNextAction")
        or _string(control_report, "nextAction")
        or _string(payload, "nextAction")
    )
    session_root = (
        _string(execution, "sessionRoot")
        or _string(control_report, "sessionRoot")
        or _string(payload, "sessionRoot")
    )
    opens_microphone = _bool_any(
        payload.get("opensMicrophone"),
        execution.get("opensMicrophone") if execution else None,
        control_report.get("opensMicrophone") if control_report else None,
        chain_summary.get("opensMicrophone") if chain_summary else None,
    )
    emits_audio = _bool_any(
        payload.get("emitsAudio"),
        execution.get("emitsAudio") if execution else None,
        control_report.get("emitsAudio") if control_report else None,
        chain_summary.get("emitsAudio") if chain_summary else None,
    )
    applies_delay = _bool_any(
        payload.get("appliesDelay"),
        execution.get("appliesDelay") if execution else None,
        control_report.get("appliesDelay") if control_report else None,
        chain_summary.get("appliesDelay") if chain_summary else None,
    )
    accepted_apply_result = (
        execution.get("passiveAcceptedApplyResult")
        if isinstance(execution, dict)
        and isinstance(execution.get("passiveAcceptedApplyResult"), dict)
        else None
    )
    rollback_result = (
        execution.get("passiveRollbackResult")
        if isinstance(execution, dict)
        and isinstance(execution.get("passiveRollbackResult"), dict)
        else None
    )
    return {
        "path": str(path),
        "jsonExists": True,
        "jsonReadable": True,
        "mtimeUnix": round(_mtime(path), 3),
        "verdict": verdict,
        "reason": reason,
        "nextAction": next_action,
        "sessionRoot": session_root,
        "controlReport": str(control_path) if control_path else None,
        "controlReportExists": control_report is not None,
        "controlReportVerdict": _string(control_report, "verdict"),
        "phase": _string(execution, "phase") or _string(control_report, "phase"),
        "blockingStage": (
            _string(execution, "blockingStage")
            or _string(control_report, "blockingStage")
        ),
        "readinessStage": (
            _string(execution, "readinessStage")
            or _string(control_report, "readinessStage")
            or _string(payload, "readinessStage")
        ),
        "readinessWorkflow": (
            _string(execution, "readinessRecommendedWorkflow")
            or _string(control_report, "readinessRecommendedWorkflow")
            or _string(payload, "recommendedWorkflow")
        ),
        "chainStopReason": _string(chain_summary, "stopReason"),
        "chainStepsExecuted": chain_summary.get("stepsExecuted")
        if isinstance(chain_summary, dict)
        else None,
        "passiveAcceptedApply": _string(execution, "passiveAcceptedApply"),
        "passiveAcceptedApplyVerdict": _string(
            execution,
            "passiveAcceptedApplyVerdict",
        ),
        "passiveAcceptedAppliedDelayMs": (
            accepted_apply_result.get("appliedDelayMs")
            if accepted_apply_result is not None
            else None
        ),
        "passiveRollback": _string(execution, "passiveRollback"),
        "passiveRollbackVerdict": _string(execution, "passiveRollbackVerdict"),
        "passiveRollbackAppliedDelayMs": (
            rollback_result.get("appliedDelayMs")
            if rollback_result is not None
            else None
        ),
        "passiveRollbackPreviousDelayMs": (
            rollback_result.get("previousDelayMs")
            if rollback_result is not None
            else None
        ),
        "opensMicrophone": opens_microphone,
        "emitsAudio": emits_audio,
        "appliesDelay": applies_delay,
        "safetyIssue": (
            _string(execution, "safetyIssue")
            or _string(control_report, "safetyIssue")
        ),
    }


def summarize_partial_run(
    artifacts: RunArtifacts,
    *,
    now: float | None = None,
    partial_stale_sec: float = DEFAULT_PARTIAL_STALE_SEC,
) -> dict[str, Any]:
    now = time.time() if now is None else now
    age_sec = _artifact_age_sec(artifacts, now)
    stale = age_sec >= partial_stale_sec
    stdout_tail = _read_tail(artifacts.stdout_path)
    stderr_tail = _read_tail(artifacts.stderr_path)
    if stale:
        verdict = "missing_json"
        reason = "controller did not write a readable JSON report"
        next_action = (
            "inspect stdout/stderr and launch log, then rerun Passive Check "
            "after fixing the controller startup failure"
        )
        phase = "controller_launch"
        blocking_stage = "controller_report"
        diagnostic_issue = "missing_json_report"
    else:
        verdict = "report_pending"
        reason = "controller JSON report is not present yet; run may still be in progress"
        next_action = (
            "wait for the controller to finish; inspect stdout/stderr if this "
            "remains pending past the stale threshold"
        )
        phase = "controller_running_or_startup"
        blocking_stage = "controller_report_pending"
        diagnostic_issue = "json_report_pending"
    return {
        "path": str(artifacts.expected_json_path),
        "jsonExists": False,
        "jsonReadable": False,
        "mtimeUnix": round(artifacts.latest_mtime, 3),
        "artifactAgeSec": round(age_sec, 3),
        "partialStaleAfterSec": partial_stale_sec,
        "partialStale": stale,
        "verdict": verdict,
        "reason": reason,
        "nextAction": next_action,
        "sessionRoot": None,
        "controlReport": None,
        "controlReportExists": False,
        "controlReportVerdict": None,
        "phase": phase,
        "blockingStage": blocking_stage,
        "readinessStage": None,
        "readinessWorkflow": None,
        "chainStopReason": None,
        "chainStepsExecuted": None,
        "opensMicrophone": None,
        "emitsAudio": None,
        "appliesDelay": None,
        "safetyIssue": None,
        "diagnosticIssue": diagnostic_issue,
        "stdout": str(artifacts.stdout_path) if artifacts.stdout_path else None,
        "stdoutExists": artifacts.stdout_path is not None,
        "stdoutTail": stdout_tail,
        "stderr": str(artifacts.stderr_path) if artifacts.stderr_path else None,
        "stderrExists": artifacts.stderr_path is not None,
        "stderrTail": stderr_tail,
    }


def summarize_unreadable_run(
    artifacts: RunArtifacts,
    error: Exception,
    *,
    now: float | None = None,
    partial_stale_sec: float = DEFAULT_PARTIAL_STALE_SEC,
) -> dict[str, Any]:
    now = time.time() if now is None else now
    age_sec = _artifact_age_sec(artifacts, now)
    stale = age_sec >= partial_stale_sec
    if stale:
        verdict = "unreadable_json"
        reason = f"controller JSON report is not readable: {error}"
        next_action = (
            "inspect stdout/stderr and launch log, then rerun Passive Check "
            "after fixing the controller report failure"
        )
        blocking_stage = "controller_report"
        diagnostic_issue = "unreadable_json_report"
    else:
        verdict = "report_pending"
        reason = "controller JSON report is not readable yet; it may still be writing"
        next_action = (
            "wait for the controller to finish; inspect stdout/stderr if this "
            "remains pending past the stale threshold"
        )
        blocking_stage = "controller_report_pending"
        diagnostic_issue = "json_report_pending"
    return {
        "path": str(artifacts.json_path or artifacts.expected_json_path),
        "jsonExists": artifacts.json_path is not None,
        "jsonReadable": False,
        "mtimeUnix": round(artifacts.latest_mtime, 3),
        "artifactAgeSec": round(age_sec, 3),
        "partialStaleAfterSec": partial_stale_sec,
        "partialStale": stale,
        "verdict": verdict,
        "reason": reason,
        "nextAction": next_action,
        "sessionRoot": None,
        "controlReport": None,
        "controlReportExists": False,
        "controlReportVerdict": None,
        "phase": "controller_report",
        "blockingStage": blocking_stage,
        "readinessStage": None,
        "readinessWorkflow": None,
        "chainStopReason": None,
        "chainStepsExecuted": None,
        "opensMicrophone": None,
        "emitsAudio": None,
        "appliesDelay": None,
        "safetyIssue": None,
        "diagnosticIssue": diagnostic_issue,
        "stdout": str(artifacts.stdout_path) if artifacts.stdout_path else None,
        "stdoutExists": artifacts.stdout_path is not None,
        "stdoutTail": _read_tail(artifacts.stdout_path),
        "stderr": str(artifacts.stderr_path) if artifacts.stderr_path else None,
        "stderrExists": artifacts.stderr_path is not None,
        "stderrTail": _read_tail(artifacts.stderr_path),
    }


def summarize_artifacts(
    artifacts: RunArtifacts,
    *,
    now: float | None = None,
    partial_stale_sec: float = DEFAULT_PARTIAL_STALE_SEC,
) -> dict[str, Any]:
    if artifacts.json_path is None:
        return summarize_partial_run(
            artifacts,
            now=now,
            partial_stale_sec=partial_stale_sec,
        )
    try:
        summary = summarize_run(artifacts.json_path)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        return summarize_unreadable_run(
            artifacts,
            exc,
            now=now,
            partial_stale_sec=partial_stale_sec,
        )
    summary.update(
        {
            "stdout": str(artifacts.stdout_path) if artifacts.stdout_path else None,
            "stdoutExists": artifacts.stdout_path is not None,
            "stdoutTail": _read_tail(artifacts.stdout_path),
            "stderr": str(artifacts.stderr_path) if artifacts.stderr_path else None,
            "stderrExists": artifacts.stderr_path is not None,
            "stderrTail": _read_tail(artifacts.stderr_path),
        }
    )
    return summary


def find_runs(state_root: Path) -> list[Path]:
    candidates: list[Path] = []
    runs = state_root / "runs"
    if runs.exists():
        candidates.extend(runs.glob("autosync-*.json"))
    candidates.extend(state_root.glob("autosync-*.json"))
    unique = {str(path): path for path in candidates if path.is_file()}
    return sorted(unique.values(), key=_mtime, reverse=True)


def find_run_artifacts(state_root: Path) -> list[RunArtifacts]:
    grouped: dict[tuple[str, str], dict[str, Path]] = {}
    for root in (state_root / "runs", state_root):
        if not root.exists():
            continue
        for path in root.glob("autosync-*"):
            if not path.is_file():
                continue
            stem = _run_stem(path)
            if stem is None:
                continue
            key = (str(path.parent), stem)
            grouped.setdefault(key, {})[path.suffix] = path

    artifacts = [
        RunArtifacts(
            directory=Path(directory),
            stem=stem,
            json_path=bucket.get(".json"),
            stdout_path=bucket.get(".stdout"),
            stderr_path=bucket.get(".stderr"),
        )
        for (directory, stem), bucket in grouped.items()
    ]
    return sorted(artifacts, key=lambda item: item.latest_mtime, reverse=True)


def build_status(
    state_root: Path,
    *,
    limit: int,
    now: float | None = None,
    partial_stale_sec: float = DEFAULT_PARTIAL_STALE_SEC,
    include_launch_log: bool = False,
    launch_log: Path | None = None,
    launch_log_tail_bytes: int = DEFAULT_LAUNCH_LOG_TAIL_BYTES,
) -> dict[str, Any]:
    now = time.time() if now is None else now
    runs = find_run_artifacts(state_root)
    summaries = [
        summarize_artifacts(
            artifacts,
            now=now,
            partial_stale_sec=partial_stale_sec,
        )
        for artifacts in runs[:limit]
    ]
    latest = summaries[0] if summaries else None
    safety_issues = [
        run
        for run in summaries
        if run.get("emitsAudio") is True or run.get("safetyIssue")
    ]
    delay_writes = [run for run in summaries if run.get("appliesDelay") is True]
    microphone_runs = [run for run in summaries if run.get("opensMicrophone") is True]
    partial_runs = [run for run in summaries if run.get("jsonReadable") is False]
    stale_partial_runs = [
        run
        for run in partial_runs
        if run.get("partialStale") is True
    ]
    status = {
        "schema": "syncast.passive_autosync_status.v1",
        "stateRoot": str(state_root),
        "exists": state_root.exists(),
        "runsTotal": len(runs),
        "runsReported": len(summaries),
        "latest": latest,
        "runs": summaries,
        "partialRunCount": len(partial_runs),
        "stalePartialRunCount": len(stale_partial_runs),
        "microphoneRunCount": len(microphone_runs),
        "delayWriteCount": len(delay_writes),
        "safetyIssueCount": len(safety_issues),
        "latestVerdict": latest.get("verdict") if latest else None,
        "latestBlockingStage": latest.get("blockingStage") if latest else None,
        "latestNextAction": latest.get("nextAction") if latest else None,
    }
    if include_launch_log:
        status["launchLog"] = summarize_launch_log(
            launch_log or _default_launch_log(),
            tail_bytes=launch_log_tail_bytes,
        )
    return status


def _format_text(status: dict[str, Any]) -> str:
    lines = [
        "Passive autosync status",
        f"  state root : {status['stateRoot']}",
        f"  exists     : {status['exists']}",
        f"  runs       : {status['runsTotal']} total, {status['runsReported']} shown",
    ]
    latest = status.get("latest")
    if not isinstance(latest, dict):
        lines.append("  latest     : none")
        return "\n".join(lines)
    lines.extend(
        [
            f"  latest     : {latest.get('verdict')}",
            f"  reason     : {latest.get('reason') or ''}",
            f"  stage      : {latest.get('blockingStage') or latest.get('phase') or latest.get('readinessStage') or ''}",
            f"  workflow   : {latest.get('readinessWorkflow') or ''}",
            f"  mic/audio/delay: {latest.get('opensMicrophone')}/{latest.get('emitsAudio')}/{latest.get('appliesDelay')}",
        ]
    )
    if latest.get("nextAction"):
        lines.append(f"  next       : {latest['nextAction']}")
    if latest.get("passiveAcceptedApplyVerdict"):
        lines.append(
            "  accepted   : "
            f"{latest['passiveAcceptedApplyVerdict']} "
            f"applied={latest.get('passiveAcceptedAppliedDelayMs')}"
        )
    if latest.get("passiveRollbackVerdict"):
        lines.append(
            "  rollback   : "
            f"{latest['passiveRollbackVerdict']} "
            f"{latest.get('passiveRollbackPreviousDelayMs')}->"
            f"{latest.get('passiveRollbackAppliedDelayMs')}"
        )
    if latest.get("controlReport"):
        exists = "yes" if latest.get("controlReportExists") else "no"
        lines.append(f"  report     : {latest['controlReport']} ({exists})")
    if status.get("safetyIssueCount"):
        lines.append(f"  safety     : {status['safetyIssueCount']} issue(s), inspect JSON")
    if status.get("delayWriteCount"):
        lines.append(f"  delay writes: {status['delayWriteCount']} run(s)")
    if status.get("partialRunCount"):
        stale = status.get("stalePartialRunCount") or 0
        lines.append(
            f"  partial    : {status['partialRunCount']} incomplete JSON report(s), "
            f"{stale} stale"
        )
    launch_log = status.get("launchLog")
    if isinstance(launch_log, dict):
        lines.append(
            "  launch.log : "
            f"{launch_log.get('matchedLineCount', 0)} matched line(s), "
            f"{launch_log.get('activeProbeLineCount', 0)} active-probe line(s)"
        )
        if launch_log.get("latestLine"):
            lines.append(f"  log latest : {launch_log['latestLine']}")
    if latest.get("stderr") and not latest.get("jsonExists"):
        lines.append(f"  stderr     : {latest['stderr']}")
    return "\n".join(lines)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize app-owned passive autosync runs without side effects."
    )
    parser.add_argument("--state-root", type=Path, default=_default_state_root())
    parser.add_argument("--limit", type=int, default=5)
    parser.add_argument(
        "--partial-stale-sec",
        type=float,
        default=DEFAULT_PARTIAL_STALE_SEC,
        help=(
            "Treat stdout/stderr-only or unreadable-JSON runs as stale after "
            "this many seconds."
        ),
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--include-launch-log",
        action="store_true",
        help="Include recent SyncCast launch.log passive/active diagnostic lines.",
    )
    parser.add_argument("--launch-log", type=Path, default=_default_launch_log())
    parser.add_argument(
        "--launch-log-tail-bytes",
        type=int,
        default=DEFAULT_LAUNCH_LOG_TAIL_BYTES,
    )
    parser.add_argument(
        "--verdict-exit",
        action="store_true",
        help="Exit 3 when no autosync runs are present.",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        if args.limit < 1:
            raise ValueError("--limit must be >= 1")
        if args.partial_stale_sec < 0:
            raise ValueError("--partial-stale-sec must be >= 0")
        if args.launch_log_tail_bytes < 1:
            raise ValueError("--launch-log-tail-bytes must be >= 1")
        status = build_status(
            args.state_root,
            limit=args.limit,
            partial_stale_sec=args.partial_stale_sec,
            include_launch_log=args.include_launch_log,
            launch_log=args.launch_log,
            launch_log_tail_bytes=args.launch_log_tail_bytes,
        )
        if args.json:
            print(json.dumps(status, indent=2, sort_keys=True))
        else:
            print(_format_text(status))
        if args.verdict_exit and status["runsTotal"] == 0:
            return EXIT_NO_RUNS
        return EXIT_OK
    except Exception as exc:
        print(json.dumps({"verdict": "bad_input", "error": str(exc)}, indent=2), file=sys.stderr)
        return EXIT_BAD_INPUT


if __name__ == "__main__":
    raise SystemExit(main())
