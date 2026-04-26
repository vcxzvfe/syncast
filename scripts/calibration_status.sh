#!/usr/bin/env bash
# calibration_status.sh — one-shot snapshot of SyncCast's calibration state.
#
# Reads the most recent calibration-related lines from launch.log, the
# persisted airplayDelayMs from UserDefaults, and a few quick-glance signals
# (process running? socket present? mode? device count?) and prints a
# 1-screen status block.
#
# Does NOT trigger calibration. Safe to run at any time, including against
# a paused or backgrounded SyncCast — it only reads files and `defaults`.
#
# Usage:
#   bash scripts/calibration_status.sh [tail_lines]
#
# tail_lines defaults to 5; max is 200 (anything larger is clamped — the
# point of this script is one-screen output, not a full transcript).

set -euo pipefail

LOG="$HOME/Library/Logs/SyncCast/launch.log"
SOCKET="/tmp/syncast-$(id -u).calibration.sock"
DEFAULTS_DOMAIN="io.syncast.menubar"

TAIL_LINES="${1:-5}"
if ! [[ "$TAIL_LINES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: tail_lines must be a non-negative integer (got '$TAIL_LINES')" >&2
    exit 1
fi
if (( TAIL_LINES > 200 )); then TAIL_LINES=200; fi

# ---- helpers ---------------------------------------------------------------

# Human-readable yes/no with a coloured marker. We keep colour minimal
# (just OK/FAIL) so the output is grep-friendly when piped to a file.
ok()   { printf '\033[32mOK\033[0m'; }
fail() { printf '\033[31mFAIL\033[0m'; }

read_default() {
    # $1 = key. Prints empty string if unset (rather than echoing the
    # error from `defaults read`).
    defaults read "$DEFAULTS_DOMAIN" "$1" 2>/dev/null || true
}

# ---- gather -----------------------------------------------------------------

# 1. Process state.
if pgrep -fl SyncCastMenuBar >/dev/null 2>&1; then
    PROC_PID=$(pgrep -f SyncCastMenuBar | head -1)
    PROC_STATE="running (pid $PROC_PID)"
    PROC_OK=1
else
    PROC_STATE="not running"
    PROC_OK=0
fi

# 2. Calibration socket.
if [[ -S "$SOCKET" ]]; then
    SOCKET_STATE="present  ($SOCKET)"
    SOCKET_OK=1
else
    SOCKET_STATE="absent   ($SOCKET)"
    SOCKET_OK=0
fi

# 3. Persisted settings.
DELAY_MS=$(read_default "syncast.airplayDelayMs")
DELAY_MS="${DELAY_MS:-(unset, app-default)}"
BG_ENABLED=$(read_default "syncast.bgCalibrationEnabled")
BG_INTERVAL=$(read_default "syncast.bgCalibrationIntervalS")
MIC_ID=$(read_default "syncast.calibrationMicID")
MIC_ID="${MIC_ID:-(none — system default)}"

# 4. Mode + device snapshot from the most recent launch.log entries.
#    `reconcile:` lines emit `mode=...` and `setActiveAirplayDevices:`
#    emits the routed-device id list. We grab the *most recent* one of
#    each so the output reflects current truth.
MODE_LINE=""
DEVICES_LINE=""
if [[ -r "$LOG" ]]; then
    # Reverse-tail to grab the latest occurrence of each marker without
    # re-reading the whole file twice. tail-by-grep is reliable on
    # files of any size. We match `mode=` rather than `reconcile:` for
    # the mode line because reconcile emits multiple flavours and only
    # the first one in each cycle carries the `mode=...` token.
    MODE_LINE=$(grep "mode=" "$LOG" 2>/dev/null | tail -1 || true)
    DEVICES_LINE=$(grep "setActiveAirplayDevices:" "$LOG" 2>/dev/null | tail -1 || true)
fi

# Best-effort device count from the routed-id JSON-array string:
#   `setActiveAirplayDevices: ids=["id1", "id2", "id3"]`
DEVICE_COUNT=0
if [[ -n "$DEVICES_LINE" ]]; then
    # Count the number of quoted ids. Falls back to 0 if the line is
    # malformed for any reason.
    DEVICE_COUNT=$(printf '%s' "$DEVICES_LINE" \
        | grep -oE '"[^"]+"' | wc -l | tr -d ' ' || echo 0)
fi

# 5. Mode extraction from the last reconcile: line.
MODE="unknown"
if [[ -n "$MODE_LINE" ]]; then
    if [[ "$MODE_LINE" =~ mode=([a-zA-Z]+) ]]; then
        MODE="${BASH_REMATCH[1]}"
    fi
fi

# 6. Recent calibrator lines. Matches both v3 (MuteDip / ActiveCalib /
#    PassiveCalibrator) and the v4 ContActiveCalib tag from the
#    parallel continuous-calibration WIP.
RECENT_LINES=""
if [[ -r "$LOG" ]]; then
    RECENT_LINES=$(grep -E '\[ContActiveCalib\]|\[MuteDip\]|\[ActiveCalib\]|\[PassiveCalibrator\]|bgCalib' \
        "$LOG" 2>/dev/null | tail -"$TAIL_LINES" || true)
fi

# ---- render ----------------------------------------------------------------

printf '=== SyncCast calibration status ===\n'
printf '  process    : %s   %s\n' \
    "$([[ $PROC_OK -eq 1 ]] && ok || fail)" "$PROC_STATE"
printf '  calib sock : %s %s\n' \
    "$([[ $SOCKET_OK -eq 1 ]] && ok || fail)" "$SOCKET_STATE"
printf '  mode       : %s\n' "$MODE"
printf '  devices    : %d (from last setActiveAirplayDevices line)\n' "$DEVICE_COUNT"
printf '\n'
printf 'Persisted settings (UserDefaults: %s):\n' "$DEFAULTS_DOMAIN"
printf '  airplayDelayMs        : %s\n' "$DELAY_MS"
printf '  bgCalibrationEnabled  : %s\n' "${BG_ENABLED:-(unset)}"
printf '  bgCalibrationIntervalS: %s\n' "${BG_INTERVAL:-(unset)}"
printf '  calibrationMicID      : %s\n' "$MIC_ID"
printf '\n'

if [[ -z "$MODE_LINE" && -z "$DEVICES_LINE" ]]; then
    if [[ ! -r "$LOG" ]]; then
        printf 'launch.log not readable at %s\n' "$LOG"
    else
        printf 'launch.log present but no reconcile/devices lines yet\n'
    fi
else
    if [[ -n "$MODE_LINE" ]]; then
        printf 'last reconcile : %s\n' "$MODE_LINE"
    fi
    if [[ -n "$DEVICES_LINE" ]]; then
        printf 'last devices   : %s\n' "$DEVICES_LINE"
    fi
fi
printf '\n'

printf 'Last %s calibrator log line(s):\n' "$TAIL_LINES"
if [[ -z "$RECENT_LINES" ]]; then
    printf '  (no [ContActiveCalib] / [ActiveCalib] / [MuteDip] / [PassiveCalibrator] lines yet)\n'
else
    # Indent each line two spaces so it nests under the header.
    while IFS= read -r line; do
        printf '  %s\n' "$line"
    done <<< "$RECENT_LINES"
fi
printf '\n'

# Drift-test pointer — keeps the doc + script set self-discoverable.
printf 'To run the long drift validation:\n'
printf '  bash %s/drift_test.sh           # default 10 cycles × 60 s\n' \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '  bash %s/drift_test.sh --help    # full options\n' \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
