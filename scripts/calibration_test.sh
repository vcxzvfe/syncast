#!/usr/bin/env bash
# Trigger one calibration run via the Router's diagnostic socket and print
# per-device offsets. Requires SyncCast.app running in whole-home mode
# with at least one device enabled and microphone permission granted.
#
#   bash scripts/calibration_test.sh
#
# Exit codes: 0 success, 1 socket missing, 2 RPC error, 3 parse failure.

set -e

SOCKET="/tmp/syncast-$(id -u).calibration.sock"

if [[ ! -S "$SOCKET" ]]; then
    cat >&2 <<EOF
ERROR: socket not found at $SOCKET — SyncCast must be running in
       whole-home mode with at least one device enabled. Verify with:
         pgrep -fl SyncCastMenuBar
         bash scripts/calibration_watch.sh
EOF
    exit 1
fi

REQ='{"jsonrpc":"2.0","id":1,"method":"calibrate","params":{}}'
# Sweeps each enabled device for ~5 s; -w 60 is safe up to ~10 devices.
RESP=$(printf '%s\n' "$REQ" | nc -U -w 60 "$SOCKET")
[[ -z "$RESP" ]] && { echo "ERROR: empty reply from $SOCKET" >&2; exit 3; }

# Use a here-string for the JSON; -c gives us a one-arg python program
# that doesn't conflict with stdin redirection.
python3 -c '
import json, sys
raw = sys.argv[1].strip()
try:
    r = json.loads(raw)
except Exception as e:
    sys.stderr.write("PARSE ERROR: %s\nRaw: %r\n" % (e, raw))
    sys.exit(3)
if "error" in r:
    err = r["error"]
    sys.stderr.write("CALIBRATION FAILED: code=%s message=%s\n" % (
        err.get("code"), err.get("message")))
    sys.exit(2)
result = r.get("result") or {}
offsets = result.get("perDeviceOffsetMs") or {}
print("Per-device latencies (ms, relative to common anchor):")
if not offsets:
    print("  (none reported)")
else:
    for dev, ms in sorted(offsets.items(), key=lambda kv: kv[1]):
        print("  %-30s  %+5d ms" % (dev, ms))
print()
print("Recommended airplayDelayMs (absolute target): %d ms" % result.get("deltaMs", 0))
print("Confidence: %.2f" % result.get("confidence", 0.0))
' "$RESP"
