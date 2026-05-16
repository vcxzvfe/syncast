#!/usr/bin/env python3
"""Summarize SyncCast drift-test CSV logs and enforce health gates."""

from __future__ import annotations

import csv
import json
import statistics
import sys
from pathlib import Path


EXIT_OK = 0
EXIT_NO_DATA = 2
EXIT_INCONCLUSIVE = 3
EXIT_UNHEALTHY = 5


JSON_FIELDS = (
    "raw_per_device",
    "raw_per_device_confidence",
    "raw_per_device_uncertainty",
)


class MalformedJSON(ValueError):
    """Raised when a CSV JSON column is present but cannot be trusted."""


def _load_json_dict(value: str, field: str) -> dict:
    if not value:
        return {}
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError as exc:
        raise MalformedJSON(f"{field}: {exc}") from exc
    if not isinstance(decoded, dict):
        raise MalformedJSON(f"{field}: expected JSON object")
    return decoded


def _int_or_none(value: object) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _float_or_none(value: object) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _fmt_dev_state(row: dict[str, str]) -> str:
    devices = _load_json_dict(row.get("raw_per_device", ""), "raw_per_device")
    if not devices:
        return "(none)"
    return ", ".join(
        f"{key[:16]} tau={value}" for key, value in sorted(devices.items())
    )


def summarize(csv_path: Path, cycles: int, interval: int) -> int:
    with csv_path.open(newline="") as handle:
        rows = list(csv.DictReader(handle))

    ok_rows = [row for row in rows if row.get("status") == "OK"]
    err_rows = [row for row in rows if row.get("status") != "OK"]

    if rows:
        first_elapsed = _int_or_none(rows[0].get("t_elapsed_s"))
        last_elapsed = _int_or_none(rows[-1].get("t_elapsed_s"))
        if first_elapsed is not None and last_elapsed is not None:
            elapsed_s = last_elapsed - first_elapsed
        else:
            elapsed_s = (len(rows) - 1) * interval
    else:
        elapsed_s = 0

    print(
        f"Duration: {len(rows)} cycles over ~{elapsed_s}s "
        f"(requested sleep interval {interval}s)"
    )
    print(f"CSV log:  {csv_path}")

    if not ok_rows:
        print("VERDICT: NO_DATA - every cycle failed. Inspect CSV + launch.log.")
        if err_rows:
            print("First error: " + err_rows[0].get("raw_per_device", "(none)"))
        return EXIT_NO_DATA

    if len(ok_rows) < 2:
        print(
            "VERDICT: INCONCLUSIVE - at least two OK cycles are required "
            "before drift can be measured."
        )
        return EXIT_INCONCLUSIVE

    if err_rows:
        print(
            f"WARN: {len(err_rows)} cycle(s) failed; summary uses "
            f"{len(ok_rows)} OK rows."
        )

    malformed: list[str] = []
    for row in ok_rows:
        cycle = row.get("cycle", "?")
        for field in JSON_FIELDS:
            try:
                _load_json_dict(row.get(field, ""), field)
            except MalformedJSON as exc:
                malformed.append(f"cycle {cycle} {exc}")
    if malformed:
        print("VERDICT: INCONCLUSIVE - malformed JSON in drift CSV.")
        for item in malformed[:5]:
            print("  " + item)
        if len(malformed) > 5:
            print(f"  ... {len(malformed) - 5} more")
        return EXIT_INCONCLUSIVE

    devices: dict[str, list[int]] = {}
    for row in ok_rows:
        for key, value in _load_json_dict(
            row.get("raw_per_device", ""), "raw_per_device"
        ).items():
            tau = _int_or_none(value)
            if tau is not None:
                devices.setdefault(key, []).append(tau)

    initial = ok_rows[0]
    final = ok_rows[-1]

    print(
        f"Initial state: airplayDelayMs={initial.get('airplay_delay_ms')}, "
        f"deltaMs={initial.get('delta_ms')}, {_fmt_dev_state(initial)}"
    )
    print(
        f"Final state:   airplayDelayMs={final.get('airplay_delay_ms')}, "
        f"deltaMs={final.get('delta_ms')}, {_fmt_dev_state(final)}"
    )

    d1 = _int_or_none(initial.get("delta_ms"))
    dn = _int_or_none(final.get("delta_ms"))
    if d1 is None or dn is None:
        total_drift: int | None = None
        print("Delta deltaMs over window: n/a (non-numeric values)")
    else:
        total_drift = dn - d1
        print(
            f"Delta deltaMs over {len(ok_rows)} cycles: "
            f"{total_drift:+d} ms "
            f"(cycle 1: {d1:+d} -> cycle {len(ok_rows)}: {dn:+d})"
        )

    deltas = [
        value
        for value in (_int_or_none(row.get("delta_ms")) for row in ok_rows)
        if value is not None
    ]
    per_cycle = [b - a for a, b in zip(deltas, deltas[1:])]
    if per_cycle:
        mean_delta = statistics.mean(per_cycle)
        stdev_delta = statistics.stdev(per_cycle) if len(per_cycle) > 1 else 0.0
        print(
            f"Per-cycle Delta: mean={mean_delta:+.1f}ms "
            f"stdev={stdev_delta:.1f}ms (n={len(per_cycle)})"
        )

    applied_errors: list[int] = []
    for row in ok_rows:
        target = _int_or_none(row.get("delta_ms"))
        applied = _int_or_none(row.get("airplay_delay_ms"))
        if target is not None and applied is not None:
            applied_errors.append(target - applied)
    if applied_errors:
        final_error = applied_errors[-1]
        max_abs_error = max(abs(value) for value in applied_errors)
        mean_abs_error = statistics.mean(abs(value) for value in applied_errors)
        print(
            f"Applied error: final={final_error:+d}ms "
            f"max_abs={max_abs_error}ms mean_abs={mean_abs_error:.1f}ms "
            "(target - applied)"
        )
    else:
        max_abs_error = None

    confs = [
        value
        for value in (_float_or_none(row.get("confidence")) for row in ok_rows)
        if value is not None
    ]
    if confs:
        mean_conf = statistics.mean(confs)
        stdev_conf = statistics.stdev(confs) if len(confs) > 1 else 0.0
        print(
            f"Confidence:    {mean_conf:.1f} +/- {stdev_conf:.1f} "
            f"(min={min(confs):.1f}, max={max(confs):.1f})"
        )

    per_device_confs: list[float] = []
    for row in ok_rows:
        for value in _load_json_dict(
            row.get("raw_per_device_confidence", ""),
            "raw_per_device_confidence",
        ).values():
            conf = _float_or_none(value)
            if conf is not None:
                per_device_confs.append(conf)
    if per_device_confs:
        print(
            f"Per-device confidence: min={min(per_device_confs):.2f} "
            f"mean={statistics.mean(per_device_confs):.2f} "
            f"(n={len(per_device_confs)})"
        )

    uncertainties: list[int] = []
    for row in ok_rows:
        for value in _load_json_dict(
            row.get("raw_per_device_uncertainty", ""),
            "raw_per_device_uncertainty",
        ).values():
            uncertainty = _int_or_none(value)
            if uncertainty is not None:
                uncertainties.append(uncertainty)
    if uncertainties:
        print(
            f"Uncertainty:   max={max(uncertainties)}ms "
            f"mean={statistics.mean(uncertainties):.1f}ms "
            f"(n={len(uncertainties)})"
        )

    airplay_spreads: list[int] = []
    for row in ok_rows:
        taus: list[int] = []
        for value in _load_json_dict(
            row.get("raw_per_device", ""), "raw_per_device"
        ).values():
            tau = _int_or_none(value)
            if tau is not None and tau >= 500:
                taus.append(tau)
        if len(taus) >= 2:
            airplay_spreads.append(max(taus) - min(taus))
    if airplay_spreads:
        print(
            f"AirPlay high-latency spread: max={max(airplay_spreads)}ms "
            f"mean={statistics.mean(airplay_spreads):.1f}ms "
            "(heuristic independent tau>=500ms)"
        )

    if devices:
        print("Per-device tau drift (final - initial):")
        for key in sorted(devices):
            values = devices[key]
            if len(values) < 2:
                continue
            diff = values[-1] - values[0]
            stdev = statistics.stdev(values) if len(values) > 2 else 0.0
            print(
                f"  {key[:16]:16s}  tau1={values[0]:>5d}  "
                f"tauN={values[-1]:>5d}  Delta={diff:+5d}ms  "
                f"stdev={stdev:5.1f}ms"
            )

    print()
    if total_drift is None:
        verdict_code = EXIT_INCONCLUSIVE
        print("Verdict: INCONCLUSIVE - non-numeric deltaMs values in log.")
    elif abs(total_drift) <= 30:
        verdict_code = EXIT_OK
        print(
            f"Verdict: STABLE - total drift {total_drift:+d} ms "
            "is within +/-30 ms threshold."
        )
    elif abs(total_drift) <= 100:
        verdict_code = EXIT_UNHEALTHY
        print(
            f"Verdict: MARGINAL - drift {total_drift:+d} ms exceeds "
            "the +/-30 ms target but is below the 100 ms mismatch ceiling."
        )
    else:
        verdict_code = EXIT_UNHEALTHY
        print(
            f"Verdict: UNSTABLE - drift {total_drift:+d} ms is audible-tier. "
            "Continuous calibration is not tracking."
        )

    health_flags: list[str] = []
    if len(rows) < cycles:
        health_flags.append(f"only {len(rows)}/{cycles} requested cycle(s) recorded")
    expected_elapsed_s = max(0, cycles - 1) * interval
    if expected_elapsed_s > 0 and elapsed_s < int(expected_elapsed_s * 0.75):
        health_flags.append(
            f"elapsed {elapsed_s}s < 75% of requested {expected_elapsed_s}s window"
        )
    if err_rows:
        health_flags.append(f"{len(err_rows)} failed cycle(s)")
    if cycles >= 3 and len(ok_rows) < 3:
        health_flags.append(
            f"only {len(ok_rows)} OK cycle(s); reliability gate needs at least 3"
        )
    if max_abs_error is not None and max_abs_error > 30:
        health_flags.append(f"applied error {max_abs_error}ms > 30ms")
    if confs and min(confs) < 3.0:
        health_flags.append(f"min confidence {min(confs):.2f} < 3.0")
    if per_device_confs and min(per_device_confs) < 3.0:
        health_flags.append(
            f"min per-device confidence {min(per_device_confs):.2f} < 3.0"
        )
    if uncertainties and max(uncertainties) > 15:
        health_flags.append(f"max uncertainty {max(uncertainties)}ms > 15ms")
    if airplay_spreads and max(airplay_spreads) > 30:
        health_flags.append(
            f"AirPlay high-latency spread {max(airplay_spreads)}ms > 30ms"
        )
    if health_flags:
        print("Health flags:  " + "; ".join(health_flags))
    else:
        print("Health flags:  none")

    print()
    print("Per-cycle table:")
    print(
        f"  {'cycle':>5} {'time_s':>6} {'status':>8} {'delta':>7} "
        f"{'conf':>6} {'aplyDly':>7}  per-device"
    )
    for row in rows:
        try:
            devices_for_row = _load_json_dict(
                row.get("raw_per_device", ""), "raw_per_device"
            )
            per_device = " ".join(
                f"{key[:16]}={value}"
                for key, value in sorted(devices_for_row.items())
            )
        except MalformedJSON:
            per_device = "(bad-json)"
        print(
            f"  {row.get('cycle', ''):>5} {row.get('t_elapsed_s', ''):>6} "
            f"{row.get('status', ''):>8} "
            f"{(row.get('delta_ms') or '-'):>7} "
            f"{(row.get('confidence') or '-'):>6} "
            f"{row.get('airplay_delay_ms', ''):>7}  {per_device}"
        )

    if health_flags and verdict_code == EXIT_OK:
        return EXIT_UNHEALTHY
    return verdict_code


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(
            "usage: drift_summary.py <csv_path> <cycles> <interval_sec>",
            file=sys.stderr,
        )
        return 4
    csv_path = Path(argv[1])
    try:
        cycles = int(argv[2])
        interval = int(argv[3])
    except ValueError:
        print("cycles and interval_sec must be integers", file=sys.stderr)
        return 4
    return summarize(csv_path, cycles, interval)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
