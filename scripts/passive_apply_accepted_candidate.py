#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import sys
import time
from typing import Any

import passive_capture_estimate as pce
import passive_readiness_report as readiness_report


EXIT_OK = 0
EXIT_NOT_READY = 2
EXIT_ERROR = 3
ACCEPTED_DRY_RUN_MAX_AGE_SEC = 120.0
ACCEPTED_DRY_RUN_FUTURE_SKEW_SEC = 5.0


def _default_socket_path() -> Path:
    import os

    return Path(f"/tmp/syncast-{os.getuid()}.calibration.sock")


def _number(value: Any, name: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be a number")
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str) and value.strip():
        return int(value.strip())
    raise ValueError(f"{name} must be a number")


def _float_number(value: Any, name: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be a number")
    if isinstance(value, (int, float)):
        result = float(value)
    elif isinstance(value, str) and value.strip():
        result = float(value.strip())
    else:
        raise ValueError(f"{name} must be a number")
    if not math.isfinite(result):
        raise ValueError(f"{name} must be finite")
    return result


def _required_str(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if isinstance(value, str) and value.strip():
        return value.strip()
    raise ValueError(f"readiness is missing {key}")


def _validate_expected_readiness(
    readiness: dict[str, Any],
    expected: dict[str, Any] | None,
) -> None:
    if not expected:
        return
    number_fields = {
        "passiveDryRunTargetDelayMs",
        "passiveDryRunCurrentDelayMs",
        "passiveDryRunEnabledAirplayCount",
        "passiveDryRunActiveAirplayCount",
        "passiveDryRunAirplayTimingEpoch",
        "passiveDryRunAcceptedSyncContextRevision",
    }
    float_fields = {
        "passiveDryRunAcceptedUnix",
    }
    for field, expected_value in expected.items():
        if expected_value is None:
            continue
        if field in number_fields:
            actual = _number(readiness.get(field), field)
            expected_number = _number(expected_value, field)
            if actual != expected_number:
                raise RuntimeError(
                    "accepted candidate readiness mismatch: "
                    f"{field} expected={expected_number} actual={actual}"
                )
            continue
        if field in float_fields:
            actual = _float_number(readiness.get(field), field)
            expected_float = _float_number(expected_value, field)
            if abs(actual - expected_float) > 0.001:
                raise RuntimeError(
                    "accepted candidate readiness mismatch: "
                    f"{field} expected={expected_float} actual={actual}"
                )
            continue
        actual = str(readiness.get(field) or "").strip()
        expected_text = str(expected_value or "").strip()
        if actual != expected_text:
            raise RuntimeError(
                "accepted candidate readiness mismatch: "
                f"{field} expected={expected_text!r} actual={actual!r}"
            )


def build_params(readiness: dict[str, Any], *, dry_run: bool) -> dict[str, Any]:
    if readiness.get("verdict") != "ready":
        raise RuntimeError(
            "passive readiness is not ready: "
            f"{readiness.get('verdict')} ({readiness.get('reason')})"
        )
    if readiness.get("syncContextState") != "dryRunReady":
        raise RuntimeError(
            "accepted passive candidate requires syncContextState=dryRunReady: "
            f"{readiness.get('syncContextState')}"
        )
    if readiness.get("passiveEvidenceIntent") != "manual_validation_required":
        raise RuntimeError(
            "accepted passive candidate requires manual_validation_required "
            f"intent: {readiness.get('passiveEvidenceIntent')}"
        )
    accepted_unix = _float_number(
        readiness.get("passiveDryRunAcceptedUnix"),
        "passiveDryRunAcceptedUnix",
    )
    accepted_age_sec = time.time() - accepted_unix
    if accepted_age_sec < -ACCEPTED_DRY_RUN_FUTURE_SKEW_SEC:
        raise RuntimeError(
            "accepted passive candidate timestamp is in the future: "
            f"ageSec={accepted_age_sec:.3f}"
        )
    if accepted_age_sec > ACCEPTED_DRY_RUN_MAX_AGE_SEC:
        raise RuntimeError(
            "accepted passive candidate expired: "
            f"ageSec={accepted_age_sec:.3f} maxAgeSec={ACCEPTED_DRY_RUN_MAX_AGE_SEC:g}"
        )
    return {
        "targetDelayMs": _number(
            readiness.get("passiveDryRunTargetDelayMs"),
            "passiveDryRunTargetDelayMs",
        ),
        "currentDelayMs": _number(
            readiness.get("passiveDryRunCurrentDelayMs"),
            "passiveDryRunCurrentDelayMs",
        ),
        "contextSignature": _required_str(
            readiness,
            "passiveDryRunContextSignature",
        ),
        "captureBackend": _required_str(
            readiness,
            "passiveDryRunCaptureBackend",
        ),
        "enabledAirplayCount": _number(
            readiness.get("passiveDryRunEnabledAirplayCount"),
            "passiveDryRunEnabledAirplayCount",
        ),
        "activeAirplayCount": _number(
            readiness.get("passiveDryRunActiveAirplayCount"),
            "passiveDryRunActiveAirplayCount",
        ),
        "airplayTimingEpoch": _number(
            readiness.get("passiveDryRunAirplayTimingEpoch"),
            "passiveDryRunAirplayTimingEpoch",
        ),
        "acceptedSyncContextRevision": _number(
            readiness.get("passiveDryRunAcceptedSyncContextRevision"),
            "passiveDryRunAcceptedSyncContextRevision",
        ),
        "acceptedUnix": accepted_unix,
        "dryRun": dry_run,
    }


def _positive_result_mismatch(
    params: dict[str, Any],
    result: dict[str, Any],
    *,
    dry_run: bool,
) -> str | None:
    number_pairs = [
        ("targetDelayMs", "targetDelayMs"),
        ("currentDelayMs", "currentDelayMs"),
        ("enabledAirplayCount", "enabledAirplayCount"),
        ("activeAirplayCount", "activeAirplayCount"),
        ("airplayTimingEpoch", "airplayTimingEpoch"),
        ("syncContextRevision", "acceptedSyncContextRevision"),
    ]
    for result_field, request_field in number_pairs:
        try:
            expected = _number(params[request_field], request_field)
            actual = _number(result.get(result_field), result_field)
        except (KeyError, ValueError):
            return result_field
        if actual != expected:
            return result_field

    string_pairs = [
        ("contextSignature", "contextSignature"),
        ("captureBackend", "captureBackend"),
    ]
    for result_field, request_field in string_pairs:
        if str(result.get(result_field) or "") != str(params.get(request_field) or ""):
            return result_field

    if result.get("applied") is True:
        if dry_run:
            return "applied"
        if result.get("wouldApply") is not True:
            return "wouldApply"
        try:
            applied_delay = _number(result.get("appliedDelayMs"), "appliedDelayMs")
            target_delay = _number(params["targetDelayMs"], "targetDelayMs")
        except (KeyError, ValueError):
            return "appliedDelayMs"
        if applied_delay != target_delay:
            return "appliedDelayMs"
    elif result.get("wouldApply") is True and not dry_run:
        return "wouldApply"
    return None


def apply_accepted_candidate(
    *,
    readiness: dict[str, Any],
    socket_path: Path,
    dry_run: bool,
    expected: dict[str, Any] | None = None,
) -> dict[str, Any]:
    _validate_expected_readiness(readiness, expected)
    params = build_params(readiness, dry_run=dry_run)
    response = pce._json_rpc(socket_path, "passive_apply_accepted_candidate", params)
    if "error" in response:
        error = response["error"]
        if isinstance(error, dict):
            raise RuntimeError(
                "passive_apply_accepted_candidate failed: "
                f"{error.get('code')} {error.get('message')}"
            )
        raise RuntimeError(f"passive_apply_accepted_candidate failed: {error!r}")
    result = response.get("result")
    if not isinstance(result, dict):
        raise RuntimeError("passive_apply_accepted_candidate reply missing result object")
    if result.get("wouldApply") is True or result.get("applied") is True:
        mismatch = _positive_result_mismatch(params, result, dry_run=dry_run)
        if mismatch is not None:
            raise RuntimeError(
                "passive_apply_accepted_candidate result context mismatch: "
                f"{mismatch}"
            )
    return {
        "schema": "syncast.passive_apply_accepted_candidate.v1",
        "verdict": (
            "applied"
            if result.get("applied") is True
            else "dry_run_ready"
            if result.get("wouldApply") is True
            else "not_applied"
        ),
        "dryRun": dry_run,
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
            "Dry-run or explicitly apply the app runtime's accepted passive "
            "dry-run candidate without collecting another microphone corpus."
        )
    )
    parser.add_argument("--readiness-json", type=Path)
    parser.add_argument("--socket", type=Path, default=_default_socket_path())
    parser.add_argument("--app", type=Path, default=Path("/Applications/SyncCast.app"))
    parser.add_argument("--process-name", default="SyncCastMenuBar")
    parser.add_argument("--timeout-sec", type=float, default=2.0)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--expected-session-root")
    parser.add_argument("--expected-control-report")
    parser.add_argument("--expected-target-delay-ms", type=int)
    parser.add_argument("--expected-current-delay-ms", type=int)
    parser.add_argument("--expected-context-signature")
    parser.add_argument("--expected-capture-backend")
    parser.add_argument("--expected-enabled-airplay-count", type=int)
    parser.add_argument("--expected-active-airplay-count", type=int)
    parser.add_argument("--expected-airplay-timing-epoch", type=int)
    parser.add_argument("--expected-accepted-sync-context-revision", type=int)
    parser.add_argument("--expected-accepted-unix", type=float)
    return parser.parse_args()


def _expected_from_args(args: argparse.Namespace) -> dict[str, Any]:
    pairs = {
        "passiveDryRunSessionRoot": args.expected_session_root,
        "passiveDryRunControlReport": args.expected_control_report,
        "passiveDryRunTargetDelayMs": args.expected_target_delay_ms,
        "passiveDryRunCurrentDelayMs": args.expected_current_delay_ms,
        "passiveDryRunContextSignature": args.expected_context_signature,
        "passiveDryRunCaptureBackend": args.expected_capture_backend,
        "passiveDryRunEnabledAirplayCount": args.expected_enabled_airplay_count,
        "passiveDryRunActiveAirplayCount": args.expected_active_airplay_count,
        "passiveDryRunAirplayTimingEpoch": args.expected_airplay_timing_epoch,
        "passiveDryRunAcceptedSyncContextRevision": (
            args.expected_accepted_sync_context_revision
        ),
        "passiveDryRunAcceptedUnix": args.expected_accepted_unix,
    }
    return {key: value for key, value in pairs.items() if value is not None}


def main() -> int:
    args = _parse_args()
    try:
        if args.readiness_json is not None:
            readiness = json.loads(args.readiness_json.read_text())
        else:
            readiness = readiness_report.build_report(
                socket_path=args.socket,
                app_path=args.app,
                process_name=args.process_name,
                timeout_sec=args.timeout_sec,
            )
        payload = apply_accepted_candidate(
            readiness=readiness,
            socket_path=args.socket,
            dry_run=not args.apply,
            expected=_expected_from_args(args),
        )
        if args.output is not None:
            _write_json(args.output, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return EXIT_OK if payload["verdict"] in {"applied", "dry_run_ready"} else EXIT_NOT_READY
    except Exception as exc:
        payload = {
            "schema": "syncast.passive_apply_accepted_candidate.v1",
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
