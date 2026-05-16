#!/usr/bin/env python3
"""Summarize recent SyncCast acoustic-calibration lines from launch.log.

This is intentionally read-only. It does not launch SyncCast, touch CoreAudio,
or emit any probe audio. Use it after manual or harness-driven runs to quickly
separate probe-profile, mic-readiness, confidence, route-mutation, and apply
decision failures.
"""

from __future__ import annotations

import argparse
import collections
import os
import re
import sys
from pathlib import Path


DEFAULT_LOG = Path.home() / "Library/Logs/SyncCast/launch.log"
DEFAULT_TAIL = 4000

PROFILE_RE = re.compile(r"profile=([A-Za-z0-9_.-]+)")
PHASE_RE = re.compile(r"\[ActiveCalib\] phase=([A-Za-z0-9_]+)")
DONE_RE = re.compile(
    r"\[ActiveCalib\] DONE .*?delta=([-0-9]+)ms confidence=([0-9.]+)"
)
APPLY_RE = re.compile(r"autoCalib: applied(?: repeated large correction)? ([0-9]+)ms")
REJECT_RE = re.compile(r"autoCalib: recommended .*? rejected: (.*)$")
HELD_RE = re.compile(r"autoCalib: recommended ([0-9]+)ms held")
FAILED_RE = re.compile(r"autoCalib: failed (.*)$")
UNCERTAINTY_RE = re.compile(r"uncertainty=([-0-9]+)ms")


def _tail_lines(path: Path, limit: int) -> list[str]:
    if not path.exists():
        raise FileNotFoundError(path)
    lines = path.read_text(errors="replace").splitlines()
    if limit <= 0:
        return lines
    return lines[-limit:]


def _first_match(pattern: re.Pattern[str], text: str) -> str | None:
    match = pattern.search(text)
    return match.group(1) if match else None


def summarize(lines: list[str]) -> int:
    calibration_lines = [
        line for line in lines
        if "[ActiveCalib]" in line
        or "autoCalib" in line
        or "airplayDelay applied" in line
        or "calibration route context changed" in line
        or "mic_ready first_host=" in line
        or "mic_ready_host=" in line
        or "probe_anchor=" in line
    ]

    profiles: collections.Counter[str] = collections.Counter()
    phases: collections.Counter[str] = collections.Counter()
    rejects: collections.Counter[str] = collections.Counter()
    failures: collections.Counter[str] = collections.Counter()
    done: list[tuple[int, float, str]] = []
    applied: list[tuple[int, str]] = []
    held: list[tuple[int, str]] = []
    mic_ready = 0
    probe_anchor = 0
    route_changed = 0
    uncertainty_values: list[int] = []

    recent_events: collections.deque[str] = collections.deque(maxlen=20)

    for line in calibration_lines:
        if profile := _first_match(PROFILE_RE, line):
            profiles[profile] += 1
        if phase := _first_match(PHASE_RE, line):
            phases[phase] += 1
        if "mic_ready first_host=" in line or "mic_ready_host=" in line:
            mic_ready += 1
        if "probe_anchor=" in line:
            probe_anchor += 1
        if "calibration route context changed" in line:
            route_changed += 1
        for match in UNCERTAINTY_RE.finditer(line):
            try:
                uncertainty_values.append(int(match.group(1)))
            except ValueError:
                pass
        if match := DONE_RE.search(line):
            done.append((int(match.group(1)), float(match.group(2)), line))
            recent_events.append(line)
        elif match := APPLY_RE.search(line):
            applied.append((int(match.group(1)), line))
            recent_events.append(line)
        elif match := HELD_RE.search(line):
            held.append((int(match.group(1)), line))
            recent_events.append(line)
        elif match := REJECT_RE.search(line):
            rejects[match.group(1)] += 1
            recent_events.append(line)
        elif match := FAILED_RE.search(line):
            failures[match.group(1)] += 1
            recent_events.append(line)
        elif "REJECT" in line:
            reason = line.split("REJECT", 1)[1].strip() or "(unknown)"
            failures[reason] += 1
            recent_events.append(line)
        elif "autoCalib event" in line or "post-apply validation" in line:
            recent_events.append(line)

    print(f"Scanned lines:       {len(lines)}")
    print(f"Calibration lines:  {len(calibration_lines)}")
    print(f"Mic-ready anchors:  mic_ready={mic_ready} probe_anchor={probe_anchor}")
    print(f"Route mutations:    {route_changed}")
    print()

    if profiles:
        print("Probe profiles:")
        for name, count in profiles.most_common():
            print(f"  {name}: {count}")
    else:
        print("Probe profiles:     none observed")

    if phases:
        print("Phases:")
        for name, count in phases.most_common():
            print(f"  {name}: {count}")

    if done:
        last_delta, last_conf, _ = done[-1]
        min_conf = min(conf for _, conf, _ in done)
        max_conf = max(conf for _, conf, _ in done)
        print(
            f"Completed runs:     {len(done)} "
            f"(last delta={last_delta}ms conf={last_conf:.2f}; "
            f"conf range={min_conf:.2f}-{max_conf:.2f})"
        )
    else:
        print("Completed runs:     0")

    if uncertainty_values:
        print(
            f"Uncertainty seen:   max={max(uncertainty_values)}ms "
            f"n={len(uncertainty_values)}"
        )

    print(f"Auto applies:       {len(applied)}")
    if applied:
        print(f"  last applied: {applied[-1][0]}ms")
    print(f"Held for repeat:    {len(held)}")

    if rejects:
        print("Auto-apply rejects:")
        for reason, count in rejects.most_common():
            print(f"  {reason}: {count}")
    if failures:
        print("Failures / REJECTs:")
        for reason, count in failures.most_common(12):
            print(f"  {reason}: {count}")

    if recent_events:
        print()
        print("Recent calibration events:")
        for event in recent_events:
            print("  " + event)

    if not calibration_lines:
        print()
        print("No calibration evidence found in the selected log window.")
        return 2
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "log",
        nargs="?",
        default=str(DEFAULT_LOG),
        help=f"launch.log path (default: {DEFAULT_LOG})",
    )
    parser.add_argument(
        "--tail",
        type=int,
        default=DEFAULT_TAIL,
        help=f"number of log lines to scan; 0 scans the full file (default: {DEFAULT_TAIL})",
    )
    args = parser.parse_args(argv)

    try:
        lines = _tail_lines(Path(os.path.expanduser(args.log)), args.tail)
    except FileNotFoundError as exc:
        print(f"ERROR: log not found: {exc.filename}", file=sys.stderr)
        return 2

    return summarize(lines)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
