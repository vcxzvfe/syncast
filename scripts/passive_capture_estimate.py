#!/usr/bin/env python3
"""Capture and estimate passive SyncCast delay evidence.

This diagnostic opens SyncCast's existing calibration socket and asks the
running app to record a no-probe passive snapshot: reference audio from the
router capture ring plus microphone audio from the selected calibration mic.
It then runs the offline passive estimator and, optionally, repeats the
capture several times to require a stable cross-cycle consensus.

It does not launch SyncCast, emit audio, change routes, or apply delay. The
app must already be running in Whole-home mode with real program audio.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import socket
import sys
import time
from pathlib import Path
from typing import Any

import passive_delay_estimator as estimator


EXIT_OK = 0
EXIT_CAPTURE_FAILED = 2
EXIT_INCONCLUSIVE = 3
SUPPORTED_PASSIVE_BACKENDS = {"sck", "tap"}

CAPTURE_CONTEXT_CHECKS = [
    ("contextSignature", "route context", "context_signatures"),
    ("currentDelayMs", "applied delay", "current_delay_values_ms"),
    ("enabledAirplayCount", "enabled AirPlay count", "enabled_airplay_counts"),
    ("activeAirplayCount", "active AirPlay count", "active_airplay_counts"),
    ("airplayTimingEpoch", "AirPlay timing epoch", "airplay_timing_epochs"),
    ("syncContextState", "sync context state", "sync_context_states"),
    ("syncContextRevision", "sync context revision", "sync_context_revisions"),
    ("backend", "capture backend", "capture_backends"),
    ("delayLocked", "delay lock state", "delay_lock_values"),
]

PREFLIGHT_CAPTURE_CONTEXT_PAIRS = [
    ("contextSignature", "contextSignature", "route context"),
    ("currentDelayMs", "currentDelayMs", "applied delay"),
    ("enabledAirplayCount", "enabledAirplayCount", "enabled AirPlay count"),
    ("activeAirplayCount", "activeAirplayCount", "active AirPlay count"),
    ("airplayTimingEpoch", "airplayTimingEpoch", "AirPlay timing epoch"),
    ("syncContextState", "syncContextState", "sync context state"),
    ("syncContextRevision", "syncContextRevision", "sync context revision"),
    ("captureBackend", "backend", "capture backend"),
    ("delayLocked", "delayLocked", "delay lock state"),
]

CAPTURE_END_CONTEXT_PAIRS = [
    ("contextSignature", "endContextSignature", "route context"),
    ("currentDelayMs", "endCurrentDelayMs", "applied delay"),
    ("enabledAirplayCount", "endEnabledAirplayCount", "enabled AirPlay count"),
    ("activeAirplayCount", "endActiveAirplayCount", "active AirPlay count"),
    ("airplayTimingEpoch", "endAirplayTimingEpoch", "AirPlay timing epoch"),
    ("syncContextState", "endSyncContextState", "sync context state"),
    ("syncContextRevision", "endSyncContextRevision", "sync context revision"),
    ("delayLocked", "endDelayLocked", "delay lock state"),
]

MIC_TIMING_FIELDS = (
    "sampleRate",
    "microphoneArmedAtNs",
    "microphoneFirstSampleAtNs",
    "microphoneStartPaddingFrames",
    "microphoneWarmupFramesDropped",
)


def _default_socket_path() -> Path:
    return Path(f"/tmp/syncast-{os.getuid()}.calibration.sock")


def _json_rpc(
    socket_path: Path,
    method: str,
    params: dict[str, Any],
    *,
    timeout_sec: float,
) -> dict[str, Any]:
    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    }
    payload = json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout_sec)
        sock.connect(str(socket_path))
        sock.sendall(payload)
        chunks: list[bytes] = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    if not chunks:
        raise RuntimeError(f"empty reply from {socket_path}")
    raw = b"".join(chunks).decode("utf-8", errors="replace").strip()
    response = json.loads(raw)
    if "error" in response:
        err = response["error"]
        raise RuntimeError(
            "%s failed: code=%s message=%s"
            % (method, err.get("code"), err.get("message"))
        )
    result = response.get("result")
    if not isinstance(result, dict):
        raise RuntimeError("passive_capture response did not contain a result object")
    return result


def _capture_once(
    *,
    socket_path: Path,
    duration_sec: float,
    max_delay_ms: int,
    output_directory: Path | None,
    timeout_sec: float,
) -> dict[str, Any]:
    params: dict[str, Any] = {
        "durationSec": duration_sec,
        "maxDelayMs": max_delay_ms,
    }
    if output_directory is not None:
        output_directory.mkdir(parents=True, exist_ok=True)
        params["outputDirectory"] = str(output_directory)
    return _json_rpc(
        socket_path,
        "passive_capture",
        params,
        timeout_sec=timeout_sec,
    )


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def _check_socket_ready(socket_path: Path) -> None:
    try:
        result = _json_rpc(socket_path, "ping", {}, timeout_sec=2.0)
    except Exception as exc:
        raise RuntimeError(
            f"diagnostic socket is not accepting ping at {socket_path}; "
            f"it may be stale, or the current sandbox may be blocking "
            f"Unix-socket access: {exc}"
        ) from exc
    if result.get("ok") is not True:
        raise RuntimeError(f"diagnostic socket ping returned unexpected result: {result!r}")


def _passive_status(socket_path: Path) -> dict[str, Any]:
    return _json_rpc(socket_path, "passive_status", {}, timeout_sec=2.0)


def _check_passive_status_ready(status: dict[str, Any]) -> None:
    if status.get("ok") is not True:
        raise RuntimeError(f"passive_status returned unexpected result: {status!r}")
    if status.get("passiveCaptureAvailable") is not True:
        raise RuntimeError(
            "passive capture is not available for the current route; "
            "enable at least one local CoreAudio output and one AirPlay output"
        )
    in_progress = status.get("inProgress")
    if in_progress is True:
        raise RuntimeError("passive capture is already in progress")
    if in_progress is not False:
        raise RuntimeError(
            f"passive capture busy state is missing or invalid: {in_progress!r}"
        )

    backend = str(status.get("captureBackend") or "").strip()
    if backend not in SUPPORTED_PASSIVE_BACKENDS:
        raise RuntimeError(
            "passive capture backend is not ready or unsupported: "
            f"{backend or 'missing'}"
        )

    enabled_airplay_count = status.get("enabledAirplayCount")
    if (
        type(enabled_airplay_count) is not int
        or enabled_airplay_count < 1
    ):
        raise RuntimeError(
            "passive capture requires at least one enabled AirPlay output; "
            f"enabledAirplayCount={enabled_airplay_count!r}"
        )

    active_airplay_count = status.get("activeAirplayCount")
    if (
        type(active_airplay_count) is not int
        or active_airplay_count != enabled_airplay_count
    ):
        raise RuntimeError(
            "passive capture requires every enabled AirPlay output to be "
            "connected before microphone capture; "
            f"activeAirplayCount={active_airplay_count!r} "
            f"enabledAirplayCount={enabled_airplay_count!r}"
        )

    current_delay_ms = status.get("currentDelayMs")
    if (
        isinstance(current_delay_ms, bool)
        or not isinstance(current_delay_ms, (int, float))
    ):
        raise RuntimeError(
            "passive capture current delay metadata is missing or invalid: "
            f"{current_delay_ms!r}"
        )

    delay_locked = status.get("delayLocked")
    if not isinstance(delay_locked, bool):
        raise RuntimeError(
            "passive capture delay-lock metadata is missing or invalid: "
            f"{delay_locked!r}"
        )

    if not str(status.get("contextSignature") or "").strip():
        raise RuntimeError("passive capture route context is missing")

    airplay_timing_epoch = status.get("airplayTimingEpoch")
    if type(airplay_timing_epoch) is not int or airplay_timing_epoch < 0:
        raise RuntimeError(
            "passive capture AirPlay timing epoch metadata is missing or invalid: "
            f"{airplay_timing_epoch!r}"
        )

    sync_context_state = str(status.get("syncContextState") or "").strip()
    if not sync_context_state:
        raise RuntimeError("passive capture sync context state is missing")
    known_sync_context_states = {
        "valid",
        "suspect",
        "measuring",
        "readyToDryRun",
        "dryRunReady",
        "applied",
        "locked",
    }
    if sync_context_state not in known_sync_context_states:
        raise RuntimeError(
            "passive capture sync context state is unknown: "
            f"{sync_context_state}"
        )
    if sync_context_state == "measuring":
        raise RuntimeError(
            "passive capture blocked while sync context is already measuring"
        )
    sync_context_revision = status.get("syncContextRevision")
    if type(sync_context_revision) is not int or sync_context_revision < 0:
        raise RuntimeError(
            "passive capture sync context revision metadata is missing or invalid: "
            f"{sync_context_revision!r}"
        )


def _passive_capture_preflight(socket_path: Path) -> dict[str, Any]:
    status = _passive_status(socket_path)
    _check_passive_status_ready(status)
    return status


def _estimate_capture(capture: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    ref_path = Path(str(capture.get("referencePath") or ""))
    mic_path = Path(str(capture.get("microphonePath") or ""))
    if not ref_path.exists() or not mic_path.exists():
        raise RuntimeError(
            "passive_capture did not write expected WAVs: reference=%s microphone=%s"
            % (ref_path, mic_path)
        )
    ref_sr, reference = estimator._read_pcm_wav(ref_path, None)
    mic_sr, microphone = estimator._read_pcm_wav(mic_path, None)
    if ref_sr != mic_sr:
        raise RuntimeError(
            f"reference/microphone sample-rate mismatch: {ref_sr} != {mic_sr}"
        )
    return estimator.estimate_delay(
        reference,
        microphone,
        ref_sr,
        min_ms=args.min_ms,
        max_ms=args.max_ms if args.max_ms is not None else float(capture["maxDelayMs"]),
        mode=args.mode,
        window_s=args.window_sec,
        hop_s=args.hop_sec,
        min_rms=args.min_rms,
        min_score=args.min_score,
        min_prominence=args.min_prominence,
        peak_separation_ms=args.peak_separation_ms,
        cluster_radius_ms=args.cluster_radius_ms,
        min_cluster_fraction=args.min_cluster_fraction,
        max_mad_ms=args.max_mad_ms,
        min_peak_z=args.min_peak_z,
        min_accepted_window_fraction=args.min_accepted_window_fraction,
        max_feature_delta_ms=getattr(args, "max_feature_delta_ms", 25.0),
    )


def _valid_reference_ratio(capture: dict[str, Any]) -> float:
    expected = int(capture.get("referenceFrames") or 0)
    valid = int(capture.get("validReferenceFrames") or 0)
    if expected <= 0:
        return 0.0
    return valid / float(expected)


def _cycle_is_accepted(cycle: dict[str, Any], *, min_valid_reference_ratio: float) -> bool:
    estimate = cycle.get("estimate") or {}
    if estimate.get("inconclusive_reason"):
        return False
    if estimate.get("delay_ms") is None:
        return False
    capture = cycle.get("capture") or {}
    if _microphone_timing_failure(capture) is not None:
        return False
    if _valid_reference_ratio(capture) < min_valid_reference_ratio:
        return False
    return True


def _estimate_slope_ms_per_min(cycle: dict[str, Any]) -> float | None:
    estimate = cycle.get("estimate") or {}
    value = estimate.get("slope_ms_per_min")
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return float(value)
    return None


def _is_int_metadata(value: Any) -> bool:
    return type(value) is int


def _is_number_metadata(value: Any) -> bool:
    return not isinstance(value, bool) and isinstance(value, (int, float))


def _microphone_timing_failure(
    capture: dict[str, Any],
    *,
    cycle_index: Any | None = None,
) -> dict[str, Any] | None:
    def gate(field: str, value: Any, reason: str) -> dict[str, Any]:
        detail = {
            "field": field,
            "value": value,
            "required_fields": list(MIC_TIMING_FIELDS),
        }
        if cycle_index is not None:
            detail["cycle_index"] = cycle_index
        return {
            "reason": reason,
            "timing_gate": detail,
        }

    sample_rate = capture.get("sampleRate")
    if not _is_number_metadata(sample_rate) or float(sample_rate) <= 0.0:
        return gate(
            "sampleRate",
            sample_rate,
            "passive capture microphone timing metadata is missing sampleRate",
        )

    armed_at = capture.get("microphoneArmedAtNs")
    if not _is_int_metadata(armed_at) or armed_at <= 0:
        return gate(
            "microphoneArmedAtNs",
            armed_at,
            "passive capture microphone timing metadata is missing arm timestamp",
        )

    first_sample_at = capture.get("microphoneFirstSampleAtNs")
    if not _is_int_metadata(first_sample_at) or first_sample_at <= 0:
        return gate(
            "microphoneFirstSampleAtNs",
            first_sample_at,
            "passive capture microphone timing metadata is missing first-sample timestamp",
        )
    if first_sample_at < armed_at:
        return gate(
            "microphoneFirstSampleAtNs",
            first_sample_at,
            "passive capture microphone first sample predates microphone arm point",
        )

    padding_frames = capture.get("microphoneStartPaddingFrames")
    if not _is_int_metadata(padding_frames) or padding_frames < 0:
        return gate(
            "microphoneStartPaddingFrames",
            padding_frames,
            "passive capture microphone timing metadata is missing start padding",
        )

    warmup_frames = capture.get("microphoneWarmupFramesDropped")
    if not _is_int_metadata(warmup_frames) or warmup_frames < 0:
        return gate(
            "microphoneWarmupFramesDropped",
            warmup_frames,
            "passive capture microphone timing metadata is missing warmup drop count",
        )

    expected_padding = int(round((first_sample_at - armed_at) * float(sample_rate) / 1e9))
    if abs(expected_padding - padding_frames) > 2:
        return gate(
            "microphoneStartPaddingFrames",
            padding_frames,
            (
                "passive capture microphone start padding is inconsistent with "
                f"arm/first-sample timing: {padding_frames} frames vs "
                f"expected {expected_padding}"
            ),
        )

    microphone_frames = capture.get("microphoneFrames")
    if (
        _is_int_metadata(microphone_frames)
        and padding_frames > microphone_frames
    ):
        return gate(
            "microphoneStartPaddingFrames",
            padding_frames,
            "passive capture microphone start padding exceeds microphone WAV frames",
        )

    return None


def _capture_context_failure(capture: dict[str, Any]) -> dict[str, Any] | None:
    stable_flag = capture.get("contextStableDuringCapture")
    if stable_flag is not True:
        if stable_flag is False:
            return {
                "reason": "passive capture reported route context change during capture",
                "context_gate": {
                    "field": "contextStableDuringCapture",
                    "context_stable_during_capture": False,
                },
            }
        return {
            "reason": (
                "passive capture context stability metadata is missing or invalid: "
                f"{stable_flag!r}"
            ),
            "context_gate": {
                "field": "contextStableDuringCapture",
                "value": stable_flag,
            },
        }
    if stable_flag is False:
        return {
            "reason": "passive capture reported route context change during capture",
            "context_gate": {
                "field": "contextStableDuringCapture",
                "context_stable_during_capture": False,
            },
        }
    for start_key, end_key, label in CAPTURE_END_CONTEXT_PAIRS:
        if _context_value_missing(capture.get(start_key)):
            return {
                "reason": (
                    f"incomplete passive capture context metadata for {label}: "
                    f"missing {start_key}"
                ),
                "context_gate": {
                    "field": start_key,
                    "missing": start_key,
                },
            }
        if _context_value_missing(capture.get(end_key)):
            return {
                "reason": (
                    f"incomplete passive capture context metadata for {label}: "
                    f"missing {end_key}"
                ),
                "context_gate": {
                    "field": end_key,
                    "missing": end_key,
                },
            }
        before = _normalized_context_value(capture.get(start_key))
        after = _normalized_context_value(capture.get(end_key))
        if before != after:
            return {
                "reason": (
                    f"passive capture {label} changed during capture: "
                    f"{before!r} -> {after!r}"
                ),
                "context_gate": {
                    "field": start_key,
                    "start": before,
                    "end": after,
                },
            }
    return None


def _context_value_missing(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, str) and not value.strip():
        return True
    return False


def _normalized_context_value(value: Any) -> Any:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return round(float(value), 3)
    return value


def _cycle_context_failure(cycles: list[dict[str, Any]]) -> dict[str, Any] | None:
    for cycle in cycles:
        index = cycle.get("index")
        preflight = cycle.get("preflight")
        if not isinstance(preflight, dict):
            return {
                "reason": "missing passive cycle preflight metadata",
                "context_gate": {
                    "field": "preflight",
                    "cycle_index": index,
                },
            }
        capture = cycle.get("capture")
        if not isinstance(capture, dict):
            return {
                "reason": "missing passive cycle capture metadata",
                "context_gate": {
                    "field": "capture",
                    "cycle_index": index,
                },
            }
        timing_failure = _microphone_timing_failure(
            capture,
            cycle_index=index,
        )
        if timing_failure is not None:
            return timing_failure
        for preflight_key, capture_key, label in PREFLIGHT_CAPTURE_CONTEXT_PAIRS:
            if _context_value_missing(preflight.get(preflight_key)):
                return {
                    "reason": (
                        f"incomplete passive preflight context metadata for {label}: "
                        f"missing {preflight_key}"
                    ),
                    "context_gate": {
                        "field": preflight_key,
                        "cycle_index": index,
                        "source": "preflight",
                    },
                }
            if _context_value_missing(capture.get(capture_key)):
                return {
                    "reason": (
                        f"incomplete passive capture context metadata for {label}: "
                        f"missing {capture_key}"
                    ),
                    "context_gate": {
                        "field": capture_key,
                        "cycle_index": index,
                        "source": "capture",
                    },
                }
            before = _normalized_context_value(preflight.get(preflight_key))
            after = _normalized_context_value(capture.get(capture_key))
            if before != after:
                return {
                    "reason": (
                        f"passive cycle {label} changed between preflight and capture: "
                        f"{before!r} -> {after!r}"
                    ),
                    "context_gate": {
                        "field": capture_key,
                        "cycle_index": index,
                        "preflight": before,
                        "capture": after,
                    },
                }
        failure = _capture_context_failure(capture)
        if failure is not None:
            return failure
    for key, label, output_key in CAPTURE_CONTEXT_CHECKS:
        present = []
        values = []
        seen = set()
        for cycle in cycles:
            capture = cycle.get("capture")
            if not isinstance(capture, dict):
                continue
            value = capture.get(key)
            if value is None or value == "":
                continue
            present.append(cycle)
            normalized = _normalized_context_value(value)
            marker = json.dumps(normalized, sort_keys=True)
            if marker in seen:
                continue
            seen.add(marker)
            values.append(normalized)
        if not present:
            continue
        detail = {
            "field": key,
            output_key: values,
            "cycles_with_value": len(present),
            "cycles_total": len(cycles),
        }
        if len(present) < len(cycles):
            return {
                "reason": (
                    f"incomplete passive cycle context metadata for {label}: "
                    f"{len(present)}/{len(cycles)} cycles"
                ),
                "context_gate": detail,
            }
        if len(values) > 1:
            return {
                "reason": f"passive cycle {label} changed during sample: {values}",
                "context_gate": detail,
            }
    return None


def _cycle_reject_reason(
    cycle: dict[str, Any],
    *,
    min_valid_reference_ratio: float,
    max_estimate_slope_ms_per_min: float | None = None,
) -> str | None:
    estimate = cycle.get("estimate") or {}
    reason = estimate.get("inconclusive_reason")
    if reason:
        return f"estimate inconclusive: {reason}"
    if estimate.get("delay_ms") is None:
        return "estimate missing delay_ms"
    slope = _estimate_slope_ms_per_min(cycle)
    if (
        max_estimate_slope_ms_per_min is not None
        and slope is not None
        and abs(slope) > max_estimate_slope_ms_per_min
    ):
        return (
            "estimate drift slope %.3fms/min > %.3fms/min"
            % (abs(slope), max_estimate_slope_ms_per_min)
        )
    capture = cycle.get("capture") or {}
    timing_failure = _microphone_timing_failure(capture)
    if timing_failure is not None:
        return timing_failure["reason"]
    ratio = _valid_reference_ratio(capture)
    if ratio < min_valid_reference_ratio:
        return (
            "valid reference ratio %.3f < %.3f"
            % (ratio, min_valid_reference_ratio)
        )
    return None


def _best_delay_cluster(
    cycles: list[dict[str, Any]],
    *,
    radius_ms: float,
) -> list[dict[str, Any]]:
    if not cycles:
        return []
    best: list[dict[str, Any]] = []
    best_score = -1.0
    for seed in cycles:
        seed_delay = float(seed["estimate"]["delay_ms"])
        cluster = [
            item
            for item in cycles
            if abs(float(item["estimate"]["delay_ms"]) - seed_delay) <= radius_ms
        ]
        score = sum(float((item["estimate"] or {}).get("mean_score") or 0.0) for item in cluster)
        if len(cluster) > len(best) or (len(cluster) == len(best) and score > best_score):
            best = cluster
            best_score = score
    return best


def _strong_peak_summary(
    estimate: dict[str, Any],
    *,
    relative_score: float,
    relative_count: float,
) -> dict[str, Any]:
    peaks = list(estimate.get("aggregate_peaks") or [])
    if not peaks:
        return {
            "count": 0,
            "spread_ms": None,
            "delays_ms": [],
        }
    strengths = [
        (
            p,
            float(p.get("mean_score") or 0.0)
            * math.sqrt(max(1, int(p.get("count") or 0))),
        )
        for p in peaks
    ]
    strongest_peak, top_strength = max(strengths, key=lambda row: row[1])
    strongest_count = max(1, int(strongest_peak.get("count") or 0))
    strength_floor = top_strength * max(0.0, relative_score)
    count_floor = max(1.0, strongest_count * max(0.0, relative_count))
    strong = [
        p
        for p, strength in strengths
        if strength >= strength_floor
        and int(p.get("count") or 0) >= count_floor
    ]
    delays = sorted(float(p["delay_ms"]) for p in strong if p.get("delay_ms") is not None)
    spread = None if not delays else round(max(delays) - min(delays), 3)
    return {
        "count": len(delays),
        "spread_ms": spread,
        "delays_ms": [round(value, 3) for value in delays],
    }


def _summarize_cycles(cycles: list[dict[str, Any]], args: argparse.Namespace) -> dict[str, Any]:
    max_estimate_slope_ms_per_min = getattr(
        args,
        "max_estimate_slope_ms_per_min",
        None,
    )
    if len(cycles) < 2 and not args.allow_single_cycle_accept:
        return {
            "ok": False,
            "delay_ms": None,
            "delay_mad_ms": None,
            "delay_range_ms": None,
            "cycles_total": len(cycles),
            "cycles_accepted": 0,
            "cycles_clustered": 0,
            "inconclusive_reason": (
                "single-cycle passive estimates are diagnostic-only; rerun with "
                "--cycles >= 2 or explicitly pass --allow-single-cycle-accept"
            ),
        }
    accepted = [
        cycle
        for cycle in cycles
        if _cycle_is_accepted(
            cycle,
            min_valid_reference_ratio=args.min_valid_reference_ratio,
        )
        and (
            max_estimate_slope_ms_per_min is None
            or (slope := _estimate_slope_ms_per_min(cycle)) is None
            or abs(slope) <= max_estimate_slope_ms_per_min
        )
    ]
    cycle_rejects = [
        {
            "index": cycle.get("index"),
            "reason": reason,
        }
        for cycle in cycles
        if (reason := _cycle_reject_reason(
            cycle,
            min_valid_reference_ratio=args.min_valid_reference_ratio,
            max_estimate_slope_ms_per_min=max_estimate_slope_ms_per_min,
        ))
        is not None
    ]
    required = max(1, int(math.ceil(len(cycles) * args.min_cycle_fraction)))

    context_failure = _cycle_context_failure(cycles)
    if context_failure is not None:
        result = {
            "ok": False,
            "delay_ms": None,
            "delay_mad_ms": None,
            "delay_range_ms": None,
            "cycles_total": len(cycles),
            "cycles_accepted": len(accepted),
            "cycles_clustered": 0,
            "inconclusive_reason": context_failure["reason"],
            "cycle_rejects": cycle_rejects,
        }
        if "context_gate" in context_failure:
            result["context_gate"] = context_failure["context_gate"]
        if "timing_gate" in context_failure:
            result["timing_gate"] = context_failure["timing_gate"]
        return result

    if len(accepted) < required:
        return {
            "ok": False,
            "delay_ms": None,
            "delay_mad_ms": None,
            "delay_range_ms": None,
            "cycles_total": len(cycles),
            "cycles_accepted": len(accepted),
            "cycles_clustered": 0,
            "inconclusive_reason": (
                f"only {len(accepted)}/{len(cycles)} cycles accepted, required {required}"
            ),
            "cycle_rejects": cycle_rejects,
        }

    ambiguous = []
    ambiguous_unmeasured = []
    if args.max_strong_peak_spread_ms is not None:
        for cycle in accepted:
            strong_peaks = cycle.get("strong_peaks") or {}
            try:
                strong_peak_count = int(strong_peaks.get("count") or 0)
            except (TypeError, ValueError):
                strong_peak_count = 0
            if strong_peak_count >= 2:
                spread = strong_peaks.get("spread_ms")
                try:
                    spread_value = float(spread)
                except (TypeError, ValueError):
                    ambiguous_unmeasured.append(cycle.get("index"))
                    continue
                if not math.isfinite(spread_value):
                    ambiguous_unmeasured.append(cycle.get("index"))
                    continue
                if spread_value > args.max_strong_peak_spread_ms:
                    ambiguous.append((cycle.get("index"), spread_value))
    if ambiguous_unmeasured:
        return {
            "ok": False,
            "delay_ms": None,
            "delay_mad_ms": None,
            "delay_range_ms": None,
            "cycles_total": len(cycles),
            "cycles_accepted": len(accepted),
            "cycles_clustered": 0,
            "inconclusive_reason": (
                "ambiguous strong aggregate peaks: missing or invalid spread_ms"
            ),
        }
    if ambiguous:
        worst = max(spread for _, spread in ambiguous)
        return {
            "ok": False,
            "delay_ms": None,
            "delay_mad_ms": None,
            "delay_range_ms": None,
            "cycles_total": len(cycles),
            "cycles_accepted": len(accepted),
            "cycles_clustered": 0,
            "inconclusive_reason": (
                "ambiguous strong aggregate peaks: max spread %.3fms > %.3fms"
                % (worst, args.max_strong_peak_spread_ms)
            ),
        }

    cluster = _best_delay_cluster(accepted, radius_ms=args.cycle_cluster_radius_ms)
    if len(cluster) < required:
        return {
            "ok": False,
            "delay_ms": None,
            "delay_mad_ms": None,
            "delay_range_ms": None,
            "cycles_total": len(cycles),
            "cycles_accepted": len(accepted),
            "cycles_clustered": len(cluster),
            "inconclusive_reason": (
                "no cross-cycle delay consensus: best %d/%d cycles, required %d"
                % (len(cluster), len(cycles), required)
            ),
        }

    delays = sorted(float(item["estimate"]["delay_ms"]) for item in cluster)
    slopes = sorted(
        slope
        for item in cluster
        if (slope := _estimate_slope_ms_per_min(item)) is not None
    )
    delay_range = max(delays) - min(delays)
    median = delays[len(delays) // 2] if len(delays) % 2 else (
        delays[len(delays) // 2 - 1] + delays[len(delays) // 2]
    ) / 2.0
    mad_values = sorted(abs(value - median) for value in delays)
    mad = mad_values[len(mad_values) // 2] if len(mad_values) % 2 else (
        mad_values[len(mad_values) // 2 - 1] + mad_values[len(mad_values) // 2]
    ) / 2.0
    slope_median = None
    slope_range = None
    if slopes:
        slope_median = slopes[len(slopes) // 2] if len(slopes) % 2 else (
            slopes[len(slopes) // 2 - 1] + slopes[len(slopes) // 2]
        ) / 2.0
        slope_range = max(slopes) - min(slopes)
    if delay_range > args.max_cycle_range_ms:
        return {
            "ok": False,
            "delay_ms": round(median, 3),
            "delay_mad_ms": round(mad, 3),
            "delay_range_ms": round(delay_range, 3),
            "cycles_total": len(cycles),
            "cycles_accepted": len(accepted),
            "cycles_clustered": len(cluster),
            "inconclusive_reason": (
                f"cross-cycle delay range too wide: {delay_range:.3f}ms > "
                f"{args.max_cycle_range_ms:.3f}ms"
            ),
        }
    if mad > args.max_cycle_mad_ms:
        return {
            "ok": False,
            "delay_ms": round(median, 3),
            "delay_mad_ms": round(mad, 3),
            "delay_range_ms": round(delay_range, 3),
            "cycles_total": len(cycles),
            "cycles_accepted": len(accepted),
            "cycles_clustered": len(cluster),
            "inconclusive_reason": (
                f"cross-cycle delay cluster too wide: MAD {mad:.3f}ms > "
                f"{args.max_cycle_mad_ms:.3f}ms"
            ),
        }

    return {
        "ok": True,
        "delay_ms": round(median, 3),
        "delay_mad_ms": round(mad, 3),
        "delay_range_ms": round(delay_range, 3),
        "estimate_slope_ms_per_min": None
        if slope_median is None
        else round(slope_median, 3),
        "estimate_slope_range_ms_per_min": None
        if slope_range is None
        else round(slope_range, 3),
        "cycles_total": len(cycles),
        "cycles_accepted": len(accepted),
        "cycles_clustered": len(cluster),
        "inconclusive_reason": None,
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Capture passive SyncCast reference/mic WAV evidence and estimate "
            "delay without emitting calibration audio."
        )
    )
    parser.add_argument("--socket", type=Path, default=_default_socket_path())
    parser.add_argument("--duration-sec", type=float, default=4.0)
    parser.add_argument("--max-delay-ms", type=int, default=3500)
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--report-path", type=Path)
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument(
        "--preflight-only",
        action="store_true",
        help=(
            "validate args, diagnostic socket reachability, and route readiness, "
            "then exit before opening the microphone"
        ),
    )
    parser.add_argument("--allow-single-cycle-accept", action="store_true")
    parser.add_argument("--interval-sec", type=float, default=0.0)
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
    if args.cycles < 1:
        raise ValueError("--cycles must be >= 1")
    if args.duration_sec <= 0:
        raise ValueError("--duration-sec must be > 0")
    if args.max_delay_ms < 0:
        raise ValueError("--max-delay-ms must be >= 0")
    if args.min_ms < 0:
        raise ValueError("--min-ms must be >= 0")
    if args.window_sec <= 0:
        raise ValueError("--window-sec must be > 0")
    if args.hop_sec <= 0:
        raise ValueError("--hop-sec must be > 0")
    if args.min_rms < 0:
        raise ValueError("--min-rms must be >= 0")
    if args.min_score < 0:
        raise ValueError("--min-score must be >= 0")
    if args.min_prominence < 0:
        raise ValueError("--min-prominence must be >= 0")
    if args.min_peak_z < 0:
        raise ValueError("--min-peak-z must be >= 0")
    if args.min_accepted_window_fraction < 0 or args.min_accepted_window_fraction > 1:
        raise ValueError("--min-accepted-window-fraction must be between 0 and 1")
    if getattr(args, "max_feature_delta_ms", 25.0) < 0:
        raise ValueError("--max-feature-delta-ms must be >= 0")
    if args.peak_separation_ms <= 0:
        raise ValueError("--peak-separation-ms must be > 0")
    if args.cluster_radius_ms < 0:
        raise ValueError("--cluster-radius-ms must be >= 0")
    if args.max_mad_ms < 0:
        raise ValueError("--max-mad-ms must be >= 0")
    if args.cycle_cluster_radius_ms < 0:
        raise ValueError("--cycle-cluster-radius-ms must be >= 0")
    if args.max_cycle_range_ms < 0:
        raise ValueError("--max-cycle-range-ms must be >= 0")
    if args.max_cycle_mad_ms < 0:
        raise ValueError("--max-cycle-mad-ms must be >= 0")
    if (
        getattr(args, "max_estimate_slope_ms_per_min", None) is not None
        and getattr(args, "max_estimate_slope_ms_per_min") < 0
    ):
        raise ValueError("--max-estimate-slope-ms-per-min must be >= 0")
    if args.max_strong_peak_spread_ms is not None and args.max_strong_peak_spread_ms < 0:
        raise ValueError("--max-strong-peak-spread-ms must be >= 0")
    if args.max_ms is not None and args.max_ms < args.min_ms:
        raise ValueError("--max-ms must be >= --min-ms")
    if args.max_ms is not None and args.max_ms > args.max_delay_ms:
        raise ValueError("--max-ms must be <= --max-delay-ms")
    for name in (
        "min_cluster_fraction",
        "min_valid_reference_ratio",
        "min_cycle_fraction",
        "strong_peak_relative_score",
        "strong_peak_relative_count",
    ):
        value = float(getattr(args, name))
        if value < 0.0 or value > 1.0:
            raise ValueError(f"--{name.replace('_', '-')} must be between 0 and 1")
    if not args.socket.exists():
        raise FileNotFoundError(
            f"socket not found at {args.socket}; SyncCast must be running in Whole-home mode"
        )


def main() -> int:
    args = _parse_args()
    try:
        _validate_args(args)
        _check_socket_ready(args.socket)
        first_preflight = _passive_capture_preflight(args.socket)
        if args.preflight_only:
            payload = {
                "verdict": "preflight_ok",
                "socket": str(args.socket),
                "cycles": args.cycles,
                "durationSec": args.duration_sec,
                "maxDelayMs": args.max_delay_ms,
                "opensMicrophone": False,
                "emitsAudio": False,
                "appliesDelay": False,
                "status": first_preflight,
            }
            if args.report_path is not None:
                _write_json(args.report_path, payload)
            print(json.dumps(payload, indent=2, sort_keys=True))
            return EXIT_OK

        cycles: list[dict[str, Any]] = []
        preflight_statuses: list[dict[str, Any]] = []
        for index in range(args.cycles):
            preflight_status = (
                first_preflight if index == 0 else _passive_capture_preflight(args.socket)
            )
            preflight_statuses.append(preflight_status)
            output_dir = None
            if args.output_root is not None:
                output_dir = args.output_root / f"cycle-{index + 1:03d}"
            timeout = args.duration_sec + args.max_delay_ms / 1000.0 + 15.0
            capture = _capture_once(
                socket_path=args.socket,
                duration_sec=args.duration_sec,
                max_delay_ms=args.max_delay_ms,
                output_directory=output_dir,
                timeout_sec=timeout,
            )
            estimate = _estimate_capture(capture, args)
            cycles.append(
                {
                    "index": index + 1,
                    "preflight": preflight_status,
                    "capture": capture,
                    "estimate": estimate,
                    "strong_peaks": _strong_peak_summary(
                        estimate,
                        relative_score=args.strong_peak_relative_score,
                        relative_count=args.strong_peak_relative_count,
                    ),
                }
            )
            if index < args.cycles - 1 and args.interval_sec > 0:
                time.sleep(args.interval_sec)
        summary = _summarize_cycles(cycles, args)
        payload = {
            "verdict": "accepted" if summary["ok"] else "inconclusive",
            "summary": summary,
            "preflight": preflight_statuses[0] if preflight_statuses else None,
            "preflights": preflight_statuses,
            "cycles": cycles,
        }
        if args.report_path is not None:
            _write_json(args.report_path, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return EXIT_OK if summary["ok"] else EXIT_INCONCLUSIVE
    except Exception as exc:
        payload = {
            "verdict": "capture_failed",
            "error": str(exc),
        }
        if getattr(args, "report_path", None) is not None:
            try:
                _write_json(args.report_path, payload)
            except Exception as report_exc:
                payload["report_write_error"] = str(report_exc)
        print(json.dumps(payload, indent=2, sort_keys=True), file=sys.stderr)
        return EXIT_CAPTURE_FAILED


if __name__ == "__main__":
    raise SystemExit(main())
