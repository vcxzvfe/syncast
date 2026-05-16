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
#   bash scripts/drift_test.sh --summarize-csv <csv_path> [cycles] [interval_sec]
#   bash scripts/drift_test.sh --help
#
# Defaults: 10 cycles × 60 s = 10 minutes total.
#
# Prereqs: SyncCast.app running in whole-home mode with at least two devices
# enabled (otherwise drift is undefined) and microphone permission granted.
# A second terminal running `bash scripts/calibration_watch.sh` is helpful
# but not required.
#
# Exit codes: 0 success, 1 missing socket, 2 every calibration cycle failed,
# 3 inconclusive/non-numeric summary, 4 invalid argument, 5 unhealthy drift.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCKET="/tmp/syncast-$(id -u).calibration.sock"
DEFAULTS_DOMAIN="io.syncast.menubar"
DELAY_KEY="syncast.airplayDelayMs"
LOCK_KEY="syncast.airplayDelayLockedAt"
DEFAULT_AIRPLAY_DELAY_MS=1750
MIN_AIRPLAY_DELAY_MS=0
MAX_AIRPLAY_DELAY_MS=5000

print_help() {
    cat <<'EOF'
drift_test.sh — measure SyncCast sync drift over a long window

USAGE
  bash scripts/drift_test.sh [cycles] [interval_sec]
  bash scripts/drift_test.sh --summarize-csv <csv_path> [cycles] [interval_sec]
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
             Exit code 5 means the run produced data but failed a health gate.

WHAT IT VALIDATES
  Continuous calibration (parallel WIP) is supposed to keep airplayDelayMs
  auto-tracking the per-device drift. After 10 cycles you can answer:

    1. Total drift cycle 1 → cycle N — did the recommended target delay change?
       Stable system: |Δ| < ~30 ms across 10 minutes.
       Broken system: linear growth → continuous calibrator is silent.

    1b. Applied-vs-recommended error — is the persisted airplayDelayMs still
        close to the measured target? A stable target 150 ms away from the
        applied delay is still a sync problem.

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

  # Re-run the summary / health gates on a saved CSV without probing audio
  bash scripts/drift_test.sh --summarize-csv /tmp/syncast_drift_123.csv 10 60
EOF
}

# ---- arg parsing -----------------------------------------------------------

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    print_help
    exit 0
fi

if [[ "${1:-}" == "--summarize-csv" ]]; then
    CSV_PATH="${2:-}"
    CYCLES="${3:-1}"
    INTERVAL="${4:-60}"
    if [[ -z "$CSV_PATH" || ! -r "$CSV_PATH" ]]; then
        echo "ERROR: --summarize-csv requires a readable CSV path" >&2
        exit 4
    fi
    if ! [[ "$CYCLES" =~ ^[0-9]+$ ]] || (( CYCLES < 1 )); then
        echo "ERROR: cycles must be a positive integer (got '$CYCLES')" >&2
        exit 4
    fi
    if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || (( INTERVAL < 1 )); then
        echo "ERROR: interval_sec must be a positive integer (got '$INTERVAL')" >&2
        exit 4
    fi
    echo "=== drift_test summary ==="
    python3 "$SCRIPT_DIR/drift_summary.py" "$CSV_PATH" "$CYCLES" "$INTERVAL"
    exit $?
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

# Read an integer UserDefaults key only when it is actually typed as an
# integer. This mirrors AppModel.loadPersistedDelayMs(), which ignores
# string-typed values even if `defaults read` prints something numeric.
read_int_default_or_empty() {
    local key="$1"
    local type
    type=$(defaults read-type "$DEFAULTS_DOMAIN" "$key" 2>/dev/null || true)
    if ! printf '%s' "$type" | grep -qi 'integer'; then
        echo ""
        return
    fi
    local v
    v=$(defaults read "$DEFAULTS_DOMAIN" "$key" 2>/dev/null || true)
    if [[ "$v" =~ ^-?[0-9]+$ ]]; then
        echo "$v"
    else
        echo ""
    fi
}

clamp_delay() {
    local value="$1"
    if (( value < MIN_AIRPLAY_DELAY_MS )); then
        echo "$MIN_AIRPLAY_DELAY_MS"
    elif (( value > MAX_AIRPLAY_DELAY_MS )); then
        echo "$MAX_AIRPLAY_DELAY_MS"
    else
        echo "$value"
    fi
}

# Read the app-effective airplayDelayMs from UserDefaults. This follows
# AppModel.loadPersistedDelayMs(): a positive lock overrides the plain
# delay key, an unset/untyped delay falls back to 1750ms, and values are
# clamped to the shared 0...5000ms UI/diagnostic range.
read_current_delay() {
    local locked delay
    locked=$(read_int_default_or_empty "$LOCK_KEY")
    if [[ "$locked" =~ ^-?[0-9]+$ ]] && (( locked > 0 )); then
        clamp_delay "$locked"
        return
    fi
    delay=$(read_int_default_or_empty "$DELAY_KEY")
    if [[ "$delay" =~ ^-?[0-9]+$ ]]; then
        clamp_delay "$delay"
    else
        echo "$DEFAULT_AIRPLAY_DELAY_MS"
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
    printf 'cycle,unix_ts,t_elapsed_s,status,delta_ms,confidence,airplay_delay_ms,raw_per_device,raw_per_device_confidence,raw_per_device_uncertainty\n'
} > "$CSV_PATH"

echo "drift_test starting"
echo "  cycles      : $CYCLES"
echo "  interval    : ${INTERVAL}s"
echo "  csv log     : $CSV_PATH"
echo "  socket      : $SOCKET"
echo

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
per_dev_conf_json = ""
per_dev_unc_json = ""

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
            per_dev_conf = res.get("perDeviceConfidence") or {}
            per_dev_unc = res.get("perDeviceUncertaintyMs") or {}
            per_dev_json = json.dumps(offsets, sort_keys=True,
                                      ensure_ascii=False)
            per_dev_conf_json = json.dumps(per_dev_conf, sort_keys=True,
                                           ensure_ascii=False)
            per_dev_unc_json = json.dumps(per_dev_unc, sort_keys=True,
                                          ensure_ascii=False)

with open(csv_path, "a", newline="") as f:
    w = csv.writer(f)
    w.writerow([cycle, unix_ts, t_elapsed, status, delta_ms, confidence,
                delay_after, per_dev_json, per_dev_conf_json,
                per_dev_unc_json])

# One-line live summary
if status == "OK":
    short = ""
    metrics = ""
    if per_dev_json:
        try:
            parsed = json.loads(per_dev_json)
            short = " τ=" + ",".join(
                f"{k[:16]}:{v}ms" for k, v in sorted(parsed.items()))
        except Exception:
            pass
    if per_dev_unc_json:
        try:
            parsed_unc = json.loads(per_dev_unc_json)
            if parsed_unc:
                metrics = " MAD=" + ",".join(
                    f"{k[:16]}:{v}ms" for k, v in sorted(parsed_unc.items()))
        except Exception:
            pass
    print(f"  -> deltaMs={delta_ms} confidence={confidence}"
          f" airplayDelayMs={delay_after}{short}{metrics}")
else:
    print(f"  -> {status}: {body}")
PYEOF

    # Skip the inter-cycle sleep on the last iteration so total wall-clock
    # is ~cycles*interval, not cycles*interval+interval.
    if (( i < CYCLES )); then
        sleep "$INTERVAL"
    fi
done

# ---- summary ---------------------------------------------------------------

echo
echo "=== drift_test summary ==="

python3 "$SCRIPT_DIR/drift_summary.py" "$CSV_PATH" "$CYCLES" "$INTERVAL"
exit $?
