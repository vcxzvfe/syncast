#!/usr/bin/env python3
"""Audit a passive drift session output directory.

This is the last offline gate before treating a live passive corpus as useful
evidence. It checks that the session artifacts are present and internally
consistent, then classifies the result into one actionable state:
baseline-ready, correction-ready, hold, not-applicable, capture-failed, or
incomplete.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import passive_drift_summary as pds


EXIT_OK = 0
EXIT_BAD_INPUT = 2
EXIT_NOT_READY = 3
EXIT_CAPTURE_FAILED = 4


SESSION_FILES = {
    "manifest": "manifest.json",
    "auto_start_setup": "auto_start_setup.json",
    "headless_status": "headless_status.json",
    "auto_start_capture_preflight": "auto_start_capture_preflight.json",
    "auto_start_preflight": "auto_start_preflight.json",
    "capture_preflight": "capture_preflight.json",
    "preflight": "preflight.json",
    "monitor": "monitor.json",
    "samples": "samples.jsonl",
    "summary": "summary.json",
    "decision": "decision.json",
}

MIC_TIMING_FIELDS = (
    "sampleRate",
    "microphoneArmedAtNs",
    "microphoneFirstSampleAtNs",
    "microphoneStartPaddingFrames",
    "microphoneWarmupFramesDropped",
    "airplayTimingEpoch",
    "endAirplayTimingEpoch",
)


def _read_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected JSON object")
    return payload


def _try_read_json(path: Path, issues: list[str]) -> dict[str, Any] | None:
    if not path.exists():
        issues.append(f"missing {path.name}")
        return None
    try:
        return _read_json(path)
    except ValueError as exc:
        issues.append(str(exc))
        return None


def _summary_verdict(payload: dict[str, Any] | None) -> str | None:
    if not payload:
        return None
    summary = payload.get("summary")
    if isinstance(summary, dict):
        verdict = summary.get("verdict")
        if isinstance(verdict, str):
            return verdict
    verdict = payload.get("verdict")
    return verdict if isinstance(verdict, str) else None


def _summary_reason(payload: dict[str, Any] | None) -> str | None:
    if not payload:
        return None
    summary = payload.get("summary")
    if isinstance(summary, dict):
        reason = summary.get("reason")
        if isinstance(reason, str):
            return reason
    reason = payload.get("reason")
    if isinstance(reason, str):
        return reason
    error = payload.get("error")
    return error if isinstance(error, str) else None


def _unexpected_preflight_reason(
    label: str,
    payload: dict[str, Any] | None,
) -> str | None:
    verdict = _summary_verdict(payload)
    if verdict in (None, "preflight_ok", "capture_failed"):
        return None
    reason = _summary_reason(payload)
    suffix = f": {reason}" if reason else ""
    return f"unexpected {label} verdict: {verdict}{suffix}"


def _preflight_blocks_downstream(
    *,
    payload: dict[str, Any] | None,
    required: bool,
) -> bool:
    verdict = _summary_verdict(payload)
    return (
        verdict == "capture_failed"
        or (required and payload is None)
        or verdict not in (None, "preflight_ok")
    )


def _jsonl_rows(path: Path, issues: list[str]) -> list[dict[str, Any]] | None:
    if not path.exists():
        issues.append(f"missing {path.name}")
        return None
    try:
        return pds._load_jsonl_rows(path.read_text())
    except ValueError as exc:
        issues.append(f"{path.name}: {exc}")
        return None


def _row_count(payload: dict[str, Any] | None) -> int | None:
    rows = None if not payload else payload.get("rows")
    return len(rows) if isinstance(rows, list) else None


def _is_int_metadata(value: Any) -> bool:
    return type(value) is int


def _is_number_metadata(value: Any) -> bool:
    return not isinstance(value, bool) and isinstance(value, (int, float))


def _capture_timing_failure(
    capture: dict[str, Any],
    *,
    sample_index: Any,
    cycle_index: Any,
) -> dict[str, Any] | None:
    def gate(field: str, value: Any, reason: str) -> dict[str, Any]:
        return {
            "reason": reason,
            "timing_gate": {
                "field": field,
                "value": value,
                "sample_index": sample_index,
                "cycle_index": cycle_index,
                "required_fields": list(MIC_TIMING_FIELDS),
            },
        }

    sample_rate = capture.get("sampleRate")
    if not _is_number_metadata(sample_rate) or float(sample_rate) <= 0.0:
        return gate(
            "sampleRate",
            sample_rate,
            "accepted passive sample is missing microphone timing sampleRate",
        )
    armed_at = capture.get("microphoneArmedAtNs")
    if not _is_int_metadata(armed_at) or armed_at <= 0:
        return gate(
            "microphoneArmedAtNs",
            armed_at,
            "accepted passive sample is missing microphone arm timestamp",
        )
    first_sample_at = capture.get("microphoneFirstSampleAtNs")
    if not _is_int_metadata(first_sample_at) or first_sample_at <= 0:
        return gate(
            "microphoneFirstSampleAtNs",
            first_sample_at,
            "accepted passive sample is missing microphone first-sample timestamp",
        )
    if first_sample_at < armed_at:
        return gate(
            "microphoneFirstSampleAtNs",
            first_sample_at,
            "accepted passive sample microphone first sample predates arm point",
        )
    padding_frames = capture.get("microphoneStartPaddingFrames")
    if not _is_int_metadata(padding_frames) or padding_frames < 0:
        return gate(
            "microphoneStartPaddingFrames",
            padding_frames,
            "accepted passive sample is missing microphone start padding",
        )
    warmup_frames = capture.get("microphoneWarmupFramesDropped")
    if not _is_int_metadata(warmup_frames) or warmup_frames < 0:
        return gate(
            "microphoneWarmupFramesDropped",
            warmup_frames,
            "accepted passive sample is missing microphone warmup drop count",
        )

    expected_padding = int(round((first_sample_at - armed_at) * float(sample_rate) / 1e9))
    if abs(expected_padding - padding_frames) > 2:
        return gate(
            "microphoneStartPaddingFrames",
            padding_frames,
            (
                "accepted passive sample microphone start padding is inconsistent "
                f"with arm/first-sample timing: {padding_frames} frames vs "
                f"expected {expected_padding}"
            ),
        )
    microphone_frames = capture.get("microphoneFrames")
    if (
        _is_int_metadata(microphone_frames)
        and padding_frames > microphone_frames
    ):
        return gate(
            "microphoneStartPaddingFrames",
            padding_frames,
            "accepted passive sample microphone start padding exceeds microphone WAV frames",
        )
    airplay_epoch = capture.get("airplayTimingEpoch")
    if not _is_int_metadata(airplay_epoch) or airplay_epoch < 0:
        return gate(
            "airplayTimingEpoch",
            airplay_epoch,
            "accepted passive sample is missing AirPlay timing epoch",
        )
    end_airplay_epoch = capture.get("endAirplayTimingEpoch")
    if not _is_int_metadata(end_airplay_epoch) or end_airplay_epoch < 0:
        return gate(
            "endAirplayTimingEpoch",
            end_airplay_epoch,
            "accepted passive sample is missing end AirPlay timing epoch",
        )
    if airplay_epoch != end_airplay_epoch:
        return gate(
            "endAirplayTimingEpoch",
            end_airplay_epoch,
            (
                "accepted passive sample AirPlay timing epoch changed during capture: "
                f"{airplay_epoch} -> {end_airplay_epoch}"
            ),
        )
    return None


def _monitor_timing_failure(
    monitor: dict[str, Any] | None,
) -> dict[str, Any] | None:
    rows = None if monitor is None else monitor.get("rows")
    if not isinstance(rows, list):
        return {
            "reason": "monitor rows are missing microphone timing evidence",
            "timing_gate": {"field": "rows"},
        }
    for row in rows:
        if row.get("verdict") != "accepted":
            continue
        sample_index = row.get("index")
        sample = row.get("sample")
        if not isinstance(sample, dict):
            return {
                "reason": "accepted passive sample is missing sample payload",
                "timing_gate": {
                    "field": "sample",
                    "sample_index": sample_index,
                },
            }
        cycles = sample.get("cycles")
        if not isinstance(cycles, list) or not cycles:
            return {
                "reason": "accepted passive sample is missing cycle timing evidence",
                "timing_gate": {
                    "field": "cycles",
                    "sample_index": sample_index,
                },
            }
        for cycle in cycles:
            cycle_index = cycle.get("index") if isinstance(cycle, dict) else None
            if not isinstance(cycle, dict):
                return {
                    "reason": "accepted passive sample contains invalid cycle payload",
                    "timing_gate": {
                        "field": "cycle",
                        "sample_index": sample_index,
                        "cycle_index": cycle_index,
                    },
                }
            capture = cycle.get("capture")
            if not isinstance(capture, dict):
                return {
                    "reason": "accepted passive sample cycle is missing capture timing metadata",
                    "timing_gate": {
                        "field": "capture",
                        "sample_index": sample_index,
                        "cycle_index": cycle_index,
                    },
                }
            failure = _capture_timing_failure(
                capture,
                sample_index=sample_index,
                cycle_index=cycle_index,
            )
            if failure is not None:
                return failure
    return None


def _rows_match_jsonl(
    jsonl_rows: list[dict[str, Any]] | None,
    monitor: dict[str, Any] | None,
    issues: list[str],
) -> bool:
    monitor_rows = None if not monitor else monitor.get("rows")
    if jsonl_rows is None or not isinstance(monitor_rows, list):
        return False
    if len(jsonl_rows) != len(monitor_rows):
        issues.append(
            f"samples.jsonl row count {len(jsonl_rows)} != monitor rows {len(monitor_rows)}"
        )
        return False
    for index, (jsonl_row, monitor_row) in enumerate(
        zip(jsonl_rows, monitor_rows),
        start=1,
    ):
        left = json.dumps(jsonl_row, sort_keys=True, separators=(",", ":"))
        right = json.dumps(monitor_row, sort_keys=True, separators=(",", ":"))
        if left != right:
            issues.append(
                f"samples.jsonl row {index} does not match monitor.json rows[{index - 1}]"
            )
            return False
    return True


def _decision_verdict(payload: dict[str, Any] | None) -> str | None:
    verdict = None if not payload else payload.get("verdict")
    return verdict if isinstance(verdict, str) else None


def _decision_reason(payload: dict[str, Any] | None) -> str | None:
    if not payload:
        return None
    reason = payload.get("reason") or payload.get("error")
    return reason if isinstance(reason, str) else None


def _manifest_requires_capture_preflight(manifest: dict[str, Any] | None) -> bool:
    if not isinstance(manifest, dict):
        return False
    artifacts = manifest.get("artifacts")
    if isinstance(artifacts, dict) and artifacts.get("capturePreflight"):
        return True
    workflow = manifest.get("workflow")
    return isinstance(workflow, list) and "capture_preflight" in workflow


def _manifest_auto_start_requested(manifest: dict[str, Any] | None) -> bool:
    if not isinstance(manifest, dict):
        return False
    targets = manifest.get("autoStartTargets")
    if isinstance(targets, str):
        return bool(targets.strip())
    return targets is not None


def _manifest_requires_auto_start_capture_preflight(
    manifest: dict[str, Any] | None,
) -> bool:
    if not _manifest_auto_start_requested(manifest):
        return False
    artifacts = manifest.get("artifacts") if isinstance(manifest, dict) else None
    if isinstance(artifacts, dict) and artifacts.get("autoStartCapturePreflight"):
        return True
    workflow = manifest.get("workflow") if isinstance(manifest, dict) else None
    return (
        isinstance(workflow, list)
        and "auto_start_capture_preflight_if_requested" in workflow
    )


def _manifest_requires_auto_start_setup(
    manifest: dict[str, Any] | None,
) -> bool:
    if not _manifest_auto_start_requested(manifest):
        return False
    artifacts = manifest.get("artifacts") if isinstance(manifest, dict) else None
    if isinstance(artifacts, dict) and artifacts.get("autoStartSetup"):
        return True
    workflow = manifest.get("workflow") if isinstance(manifest, dict) else None
    return isinstance(workflow, list) and "auto_start_setup_if_requested" in workflow


def _manifest_failure(
    manifest: dict[str, Any] | None,
    issues: list[str],
) -> tuple[str, str, str] | None:
    if manifest is None:
        return ("incomplete", "manifest", "manifest JSON is missing")
    if manifest.get("schema") != "syncast.passive_drift_session.v1":
        issues.append(f"unexpected manifest schema: {manifest.get('schema')!r}")
        return ("incomplete", "manifest", "manifest schema is not recognized")
    checks = [
        ("emitsAudio", False, "session manifest does not guarantee no audio emission"),
        ("appliesDelay", False, "session manifest does not guarantee no delay writes"),
        (
            "opensMicrophoneOnlyAfterPreflight",
            True,
            "session manifest does not guarantee mic-after-preflight ordering",
        ),
    ]
    for key, expected, reason in checks:
        if manifest.get(key) is not expected:
            issues.append(f"manifest {key}={manifest.get(key)!r}, expected {expected!r}")
            return ("not_applicable", "manifest", reason)
    auto_start_requested = _manifest_auto_start_requested(manifest)
    if auto_start_requested:
        if not (
            manifest.get("launchesApp") is True
            or manifest.get("launchesHeadlessRuntime") is True
        ):
            issues.append(
                "manifest launchesApp/launchesHeadlessRuntime do not declare "
                "an auto-start runtime"
            )
            return (
                "not_applicable",
                "manifest",
                "auto-start manifest does not declare a runtime launch side effect",
            )
        side_effect_checks = [
            (
                "changesRoutes",
                True,
                "auto-start manifest does not declare route mutation side effects",
            ),
            (
                "mayChangeDefaultOutput",
                True,
                "auto-start manifest does not declare default-output side effects",
            ),
            (
                "autoStartSideEffectsUpdated",
                True,
                "auto-start manifest side-effect evidence was not refreshed after setup",
            ),
        ]
        for key, expected, reason in side_effect_checks:
            if manifest.get(key) is not expected:
                issues.append(
                    f"manifest {key}={manifest.get(key)!r}, expected {expected!r}"
                )
                return ("not_applicable", "manifest", reason)
        if type(manifest.get("changesLaunchEnvironment")) is not bool:
            issues.append(
                "manifest changesLaunchEnvironment="
                f"{manifest.get('changesLaunchEnvironment')!r}, expected bool"
            )
            return (
                "not_applicable",
                "manifest",
                "auto-start manifest does not record whether launch environment changed",
            )
        if type(manifest.get("changesDefaultOutput")) is not bool:
            issues.append(
                "manifest changesDefaultOutput="
                f"{manifest.get('changesDefaultOutput')!r}, expected bool"
            )
            return (
                "not_applicable",
                "manifest",
                "auto-start manifest does not record whether default output changed",
            )
        default_output_report = manifest.get("defaultOutputReport")
        if manifest.get("changesDefaultOutput") is True and not (
            isinstance(default_output_report, str) and default_output_report.strip()
        ):
            issues.append("manifest defaultOutputReport is missing for default-output change")
            return (
                "not_applicable",
                "manifest",
                "auto-start manifest does not record default-output before/after evidence",
            )
    else:
        for key in (
            "launchesApp",
            "launchesHeadlessRuntime",
            "changesRoutes",
            "changesLaunchEnvironment",
            "mayChangeDefaultOutput",
            "changesDefaultOutput",
        ):
            if manifest.get(key) is True:
                issues.append(f"manifest {key}=True without autoStartTargets")
                return (
                    "not_applicable",
                    "manifest",
                    "session manifest declares side effects without auto-start targets",
                )
    return None


def _classify(
    *,
    manifest: dict[str, Any] | None,
    auto_start_setup: dict[str, Any] | None,
    auto_start_capture_preflight: dict[str, Any] | None,
    auto_start_preflight: dict[str, Any] | None,
    capture_preflight: dict[str, Any] | None,
    preflight: dict[str, Any] | None,
    monitor: dict[str, Any] | None,
    summary: dict[str, Any] | None,
    decision: dict[str, Any] | None,
    issues: list[str],
) -> tuple[str, str, str]:
    manifest_problem = _manifest_failure(manifest, issues)
    if manifest_problem is not None:
        return manifest_problem

    auto_start_setup_verdict = _summary_verdict(auto_start_setup)
    auto_start_capture_preflight_verdict = _summary_verdict(
        auto_start_capture_preflight
    )
    auto_start_preflight_verdict = _summary_verdict(auto_start_preflight)
    if _manifest_auto_start_requested(manifest):
        if _manifest_requires_auto_start_setup(manifest) and auto_start_setup is None:
            return (
                "incomplete",
                "auto_start_setup",
                "auto-start setup JSON is missing or invalid",
            )
        if auto_start_setup_verdict == "capture_failed":
            return (
                "capture_failed",
                "auto_start_setup",
                _summary_reason(auto_start_setup)
                or "auto-start setup failed before app launch or mic access",
            )
        if reason := _unexpected_preflight_reason(
            "auto-start setup",
            auto_start_setup,
        ):
            return (
                "not_applicable",
                "auto_start_setup",
                reason,
            )
        if (
            _manifest_requires_auto_start_capture_preflight(manifest)
            and auto_start_capture_preflight is None
        ):
            return (
                "incomplete",
                "auto_start_capture_preflight",
                "auto-start capture preflight JSON is missing or invalid",
            )
        if auto_start_capture_preflight_verdict == "capture_failed":
            return (
                "capture_failed",
                "auto_start_capture_preflight",
                _summary_reason(auto_start_capture_preflight)
                or "auto-start capture preflight failed before mic access",
            )
        if reason := _unexpected_preflight_reason(
            "auto-start capture preflight",
            auto_start_capture_preflight,
        ):
            return (
                "not_applicable",
                "auto_start_capture_preflight",
                reason,
            )
        if auto_start_preflight is None:
            return (
                "incomplete",
                "auto_start_preflight",
                "auto-start preflight JSON is missing or invalid",
            )
        if auto_start_preflight_verdict == "capture_failed":
            return (
                "capture_failed",
                "auto_start_preflight",
                _summary_reason(auto_start_preflight)
                or "auto-start preflight failed before mic access",
            )
        if reason := _unexpected_preflight_reason(
            "auto-start preflight",
            auto_start_preflight,
        ):
            return (
                "not_applicable",
                "auto_start_preflight",
                reason,
            )

    capture_preflight_verdict = _summary_verdict(capture_preflight)
    if _manifest_requires_capture_preflight(manifest) and capture_preflight is None:
        return (
            "incomplete",
            "capture_preflight",
            "capture preflight JSON is missing or invalid",
        )
    if capture_preflight_verdict == "capture_failed":
        return (
            "capture_failed",
            "capture_preflight",
            _summary_reason(capture_preflight)
            or "capture preflight failed before mic access",
        )
    if reason := _unexpected_preflight_reason(
        "capture preflight",
        capture_preflight,
    ):
        return (
            "not_applicable",
            "capture_preflight",
            reason,
        )

    preflight_verdict = _summary_verdict(preflight)
    if preflight is None:
        return (
            "incomplete",
            "preflight",
            "preflight JSON is missing or invalid",
        )
    if preflight_verdict == "capture_failed":
        return (
            "capture_failed",
            "preflight",
            _summary_reason(preflight) or "preflight failed before mic access",
        )
    if reason := _unexpected_preflight_reason("preflight", preflight):
        return (
            "not_applicable",
            "preflight",
            reason,
        )

    monitor_verdict = _summary_verdict(monitor)
    if monitor is None:
        return ("incomplete", "monitor", "monitor report is missing")
    if monitor_verdict == "capture_failed":
        return (
            "capture_failed",
            "monitor",
            _summary_reason(monitor) or "passive monitor capture failed",
        )
    if monitor_verdict != "stable":
        return (
            "not_applicable",
            "monitor",
            _summary_reason(monitor) or f"monitor verdict is {monitor_verdict}",
        )

    if summary is None:
        return ("incomplete", "summary", "summary JSON is missing")
    summary_verdict = summary.get("monitor_verdict")
    if summary_verdict != "stable":
        return (
            "not_applicable",
            "summary",
            f"summary monitor_verdict mismatch: {summary_verdict!r}",
        )
    decision_basis = None
    verdict = None
    if isinstance(decision, dict):
        decision_basis = decision.get("decision_basis")
        verdict = _decision_verdict(decision)
    coherent_path_pair = decision_basis == "coherent_path_pair_relative" or (
        verdict == "initialize_baseline"
        and decision_basis in {
            "coherent_path_pair_aligned_baseline",
            "coherent_path_pair_unverified_baseline",
        }
    )
    if summary.get("strong_peak_flag_count") and not coherent_path_pair:
        return (
            "not_applicable",
            "summary",
            "strong multi-peak evidence present",
        )
    if summary.get("multi_path_candidate_flag_count") and not coherent_path_pair:
        return (
            "not_applicable",
            "summary",
            "multi-path candidate evidence present",
        )

    if decision is None:
        return ("incomplete", "decision", "decision JSON is missing")
    if verdict == "initialize_baseline":
        return (
            "ready_for_baseline",
            "decision",
            "stable passive evidence can initialize a relative baseline",
        )
    if verdict == "hold":
        return ("hold", "decision", _decision_reason(decision) or "inside deadband")
    if verdict == "recommend":
        if decision_basis in {
            "coherent_path_pair_absolute",
            "coherent_path_pair_aligned_baseline",
            "coherent_path_pair_unverified_baseline",
            "coherent_path_pair_missing_baseline",
        }:
            return (
                "not_applicable",
                "decision",
                "path-pair correction is not backed by a stored relative baseline",
            )
        if decision.get("auto_apply_eligible") is True:
            return (
                "ready_for_correction",
                "decision",
                _decision_reason(decision) or "bounded correction recommended",
            )
        return (
            "not_applicable",
            "decision",
            _decision_reason(decision) or "recommendation is not auto-apply eligible",
        )
    if verdict == "reject":
        return (
            "not_applicable",
            "decision",
            _decision_reason(decision) or "decision layer rejected evidence",
        )
    return ("incomplete", "decision", f"unknown decision verdict: {verdict!r}")


def audit_session(root: Path) -> dict[str, Any]:
    issues: list[str] = []
    paths = {key: root / name for key, name in SESSION_FILES.items()}
    if not root.exists():
        raise FileNotFoundError(f"session directory not found: {root}")
    if not root.is_dir():
        raise ValueError(f"session path is not a directory: {root}")

    manifest = _try_read_json(paths["manifest"], issues)
    headless_status = None
    if paths["headless_status"].exists():
        headless_status = _try_read_json(paths["headless_status"], issues)
    auto_start_setup = None
    auto_start_capture_preflight = None
    auto_start_preflight = None
    auto_start_requested = _manifest_auto_start_requested(manifest)
    auto_start_setup_required = _manifest_requires_auto_start_setup(manifest)
    auto_start_capture_preflight_required = (
        _manifest_requires_auto_start_capture_preflight(manifest)
    )
    if auto_start_setup_required or paths["auto_start_setup"].exists():
        auto_start_setup = _try_read_json(paths["auto_start_setup"], issues)
    auto_start_setup_verdict = _summary_verdict(auto_start_setup)
    auto_start_setup_blocks = (
        auto_start_requested
        and _preflight_blocks_downstream(
            payload=auto_start_setup,
            required=auto_start_setup_required,
        )
    )
    if (
        not auto_start_setup_blocks
        and (
            auto_start_capture_preflight_required
            or paths["auto_start_capture_preflight"].exists()
        )
    ):
        auto_start_capture_preflight = _try_read_json(
            paths["auto_start_capture_preflight"],
            issues,
        )
    if (
        not auto_start_setup_blocks
        and (auto_start_requested or paths["auto_start_preflight"].exists())
    ):
        auto_start_preflight = _try_read_json(paths["auto_start_preflight"], issues)
    auto_start_capture_preflight_verdict = _summary_verdict(
        auto_start_capture_preflight
    )
    auto_start_preflight_verdict = _summary_verdict(auto_start_preflight)
    capture_preflight = None
    capture_preflight_required = _manifest_requires_capture_preflight(manifest)
    auto_start_blocks_normal_preflight = (
        auto_start_requested
        and (
            auto_start_setup_blocks
            or _preflight_blocks_downstream(
                payload=auto_start_capture_preflight,
                required=auto_start_capture_preflight_required,
            )
            or _preflight_blocks_downstream(
                payload=auto_start_preflight,
                required=True,
            )
        )
    )
    if (
        not auto_start_blocks_normal_preflight
        and (capture_preflight_required or paths["capture_preflight"].exists())
    ):
        capture_preflight = _try_read_json(paths["capture_preflight"], issues)
    capture_preflight_verdict = _summary_verdict(capture_preflight)
    capture_preflight_blocks = _preflight_blocks_downstream(
        payload=capture_preflight,
        required=capture_preflight_required,
    )
    if (
        auto_start_blocks_normal_preflight
        or capture_preflight_blocks
    ):
        preflight = None
        monitor = None
        summary = None
        decision = None
        jsonl_payload_rows = None
        jsonl_rows = None
        monitor_rows = None
        jsonl_matches_monitor_rows = False
        timing_failure = {
            "reason": "monitor rows are missing microphone timing evidence",
            "timing_gate": {"field": "rows"},
        }
        verdict, phase, reason = _classify(
            manifest=manifest,
            auto_start_setup=auto_start_setup,
            auto_start_capture_preflight=auto_start_capture_preflight,
            auto_start_preflight=auto_start_preflight,
            capture_preflight=capture_preflight,
            preflight=preflight,
            monitor=monitor,
            summary=summary,
            decision=decision,
            issues=issues,
        )
    else:
        preflight = _try_read_json(paths["preflight"], issues)
        preflight_verdict = _summary_verdict(preflight)
    if (
        not auto_start_blocks_normal_preflight
        and not capture_preflight_blocks
        and preflight_verdict == "capture_failed"
    ):
        monitor = None
        summary = None
        decision = None
        jsonl_payload_rows = None
        jsonl_rows = None
        monitor_rows = None
        jsonl_matches_monitor_rows = False
        timing_failure = {
            "reason": "monitor rows are missing microphone timing evidence",
            "timing_gate": {"field": "rows"},
        }
        verdict, phase, reason = _classify(
            manifest=manifest,
            auto_start_setup=auto_start_setup,
            auto_start_capture_preflight=auto_start_capture_preflight,
            auto_start_preflight=auto_start_preflight,
            capture_preflight=capture_preflight,
            preflight=preflight,
            monitor=monitor,
            summary=summary,
            decision=decision,
            issues=issues,
        )
    elif not (
        auto_start_blocks_normal_preflight
        or capture_preflight_blocks
    ):
        monitor = _try_read_json(paths["monitor"], issues)
        summary = _try_read_json(paths["summary"], issues)
        decision = _try_read_json(paths["decision"], issues)
        jsonl_payload_rows = _jsonl_rows(paths["samples"], issues)
        jsonl_rows = None if jsonl_payload_rows is None else len(jsonl_payload_rows)
        monitor_rows = _row_count(monitor)
        jsonl_matches_monitor_rows = _rows_match_jsonl(
            jsonl_payload_rows,
            monitor,
            issues,
        )
        timing_failure = _monitor_timing_failure(monitor)

        verdict, phase, reason = _classify(
            manifest=manifest,
            auto_start_setup=auto_start_setup,
            auto_start_capture_preflight=auto_start_capture_preflight,
            auto_start_preflight=auto_start_preflight,
            capture_preflight=capture_preflight,
            preflight=preflight,
            monitor=monitor,
            summary=summary,
            decision=decision,
            issues=issues,
        )
    if verdict in {"ready_for_baseline", "ready_for_correction", "hold"}:
        if jsonl_rows is None:
            verdict, phase, reason = (
                "incomplete",
                "samples",
                "samples JSONL is missing or invalid",
            )
        elif monitor_rows is None:
            verdict, phase, reason = (
                "incomplete",
                "monitor",
                "monitor rows are missing",
            )
        elif not jsonl_matches_monitor_rows:
            verdict, phase, reason = (
                "incomplete",
                "samples",
                "samples JSONL content does not match monitor rows",
            )
        elif timing_failure is not None:
            verdict, phase, reason = (
                "incomplete",
                "timing",
                timing_failure["reason"],
            )
            issues.append(timing_failure["reason"])
        elif (
            isinstance(manifest, dict)
            and manifest.get("defaultOutputReadFailed") is True
        ):
            verdict, phase, reason = (
                "not_applicable",
                "manifest",
                "default output was unverified during auto-start setup",
            )
    checklist = {
        "manifest_json": paths["manifest"].exists(),
        "auto_start_setup_json": paths["auto_start_setup"].exists(),
        "headless_status_json": paths["headless_status"].exists(),
        "auto_start_capture_preflight_json": paths["auto_start_capture_preflight"].exists(),
        "auto_start_preflight_json": paths["auto_start_preflight"].exists(),
        "capture_preflight_json": paths["capture_preflight"].exists(),
        "preflight_json": paths["preflight"].exists(),
        "monitor_json": paths["monitor"].exists(),
        "samples_jsonl": paths["samples"].exists(),
        "summary_json": paths["summary"].exists(),
        "decision_json": paths["decision"].exists(),
        "jsonl_matches_monitor_rows": (
            jsonl_matches_monitor_rows
        ),
        "monitor_stable": _summary_verdict(monitor) == "stable",
        "decision_known": _decision_verdict(decision)
        in {"initialize_baseline", "hold", "recommend", "reject"},
        "manifest_no_audio": (
            isinstance(manifest, dict) and manifest.get("emitsAudio") is False
        ),
        "manifest_no_delay_write": (
            isinstance(manifest, dict) and manifest.get("appliesDelay") is False
        ),
        "manifest_mic_after_preflight": (
            isinstance(manifest, dict)
            and manifest.get("opensMicrophoneOnlyAfterPreflight") is True
        ),
        "manifest_launches_app_declared": (
            isinstance(manifest, dict)
            and (
                not _manifest_auto_start_requested(manifest)
                or manifest.get("launchesApp") is True
                or manifest.get("launchesHeadlessRuntime") is True
            )
        ),
        "manifest_launches_headless_runtime": (
            isinstance(manifest, dict)
            and manifest.get("launchesHeadlessRuntime") is True
        ),
        "manifest_changes_routes_declared": (
            isinstance(manifest, dict)
            and (
                not _manifest_auto_start_requested(manifest)
                or manifest.get("changesRoutes") is True
            )
        ),
        "manifest_changes_launch_environment_declared": (
            isinstance(manifest, dict)
            and (
                not _manifest_auto_start_requested(manifest)
                or type(manifest.get("changesLaunchEnvironment")) is bool
            )
        ),
        "manifest_default_output_side_effect_declared": (
            isinstance(manifest, dict)
            and (
                not _manifest_auto_start_requested(manifest)
                or (
                    manifest.get("mayChangeDefaultOutput") is True
                    and type(manifest.get("changesDefaultOutput")) is bool
                )
            )
        ),
        "manifest_default_output_reported": (
            isinstance(manifest, dict)
            and (
                manifest.get("changesDefaultOutput") is not True
                and manifest.get("defaultOutputReadFailed") is not True
                or (
                    isinstance(manifest.get("defaultOutputReport"), str)
                    and bool(manifest.get("defaultOutputReport").strip())
                )
            )
        ),
        "no_delay_write_by_session": (
            isinstance(manifest, dict) and manifest.get("appliesDelay") is False
        ),
        "passive_mic_timing_metadata": timing_failure is None,
    }
    return {
        "verdict": verdict,
        "phase": phase,
        "reason": reason,
        "session_root": str(root),
        "checklist": checklist,
        "issues": issues,
        "manifest_schema": manifest.get("schema") if isinstance(manifest, dict) else None,
        "auto_start_targets": (
            manifest.get("autoStartTargets") if isinstance(manifest, dict) else None
        ),
        "launches_app": (
            manifest.get("launchesApp") if isinstance(manifest, dict) else None
        ),
        "launches_headless_runtime": (
            manifest.get("launchesHeadlessRuntime")
            if isinstance(manifest, dict)
            else None
        ),
        "app_launch_attempted": (
            manifest.get("appLaunchAttempted") if isinstance(manifest, dict) else None
        ),
        "app_launched": (
            manifest.get("appLaunched") if isinstance(manifest, dict) else None
        ),
        "headless_runtime_launched": (
            manifest.get("headlessRuntimeLaunched")
            if isinstance(manifest, dict)
            else None
        ),
        "launch_method_requested": (
            manifest.get("launchMethodRequested") if isinstance(manifest, dict) else None
        ),
        "launch_method_used": (
            manifest.get("launchMethodUsed") if isinstance(manifest, dict) else None
        ),
        "launch_environment_applied": (
            manifest.get("launchEnvironmentApplied") if isinstance(manifest, dict) else None
        ),
        "changes_routes": (
            manifest.get("changesRoutes") if isinstance(manifest, dict) else None
        ),
        "changes_launch_environment": (
            manifest.get("changesLaunchEnvironment") if isinstance(manifest, dict) else None
        ),
        "may_change_default_output": (
            manifest.get("mayChangeDefaultOutput") if isinstance(manifest, dict) else None
        ),
        "changes_default_output": (
            manifest.get("changesDefaultOutput") if isinstance(manifest, dict) else None
        ),
        "default_output_report": (
            manifest.get("defaultOutputReport") if isinstance(manifest, dict) else None
        ),
        "default_output_read_failed": (
            manifest.get("defaultOutputReadFailed") if isinstance(manifest, dict) else None
        ),
        "default_output_verified": (
            manifest.get("defaultOutputVerified") if isinstance(manifest, dict) else None
        ),
        "default_output_setup_skipped": (
            manifest.get("defaultOutputSetupSkipped") if isinstance(manifest, dict) else None
        ),
        "headless_status_stage": (
            headless_status.get("stage") if isinstance(headless_status, dict) else None
        ),
        "headless_status_error": (
            headless_status.get("error") if isinstance(headless_status, dict) else None
        ),
        "headless_discovered_device_count": (
            headless_status.get("discoveredDeviceCount")
            if isinstance(headless_status, dict)
            else None
        ),
        "headless_direct_coreaudio_output_count": (
            headless_status.get("directCoreAudioOutputCount")
            if isinstance(headless_status, dict)
            else None
        ),
        "headless_missing_targets": (
            headless_status.get("missingTargets")
            if isinstance(headless_status, dict)
            else None
        ),
        "headless_discovery_errors": (
            headless_status.get("discoveryErrors")
            if isinstance(headless_status, dict)
            else None
        ),
        "auto_start_setup_verdict": _summary_verdict(auto_start_setup),
        "auto_start_capture_preflight_verdict": _summary_verdict(
            auto_start_capture_preflight
        ),
        "auto_start_preflight_verdict": _summary_verdict(auto_start_preflight),
        "capture_preflight_verdict": _summary_verdict(capture_preflight),
        "preflight_verdict": _summary_verdict(preflight),
        "monitor_verdict": _summary_verdict(monitor),
        "decision_verdict": _decision_verdict(decision),
        "decision_auto_apply_eligible": (
            decision.get("auto_apply_eligible") if isinstance(decision, dict) else None
        ),
        "samples_jsonl_rows": jsonl_rows,
        "monitor_rows": monitor_rows,
        "timing_gate": (
            None if timing_failure is None else timing_failure.get("timing_gate")
        ),
    }


def _exit_code(verdict: str) -> int:
    if verdict in {"ready_for_baseline", "ready_for_correction", "hold"}:
        return EXIT_OK
    if verdict == "capture_failed":
        return EXIT_CAPTURE_FAILED
    return EXIT_NOT_READY


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Audit a scripts/passive_drift_session.sh output directory."
    )
    parser.add_argument("session_root", type=Path)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        result = audit_session(args.session_root)
        print(json.dumps(result, indent=2, sort_keys=True))
        return _exit_code(str(result["verdict"]))
    except Exception as exc:
        print(
            json.dumps({"verdict": "bad_input", "error": str(exc)}, indent=2),
            file=sys.stderr,
        )
        return EXIT_BAD_INPUT


if __name__ == "__main__":
    raise SystemExit(main())
