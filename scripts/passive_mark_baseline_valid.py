#!/usr/bin/env python3
"""Mark SyncCast's runtime sync context valid after a safe passive baseline.

This helper never emits audio, opens the microphone, or writes delay. It only
calls the local diagnostic socket with the route/timing context captured in an
audited `baseline_recorded` passive session. The app re-checks the live route
before changing its in-memory sync context.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from pathlib import Path
from typing import Any

import passive_control_report as pcr


EXIT_OK = 0
EXIT_BAD_INPUT = 2
EXIT_NOT_READY = 3
EXIT_RPC_FAILED = 4


def _default_socket_path() -> Path:
    return Path(f"/tmp/syncast-{os.getuid()}.calibration.sock")


def _read_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text())
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected JSON object")
    return payload


def _read_json_optional(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    return _read_json(path)


def _int_value(value: Any, field: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"{field} must be numeric")
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            pass
    raise ValueError(f"{field} must be an integer")


def _required_str(payload: dict[str, Any], field: str) -> str:
    value = payload.get(field)
    if not isinstance(value, str) or not value:
        raise ValueError(f"baseline missing required field {field}")
    return value


def _baseline_from_finalize(session_root: Path) -> dict[str, Any]:
    finalize = _read_json(session_root / "finalize.json")
    result = finalize.get("result")
    if not isinstance(result, dict):
        raise ValueError("finalize.json missing result object")
    baseline = result.get("baseline")
    if not isinstance(baseline, dict):
        raise ValueError("finalize.json missing baseline object")
    return baseline


def baseline_mark_params(session_root: Path, *, dry_run: bool) -> dict[str, Any]:
    report = pcr.build_report(session_root)
    if report.get("verdict") != "baseline_recorded":
        raise RuntimeError(
            "passive session is not ready to mark baseline valid: "
            f"{report.get('verdict')} ({report.get('reason')})"
        )

    baseline = _baseline_from_finalize(session_root)
    if baseline.get("delayLocked") is not False:
        raise ValueError("recorded baseline must have delayLocked=false")

    params: dict[str, Any] = {
        "currentDelayMs": _int_value(
            baseline.get("currentDelayMs"),
            "currentDelayMs",
        ),
        "contextSignature": _required_str(baseline, "contextSignature"),
        "delayLocked": False,
        "enabledAirplayCount": _int_value(
            baseline.get("enabledAirplayCount"),
            "enabledAirplayCount",
        ),
        "airplayTimingEpoch": _int_value(
            baseline.get("airplayTimingEpoch"),
            "airplayTimingEpoch",
        ),
        "captureBackend": _required_str(baseline, "captureBackend"),
        "syncContextState": _required_str(baseline, "syncContextState"),
        "syncContextRevision": _int_value(
            baseline.get("syncContextRevision"),
            "syncContextRevision",
        ),
        "dryRun": dry_run,
        "reason": (
            "passive baseline recorded for current Local+AirPlay route"
            f" ({baseline.get('key', 'unknown')})"
        ),
    }

    readiness = _read_json_optional(session_root / "readiness.json")
    if isinstance(readiness, dict) and readiness.get("activeAirplayCount") is not None:
        params["activeAirplayCount"] = _int_value(
            readiness.get("activeAirplayCount"),
            "activeAirplayCount",
        )
    if baseline.get("baselineOffsetMs") is not None:
        params["baselineOffsetMs"] = baseline.get("baselineOffsetMs")
    if baseline.get("key"):
        params["baselineKey"] = str(baseline["key"])
    return params


def _json_rpc(socket_path: Path, method: str, params: dict[str, Any]) -> dict[str, Any]:
    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    }
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(10)
        sock.connect(str(socket_path))
        sock.sendall((json.dumps(request, sort_keys=True) + "\n").encode("utf-8"))
        chunks = []
        while True:
            data = sock.recv(65536)
            if not data:
                break
            chunks.append(data)
            if b"\n" in data:
                break
    raw = b"".join(chunks).split(b"\n", 1)[0].decode("utf-8", errors="replace")
    if not raw:
        raise RuntimeError(f"empty RPC reply from {socket_path}")
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise RuntimeError("RPC reply was not a JSON object")
    return payload


def _baseline_mark_result_mismatch(
    params: dict[str, Any],
    result: dict[str, Any],
    *,
    dry_run: bool,
) -> str | None:
    if result.get("accepted") is not True:
        return "accepted"
    if result.get("dryRun") is not dry_run:
        return "dryRun"
    if result.get("emitsAudio") is not False:
        return "emitsAudio"
    if result.get("opensMicrophone") is not False:
        return "opensMicrophone"
    if result.get("appliesDelay") is not False:
        return "appliesDelay"
    if result.get("delayLocked") is not False:
        return "delayLocked"

    number_pairs = [
        ("currentDelayMs", "currentDelayMs"),
        ("enabledAirplayCount", "enabledAirplayCount"),
        ("airplayTimingEpoch", "airplayTimingEpoch"),
    ]
    for result_field, request_field in number_pairs:
        try:
            expected = _int_value(params[request_field], request_field)
            actual = _int_value(result.get(result_field), result_field)
        except (KeyError, ValueError):
            return result_field
        if actual != expected:
            return result_field

    active_expected = params.get("activeAirplayCount", params.get("enabledAirplayCount"))
    try:
        expected_active = _int_value(active_expected, "activeAirplayCount")
        actual_active = _int_value(result.get("activeAirplayCount"), "activeAirplayCount")
    except ValueError:
        return "activeAirplayCount"
    if actual_active != expected_active:
        return "activeAirplayCount"

    string_pairs = [
        ("contextSignature", "contextSignature"),
        ("captureBackend", "captureBackend"),
    ]
    for result_field, request_field in string_pairs:
        if str(result.get(result_field) or "") != str(params.get(request_field) or ""):
            return result_field

    request_state = str(params.get("syncContextState") or "")
    try:
        request_revision = _int_value(
            params.get("syncContextRevision"),
            "syncContextRevision",
        )
    except ValueError:
        return "syncContextRevision"

    if dry_run:
        if result.get("applied") is True:
            return "applied"
        if str(result.get("syncContextState") or "") != request_state:
            return "syncContextState"
        try:
            result_revision = _int_value(
                result.get("syncContextRevision"),
                "syncContextRevision",
            )
        except ValueError:
            return "syncContextRevision"
        if result_revision != request_revision:
            return "syncContextRevision"
        return None

    if result.get("applied") is not True:
        return "applied"
    if str(result.get("previousSyncContextState") or "") != request_state:
        return "previousSyncContextState"
    try:
        previous_revision = _int_value(
            result.get("previousSyncContextRevision"),
            "previousSyncContextRevision",
        )
        marked_revision = _int_value(
            result.get("syncContextRevision"),
            "syncContextRevision",
        )
    except ValueError as exc:
        message = str(exc)
        if "previousSyncContextRevision" in message:
            return "previousSyncContextRevision"
        return "syncContextRevision"
    if previous_revision != request_revision:
        return "previousSyncContextRevision"
    if str(result.get("syncContextState") or "") != "valid":
        return "syncContextState"
    if request_state != "valid":
        if marked_revision <= request_revision:
            return "syncContextRevision"
    elif marked_revision < request_revision:
        return "syncContextRevision"
    return None


def mark_baseline(
    session_root: Path,
    *,
    socket_path: Path,
    dry_run: bool,
) -> dict[str, Any]:
    params = baseline_mark_params(session_root, dry_run=dry_run)
    response = _json_rpc(socket_path, "passive_mark_baseline_valid", params)
    if "error" in response:
        error = response["error"]
        raise RuntimeError(
            "passive_mark_baseline_valid failed: "
            f"{error.get('code')} {error.get('message')}"
        )
    result = response.get("result")
    if not isinstance(result, dict):
        raise RuntimeError("passive_mark_baseline_valid reply missing result object")
    if result.get("accepted") is True or result.get("applied") is True:
        mismatch = _baseline_mark_result_mismatch(params, result, dry_run=dry_run)
        if mismatch is not None:
            raise RuntimeError(
                "passive_mark_baseline_valid result context mismatch: "
                f"{mismatch}"
            )
    verdict = "not_marked"
    if result.get("applied") is True:
        verdict = "marked_valid"
    elif result.get("accepted") is True and result.get("dryRun") is True:
        verdict = "dry_run_ready"
    return {
        "verdict": verdict,
        "sessionRoot": str(session_root),
        "socket": str(socket_path),
        "dryRun": dry_run,
        "request": params,
        "result": result,
        "emitsAudio": False,
        "opensMicrophone": False,
        "appliesDelay": False,
    }


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Mark app sync context valid after a recorded passive baseline."
    )
    parser.add_argument("session_root", type=Path)
    parser.add_argument("--socket", type=Path, default=_default_socket_path())
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        payload = mark_baseline(
            args.session_root,
            socket_path=args.socket,
            dry_run=args.dry_run,
        )
        if args.output is not None:
            _write_json(args.output, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return EXIT_OK if payload["verdict"] in {"marked_valid", "dry_run_ready"} else EXIT_NOT_READY
    except (ValueError, FileNotFoundError) as exc:
        payload = {"verdict": "bad_input", "error": str(exc)}
        if args.output is not None:
            _write_json(args.output, payload)
        print(json.dumps(payload, indent=2), file=sys.stderr)
        return EXIT_BAD_INPUT
    except RuntimeError as exc:
        payload = {"verdict": "not_ready", "error": str(exc)}
        if args.output is not None:
            _write_json(args.output, payload)
        print(json.dumps(payload, indent=2), file=sys.stderr)
        return EXIT_NOT_READY
    except OSError as exc:
        payload = {"verdict": "rpc_failed", "error": str(exc)}
        if args.output is not None:
            _write_json(args.output, payload)
        print(json.dumps(payload, indent=2), file=sys.stderr)
        return EXIT_RPC_FAILED


if __name__ == "__main__":
    raise SystemExit(main())
