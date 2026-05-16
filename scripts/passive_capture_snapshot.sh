#!/usr/bin/env bash
# Capture a no-probe passive calibration snapshot through SyncCast's
# diagnostic socket, then run the offline estimator on the generated WAVs.
#
# Requirements:
#   - SyncCast is already running in Whole-home mode.
#   - A real program audio source is playing; this script emits no sound.
#   - Microphone permission is available for the selected calibration mic.
#
# Usage:
#   bash scripts/passive_capture_snapshot.sh [duration_sec] [max_delay_ms] [output_dir]

set -euo pipefail

DURATION_SEC="${1:-4}"
MAX_DELAY_MS="${2:-3500}"
OUTPUT_DIR="${3:-}"
SOCKET="/tmp/syncast-$(id -u).calibration.sock"

if [[ ! -S "$SOCKET" ]]; then
    cat >&2 <<EOF
ERROR: socket not found at $SOCKET — SyncCast must be running in
       Whole-home mode with at least one local and one AirPlay device enabled.
       This script does not launch SyncCast and does not emit audio.
EOF
    exit 1
fi

if ! PREFLIGHT_RESP=$(PYTHONPATH=scripts python3 -c '
import json, sys
from pathlib import Path
import passive_capture_estimate as pce
try:
    result = pce._passive_capture_preflight(Path(sys.argv[1]))
except Exception as exc:
    sys.stderr.write(str(exc) + "\n")
    sys.exit(1)
print(json.dumps(result))
' "$SOCKET" 2>/dev/null); then
    cat >&2 <<EOF
ERROR: passive preflight failed at $SOCKET.
       SyncCast may not be in Whole-home mode, the diagnostic socket may be
       stale, the capture backend may be unavailable, or the current sandbox
       may be blocking Unix-socket access. This script does not launch
       SyncCast and does not emit audio.
EOF
    exit 1
fi
python3 -c '
import json, sys
try:
    response = json.loads(sys.argv[1])
except Exception as exc:
    sys.stderr.write(f"ERROR: preflight response was not JSON: {exc}\n")
    sys.exit(1)
if response.get("ok") is not True:
    sys.stderr.write(f"ERROR: unexpected preflight response: {response!r}\n")
    sys.exit(1)
' "$PREFLIGHT_RESP"

PARAMS_JSON=$(python3 -c '
import json, sys
duration = float(sys.argv[1])
max_delay = int(float(sys.argv[2]))
out = sys.argv[3]
params = {"durationSec": duration, "maxDelayMs": max_delay}
if out:
    params["outputDirectory"] = out
print(json.dumps(params, separators=(",", ":")))
' "$DURATION_SEC" "$MAX_DELAY_MS" "$OUTPUT_DIR")

TIMEOUT_SEC=$(python3 -c '
import math, sys
duration = float(sys.argv[1])
max_delay = float(sys.argv[2])
print(max(1, int(math.ceil(duration + max_delay / 1000.0 + 15))))
' "$DURATION_SEC" "$MAX_DELAY_MS")

if ! RESP=$(PYTHONPATH=scripts python3 -c '
import json, sys
from pathlib import Path
import passive_capture_estimate as pce
try:
    params = json.loads(sys.argv[2])
    result = pce._json_rpc(
        Path(sys.argv[1]),
        "passive_capture",
        params,
        timeout_sec=float(sys.argv[3]),
    )
except Exception as exc:
    sys.stderr.write(str(exc) + "\n")
    sys.exit(1)
print(json.dumps({"jsonrpc": "2.0", "id": 1, "result": result}))
' "$SOCKET" "$PARAMS_JSON" "$TIMEOUT_SEC" 2>&1); then
    printf 'PASSIVE CAPTURE FAILED: %s\n' "$RESP" >&2
    exit 2
fi
[[ -z "$RESP" ]] && { echo "ERROR: empty reply from $SOCKET" >&2; exit 3; }

python3 -c '
import json, subprocess, sys
raw = sys.argv[1].strip()
try:
    response = json.loads(raw)
except Exception as exc:
    sys.stderr.write(f"PARSE ERROR: {exc}\nRaw: {raw!r}\n")
    sys.exit(3)
if "error" in response:
    err = response["error"]
    sys.stderr.write(
        "PASSIVE CAPTURE FAILED: code=%s message=%s\n"
        % (err.get("code"), err.get("message"))
    )
    sys.exit(2)
result = response.get("result") or {}
ref = result.get("referencePath")
mic = result.get("microphonePath")
meta = result.get("metadataPath")
print("Passive capture wrote:")
print(f"  reference : {ref}")
print(f"  microphone: {mic}")
print(f"  metadata  : {meta}")
print(
    "  frames    : reference=%s valid=%s microphone=%s backend=%s"
    % (
        result.get("referenceFrames"),
        result.get("validReferenceFrames"),
        result.get("microphoneFrames"),
        result.get("backend"),
    )
)
print(
    "  context   : delay=%s locked=%s airplays=%s signature=%s"
    % (
        result.get("currentDelayMs"),
        result.get("delayLocked"),
        result.get("enabledAirplayCount"),
        result.get("contextSignature"),
    )
)
if not ref or not mic:
    sys.stderr.write("ERROR: passive_capture response did not include WAV paths\n")
    sys.exit(3)
cmd = [
    "python3",
    "scripts/passive_delay_estimator.py",
    "--reference",
    ref,
    "--microphone",
    mic,
    "--min-ms",
    "0",
    "--max-ms",
    str(result.get("maxDelayMs") or 3500),
    "--window-sec",
    "2",
    "--hop-sec",
    "1",
]
print()
print("Running offline estimator:")
print("  " + " ".join(cmd))
completed = subprocess.run(cmd)
sys.exit(completed.returncode)
' "$RESP"
