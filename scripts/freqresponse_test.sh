#!/usr/bin/env bash
# Trigger one frequency-response sweep via the Router's diagnostic socket
# and print a per-frequency × per-device SNR table. Requires SyncCast.app
# running in whole-home mode with at least one local CoreAudio device
# enabled and microphone permission granted.
#
#   bash scripts/freqresponse_test.sh
#   bash scripts/freqresponse_test.sh --amplitude 0.2
#   bash scripts/freqresponse_test.sh --freqs 1000,4000,16000,18000,19000
#   bash scripts/freqresponse_test.sh --amplitude 0.2 --freqs 1000,4000
#
# Flags (both optional; both default-handled by the router):
#   --amplitude <float>   Tone digital amplitude. Range (0, 1]. Default 0.1.
#                         Bump to 0.2-0.3 to validate ultrasonic-band SNR
#                         on speakers with steep HF rolloff (HomePod, Sonos).
#   --freqs <csv>         Comma-separated frequency list (Hz, integers or
#                         floats). Replaces the router's default 17-point
#                         sweep with the supplied list. Useful for spot-
#                         checking a single band, e.g. only the ultrasonic
#                         frequencies used by ActiveCalibrator.
#
# Exit codes: 0 success, 1 socket missing, 2 RPC error, 3 parse failure.
#
# Sweep takes ~12 s with the default 17-frequency list (500..22000 Hz,
# explicitly including 18500/19000/19500/20000 for the ultrasonic
# calibration band). -w 60 is plenty.

set -e

SOCKET="/tmp/syncast-$(id -u).calibration.sock"

# Default params payload — matches pre-v7 behavior (router uses its
# built-in 17-frequency sweep at amplitude 0.1).
PARAMS_AMPLITUDE=""
PARAMS_FREQS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --amplitude)
            PARAMS_AMPLITUDE="$2"; shift 2;;
        --freqs)
            PARAMS_FREQS="$2"; shift 2;;
        -h|--help)
            sed -n '2,/^set -e/p' "$0" | sed 's/^# \?//;/^set -e$/d' >&2
            exit 0;;
        *)
            echo "ERROR: unknown flag '$1' (use --help for usage)" >&2
            exit 1;;
    esac
done

# Build the JSON params object. Empty params {} when no flags supplied
# preserves the prior behavior — the router uses its defaults.
PARAMS_JSON='{}'
if [[ -n "$PARAMS_AMPLITUDE" || -n "$PARAMS_FREQS" ]]; then
    PARAMS_JSON=$(python3 -c '
import json, sys
out = {}
amp = sys.argv[1]
freqs = sys.argv[2]
if amp:
    try:
        out["toneAmplitude"] = float(amp)
    except ValueError:
        sys.stderr.write("ERROR: --amplitude must be a number, got %r\n" % amp)
        sys.exit(1)
if freqs:
    parsed = []
    for s in freqs.split(","):
        s = s.strip()
        if not s:
            continue
        try:
            parsed.append(float(s))
        except ValueError:
            sys.stderr.write("ERROR: --freqs entry must be numeric, got %r\n" % s)
            sys.exit(1)
    if not parsed:
        sys.stderr.write("ERROR: --freqs gave an empty list\n")
        sys.exit(1)
    out["frequencies"] = parsed
sys.stdout.write(json.dumps(out))
' "$PARAMS_AMPLITUDE" "$PARAMS_FREQS")
fi

if [[ ! -S "$SOCKET" ]]; then
    cat >&2 <<EOF
ERROR: socket not found at $SOCKET — SyncCast must be running in
       whole-home mode with at least one device enabled. Verify with:
         pgrep -fl SyncCastMenuBar
         bash scripts/calibration_watch.sh
EOF
    exit 1
fi

REQ=$(printf '{"jsonrpc":"2.0","id":1,"method":"freqresponse","params":%s}' "$PARAMS_JSON")
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
