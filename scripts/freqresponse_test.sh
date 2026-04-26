#!/usr/bin/env bash
# Trigger one frequency-response sweep via the Router's diagnostic socket
# and print a per-frequency × per-device SNR table. Requires SyncCast.app
# running in whole-home mode with at least one local CoreAudio device
# enabled and microphone permission granted.
#
#   bash scripts/freqresponse_test.sh
#
# Exit codes: 0 success, 1 socket missing, 2 RPC error, 3 parse failure.
#
# Sweep takes ~10 s with the default 15-frequency list. -w 60 is plenty.

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

REQ='{"jsonrpc":"2.0","id":1,"method":"freqresponse","params":{}}'
RESP=$(printf '%s\n' "$REQ" | nc -U -w 60 "$SOCKET")
[[ -z "$RESP" ]] && { echo "ERROR: empty reply from $SOCKET" >&2; exit 3; }

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
    sys.stderr.write("FREQRESPONSE FAILED: code=%s message=%s\n" % (
        err.get("code"), err.get("message")))
    sys.exit(2)
res = r.get("result") or {}
points = res.get("points") or []
if not points:
    print("(no data)"); sys.exit(0)
devices = sorted({d for p in points for d in p["perDeviceSnrDb"]})
print("Frequency response (SNR in dB by frequency x device):")
print()
print("  %8s | %s" % ("freq Hz", " | ".join("%10s" % d[:8] for d in devices)))
print("  " + "-" * (10 + 13 * len(devices)))
for p in points:
    row = "  %8d | " % int(p["frequencyHz"])
    cells = []
    for d in devices:
        v = p["perDeviceSnrDb"].get(d)
        cells.append("%9.1fdB" % v if v is not None else "       n/a")
    row += " | ".join(cells)
    print(row)
print()
print(res.get("summary", ""))
' "$RESP"
