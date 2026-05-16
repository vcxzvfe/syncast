#!/usr/bin/env python3
"""Finalize a passive session against a baseline store.

This helper is intentionally still no-write with respect to SyncCast playback:
it only writes JSON artifacts. In auto mode it records the first audited
baseline for a route/backend/AirPlay context, and for later matching sessions
it emits a stored-baseline no-write decision.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import passive_baseline_store as pbs
import passive_delay_decision as pdd
import passive_session_audit as psa


EXIT_OK = 0
EXIT_BAD_INPUT = 2
EXIT_NOT_APPLICABLE = 3


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def finalize_session(
    *,
    session_root: Path,
    store_path: Path,
    mode: str = "auto",
) -> dict[str, Any]:
    if mode not in {"auto", "record", "decide"}:
        raise ValueError("--mode must be one of auto, record, decide")
    audit = psa.audit_session(session_root)
    if audit.get("verdict") == "capture_failed":
        raise pdd.DecisionRejected(
            f"session capture failed at {audit.get('phase')}: {audit.get('reason')}"
        )
    if audit.get("verdict") not in {"ready_for_baseline", "hold", "ready_for_correction"}:
        raise pdd.DecisionRejected(
            f"session is not usable for baseline finalization: "
            f"{audit.get('verdict')} ({audit.get('reason')})"
        )

    if mode == "record":
        result = pbs.record_baseline(store_path, session_root)
        action = "recorded"
    elif mode == "decide":
        result = pbs.decide_with_store(store_path, session_root)
        action = "decided"
    else:
        try:
            result = pbs.decide_with_store(store_path, session_root)
            action = "decided"
        except pdd.DecisionRejected as exc:
            can_rebaseline = (
                "no passive baseline" in str(exc)
                or "lacks Local/AirPlay path-pair metadata" in str(exc)
            )
            if not can_rebaseline:
                raise
            result = pbs.record_baseline(store_path, session_root)
            action = "recorded"

    return {
        "verdict": action,
        "mode": mode,
        "sessionRoot": str(session_root),
        "store": str(store_path),
        "auditVerdict": audit.get("verdict"),
        "result": result,
        "emitsAudio": False,
        "appliesDelay": False,
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Record or reuse a passive baseline for a session directory."
    )
    parser.add_argument("session_root", type=Path)
    parser.add_argument("--store", type=Path, required=True)
    parser.add_argument(
        "--mode",
        choices=("auto", "record", "decide"),
        default="auto",
    )
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        result = finalize_session(
            session_root=args.session_root,
            store_path=args.store,
            mode=args.mode,
        )
        if args.output is not None:
            _write_json(args.output, result)
        print(json.dumps(result, indent=2, sort_keys=True))
        return EXIT_OK
    except pdd.DecisionRejected as exc:
        payload = {"verdict": "not_applicable", "error": str(exc)}
        if args.output is not None:
            _write_json(args.output, payload)
        print(json.dumps(payload, indent=2), file=sys.stderr)
        return EXIT_NOT_APPLICABLE
    except Exception as exc:
        payload = {"verdict": "bad_input", "error": str(exc)}
        if args.output is not None:
            _write_json(args.output, payload)
        print(json.dumps(payload, indent=2), file=sys.stderr)
        return EXIT_BAD_INPUT


if __name__ == "__main__":
    raise SystemExit(main())
