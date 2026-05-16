#!/usr/bin/env python3
"""Create a small evidence folder for manual DRM playback checks.

This helper is deliberately passive: it does not launch SyncCast, open DRM
sites, change routes, open the microphone, emit audio, or apply delay. It
records the current launch.log byte offset before a manual test, then audits
only the new log lines afterwards with scripts/drm_path_audit.py.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
import sys
from typing import Any

import drm_path_audit


EXIT_OK = 0
EXIT_BAD_INPUT = 2
EXIT_INCONCLUSIVE = 3

SCHEMA = "syncast.drm_manual_session.v1"


def _default_session_root() -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    return Path(f"/tmp/syncast-drm-manual-{stamp}")


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def start_session(args: argparse.Namespace) -> int:
    log = args.log
    if not log.exists():
        print(f"ERROR: log not found: {log}", file=sys.stderr)
        return EXIT_BAD_INPUT
    root = args.session_root
    root.mkdir(parents=True, exist_ok=True)
    offset = log.stat().st_size
    manifest = {
        "schema": SCHEMA,
        "createdUnix": round(time.time(), 3),
        "mode": args.mode,
        "requireTapAudio": args.require_tap_audio,
        "log": str(log),
        "startOffset": offset,
        "emitsAudio": False,
        "opensMicrophone": False,
        "changesRoutes": False,
        "appliesDelay": False,
        "instructions": [
            "Manually launch the intended SyncCast mode.",
            "Manually play the DRM source under test.",
            "Run this helper with 'finish' on the same session root.",
        ],
    }
    _write_json(root / "manifest.json", manifest)
    print(json.dumps({
        "verdict": "started",
        "sessionRoot": str(root),
        "log": str(log),
        "startOffset": offset,
        "mode": args.mode,
        "emitsAudio": False,
        "opensMicrophone": False,
        "changesRoutes": False,
        "appliesDelay": False,
    }, indent=2, sort_keys=True))
    return EXIT_OK


def _read_manifest(root: Path) -> dict[str, Any]:
    path = root / "manifest.json"
    payload = json.loads(path.read_text())
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected JSON object")
    if payload.get("schema") != SCHEMA:
        raise ValueError(f"{path}: unexpected schema {payload.get('schema')!r}")
    return payload


def finish_session(args: argparse.Namespace) -> int:
    root = args.session_root
    try:
        manifest = _read_manifest(root)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return EXIT_BAD_INPUT
    log = Path(str(args.log or manifest.get("log") or ""))
    mode = args.mode or str(manifest.get("mode") or "no-sck")
    require_tap_audio = (
        args.require_tap_audio
        if args.require_tap_audio is not None
        else bool(manifest.get("requireTapAudio"))
    )
    start_offset = int(manifest.get("startOffset") or 0)
    try:
        text, start, end = drm_path_audit._read_window(
            log,
            since_offset=start_offset,
            tail_bytes=1,
        )
    except OSError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return EXIT_BAD_INPUT
    result = drm_path_audit.audit_log(
        text,
        mode=mode,
        require_tap_audio=require_tap_audio,
    )
    result.update(
        {
            "sessionRoot": str(root),
            "manifest": str(root / "manifest.json"),
            "log": str(log),
            "startOffset": start,
            "endOffset": end,
            "manualPlayback": True,
            "emitsAudio": False,
            "opensMicrophone": False,
            "changesRoutes": False,
            "appliesDelay": False,
        }
    )
    _write_json(root / "drm_audit.json", result)
    print(json.dumps(result, indent=2, sort_keys=True))
    if result["verdict"] == "pass":
        return EXIT_OK
    if result["verdict"] == "fail":
        return drm_path_audit.EXIT_FAIL
    return EXIT_INCONCLUSIVE


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    start = sub.add_parser("start")
    start.add_argument("--session-root", type=Path, default=_default_session_root())
    start.add_argument("--log", type=Path, default=drm_path_audit._default_log_path())
    start.add_argument(
        "--mode",
        choices=("no-sck", "direct-stereo", "tap"),
        default="direct-stereo",
    )
    start.add_argument("--require-tap-audio", action="store_true")

    finish = sub.add_parser("finish")
    finish.add_argument("session_root", type=Path)
    finish.add_argument("--log", type=Path)
    finish.add_argument("--mode", choices=("no-sck", "direct-stereo", "tap"))
    finish.add_argument(
        "--require-tap-audio",
        action=argparse.BooleanOptionalAction,
        default=None,
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.command == "start":
        return start_session(args)
    if args.command == "finish":
        return finish_session(args)
    return EXIT_BAD_INPUT


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
