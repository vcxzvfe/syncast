#!/usr/bin/env python3
"""Make conservative delay-control decisions from passive monitor evidence.

The passive estimator measures reference-audio-to-microphone acoustic delay.
That value is not, by itself, a safe absolute target for airplayDelayMs because
the dominant path can be local, AirPlay, or a room reflection. This script
therefore uses passive evidence as a relative tracker: establish a stable
baseline when the user has a known-good alignment, then recommend only bounded
small corrections when a later stable, single-path monitor report drifts from
that baseline.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any

import passive_drift_summary as pds


EXIT_OK = 0
EXIT_BAD_INPUT = 2
EXIT_NOT_APPLICABLE = 3
MAX_AIRPLAY_GROUP_RECEIVERS = 8
MIN_PATH_PAIR_WINDOW_FRACTION = 0.55
MAX_LOCAL_PATH_DISTANCE_MS = 350.0


class DecisionRejected(ValueError):
    """Raised when evidence is valid but unsafe for a delay decision."""


def _number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return float(value)
    return None


def _accepted_rows(payload: dict[str, Any]) -> list[dict[str, Any]]:
    rows = payload.get("rows")
    if not isinstance(rows, list):
        raise ValueError("passive monitor payload must contain list 'rows'")
    return [
        row
        for row in rows
        if isinstance(row, dict)
        and row.get("verdict") == "accepted"
        and _number(row.get("delay_ms")) is not None
    ]


def _stable_single_value(
    rows: list[dict[str, Any]],
    key: str,
    *,
    label: str,
) -> Any:
    values: list[Any] = []
    markers = set()
    for row in rows:
        value = row.get(key)
        if value is None or value == "":
            raise ValueError(f"accepted passive rows are missing {label}")
        marker = json.dumps(value, sort_keys=True)
        if marker in markers:
            continue
        markers.add(marker)
        values.append(value)
    if len(values) != 1:
        raise ValueError(f"accepted passive rows changed {label}: {values}")
    return values[0]


def _stable_numeric_value(
    rows: list[dict[str, Any]],
    key: str,
    *,
    label: str,
) -> float:
    value = _stable_single_value(rows, key, label=label)
    numeric = _number(value)
    if numeric is None:
        raise ValueError(f"accepted passive rows have invalid {label}: {value!r}")
    return numeric


def _stable_airplay_count(rows: list[dict[str, Any]]) -> int:
    value = _stable_single_value(
        rows,
        "enabled_airplay_count",
        label="enabled AirPlay count",
    )
    if type(value) is not int or value < 1:
        raise ValueError(f"invalid enabled AirPlay count: {value!r}")
    return value


def _stable_active_airplay_count(
    rows: list[dict[str, Any]],
    *,
    enabled_airplay_count: int,
) -> int:
    value = _stable_single_value(
        rows,
        "active_airplay_count",
        label="active AirPlay count",
    )
    if type(value) is not int or value < 0:
        raise ValueError(f"invalid active AirPlay count: {value!r}")
    if value != enabled_airplay_count:
        raise DecisionRejected(
            "passive delay decision requires every enabled AirPlay output to "
            "remain active in accepted evidence; "
            f"active={value} enabled={enabled_airplay_count}"
        )
    return value


def _stable_airplay_timing_epoch(rows: list[dict[str, Any]]) -> int:
    value = _stable_single_value(
        rows,
        "airplay_timing_epoch",
        label="AirPlay timing epoch",
    )
    if type(value) is not int or value < 0:
        raise ValueError(f"invalid AirPlay timing epoch: {value!r}")
    return value


def _stable_delay_locked(rows: list[dict[str, Any]]) -> bool:
    value = _stable_single_value(
        rows,
        "delay_locked",
        label="delay lock state",
    )
    if type(value) is not bool:
        raise ValueError(f"invalid delay lock state: {value!r}")
    return value


def _stable_sync_context_revision(rows: list[dict[str, Any]]) -> int:
    value = _stable_single_value(
        rows,
        "sync_context_revision",
        label="sync context revision",
    )
    if type(value) is not int or value < 0:
        raise ValueError(f"invalid sync context revision: {value!r}")
    return value


def _path_candidate_groups(row: dict[str, Any]) -> list[dict[str, Any]]:
    sample = row.get("sample")
    if not isinstance(sample, dict):
        return []
    cycles = sample.get("cycles")
    if not isinstance(cycles, list):
        return []
    groups: list[dict[str, Any]] = []
    for cycle in cycles:
        if not isinstance(cycle, dict):
            continue
        estimate = cycle.get("estimate")
        if not isinstance(estimate, dict):
            continue
        raw_candidates = estimate.get("path_candidates")
        if not isinstance(raw_candidates, list):
            continue
        strong = cycle.get("strong_peaks")
        strong_count = 0
        if isinstance(strong, dict):
            raw_count = strong.get("count")
            if type(raw_count) is int:
                strong_count = raw_count
        candidates: list[dict[str, Any]] = []
        for path in raw_candidates:
            if not isinstance(path, dict):
                continue
            delay = _number(path.get("delay_ms"))
            if delay is None:
                continue
            window_fraction = _number(path.get("window_fraction"))
            if (
                window_fraction is not None
                and window_fraction < MIN_PATH_PAIR_WINDOW_FRACTION
            ):
                continue
            candidates.append(
                {
                    "delay_ms": delay,
                    "window_fraction": window_fraction
                    if window_fraction is not None
                    else 0.0,
                    "mean_score": _number(path.get("mean_score")) or 0.0,
                }
            )
        candidates.sort(
            key=lambda item: (item["window_fraction"], item["mean_score"]),
            reverse=True,
        )
        raw_candidate_count = sum(1 for path in raw_candidates if isinstance(path, dict))
        if candidates or raw_candidate_count >= 2 or strong_count >= 2:
            groups.append(
                {
                    "candidates": candidates,
                    "flagged": raw_candidate_count >= 2 or strong_count >= 2,
                }
            )
    return groups


def _path_pair_from_candidate_pair(
    first: dict[str, Any],
    second: dict[str, Any],
    *,
    current_delay_ms: float,
) -> dict[str, Any] | None:
    selected = sorted((first, second), key=lambda item: item["delay_ms"])
    low = selected[0]["delay_ms"]
    high = selected[1]["delay_ms"]
    local_is_low = abs(low - current_delay_ms) <= abs(high - current_delay_ms)
    local = low if local_is_low else high
    airplay = high if local_is_low else low
    local_distance = abs(local - current_delay_ms)
    if local_distance > MAX_LOCAL_PATH_DISTANCE_MS:
        return None
    return {
        "low_delay_ms": low,
        "high_delay_ms": high,
        "local_delay_ms": local,
        "airplay_delay_ms": airplay,
        "local_to_airplay_delta_ms": airplay - local,
        "local_path_distance_from_current_delay_ms": local_distance,
        "path_pair_score": (
            selected[0]["window_fraction"]
            + selected[1]["window_fraction"]
            + selected[0]["mean_score"]
            + selected[1]["mean_score"]
            - (local_distance / 1000.0)
        ),
    }


def _path_pairs_from_cycle_candidates(
    candidates: list[dict[str, Any]],
    *,
    current_delay_ms: float,
) -> list[dict[str, Any]]:
    if len(candidates) < 2:
        return []
    pairs: list[dict[str, Any]] = []
    for left_index, left in enumerate(candidates):
        for right in candidates[left_index + 1:]:
            pair = _path_pair_from_candidate_pair(
                left,
                right,
                current_delay_ms=current_delay_ms,
            )
            if pair is not None:
                pairs.append(pair)
    pairs.sort(key=lambda item: item["path_pair_score"], reverse=True)
    return pairs


def _path_pair_from_cycle_candidates(
    candidates: list[dict[str, Any]],
    *,
    current_delay_ms: float,
) -> dict[str, Any] | None:
    pairs = _path_pairs_from_cycle_candidates(
        candidates,
        current_delay_ms=current_delay_ms,
    )
    return pairs[0] if pairs else None


def _path_pair_groups_for_row(
    row: dict[str, Any],
    *,
    current_delay_ms: float,
) -> list[dict[str, Any]]:
    pair_groups: list[dict[str, Any]] = []
    for group in _path_candidate_groups(row):
        pairs = _path_pairs_from_cycle_candidates(
            group["candidates"],
            current_delay_ms=current_delay_ms,
        )
        pair_groups.append(
            {
                "pairs": pairs,
                "flagged": group["flagged"],
            }
        )
    return pair_groups


def _best_path_pair_for_row(
    row: dict[str, Any],
    *,
    current_delay_ms: float,
) -> dict[str, Any] | None:
    pairs = [
        pair
        for group in _path_pair_groups_for_row(row, current_delay_ms=current_delay_ms)
        for pair in group["pairs"]
    ]
    if not pairs:
        return None
    pairs.sort(key=lambda item: item["path_pair_score"], reverse=True)
    return pairs[0]


def _delta_for_pair(pair: dict[str, Any]) -> float:
    return float(pair["local_to_airplay_delta_ms"])


def _best_pair_in_delta_window(
    pairs: list[dict[str, Any]],
    *,
    lower: float,
    upper: float,
) -> dict[str, Any] | None:
    window_pairs = [
        pair
        for pair in pairs
        if lower <= _delta_for_pair(pair) <= upper
    ]
    if not window_pairs:
        return None
    window_pairs.sort(key=lambda item: item["path_pair_score"], reverse=True)
    return window_pairs[0]


def _select_coherent_path_pairs(
    rows: list[dict[str, Any]],
    *,
    current_delay_ms: float,
    max_delta_range_ms: float,
    require_flagged_cycle_explanation: bool,
) -> dict[str, Any] | None:
    row_pair_options: list[list[dict[str, Any]]] = []
    flagged_pair_options: list[list[dict[str, Any]]] = []
    for row in rows:
        groups = _path_pair_groups_for_row(row, current_delay_ms=current_delay_ms)
        row_pairs = [pair for group in groups for pair in group["pairs"]]
        row_pair_options.append(row_pairs)
        for group in groups:
            if group["flagged"]:
                flagged_pair_options.append(group["pairs"])

    flagged_cycle_count = len(flagged_pair_options)
    required = max(2, math.ceil(len(rows) * 0.66))
    all_pairs = [
        pair
        for pairs in row_pair_options + flagged_pair_options
        for pair in pairs
    ]
    if not all_pairs:
        if require_flagged_cycle_explanation and flagged_cycle_count:
            raise DecisionRejected(
                "multi-path evidence is not coherently explained by "
                "a Local/AirPlay path-pair"
            )
        return None

    best_selection: dict[str, Any] | None = None
    epsilon = 1e-9
    for lower in sorted({_delta_for_pair(pair) for pair in all_pairs}):
        upper = lower + max_delta_range_ms + epsilon
        row_pairs = [
            pair
            for pairs in row_pair_options
            if (
                pair := _best_pair_in_delta_window(
                    pairs,
                    lower=lower,
                    upper=upper,
                )
            )
            is not None
        ]
        if len(row_pairs) < required:
            continue
        flagged_pairs = [
            pair
            for pairs in flagged_pair_options
            if (
                pair := _best_pair_in_delta_window(
                    pairs,
                    lower=lower,
                    upper=upper,
                )
            )
            is not None
        ]
        if (
            require_flagged_cycle_explanation
            and len(flagged_pairs) != flagged_cycle_count
        ):
            continue

        coherence_pairs = row_pairs + flagged_pairs
        deltas = [_delta_for_pair(pair) for pair in coherence_pairs]
        delta_range = max(deltas) - min(deltas)
        if delta_range > max_delta_range_ms + epsilon:
            continue
        median_abs_delta = _median([abs(delta) for delta in deltas])
        score = sum(float(pair["path_pair_score"]) for pair in coherence_pairs)
        selection = {
            "pairs": row_pairs,
            "flagged_pairs": flagged_pairs,
            "flagged_cycle_count": flagged_cycle_count,
            "explained_flagged_cycle_count": len(flagged_pairs),
            "delta_range": delta_range,
            "median_abs_delta": median_abs_delta,
            "score": score,
        }
        key = (
            len(row_pairs),
            len(flagged_pairs),
            -delta_range,
            -median_abs_delta,
            score,
        )
        if best_selection is None or key > best_selection["key"]:
            selection["key"] = key
            best_selection = selection

    if best_selection is None:
        if require_flagged_cycle_explanation and flagged_cycle_count:
            raise DecisionRejected(
                "multi-path evidence is not coherently explained by "
                "a Local/AirPlay path-pair"
            )
        return None
    return best_selection


def _median(values: list[float]) -> float:
    return statistics.median(values)


def _coherent_path_pair_features(
    rows: list[dict[str, Any]],
    *,
    current_delay_ms: float,
    max_delta_range_ms: float,
    require_flagged_cycle_explanation: bool,
) -> dict[str, Any] | None:
    selection = _select_coherent_path_pairs(
        rows,
        current_delay_ms=current_delay_ms,
        max_delta_range_ms=max_delta_range_ms,
        require_flagged_cycle_explanation=require_flagged_cycle_explanation,
    )
    if selection is None:
        return None
    pairs = selection["pairs"]
    flagged_pairs = selection["flagged_pairs"]
    flagged_cycle_count = selection["flagged_cycle_count"]
    explained_flagged_cycle_count = selection["explained_flagged_cycle_count"]
    required = max(2, math.ceil(len(rows) * 0.66))
    if len(pairs) < required:
        return None

    coherence_pairs = pairs + flagged_pairs
    deltas = [float(pair["local_to_airplay_delta_ms"]) for pair in coherence_pairs]
    delta_range = max(deltas) - min(deltas)
    if delta_range > max_delta_range_ms:
        raise DecisionRejected(
            "coherent Local/AirPlay path-pair delta range "
            f"{delta_range:.3f}ms > {max_delta_range_ms:.3f}ms"
        )
    lows = [float(pair["low_delay_ms"]) for pair in pairs]
    highs = [float(pair["high_delay_ms"]) for pair in pairs]
    locals_ = [float(pair["local_delay_ms"]) for pair in pairs]
    airplays = [float(pair["airplay_delay_ms"]) for pair in pairs]
    local_distances = [
        float(pair["local_path_distance_from_current_delay_ms"])
        for pair in pairs
    ]
    return {
        "path_pair_samples": len(pairs),
        "path_pair_required_samples": required,
        "path_pair_flagged_cycles": flagged_cycle_count,
        "path_pair_explained_flagged_cycles": explained_flagged_cycle_count,
        "path_pair_low_delay_ms": round(_median(lows), 3),
        "path_pair_high_delay_ms": round(_median(highs), 3),
        "path_pair_local_delay_ms": round(_median(locals_), 3),
        "path_pair_airplay_delay_ms": round(_median(airplays), 3),
        "path_pair_delta_ms": round(_median(deltas), 3),
        "path_pair_delta_range_ms": round(delta_range, 3),
        "path_pair_local_distance_from_current_delay_ms": round(
            _median(local_distances),
            3,
        ),
    }


def _monitor_features(
    payload: dict[str, Any],
    *,
    min_accepted_samples: int,
    max_delay_range_ms: float,
    allow_multiple_airplay: bool,
    allow_multipath: bool,
) -> dict[str, Any]:
    summary = payload.get("summary")
    if not isinstance(summary, dict):
        raise ValueError("passive monitor payload must contain object 'summary'")
    if summary.get("verdict") != "stable":
        raise DecisionRejected(
            "passive monitor is not stable: %s"
            % (summary.get("reason") or summary.get("verdict"))
        )
    if summary.get("context_gate") is not None:
        raise DecisionRejected(
            f"passive monitor context gate failed: {summary['context_gate']!r}"
        )
    delay_range = _number(summary.get("delay_range_ms"))
    if delay_range is None:
        raise ValueError("passive monitor summary is missing delay_range_ms")
    if delay_range > max_delay_range_ms:
        raise DecisionRejected(
            f"passive monitor delay range {delay_range:.3f}ms > "
            f"{max_delay_range_ms:.3f}ms"
        )

    rows = _accepted_rows(payload)
    if len(rows) < min_accepted_samples:
        raise DecisionRejected(
            f"only {len(rows)} accepted passive samples, required {min_accepted_samples}"
        )

    current_delay_ms = _stable_numeric_value(
        rows,
        "current_delay_ms",
        label="current delay",
    )
    delay_locked = _stable_delay_locked(rows)
    if delay_locked:
        raise DecisionRejected(
            "passive delay decision refuses locked manual delay state"
        )
    context_signature = _stable_single_value(
        rows,
        "context_signature",
        label="route context",
    )
    capture_backend = _stable_single_value(
        rows,
        "capture_backend",
        label="capture backend",
    )
    airplay_count = _stable_airplay_count(rows)
    active_airplay_count = _stable_active_airplay_count(
        rows,
        enabled_airplay_count=airplay_count,
    )
    airplay_timing_epoch = _stable_airplay_timing_epoch(rows)
    sync_context_state = _stable_single_value(
        rows,
        "sync_context_state",
        label="sync context state",
    )
    if not isinstance(sync_context_state, str) or not sync_context_state:
        raise ValueError(f"invalid sync context state: {sync_context_state!r}")
    if sync_context_state == "measuring":
        raise DecisionRejected(
            "passive delay decision refuses measuring sync context"
        )
    sync_context_revision = _stable_sync_context_revision(rows)
    if airplay_count > MAX_AIRPLAY_GROUP_RECEIVERS:
        raise DecisionRejected(
            "passive auto decision supports at most "
            f"{MAX_AIRPLAY_GROUP_RECEIVERS} enabled AirPlay outputs; "
            f"got {airplay_count}"
        )
    if airplay_count != 1 and not allow_multiple_airplay:
        raise DecisionRejected(
            "passive auto decision requires exactly one enabled AirPlay output; "
            f"got {airplay_count}"
        )

    summary_view = pds._summarize_payload(payload)
    path_pair = _coherent_path_pair_features(
        rows,
        current_delay_ms=current_delay_ms,
        max_delta_range_ms=max_delay_range_ms,
        require_flagged_cycle_explanation=(
            not allow_multipath
            and (
                bool(summary_view["strong_peak_flag_count"])
                or bool(summary_view["multi_path_candidate_flag_count"])
            )
        ),
    )
    if not allow_multipath:
        if summary_view["strong_peak_flag_count"] and path_pair is None:
            raise DecisionRejected(
                "passive monitor has strong multi-peak evidence; refusing delay decision"
            )
        if summary_view["multi_path_candidate_flag_count"] and path_pair is None:
            raise DecisionRejected(
                "passive monitor has multi-path candidate evidence; refusing delay decision"
            )

    delays = [float(row["delay_ms"]) for row in rows]
    measured_delay_ms = statistics.median(delays)
    observed_offset_ms = measured_delay_ms - current_delay_ms
    result = {
        "samples_accepted": len(rows),
        "measured_delay_ms": round(measured_delay_ms, 3),
        "current_delay_ms": round(current_delay_ms, 3),
        "delay_locked": delay_locked,
        "observed_offset_ms": round(observed_offset_ms, 3),
        "delay_range_ms": round(delay_range, 3),
        "context_signature": context_signature,
        "capture_backend": capture_backend,
        "enabled_airplay_count": airplay_count,
        "active_airplay_count": active_airplay_count,
        "airplay_timing_epoch": airplay_timing_epoch,
        "sync_context_state": sync_context_state,
        "sync_context_revision": sync_context_revision,
        "summary": summary_view,
    }
    if path_pair is not None:
        result.update(path_pair)
    return result


def _load_payload(path: Path) -> dict[str, Any]:
    return pds._load_payload(
        path,
        min_sample_fraction=0.66,
        max_monitor_drift_ms=30.0,
        max_trailing_inconclusive_samples=0,
    )


def _clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


def decide(
    payload: dict[str, Any],
    *,
    baseline_payload: dict[str, Any] | None = None,
    baseline_offset_ms: float | None = None,
    baseline_path_pair_delta_ms: float | None = None,
    min_accepted_samples: int = 2,
    max_delay_range_ms: float = 30.0,
    deadband_ms: float = 8.0,
    max_step_ms: float = 20.0,
    max_correction_ms: float = 80.0,
    delay_min_ms: float = 0.0,
    delay_max_ms: float = 5000.0,
    allow_multiple_airplay: bool = True,
    allow_multipath: bool = False,
) -> dict[str, Any]:
    features = _monitor_features(
        payload,
        min_accepted_samples=min_accepted_samples,
        max_delay_range_ms=max_delay_range_ms,
        allow_multiple_airplay=allow_multiple_airplay,
        allow_multipath=allow_multipath,
    )
    if baseline_offset_ms is not None:
        baseline_offset_ms = _number(baseline_offset_ms)
        if baseline_offset_ms is None:
            raise ValueError("baseline_offset_ms must be a finite number")
    if baseline_path_pair_delta_ms is not None:
        baseline_path_pair_delta_ms = _number(baseline_path_pair_delta_ms)
        if baseline_path_pair_delta_ms is None:
            raise ValueError("baseline_path_pair_delta_ms must be a finite number")
    if baseline_payload is not None and baseline_offset_ms is not None:
        raise ValueError("use either baseline_payload or baseline_offset_ms, not both")
    if baseline_payload is not None and baseline_path_pair_delta_ms is not None:
        raise ValueError(
            "use either baseline_payload or baseline_path_pair_delta_ms, not both"
        )
    if baseline_path_pair_delta_ms is not None and baseline_offset_ms is None:
        raise ValueError(
            "baseline_path_pair_delta_ms requires baseline_offset_ms"
        )
    if baseline_payload is None and baseline_offset_ms is None:
        path_pair_delta = _number(features.get("path_pair_delta_ms"))
        if path_pair_delta is not None:
            if abs(path_pair_delta) > max_correction_ms:
                return {
                    "verdict": "reject",
                    "auto_apply_eligible": False,
                    "reason": (
                        f"coherent Local/AirPlay path-pair delta "
                        f"{path_pair_delta:+.3f}ms exceeds maximum single "
                        f"decision correction {max_correction_ms:.3f}ms"
                    ),
                    "features": features,
                    "raw_correction_ms": path_pair_delta,
                    "decision_basis": "coherent_path_pair_absolute",
                }
            aligned = abs(path_pair_delta) <= deadband_ms
            decision_basis = (
                "coherent_path_pair_aligned_baseline"
                if aligned
                else "coherent_path_pair_unverified_baseline"
            )
            reason_middle = (
                f"is within deadband {deadband_ms:.3f}ms; "
                if aligned
                else "has no trusted baseline yet; "
            )
            return {
                "verdict": "initialize_baseline",
                "auto_apply_eligible": False,
                "reason": (
                    f"coherent Local/AirPlay path-pair delta "
                    f"{path_pair_delta:+.3f}ms {reason_middle}"
                    "store this route as baseline and require future drift "
                    "evidence before correction"
                ),
                "features": features,
                "baseline_offset_ms": features["observed_offset_ms"],
                "baseline_path_pair_delta_ms": path_pair_delta,
                "decision_basis": decision_basis,
            }
        return {
            "verdict": "initialize_baseline",
            "auto_apply_eligible": False,
            "reason": (
                "stable passive evidence is suitable as a relative baseline; "
                "do not apply delay from the first report"
            ),
            "features": features,
            "baseline_offset_ms": features["observed_offset_ms"],
            "baseline_path_pair_delta_ms": features.get("path_pair_delta_ms"),
            "decision_basis": "single_path_relative_baseline",
        }

    baseline_features = None
    if baseline_payload is not None:
        baseline_features = _monitor_features(
            baseline_payload,
            min_accepted_samples=min_accepted_samples,
            max_delay_range_ms=max_delay_range_ms,
            allow_multiple_airplay=allow_multiple_airplay,
            allow_multipath=allow_multipath,
        )
        baseline_offset_ms = float(baseline_features["observed_offset_ms"])
        for field, label in (
            ("context_signature", "route context"),
            ("capture_backend", "capture backend"),
            ("enabled_airplay_count", "enabled AirPlay count"),
            ("active_airplay_count", "active AirPlay count"),
            ("airplay_timing_epoch", "AirPlay timing epoch"),
            ("sync_context_state", "sync context state"),
            ("sync_context_revision", "sync context revision"),
        ):
            if baseline_features[field] != features[field]:
                raise DecisionRejected(
                    f"baseline {label} does not match current report: "
                    f"{baseline_features[field]!r} != {features[field]!r}"
                )
    assert baseline_offset_ms is not None

    path_pair_delta = _number(features.get("path_pair_delta_ms"))
    baseline_path_pair_delta = (
        baseline_path_pair_delta_ms
        if baseline_features is None
        else _number(baseline_features.get("path_pair_delta_ms"))
    )
    if (
        path_pair_delta is not None
        and baseline_path_pair_delta is None
        and not allow_multipath
    ):
        return {
            "verdict": "reject",
            "auto_apply_eligible": False,
            "reason": (
                "current Local/AirPlay path-pair evidence cannot be compared "
                "against a legacy single-path baseline; record a new baseline "
                "before considering delay correction"
            ),
            "features": features,
            "baseline_features": baseline_features,
            "baseline_offset_ms": round(baseline_offset_ms, 3),
            "baseline_path_pair_delta_ms": None,
            "raw_correction_ms": path_pair_delta,
            "decision_basis": "coherent_path_pair_missing_baseline",
        }
    if path_pair_delta is not None and baseline_path_pair_delta is not None:
        raw_correction = path_pair_delta - baseline_path_pair_delta
        decision_basis = "coherent_path_pair_relative"
    else:
        raw_correction = features["observed_offset_ms"] - baseline_offset_ms
        decision_basis = "single_path_relative"
    if abs(raw_correction) <= deadband_ms:
        return {
            "verdict": "hold",
            "auto_apply_eligible": False,
            "reason": (
                f"passive drift {raw_correction:+.3f}ms is within "
                f"deadband {deadband_ms:.3f}ms"
            ),
            "features": features,
            "baseline_features": baseline_features,
            "baseline_offset_ms": round(baseline_offset_ms, 3),
            "baseline_path_pair_delta_ms": baseline_path_pair_delta,
            "raw_correction_ms": round(raw_correction, 3),
            "recommended_delay_ms": int(round(features["current_delay_ms"])),
            "decision_basis": decision_basis,
        }

    if features.get("sync_context_state") != "valid":
        return {
            "verdict": "reject",
            "auto_apply_eligible": False,
            "reason": (
                "passive correction requires a valid Local+AirPlay sync "
                f"context; current state is {features.get('sync_context_state')!r}"
            ),
            "features": features,
            "baseline_features": baseline_features,
            "baseline_offset_ms": round(baseline_offset_ms, 3),
            "baseline_path_pair_delta_ms": baseline_path_pair_delta,
            "raw_correction_ms": round(raw_correction, 3),
            "decision_basis": decision_basis,
        }

    if abs(raw_correction) > max_correction_ms:
        return {
            "verdict": "reject",
            "auto_apply_eligible": False,
            "reason": (
                f"passive drift {raw_correction:+.3f}ms exceeds maximum "
                f"single decision correction {max_correction_ms:.3f}ms"
            ),
            "features": features,
            "baseline_features": baseline_features,
            "baseline_offset_ms": round(baseline_offset_ms, 3),
            "baseline_path_pair_delta_ms": baseline_path_pair_delta,
            "raw_correction_ms": round(raw_correction, 3),
            "decision_basis": decision_basis,
        }

    limited_correction = _clamp(raw_correction, -max_step_ms, max_step_ms)
    proposed = features["current_delay_ms"] + limited_correction
    clamped = _clamp(proposed, delay_min_ms, delay_max_ms)
    limited = abs(limited_correction - raw_correction) > 0.0005
    bounded = abs(clamped - proposed) > 0.0005
    return {
        "verdict": "recommend",
        "auto_apply_eligible": not limited and not bounded,
        "reason": (
            f"passive relative drift {raw_correction:+.3f}ms from baseline; "
            f"recommend {'bounded ' if limited or bounded else ''}delay update"
        ),
        "features": features,
        "baseline_features": baseline_features,
        "baseline_offset_ms": round(baseline_offset_ms, 3),
        "baseline_path_pair_delta_ms": baseline_path_pair_delta,
        "raw_correction_ms": round(raw_correction, 3),
        "limited_correction_ms": round(limited_correction, 3),
        "recommended_delay_ms": int(round(clamped)),
        "limited_by_step": limited,
        "limited_by_bounds": bounded,
        "decision_basis": decision_basis,
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Decide whether stable passive drift evidence should initialize a "
            "baseline, hold, or recommend a bounded delay correction."
        )
    )
    parser.add_argument("report", type=Path)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--baseline-report", type=Path)
    group.add_argument("--baseline-offset-ms", type=float)
    parser.add_argument("--min-accepted-samples", type=int, default=2)
    parser.add_argument("--max-delay-range-ms", type=float, default=30.0)
    parser.add_argument("--deadband-ms", type=float, default=8.0)
    parser.add_argument("--max-step-ms", type=float, default=20.0)
    parser.add_argument("--max-correction-ms", type=float, default=80.0)
    parser.add_argument("--delay-min-ms", type=float, default=0.0)
    parser.add_argument("--delay-max-ms", type=float, default=5000.0)
    parser.add_argument(
        "--allow-multiple-airplay",
        action="store_true",
        default=True,
        help="Allow Local+AirPlay-group decisions with multiple AirPlay receivers (default).",
    )
    parser.add_argument(
        "--single-airplay-only",
        action="store_true",
        help="Require exactly one AirPlay receiver for legacy diagnostics.",
    )
    parser.add_argument("--allow-multipath", action="store_true")
    return parser.parse_args()


def _validate_args(args: argparse.Namespace) -> None:
    numeric_args = (
        ("--baseline-offset-ms", args.baseline_offset_ms),
        ("--max-delay-range-ms", args.max_delay_range_ms),
        ("--deadband-ms", args.deadband_ms),
        ("--max-step-ms", args.max_step_ms),
        ("--max-correction-ms", args.max_correction_ms),
        ("--delay-min-ms", args.delay_min_ms),
        ("--delay-max-ms", args.delay_max_ms),
    )
    for label, value in numeric_args:
        if value is not None and not math.isfinite(float(value)):
            raise ValueError(f"{label} must be finite")
    if args.min_accepted_samples < 1:
        raise ValueError("--min-accepted-samples must be >= 1")
    if args.max_delay_range_ms < 0:
        raise ValueError("--max-delay-range-ms must be >= 0")
    if args.deadband_ms < 0:
        raise ValueError("--deadband-ms must be >= 0")
    if args.max_step_ms <= 0:
        raise ValueError("--max-step-ms must be > 0")
    if args.max_correction_ms < args.deadband_ms:
        raise ValueError("--max-correction-ms must be >= --deadband-ms")
    if args.delay_min_ms > args.delay_max_ms:
        raise ValueError("--delay-min-ms must be <= --delay-max-ms")


def main() -> int:
    args = _parse_args()
    try:
        _validate_args(args)
        payload = _load_payload(args.report)
        baseline_payload = (
            None if args.baseline_report is None else _load_payload(args.baseline_report)
        )
        decision = decide(
            payload,
            baseline_payload=baseline_payload,
            baseline_offset_ms=args.baseline_offset_ms,
            min_accepted_samples=args.min_accepted_samples,
            max_delay_range_ms=args.max_delay_range_ms,
            deadband_ms=args.deadband_ms,
            max_step_ms=args.max_step_ms,
            max_correction_ms=args.max_correction_ms,
            delay_min_ms=args.delay_min_ms,
            delay_max_ms=args.delay_max_ms,
            allow_multiple_airplay=(
                args.allow_multiple_airplay and not args.single_airplay_only
            ),
            allow_multipath=args.allow_multipath,
        )
        print(json.dumps(decision, indent=2, sort_keys=True))
        return EXIT_OK if decision["verdict"] != "reject" else EXIT_NOT_APPLICABLE
    except DecisionRejected as exc:
        print(
            json.dumps({"verdict": "reject", "error": str(exc)}, indent=2),
            file=sys.stderr,
        )
        return EXIT_NOT_APPLICABLE
    except Exception as exc:
        print(
            json.dumps({"verdict": "reject", "error": str(exc)}, indent=2),
            file=sys.stderr,
        )
        return EXIT_BAD_INPUT


if __name__ == "__main__":
    raise SystemExit(main())
