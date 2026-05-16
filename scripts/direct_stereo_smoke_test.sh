#!/usr/bin/env bash
# Verify the experimental DRM-oriented Direct Stereo path.
#
# This launches the installed app, toggles local CoreAudio outputs through
# SYNCAST_AUTO_TEST, and watches launch.log for proof that SyncCast used
# Direct Stereo instead of ScreenCaptureKit.
#
# Usage:
#   bash scripts/direct_stereo_smoke_test.sh [--default-path] [auto_test_targets] [timeout_sec]
#
# Defaults:
#   auto_test_targets = display,mbp
#   timeout_sec       = 80
#
# Modes:
#   default           set SYNCAST_STEREO_PATH=direct before launch
#   --default-path    leave SYNCAST_STEREO_PATH unset and verify the app policy
#                     selects Direct Stereo by default
#
# Exit codes:
#   0 pass
#   1 app not installed
#   2 Direct Stereo was not observed
#   3 router/backend failed
#   4 invalid arguments

set -euo pipefail

USE_DEFAULT_PATH=0
if [[ "${1:-}" == "--default-path" ]]; then
    USE_DEFAULT_PATH=1
    shift
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -gt 2 ]]; then
    sed -n '1,26p' "$0"
    exit 4
fi

TARGETS="${1:-display,mbp}"
TIMEOUT="${2:-80}"

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || (( TIMEOUT < 20 )); then
    echo "ERROR: timeout_sec must be an integer >= 20 (got '$TIMEOUT')" >&2
    exit 4
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HOME/Library/Logs/SyncCast/launch.log"
APP="/Applications/SyncCast.app"
DEFAULT_OUTPUT_HELPER="$SCRIPT_DIR/coreaudio_default_output.c"
DEFAULT_OUTPUT_PROBE="${TMPDIR:-/tmp}/syncast-coreaudio-default-output.$$"
DIRECT_UID_PREFIX="io.syncast.directaggregate.v1."

RESTORE_STEREO_PATH="$(launchctl getenv SYNCAST_STEREO_PATH 2>/dev/null || true)"
RESTORE_INITIAL_MODE="$(launchctl getenv SYNCAST_INITIAL_MODE 2>/dev/null || true)"
RESTORE_AUTO_TEST="$(launchctl getenv SYNCAST_AUTO_TEST 2>/dev/null || true)"

restore_launchctl_env() {
    local name="$1"
    local value="$2"
    if [[ -n "$value" ]]; then
        launchctl setenv "$name" "$value" >/dev/null 2>&1 || true
    else
        launchctl unsetenv "$name" >/dev/null 2>&1 || true
    fi
}

quit_syncast() {
    osascript -e 'quit app "SyncCast"' >/dev/null 2>&1 || true
    for _ in {1..20}; do
        if ! pgrep -fl SyncCastMenuBar >/dev/null 2>&1; then
            break
        fi
        sleep 0.25
    done
    pkill -9 -f '/Applications/SyncCast.app/Contents/Resources/sidecar/syncast-sidecar' 2>/dev/null || true
    pkill -9 -f '/Applications/SyncCast.app/Contents/Resources/owntone/owntone' 2>/dev/null || true
}

APP_WAS_RUNNING=0
if pgrep -fl SyncCastMenuBar >/dev/null 2>&1; then
    APP_WAS_RUNNING=1
fi

cleanup() {
    restore_launchctl_env SYNCAST_STEREO_PATH "$RESTORE_STEREO_PATH"
    restore_launchctl_env SYNCAST_INITIAL_MODE "$RESTORE_INITIAL_MODE"
    restore_launchctl_env SYNCAST_AUTO_TEST "$RESTORE_AUTO_TEST"
    quit_syncast
    rm -f "$DEFAULT_OUTPUT_PROBE"
    if [[ "$APP_WAS_RUNNING" == "1" ]]; then
        open "$APP" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if [[ ! -d "$APP" ]]; then
    echo "ERROR: $APP not found; install SyncCast first." >&2
    exit 1
fi
if [[ ! -f "$DEFAULT_OUTPUT_HELPER" ]]; then
    echo "ERROR: $DEFAULT_OUTPUT_HELPER not found." >&2
    exit 1
fi

read_default_output() {
    if [[ ! -x "$DEFAULT_OUTPUT_PROBE" || "$DEFAULT_OUTPUT_PROBE" -ot "$DEFAULT_OUTPUT_HELPER" ]]; then
        cc "$DEFAULT_OUTPUT_HELPER" \
            -framework CoreAudio \
            -framework CoreFoundation \
            -o "$DEFAULT_OUTPUT_PROBE"
    fi
    "$DEFAULT_OUTPUT_PROBE"
}

default_uid() {
    printf '%s\n' "$1" | awk -F '\t' '{print $2}'
}

quit_syncast
BASELINE_DEFAULT="$(read_default_output)"
BASELINE_UID="$(default_uid "$BASELINE_DEFAULT")"
if [[ -z "$BASELINE_UID" ]]; then
    echo "ERROR: could not read baseline default output UID." >&2
    exit 3
fi
if [[ "$BASELINE_UID" == "$DIRECT_UID_PREFIX"* ]]; then
    echo "ERROR: baseline default output is already a stale SyncCast Direct aggregate: $BASELINE_DEFAULT" >&2
    exit 3
fi

START_OFFSET=0
if [[ -f "$LOG" ]]; then
    START_OFFSET="$(stat -f '%z' "$LOG")"
fi

if (( USE_DEFAULT_PATH == 1 )); then
    launchctl unsetenv SYNCAST_STEREO_PATH
    PATH_MODE="default policy (SYNCAST_STEREO_PATH unset)"
else
    launchctl setenv SYNCAST_STEREO_PATH direct
    PATH_MODE="explicit SYNCAST_STEREO_PATH=direct"
fi
launchctl setenv SYNCAST_INITIAL_MODE stereo
launchctl setenv SYNCAST_AUTO_TEST "$TARGETS"
open "$APP"

echo "direct_stereo_smoke_test starting"
echo "  path    : $PATH_MODE"
echo "  targets : $TARGETS"
echo "  timeout : ${TIMEOUT}s"
echo "  log     : $LOG"
echo "  default : $BASELINE_DEFAULT"
echo

deadline=$((SECONDS + TIMEOUT))
read_offset="$START_OFFSET"
preflight_skipped=0
direct_start_seen=0
direct_driver_seen=0
start_ok_seen=0
router_start_failed=0
sck_start_seen=0
screen_recording_forbidden_seen=0
default_restore_failed=0
SUMMARY_LOG=""

while (( SECONDS < deadline )); do
    NEW_LOG="$(
        python3 - "$LOG" "$read_offset" <<'PYEOF'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
offset = int(sys.argv[2])
if not path.exists():
    sys.exit(0)
with path.open("rb") as f:
    f.seek(offset)
    sys.stdout.write(f.read().decode("utf-8", errors="replace"))
PYEOF
    )"
    if [[ -f "$LOG" ]]; then
        read_offset="$(stat -f '%z' "$LOG")"
    fi
    MATCHED_LINES="$(
        printf '%s\n' "$NEW_LOG" \
            | grep -E 'screen-recording preflight|requesting screen-recording access|screen-recording status|INITIAL_MODE env|AUTO_TEST:|reconcile: starting router|reconcile: router.start|capture report @ .*driver=directStereo|driver=directStereo|SCKCapture|router.start FAILED' \
            || true
    )"
    if [[ -n "$MATCHED_LINES" ]]; then
        SUMMARY_LOG+="${MATCHED_LINES}"$'\n'
    fi

    if printf '%s\n' "$NEW_LOG" | grep -q 'screen-recording preflight skipped:'; then
        preflight_skipped=1
    fi
    if printf '%s\n' "$NEW_LOG" | grep -q 'reconcile: starting router (Direct Stereo)'; then
        direct_start_seen=1
    fi
    if printf '%s\n' "$NEW_LOG" | grep -q 'driver=directStereo'; then
        direct_driver_seen=1
    fi
    if printf '%s\n' "$NEW_LOG" | grep -q 'reconcile: router.start OK'; then
        start_ok_seen=1
    fi
    if printf '%s\n' "$NEW_LOG" | grep -q 'reconcile: starting router (SCK capture)'; then
        sck_start_seen=1
    fi
    if printf '%s\n' "$NEW_LOG" \
        | grep -Eq 'screen-recording preflight:|requesting screen-recording access|SCKCapture|reconcile: starting router \(SCK capture\)|backend=sck|capture report .*backend=sck'; then
        screen_recording_forbidden_seen=1
        break
    fi
    if printf '%s\n' "$NEW_LOG" | grep -q 'reconcile: router.start FAILED:'; then
        router_start_failed=1
        break
    fi
    if (( preflight_skipped == 1 && direct_start_seen == 1 && direct_driver_seen == 1 && start_ok_seen == 1 )); then
        break
    fi
    sleep 2
done

quit_syncast
AFTER_DEFAULT=""
AFTER_UID=""
if ! AFTER_DEFAULT="$(read_default_output)"; then
    default_restore_failed=1
else
    AFTER_UID="$(default_uid "$AFTER_DEFAULT")"
    if [[ -z "$AFTER_UID" || "$AFTER_UID" == "$DIRECT_UID_PREFIX"* || "$AFTER_UID" != "$BASELINE_UID" ]]; then
        default_restore_failed=1
    fi
fi

printf '%s\n' "$SUMMARY_LOG" | sed '/^$/d'

echo
if (( router_start_failed == 1 )); then
    echo "BLOCKED: router failed to start during Direct Stereo smoke test." >&2
    exit 3
fi
if (( sck_start_seen == 1 )); then
    echo "FAIL: SCK capture started; Direct Stereo did not own the launch path." >&2
    exit 2
fi
if (( screen_recording_forbidden_seen == 1 )); then
    echo "FAIL: no-SCK Direct Stereo path touched Screen Recording or SCK." >&2
    exit 2
fi
if (( default_restore_failed == 1 )); then
    echo "FAIL: Direct Stereo did not restore the system default output." >&2
    echo "      before: $BASELINE_DEFAULT" >&2
    echo "      after : ${AFTER_DEFAULT:-<unreadable>}" >&2
    exit 3
fi
if (( preflight_skipped == 1 && direct_start_seen == 1 && direct_driver_seen == 1 && start_ok_seen == 1 )); then
    echo "PASS: Direct Stereo launch path observed; Screen Recording preflight was skipped, driver=directStereo appeared, and default output was restored."
    exit 0
fi

echo "FAIL: Direct Stereo launch path was not fully observed." >&2
echo "      Check that targets select one or more local CoreAudio outputs, not AirPlay receivers." >&2
exit 2
