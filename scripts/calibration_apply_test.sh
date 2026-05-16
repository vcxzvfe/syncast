#!/usr/bin/env bash
# Trigger the protected two-pass calibration apply path.
#
# Unlike calibration_test.sh, this MAY change syncast.airplayDelayMs when
# both measurements agree and the route context stays unchanged.

set -e

SOCKET="/tmp/syncast-$(id -u).calibration.sock"

if [[ ! -S "$SOCKET" ]]; then
    cat >&2 <<EOF
ERROR: socket not found at $SOCKET — SyncCast must be running in
       whole-home mode with at least one local and one AirPlay output enabled.
EOF
    exit 1
fi

REQ='{"jsonrpc":"2.0","id":1,"method":"calibrate_apply","params":{}}'
RESP=$(printf '%s\n' "$REQ" | nc -U -w 300 "$SOCKET")
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
    sys.stderr.write("CALIBRATION APPLY FAILED: code=%s message=%s\n" % (
        err.get("code"), err.get("message")))
    sys.exit(2)
res = r.get("result") or {}
print("Recommended airplayDelayMs: %d ms" % res.get("deltaMs", 0))
if "firstDeltaMs" in res:
    print("First-pass target: %d ms" % res["firstDeltaMs"])
print("Confidence: %.2f" % res.get("confidence", 0.0))
print("Applied: %s" % res.get("applied", False))
print("Applied delay: %s ms" % res.get("appliedDelayMs", "-"))
print("Reason: %s" % res.get("reason", "-"))
' "$RESP"
