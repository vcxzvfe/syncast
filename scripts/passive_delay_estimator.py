#!/usr/bin/env python3
"""Estimate acoustic delay from ordinary program audio.

This is an offline, no-audio diagnostic tool. It does not open CoreAudio,
start SyncCast, or emit any probe. Given a reference WAV (the PCM that was
sent to outputs) and a microphone WAV recorded at the same time, it searches
for the delay where the microphone best correlates with the reference.

The intent is to develop the passive calibration path before wiring it into
the live app: prove confidence gates, multi-peak reporting, and failure modes
on files first.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np


EXIT_OK = 0
EXIT_NO_DATA = 2
EXIT_INCONCLUSIVE = 3


@dataclass(frozen=True)
class Peak:
    delay_ms: float
    score: float


@dataclass(frozen=True)
class WindowEstimate:
    ref_start_s: float
    delay_ms: float
    score: float
    second_score: float
    prominence: float
    peak_z: float
    peaks: tuple[Peak, ...]


@dataclass(frozen=True)
class ClusterResult:
    estimates: tuple[WindowEstimate, ...]
    median_delay_ms: float
    mad_ms: float
    mean_score: float
    median_prominence: float
    reason: str | None


def _number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return float(value)
    return None


def _next_pow2(value: int) -> int:
    out = 1
    while out < value:
        out <<= 1
    return out


def _read_pcm_wav(path: Path, max_duration_s: float | None) -> tuple[int, np.ndarray]:
    with wave.open(str(path), "rb") as handle:
        channels = handle.getnchannels()
        sample_width = handle.getsampwidth()
        sample_rate = handle.getframerate()
        frames = handle.getnframes()
        if max_duration_s is not None:
            frames = min(frames, int(max_duration_s * sample_rate))
        raw = handle.readframes(frames)

    frame_bytes = sample_width * channels
    if frame_bytes <= 0:
        raise ValueError(f"{path}: invalid PCM frame size")
    if len(raw) % frame_bytes != 0:
        raise ValueError(f"{path}: truncated PCM frame data")

    if sample_width == 1:
        data = np.frombuffer(raw, dtype=np.uint8).astype(np.float32)
        data = (data - 128.0) / 128.0
    elif sample_width == 2:
        data = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    elif sample_width == 3:
        bytes_ = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        signed = (
            bytes_[:, 0].astype(np.int32)
            | (bytes_[:, 1].astype(np.int32) << 8)
            | (bytes_[:, 2].astype(np.int32) << 16)
        )
        signed = np.where(signed & 0x800000, signed | ~0xFFFFFF, signed)
        data = signed.astype(np.float32) / 8_388_608.0
    elif sample_width == 4:
        data = np.frombuffer(raw, dtype="<i4").astype(np.float32) / 2_147_483_648.0
    else:
        raise ValueError(f"{path}: unsupported PCM sample width {sample_width}")

    if channels <= 0:
        raise ValueError(f"{path}: invalid channel count {channels}")
    if data.size % channels != 0:
        raise ValueError(f"{path}: truncated PCM frame data")
    data = data.reshape(-1, channels).mean(axis=1)
    return sample_rate, np.asarray(data, dtype=np.float32)


def _moving_average(values: np.ndarray, width: int) -> np.ndarray:
    width = max(1, int(width))
    if width == 1:
        return values
    kernel = np.ones(width, dtype=np.float32) / float(width)
    return np.convolve(values, kernel, mode="same")


def _envelope(signal: np.ndarray, sample_rate: int) -> tuple[int, np.ndarray]:
    win = max(1, int(round(sample_rate * 0.020)))
    hop = max(1, int(round(sample_rate * 0.005)))
    if signal.size < win:
        return sample_rate, signal.copy()
    power = signal.astype(np.float32) ** 2
    rms = np.sqrt(_moving_average(power, win))[::hop]
    compressed = np.log1p(20.0 * rms).astype(np.float32)
    trend = _moving_average(compressed, max(1, int(round(1.0 / 0.005))))
    env = compressed - trend
    env_sr = int(round(sample_rate / hop))
    return env_sr, env.astype(np.float32)


def _prepare_signal(
    reference: np.ndarray,
    microphone: np.ndarray,
    sample_rate: int,
    mode: str,
) -> tuple[int, np.ndarray, np.ndarray]:
    ref = reference.astype(np.float32)
    mic = microphone.astype(np.float32)
    if mode == "envelope":
        env_sr, ref_env = _envelope(ref, sample_rate)
        mic_env_sr, mic_env = _envelope(mic, sample_rate)
        if mic_env_sr != env_sr:
            raise ValueError("internal envelope sample-rate mismatch")
        return env_sr, ref_env, mic_env
    if mode != "waveform":
        raise ValueError(f"unsupported mode {mode}")
    # First difference suppresses slow room/level changes and emphasizes
    # content transients. Polarity is handled later by absolute correlation.
    ref = np.diff(ref, prepend=ref[:1])
    mic = np.diff(mic, prepend=mic[:1])
    return sample_rate, ref.astype(np.float32), mic.astype(np.float32)


def _normalized_scores(
    ref_window: np.ndarray,
    mic_segment: np.ndarray,
) -> np.ndarray:
    ref = ref_window.astype(np.float32) - float(np.mean(ref_window))
    seg = mic_segment.astype(np.float32)
    ref_energy = float(np.dot(ref, ref))
    if ref_energy <= 1e-12:
        return np.empty(0, dtype=np.float32)
    n_scores = seg.size - ref.size + 1
    if n_scores <= 0:
        return np.empty(0, dtype=np.float32)
    nfft = _next_pow2(seg.size + ref.size - 1)
    corr = np.fft.irfft(
        np.fft.rfft(seg, nfft) * np.conj(np.fft.rfft(ref, nfft)),
        nfft,
    )[:n_scores]
    sum_cumsum = np.concatenate(([0.0], np.cumsum(seg.astype(np.float64))))
    energy_cumsum = np.concatenate(([0.0], np.cumsum((seg * seg).astype(np.float64))))
    seg_sum = sum_cumsum[ref.size:] - sum_cumsum[:-ref.size]
    seg_sum_sq = energy_cumsum[ref.size:] - energy_cumsum[:-ref.size]
    seg_energy = seg_sum_sq - (seg_sum * seg_sum / float(ref.size))
    denom = np.sqrt(np.maximum(seg_energy * ref_energy, 1e-12))
    return np.abs(corr / denom).astype(np.float32)


def _pick_peaks(
    scores: np.ndarray,
    sample_rate: int,
    min_delay_samples: int,
    min_separation_ms: float,
    limit: int,
) -> list[Peak]:
    if scores.size == 0:
        return []
    min_sep = max(1, int(round(sample_rate * min_separation_ms / 1000.0)))
    candidates: list[tuple[float, int]] = []
    if scores.size == 1:
        candidates.append((float(scores[0]), 0))
    elif float(scores[0]) >= float(scores[1]):
        candidates.append((float(scores[0]), 0))
    for idx in range(1, scores.size - 1):
        value = float(scores[idx])
        if value >= float(scores[idx - 1]) and value >= float(scores[idx + 1]):
            candidates.append((value, idx))
    if scores.size > 1 and float(scores[-1]) >= float(scores[-2]):
        candidates.append((float(scores[-1]), scores.size - 1))
    if not candidates:
        idx = int(np.argmax(scores))
        candidates = [(float(scores[idx]), idx)]
    selected: list[tuple[float, int]] = []
    for value, idx in sorted(candidates, reverse=True):
        if all(abs(idx - other_idx) >= min_sep for _, other_idx in selected):
            selected.append((value, idx))
            if len(selected) >= limit:
                break
    return [
        Peak(
            delay_ms=(min_delay_samples + idx) * 1000.0 / sample_rate,
            score=value,
        )
        for value, idx in selected
    ]


def _dominant_cluster(
    estimates: list[WindowEstimate],
    *,
    radius_ms: float,
    min_fraction: float,
    max_mad_ms: float,
) -> ClusterResult:
    if not estimates:
        return ClusterResult((), math.nan, math.nan, 0.0, 0.0, "no accepted windows")
    radius_ms = max(0.0, radius_ms)
    min_fraction = min(1.0, max(0.0, min_fraction))
    required = max(2, int(math.ceil(len(estimates) * min_fraction)))
    best: list[WindowEstimate] = []
    best_score = -1.0
    for seed in estimates:
        cluster = [
            item
            for item in estimates
            if abs(item.delay_ms - seed.delay_ms) <= radius_ms
        ]
        score_sum = sum(item.score for item in cluster)
        if len(cluster) > len(best) or (
            len(cluster) == len(best) and score_sum > best_score
        ):
            best = cluster
            best_score = score_sum
    if len(best) < required:
        return ClusterResult(
            tuple(best),
            math.nan,
            math.nan,
            0.0,
            0.0,
            f"no dominant delay cluster: best {len(best)}/{len(estimates)} windows, required {required}",
        )
    delays = np.asarray([item.delay_ms for item in best], dtype=np.float64)
    scores = np.asarray([item.score for item in best], dtype=np.float64)
    median_delay = float(np.median(delays))
    mad = float(np.median(np.abs(delays - median_delay)))
    if mad > max_mad_ms:
        return ClusterResult(
            tuple(best),
            median_delay,
            mad,
            float(np.mean(scores)),
            float(np.median([item.prominence for item in best])),
            f"dominant delay cluster too wide: MAD {mad:.3f}ms > {max_mad_ms:.3f}ms",
        )
    return ClusterResult(
        tuple(best),
        median_delay,
        mad,
        float(np.mean(scores)),
        float(np.median([item.prominence for item in best])),
        None,
    )


def _path_candidates(
    windows: list[WindowEstimate],
    *,
    radius_ms: float,
    min_fraction: float,
    max_mad_ms: float,
    max_paths: int,
    min_peak_score: float,
    min_relative_peak_score: float = 0.45,
) -> list[dict[str, Any]]:
    peak_rows = []
    for window_index, window in enumerate(windows):
        for peak in window.peaks:
            if peak.score < min_peak_score:
                continue
            if peak.score < window.score * max(0.0, min_relative_peak_score):
                continue
            peak_rows.append(
                {
                    "window_index": window_index,
                    "ref_start_s": window.ref_start_s,
                    "delay_ms": peak.delay_ms,
                    "score": peak.score,
                }
            )
    if not peak_rows:
        return []
    radius_ms = max(0.0, radius_ms)
    min_fraction = min(1.0, max(0.0, min_fraction))
    required = max(1, int(math.ceil(len(windows) * min_fraction)))
    remaining = list(peak_rows)
    candidates: list[dict[str, Any]] = []
    while remaining and len(candidates) < max_paths:
        best_cluster: list[dict[str, Any]] = []
        best_score = -1.0
        for seed in remaining:
            cluster = [
                row
                for row in remaining
                if abs(float(row["delay_ms"]) - float(seed["delay_ms"])) <= radius_ms
            ]
            window_count = len({int(row["window_index"]) for row in cluster})
            score_sum = sum(float(row["score"]) for row in cluster)
            weighted = window_count * 10.0 + score_sum
            if weighted > best_score:
                best_cluster = cluster
                best_score = weighted
        if not best_cluster:
            break
        window_indices = {int(row["window_index"]) for row in best_cluster}
        delays = np.asarray([float(row["delay_ms"]) for row in best_cluster], dtype=np.float64)
        scores = np.asarray([float(row["score"]) for row in best_cluster], dtype=np.float64)
        median_delay = float(np.median(delays))
        mad = float(np.median(np.abs(delays - median_delay)))
        if len(window_indices) >= required and mad <= max_mad_ms:
            candidates.append(
                {
                    "delay_ms": round(median_delay, 3),
                    "delay_mad_ms": round(mad, 3),
                    "window_count": len(window_indices),
                    "window_fraction": round(len(window_indices) / max(1, len(windows)), 3),
                    "mean_score": round(float(np.mean(scores)), 6),
                    "max_score": round(float(np.max(scores)), 6),
                }
            )
        used = set()
        for row in best_cluster:
            used.add((int(row["window_index"]), round(float(row["delay_ms"]), 6)))
        remaining = [
            row
            for row in remaining
            if (int(row["window_index"]), round(float(row["delay_ms"]), 6)) not in used
        ]
    candidates.sort(
        key=lambda row: (
            row["window_count"],
            row["mean_score"],
            row["max_score"],
        ),
        reverse=True,
    )
    return candidates


def _drift_summary(estimates: tuple[WindowEstimate, ...]) -> dict[str, Any]:
    if len(estimates) < 2:
        return {
            "slope_ms_per_min": None,
            "drift_ppm": None,
            "fitted_span_ms": None,
            "residual_mad_ms": None,
            "window_span_s": 0.0,
        }
    times = np.asarray([item.ref_start_s for item in estimates], dtype=np.float64)
    delays = np.asarray([item.delay_ms for item in estimates], dtype=np.float64)
    span = float(np.max(times) - np.min(times))
    if span <= 1e-9:
        return {
            "slope_ms_per_min": 0.0,
            "drift_ppm": 0.0,
            "fitted_span_ms": 0.0,
            "residual_mad_ms": 0.0,
            "window_span_s": 0.0,
        }
    centered = times - float(np.mean(times))
    denom = float(np.dot(centered, centered))
    if denom <= 1e-12:
        slope_ms_per_s = 0.0
    else:
        slope_ms_per_s = float(np.dot(centered, delays - float(np.mean(delays))) / denom)
    intercept = float(np.mean(delays) - slope_ms_per_s * np.mean(times))
    fitted = intercept + slope_ms_per_s * times
    residuals = delays - fitted
    residual_mad = float(np.median(np.abs(residuals - np.median(residuals))))
    return {
        "slope_ms_per_min": round(slope_ms_per_s * 60.0, 3),
        "drift_ppm": round(slope_ms_per_s * 1000.0, 3),
        "fitted_span_ms": round(slope_ms_per_s * span, 3),
        "residual_mad_ms": round(residual_mad, 3),
        "window_span_s": round(span, 3),
    }


def _accepted_window_map(result: dict[str, Any]) -> dict[float, dict[str, float]]:
    rows: dict[float, dict[str, float]] = {}
    for item in result.get("accepted_windows") or []:
        if not isinstance(item, dict):
            continue
        ref_start_s = _number(item.get("ref_start_s"))
        delay_ms = _number(item.get("delay_ms"))
        if ref_start_s is None or delay_ms is None:
            continue
        key = round(ref_start_s, 3)
        rows[key] = {
            "ref_start_s": key,
            "delay_ms": delay_ms,
            "score": _number(item.get("score")) or 0.0,
            "prominence": _number(item.get("prominence")) or 0.0,
            "peak_z": _number(item.get("peak_z")) or 0.0,
        }
    return rows


def _dual_window_agreement(
    waveform: dict[str, Any],
    envelope: dict[str, Any],
    *,
    max_delta_ms: float,
    cluster_radius_ms: float,
    min_cluster_fraction: float,
    max_mad_ms: float,
) -> tuple[ClusterResult, list[dict[str, Any]], int, str | None]:
    waveform_windows = _accepted_window_map(waveform)
    envelope_windows = _accepted_window_map(envelope)
    overlap_keys = sorted(set(waveform_windows) & set(envelope_windows))
    overlapped: list[dict[str, Any]] = []
    for key in overlap_keys:
        wave = waveform_windows[key]
        env = envelope_windows[key]
        delta_ms = abs(wave["delay_ms"] - env["delay_ms"])
        row = {
            "ref_start_s": key,
            "delay_ms": float(np.median([wave["delay_ms"], env["delay_ms"]])),
            "waveform_delay_ms": wave["delay_ms"],
            "envelope_delay_ms": env["delay_ms"],
            "delta_ms": delta_ms,
            "score": min(wave["score"], env["score"]),
            "prominence": min(wave["prominence"], env["prominence"]),
            "peak_z": min(wave["peak_z"], env["peak_z"]),
        }
        if delta_ms <= max_delta_ms:
            overlapped.append(row)

    feature_clustered = min(
        int(waveform.get("windows_clustered") or 0),
        int(envelope.get("windows_clustered") or 0),
    )
    required = max(2, int(math.ceil(feature_clustered * min_cluster_fraction)))
    if len(overlap_keys) < required:
        return (
            ClusterResult((), math.nan, math.nan, 0.0, 0.0, None),
            overlapped,
            len(overlap_keys),
            (
                "feature window overlap too sparse: "
                f"{len(overlap_keys)}/{feature_clustered} windows, required {required}"
            ),
        )
    if len(overlapped) < required:
        return (
            ClusterResult((), math.nan, math.nan, 0.0, 0.0, None),
            overlapped,
            len(overlap_keys),
            (
                "feature window agreement too sparse: "
                f"{len(overlapped)}/{len(overlap_keys)} overlap windows, required {required}"
            ),
        )

    estimates = [
        WindowEstimate(
            ref_start_s=float(row["ref_start_s"]),
            delay_ms=float(row["delay_ms"]),
            score=float(row["score"]),
            second_score=0.0,
            prominence=float(row["prominence"]),
            peak_z=float(row["peak_z"]),
            peaks=(Peak(delay_ms=float(row["delay_ms"]), score=float(row["score"])),),
        )
        for row in overlapped
    ]
    cluster = _dominant_cluster(
        estimates,
        radius_ms=cluster_radius_ms,
        min_fraction=min_cluster_fraction,
        max_mad_ms=max_mad_ms,
    )
    if cluster.reason is not None:
        return (
            cluster,
            overlapped,
            len(overlap_keys),
            "feature overlap cluster rejected: " + cluster.reason,
        )
    return cluster, overlapped, len(overlap_keys), None


def _dual_path_candidate_agreement(
    waveform: dict[str, Any],
    envelope: dict[str, Any],
    *,
    max_delta_ms: float,
) -> list[dict[str, Any]]:
    waveform_candidates = [
        row
        for row in (waveform.get("path_candidates") or [])
        if isinstance(row, dict) and _number(row.get("delay_ms")) is not None
    ]
    envelope_candidates = [
        row
        for row in (envelope.get("path_candidates") or [])
        if isinstance(row, dict) and _number(row.get("delay_ms")) is not None
    ]
    used_envelope: set[int] = set()
    agreed: list[dict[str, Any]] = []
    for wave in waveform_candidates:
        wave_delay = _number(wave.get("delay_ms"))
        if wave_delay is None:
            continue
        best_index = None
        best_delta = math.inf
        best_env: dict[str, Any] | None = None
        for index, env in enumerate(envelope_candidates):
            if index in used_envelope:
                continue
            env_delay = _number(env.get("delay_ms"))
            if env_delay is None:
                continue
            delta = abs(wave_delay - env_delay)
            if delta <= max_delta_ms and delta < best_delta:
                best_index = index
                best_delta = delta
                best_env = env
        if best_index is None or best_env is None:
            continue
        used_envelope.add(best_index)
        env_delay = _number(best_env.get("delay_ms"))
        assert env_delay is not None
        delay = float(np.median([wave_delay, env_delay]))
        wave_fraction = _number(wave.get("window_fraction"))
        env_fraction = _number(best_env.get("window_fraction"))
        wave_mean = _number(wave.get("mean_score"))
        env_mean = _number(best_env.get("mean_score"))
        wave_max = _number(wave.get("max_score"))
        env_max = _number(best_env.get("max_score"))
        wave_count = wave.get("window_count")
        env_count = best_env.get("window_count")
        agreed.append(
            {
                "delay_ms": round(delay, 3),
                "delay_mad_ms": round(
                    max(
                        _number(wave.get("delay_mad_ms")) or 0.0,
                        _number(best_env.get("delay_mad_ms")) or 0.0,
                        best_delta / 2.0,
                    ),
                    3,
                ),
                "window_count": min(
                    wave_count if type(wave_count) is int else 0,
                    env_count if type(env_count) is int else 0,
                ),
                "window_fraction": round(
                    min(wave_fraction or 0.0, env_fraction or 0.0),
                    3,
                ),
                "mean_score": round(min(wave_mean or 0.0, env_mean or 0.0), 6),
                "max_score": round(min(wave_max or 0.0, env_max or 0.0), 6),
                "feature_delta_ms": round(best_delta, 3),
                "waveform_delay_ms": round(wave_delay, 3),
                "envelope_delay_ms": round(env_delay, 3),
            }
        )
    agreed.sort(
        key=lambda row: (
            row["window_count"],
            row["window_fraction"],
            row["mean_score"],
            row["max_score"],
        ),
        reverse=True,
    )
    return agreed


def _estimate_delay_single(
    reference: np.ndarray,
    microphone: np.ndarray,
    sample_rate: int,
    *,
    min_ms: float,
    max_ms: float,
    mode: str,
    window_s: float,
    hop_s: float,
    min_rms: float,
    min_score: float,
    min_prominence: float,
    peak_separation_ms: float,
    cluster_radius_ms: float,
    min_cluster_fraction: float,
    max_mad_ms: float,
    min_peak_z: float = 6.0,
    min_accepted_window_fraction: float = 0.50,
) -> dict[str, Any]:
    work_sr, ref, mic = _prepare_signal(reference, microphone, sample_rate, mode)
    min_delay = max(0, int(round(min_ms * work_sr / 1000.0)))
    max_delay = max(min_delay, int(round(max_ms * work_sr / 1000.0)))
    window = max(1, int(round(window_s * work_sr)))
    hop = max(1, int(round(hop_s * work_sr)))
    max_ref_start = min(ref.size - window, mic.size - max_delay - window)
    if max_ref_start < 0:
        raise ValueError(
            "recordings are too short for the requested delay range/window"
        )

    global_rms = float(np.sqrt(np.mean(ref * ref))) if ref.size else 0.0
    rms_floor = max(min_rms, global_rms * 0.05)
    estimates: list[WindowEstimate] = []
    all_peak_bins: dict[int, list[float]] = {}
    bin_ms = max(1.0, peak_separation_ms / 2.0)
    windows_considered = 0

    for start in range(0, max_ref_start + 1, hop):
        ref_window = ref[start : start + window]
        ref_rms = float(np.sqrt(np.mean(ref_window * ref_window)))
        if ref_rms < rms_floor:
            continue
        windows_considered += 1
        mic_start = start + min_delay
        mic_stop = start + max_delay + window
        scores = _normalized_scores(ref_window, mic[mic_start:mic_stop])
        peaks = _pick_peaks(
            scores,
            work_sr,
            min_delay,
            peak_separation_ms,
            limit=5,
        )
        if not peaks:
            continue
        best = peaks[0]
        second = peaks[1].score if len(peaks) > 1 else 0.0
        prominence = best.score / max(second, 1e-6)
        score_mean = float(np.mean(scores)) if scores.size else 0.0
        score_std = float(np.std(scores)) if scores.size else 0.0
        peak_z = (best.score - score_mean) / max(score_std, 1e-9)
        for peak in peaks:
            key = int(round(peak.delay_ms / bin_ms))
            all_peak_bins.setdefault(key, []).append(peak.score)
        estimates.append(
            WindowEstimate(
                ref_start_s=start / work_sr,
                delay_ms=best.delay_ms,
                score=best.score,
                second_score=second,
                prominence=prominence,
                peak_z=peak_z,
                peaks=tuple(peaks),
            )
        )

    accepted = [
        item
        for item in estimates
        if (
            item.score >= min_score
            and item.prominence >= min_prominence
            and item.peak_z >= min_peak_z
        )
    ]
    candidate_source_windows = [
        item
        for item in estimates
        if item.score >= min_score and item.peak_z >= min_peak_z
    ]
    cluster = _dominant_cluster(
        accepted,
        radius_ms=cluster_radius_ms,
        min_fraction=min_cluster_fraction,
        max_mad_ms=max_mad_ms,
    )
    median_delay = cluster.median_delay_ms
    mad = cluster.mad_ms
    mean_score = cluster.mean_score
    median_prominence = cluster.median_prominence
    median_peak_z = (
        0.0
        if not cluster.estimates
        else float(np.median([item.peak_z for item in cluster.estimates]))
    )
    accepted_window_fraction = (
        0.0
        if windows_considered <= 0
        else len(accepted) / float(windows_considered)
    )
    quality_reason = cluster.reason
    if (
        quality_reason is None
        and accepted_window_fraction < min_accepted_window_fraction
    ):
        quality_reason = (
            "accepted window fraction %.3f < %.3f"
            % (accepted_window_fraction, min_accepted_window_fraction)
        )

    aggregate_peaks = []
    for key, values in all_peak_bins.items():
        aggregate_peaks.append(
            {
                "delay_ms": round(key * bin_ms, 3),
                "count": len(values),
                "mean_score": round(float(np.mean(values)), 6),
                "max_score": round(float(np.max(values)), 6),
            }
        )
    aggregate_peaks.sort(
        key=lambda row: (row["count"], row["mean_score"], row["max_score"]),
        reverse=True,
    )
    path_candidates = _path_candidates(
        candidate_source_windows,
        radius_ms=cluster_radius_ms,
        min_fraction=min_cluster_fraction,
        max_mad_ms=max_mad_ms,
        max_paths=6,
        min_peak_score=min_score,
    )
    drift = _drift_summary(cluster.estimates)

    return {
        "mode": mode,
        "sample_rate": work_sr,
        "source_sample_rate": sample_rate,
        "min_ms": min_ms,
        "max_ms": max_ms,
        "window_s": window / work_sr,
        "hop_s": hop / work_sr,
        "windows_considered": windows_considered,
        "windows_total": len(estimates),
        "windows_accepted": len(accepted),
        "accepted_window_fraction": round(accepted_window_fraction, 3),
        "min_accepted_window_fraction": round(min_accepted_window_fraction, 3),
        "min_peak_z": round(min_peak_z, 3),
        "path_candidate_windows": len(candidate_source_windows),
        "windows_clustered": len(cluster.estimates),
        "inconclusive_reason": quality_reason,
        "delay_ms": None if quality_reason is not None or math.isnan(median_delay) else round(median_delay, 3),
        "delay_mad_ms": None if quality_reason is not None or math.isnan(mad) else round(mad, 3),
        "slope_ms_per_min": drift["slope_ms_per_min"],
        "drift_ppm": drift["drift_ppm"],
        "fitted_drift_span_ms": drift["fitted_span_ms"],
        "drift_residual_mad_ms": drift["residual_mad_ms"],
        "drift_window_span_s": drift["window_span_s"],
        "mean_score": round(mean_score, 6),
        "median_prominence": round(median_prominence, 3),
        "median_peak_z": round(median_peak_z, 3),
        "aggregate_peaks": aggregate_peaks[:8],
        "path_candidates": path_candidates,
        "accepted_windows": [
            {
                "ref_start_s": round(item.ref_start_s, 3),
                "delay_ms": round(item.delay_ms, 3),
                "score": round(item.score, 6),
                "prominence": round(item.prominence, 3),
                "peak_z": round(item.peak_z, 3),
            }
            for item in cluster.estimates[:40]
        ],
    }


def _estimate_delay_dual(
    reference: np.ndarray,
    microphone: np.ndarray,
    sample_rate: int,
    *,
    min_ms: float,
    max_ms: float,
    window_s: float,
    hop_s: float,
    min_rms: float,
    min_score: float,
    min_prominence: float,
    peak_separation_ms: float,
    cluster_radius_ms: float,
    min_cluster_fraction: float,
    max_mad_ms: float,
    min_peak_z: float,
    min_accepted_window_fraction: float,
    max_feature_delta_ms: float,
) -> dict[str, Any]:
    waveform = _estimate_delay_single(
        reference,
        microphone,
        sample_rate,
        min_ms=min_ms,
        max_ms=max_ms,
        mode="waveform",
        window_s=window_s,
        hop_s=hop_s,
        min_rms=min_rms,
        min_score=min_score,
        min_prominence=min_prominence,
        peak_separation_ms=peak_separation_ms,
        cluster_radius_ms=cluster_radius_ms,
        min_cluster_fraction=min_cluster_fraction,
        max_mad_ms=max_mad_ms,
        min_peak_z=min_peak_z,
        min_accepted_window_fraction=min_accepted_window_fraction,
    )
    envelope = _estimate_delay_single(
        reference,
        microphone,
        sample_rate,
        min_ms=min_ms,
        max_ms=max_ms,
        mode="envelope",
        window_s=window_s,
        hop_s=hop_s,
        min_rms=min_rms,
        min_score=min_score,
        min_prominence=min_prominence,
        peak_separation_ms=peak_separation_ms,
        cluster_radius_ms=cluster_radius_ms,
        min_cluster_fraction=min_cluster_fraction,
        max_mad_ms=max_mad_ms,
        # The smoothed RMS envelope has a much flatter score distribution
        # than waveform NCC, so use it as an independent agreement feature
        # with a lower z gate; the dual-mode decision still requires waveform
        # and envelope to agree before accepting.
        min_peak_z=min(min_peak_z, 1.0),
        min_accepted_window_fraction=min_accepted_window_fraction,
    )
    waveform_delay = _number(waveform.get("delay_ms"))
    envelope_delay = _number(envelope.get("delay_ms"))
    feature_delta = (
        None
        if waveform_delay is None or envelope_delay is None
        else abs(waveform_delay - envelope_delay)
    )
    effective_max_feature_delta_ms = min(
        max_feature_delta_ms,
        max(0.0, max_mad_ms * 2.0),
    )
    overlap_cluster, overlap_windows, overlap_total, window_reason = (
        _dual_window_agreement(
            waveform,
            envelope,
            max_delta_ms=effective_max_feature_delta_ms,
            cluster_radius_ms=cluster_radius_ms,
            min_cluster_fraction=min_cluster_fraction,
            max_mad_ms=max_mad_ms,
        )
    )
    agreed_path_candidates = _dual_path_candidate_agreement(
        waveform,
        envelope,
        max_delta_ms=effective_max_feature_delta_ms,
    )
    reason = None
    if waveform_delay is None:
        reason = "waveform feature inconclusive: %s" % (
            waveform.get("inconclusive_reason") or "no trusted delay"
        )
    elif envelope_delay is None:
        reason = "envelope feature inconclusive: %s" % (
            envelope.get("inconclusive_reason") or "no trusted delay"
        )
    elif feature_delta is not None and feature_delta > effective_max_feature_delta_ms:
        reason = (
            "feature delay disagreement %.3fms > %.3fms"
            % (feature_delta, effective_max_feature_delta_ms)
        )
    elif window_reason is not None:
        reason = window_reason

    delay = (
        None
        if reason is not None or math.isnan(overlap_cluster.median_delay_ms)
        else overlap_cluster.median_delay_ms
    )
    waveform_mad = _number(waveform.get("delay_mad_ms")) or 0.0
    envelope_mad = _number(envelope.get("delay_mad_ms")) or 0.0
    feature_mad = 0.0 if feature_delta is None else feature_delta / 2.0
    delay_mad = max(waveform_mad, envelope_mad, feature_mad, overlap_cluster.mad_ms)
    waveform_slope = _number(waveform.get("slope_ms_per_min"))
    envelope_slope = _number(envelope.get("slope_ms_per_min"))
    overlap_drift = _drift_summary(overlap_cluster.estimates)
    overlap_slope = _number(overlap_drift.get("slope_ms_per_min"))
    slope = None
    slope_source = None
    slope_span_s = 0.0
    for source, value, span in (
        ("waveform", waveform_slope, _number(waveform.get("drift_window_span_s"))),
        ("envelope", envelope_slope, _number(envelope.get("drift_window_span_s"))),
        ("overlap", overlap_slope, _number(overlap_drift.get("window_span_s"))),
    ):
        if value is None:
            continue
        if slope is None or abs(value) > abs(slope):
            slope = value
            slope_source = source
            slope_span_s = span or 0.0
    fitted_drift_span_ms = (
        None if slope is None else round(slope * slope_span_s / 60.0, 3)
    )

    return {
        "mode": "dual",
        "sample_rate": sample_rate,
        "source_sample_rate": sample_rate,
        "min_ms": min_ms,
        "max_ms": max_ms,
        "window_s": window_s,
        "hop_s": hop_s,
        "windows_considered": min(
            int(waveform.get("windows_considered") or 0),
            int(envelope.get("windows_considered") or 0),
        ),
        "windows_total": min(
            int(waveform.get("windows_total") or 0),
            int(envelope.get("windows_total") or 0),
        ),
        "windows_accepted": min(
            int(waveform.get("windows_accepted") or 0),
            int(envelope.get("windows_accepted") or 0),
        ),
        "accepted_window_fraction": round(
            min(
                float(waveform.get("accepted_window_fraction") or 0.0),
                float(envelope.get("accepted_window_fraction") or 0.0),
            ),
            3,
        ),
        "min_accepted_window_fraction": round(min_accepted_window_fraction, 3),
        "min_peak_z": round(min_peak_z, 3),
        "path_candidate_windows": int(waveform.get("path_candidate_windows") or 0),
        "windows_clustered": len(overlap_cluster.estimates),
        "inconclusive_reason": reason,
        "delay_ms": None if delay is None else round(delay, 3),
        "delay_mad_ms": None if delay is None else round(delay_mad, 3),
        "slope_ms_per_min": None if slope is None else round(slope, 3),
        "drift_ppm": None if slope is None else round(slope * 1000.0 / 60.0, 3),
        "fitted_drift_span_ms": fitted_drift_span_ms,
        "drift_residual_mad_ms": max(
            _number(waveform.get("drift_residual_mad_ms")) or 0.0,
            _number(envelope.get("drift_residual_mad_ms")) or 0.0,
            _number(overlap_drift.get("residual_mad_ms")) or 0.0,
        ),
        "drift_window_span_s": slope_span_s,
        "drift_slope_source": slope_source,
        "mean_score": round(
            min(
                float(waveform.get("mean_score") or 0.0),
                float(envelope.get("mean_score") or 0.0),
            ),
            6,
        ),
        "median_prominence": round(
            min(
                float(waveform.get("median_prominence") or 0.0),
                float(envelope.get("median_prominence") or 0.0),
            ),
            3,
        ),
        "median_peak_z": round(
            min(
                float(waveform.get("median_peak_z") or 0.0),
                float(envelope.get("median_peak_z") or 0.0),
            ),
            3,
        ),
        "feature_agreement": {
            "ok": reason is None,
            "max_delta_ms": round(effective_max_feature_delta_ms, 3),
            "configured_max_delta_ms": round(max_feature_delta_ms, 3),
            "delta_ms": None if feature_delta is None else round(feature_delta, 3),
            "waveform_delay_ms": waveform_delay,
            "envelope_delay_ms": envelope_delay,
            "waveform_slope_ms_per_min": waveform_slope,
            "envelope_slope_ms_per_min": envelope_slope,
            "overlap_slope_ms_per_min": overlap_slope,
            "slope_source": slope_source,
            "overlap_windows": overlap_total,
            "agreed_windows": len(overlap_windows),
            "waveform_path_candidates": len(
                waveform.get("path_candidates") or []
            ),
            "envelope_path_candidates": len(
                envelope.get("path_candidates") or []
            ),
            "agreed_path_candidates": len(agreed_path_candidates),
        },
        "feature_estimates": {
            "waveform": waveform,
            "envelope": envelope,
        },
        "aggregate_peaks": list(waveform.get("aggregate_peaks") or [])[:8],
        "path_candidates": agreed_path_candidates,
        "accepted_windows": [
            {
                "ref_start_s": round(item.ref_start_s, 3),
                "delay_ms": round(item.delay_ms, 3),
                "score": round(item.score, 6),
                "prominence": round(item.prominence, 3),
                "peak_z": round(item.peak_z, 3),
            }
            for item in overlap_cluster.estimates[:40]
        ],
    }


def estimate_delay(
    reference: np.ndarray,
    microphone: np.ndarray,
    sample_rate: int,
    *,
    min_ms: float,
    max_ms: float,
    mode: str,
    window_s: float,
    hop_s: float,
    min_rms: float,
    min_score: float,
    min_prominence: float,
    peak_separation_ms: float,
    cluster_radius_ms: float,
    min_cluster_fraction: float,
    max_mad_ms: float,
    min_peak_z: float = 6.0,
    min_accepted_window_fraction: float = 0.50,
    max_feature_delta_ms: float = 25.0,
) -> dict[str, Any]:
    if mode == "dual":
        return _estimate_delay_dual(
            reference,
            microphone,
            sample_rate,
            min_ms=min_ms,
            max_ms=max_ms,
            window_s=window_s,
            hop_s=hop_s,
            min_rms=min_rms,
            min_score=min_score,
            min_prominence=min_prominence,
            peak_separation_ms=peak_separation_ms,
            cluster_radius_ms=cluster_radius_ms,
            min_cluster_fraction=min_cluster_fraction,
            max_mad_ms=max_mad_ms,
            min_peak_z=min_peak_z,
            min_accepted_window_fraction=min_accepted_window_fraction,
            max_feature_delta_ms=max_feature_delta_ms,
        )
    return _estimate_delay_single(
        reference,
        microphone,
        sample_rate,
        min_ms=min_ms,
        max_ms=max_ms,
        mode=mode,
        window_s=window_s,
        hop_s=hop_s,
        min_rms=min_rms,
        min_score=min_score,
        min_prominence=min_prominence,
        peak_separation_ms=peak_separation_ms,
        cluster_radius_ms=cluster_radius_ms,
        min_cluster_fraction=min_cluster_fraction,
        max_mad_ms=max_mad_ms,
        min_peak_z=min_peak_z,
        min_accepted_window_fraction=min_accepted_window_fraction,
    )


def _delayed(signal: np.ndarray, delay_samples: int, gain: float) -> np.ndarray:
    out = np.zeros_like(signal)
    if delay_samples < signal.size:
        out[delay_samples:] = gain * signal[: signal.size - delay_samples]
    return out


def self_test() -> int:
    def make_case(
        true_delay_ms: float,
        *,
        min_ms: float,
        max_ms: float,
        duration_s: float = 14.0,
    ) -> tuple[np.ndarray, np.ndarray, int]:
        sample_rate = 48_000
        n = int(sample_rate * duration_s)
        white = rng.normal(0, 0.2, n).astype(np.float32)
        envelope = 0.35 + 0.65 * np.sin(np.linspace(0, 9 * np.pi, n)) ** 2
        reference = (white * envelope).astype(np.float32)
        reference += 0.06 * np.sin(2 * np.pi * 440 * np.arange(n) / sample_rate)
        reference += 0.03 * np.sin(2 * np.pi * 1760 * np.arange(n) / sample_rate)
        reference = reference.astype(np.float32)
        true_delay = int(round(sample_rate * true_delay_ms / 1000.0))
        reflection = int(round(sample_rate * 0.081))
        microphone = _delayed(reference, true_delay, 0.78)
        microphone += _delayed(reference, true_delay + reflection, 0.22)
        microphone += rng.normal(0, 0.025, n).astype(np.float32)
        # Add slow input bias to exercise local-mean NCC normalization.
        microphone += (0.04 * np.sin(np.linspace(0, 5 * np.pi, n))).astype(np.float32)
        return reference, microphone, sample_rate

    rng = np.random.default_rng(20260512)
    true_delay_ms = 382.0
    reference, microphone, sample_rate = make_case(
        true_delay_ms, min_ms=100, max_ms=900
    )
    result = estimate_delay(
        reference,
        microphone,
        sample_rate,
        min_ms=100,
        max_ms=900,
        mode="waveform",
        window_s=4.0,
        hop_s=1.0,
        min_rms=0.0005,
        min_score=0.04,
        min_prominence=1.02,
        min_peak_z=6.0,
        min_accepted_window_fraction=0.50,
        peak_separation_ms=20.0,
        cluster_radius_ms=10.0,
        min_cluster_fraction=0.6,
        max_mad_ms=10.0,
    )
    print(json.dumps(result, indent=2, sort_keys=True))
    measured = result["delay_ms"]
    if measured is None:
        print("SELF_TEST: FAIL no accepted delay", file=sys.stderr)
        return EXIT_INCONCLUSIVE
    error = abs(float(measured) - true_delay_ms)
    if error > 3.0:
        print(
            f"SELF_TEST: FAIL expected {true_delay_ms:.1f}ms, got {measured}ms",
            file=sys.stderr,
        )
        return EXIT_INCONCLUSIVE
    for expected, min_ms, max_ms in (
        (0.0, 0.0, 600.0),
        (100.0, 100.0, 600.0),
        (500.0, 100.0, 500.0),
    ):
        reference, microphone, sample_rate = make_case(
            expected, min_ms=min_ms, max_ms=max_ms, duration_s=10.0
        )
        boundary = estimate_delay(
            reference,
            microphone,
            sample_rate,
            min_ms=min_ms,
            max_ms=max_ms,
            mode="waveform",
            window_s=3.0,
            hop_s=1.0,
            min_rms=0.0005,
            min_score=0.04,
            min_prominence=1.02,
            min_peak_z=6.0,
            min_accepted_window_fraction=0.50,
            peak_separation_ms=20.0,
            cluster_radius_ms=10.0,
            min_cluster_fraction=0.6,
            max_mad_ms=10.0,
        )
        got = boundary["delay_ms"]
        if got is None or abs(float(got) - expected) > 3.0:
            print(
                f"SELF_TEST: FAIL boundary expected {expected:.1f}ms, got {got}",
                file=sys.stderr,
            )
            return EXIT_INCONCLUSIVE

    # Bimodal route changes should fail closed instead of returning a
    # meaningless median between two real delays.
    reference, microphone_a, sample_rate = make_case(
        100.0, min_ms=0.0, max_ms=700.0, duration_s=14.0
    )
    delay_b = int(round(sample_rate * 500.0 / 1000.0))
    reflection_b = int(round(sample_rate * 0.081))
    microphone_b = _delayed(reference, delay_b, 0.78)
    microphone_b += _delayed(reference, delay_b + reflection_b, 0.22)
    microphone_b += rng.normal(0, 0.025, reference.size).astype(np.float32)
    split = microphone_a.size // 2
    bimodal_mic = microphone_a.copy()
    bimodal_mic[split:] = microphone_b[split:]
    bimodal = estimate_delay(
        reference,
        bimodal_mic,
        sample_rate,
        min_ms=0.0,
        max_ms=700.0,
        mode="waveform",
        window_s=2.0,
        hop_s=2.0,
        min_rms=0.0005,
        min_score=0.04,
        min_prominence=1.02,
        min_peak_z=6.0,
        min_accepted_window_fraction=0.50,
        peak_separation_ms=20.0,
        cluster_radius_ms=10.0,
        min_cluster_fraction=0.6,
        max_mad_ms=10.0,
    )
    if bimodal["delay_ms"] is not None:
        print(
            f"SELF_TEST: FAIL bimodal should be inconclusive, got {bimodal['delay_ms']}ms",
            file=sys.stderr,
        )
        return EXIT_INCONCLUSIVE
    print(f"SELF_TEST: PASS error={error:.3f}ms")
    return EXIT_OK


def _print_human(result: dict[str, Any]) -> None:
    print(
        f"Mode: {result['mode']}  sample_rate={result['sample_rate']}Hz  "
        f"window={result['window_s']:.3f}s hop={result['hop_s']:.3f}s"
    )
    print(
        f"Windows: accepted {result['windows_accepted']} / "
        f"{result['windows_total']}"
    )
    if result["delay_ms"] is None:
        print(
            "VERDICT: INCONCLUSIVE - "
            + (result["inconclusive_reason"] or "no trusted delay estimate")
        )
    else:
        print(
            f"Delay: {result['delay_ms']:.3f} ms  "
            f"MAD={result['delay_mad_ms']:.3f} ms  "
            f"mean_score={result['mean_score']:.4f}  "
            f"median_prominence={result['median_prominence']:.2f}  "
            f"median_peak_z={result['median_peak_z']:.2f}"
        )
        if result.get("slope_ms_per_min") is not None:
            print(
                f"Drift slope: {result['slope_ms_per_min']:+.3f} ms/min  "
                f"({result['drift_ppm']:+.3f} ppm)"
            )
    if result.get("feature_agreement"):
        agreement = result["feature_agreement"]
        print(
            "Feature agreement: "
            f"waveform={agreement.get('waveform_delay_ms')}ms "
            f"envelope={agreement.get('envelope_delay_ms')}ms "
            f"delta={agreement.get('delta_ms')}ms "
            f"limit={agreement.get('max_delta_ms')}ms"
        )
    if result["aggregate_peaks"]:
        print("Aggregate peaks:")
        for peak in result["aggregate_peaks"][:5]:
            print(
                f"  {peak['delay_ms']:8.3f} ms  "
                f"count={peak['count']:3d}  "
                f"mean_score={peak['mean_score']:.4f}"
            )
    if result.get("path_candidates"):
        print("Path candidates:")
        for path in result["path_candidates"][:5]:
            print(
                f"  {path['delay_ms']:8.3f} ms  "
                f"windows={path['window_count']:3d}  "
                f"fraction={path['window_fraction']:.2f}  "
                f"mean_score={path['mean_score']:.4f}"
            )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, help="reference/program WAV")
    parser.add_argument("--microphone", type=Path, help="microphone WAV")
    parser.add_argument("--min-ms", type=float, default=0.0)
    parser.add_argument("--max-ms", type=float, default=3500.0)
    parser.add_argument("--mode", choices=("waveform", "envelope", "dual"), default="dual")
    parser.add_argument("--window-sec", type=float, default=4.0)
    parser.add_argument("--hop-sec", type=float, default=1.0)
    parser.add_argument("--min-rms", type=float, default=0.0005)
    parser.add_argument("--min-score", type=float, default=0.04)
    parser.add_argument("--min-prominence", type=float, default=1.02)
    parser.add_argument("--min-peak-z", type=float, default=6.0)
    parser.add_argument("--min-accepted-window-fraction", type=float, default=0.50)
    parser.add_argument("--max-feature-delta-ms", type=float, default=25.0)
    parser.add_argument("--peak-separation-ms", type=float, default=20.0)
    parser.add_argument("--cluster-radius-ms", type=float, default=10.0)
    parser.add_argument("--min-cluster-fraction", type=float, default=0.60)
    parser.add_argument("--max-mad-ms", type=float, default=15.0)
    parser.add_argument("--max-duration-sec", type=float)
    parser.add_argument("--json", action="store_true", help="print JSON only")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return self_test()
    invalid: list[str] = []
    if args.min_ms < 0:
        invalid.append("--min-ms must be >= 0")
    if args.max_ms < args.min_ms:
        invalid.append("--max-ms must be >= --min-ms")
    if args.window_sec <= 0:
        invalid.append("--window-sec must be > 0")
    if args.hop_sec <= 0:
        invalid.append("--hop-sec must be > 0")
    if args.min_rms < 0:
        invalid.append("--min-rms must be >= 0")
    if args.min_score < 0:
        invalid.append("--min-score must be >= 0")
    if args.min_prominence < 1.0:
        invalid.append("--min-prominence must be >= 1")
    if args.min_peak_z < 0:
        invalid.append("--min-peak-z must be >= 0")
    if not 0 <= args.min_accepted_window_fraction <= 1:
        invalid.append("--min-accepted-window-fraction must be in [0, 1]")
    if args.max_feature_delta_ms < 0:
        invalid.append("--max-feature-delta-ms must be >= 0")
    if args.peak_separation_ms <= 0:
        invalid.append("--peak-separation-ms must be > 0")
    if args.cluster_radius_ms < 0:
        invalid.append("--cluster-radius-ms must be >= 0")
    if not 0 < args.min_cluster_fraction <= 1:
        invalid.append("--min-cluster-fraction must be in (0, 1]")
    if args.max_mad_ms < 0:
        invalid.append("--max-mad-ms must be >= 0")
    if args.max_duration_sec is not None and args.max_duration_sec <= 0:
        invalid.append("--max-duration-sec must be > 0")
    if invalid:
        for item in invalid:
            print("ERROR: " + item, file=sys.stderr)
        return EXIT_NO_DATA
    if args.reference is None or args.microphone is None:
        print(
            "ERROR: --reference and --microphone are required unless --self-test is used",
            file=sys.stderr,
        )
        return EXIT_NO_DATA
    try:
        ref_sr, reference = _read_pcm_wav(args.reference, args.max_duration_sec)
        mic_sr, microphone = _read_pcm_wav(args.microphone, args.max_duration_sec)
    except (OSError, ValueError, wave.Error) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return EXIT_NO_DATA
    if ref_sr != mic_sr:
        print(
            f"ERROR: sample-rate mismatch reference={ref_sr} microphone={mic_sr}",
            file=sys.stderr,
        )
        return EXIT_NO_DATA
    try:
        result = estimate_delay(
            reference,
            microphone,
            ref_sr,
            min_ms=args.min_ms,
            max_ms=args.max_ms,
            mode=args.mode,
            window_s=args.window_sec,
            hop_s=args.hop_sec,
            min_rms=args.min_rms,
            min_score=args.min_score,
            min_prominence=args.min_prominence,
            min_peak_z=args.min_peak_z,
            min_accepted_window_fraction=args.min_accepted_window_fraction,
            max_feature_delta_ms=args.max_feature_delta_ms,
            peak_separation_ms=args.peak_separation_ms,
            cluster_radius_ms=args.cluster_radius_ms,
            min_cluster_fraction=args.min_cluster_fraction,
            max_mad_ms=args.max_mad_ms,
        )
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return EXIT_INCONCLUSIVE
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        _print_human(result)
    return EXIT_OK if result["delay_ms"] is not None else EXIT_INCONCLUSIVE


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
