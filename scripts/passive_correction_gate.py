#!/usr/bin/env python3
"""Require repeated passive correction agreement before any apply candidate.

This is still a no-write policy layer. It consumes the JSON artifact produced
by passive_session_finalize.py and maintains a tiny confirmation-state file.
One eligible recommendation only creates a pending candidate. A second eligible
recommendation for the same baseline key, same direction, and similar target
promotes the result to ready_for_apply_candidate.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path
from typing import Any


EXIT_OK = 0
EXIT_BAD_INPUT = 2
EXIT_NOT_READY = 3

STATE_SCHEMA = "syncast.passive_correction_gate.v1"
CONTEXT_FIELDS = (
    "contextSignature",
    "captureBackend",
    "delayLocked",
    "enabledAirplayCount",
    "activeAirplayCount",
    "airplayTimingEpoch",
    "syncContextState",
    "syncContextRevision",
)
BASELINE_IDENTITY_FIELDS = (
    ("contextSignature", "context_signature"),
    ("captureBackend", "capture_backend"),
    ("delayLocked", "delay_locked"),
    ("enabledAirplayCount", "enabled_airplay_count"),
    ("activeAirplayCount", "active_airplay_count"),
    ("airplayTimingEpoch", "airplay_timing_epoch"),
)


def _read_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text())
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected JSON object")
    return payload


def _load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schema": STATE_SCHEMA, "pending": {}}
    state = _read_json(path)
    if state.get("schema") != STATE_SCHEMA:
        raise ValueError(f"unsupported correction state schema: {state.get('schema')!r}")
    if not isinstance(state.get("pending"), dict):
        raise ValueError("correction state must contain object 'pending'")
    return state


def _write_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def _number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return float(value)
    return None


def _candidate_from_finalize(payload: dict[str, Any]) -> dict[str, Any] | None:
    if payload.get("verdict") != "decided":
        return None
    result = payload.get("result")
    if not isinstance(result, dict):
        return None
    baseline = result.get("baseline")
    decision = result.get("decision")
    if not isinstance(baseline, dict) or not isinstance(decision, dict):
        return None
    if decision.get("verdict") != "recommend":
        return None
    if decision.get("auto_apply_eligible") is not True:
        return None

    recommended = _number(decision.get("recommended_delay_ms"))
    correction = _number(decision.get("raw_correction_ms"))
    features = decision.get("features")
    if not isinstance(features, dict):
        raise ValueError("finalize decision is missing features")
    current_delay = _number(features.get("current_delay_ms"))
    baseline_key = baseline.get("key")
    if not isinstance(baseline_key, str) or not baseline_key:
        raise ValueError("finalize result baseline is missing key")
    session_root = payload.get("sessionRoot")
    if not isinstance(session_root, str) or not session_root:
        raise ValueError("finalize result is missing sessionRoot")
    if recommended is None or correction is None:
        raise ValueError("finalize decision is missing numeric recommendation/correction")
    if current_delay is None:
        raise ValueError("finalize decision is missing numeric current_delay_ms")
    baseline_delay_locked = baseline.get("delayLocked")
    feature_delay_locked = features.get("delay_locked")
    if baseline_delay_locked is not False or feature_delay_locked is not False:
        raise ValueError("finalize result is not apply-safe while delay lock is active or unknown")
    baseline_enabled = baseline.get("enabledAirplayCount")
    baseline_active = baseline.get("activeAirplayCount")
    feature_enabled = features.get("enabled_airplay_count")
    feature_active = features.get("active_airplay_count")
    if baseline_active != baseline_enabled or feature_active != feature_enabled:
        raise ValueError(
            "finalize result is not apply-safe while AirPlay receivers are inactive"
        )
    for baseline_field, feature_field in BASELINE_IDENTITY_FIELDS:
        if baseline.get(baseline_field) != features.get(feature_field):
            raise ValueError(
                "finalize baseline identity does not match current decision "
                f"features: {feature_field}"
            )
    sync_context_state = features.get("sync_context_state")
    sync_context_revision = features.get("sync_context_revision")
    if not isinstance(sync_context_state, str) or not sync_context_state:
        raise ValueError("finalize decision is missing sync_context_state")
    if type(sync_context_revision) is not int or sync_context_revision < 0:
        raise ValueError("finalize decision is missing sync_context_revision")
    if sync_context_state != "valid":
        return None
    if correction == 0:
        direction = 0
    else:
        direction = 1 if correction > 0 else -1
    return {
        "baselineKey": baseline_key,
        "recommendedDelayMs": int(round(recommended)),
        "rawCorrectionMs": round(correction, 3),
        "currentDelayMs": round(current_delay, 3),
        "direction": direction,
        "sessionRoot": session_root,
        "contextSignature": baseline.get("contextSignature"),
        "captureBackend": baseline.get("captureBackend"),
        "delayLocked": baseline.get("delayLocked"),
        "enabledAirplayCount": baseline.get("enabledAirplayCount"),
        "activeAirplayCount": baseline.get("activeAirplayCount"),
        "airplayTimingEpoch": baseline.get("airplayTimingEpoch"),
        "syncContextState": sync_context_state,
        "syncContextRevision": sync_context_revision,
    }


def _same_context(pending: dict[str, Any], candidate: dict[str, Any]) -> bool:
    return all(pending.get(field) == candidate.get(field) for field in CONTEXT_FIELDS)


def evaluate(
    *,
    finalize_payload: dict[str, Any],
    state_path: Path,
    max_repeat_delta_ms: float = 8.0,
    max_pending_age_sec: float = 1800.0,
) -> dict[str, Any]:
    if max_repeat_delta_ms < 0:
        raise ValueError("max_repeat_delta_ms must be >= 0")
    if max_pending_age_sec < 0:
        raise ValueError("max_pending_age_sec must be >= 0")
    state = _load_state(state_path)
    candidate = _candidate_from_finalize(finalize_payload)
    if candidate is None:
        # Holds, baseline recordings, rejects, and inapplicable finalizations
        # invalidate stale pending candidates for safety.
        if finalize_payload.get("verdict") in {"not_applicable", "bad_input"}:
            state["pending"] = {}
            _write_state(state_path, state)
            return {
                "verdict": "not_applicable",
                "reason": "finalize result is not usable; pending passive corrections cleared",
                "emitsAudio": False,
                "appliesDelay": False,
            }
        if finalize_payload.get("verdict") in {"recorded", "decided"}:
            result = finalize_payload.get("result")
            baseline = result.get("baseline") if isinstance(result, dict) else None
            key = baseline.get("key") if isinstance(baseline, dict) else None
            if isinstance(key, str):
                state["pending"].pop(key, None)
                _write_state(state_path, state)
        return {
            "verdict": "not_applicable",
            "reason": "finalize result does not contain an eligible recommendation",
            "emitsAudio": False,
            "appliesDelay": False,
        }

    key = candidate["baselineKey"]
    pending = state["pending"].get(key)
    now = round(time.time(), 3)
    candidate["updatedUnix"] = now
    if isinstance(pending, dict):
        created = _number(pending.get("createdUnix"))
        age = None if created is None else max(0.0, now - created)
        fresh = age is not None and age <= max_pending_age_sec
        same_direction = pending.get("direction") == candidate["direction"]
        same_current_delay = (
            _number(pending.get("currentDelayMs")) == candidate["currentDelayMs"]
        )
        different_session = pending.get("sessionRoot") != candidate["sessionRoot"]
        same_context = _same_context(pending, candidate)
        previous_delay = _number(pending.get("recommendedDelayMs"))
        close_enough = (
            previous_delay is not None
            and abs(previous_delay - candidate["recommendedDelayMs"]) <= max_repeat_delta_ms
        )
        if (
            fresh
            and different_session
            and same_context
            and same_direction
            and same_current_delay
            and close_enough
        ):
            state["pending"].pop(key, None)
            _write_state(state_path, state)
            return {
                "verdict": "ready_for_apply_candidate",
                "reason": "two passive recommendations agree",
                "baselineKey": key,
                "recommendedDelayMs": candidate["recommendedDelayMs"],
                "previousRecommendedDelayMs": int(round(previous_delay)),
                "repeatDeltaMs": round(
                    abs(previous_delay - candidate["recommendedDelayMs"]),
                    3,
                ),
                "pendingAgeSec": round(age, 3),
                "rawCorrectionMs": candidate["rawCorrectionMs"],
                "currentDelayMs": candidate["currentDelayMs"],
                "contextSignature": candidate.get("contextSignature"),
                "captureBackend": candidate.get("captureBackend"),
                "delayLocked": candidate.get("delayLocked"),
                "enabledAirplayCount": candidate.get("enabledAirplayCount"),
                "activeAirplayCount": candidate.get("activeAirplayCount"),
                "airplayTimingEpoch": candidate.get("airplayTimingEpoch"),
                "syncContextState": candidate.get("syncContextState"),
                "syncContextRevision": candidate.get("syncContextRevision"),
                "emitsAudio": False,
                "appliesDelay": False,
            }

    state["pending"][key] = {
        **candidate,
        "createdUnix": now,
    }
    _write_state(state_path, state)
    return {
        "verdict": "pending_confirmation",
        "reason": "first eligible passive recommendation recorded; repeat required",
        "baselineKey": key,
        "recommendedDelayMs": candidate["recommendedDelayMs"],
        "rawCorrectionMs": candidate["rawCorrectionMs"],
        "currentDelayMs": candidate["currentDelayMs"],
        "activeAirplayCount": candidate.get("activeAirplayCount"),
        "syncContextState": candidate.get("syncContextState"),
        "syncContextRevision": candidate.get("syncContextRevision"),
        "maxPendingAgeSec": max_pending_age_sec,
        "emitsAudio": False,
        "appliesDelay": False,
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Gate passive correction decisions behind repeat agreement."
    )
    parser.add_argument("finalize_json", type=Path)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--max-repeat-delta-ms", type=float, default=8.0)
    parser.add_argument("--max-pending-age-sec", type=float, default=1800.0)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        result = evaluate(
            finalize_payload=_read_json(args.finalize_json),
            state_path=args.state,
            max_repeat_delta_ms=args.max_repeat_delta_ms,
            max_pending_age_sec=args.max_pending_age_sec,
        )
        if args.output is not None:
            _write_state(args.output, result)
        print(json.dumps(result, indent=2, sort_keys=True))
        return EXIT_OK if result["verdict"] == "ready_for_apply_candidate" else EXIT_NOT_READY
    except Exception as exc:
        payload = {"verdict": "bad_input", "error": str(exc)}
        if args.output is not None:
            _write_state(args.output, payload)
        print(json.dumps(payload, indent=2), file=sys.stderr)
        return EXIT_BAD_INPUT


if __name__ == "__main__":
    raise SystemExit(main())
