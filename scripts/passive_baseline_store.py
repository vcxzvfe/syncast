#!/usr/bin/env python3
"""Maintain no-write passive calibration baselines.

The passive decision layer needs a known-good relative baseline before it can
turn later monitor reports into bounded correction candidates. This helper
stores those baselines in a JSON file keyed by stable route identity. It never
writes SyncCast defaults and never calls the Router.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
import time
from pathlib import Path
from typing import Any

import passive_delay_decision as pdd
import passive_session_audit as psa


EXIT_OK = 0
EXIT_BAD_INPUT = 2
EXIT_NOT_APPLICABLE = 3

STORE_SCHEMA = "syncast.passive_baseline_store.v1"
BASELINE_IDENTITY_FIELDS = (
    ("contextSignature", "context_signature"),
    ("captureBackend", "capture_backend"),
    ("delayLocked", "delay_locked"),
    ("enabledAirplayCount", "enabled_airplay_count"),
    ("activeAirplayCount", "active_airplay_count"),
    ("airplayTimingEpoch", "airplay_timing_epoch"),
)


def _number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return float(value)
    return None


def _read_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text())
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected JSON object")
    return payload


def _load_store(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schema": STORE_SCHEMA, "baselines": {}}
    store = _read_json(path)
    if store.get("schema") != STORE_SCHEMA:
        raise ValueError(f"unsupported baseline store schema: {store.get('schema')!r}")
    if not isinstance(store.get("baselines"), dict):
        raise ValueError("baseline store must contain object 'baselines'")
    return store


def _write_store(path: Path, store: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(store, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def _baseline_key(features: dict[str, Any]) -> str:
    # A passive baseline describes the acoustic relationship for a stable
    # route. The runtime sync context is freshness evidence for later apply
    # guards, not part of baseline identity: baseline marking changes
    # suspect->valid and increments the revision without changing the route.
    material = {
        baseline_field: features.get(feature_field)
        for baseline_field, feature_field in BASELINE_IDENTITY_FIELDS
    }
    raw = json.dumps(material, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:24]


def _same_baseline_identity(
    baseline: dict[str, Any],
    features: dict[str, Any],
) -> bool:
    return all(
        baseline.get(baseline_field) == features.get(feature_field)
        for baseline_field, feature_field in BASELINE_IDENTITY_FIELDS
    )


def _latest_matching_baseline(
    store: dict[str, Any],
    features: dict[str, Any],
) -> dict[str, Any] | None:
    matches = [
        candidate
        for candidate in store["baselines"].values()
        if isinstance(candidate, dict) and _same_baseline_identity(candidate, features)
    ]
    if not matches:
        return None
    return max(
        matches,
        key=lambda candidate: (
            _number(candidate.get("updatedUnix"))
            or _number(candidate.get("createdUnix"))
            or 0.0
        ),
    )


def _monitor_payload(session_root: Path) -> dict[str, Any]:
    monitor_path = session_root / "monitor.json"
    if not monitor_path.exists():
        raise FileNotFoundError(f"monitor report not found: {monitor_path}")
    return _read_json(monitor_path)


def _safe_audit(session_root: Path) -> dict[str, Any]:
    audit = psa.audit_session(session_root)
    if audit.get("verdict") not in {
        "ready_for_baseline",
        "ready_for_correction",
        "hold",
    }:
        raise pdd.DecisionRejected(
            f"session audit is not usable for passive baselines: "
            f"{audit.get('verdict')} ({audit.get('reason')})"
        )
    checklist = audit.get("checklist") or {}
    for key in (
        "manifest_no_audio",
        "manifest_no_delay_write",
        "manifest_mic_after_preflight",
    ):
        if checklist.get(key) is not True:
            raise pdd.DecisionRejected(f"session audit safety check failed: {key}")
    return audit


def _baseline_from_session(session_root: Path) -> dict[str, Any]:
    audit = _safe_audit(session_root)
    if audit.get("verdict") != "ready_for_baseline":
        raise pdd.DecisionRejected(
            f"session is not baseline-ready: {audit.get('verdict')} ({audit.get('reason')})"
        )
    decision = pdd.decide(_monitor_payload(session_root))
    if decision.get("verdict") != "initialize_baseline":
        raise pdd.DecisionRejected(
            f"session decision is not a baseline initializer: {decision.get('verdict')}"
        )
    features = decision.get("features")
    if not isinstance(features, dict):
        raise ValueError("baseline decision is missing features")
    baseline_offset = _number(decision.get("baseline_offset_ms"))
    if baseline_offset is None:
        raise ValueError("baseline decision is missing numeric baseline_offset_ms")
    key = _baseline_key(features)
    now = round(time.time(), 3)
    return {
        "key": key,
        "createdUnix": now,
        "updatedUnix": now,
        "sessionRoot": str(session_root),
        "contextSignature": features["context_signature"],
        "captureBackend": features["capture_backend"],
        "delayLocked": features["delay_locked"],
        "enabledAirplayCount": features["enabled_airplay_count"],
        "activeAirplayCount": features["active_airplay_count"],
        "airplayTimingEpoch": features["airplay_timing_epoch"],
        "syncContextState": features["sync_context_state"],
        "syncContextRevision": features["sync_context_revision"],
        "baselineOffsetMs": round(baseline_offset, 3),
        "baselinePathPairDeltaMs": decision.get("baseline_path_pair_delta_ms"),
        "decisionBasis": decision.get("decision_basis"),
        "measuredDelayMs": features["measured_delay_ms"],
        "currentDelayMs": features["current_delay_ms"],
        "samplesAccepted": features["samples_accepted"],
        "delayRangeMs": features["delay_range_ms"],
        "emitsAudio": False,
        "appliesDelay": False,
    }


def record_baseline(store_path: Path, session_root: Path) -> dict[str, Any]:
    entry = _baseline_from_session(session_root)
    store = _load_store(store_path)
    existing = store["baselines"].get(entry["key"])
    if isinstance(existing, dict) and existing.get("createdUnix") is not None:
        entry["createdUnix"] = existing["createdUnix"]
    store["baselines"][entry["key"]] = entry
    _write_store(store_path, store)
    return {
        "verdict": "recorded",
        "store": str(store_path),
        "baseline": entry,
    }


def decide_with_store(store_path: Path, session_root: Path) -> dict[str, Any]:
    _safe_audit(session_root)
    monitor = _monitor_payload(session_root)
    probe_decision = pdd.decide(monitor)
    features = probe_decision.get("features")
    if not isinstance(features, dict):
        raise ValueError("passive decision is missing features")
    key = _baseline_key(features)
    store = _load_store(store_path)
    baseline = store["baselines"].get(key)
    if not isinstance(baseline, dict):
        baseline = _latest_matching_baseline(store, features)
    if not isinstance(baseline, dict):
        raise pdd.DecisionRejected(
            "no passive baseline for this route/backend/AirPlay context"
        )
    baseline_offset = _number(baseline.get("baselineOffsetMs"))
    if baseline_offset is None:
        raise ValueError(f"stored baseline {key} has invalid baselineOffsetMs")
    baseline_path_pair_delta = _number(baseline.get("baselinePathPairDeltaMs"))
    current_path_pair_delta = _number(features.get("path_pair_delta_ms"))
    if current_path_pair_delta is not None and baseline_path_pair_delta is None:
        raise pdd.DecisionRejected(
            "stored passive baseline lacks Local/AirPlay path-pair metadata; "
            "record a new baseline before deciding correction"
        )
    decision = pdd.decide(
        monitor,
        baseline_offset_ms=baseline_offset,
        baseline_path_pair_delta_ms=baseline_path_pair_delta,
    )
    return {
        "verdict": "decided",
        "store": str(store_path),
        "baseline": baseline,
        "decision": decision,
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Record or reuse passive relative-delay baselines."
    )
    parser.add_argument("--store", type=Path, required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    record = sub.add_parser("record", help="record a baseline from a session")
    record.add_argument("session_root", type=Path)
    decide = sub.add_parser("decide", help="decide using a stored baseline")
    decide.add_argument("session_root", type=Path)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        if args.command == "record":
            result = record_baseline(args.store, args.session_root)
        elif args.command == "decide":
            result = decide_with_store(args.store, args.session_root)
        else:
            raise ValueError(f"unknown command: {args.command}")
        print(json.dumps(result, indent=2, sort_keys=True))
        decision = result.get("decision")
        if isinstance(decision, dict) and decision.get("verdict") == "reject":
            return EXIT_NOT_APPLICABLE
        return EXIT_OK
    except pdd.DecisionRejected as exc:
        print(
            json.dumps({"verdict": "not_applicable", "error": str(exc)}, indent=2),
            file=sys.stderr,
        )
        return EXIT_NOT_APPLICABLE
    except Exception as exc:
        print(
            json.dumps({"verdict": "bad_input", "error": str(exc)}, indent=2),
            file=sys.stderr,
        )
        return EXIT_BAD_INPUT


if __name__ == "__main__":
    raise SystemExit(main())
