#!/usr/bin/env python3
"""Apply a repeat-confirmed passive correction candidate through SyncCast RPC.

This is the only passive helper that can write delay, and it is deliberately
hard-gated:

- the session must audit as `ready_for_apply_candidate`;
- correction_gate.json must carry the route/timing context used for
  confirmation;
- the app-side `passive_apply_candidate` RPC re-checks current runtime context;
- CLI default is dry-run. Use --apply for the actual write.
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


def _number(value: Any, field: str) -> int:
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


def candidate_params(session_root: Path, *, dry_run: bool) -> dict[str, Any]:
    report = pcr.build_report(session_root)
    missing_own_dry_run = (
        report.get("verdict") == "incomplete"
        and report.get("phase") == "apply"
        and "dry-run artifact is missing" in str(report.get("reason") or "")
    )
    if (
        report.get("verdict") != "ready_for_apply_candidate"
        and not (dry_run and missing_own_dry_run)
    ):
        raise RuntimeError(
            "passive session is not ready for apply: "
            f"{report.get('verdict')} ({report.get('reason')})"
        )
    gate = _read_json(session_root / "correction_gate.json")
    if gate.get("verdict") != "ready_for_apply_candidate":
        raise RuntimeError(
            "correction_gate.json is not ready_for_apply_candidate: "
            f"{gate.get('verdict')}"
        )
    required = [
        "recommendedDelayMs",
        "currentDelayMs",
        "contextSignature",
        "enabledAirplayCount",
        "activeAirplayCount",
        "airplayTimingEpoch",
        "syncContextState",
        "syncContextRevision",
    ]
    missing = [field for field in required if gate.get(field) in (None, "")]
    if missing:
        raise ValueError(
            "correction_gate.json missing apply context field(s): "
            + ", ".join(missing)
        )
    if gate.get("delayLocked") is not False:
        raise ValueError("correction_gate.json must record delayLocked=false")
    params: dict[str, Any] = {
        "targetDelayMs": _number(gate["recommendedDelayMs"], "recommendedDelayMs"),
        "currentDelayMs": _number(gate["currentDelayMs"], "currentDelayMs"),
        "contextSignature": str(gate["contextSignature"]),
        "delayLocked": False,
        "enabledAirplayCount": _number(
            gate["enabledAirplayCount"],
            "enabledAirplayCount",
        ),
        "activeAirplayCount": _number(
            gate["activeAirplayCount"],
            "activeAirplayCount",
        ),
        "airplayTimingEpoch": _number(
            gate["airplayTimingEpoch"],
            "airplayTimingEpoch",
        ),
        "syncContextState": str(gate["syncContextState"]),
        "syncContextRevision": _number(
            gate["syncContextRevision"],
            "syncContextRevision",
        ),
        "dryRun": dry_run,
    }
    if gate.get("captureBackend"):
        params["captureBackend"] = str(gate["captureBackend"])
    if gate.get("baselineKey"):
        params["baselineKey"] = str(gate["baselineKey"])
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
        ("syncContextRevision", "syncContextRevision"),
    ]
    for result_field, request_field in number_pairs:
        try:
            expected = _number(params[request_field], request_field)
            actual = _number(result.get(result_field), result_field)
        except ValueError:
            return result_field
        if actual != expected:
            return result_field

    string_pairs = [
        ("contextSignature", "contextSignature"),
        ("syncContextState", "syncContextState"),
    ]
    optional_string_pairs = [
        ("captureBackend", "captureBackend"),
    ]
    for result_field, request_field in string_pairs:
        if str(result.get(result_field) or "") != str(params.get(request_field) or ""):
            return result_field
    for result_field, request_field in optional_string_pairs:
        expected = params.get(request_field)
        if expected not in (None, "") and str(result.get(result_field) or "") != str(expected):
            return result_field
    if result.get("delayLocked") is not False:
        return "delayLocked"
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


def apply_candidate(
    session_root: Path,
    *,
    socket_path: Path,
    dry_run: bool,
) -> dict[str, Any]:
    params = candidate_params(session_root, dry_run=dry_run)
    response = _json_rpc(socket_path, "passive_apply_candidate", params)
    if "error" in response:
        error = response["error"]
        raise RuntimeError(
            "passive_apply_candidate failed: "
            f"{error.get('code')} {error.get('message')}"
        )
    result = response.get("result")
    if not isinstance(result, dict):
        raise RuntimeError("passive_apply_candidate reply missing result object")
    if result.get("wouldApply") is True or result.get("applied") is True:
        mismatch = _positive_result_mismatch(params, result, dry_run=dry_run)
        if mismatch is not None:
            raise RuntimeError(
                "passive_apply_candidate result context mismatch: "
                f"{mismatch}"
            )
    return {
        "verdict": "applied"
        if result.get("applied") is True
        else "dry_run_ready"
        if result.get("wouldApply") is True
        else "not_applied",
        "sessionRoot": str(session_root),
        "socket": str(socket_path),
        "dryRun": dry_run,
        "request": params,
        "result": result,
        "emitsAudio": False,
        "appliesDelay": result.get("applied") is True,
    }


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Dry-run or apply a repeat-confirmed passive delay candidate."
    )
    parser.add_argument("session_root", type=Path)
    parser.add_argument("--socket", type=Path, default=_default_socket_path())
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        payload = apply_candidate(
            args.session_root,
            socket_path=args.socket,
            dry_run=not args.apply,
        )
        if args.output is not None:
            _write_json(args.output, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return EXIT_OK if payload["verdict"] in {"applied", "dry_run_ready"} else EXIT_NOT_READY
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
