#!/usr/bin/env python3
"""Audit SyncCast logs for DRM-safe no-SCK playback evidence.

This script is intentionally read-only. It does not launch SyncCast, change
routes, open the microphone, or emit audio. Use it after a manual DRM playback
check to answer one narrow question: did the log window show Direct Stereo or
Process Tap evidence without touching ScreenCaptureKit / Screen Recording?
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any


EXIT_OK = 0
EXIT_FAIL = 2
EXIT_INCONCLUSIVE = 3


FORBIDDEN_PATTERNS = [
    ("sck_start", re.compile(r"reconcile: starting router \(SCK capture\)")),
    ("sck_capture", re.compile(r"\bSCKCapture\b|SCK capture")),
    ("sck_backend", re.compile(r"\bbackend=sck\b|capture report .*backend=sck")),
    (
        "screen_recording_request",
        re.compile(r"requesting screen-recording access"),
    ),
    (
        "screen_recording_preflight",
        re.compile(r"screen-recording preflight:(?! skipped)"),
    ),
]

DIRECT_PATTERNS = {
    "direct_start": re.compile(r"reconcile: starting router \(Direct Stereo\)"),
    "direct_driver": re.compile(r"driver=directStereo"),
    "screen_preflight_skipped": re.compile(r"screen-recording preflight skipped:"),
    "router_start_ok": re.compile(r"reconcile: router\.start OK"),
}

TAP_PATTERNS = {
    "tap_start": re.compile(r"reconcile: starting router \(Process Tap capture\)"),
    "tap_backend": re.compile(r"backend=tap"),
    "screen_not_required": re.compile(
        r"screen-recording status: not required.*(Process Tap capture|capture=tap)"
    ),
    "router_start_ok": re.compile(r"reconcile: router\.start OK"),
}

TAP_COUNTER_RE = re.compile(
    r"backend=tap seen=(?P<seen>\d+) written=(?P<written>\d+) "
    r"ticks=(?P<ticks>\d+).*?peak=(?P<peak_l>[0-9.]+)/(?P<peak_r>[0-9.]+)"
)


def _default_log_path() -> Path:
    return Path.home() / "Library" / "Logs" / "SyncCast" / "launch.log"


def _read_window(path: Path, *, since_offset: int | None, tail_bytes: int) -> tuple[str, int, int]:
    if not path.exists():
        raise FileNotFoundError(f"log not found: {path}")
    size = path.stat().st_size
    if since_offset is not None:
        start = min(max(0, since_offset), size)
    else:
        start = max(0, size - max(1, tail_bytes))
    with path.open("rb") as handle:
        handle.seek(start)
        text = handle.read().decode("utf-8", errors="replace")
    return text, start, size


def _line_matches(lines: list[str], patterns: dict[str, re.Pattern[str]]) -> dict[str, list[str]]:
    matches: dict[str, list[str]] = {key: [] for key in patterns}
    for line in lines:
        for key, pattern in patterns.items():
            if pattern.search(line):
                matches[key].append(line)
    return matches


def _forbidden_matches(lines: list[str]) -> dict[str, list[str]]:
    matches: dict[str, list[str]] = {key: [] for key, _ in FORBIDDEN_PATTERNS}
    for line in lines:
        for key, pattern in FORBIDDEN_PATTERNS:
            if pattern.search(line):
                matches[key].append(line)
    return {key: value for key, value in matches.items() if value}


def _max_tap_counters(lines: list[str]) -> dict[str, Any]:
    best = {"seen": 0, "written": 0, "ticks": 0, "peak": 0.0}
    for line in lines:
        match = TAP_COUNTER_RE.search(line)
        if not match:
            continue
        seen = int(match.group("seen"))
        written = int(match.group("written"))
        ticks = int(match.group("ticks"))
        peak = max(float(match.group("peak_l")), float(match.group("peak_r")))
        if (seen, written, ticks, peak) > (
            best["seen"],
            best["written"],
            best["ticks"],
            best["peak"],
        ):
            best = {
                "seen": seen,
                "written": written,
                "ticks": ticks,
                "peak": peak,
            }
    return best


def audit_log(
    text: str,
    *,
    mode: str,
    require_tap_audio: bool,
) -> dict[str, Any]:
    lines = [line for line in text.splitlines() if line.strip()]
    forbidden = _forbidden_matches(lines)
    direct = _line_matches(lines, DIRECT_PATTERNS)
    tap = _line_matches(lines, TAP_PATTERNS)
    tap_counters = _max_tap_counters(lines)

    direct_ok = all(direct[key] for key in DIRECT_PATTERNS)
    tap_required = ["tap_start", "tap_backend", "screen_not_required", "router_start_ok"]
    tap_ok = all(tap[key] for key in tap_required)
    if require_tap_audio:
        tap_ok = tap_ok and tap_counters["seen"] > 0 and tap_counters["written"] > 0

    if forbidden:
        verdict = "fail"
        reason = "ScreenCaptureKit or Screen Recording path observed"
    elif mode == "direct-stereo":
        verdict = "pass" if direct_ok else "inconclusive"
        reason = None if direct_ok else "Direct Stereo evidence incomplete"
    elif mode == "tap":
        verdict = "pass" if tap_ok else "inconclusive"
        reason = None if tap_ok else "Process Tap evidence incomplete"
    else:
        verdict = "pass" if (direct_ok or tap_ok) else "inconclusive"
        reason = None if verdict == "pass" else "no complete no-SCK path evidence"

    return {
        "verdict": verdict,
        "reason": reason,
        "mode": mode,
        "lines_scanned": len(lines),
        "forbidden": forbidden,
        "direct": {key: bool(value) for key, value in direct.items()},
        "tap": {key: bool(value) for key, value in tap.items()},
        "tap_counters": tap_counters,
        "require_tap_audio": require_tap_audio,
        "emitsAudio": False,
        "opensMicrophone": False,
        "changesRoutes": False,
        "appliesDelay": False,
    }


def _print_human(result: dict[str, Any]) -> None:
    print(f"Verdict: {result['verdict']}")
    if result.get("reason"):
        print(f"Reason : {result['reason']}")
    print(f"Mode   : {result['mode']}")
    print(f"Lines  : {result['lines_scanned']}")
    print(f"Direct : {result['direct']}")
    print(f"Tap    : {result['tap']} counters={result['tap_counters']}")
    if result["forbidden"]:
        print("Forbidden evidence:")
        for key, lines in result["forbidden"].items():
            print(f"  {key}: {len(lines)} line(s)")
            for line in lines[:5]:
                print(f"    {line}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, default=_default_log_path())
    parser.add_argument("--since-offset", type=int)
    parser.add_argument("--tail-bytes", type=int, default=200_000)
    parser.add_argument(
        "--mode",
        choices=("no-sck", "direct-stereo", "tap"),
        default="no-sck",
    )
    parser.add_argument(
        "--require-tap-audio",
        action="store_true",
        help="for Tap mode, require nonzero callback/write counters",
    )
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.tail_bytes <= 0:
        print("ERROR: --tail-bytes must be > 0", file=sys.stderr)
        return EXIT_INCONCLUSIVE
    if args.since_offset is not None and args.since_offset < 0:
        print("ERROR: --since-offset must be >= 0", file=sys.stderr)
        return EXIT_INCONCLUSIVE
    try:
        text, start, end = _read_window(
            args.log,
            since_offset=args.since_offset,
            tail_bytes=args.tail_bytes,
        )
    except OSError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return EXIT_INCONCLUSIVE
    result = audit_log(
        text,
        mode=args.mode,
        require_tap_audio=args.require_tap_audio,
    )
    result["log"] = str(args.log)
    result["startOffset"] = start
    result["endOffset"] = end
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        _print_human(result)
        print(f"Offsets: {start}..{end}")
    if result["verdict"] == "pass":
        return EXIT_OK
    if result["verdict"] == "fail":
        return EXIT_FAIL
    return EXIT_INCONCLUSIVE


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
