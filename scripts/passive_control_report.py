#!/usr/bin/env python3
"""Summarize passive session, baseline finalization, and correction gate state."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any

import passive_delay_decision as pdd
import passive_session_audit as psa


EXIT_OK = 0
EXIT_BAD_INPUT = 2
EXIT_NOT_READY = 3
EXIT_CAPTURE_FAILED = 4


def _read_json_optional(path: Path, issues: list[str]) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        issues.append(f"{path.name}: invalid JSON: {exc}")
        return None
    if not isinstance(payload, dict):
        issues.append(f"{path.name}: expected JSON object")
        return None
    return payload


def _int_value(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return None
    return None


def _float_value(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return float(value)
    if isinstance(value, str):
        try:
            parsed = float(value)
        except ValueError:
            return None
        return parsed if math.isfinite(parsed) else None
    return None


def _current_features(session_root: Path) -> dict[str, Any] | None:
    monitor_path = session_root / "monitor.json"
    if not monitor_path.exists():
        return None
    monitor = json.loads(monitor_path.read_text())
    if not isinstance(monitor, dict):
        return None
    decision = pdd.decide(monitor)
    features = decision.get("features")
    return features if isinstance(features, dict) else None


def _same_float(left: Any, right: Any, *, tolerance: float = 0.001) -> bool:
    left_value = _float_value(left)
    right_value = _float_value(right)
    return (
        left_value is not None
        and right_value is not None
        and abs(left_value - right_value) <= tolerance
    )


def _finalize_artifact_issue(
    *,
    session_root: Path,
    audit: dict[str, Any],
    finalize: dict[str, Any],
) -> str | None:
    artifact_root = finalize.get("sessionRoot")
    if isinstance(artifact_root, str) and artifact_root:
        if Path(artifact_root).resolve(strict=False) != session_root.resolve(strict=False):
            return "finalize artifact belongs to a different session root"
    finalize_verdict = finalize.get("verdict")
    if finalize_verdict not in {"decided", "recorded"}:
        return None
    artifact_audit = finalize.get("auditVerdict")
    if not isinstance(artifact_audit, str):
        return "finalize artifact missing audit verdict binding"
    if artifact_audit != audit.get("verdict"):
        return "finalize artifact audit verdict does not match current audit"
    try:
        current_features = _current_features(session_root)
    except Exception as exc:
        return f"current monitor feature binding failed: {exc}"
    if not isinstance(current_features, dict):
        return "current monitor feature binding is unavailable"

    if finalize_verdict == "recorded":
        baseline = (finalize.get("result") or {}).get("baseline")
        if not isinstance(baseline, dict):
            return "finalize artifact is missing recorded baseline binding"
        # A freshly recorded baseline artifact must describe this same monitor
        # session exactly, including the sync context captured at recording
        # time. Stored-baseline identity is looser later; this branch only
        # rejects stale or swapped finalize.json artifacts for the recording
        # session itself.
        same_recording_pairs = (
            ("contextSignature", "context_signature"),
            ("captureBackend", "capture_backend"),
            ("delayLocked", "delay_locked"),
            ("enabledAirplayCount", "enabled_airplay_count"),
            ("airplayTimingEpoch", "airplay_timing_epoch"),
            ("syncContextState", "sync_context_state"),
            ("syncContextRevision", "sync_context_revision"),
        )
        for baseline_field, feature_field in same_recording_pairs:
            if baseline.get(baseline_field) != current_features.get(feature_field):
                return (
                    "finalize artifact recorded baseline does not match current "
                    f"monitor: {feature_field}"
                )
        numeric_pairs = (
            ("currentDelayMs", "current_delay_ms"),
            ("measuredDelayMs", "measured_delay_ms"),
            ("baselineOffsetMs", "observed_offset_ms"),
            ("delayRangeMs", "delay_range_ms"),
        )
        for baseline_field, feature_field in numeric_pairs:
            if not _same_float(
                baseline.get(baseline_field),
                current_features.get(feature_field),
            ):
                return (
                    "finalize artifact recorded baseline does not match current "
                    f"monitor: {feature_field}"
                )
        if _int_value(baseline.get("samplesAccepted")) != _int_value(
            current_features.get("samples_accepted")
        ):
            return (
                "finalize artifact recorded baseline does not match current "
                "monitor: samples_accepted"
            )
        return None

    decision = (finalize.get("result") or {}).get("decision")
    if not isinstance(decision, dict):
        return "finalize artifact is missing stored-baseline decision"
    features = decision.get("features")
    if not isinstance(features, dict):
        return "finalize artifact is missing decision feature binding"
    baseline = (finalize.get("result") or {}).get("baseline")
    if not isinstance(baseline, dict):
        return "finalize artifact is missing stored baseline binding"

    route_pairs = (
        ("contextSignature", "context_signature"),
        ("captureBackend", "capture_backend"),
        ("delayLocked", "delay_locked"),
        ("enabledAirplayCount", "enabled_airplay_count"),
        ("airplayTimingEpoch", "airplay_timing_epoch"),
    )
    for baseline_field, feature_field in route_pairs:
        if baseline.get(baseline_field) != features.get(feature_field):
            return (
                "finalize artifact stored baseline does not match decision "
                f"route identity: {feature_field}"
            )

    exact_fields = (
        "context_signature",
        "capture_backend",
        "delay_locked",
        "enabled_airplay_count",
        "airplay_timing_epoch",
        "sync_context_state",
        "sync_context_revision",
    )
    for field in exact_fields:
        if features.get(field) != current_features.get(field):
            return f"finalize artifact decision does not match current monitor: {field}"
    numeric_fields = (
        "current_delay_ms",
        "measured_delay_ms",
        "observed_offset_ms",
        "delay_range_ms",
    )
    for field in numeric_fields:
        if not _same_float(features.get(field), current_features.get(field)):
            return f"finalize artifact decision does not match current monitor: {field}"
    return None


def _gate_artifact_issue(
    *,
    session_root: Path,
    finalize: dict[str, Any],
    gate: dict[str, Any],
) -> str | None:
    gate_root = gate.get("sessionRoot")
    if not isinstance(gate_root, str) or not gate_root:
        return "correction gate missing session root"
    if Path(gate_root).resolve(strict=False) != session_root.resolve(strict=False):
        return "correction gate belongs to a different session root"
    if gate.get("delayLocked") is not False:
        return "correction gate missing delayLocked=false apply binding"
    result = finalize.get("result")
    if not isinstance(result, dict):
        return "finalize artifact is missing result object"
    baseline = result.get("baseline")
    decision = result.get("decision")
    if not isinstance(baseline, dict) or not isinstance(decision, dict):
        return "finalize artifact is missing baseline or decision object"
    features = decision.get("features")
    if not isinstance(features, dict):
        return "finalize artifact is missing decision feature binding"
    bindings = (
        ("baselineKey", baseline.get("key")),
        ("contextSignature", baseline.get("contextSignature")),
        ("captureBackend", baseline.get("captureBackend")),
        ("delayLocked", baseline.get("delayLocked")),
        ("enabledAirplayCount", baseline.get("enabledAirplayCount")),
        ("activeAirplayCount", baseline.get("activeAirplayCount")),
        ("airplayTimingEpoch", baseline.get("airplayTimingEpoch")),
        ("syncContextState", features.get("sync_context_state")),
        ("syncContextRevision", features.get("sync_context_revision")),
        ("recommendedDelayMs", decision.get("recommended_delay_ms")),
        ("currentDelayMs", features.get("current_delay_ms")),
    )
    for gate_field, expected in bindings:
        if expected in (None, ""):
            return f"finalize artifact missing field required to validate gate: {gate_field}"
        actual = gate.get(gate_field)
        if isinstance(expected, (int, float)) and not isinstance(expected, bool):
            if _int_value(actual) != int(round(float(expected))):
                return f"correction gate does not match finalize artifact: {gate_field}"
        elif actual != expected:
            return f"correction gate does not match finalize artifact: {gate_field}"
    return None


def _apply_artifact_issue(
    *,
    session_root: Path,
    gate: dict[str, Any],
    passive_apply: dict[str, Any],
) -> str | None:
    request = passive_apply.get("request")
    if not isinstance(request, dict):
        return "passive apply artifact missing request context"

    artifact_root = passive_apply.get("sessionRoot")
    if not isinstance(artifact_root, str) or not artifact_root:
        return "passive apply artifact missing session root"
    if Path(artifact_root).resolve(strict=False) != session_root.resolve(strict=False):
        return "passive apply artifact belongs to a different session root"

    required_number_fields = [
        ("targetDelayMs", "recommendedDelayMs"),
        ("currentDelayMs", "currentDelayMs"),
        ("enabledAirplayCount", "enabledAirplayCount"),
        ("activeAirplayCount", "activeAirplayCount"),
        ("airplayTimingEpoch", "airplayTimingEpoch"),
        ("syncContextRevision", "syncContextRevision"),
    ]
    for request_field, gate_field in required_number_fields:
        gate_value = _int_value(gate.get(gate_field))
        if gate_value is None:
            return (
                "correction gate missing field required to validate passive apply "
                f"artifact: {gate_field}"
            )
        if _int_value(request.get(request_field)) != gate_value:
            return (
                "passive apply artifact request does not match correction gate: "
                f"{request_field}"
            )

    required_string_fields = [
        ("contextSignature", "contextSignature"),
        ("syncContextState", "syncContextState"),
    ]
    optional_string_fields = [
        ("captureBackend", "captureBackend"),
        ("baselineKey", "baselineKey"),
    ]
    for request_field, gate_field in required_string_fields:
        gate_value = gate.get(gate_field)
        if gate_value in (None, ""):
            return (
                "correction gate missing field required to validate passive apply "
                f"artifact: {gate_field}"
            )
        if str(request.get(request_field) or "") != str(gate_value):
            return (
                "passive apply artifact request does not match correction gate: "
                f"{request_field}"
            )
    for request_field, gate_field in optional_string_fields:
        gate_value = gate.get(gate_field)
        if gate_value not in (None, "") and str(request.get(request_field) or "") != str(gate_value):
            return (
                "passive apply artifact request does not match correction gate: "
                f"{request_field}"
            )

    dry_run = passive_apply.get("dryRun")
    request_dry_run = request.get("dryRun")
    if not isinstance(dry_run, bool) or request_dry_run is not dry_run:
        return "passive apply artifact has inconsistent dry-run state"
    if gate.get("delayLocked") is not False or request.get("delayLocked") is not False:
        return "passive apply artifact request does not match correction gate: delayLocked"

    result = passive_apply.get("result")
    if not isinstance(result, dict):
        return "passive apply artifact missing result object"

    apply_verdict = passive_apply.get("verdict")
    if apply_verdict == "dry_run_ready":
        result_issue = _apply_result_runtime_issue(gate=gate, result=result)
        if result_issue is not None:
            return result_issue
        if dry_run is not True:
            return "passive dry-run artifact was not produced by a dry-run request"
        if passive_apply.get("appliesDelay") is not False:
            return "passive dry-run artifact claims it applied delay"
        if result.get("applied") is True:
            return "passive dry-run artifact result contradicts dry-run verdict"
        if result.get("wouldApply") is not True:
            return "passive dry-run artifact did not confirm runtime would apply"
    elif apply_verdict == "applied":
        result_issue = _apply_result_runtime_issue(gate=gate, result=result)
        if result_issue is not None:
            return result_issue
        if dry_run is not False:
            return "passive applied artifact was produced by a dry-run request"
        if passive_apply.get("appliesDelay") is not True:
            return "passive applied artifact does not record a delay write"
        if result.get("applied") is not True:
            return "passive applied artifact result does not confirm applied=true"
        if _int_value(result.get("appliedDelayMs")) != _int_value(gate.get("recommendedDelayMs")):
            return "passive applied artifact wrote a different delay than the gate target"
    return None


def _apply_result_runtime_issue(
    *,
    gate: dict[str, Any],
    result: dict[str, Any],
) -> str | None:
    required_number_fields = [
        ("targetDelayMs", "recommendedDelayMs"),
        ("currentDelayMs", "currentDelayMs"),
        ("enabledAirplayCount", "enabledAirplayCount"),
        ("activeAirplayCount", "activeAirplayCount"),
        ("airplayTimingEpoch", "airplayTimingEpoch"),
        ("syncContextRevision", "syncContextRevision"),
    ]
    for result_field, gate_field in required_number_fields:
        gate_value = _int_value(gate.get(gate_field))
        if gate_value is None:
            return (
                "correction gate missing field required to validate passive apply "
                f"result: {gate_field}"
            )
        if _int_value(result.get(result_field)) != gate_value:
            return (
                "passive apply artifact result does not match correction gate: "
                f"{result_field}"
            )

    required_string_fields = [
        ("contextSignature", "contextSignature"),
        ("syncContextState", "syncContextState"),
    ]
    optional_string_fields = [
        ("captureBackend", "captureBackend"),
    ]
    for result_field, gate_field in required_string_fields:
        gate_value = gate.get(gate_field)
        if gate_value in (None, ""):
            return (
                "correction gate missing field required to validate passive apply "
                f"result: {gate_field}"
            )
        if str(result.get(result_field) or "") != str(gate_value):
            return (
                "passive apply artifact result does not match correction gate: "
                f"{result_field}"
            )
    for result_field, gate_field in optional_string_fields:
        gate_value = gate.get(gate_field)
        if gate_value not in (None, "") and str(result.get(result_field) or "") != str(gate_value):
            return (
                "passive apply artifact result does not match correction gate: "
                f"{result_field}"
            )
    if result.get("delayLocked") is not False:
        return "passive apply artifact result does not match correction gate: delayLocked"
    return None


def _baseline_mark_artifact_issue(
    *,
    session_root: Path,
    finalize: dict[str, Any],
    passive_baseline_mark: dict[str, Any],
) -> str | None:
    request = passive_baseline_mark.get("request")
    if not isinstance(request, dict):
        return "passive baseline mark artifact missing request context"

    artifact_root = passive_baseline_mark.get("sessionRoot")
    if not isinstance(artifact_root, str) or not artifact_root:
        return "passive baseline mark artifact missing session root"
    if Path(artifact_root).resolve(strict=False) != session_root.resolve(strict=False):
        return "passive baseline mark artifact belongs to a different session root"

    result = finalize.get("result")
    if not isinstance(result, dict):
        return "finalize artifact is missing result object"
    baseline = result.get("baseline")
    if not isinstance(baseline, dict):
        return "finalize artifact is missing recorded baseline object"

    required_number_fields = [
        ("currentDelayMs", "currentDelayMs"),
        ("enabledAirplayCount", "enabledAirplayCount"),
        ("airplayTimingEpoch", "airplayTimingEpoch"),
        ("syncContextRevision", "syncContextRevision"),
    ]
    for request_field, baseline_field in required_number_fields:
        baseline_value = _int_value(baseline.get(baseline_field))
        if baseline_value is None:
            return (
                "recorded baseline missing field required to validate baseline "
                f"mark artifact: {baseline_field}"
            )
        if _int_value(request.get(request_field)) != baseline_value:
            return (
                "passive baseline mark artifact request does not match recorded "
                f"baseline: {request_field}"
            )

    required_string_fields = [
        ("contextSignature", "contextSignature"),
        ("captureBackend", "captureBackend"),
        ("syncContextState", "syncContextState"),
    ]
    for request_field, baseline_field in required_string_fields:
        baseline_value = baseline.get(baseline_field)
        if baseline_value in (None, ""):
            return (
                "recorded baseline missing field required to validate baseline "
                f"mark artifact: {baseline_field}"
            )
        if str(request.get(request_field) or "") != str(baseline_value):
            return (
                "passive baseline mark artifact request does not match recorded "
                f"baseline: {request_field}"
            )

    if baseline.get("delayLocked") is not False or request.get("delayLocked") is not False:
        return "passive baseline mark artifact request does not record delayLocked=false"
    if baseline.get("key") not in (None, ""):
        if str(request.get("baselineKey") or "") != str(baseline.get("key")):
            return "passive baseline mark artifact request does not match recorded baseline: baselineKey"
    if request.get("activeAirplayCount") is not None:
        if _int_value(request.get("activeAirplayCount")) != _int_value(
            baseline.get("enabledAirplayCount")
        ):
            return "passive baseline mark artifact request has inconsistent activeAirplayCount"

    dry_run = passive_baseline_mark.get("dryRun")
    request_dry_run = request.get("dryRun")
    if not isinstance(dry_run, bool) or request_dry_run is not dry_run:
        return "passive baseline mark artifact has inconsistent dry-run state"
    if passive_baseline_mark.get("emitsAudio") is not False:
        return "passive baseline mark artifact claims it emitted audio"
    if passive_baseline_mark.get("opensMicrophone") is not False:
        return "passive baseline mark artifact claims it opened the microphone"
    if passive_baseline_mark.get("appliesDelay") is not False:
        return "passive baseline mark artifact claims it applied delay"

    result = passive_baseline_mark.get("result")
    if not isinstance(result, dict):
        return "passive baseline mark artifact missing result object"
    mark_verdict = passive_baseline_mark.get("verdict")
    if mark_verdict == "dry_run_ready":
        if dry_run is not True:
            return "passive baseline dry-run artifact was not produced by a dry-run request"
        if result.get("accepted") is not True or result.get("applied") is True:
            return "passive baseline dry-run artifact result contradicts dry-run verdict"
        runtime_issue = _baseline_mark_result_runtime_issue(
            request=request,
            result=result,
            dry_run=True,
            marked_valid=False,
        )
        if runtime_issue is not None:
            return runtime_issue
    elif mark_verdict == "marked_valid":
        if dry_run is not False:
            return "passive baseline marked artifact was produced by a dry-run request"
        if result.get("accepted") is not True or result.get("applied") is not True:
            return "passive baseline marked artifact result does not confirm applied=true"
        runtime_issue = _baseline_mark_result_runtime_issue(
            request=request,
            result=result,
            dry_run=False,
            marked_valid=True,
        )
        if runtime_issue is not None:
            return runtime_issue
    elif mark_verdict in {"not_marked", "not_ready", "rpc_failed"}:
        return str(
            passive_baseline_mark.get("error")
            or result.get("reason")
            or f"passive baseline mark verdict is {mark_verdict}"
        )
    else:
        return f"passive baseline mark verdict is {mark_verdict}"
    return None


def _baseline_mark_result_runtime_issue(
    *,
    request: dict[str, Any],
    result: dict[str, Any],
    dry_run: bool,
    marked_valid: bool,
) -> str | None:
    if result.get("dryRun") is not dry_run:
        return "passive baseline mark artifact result has inconsistent dry-run state"
    if result.get("emitsAudio") is not False:
        return "passive baseline mark artifact result claims it emitted audio"
    if result.get("opensMicrophone") is not False:
        return "passive baseline mark artifact result claims it opened the microphone"
    if result.get("appliesDelay") is not False:
        return "passive baseline mark artifact result claims it applied delay"
    if result.get("delayLocked") is not False:
        return "passive baseline mark artifact result does not match request: delayLocked"

    required_number_fields = [
        ("currentDelayMs", "currentDelayMs"),
        ("enabledAirplayCount", "enabledAirplayCount"),
        ("airplayTimingEpoch", "airplayTimingEpoch"),
    ]
    for result_field, request_field in required_number_fields:
        request_value = _int_value(request.get(request_field))
        if request_value is None:
            return (
                "passive baseline mark artifact request missing field required "
                f"to validate result: {request_field}"
            )
        if _int_value(result.get(result_field)) != request_value:
            return (
                "passive baseline mark artifact result does not match request: "
                f"{result_field}"
            )

    active_request_value = request.get(
        "activeAirplayCount",
        request.get("enabledAirplayCount"),
    )
    active_expected = _int_value(active_request_value)
    if active_expected is None:
        return "passive baseline mark artifact request missing field required to validate result: activeAirplayCount"
    if _int_value(result.get("activeAirplayCount")) != active_expected:
        return "passive baseline mark artifact result does not match request: activeAirplayCount"

    required_string_fields = [
        ("contextSignature", "contextSignature"),
        ("captureBackend", "captureBackend"),
    ]
    for result_field, request_field in required_string_fields:
        request_value = request.get(request_field)
        if request_value in (None, ""):
            return (
                "passive baseline mark artifact request missing field required "
                f"to validate result: {request_field}"
            )
        if str(result.get(result_field) or "") != str(request_value):
            return (
                "passive baseline mark artifact result does not match request: "
                f"{result_field}"
            )

    request_state = str(request.get("syncContextState") or "")
    request_revision = _int_value(request.get("syncContextRevision"))
    if not request_state:
        return "passive baseline mark artifact request missing syncContextState"
    if request_revision is None:
        return "passive baseline mark artifact request missing syncContextRevision"

    if not marked_valid:
        if str(result.get("syncContextState") or "") != request_state:
            return "passive baseline mark artifact result does not match request: syncContextState"
        if _int_value(result.get("syncContextRevision")) != request_revision:
            return "passive baseline mark artifact result does not match request: syncContextRevision"
        return None

    if str(result.get("syncContextState") or "") != "valid":
        return "passive baseline marked artifact did not set syncContextState=valid"
    if str(result.get("previousSyncContextState") or "") != request_state:
        return "passive baseline marked artifact previous sync context does not match request: previousSyncContextState"
    previous_revision = _int_value(result.get("previousSyncContextRevision"))
    marked_revision = _int_value(result.get("syncContextRevision"))
    if previous_revision != request_revision:
        return "passive baseline marked artifact previous sync context does not match request: previousSyncContextRevision"
    if marked_revision is None:
        return "passive baseline marked artifact missing syncContextRevision"
    if request_state != "valid":
        if marked_revision <= request_revision:
            return "passive baseline marked artifact did not advance syncContextRevision"
    elif marked_revision < request_revision:
        return "passive baseline marked artifact syncContextRevision moved backwards"
    return None


def _classify(
    *,
    session_root: Path,
    manifest: dict[str, Any] | None,
    audit: dict[str, Any],
    finalize: dict[str, Any] | None,
    gate: dict[str, Any] | None,
    passive_apply: dict[str, Any] | None,
    passive_baseline_mark: dict[str, Any] | None,
    workflow_guard: dict[str, Any] | None,
) -> tuple[str, str, str]:
    if isinstance(workflow_guard, dict) and workflow_guard.get("verdict") == "blocked":
        return (
            "not_applicable",
            "workflow_guard",
            str(
                workflow_guard.get("reason")
                or "passive readiness workflow guard blocked this session"
            ),
        )
    audit_verdict = audit.get("verdict")
    if audit_verdict == "capture_failed":
        audit_phase = audit.get("phase")
        return (
            "capture_failed",
            audit_phase if isinstance(audit_phase, str) else "audit",
            str(audit.get("reason") or "session failed before usable evidence"),
        )
    if audit_verdict == "incomplete":
        audit_phase = audit.get("phase")
        return (
            "incomplete",
            audit_phase if isinstance(audit_phase, str) else "audit",
            str(audit.get("reason") or "session artifacts are incomplete"),
        )
    if audit_verdict == "not_applicable":
        audit_phase = audit.get("phase")
        return (
            "not_applicable",
            audit_phase if isinstance(audit_phase, str) else "audit",
            str(audit.get("reason") or "audit rejected this passive evidence"),
        )
    if audit_verdict not in {"ready_for_baseline", "ready_for_correction", "hold"}:
        return (
            "incomplete",
            "audit",
            str(audit.get("reason") or f"audit verdict is {audit_verdict}"),
        )

    if finalize is None:
        if audit_verdict == "hold":
            return (
                "hold",
                "decision",
                str(audit.get("reason") or "no correction needed"),
            )
        if audit_verdict == "ready_for_baseline":
            return (
                "ready_for_baseline",
                "decision",
                "stable passive evidence can initialize a relative baseline",
            )
        return (
            "incomplete",
            "finalize",
            "session audit is usable but no finalize artifact is present",
        )
    finalize_issue = _finalize_artifact_issue(
        session_root=session_root,
        audit=audit,
        finalize=finalize,
    )
    if finalize_issue is not None:
        return ("not_applicable", "finalize", finalize_issue)
    finalize_verdict = finalize.get("verdict")
    if finalize_verdict == "recorded":
        if passive_baseline_mark is not None:
            baseline_mark_issue = _baseline_mark_artifact_issue(
                session_root=session_root,
                finalize=finalize,
                passive_baseline_mark=passive_baseline_mark,
            )
            if baseline_mark_issue is not None:
                return ("not_applicable", "baseline_mark", baseline_mark_issue)
            if passive_baseline_mark.get("verdict") == "dry_run_ready":
                return (
                    "baseline_mark_dry_run_ready",
                    "baseline_mark",
                    "app-side baseline mark dry-run accepted the recorded baseline context",
                )
            if passive_baseline_mark.get("verdict") == "marked_valid":
                return (
                    "baseline_recorded",
                    "baseline_mark",
                    "first safe passive baseline recorded and app runtime context marked valid",
                )
        if (
            isinstance(manifest, dict)
            and manifest.get("baselineMarkMode") in {"mark", "dry-run"}
        ):
            return (
                "incomplete",
                "baseline_mark",
                "recorded baseline is missing app-side baseline mark artifact",
            )
        return (
            "baseline_recorded",
            "finalize",
            "first safe passive baseline recorded for this route context",
        )
    if finalize_verdict != "decided":
        return (
            "not_applicable",
            "finalize",
            str(finalize.get("error") or f"finalize verdict is {finalize_verdict}"),
        )

    decision = (finalize.get("result") or {}).get("decision")
    decision_verdict = decision.get("verdict") if isinstance(decision, dict) else None
    if decision_verdict == "hold":
        return (
            "hold",
            "decision",
            str(decision.get("reason") or "stored-baseline decision is inside deadband"),
        )
    if decision_verdict != "recommend":
        return (
            "not_applicable",
            "decision",
            str(
                (decision or {}).get("reason")
                or f"stored-baseline decision verdict is {decision_verdict}"
            ),
        )

    if gate is None:
        return (
            "incomplete",
            "gate",
            "stored-baseline recommendation exists but no correction gate artifact is present",
        )
    gate_verdict = gate.get("verdict")
    if gate_verdict == "ready_for_apply_candidate":
        gate_issue = _gate_artifact_issue(
            session_root=session_root,
            finalize=finalize,
            gate=gate,
        )
        if gate_issue is not None:
            return ("not_applicable", "gate", gate_issue)
        if passive_apply is not None:
            artifact_issue = _apply_artifact_issue(
                session_root=session_root,
                gate=gate,
                passive_apply=passive_apply,
            )
            if artifact_issue is not None:
                return ("not_applicable", "apply", artifact_issue)
            apply_verdict = passive_apply.get("verdict")
            if (
                isinstance(manifest, dict)
                and manifest.get("passiveApplyMode") == "dry-run"
                and apply_verdict == "applied"
            ):
                return (
                    "not_applicable",
                    "apply",
                    "passive apply artifact contradicts manifest dry-run mode",
                )
            if apply_verdict == "dry_run_ready":
                return (
                    "dry_run_ready",
                    "apply",
                    str(
                        (passive_apply.get("result") or {}).get("reason")
                        or "app-side passive apply dry-run accepted candidate"
                    ),
                )
            if apply_verdict == "applied":
                return (
                    "applied",
                    "apply",
                    str(
                        (passive_apply.get("result") or {}).get("reason")
                        or "passive correction applied"
                    ),
                )
            if apply_verdict in {"not_applied", "not_ready", "rpc_failed"}:
                return (
                    "not_applicable",
                    "apply",
                    str(
                        passive_apply.get("error")
                        or (passive_apply.get("result") or {}).get("reason")
                        or f"passive apply verdict is {apply_verdict}"
                    ),
                )
        if isinstance(manifest, dict) and manifest.get("passiveApplyMode") == "dry-run":
            return (
                "incomplete",
                "apply",
                "correction gate is ready but passive apply dry-run artifact is missing",
            )
        return (
            "ready_for_apply_candidate",
            "gate",
            str(gate.get("reason") or "repeat-confirmed passive correction candidate"),
        )
    if gate_verdict == "pending_confirmation":
        return (
            "pending_confirmation",
            "gate",
            str(gate.get("reason") or "repeat confirmation required"),
        )
    return (
        "not_applicable",
        "gate",
        str(gate.get("reason") or gate.get("error") or f"gate verdict is {gate_verdict}"),
    )


def _next_action(
    *,
    verdict: str,
    phase: str,
    audit: dict[str, Any],
    manifest: dict[str, Any] | None,
    readiness: dict[str, Any] | None,
) -> tuple[str | None, str]:
    audit_phase = audit.get("phase")
    blocking_stage = audit_phase if isinstance(audit_phase, str) else phase
    auto_start_targets = (
        manifest.get("autoStartTargets") if isinstance(manifest, dict) else None
    )

    if verdict == "capture_failed":
        if blocking_stage == "auto_start_setup":
            return (
                blocking_stage,
                (
                    "auto-start could not prepare the app launch or CoreAudio/"
                    "default-output environment; inspect auto_start_setup.json, "
                    "manifest.json, direct/headless launch stderr if present, "
                    "and CoreAudio default-output probe output"
                ),
            )
        if blocking_stage == "auto_start_capture_preflight":
            return (
                blocking_stage,
                (
                    "auto-start did not reach passive capture readiness; inspect "
                    "auto_start_capture_preflight.json and launch.log for app, socket, "
                    "Whole-home, backend, or AirPlay connection failures"
                ),
            )
        if isinstance(readiness, dict) and readiness.get("verdict") != "ready":
            readiness_stage = readiness.get("stage")
            readiness_action = readiness.get("nextAction")
            return (
                readiness_stage if isinstance(readiness_stage, str) else blocking_stage,
                (
                    readiness_action
                    if isinstance(readiness_action, str) and readiness_action
                    else "inspect readiness.json before running passive diagnostics"
                ),
            )
        if blocking_stage == "auto_start_preflight":
            return (
                blocking_stage,
                (
                    "auto-start reached the app but drift readiness failed; inspect "
                    "auto_start_preflight.json for route, delay, backend, or AirPlay "
                    "metadata failures"
                ),
            )
        if auto_start_targets:
            return (
                blocking_stage,
                (
                    "retry the no-probe session with auto-start targets after checking "
                    "SyncCast launch.log and selected local+AirPlay devices"
                ),
            )
        return (
            blocking_stage,
            (
                "start SyncCast in Whole-home with at least one local CoreAudio output "
                "and one or more connected AirPlay outputs, then rerun the no-probe passive "
                "session"
            ),
        )

    if verdict == "ready_for_baseline":
        return (
            None,
            "record this stable session as the route baseline before applying corrections",
        )
    if verdict == "baseline_recorded":
        return (
            None,
            "collect a later same-route passive session to compare against the stored baseline",
        )
    if verdict == "baseline_mark_dry_run_ready":
        return (
            None,
            "app-side dry-run accepted the recorded baseline context; rerun baseline mark in mark mode before using drift-monitor evidence",
        )
    if verdict == "pending_confirmation":
        return (
            None,
            "collect one more independent same-context passive session to confirm the correction",
        )
    if verdict == "ready_for_apply_candidate":
        return (
            None,
            "run the app-side passive apply dry-run before any delay write is allowed",
        )
    if verdict == "dry_run_ready":
        return (
            None,
            "app-side dry-run accepted the passive correction candidate; keep listening validation separate from automatic writes",
        )
    if verdict == "hold":
        return (
            None,
            "no correction is needed for this stable same-baseline session",
        )
    if verdict == "applied":
        return (
            None,
            "verify a post-apply passive session before treating the correction as stable",
        )
    if phase == "artifact_json":
        return (
            "artifact_json",
            "repair or rerun the passive session so corrupt JSON artifacts are replaced",
        )
    if verdict == "incomplete":
        if phase == "baseline_mark":
            return (
                phase,
                "run the app-side passive baseline mark step or rerun the session with SYNCAST_PASSIVE_BASELINE_MARK_MODE=mark",
            )
        return (
            blocking_stage,
            "repair or rerun the passive session so all required artifacts are present",
        )
    return (
        blocking_stage,
        "inspect the rejected passive evidence before using it for delay control",
    )


def build_report(session_root: Path) -> dict[str, Any]:
    if not session_root.exists():
        raise FileNotFoundError(f"session directory not found: {session_root}")
    artifact_issues: list[str] = []
    manifest = _read_json_optional(session_root / "manifest.json", artifact_issues)
    audit = psa.audit_session(session_root)
    finalize = _read_json_optional(session_root / "finalize.json", artifact_issues)
    gate = _read_json_optional(session_root / "correction_gate.json", artifact_issues)
    passive_apply = _read_json_optional(
        session_root / "passive_apply.json",
        artifact_issues,
    )
    passive_baseline_mark = _read_json_optional(
        session_root / "passive_baseline_mark.json",
        artifact_issues,
    )
    readiness = _read_json_optional(session_root / "readiness.json", artifact_issues)
    workflow_guard = _read_json_optional(
        session_root / "workflow_guard.json",
        artifact_issues,
    )
    auto_start_setup = _read_json_optional(
        session_root / "auto_start_setup.json",
        artifact_issues,
    )
    headless_status = _read_json_optional(
        session_root / "headless_status.json",
        artifact_issues,
    )
    verdict, phase, reason = _classify(
        session_root=session_root,
        manifest=manifest,
        audit=audit,
        finalize=finalize,
        gate=gate,
        passive_apply=passive_apply,
        passive_baseline_mark=passive_baseline_mark,
        workflow_guard=workflow_guard,
    )
    if artifact_issues:
        verdict = "incomplete"
        phase = "artifact_json"
        reason = artifact_issues[0]
    checklist = audit.get("checklist") if isinstance(audit.get("checklist"), dict) else {}
    passive_apply_result = (
        passive_apply.get("result") if isinstance(passive_apply, dict) else None
    )
    passive_baseline_mark_result = (
        passive_baseline_mark.get("result")
        if isinstance(passive_baseline_mark, dict)
        else None
    )
    blocking_stage, next_action = _next_action(
        verdict=verdict,
        phase=phase,
        audit=audit,
        manifest=manifest,
        readiness=readiness,
    )
    if phase == "workflow_guard" and isinstance(workflow_guard, dict):
        blocking_stage = "workflow_guard"
        next_action = str(
            workflow_guard.get("nextAction")
            or "adjust passive session configuration before opening the microphone"
        )
    return {
        "verdict": verdict,
        "phase": phase,
        "reason": reason,
        "sessionRoot": str(session_root),
        "blockingStage": blocking_stage,
        "nextAction": next_action,
        "auditVerdict": audit.get("verdict"),
        "readinessJson": isinstance(readiness, dict),
        "readinessVerdict": (
            readiness.get("verdict") if isinstance(readiness, dict) else None
        ),
        "readinessStage": (
            readiness.get("stage") if isinstance(readiness, dict) else None
        ),
        "readinessNextAction": (
            readiness.get("nextAction") if isinstance(readiness, dict) else None
        ),
        "readinessPassiveEvidenceIntent": (
            readiness.get("passiveEvidenceIntent")
            if isinstance(readiness, dict)
            else None
        ),
        "readinessPassiveEvidenceIntentSource": (
            readiness.get("passiveEvidenceIntentSource")
            if isinstance(readiness, dict)
            else None
        ),
        "readinessBaselineRequired": (
            readiness.get("baselineRequired") if isinstance(readiness, dict) else None
        ),
        "readinessPassiveCanApply": (
            readiness.get("passiveCanApply") if isinstance(readiness, dict) else None
        ),
        "readinessRecommendedWorkflow": (
            readiness.get("recommendedWorkflow")
            if isinstance(readiness, dict)
            else None
        ),
        "readinessRecommendedSessionMode": (
            readiness.get("recommendedSessionMode")
            if isinstance(readiness, dict)
            else None
        ),
        "readinessRequiresBaselineStore": (
            readiness.get("requiresBaselineStore")
            if isinstance(readiness, dict)
            else None
        ),
        "readinessAllowsPassiveApply": (
            readiness.get("allowsPassiveApply")
            if isinstance(readiness, dict)
            else None
        ),
        "workflowGuardJson": isinstance(workflow_guard, dict),
        "workflowGuardVerdict": (
            workflow_guard.get("verdict") if isinstance(workflow_guard, dict) else None
        ),
        "workflowGuardMode": (
            workflow_guard.get("mode") if isinstance(workflow_guard, dict) else None
        ),
        "workflowGuardReason": (
            workflow_guard.get("reason") if isinstance(workflow_guard, dict) else None
        ),
        "workflowGuardNextAction": (
            workflow_guard.get("nextAction") if isinstance(workflow_guard, dict) else None
        ),
        "syncContextState": (
            gate.get("syncContextState")
            if isinstance(gate, dict)
            else readiness.get("syncContextState")
            if isinstance(readiness, dict)
            else None
        ),
        "syncContextReason": (
            readiness.get("syncContextReason") if isinstance(readiness, dict) else None
        ),
        "syncContextRevision": (
            gate.get("syncContextRevision")
            if isinstance(gate, dict)
            else readiness.get("syncContextRevision")
            if isinstance(readiness, dict)
            else None
        ),
        "autoStartCapturePreflightVerdict": audit.get(
            "auto_start_capture_preflight_verdict"
        ),
        "autoStartSetupVerdict": audit.get("auto_start_setup_verdict"),
        "autoStartSetupReason": (
            auto_start_setup.get("reason")
            if isinstance(auto_start_setup, dict)
            else None
        ),
        "autoStartPreflightVerdict": audit.get("auto_start_preflight_verdict"),
        "autoStartSetupJson": checklist.get("auto_start_setup_json") is True,
        "directLaunchStderr": (
            auto_start_setup.get("directLaunchStderr")
            if isinstance(auto_start_setup, dict)
            else None
        ),
        "directLaunchStderrTail": (
            auto_start_setup.get("directLaunchStderrTail")
            if isinstance(auto_start_setup, dict)
            else None
        ),
        "headlessLaunchStderr": (
            auto_start_setup.get("headlessLaunchStderr")
            if isinstance(auto_start_setup, dict)
            else None
        ),
        "headlessLaunchStderrTail": (
            auto_start_setup.get("headlessLaunchStderrTail")
            if isinstance(auto_start_setup, dict)
            else None
        ),
        "autoStartCapturePreflightJson": (
            checklist.get("auto_start_capture_preflight_json") is True
        ),
        "autoStartPreflightJson": checklist.get("auto_start_preflight_json") is True,
        "capturePreflightVerdict": audit.get("capture_preflight_verdict"),
        "capturePreflightJson": checklist.get("capture_preflight_json") is True,
        "finalizeVerdict": finalize.get("verdict") if isinstance(finalize, dict) else None,
        "gateVerdict": gate.get("verdict") if isinstance(gate, dict) else None,
        "passiveApplyVerdict": passive_apply.get("verdict")
        if isinstance(passive_apply, dict)
        else None,
        "passiveBaselineMarkVerdict": passive_baseline_mark.get("verdict")
        if isinstance(passive_baseline_mark, dict)
        else None,
        "recommendedDelayMs": gate.get("recommendedDelayMs")
        if isinstance(gate, dict)
        else None,
        "passiveApplyResult": passive_apply_result
        if isinstance(passive_apply_result, dict)
        else None,
        "passiveBaselineMarkResult": passive_baseline_mark_result
        if isinstance(passive_baseline_mark_result, dict)
        else None,
        "baselineKey": gate.get("baselineKey") if isinstance(gate, dict) else None,
        "emitsAudio": False,
        "appliesDelay": (
            isinstance(passive_apply, dict)
            and passive_apply.get("appliesDelay") is True
        ),
        "manifestNoAudio": checklist.get("manifest_no_audio") is True,
        "manifestNoDelayWrite": checklist.get("manifest_no_delay_write") is True,
        "manifestMicAfterPreflight": checklist.get("manifest_mic_after_preflight") is True,
        "manifestLaunchesAppDeclared": (
            checklist.get("manifest_launches_app_declared") is True
        ),
        "manifestChangesRoutesDeclared": (
            checklist.get("manifest_changes_routes_declared") is True
        ),
        "manifestChangesLaunchEnvironmentDeclared": (
            checklist.get("manifest_changes_launch_environment_declared") is True
        ),
        "manifestDefaultOutputSideEffectDeclared": (
            checklist.get("manifest_default_output_side_effect_declared") is True
        ),
        "manifestDefaultOutputReported": (
            checklist.get("manifest_default_output_reported") is True
        ),
        "launchesApp": (
            manifest.get("launchesApp") if isinstance(manifest, dict) else None
        ),
        "launchesHeadlessRuntime": (
            manifest.get("launchesHeadlessRuntime")
            if isinstance(manifest, dict)
            else None
        ),
        "appLaunchAttempted": (
            manifest.get("appLaunchAttempted") if isinstance(manifest, dict) else None
        ),
        "appLaunched": (
            manifest.get("appLaunched") if isinstance(manifest, dict) else None
        ),
        "headlessRuntimeLaunched": (
            manifest.get("headlessRuntimeLaunched")
            if isinstance(manifest, dict)
            else None
        ),
        "headlessStatusJson": isinstance(headless_status, dict),
        "headlessStatusStage": (
            headless_status.get("stage") if isinstance(headless_status, dict) else None
        ),
        "headlessStatusError": (
            headless_status.get("error") if isinstance(headless_status, dict) else None
        ),
        "headlessDiscoveredDeviceCount": (
            headless_status.get("discoveredDeviceCount")
            if isinstance(headless_status, dict)
            else None
        ),
        "headlessDirectCoreAudioOutputCount": (
            headless_status.get("directCoreAudioOutputCount")
            if isinstance(headless_status, dict)
            else None
        ),
        "headlessMissingTargets": (
            headless_status.get("missingTargets")
            if isinstance(headless_status, dict)
            else None
        ),
        "headlessDiscoveryErrors": (
            headless_status.get("discoveryErrors")
            if isinstance(headless_status, dict)
            else None
        ),
        "launchMethodRequested": (
            manifest.get("launchMethodRequested")
            if isinstance(manifest, dict)
            else None
        ),
        "launchMethodUsed": (
            manifest.get("launchMethodUsed") if isinstance(manifest, dict) else None
        ),
        "launchEnvironmentApplied": (
            manifest.get("launchEnvironmentApplied")
            if isinstance(manifest, dict)
            else None
        ),
        "changesRoutes": (
            manifest.get("changesRoutes") if isinstance(manifest, dict) else None
        ),
        "changesLaunchEnvironment": (
            manifest.get("changesLaunchEnvironment")
            if isinstance(manifest, dict)
            else None
        ),
        "mayChangeDefaultOutput": (
            manifest.get("mayChangeDefaultOutput")
            if isinstance(manifest, dict)
            else None
        ),
        "changesDefaultOutput": (
            manifest.get("changesDefaultOutput") if isinstance(manifest, dict) else None
        ),
        "defaultOutputReport": (
            manifest.get("defaultOutputReport") if isinstance(manifest, dict) else None
        ),
        "defaultOutputReadFailed": (
            manifest.get("defaultOutputReadFailed")
            if isinstance(manifest, dict)
            else None
        ),
        "defaultOutputVerified": (
            manifest.get("defaultOutputVerified") if isinstance(manifest, dict) else None
        ),
        "defaultOutputSetupSkipped": (
            manifest.get("defaultOutputSetupSkipped")
            if isinstance(manifest, dict)
            else None
        ),
        "issues": [*list(audit.get("issues") or []), *artifact_issues],
    }


def _exit_code(verdict: str) -> int:
    if verdict in {
        "applied",
        "baseline_mark_dry_run_ready",
        "baseline_recorded",
        "dry_run_ready",
        "hold",
        "pending_confirmation",
        "ready_for_baseline",
        "ready_for_apply_candidate",
    }:
        return EXIT_OK
    if verdict == "capture_failed":
        return EXIT_CAPTURE_FAILED
    return EXIT_NOT_READY


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a final passive control report for a session directory."
    )
    parser.add_argument("session_root", type=Path)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        report = build_report(args.session_root)
        if args.output is not None:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(json.dumps(report, indent=2, sort_keys=True))
        return _exit_code(str(report["verdict"]))
    except Exception as exc:
        payload = {"verdict": "bad_input", "error": str(exc)}
        if args.output is not None:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        print(json.dumps(payload, indent=2), file=sys.stderr)
        return EXIT_BAD_INPUT


if __name__ == "__main__":
    raise SystemExit(main())
