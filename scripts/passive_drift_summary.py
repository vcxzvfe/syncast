#!/usr/bin/env python3
"""Summarize passive drift monitor JSON or JSONL output."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

import passive_drift_monitor as pdm


EXIT_BAD_INPUT = 2


def _load_raw(path: Path | None) -> str:
    return sys.stdin.read() if path is None else path.read_text()


def _load_json_payload(raw: str) -> dict[str, Any]:
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError("passive drift payload must be a JSON object")
    return payload


def _load_jsonl_rows(raw: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line_no, line in enumerate(raw.splitlines(), start=1):
        stripped = line.strip()
        if not stripped:
            continue
        try:
            row = json.loads(stripped)
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid JSONL line {line_no}: {exc}") from exc
        if not isinstance(row, dict):
            raise ValueError(f"JSONL line {line_no} must be a JSON object")
        rows.append(row)
    if not rows:
        raise ValueError("JSONL input contains no sample rows")
    return rows


def _payload_from_jsonl_rows(
    rows: list[dict[str, Any]],
    *,
    min_sample_fraction: float,
    max_monitor_drift_ms: float,
    max_trailing_inconclusive_samples: int,
) -> dict[str, Any]:
    summary = pdm._summarize_rows(
        rows,
        min_ok_fraction=min_sample_fraction,
        max_drift_ms=max_monitor_drift_ms,
        max_trailing_inconclusive_samples=max_trailing_inconclusive_samples,
    )
    summary["source_format"] = "jsonl"
    summary["jsonl_recomputed"] = True
    summary["jsonl_min_sample_fraction"] = min_sample_fraction
    summary["jsonl_max_monitor_drift_ms"] = max_monitor_drift_ms
    summary["jsonl_max_trailing_inconclusive_samples"] = max_trailing_inconclusive_samples
    return {"summary": summary, "rows": rows}


def _load_payload(
    path: Path | None,
    *,
    jsonl: bool = False,
    min_sample_fraction: float = 0.66,
    max_monitor_drift_ms: float = 30.0,
    max_trailing_inconclusive_samples: int = 0,
) -> dict[str, Any]:
    raw = _load_raw(path)
    use_jsonl = jsonl or (path is not None and path.suffix.lower() == ".jsonl")
    if use_jsonl:
        return _payload_from_jsonl_rows(
            _load_jsonl_rows(raw),
            min_sample_fraction=min_sample_fraction,
            max_monitor_drift_ms=max_monitor_drift_ms,
            max_trailing_inconclusive_samples=max_trailing_inconclusive_samples,
        )
    return _load_json_payload(raw)


def _validate_args(args: argparse.Namespace) -> None:
    if args.min_sample_fraction < 0.0 or args.min_sample_fraction > 1.0:
        raise ValueError("--min-sample-fraction must be between 0 and 1")
    if args.max_monitor_drift_ms < 0.0:
        raise ValueError("--max-monitor-drift-ms must be >= 0")
    if args.max_trailing_inconclusive_samples < 0:
        raise ValueError("--max-trailing-inconclusive-samples must be >= 0")


def _strong_peak_flags(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    flags: list[dict[str, Any]] = []
    for row in rows:
        sample = row.get("sample") or {}
        for cycle in sample.get("cycles") or []:
            strong = cycle.get("strong_peaks") or {}
            if int(strong.get("count") or 0) < 2:
                continue
            spread = strong.get("spread_ms")
            flags.append(
                {
                    "sample": row.get("index"),
                    "cycle": cycle.get("index"),
                    "spread_ms": spread,
                    "delays_ms": strong.get("delays_ms") or [],
                }
            )
    return flags


def _path_candidate_flags(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    flags: list[dict[str, Any]] = []
    for row in rows:
        sample = row.get("sample") or {}
        for cycle in sample.get("cycles") or []:
            candidates = cycle.get("estimate", {}).get("path_candidates") or []
            if len(candidates) < 2:
                continue
            flags.append(
                {
                    "sample": row.get("index"),
                    "cycle": cycle.get("index"),
                    "paths": [
                        {
                            "delay_ms": path.get("delay_ms"),
                            "window_fraction": path.get("window_fraction"),
                            "mean_score": path.get("mean_score"),
                        }
                        for path in candidates[:5]
                    ],
                    "candidate_windows": cycle.get("estimate", {}).get("path_candidate_windows"),
                }
            )
    return flags


def _summarize_payload(payload: dict[str, Any]) -> dict[str, Any]:
    summary = payload.get("summary")
    rows = payload.get("rows")
    if not isinstance(summary, dict) or not isinstance(rows, list):
        raise ValueError("payload must contain object 'summary' and list 'rows'")
    verdict_counts = Counter(str(row.get("verdict") or "unknown") for row in rows)
    accepted_delays = [
        float(row["delay_ms"])
        for row in rows
        if row.get("verdict") == "accepted" and row.get("delay_ms") is not None
    ]
    current_delays = [
        round(float(row["current_delay_ms"]), 3)
        for row in rows
        if row.get("current_delay_ms") is not None
    ]
    context_counts = Counter(
        str(row.get("context_signature"))
        for row in rows
        if row.get("context_signature")
    )
    airplay_counts = Counter(
        str(row.get("enabled_airplay_count"))
        for row in rows
        if row.get("enabled_airplay_count") is not None
    )
    reasons = Counter(
        str(row.get("inconclusive_reason"))
        for row in rows
        if row.get("inconclusive_reason")
    )
    strong_flags = _strong_peak_flags(rows)
    path_flags = _path_candidate_flags(rows)
    return {
        "monitor_verdict": summary.get("verdict"),
        "source_format": summary.get("source_format", "json"),
        "jsonl_recomputed": bool(summary.get("jsonl_recomputed")),
        "reason": summary.get("reason"),
        "samples_total": len(rows),
        "sample_verdict_counts": dict(sorted(verdict_counts.items())),
        "accepted_delay_min_ms": None if not accepted_delays else round(min(accepted_delays), 3),
        "accepted_delay_max_ms": None if not accepted_delays else round(max(accepted_delays), 3),
        "accepted_delay_range_ms": None
        if not accepted_delays
        else round(max(accepted_delays) - min(accepted_delays), 3),
        "monitor_delay_range_ms": summary.get("delay_range_ms"),
        "monitor_delay_end_to_start_ms": summary.get("delay_end_to_start_ms"),
        "context_gate": summary.get("context_gate"),
        "current_delay_min_ms": None if not current_delays else min(current_delays),
        "current_delay_max_ms": None if not current_delays else max(current_delays),
        "current_delay_values_ms": sorted(set(current_delays)),
        "context_signature_count": len(context_counts),
        "enabled_airplay_counts": dict(sorted(airplay_counts.items())),
        "trailing_inconclusive_samples": summary.get("trailing_inconclusive_samples"),
        "top_inconclusive_reasons": [
            {"reason": reason, "count": count}
            for reason, count in reasons.most_common(6)
        ],
        "strong_peak_flags": strong_flags[:20],
        "strong_peak_flag_count": len(strong_flags),
        "multi_path_candidate_flags": path_flags[:20],
        "multi_path_candidate_flag_count": len(path_flags),
    }


def _format_text(summary: dict[str, Any]) -> str:
    lines = [
        "Passive drift summary",
        f"  verdict: {summary.get('monitor_verdict')}",
        (
            "  source : %s recomputed=%s"
            % (summary.get("source_format"), summary.get("jsonl_recomputed"))
        ),
        f"  reason : {summary.get('reason')}",
        f"  samples: {summary.get('samples_total')} {summary.get('sample_verdict_counts')}",
        (
            "  delay  : range=%s end-start=%s accepted-min=%s accepted-max=%s"
            % (
                summary.get("monitor_delay_range_ms"),
                summary.get("monitor_delay_end_to_start_ms"),
                summary.get("accepted_delay_min_ms"),
                summary.get("accepted_delay_max_ms"),
            )
        ),
        (
            "  applied: current-delay-values=%s contexts=%s airplay-counts=%s"
            % (
                summary.get("current_delay_values_ms"),
                summary.get("context_signature_count"),
                summary.get("enabled_airplay_counts"),
            )
        ),
        f"  trailing inconclusive: {summary.get('trailing_inconclusive_samples')}",
        f"  context gate: {summary.get('context_gate')}",
        f"  strong peak flags: {summary.get('strong_peak_flag_count')}",
        f"  multi-path candidate flags: {summary.get('multi_path_candidate_flag_count')}",
    ]
    reasons = summary.get("top_inconclusive_reasons") or []
    if reasons:
        lines.append("  inconclusive reasons:")
        for item in reasons:
            lines.append(f"    {item['count']}x {item['reason']}")
    flags = summary.get("strong_peak_flags") or []
    if flags:
        lines.append("  strong peak examples:")
        for item in flags[:5]:
            lines.append(
                "    sample=%s cycle=%s spread=%sms delays=%s"
                % (
                    item.get("sample"),
                    item.get("cycle"),
                    item.get("spread_ms"),
                    item.get("delays_ms"),
                )
            )
    path_flags = summary.get("multi_path_candidate_flags") or []
    if path_flags:
        lines.append("  multi-path examples:")
        for item in path_flags[:5]:
            lines.append(
                "    sample=%s cycle=%s paths=%s"
                % (item.get("sample"), item.get("cycle"), item.get("paths"))
            )
    return "\n".join(lines)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize JSON or JSONL from scripts/passive_drift_monitor.py"
    )
    parser.add_argument("path", nargs="?", type=Path, help="JSON/JSONL file; stdin when omitted")
    parser.add_argument("--jsonl", action="store_true", help="read newline-delimited sample rows; auto-enabled for *.jsonl")
    parser.add_argument("--json", action="store_true", help="emit compact JSON summary")
    parser.add_argument(
        "--verdict-exit",
        action="store_true",
        help="exit using the monitor verdict code: stable=0, inconclusive=3, unstable=4",
    )
    parser.add_argument("--max-monitor-drift-ms", type=float, default=30.0)
    parser.add_argument("--min-sample-fraction", type=float, default=0.66)
    parser.add_argument("--max-trailing-inconclusive-samples", type=int, default=0)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        _validate_args(args)
        payload = _load_payload(
            args.path,
            jsonl=args.jsonl,
            min_sample_fraction=args.min_sample_fraction,
            max_monitor_drift_ms=args.max_monitor_drift_ms,
            max_trailing_inconclusive_samples=args.max_trailing_inconclusive_samples,
        )
        summary = _summarize_payload(payload)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return EXIT_BAD_INPUT
    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(_format_text(summary))
    if args.verdict_exit:
        return pdm._exit_code_for_verdict(str(summary.get("monitor_verdict")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
