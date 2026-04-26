#!/usr/bin/env bash
# drift_test_v2.sh — closed-loop validation harness for the Round 10
# Hybrid Drift Tracker. v1 *triggered* disruptive Phase-2 calibrations;
# v2 just *observes* the running tracker via the `tracker.status`
# JSON-RPC method. Non-disruptive — runs for hours alongside listening.
#
# Protocol, thresholds, JSON-RPC contract, troubleshooting:
#   docs/round10_validation_protocol.md
#
# Usage: bash scripts/drift_test_v2.sh [duration_minutes] [interval_seconds]
#        defaults: 10 min, 5 s polling.   --help for usage.
# Exit:  0 ok, 1 missing socket, 2 hybrid-tracking off, 3 RPC err,
#        4 bad arg, 5 zero usable samples.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOCKET="/tmp/syncast-$(id -u).calibration.sock"
DEFAULTS_DOMAIN="io.syncast.menubar"
HYBRID_KEY="syncast.hybridTrackingEnabled"
HISTORY_CSV="${REPO_ROOT}/docs/round10_drift_history.csv"

# Verdict thresholds (ms) — see round10_validation_protocol.md.
STABLE_THRESHOLD_MS=30
MARGINAL_THRESHOLD_MS=80

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
drift_test_v2.sh — observe the Round 10 Hybrid Drift Tracker
USAGE  bash scripts/drift_test_v2.sh [duration_minutes] [interval_seconds]
       defaults: 10 minutes, 5 second polling
OUTPUT /tmp/syncast_drift_v2_<unix-ts>.csv  per-poll log
       docs/round10_drift_history.csv       one row appended per run
See docs/round10_validation_protocol.md for thresholds + JSON-RPC contract.
EOF
    exit 0
fi

DURATION_MIN="${1:-10}"
INTERVAL_SEC="${2:-5}"
[[ "$DURATION_MIN" =~ ^[0-9]+$ && "$DURATION_MIN" -ge 1 ]] \
    || { echo "ERROR: duration_minutes must be a positive integer" >&2; exit 4; }
[[ "$INTERVAL_SEC" =~ ^[0-9]+$ && "$INTERVAL_SEC" -ge 1 ]] \
    || { echo "ERROR: interval_seconds must be a positive integer" >&2; exit 4; }

# ---- preflight -------------------------------------------------------------

[[ -S "$SOCKET" ]] || { echo "ERROR: calibration socket not found at $SOCKET (SyncCast must be in whole-home mode)" >&2; exit 1; }
HYBRID_ENABLED=$(defaults read "$DEFAULTS_DOMAIN" "$HYBRID_KEY" 2>/dev/null || echo "0")
[[ "$HYBRID_ENABLED" == "1" ]] || {
    echo "ERROR: Hybrid Tracking not enabled. Set it via the menubar or:" >&2
    echo "       defaults write $DEFAULTS_DOMAIN $HYBRID_KEY -bool true" >&2
    exit 2; }

# ---- run -------------------------------------------------------------------

CSV_PATH="/tmp/syncast_drift_v2_$(date +%s).csv"
TS_START=$(date +%s)
TOTAL_SEC=$((DURATION_MIN * 60))
EXPECTED_POLLS=$(( (TOTAL_SEC + INTERVAL_SEC - 1) / INTERVAL_SEC ))
GIT_SHA=$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DATE_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

printf 'timestamp,kalman_offset_ms,kalman_drift_ppm,measured_offset_ms,confidence,source,applied_correction_ms,resulting_delay_ms,state\n' > "$CSV_PATH"

printf 'drift_test_v2 starting\n  duration : %s min (~%d polls)\n  interval : %s s\n  csv log  : %s\n  socket   : %s\n  git sha  : %s\n\n' \
    "$DURATION_MIN" "$EXPECTED_POLLS" "$INTERVAL_SEC" "$CSV_PATH" "$SOCKET" "$GIT_SHA"

poll_once() {
    printf '{"jsonrpc":"2.0","id":1,"method":"tracker.status"}\n' \
        | nc -U -w 5 "$SOCKET" 2>/dev/null || true
}

POLL_NUM=0
LAST_STATE=""
while :; do
    NOW=$(date +%s); ELAPSED=$((NOW - TS_START))
    (( ELAPSED >= TOTAL_SEC )) && break
    POLL_NUM=$((POLL_NUM + 1))

    # Parse JSON, append CSV row; stdout = new state, stderr = state changes.
    LAST_STATE=$(python3 - "$CSV_PATH" "$(poll_once)" "$LAST_STATE" \
                          "$POLL_NUM" "$ELAPSED" <<'PYEOF'
import csv, json, sys

csv_path, resp, last_state, poll_num, elapsed = sys.argv[1:6]
poll_num, elapsed = int(poll_num), int(elapsed)
cols = ["timestamp", "kalman_offset_ms", "kalman_drift_ppm",
        "measured_offset_ms", "confidence", "source",
        "applied_correction_ms", "resulting_delay_ms", "state"]
row = {k: "" for k in cols}
state = last_state
try:
    parsed = json.loads(resp) if resp.strip() else None
except json.JSONDecodeError:
    parsed = None

if isinstance(parsed, dict):
    if "error" in parsed:
        print("RPC_ERR" if poll_num == 1 else state, end=""); sys.exit(0)
    result = parsed.get("result")
    if isinstance(result, dict):
        for k in cols:
            if k in result: row[k] = result[k]
        ns = str(row["state"]) if row["state"] != "" else ""
        if ns and ns != last_state:
            print(f"  [t=+{elapsed:>4}s] state {last_state or '-'} -> {ns}  "
                  f"kalman={row['kalman_offset_ms']}ms "
                  f"corr={row['applied_correction_ms']}ms",
                  file=sys.stderr)
        if ns: state = ns

with open(csv_path, "a", newline="") as f:
    csv.writer(f).writerow([row[k] for k in cols])
print(state, end="")
PYEOF
)
    [[ "$LAST_STATE" == "RPC_ERR" ]] && {
        echo "ERROR: tracker.status returned RPC error on first poll." >&2
        exit 3; }
    (( POLL_NUM % 12 == 0 )) && \
        printf '  [t=+%ds] poll %d  state=%s\n' "$ELAPSED" "$POLL_NUM" "${LAST_STATE:-?}"

    REMAINING=$((TOTAL_SEC - ELAPSED))
    (( REMAINING <= 0 )) && break
    SLEEP_FOR=$INTERVAL_SEC
    (( SLEEP_FOR > REMAINING )) && SLEEP_FOR=$REMAINING
    sleep "$SLEEP_FOR"
done

# ---- summary + history append ---------------------------------------------

echo
echo "=== Hybrid Tracker drift_test_v2 summary ==="

python3 - "$CSV_PATH" "$HISTORY_CSV" "$DURATION_MIN" "$INTERVAL_SEC" \
          "$DATE_ISO" "$GIT_SHA" "$STABLE_THRESHOLD_MS" "$MARGINAL_THRESHOLD_MS" <<'PYEOF'
import csv, os, statistics, sys

(csv_path, history_csv, duration_min, interval_sec, date_iso, git_sha,
 stable, marginal) = sys.argv[1:9]
duration_min, interval_sec = int(duration_min), int(interval_sec)
stable, marginal = int(stable), int(marginal)

def isnum(v):
    if v in ("", None): return False
    try: float(v); return True
    except ValueError: return False

with open(csv_path) as f:
    rows = list(csv.DictReader(f))
samples = [r for r in rows if isnum(r["kalman_offset_ms"])]
print(f"Duration: {duration_min} min, {len(rows)} samples polled "
      f"(every {interval_sec}s)")

if not samples:
    print("VERDICT: NO_DATA — every poll returned null. Tracker may be")
    print("        dormant (Hybrid Tracking off?) or hasn't emitted its")
    print(f"        first sample yet. CSV: {csv_path}")
    if os.path.exists(history_csv):
        with open(history_csv, "a", newline="") as fh:
            csv.writer(fh).writerow([date_iso, git_sha, duration_min,
                                     "", "", "", "", "", "NO_DATA"])
    sys.exit(5)

# Convergence: index of first locked sample × interval.
first_locked = next((i for i, r in enumerate(samples)
                     if r["state"] == "locked"), None)
convergence_s = "" if first_locked is None else first_locked * interval_sec
convergence_str = (f"locked at t={convergence_s}s" if first_locked is not None
                   else "never locked")

# Residual stability — stdev of kalman_offset_ms.
ks = [float(r["kalman_offset_ms"]) for r in samples]
res_mean = statistics.mean(ks)
res_stdev = statistics.stdev(ks) if len(ks) > 1 else 0.0
res_max = max(abs(k - res_mean) for k in ks)

# Drift correction effort.
corr = [abs(int(float(r["applied_correction_ms"])))
        for r in samples if isnum(r["applied_correction_ms"])]
total_corr, ticks = sum(corr), len(samples)

# State + source distribution.
state_counts: dict[str, int] = {}
src_counts = {"passive": 0, "active": 0, "other": 0}
for r in samples:
    st = r["state"] or "unknown"
    state_counts[st] = state_counts.get(st, 0) + 1
    s = r["source"] or ""
    src_counts[s if s in ("passive", "active") else "other"] += 1
state_pcts = {s: 100.0 * c / len(samples) for s, c in state_counts.items()}
total_src = sum(src_counts.values())
src_pct = {k: (100.0 * v / total_src) if total_src else 0.0
           for k, v in src_counts.items()}
probes_per_min = src_counts["active"] / max(duration_min, 1)

print(f"Convergence: {convergence_str}")
print(f"Residual stability: mean ±{res_stdev:.0f} ms, "
      f"max ±{res_max:.0f} ms (n={len(samples)})")
print("State distribution: " + ", ".join(
    f"{p:.0f}% {s}" for s, p in sorted(state_pcts.items(),
                                       key=lambda kv: -kv[1])))
print(f"Source: {src_pct['passive']:.0f}% passive, "
      f"{src_pct['active']:.0f}% active probes "
      f"({src_counts['active']} probes total)")
print(f"Total correction: {total_corr} ms across {ticks} ticks "
      f"(avg {total_corr/ticks:.2f} ms/tick)")

if res_stdev <= stable:
    verdict = f"STABLE — within ±{stable} ms target"
elif res_stdev <= marginal:
    verdict = (f"MARGINAL — residual {res_stdev:.0f} ms exceeds "
               f"±{stable} ms target but tracker still locked")
else:
    verdict = (f"UNSTABLE — residual {res_stdev:.0f} ms is audible-tier; "
               "tracker not converged")
print(f"Verdict: {verdict}")
print(f"\nCSV log: {csv_path}")

# Append quarterly history row. Schema in round10_drift_history.csv header.
hist_row = [date_iso, git_sha, duration_min, convergence_s,
            f"{res_mean:.1f}", f"{res_stdev:.1f}", f"{res_max:.1f}",
            f"{probes_per_min:.2f}", verdict.split(" ")[0]]
if os.path.exists(history_csv):
    with open(history_csv, "a", newline="") as fh:
        csv.writer(fh).writerow(hist_row)
    print(f"History: appended row to {history_csv}")
else:
    print(f"History: SKIPPED — {history_csv} not found.")
PYEOF
exit 0
