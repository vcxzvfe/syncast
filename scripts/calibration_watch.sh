#!/usr/bin/env bash
# Tail SyncCast's launch log for calibration-related events in real time.
#
# Useful side-by-side with `calibration_test.sh`: in one terminal you run
# the test harness, in another this script shows what the Router and the
# bridges/writer are reporting.
#
# Filters: anything matching `calib`, `Calib`, `airplayWriter`, or
# `bridge[…]` — covers the manual + passive calibrators, the audio-socket
# writer (so you see whether PCM is reaching OwnTone) and the per-device
# bridge render counters.
#
# Usage:
#   bash scripts/calibration_watch.sh
#
# Quit with Ctrl-C.

LOG="$HOME/Library/Logs/SyncCast/launch.log"

if [[ ! -f "$LOG" ]]; then
    echo "ERROR: log file not found at $LOG" >&2
    echo "  → SyncCast may not have been launched at least once." >&2
    exit 1
fi

# -F: follow even if the file is rotated/truncated. -n 0: start at EOF.
# --line-buffered: flush per-line so we see events in real time, not in
#                   stdout-buffered chunks.
exec tail -F -n 0 "$LOG" \
    | grep --line-buffered -E 'calib|Calib|airplayWriter|bridge\['
