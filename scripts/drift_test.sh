#!/usr/bin/env bash
# drift_test.sh — long-running synchronization-drift validation harness.
#
# Runs `calibrate` against the live Router every `interval_sec` for `cycles`
# iterations and records each result (deltaMs, per-device τ, confidence, the
# currently-applied airplayDelayMs) into a CSV log. After the loop, prints a
# summary that answers: did the system actually keep audio synchronized over
# the full window, or did drift accumulate?
#
# Background: the v4 + continuous-calibration design is supposed to keep
# whole-home audio aligned indefinitely. This script is how we MEASURE that
# claim — we don't trust it, we instrument it.
#
# Usage:
#   bash scripts/drift_test.sh [cycles] [interval_sec]
#   bash scripts/drift_test.sh --help
#
# Defaults: 10 cycles × 60 s = 10 minutes total.
#
# Prereqs: SyncCast.app running in whole-home mode with at least two devices
# enabled (otherwise drift is undefined) and microphone permission granted.
# A second terminal running `bash scripts/calibration_watch.sh` is helpful
# but not required.
#
# Exit codes: 0 success, 1 missing socket, 2 RPC error on cycle 1, 3 parse
# failure, 4 user passed an invalid argument.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCKET="/tmp/syncast-$(id -u).calibration.sock"
DEFAULTS_DOMAIN="io.syncast.menubar"
DEFAULTS_KEY="syncast.airplayDelayMs"

print_help() {
    cat <<'EOF'
drift_test.sh — measure SyncCast sync drift over a long window

USAGE
  bash scripts/drift_test.sh [cycles] [interval_sec]
  bash scripts/drift_test.sh --help

ARGUMENTS
  cycles        Number of calibration cycles to run (default: 10)
  interval_sec  Seconds between consecutive cycles (default: 60)

  Total wall-clock time ≈ cycles × (interval_sec + ~5s per calibration).
  With defaults that's ~10 minutes.

OUTPUT
  CSV log    /tmp/syncast_drift_<unix-ts>.csv  (one row per cycle, header
             included). Persisted across reboots so you can diff runs.
  stdout     Per-cycle line printed live + a summary at the end.

WHAT IT VALIDATES
  Continuous calibration (parallel WIP) is supposed to keep airplayDelayMs
  auto-tracking the per-device drift. After 10 cycles you can answer:

    1. Total drift cycle 1 → cycle N — did the recommended deltaMs change?
       Stable system: |Δ| < ~30 ms across 10 minutes.
       Broken system: linear growth → continuous calibrator is silent.

    2. Per-cycle drift — does each successive cycle show a small, random
       delta (system is converged), or a monotone trend (system is chasing
       a moving setpoint and losing)?

    3. Confidence stability — should be ~constant. A drop suggests the
       mic gain or room acoustics changed mid-test, invalidating data.

  See docs/calibration_v4_status.md for the broader picture.

EXAMPLES
  # Default 10×60s
  bash scripts/drift_test.sh

  # Quick smoke test — 3 cycles × 30 s = ~90 s
  bash scripts/drift_test.sh 3 30

  # Stress test — 30 cycles × 120 s = ~1 hour
  bash scripts/drift_test.sh 30 120
EOF
}

# ---- arg parsing -----------------------------------------------------------

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    print_help
    exit 0
fi

CYCLES="${1:-10}"
INTERVAL="${2:-60}"

if ! [[ "$CYCLES" =~ ^[0-9]+$ ]] || (( CYCLES < 1 )); then
    echo "ERROR: cycles must be a positive integer (got '$CYCLES')" >&2
    exit 4
fi
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || (( INTERVAL < 5 )); then
    echo "ERROR: interval_sec must be an integer >= 5 (got '$INTERVAL')" >&2
    echo "       (calibration itself takes ~5 s; smaller intervals would" >&2
    echo "        overlap consecutive runs.)" >&2
    exit 4
fi

# ---- preflight -------------------------------------------------------------

if [[ ! -S "$SOCKET" ]]; then
    cat >&2 <<EOF
ERROR: calibration socket not found at $SOCKET

  SyncCast must be running in whole-home mode with at least one device
  enabled. Sanity-check with:

    pgrep -fl SyncCastMenuBar
    bash scripts/calibration_status.sh

  This script does not start SyncCast — it just observes a live one.
EOF
    exit 1
fi

# ---- helpers ---------------------------------------------------------------

# Read the persisted airplayDelayMs from UserDefaults. Reading the
# sidecar's `local_fifo.diagnostics` over the control socket would
# steal the Router's connection (sidecar accepts only one client at a
# time), so we fall back to the AppModel-persisted copy. This value is
# written every time the slider commits or the calibrator applies a
# delta, so it is always the authoritative current setting.
read_current_delay() {
    local v
    v=$(defaults read "$DEFAULTS_DOMAIN" "$DEFAULTS_KEY" 2>/dev/null || echo "")
    if [[ -z "$v" ]]; then
        echo "0"   # unset → AppModel default; treat as 0 for the CSV
    else
        echo "$v"
    fi
}

# One calibration cycle. Prints `OK\t<json>` to stdout on success or
# `ERR\t<message>` on failure. Always exits 0 — caller decides what to
# do with a failed cycle.
run_one_cycle() {
    local req='{"jsonrpc":"2.0","id":1,"method":"calibrate","params":{}}'
    local resp
    if ! resp=$(printf '%s\n' "$req" | nc -U -w 90 "$SOCKET" 2>/dev/null); then
        echo "ERR	nc failed (socket gone?)"
        return 0
    fi
    if [[ -z "$resp" ]]; then
        echo "ERR	empty reply"
        return 0
    fi
    echo "OK	$resp"
}

# ---- run -------------------------------------------------------------------

CSV_PATH="/tmp/syncast_drift_$(date +%s).csv"
TS_START=$(date +%s)

# Write CSV header up front so the file is self-describing even if the
# test is interrupted by Ctrl-C.
{
    printf 'cycle,unix_ts,t_elapsed_s,status,delta_ms,confidence,airplay_delay_ms,raw_per_device\n'
} > "$CSV_PATH"

echo "drift_test starting"
echo "  cycles      : $CYCLES"
echo "  interval    : ${INTERVAL}s"
echo "  csv log     : $CSV_PATH"
echo "  socket      : $SOCKET"
echo

# Track if any cycle succeeded; if cycle 1 fails outright we exit non-zero
# so CI / loops surface it.
ANY_OK=0
FIRST_FAIL_EXIT=2

for ((i = 1; i <= CYCLES; i++)); do
    NOW=$(date +%s)
    ELAPSED=$((NOW - TS_START))
    DELAY_BEFORE=$(read_current_delay)

    printf '[cycle %d/%d  t=+%ds  delay=%dms]  calibrating…\n' \
        "$i" "$CYCLES" "$ELAPSED" "$DELAY_BEFORE"

    RESULT=$(run_one_cycle)
    STATUS=$(printf '%s' "$RESULT" | cut -f1)
    BODY=$(printf '%s' "$RESULT" | cut -f2-)

    DELAY_AFTER=$(read_current_delay)

    # python3 parser writes one CSV row plus a one-line stdout summary.
    # On error path it still emits a row so the CSV stays aligned.
    python3 - "$CSV_PATH" "$i" "$NOW" "$ELAPSED" "$STATUS" "$BODY" \
              "$DELAY_AFTER" <<'PYEOF'
import csv, json, sys

csv_path, cycle, unix_ts, t_elapsed, status, body, delay_after = sys.argv[1:8]

delta_ms = ""
confidence = ""
per_dev_json = ""

if status == "OK":
    try:
        r = json.loads(body)
    except Exception as e:
        status = "PARSE_ERR"
        body = f"json: {e}"
    else:
        if "error" in r:
            status = "RPC_ERR"
            err = r["error"]
            body = f"code={err.get('code')} msg={err.get('message')}"
        else:
            res = r.get("result") or {}
            delta_ms = res.get("deltaMs", "")
            confidence = res.get("confidence", "")
            offsets = res.get("perDeviceOffsetMs") or {}
            per_dev_json = json.dumps(offsets, sort_keys=True,
                                      ensure_ascii=False)

with open(csv_path, "a", newline="") as f:
    w = csv.writer(f)
    w.writerow([cycle, unix_ts, t_elapsed, status, delta_ms, confidence,
                delay_after, per_dev_json])

# One-line live summary
if status == "OK":
    short = ""
    if per_dev_json:
        try:
            parsed = json.loads(per_dev_json)
            short = " τ=" + ",".join(
                f"{k[:8]}:{v}ms" for k, v in sorted(parsed.items()))
        except Exception:
            pass
    print(f"  -> deltaMs={delta_ms} confidence={confidence}"
          f" airplayDelayMs={delay_after}{short}")
else:
    print(f"  -> {status}: {body}")
PYEOF

    if [[ "$STATUS" == "OK" ]]; then
        ANY_OK=1
    fi

    # Skip the inter-cycle sleep on the last iteration so total wall-clock
    # is ~cycles*interval, not cycles*interval+interval.
    if (( i < CYCLES )); then
        sleep "$INTERVAL"
    fi
done

# ---- summary ---------------------------------------------------------------

echo
echo "=== drift_test summary ==="

# All summary stats are computed by python3 reading the CSV. This keeps
# the bash side simple and lets us reuse json/statistics modules.
python3 - "$CSV_PATH" "$CYCLES" "$INTERVAL" <<'PYEOF'
import csv, json, statistics, sys

csv_path, cycles, interval = sys.argv[1:4]
cycles = int(cycles)
interval = int(interval)

with open(csv_path) as f:
    rows = list(csv.DictReader(f))

ok_rows = [r for r in rows if r["status"] == "OK"]
err_rows = [r for r in rows if r["status"] != "OK"]

print(f"Duration: {len(rows)} cycles over ~{(len(rows) - 1) * interval}s")
print(f"CSV log:  {csv_path}")

if not ok_rows:
    print("VERDICT: NO_DATA — every cycle failed. Inspect CSV + launch.log.")
    if err_rows:
        print("First error: " + err_rows[0].get("raw_per_device", "(none)"))
    sys.exit(0)

if err_rows:
    print(f"WARN: {len(err_rows)} cycle(s) failed; summary uses {len(ok_rows)} OK rows.")

# Parse per-device τ history. Each row's raw_per_device is a JSON dict
# {device_id -> tau_ms}. We aggregate across rows so we can report each
# device's drift independently.
devices: dict[str, list[int]] = {}
for r in ok_rows:
    try:
        d = json.loads(r["raw_per_device"]) if r["raw_per_device"] else {}
    except json.JSONDecodeError:
        d = {}
    for k, v in d.items():
        devices.setdefault(k, []).append(int(v))

initial = ok_rows[0]
final = ok_rows[-1]

def fmt_dev_state(row):
    try:
        d = json.loads(row["raw_per_device"]) if row["raw_per_device"] else {}
    except json.JSONDecodeError:
        return "(parse-fail)"
    if not d:
        return "(none)"
    return ", ".join(f"{k[:8]} τ={v}" for k, v in sorted(d.items()))

print(f"Initial state: airplayDelayMs={initial['airplay_delay_ms']}, "
      f"deltaMs={initial['delta_ms']}, {fmt_dev_state(initial)}")
print(f"Final state:   airplayDelayMs={final['airplay_delay_ms']}, "
      f"deltaMs={final['delta_ms']}, {fmt_dev_state(final)}")

# Total drift = how much did the *recommended* delta change from cycle 1
# to cycle N. If continuous calibration is doing its job, the absolute
# delta should stay near zero — the system has converged and the next
# recommendation is "do nothing". A growing |delta| indicates drift.
try:
    d1 = int(initial["delta_ms"])
    dn = int(final["delta_ms"])
    total_drift = dn - d1
    print(f"Δ deltaMs over {len(ok_rows)} cycles: "
          f"{total_drift:+d} ms (cycle 1: {d1:+d} → cycle {len(ok_rows)}: {dn:+d})")
except (ValueError, TypeError):
    total_drift = None
    print("Δ deltaMs over window: n/a (non-numeric values)")

# Per-cycle drift = consecutive differences in deltaMs. Mean ≈ 0 with
# small stdev = stable; growing magnitude or drift trend = unstable.
deltas = []
for r in ok_rows:
    try:
        deltas.append(int(r["delta_ms"]))
    except (ValueError, TypeError):
        pass
per_cycle = [b - a for a, b in zip(deltas, deltas[1:])]
if per_cycle:
    pc_mean = statistics.mean(per_cycle)
    pc_stdev = statistics.stdev(per_cycle) if len(per_cycle) > 1 else 0.0
    print(f"Per-cycle Δ:   mean={pc_mean:+.1f}ms stdev={pc_stdev:.1f}ms "
          f"(n={len(per_cycle)})")

# Confidence stats — single number because the calibrate result only
# returns one aggregate. A drop mid-test suggests environment changed.
confs = []
for r in ok_rows:
    try:
        confs.append(float(r["confidence"]))
    except (ValueError, TypeError):
        pass
if confs:
    c_mean = statistics.mean(confs)
    c_stdev = statistics.stdev(confs) if len(confs) > 1 else 0.0
    print(f"Confidence:    {c_mean:.1f} ± {c_stdev:.1f} "
          f"(min={min(confs):.1f}, max={max(confs):.1f})")

# Per-device drift breakdown.
if devices:
    print("Per-device τ drift (final − initial):")
    for k in sorted(devices.keys()):
        vals = devices[k]
        if len(vals) < 2:
            continue
        diff = vals[-1] - vals[0]
        std = statistics.stdev(vals) if len(vals) > 2 else 0.0
        print(f"  {k[:8]:8s}  τ₁={vals[0]:>5d}  τN={vals[-1]:>5d}  "
              f"Δ={diff:+5d}ms  stdev={std:5.1f}ms")

# Verdict heuristic. The 30 ms threshold matches the perceptual sync
# tolerance most listeners can detect on consonant transients (~30 ms
# is roughly the Haas-effect ceiling for non-localized ensemble audio).
print()
if total_drift is None:
    print("Verdict: INCONCLUSIVE — non-numeric deltaMs values in log.")
elif abs(total_drift) <= 30:
    print(f"Verdict: STABLE — total drift {total_drift:+d} ms "
          f"is within ±30 ms threshold.")
elif abs(total_drift) <= 100:
    print(f"Verdict: MARGINAL — drift {total_drift:+d} ms exceeds the "
          "±30 ms target but is below the 100 ms mismatch ceiling.")
else:
    print(f"Verdict: UNSTABLE — drift {total_drift:+d} ms is "
          "audible-tier. Continuous calibration is not tracking.")

# ---- per-cycle table ----
print()
print("Per-cycle table:")
print(f"  {'cycle':>5} {'time_s':>6} {'status':>8} {'delta':>7} "
      f"{'conf':>6} {'aplyDly':>7}  per-device")
for r in rows:
    pd = ""
    try:
        d = json.loads(r["raw_per_device"]) if r["raw_per_device"] else {}
        if d:
            pd = " ".join(f"{k[:8]}={v}" for k, v in sorted(d.items()))
    except json.JSONDecodeError:
        pd = "(bad-json)"
    print(f"  {r['cycle']:>5} {r['t_elapsed_s']:>6} "
          f"{r['status']:>8} "
          f"{(r['delta_ms'] or '-'):>7} "
          f"{(r['confidence'] or '-'):>6} "
          f"{r['airplay_delay_ms']:>7}  {pd}")
PYEOF

# If every cycle failed, propagate that as a non-zero exit so CI surfaces it.
if (( ANY_OK == 0 )); then
    exit "$FIRST_FAIL_EXIT"
fi
exit 0
