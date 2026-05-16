#!/usr/bin/env bash
# Verify the experimental Core Audio Process Tap capture backend.
#
# This launches the installed app with SYNCAST_CAPTURE_BACKEND=tap, toggles
# local CoreAudio outputs through SYNCAST_AUTO_TEST, and watches launch.log
# for proof that SyncCast used Process Tap instead of ScreenCaptureKit.
#
# Usage:
#   bash scripts/tap_capture_smoke_test.sh [auto_test_targets] [timeout_sec]
#
# Defaults:
#   auto_test_targets = display,mbp
#   timeout_sec       = 80
#
# Exit codes:
#   0 pass
#   1 app not installed
#   2 Tap capture was not observed, or it started but captured no frames
#   3 router/backend failed
#   4 invalid arguments
#
# By default this test does not play any auxiliary audio. It watches whatever
# non-SyncCast audio is already present in the user session, which avoids
# surprising audible probe sounds during Goal runs. Set
# SYNCAST_TAP_SMOKE_PROBE=1 to play a short low-volume system sound when a
# deterministic non-silent Tap callback is needed. Because this is intentionally
# audible, it also requires SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST=1.

set -euo pipefail

TARGETS="${1:-display,mbp}"
TIMEOUT="${2:-80}"
TAP_AUDIO_PROBE="${SYNCAST_TAP_SMOKE_PROBE:-0}"
AUDIBLE_PROBE_CONFIRM="${SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST:-0}"

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || (( TIMEOUT < 20 )); then
    echo "ERROR: timeout_sec must be an integer >= 20 (got '$TIMEOUT')" >&2
    exit 4
fi
case "$TAP_AUDIO_PROBE" in
    0|1)
        ;;
    *)
        echo "ERROR: SYNCAST_TAP_SMOKE_PROBE must be 0 or 1 (got '$TAP_AUDIO_PROBE')" >&2
        exit 4
        ;;
esac
case "$AUDIBLE_PROBE_CONFIRM" in
    0|1)
        ;;
    *)
        echo "ERROR: SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST must be 0 or 1 (got '$AUDIBLE_PROBE_CONFIRM')" >&2
        exit 4
        ;;
esac
if [[ "$TAP_AUDIO_PROBE" == "1" && "$AUDIBLE_PROBE_CONFIRM" != "1" ]]; then
    echo "ERROR: SYNCAST_TAP_SMOKE_PROBE=1 plays an audible probe; also set SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST=1 to confirm." >&2
    exit 4
fi

LOG="$HOME/Library/Logs/SyncCast/launch.log"
APP="/Applications/SyncCast.app"
SOUND_FILE="${SYNCAST_TAP_SMOKE_SOUND:-/System/Library/Sounds/Glass.aiff}"
SOUND_VOLUME="${SYNCAST_TAP_SMOKE_VOLUME:-0.003}"
AUDIO_PROBE_PID=""

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

start_audio_probe() {
    if [[ "$TAP_AUDIO_PROBE" != "1" ]]; then
        return 0
    fi
    if [[ ! -f "$SOUND_FILE" ]]; then
        echo "ERROR: audio probe file not found: $SOUND_FILE" >&2
        return 1
    fi
    (
        child_pid=""
        trap 'if [[ -n "${child_pid:-}" ]]; then kill "$child_pid" >/dev/null 2>&1 || true; fi; exit 0' TERM INT EXIT
        while true; do
            afplay -v "$SOUND_VOLUME" "$SOUND_FILE" >/dev/null 2>&1 &
            child_pid="$!"
            wait "$child_pid" >/dev/null 2>&1 || true
            child_pid=""
            sleep 0.2 &
            child_pid="$!"
            wait "$child_pid" >/dev/null 2>&1 || true
            child_pid=""
        done
    ) &
    AUDIO_PROBE_PID="$!"
}

stop_audio_probe() {
    if [[ -n "${AUDIO_PROBE_PID:-}" ]]; then
        kill "$AUDIO_PROBE_PID" >/dev/null 2>&1 || true
        wait "$AUDIO_PROBE_PID" >/dev/null 2>&1 || true
        AUDIO_PROBE_PID=""
    fi
}

APP_WAS_RUNNING=0
if pgrep -fl SyncCastMenuBar >/dev/null 2>&1; then
    APP_WAS_RUNNING=1
fi

cleanup() {
    stop_audio_probe
    launchctl unsetenv SYNCAST_CAPTURE_BACKEND >/dev/null 2>&1 || true
    launchctl unsetenv SYNCAST_STEREO_PATH >/dev/null 2>&1 || true
    launchctl unsetenv SYNCAST_INITIAL_MODE >/dev/null 2>&1 || true
    launchctl unsetenv SYNCAST_AUTO_TEST >/dev/null 2>&1 || true
    quit_syncast
    if [[ "$APP_WAS_RUNNING" == "1" ]]; then
        open "$APP" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if [[ ! -d "$APP" ]]; then
    echo "ERROR: $APP not found; install SyncCast first." >&2
    exit 1
fi

START_OFFSET=0
if [[ -f "$LOG" ]]; then
    START_OFFSET="$(stat -f '%z' "$LOG")"
fi

quit_syncast

launchctl setenv SYNCAST_CAPTURE_BACKEND tap
launchctl setenv SYNCAST_STEREO_PATH capture
launchctl setenv SYNCAST_INITIAL_MODE stereo
launchctl setenv SYNCAST_AUTO_TEST "$TARGETS"
start_audio_probe || exit 4
open "$APP"

echo "tap_capture_smoke_test starting"
echo "  targets : $TARGETS"
echo "  timeout : ${TIMEOUT}s"
echo "  log     : $LOG"
echo "  stereo path: capture (explicit Tap/SCK fallback, not Direct Stereo)"
if [[ "$TAP_AUDIO_PROBE" == "1" ]]; then
    echo "  probe   : enabled, $SOUND_FILE @ volume $SOUND_VOLUME (confirmed audible)"
else
    echo "  probe   : disabled; relying on existing non-SyncCast audio"
fi
echo

deadline=$((SECONDS + TIMEOUT))
read_offset="$START_OFFSET"
screen_not_required=0
preflight_skipped=0
tap_start_seen=0
tap_backend_seen=0
tap_audio_seen=0
start_ok_seen=0
router_start_failed=0
sck_start_seen=0
screen_recording_forbidden_seen=0
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
            | grep -E 'screen-recording preflight|requesting screen-recording access|screen-recording status|INITIAL_MODE env|AUTO_TEST:|reconcile: starting router|reconcile: router.start|capture report @ .*backend=tap|backend=tap|SCKCapture|router.start FAILED' \
            || true
    )"
    if [[ -n "$MATCHED_LINES" ]]; then
        SUMMARY_LOG+="${MATCHED_LINES}"$'\n'
    fi

    if printf '%s\n' "$NEW_LOG" | grep -q 'screen-recording preflight skipped:'; then
        preflight_skipped=1
    fi
    if printf '%s\n' "$NEW_LOG" | grep -Eq 'screen-recording status: not required.*(Process Tap capture|capture=tap)'; then
        screen_not_required=1
    fi
    if printf '%s\n' "$NEW_LOG" | grep -q 'reconcile: starting router (Process Tap capture)'; then
        tap_start_seen=1
    fi
    if printf '%s\n' "$NEW_LOG" | grep -q 'backend=tap'; then
        tap_backend_seen=1
    fi
    if printf '%s\n' "$NEW_LOG" \
        | grep -Eq 'backend=tap seen=[1-9][0-9]* written=[1-9][0-9]* ticks=[1-9][0-9]* peak=[0-9.]+/(0\.[0-9]*[1-9]|[1-9][0-9]*(\.[0-9]+)?)'; then
        tap_audio_seen=1
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
    if (( screen_not_required == 1 && tap_start_seen == 1 && tap_backend_seen == 1 && tap_audio_seen == 1 && start_ok_seen == 1 )); then
        break
    fi
    sleep 2
done

printf '%s\n' "$SUMMARY_LOG" | sed '/^$/d'

echo
if (( router_start_failed == 1 )); then
    echo "BLOCKED: router failed to start during Process Tap smoke test." >&2
    exit 3
fi
if (( sck_start_seen == 1 )); then
    echo "FAIL: SCK capture started; Process Tap did not own the launch path." >&2
    exit 2
fi
if (( screen_recording_forbidden_seen == 1 )); then
    echo "FAIL: no-SCK Tap path touched Screen Recording or SCK." >&2
    exit 2
fi
if (( preflight_skipped == 1 && screen_not_required == 1 && tap_start_seen == 1 && tap_backend_seen == 1 && tap_audio_seen == 1 && start_ok_seen == 1 )); then
    echo "PASS: Process Tap launch path observed; Screen Recording was not required and backend=tap captured non-silent audio."
    exit 0
fi

echo "FAIL: Process Tap launch path was not fully observed." >&2
echo "      Check macOS version, Tap permissions, selected local output targets, and whether non-SyncCast audio was playing." >&2
exit 2
