#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

import passive_apply_candidate as pac
import passive_capture_estimate as pce


EXIT_OK = 0
EXIT_NOT_READY = 2
EXIT_ERROR = 3


def _default_socket_path() -> Path:
    import os

    return Path(f"/tmp/syncast-{os.getuid()}.calibration.sock")


def _number(value: Any, field: str) -> int:
    return pac._number(value, field)


def rollback_params(
    status: dict[str, Any],
    *,
    target_delay_ms: int,
    expected_current_delay_ms: int,
    expected: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if status.get("ok") is not True:
        raise RuntimeError(f"passive_status returned unexpected result: {status!r}")
    current_delay = _number(status.get("currentDelayMs"), "currentDelayMs")
    if current_delay != expected_current_delay_ms:
        raise RuntimeError(
            "rollback current delay mismatch: "
            f"expected={expected_current_delay_ms} actual={current_delay}"
        )
    sync_state = str(status.get("syncContextState") or "")
    if sync_state != "applied":
        raise RuntimeError(
            "rollback requires syncContextState=applied: "
            f"{sync_state or '<missing>'}"
        )
    active = _number(status.get("activeAirplayCount"), "activeAirplayCount")
    enabled = _number(status.get("enabledAirplayCount"), "enabledAirplayCount")
    if active != enabled:
        raise RuntimeError(
            "rollback requires all enabled AirPlay receivers connected: "
            f"{active}/{enabled}"
        )
    if status.get("delayLocked") is True:
        raise RuntimeError("rollback requires unlocked delay")

    backend = str(status.get("captureBackend") or "").strip()
    context = str(status.get("contextSignature") or "").strip()
    if not backend:
        raise RuntimeError("rollback missing captureBackend")
    if not context:
        raise RuntimeError("rollback missing contextSignature")

    expected_values = expected or {}
    numeric_status_fields = {
        "enabledAirplayCount",
        "activeAirplayCount",
        "airplayTimingEpoch",
        "syncContextRevision",
    }
    for field, expected_value in expected_values.items():
        if expected_value is None:
            continue
        if field in numeric_status_fields:
            actual = _number(status.get(field), field)
            expected_number = _number(expected_value, field)
            if actual != expected_number:
                raise RuntimeError(
                    "rollback runtime context mismatch: "
                    f"{field} expected={expected_number} actual={actual}"
                )
            continue
        actual = str(status.get(field) or "").strip()
        expected_text = str(expected_value or "").strip()
        if actual != expected_text:
            raise RuntimeError(
                "rollback runtime context mismatch: "
                f"{field} expected={expected_text!r} actual={actual!r}"
            )

    return {
        "targetDelayMs": int(target_delay_ms),
        "currentDelayMs": current_delay,
        "contextSignature": context,
        "delayLocked": False,
        "enabledAirplayCount": enabled,
        "activeAirplayCount": active,
        "airplayTimingEpoch": _number(
            status.get("airplayTimingEpoch"),
            "airplayTimingEpoch",
        ),
        "captureBackend": backend,
        "syncContextState": sync_state,
        "syncContextRevision": _number(
            status.get("syncContextRevision"),
            "syncContextRevision",
        ),
        "dryRun": False,
    }


def rollback_delay(
    *,
    socket_path: Path,
    target_delay_ms: int,
    expected_current_delay_ms: int,
    expected: dict[str, Any] | None = None,
) -> dict[str, Any]:
    status = pce._json_rpc(
        socket_path,
        "passive_status",
        {},
        timeout_sec=2.0,
    )
    params = rollback_params(
        status,
        target_delay_ms=target_delay_ms,
        expected_current_delay_ms=expected_current_delay_ms,
        expected=expected,
    )
    response = pac._json_rpc(socket_path, "passive_apply_candidate", params)
    if "error" in response:
        error = response["error"]
        raise RuntimeError(
            "passive rollback failed: "
            f"{error.get('code')} {error.get('message')}"
        )
    result = response.get("result")
    if not isinstance(result, dict):
        raise RuntimeError("passive rollback reply missing result object")
    if result.get("applied") is True or result.get("wouldApply") is True:
        mismatch = pac._positive_result_mismatch(params, result, dry_run=False)
        if mismatch is not None:
            raise RuntimeError(f"passive rollback result context mismatch: {mismatch}")
    verdict = "rolled_back" if result.get("applied") is True else "not_applied"
    return {
        "schema": "syncast.passive_rollback_delay.v1",
        "verdict": verdict,
        "expected": expected or {},
        "request": params,
        "result": result,
        "emitsAudio": False,
        "opensMicrophone": False,
        "appliesDelay": result.get("applied") is True,
    }


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Restore the previous Local+AirPlay delay after a guarded passive "
            "apply fails post-apply validation."
        )
    )
    parser.add_argument("--socket", type=Path, default=_default_socket_path())
    parser.add_argument("--target-delay-ms", type=int, required=True)
    parser.add_argument("--expected-current-delay-ms", type=int, required=True)
    parser.add_argument("--expected-context-signature")
    parser.add_argument("--expected-capture-backend")
    parser.add_argument("--expected-enabled-airplay-count", type=int)
    parser.add_argument("--expected-active-airplay-count", type=int)
    parser.add_argument("--expected-airplay-timing-epoch", type=int)
    parser.add_argument("--expected-sync-context-revision", type=int)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def _expected_from_args(args: argparse.Namespace) -> dict[str, Any]:
    pairs = {
        "contextSignature": args.expected_context_signature,
        "captureBackend": args.expected_capture_backend,
        "enabledAirplayCount": args.expected_enabled_airplay_count,
        "activeAirplayCount": args.expected_active_airplay_count,
        "airplayTimingEpoch": args.expected_airplay_timing_epoch,
        "syncContextRevision": args.expected_sync_context_revision,
    }
    return {key: value for key, value in pairs.items() if value is not None}


def main() -> int:
    args = _parse_args()
    try:
        payload = rollback_delay(
            socket_path=args.socket,
            target_delay_ms=args.target_delay_ms,
            expected_current_delay_ms=args.expected_current_delay_ms,
            expected=_expected_from_args(args),
        )
        if args.output is not None:
            _write_json(args.output, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return EXIT_OK if payload["verdict"] == "rolled_back" else EXIT_NOT_READY
    except Exception as exc:
        payload = {
            "schema": "syncast.passive_rollback_delay.v1",
            "verdict": "error",
            "error": str(exc),
            "emitsAudio": False,
            "opensMicrophone": False,
            "appliesDelay": False,
        }
        if args.output is not None:
            _write_json(args.output, payload)
        print(json.dumps(payload, indent=2, sort_keys=True), file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    raise SystemExit(main())
