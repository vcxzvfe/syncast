#!/usr/bin/env python3
"""Monitor passive SyncCast delay drift without emitting calibration audio."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import Any

import passive_capture_estimate as pce


EXIT_OK = 0
EXIT_CAPTURE_FAILED = 2
EXIT_INCONCLUSIVE = 3
EXIT_UNSTABLE = 4


def _median(values: list[float]) -> float:
    ordered = sorted(values)
    if not ordered:
        return math.nan
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0


def _normalized_context_value(value: Any) -> Any:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return round(float(value), 3)
    return value


def _ordered_present_values(rows: list[dict[str, Any]], key: str) -> list[Any]:
    values = []
    seen = set()
    for row in rows:
        value = row.get(key)
        if value is None or value == "":
            continue
        normalized = _normalized_context_value(value)
        marker = json.dumps(normalized, sort_keys=True)
        if marker in seen:
            continue
        seen.add(marker)
        values.append(normalized)
    return values


def _context_gate_failure(accepted: list[dict[str, Any]]) -> dict[str, Any] | None:
    checks = [
        ("context_signature", "route context", "context_signatures"),
        ("current_delay_ms", "applied delay", "current_delay_values_ms"),
        ("enabled_airplay_count", "enabled AirPlay count", "enabled_airplay_counts"),
        ("active_airplay_count", "active AirPlay count", "active_airplay_counts"),
        ("airplay_timing_epoch", "AirPlay timing epoch", "airplay_timing_epochs"),
        ("sync_context_state", "sync context state", "sync_context_states"),
        ("sync_context_revision", "sync context revision", "sync_context_revisions"),
        ("capture_backend", "capture backend", "capture_backends"),
        ("delay_locked", "delay lock state", "delay_lock_values"),
    ]
    for key, label, output_key in checks:
        present = [
            row
            for row in accepted
            if row.get(key) is not None and row.get(key) != ""
        ]
        if not present:
            continue
        values = _ordered_present_values(accepted, key)
        detail = {
            "field": key,
            output_key: values,
            "samples_with_value": len(present),
            "samples_accepted": len(accepted),
        }
        if len(present) < len(accepted):
            return {
                "verdict": "inconclusive",
                "reason": (
                    f"incomplete passive context metadata for {label}: "
                    f"{len(present)}/{len(accepted)} accepted samples"
                ),
                "context_gate": detail,
            }
        if len(values) > 1:
            return {
                "verdict": "unstable",
                "reason": f"passive monitor {label} changed during run: {values}",
                "context_gate": detail,
            }
    return None


def _delay_summary(
    *,
    verdict: str,
    rows: list[dict[str, Any]],
    accepted: list[dict[str, Any]],
    required: int,
    trailing_inconclusive: int,
    accepted_gap_samples: list[int],
    final_accepted_run: int,
    required_final_accepted_run: int,
    reason: str | None,
) -> dict[str, Any]:
    delays = [float(row["delay_ms"]) for row in accepted]
    delay_start = delays[0]
    delay_end = delays[-1]
    delay_range = max(delays) - min(delays)
    return {
        "verdict": verdict,
        "samples_total": len(rows),
        "samples_accepted": len(accepted),
        "required_accepted": required,
        "trailing_inconclusive_samples": trailing_inconclusive,
        "accepted_gap_samples": accepted_gap_samples,
        "max_accepted_gap_samples": max(accepted_gap_samples or [0]),
        "final_accepted_run": final_accepted_run,
        "required_final_accepted_run": required_final_accepted_run,
        "delay_start_ms": round(delay_start, 3),
        "delay_end_ms": round(delay_end, 3),
        "delay_median_ms": round(_median(delays), 3),
        "delay_range_ms": round(delay_range, 3),
        "delay_end_to_start_ms": round(delay_end - delay_start, 3),
        "reason": reason,
    }


def _summarize_rows(
    rows: list[dict[str, Any]],
    *,
    min_ok_fraction: float,
    max_drift_ms: float,
    max_trailing_inconclusive_samples: int,
    max_accepted_gap_samples: int = 0,
    min_final_accepted_run: int = 2,
) -> dict[str, Any]:
    accepted = [
        row
        for row in rows
        if row.get("verdict") == "accepted" and row.get("delay_ms") is not None
    ]
    required = max(1, int(math.ceil(len(rows) * min_ok_fraction)))
    required_final_run = min(max(1, min_final_accepted_run), required)
    if len(accepted) < required:
        return {
            "verdict": "inconclusive",
            "samples_total": len(rows),
            "samples_accepted": len(accepted),
            "required_accepted": required,
            "accepted_gap_samples": [],
            "max_accepted_gap_samples": 0,
            "final_accepted_run": 0,
            "required_final_accepted_run": required_final_run,
            "delay_start_ms": None,
            "delay_end_ms": None,
            "delay_median_ms": None,
            "delay_range_ms": None,
            "delay_end_to_start_ms": None,
            "reason": (
                f"only {len(accepted)}/{len(rows)} samples accepted, required {required}"
            ),
        }
    trailing_inconclusive = 0
    for row in reversed(rows):
        if row.get("verdict") == "accepted" and row.get("delay_ms") is not None:
            break
        trailing_inconclusive += 1
    final_accepted_run = 0
    final_index = len(rows) - trailing_inconclusive - 1
    while final_index >= 0:
        row = rows[final_index]
        if row.get("verdict") == "accepted" and row.get("delay_ms") is not None:
            final_accepted_run += 1
            final_index -= 1
            continue
        break
    accepted_indices = [
        index
        for index, row in enumerate(rows)
        if row.get("verdict") == "accepted" and row.get("delay_ms") is not None
    ]
    accepted_gap_samples = [
        later - earlier - 1
        for earlier, later in zip(accepted_indices, accepted_indices[1:])
    ]
    max_gap = max(accepted_gap_samples or [0])
    if trailing_inconclusive > max_trailing_inconclusive_samples:
        return {
            "verdict": "inconclusive",
            "samples_total": len(rows),
            "samples_accepted": len(accepted),
            "required_accepted": required,
            "accepted_gap_samples": accepted_gap_samples,
            "max_accepted_gap_samples": max_gap,
            "final_accepted_run": final_accepted_run,
            "required_final_accepted_run": required_final_run,
            "delay_start_ms": None,
            "delay_end_ms": None,
            "delay_median_ms": None,
            "delay_range_ms": None,
            "delay_end_to_start_ms": None,
            "trailing_inconclusive_samples": trailing_inconclusive,
            "reason": (
                "last accepted passive sample is too far from the end: "
                f"{trailing_inconclusive} trailing inconclusive sample(s) > "
                f"{max_trailing_inconclusive_samples}"
            ),
        }
    if max_gap > max_accepted_gap_samples:
        return {
            "verdict": "inconclusive",
            "samples_total": len(rows),
            "samples_accepted": len(accepted),
            "required_accepted": required,
            "accepted_gap_samples": accepted_gap_samples,
            "max_accepted_gap_samples": max_gap,
            "final_accepted_run": final_accepted_run,
            "required_final_accepted_run": required_final_run,
            "delay_start_ms": None,
            "delay_end_ms": None,
            "delay_median_ms": None,
            "delay_range_ms": None,
            "delay_end_to_start_ms": None,
            "trailing_inconclusive_samples": trailing_inconclusive,
            "reason": (
                "accepted passive samples are not contiguous enough: "
                f"max gap {max_gap} sample(s) > {max_accepted_gap_samples}"
            ),
        }
    if final_accepted_run < required_final_run:
        return {
            "verdict": "inconclusive",
            "samples_total": len(rows),
            "samples_accepted": len(accepted),
            "required_accepted": required,
            "accepted_gap_samples": accepted_gap_samples,
            "max_accepted_gap_samples": max_gap,
            "final_accepted_run": final_accepted_run,
            "required_final_accepted_run": required_final_run,
            "delay_start_ms": None,
            "delay_end_ms": None,
            "delay_median_ms": None,
            "delay_range_ms": None,
            "delay_end_to_start_ms": None,
            "trailing_inconclusive_samples": trailing_inconclusive,
            "reason": (
                "recent passive evidence is not contiguous enough: "
                f"final accepted run {final_accepted_run} < {required_final_run}"
            ),
        }
    context_failure = _context_gate_failure(accepted)
    if context_failure is not None:
        result = _delay_summary(
            verdict=context_failure["verdict"],
            rows=rows,
            accepted=accepted,
            required=required,
            trailing_inconclusive=trailing_inconclusive,
            accepted_gap_samples=accepted_gap_samples,
            final_accepted_run=final_accepted_run,
            required_final_accepted_run=required_final_run,
            reason=context_failure["reason"],
        )
        result["context_gate"] = context_failure["context_gate"]
        return result
    delays = [float(row["delay_ms"]) for row in accepted]
    delay_range = max(delays) - min(delays)
    verdict = "stable" if delay_range <= max_drift_ms else "unstable"
    reason = None
    if verdict == "unstable":
        reason = f"passive delay range {delay_range:.3f}ms > {max_drift_ms:.3f}ms"
    return _delay_summary(
        verdict=verdict,
        rows=rows,
        accepted=accepted,
        required=required,
        trailing_inconclusive=trailing_inconclusive,
        accepted_gap_samples=accepted_gap_samples,
        final_accepted_run=final_accepted_run,
        required_final_accepted_run=required_final_run,
        reason=reason,
    )


def _exit_code_for_verdict(verdict: str) -> int:
    if verdict == "stable":
        return EXIT_OK
    if verdict == "unstable":
        return EXIT_UNSTABLE
    if verdict == "capture_failed":
        return EXIT_CAPTURE_FAILED
    return EXIT_INCONCLUSIVE


def _capture_failed_payload(
    error: str,
    rows: list[dict[str, Any]],
    preflight_status: dict[str, Any] | None = None,
) -> dict[str, Any]:
    accepted = [
        row
        for row in rows
        if row.get("verdict") == "accepted" and row.get("delay_ms") is not None
    ]
    payload = {
        "summary": {
            "verdict": "capture_failed",
            "samples_total": len(rows),
            "samples_accepted": len(accepted),
            "required_accepted": None,
            "delay_start_ms": None,
            "delay_end_ms": None,
            "delay_median_ms": None,
            "delay_range_ms": None,
            "delay_end_to_start_ms": None,
            "reason": error,
        },
        "rows": rows,
    }
    if preflight_status is not None:
        payload["preflight"] = preflight_status
    return payload


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def _append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")


def _preflight_payload(
    args: argparse.Namespace,
    status: dict[str, Any],
) -> dict[str, Any]:
    return {
        "verdict": "preflight_ok",
        "socket": str(args.socket),
        "samples": args.samples,
        "cycles": args.cycles,
        "duration_sec": args.duration_sec,
        "max_delay_ms": args.max_delay_ms,
        "opens_microphone": False,
        "emits_audio": False,
        "applies_delay": False,
        "status": status,
    }


def _estimate_args(args: argparse.Namespace) -> argparse.Namespace:
    return argparse.Namespace(
        min_ms=args.min_ms,
        max_ms=args.max_ms,
        mode=args.mode,
        window_sec=args.window_sec,
        hop_sec=args.hop_sec,
        min_rms=args.min_rms,
        min_score=args.min_score,
        min_prominence=args.min_prominence,
        min_peak_z=args.min_peak_z,
        min_accepted_window_fraction=args.min_accepted_window_fraction,
        max_feature_delta_ms=getattr(args, "max_feature_delta_ms", 25.0),
        peak_separation_ms=args.peak_separation_ms,
        cluster_radius_ms=args.cluster_radius_ms,
        min_cluster_fraction=args.min_cluster_fraction,
        max_mad_ms=args.max_mad_ms,
        min_valid_reference_ratio=args.min_valid_reference_ratio,
        min_cycle_fraction=args.min_cycle_fraction,
        cycle_cluster_radius_ms=args.cycle_cluster_radius_ms,
        max_cycle_range_ms=args.max_cycle_range_ms,
        max_cycle_mad_ms=args.max_cycle_mad_ms,
        max_estimate_slope_ms_per_min=getattr(
            args,
            "max_estimate_slope_ms_per_min",
            None,
        ),
        strong_peak_relative_score=args.strong_peak_relative_score,
        strong_peak_relative_count=args.strong_peak_relative_count,
        max_strong_peak_spread_ms=args.max_strong_peak_spread_ms,
        allow_single_cycle_accept=args.allow_single_cycle_accept,
    )


def _capture_sample(
    *,
    sample_index: int,
    args: argparse.Namespace,
    estimate_args: argparse.Namespace,
) -> dict[str, Any]:
    cycles = []
    for cycle_index in range(args.cycles):
        preflight_status = pce._passive_capture_preflight(args.socket)
        output_dir = None
        if args.output_root is not None:
            output_dir = (
                args.output_root
                / f"sample-{sample_index + 1:03d}"
                / f"cycle-{cycle_index + 1:03d}"
            )
        timeout = args.duration_sec + args.max_delay_ms / 1000.0 + 15.0
        capture = pce._capture_once(
            socket_path=args.socket,
            duration_sec=args.duration_sec,
            max_delay_ms=args.max_delay_ms,
            output_directory=output_dir,
            timeout_sec=timeout,
        )
        estimate = pce._estimate_capture(capture, estimate_args)
        cycles.append(
            {
                "index": cycle_index + 1,
                "preflight": preflight_status,
                "capture": capture,
                "estimate": estimate,
                "strong_peaks": pce._strong_peak_summary(
                    estimate,
                    relative_score=args.strong_peak_relative_score,
                    relative_count=args.strong_peak_relative_count,
                ),
            }
        )
    summary = pce._summarize_cycles(cycles, estimate_args)
    return {
        "verdict": "accepted" if summary["ok"] else "inconclusive",
        "summary": summary,
        "cycles": cycles,
    }


def _sample_context(sample: dict[str, Any]) -> dict[str, Any]:
    cycles = sample.get("cycles") or []
    for cycle in cycles:
        capture = cycle.get("capture") or {}
        if capture:
            return {
                "current_delay_ms": capture.get("currentDelayMs"),
                "context_signature": capture.get("contextSignature"),
                "delay_locked": capture.get("delayLocked"),
                "enabled_airplay_count": capture.get("enabledAirplayCount"),
                "active_airplay_count": capture.get("activeAirplayCount"),
                "airplay_timing_epoch": capture.get("airplayTimingEpoch"),
                "sync_context_state": capture.get("syncContextState"),
                "sync_context_reason": capture.get("syncContextReason"),
                "sync_context_revision": capture.get("syncContextRevision"),
                "capture_backend": capture.get("backend"),
            }
    return {
        "current_delay_ms": None,
        "context_signature": None,
        "delay_locked": None,
        "enabled_airplay_count": None,
        "active_airplay_count": None,
        "airplay_timing_epoch": None,
        "sync_context_state": None,
        "sync_context_reason": None,
        "sync_context_revision": None,
        "capture_backend": None,
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Monitor passive SyncCast delay drift using real program audio. "
            "This emits no probe and does not apply delay."
        )
    )
    parser.add_argument("--socket", type=Path, default=Path(f"/tmp/syncast-{os.getuid()}.calibration.sock"))
    parser.add_argument("--samples", type=int, default=6)
    parser.add_argument(
        "--interval-sec",
        type=float,
        default=60.0,
        help="idle gap after each sample; sample start spacing also includes capture time",
    )
    parser.add_argument("--duration-sec", type=float, default=4.0)
    parser.add_argument("--max-delay-ms", type=int, default=3500)
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--report-path", type=Path)
    parser.add_argument("--jsonl-path", type=Path)
    parser.add_argument(
        "--preflight-only",
        action="store_true",
        help="validate args and diagnostic socket ping, then exit before any capture or microphone access",
    )
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--allow-single-cycle-accept", action="store_true")
    parser.add_argument("--max-monitor-drift-ms", type=float, default=30.0)
    parser.add_argument("--min-sample-fraction", type=float, default=0.66)
    parser.add_argument("--max-trailing-inconclusive-samples", type=int, default=0)
    parser.add_argument("--max-accepted-gap-samples", type=int, default=0)
    parser.add_argument("--min-final-accepted-run", type=int, default=2)
    parser.add_argument("--min-ms", type=float, default=0.0)
    parser.add_argument("--max-ms", type=float)
    parser.add_argument("--mode", choices=("waveform", "envelope", "dual"), default="dual")
    parser.add_argument("--window-sec", type=float, default=2.0)
    parser.add_argument("--hop-sec", type=float, default=1.0)
    parser.add_argument("--min-rms", type=float, default=0.0005)
    parser.add_argument("--min-score", type=float, default=0.04)
    parser.add_argument("--min-prominence", type=float, default=1.02)
    parser.add_argument("--min-peak-z", type=float, default=6.0)
    parser.add_argument("--min-accepted-window-fraction", type=float, default=0.50)
    parser.add_argument("--max-feature-delta-ms", type=float, default=25.0)
    parser.add_argument("--peak-separation-ms", type=float, default=20.0)
    parser.add_argument("--cluster-radius-ms", type=float, default=10.0)
    parser.add_argument("--min-cluster-fraction", type=float, default=0.6)
    parser.add_argument("--max-mad-ms", type=float, default=10.0)
    parser.add_argument("--min-valid-reference-ratio", type=float, default=0.98)
    parser.add_argument("--min-cycle-fraction", type=float, default=0.66)
    parser.add_argument("--cycle-cluster-radius-ms", type=float, default=20.0)
    parser.add_argument("--max-cycle-range-ms", type=float, default=20.0)
    parser.add_argument("--max-cycle-mad-ms", type=float, default=15.0)
    parser.add_argument("--max-estimate-slope-ms-per-min", type=float)
    parser.add_argument("--strong-peak-relative-score", type=float, default=0.45)
    parser.add_argument("--strong-peak-relative-count", type=float, default=0.5)
    parser.add_argument("--max-strong-peak-spread-ms", type=float, default=60.0)
    return parser.parse_args()


def _validate_args(args: argparse.Namespace) -> None:
    if args.samples < 1:
        raise ValueError("--samples must be >= 1")
    if args.interval_sec < 0:
        raise ValueError("--interval-sec must be >= 0")
    if args.max_monitor_drift_ms < 0:
        raise ValueError("--max-monitor-drift-ms must be >= 0")
    if args.max_trailing_inconclusive_samples < 0:
        raise ValueError("--max-trailing-inconclusive-samples must be >= 0")
    if getattr(args, "max_accepted_gap_samples", 0) < 0:
        raise ValueError("--max-accepted-gap-samples must be >= 0")
    if getattr(args, "min_final_accepted_run", 2) < 1:
        raise ValueError("--min-final-accepted-run must be >= 1")
    if args.min_sample_fraction < 0.0 or args.min_sample_fraction > 1.0:
        raise ValueError("--min-sample-fraction must be between 0 and 1")
    pce._validate_args(args)


def main() -> int:
    args = _parse_args()
    rows: list[dict[str, Any]] = []
    preflight_status: dict[str, Any] | None = None
    try:
        _validate_args(args)
        pce._check_socket_ready(args.socket)
        preflight_status = pce._passive_capture_preflight(args.socket)
        if args.preflight_only:
            payload = _preflight_payload(args, preflight_status)
            if args.report_path is not None:
                _write_json(args.report_path, payload)
            print(json.dumps(payload, indent=2, sort_keys=True))
            return EXIT_OK
        estimate_args = _estimate_args(args)
        started = time.time()
        for index in range(args.samples):
            sample_started = time.time()
            sample = _capture_sample(
                sample_index=index,
                args=args,
                estimate_args=estimate_args,
            )
            context = _sample_context(sample)
            row = {
                "index": index + 1,
                "unix_ts": round(sample_started, 3),
                "elapsed_s": round(sample_started - started, 3),
                "verdict": sample["verdict"],
                "delay_ms": sample["summary"].get("delay_ms"),
                "delay_mad_ms": sample["summary"].get("delay_mad_ms"),
                "delay_range_ms": sample["summary"].get("delay_range_ms"),
                "cycles_accepted": sample["summary"].get("cycles_accepted"),
                "cycles_clustered": sample["summary"].get("cycles_clustered"),
                "inconclusive_reason": sample["summary"].get("inconclusive_reason"),
                **context,
                "sample": sample,
            }
            rows.append(row)
            if args.jsonl_path is not None:
                _append_jsonl(args.jsonl_path, row)
            print(
                "sample=%d verdict=%s delay=%s reason=%s"
                % (
                    row["index"],
                    row["verdict"],
                    row["delay_ms"],
                    row["inconclusive_reason"],
                ),
                file=sys.stderr,
                flush=True,
            )
            if index < args.samples - 1 and args.interval_sec > 0:
                time.sleep(args.interval_sec)
        summary = _summarize_rows(
            rows,
            min_ok_fraction=args.min_sample_fraction,
            max_drift_ms=args.max_monitor_drift_ms,
            max_trailing_inconclusive_samples=args.max_trailing_inconclusive_samples,
            max_accepted_gap_samples=getattr(args, "max_accepted_gap_samples", 0),
            min_final_accepted_run=getattr(args, "min_final_accepted_run", 2),
        )
        payload = {
            "summary": summary,
            "preflight": preflight_status,
            "rows": rows,
        }
        if args.report_path is not None:
            _write_json(args.report_path, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return _exit_code_for_verdict(str(summary["verdict"]))
    except BaseException as exc:
        if isinstance(exc, SystemExit):
            raise
        reason = (
            f"interrupted: {type(exc).__name__}"
            if isinstance(exc, (KeyboardInterrupt,))
            else str(exc)
        )
        failure = _capture_failed_payload(reason, rows, preflight_status)
        report_write_error = None
        if getattr(args, "report_path", None) is not None:
            try:
                _write_json(args.report_path, failure)
            except Exception as report_exc:
                report_write_error = str(report_exc)
                failure["summary"]["report_write_error"] = report_write_error
        error_payload = {"verdict": "capture_failed", "error": reason}
        if report_write_error is not None:
            error_payload["report_write_error"] = report_write_error
        print(
            json.dumps(error_payload, indent=2),
            file=sys.stderr,
        )
        return EXIT_CAPTURE_FAILED


if __name__ == "__main__":
    raise SystemExit(main())
