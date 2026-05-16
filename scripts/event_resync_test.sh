#!/usr/bin/env bash
# Verify the opt-in event-driven Auto Calibrate path.
#
# This temporarily enables Continuous calibration, starts SyncCast in
# whole-home mode, toggles a local output plus an AirPlay receiver, and
# watches launch.log for an event-triggered full Auto Calibrate run.
# Defaults are restored on exit.
#
# Usage:
#   bash scripts/event_resync_test.sh [auto_test_targets] [timeout_sec] [drift_cycles] [drift_interval_sec]
#
# Exit codes:
#   0 pass
#   1 app not installed
#   2 calibration failed or did not apply
#   3 SyncCast could not start its capture/router backend
#   4 invalid arguments
#   5 post-apply drift validation completed but failed health gates
#   6 cleanup failed after an otherwise passing run
#
# Defaults:
#   auto_test_targets = display,xiaomi
#   timeout_sec       = 130
#   drift_cycles      = 0  (set >0 to run no-apply drift_test after apply)
#   drift_interval    = 30
#   drift_settle      = 20s via SYNCAST_DRIFT_SETTLE_SEC
#
# Active acoustic lab harness: can emit audible/high-band probes. Require
# SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST=1 plus a fresh session token file to avoid
# accidental runs from stale launchctl environment.

set -euo pipefail

TARGETS="${1:-display,xiaomi}"
TIMEOUT="${2:-130}"
DRIFT_CYCLES="${3:-0}"
DRIFT_INTERVAL="${4:-30}"
DRIFT_SETTLE="${SYNCAST_DRIFT_SETTLE_SEC:-20}"
CONFIRM_AUDIBLE_PROBE_TEST="${SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST:-0}"
ACTIVE_PROBE_SESSION_FILE="${SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE:-/private/tmp/syncast-active-probe-$(id -u).allow}"
ACTIVE_PROBE_SESSION_TOKEN="syncast-active-probe-$$-${RANDOM:-0}-$(date +%s)"

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || (( TIMEOUT < 30 )); then
    echo "ERROR: timeout_sec must be an integer >= 30 (got '$TIMEOUT')" >&2
    exit 4
fi
if ! [[ "$DRIFT_CYCLES" =~ ^[0-9]+$ ]]; then
    echo "ERROR: drift_cycles must be a non-negative integer (got '$DRIFT_CYCLES')" >&2
    exit 4
fi
if ! [[ "$DRIFT_INTERVAL" =~ ^[0-9]+$ ]] || (( DRIFT_INTERVAL < 5 )); then
    echo "ERROR: drift_interval_sec must be an integer >= 5 (got '$DRIFT_INTERVAL')" >&2
    exit 4
fi
if ! [[ "$DRIFT_SETTLE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: SYNCAST_DRIFT_SETTLE_SEC must be a non-negative integer (got '$DRIFT_SETTLE')" >&2
    exit 4
fi
if [[ "$CONFIRM_AUDIBLE_PROBE_TEST" != "1" ]]; then
    echo "ERROR: this active acoustic lab harness can emit audible probes; set SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST=1 to run it." >&2
    exit 4
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/coreaudio_default_output_guard.sh"
DOMAIN="io.syncast.menubar"
BG_KEY="syncast.bgCalibrationEnabled"
INTERVAL_KEY="syncast.bgCalibrationIntervalS"
DELAY_KEY="syncast.airplayDelayMs"
LOCK_KEY="syncast.airplayDelayLockedAt"
LOG="$HOME/Library/Logs/SyncCast/launch.log"
SOCKET="/tmp/syncast-$(id -u).calibration.sock"
APP="/Applications/SyncCast.app"

read_default_or_unset() {
    local key="$1"
    defaults read "$DOMAIN" "$key" 2>/dev/null || printf '__unset__'
}

read_launch_env() {
    local key="$1"
    launchctl getenv "$key" 2>/dev/null || true
}

restore_launch_env() {
    local key="$1"
    local value="$2"
    if [[ -n "$value" ]]; then
        launchctl setenv "$key" "$value" >/dev/null 2>&1 || true
    else
        launchctl unsetenv "$key" >/dev/null 2>&1 || true
    fi
}

remove_active_probe_session_file() {
    if [[ -f "$ACTIVE_PROBE_SESSION_FILE" ]] &&
        [[ "$(cat "$ACTIVE_PROBE_SESSION_FILE" 2>/dev/null || true)" == "$ACTIVE_PROBE_SESSION_TOKEN" ]]; then
        rm -f "$ACTIVE_PROBE_SESSION_FILE" 2>/dev/null || true
    fi
}

restore_default() {
    local key="$1"
    local value="$2"
    if [[ "$value" == "__unset__" ]]; then
        defaults delete "$DOMAIN" "$key" >/dev/null 2>&1 || true
    else
        case "$key" in
            "$BG_KEY")
                case "$value" in
                    1|true|TRUE|yes|YES)
                        defaults write "$DOMAIN" "$key" -bool true
                        ;;
                    *)
                        defaults write "$DOMAIN" "$key" -bool false
                        ;;
                esac
                ;;
            "$DELAY_KEY"|"$LOCK_KEY"|"$INTERVAL_KEY")
                defaults write "$DOMAIN" "$key" -int "$value"
                ;;
            *)
                if [[ "$value" =~ ^-?[0-9]+$ ]]; then
                    defaults write "$DOMAIN" "$key" -int "$value"
                else
                    defaults write "$DOMAIN" "$key" "$value"
                fi
                ;;
        esac
    fi
}

quit_syncast() {
    osascript -e 'quit app "SyncCast"' >/dev/null 2>&1 || true
    for _ in {1..20}; do
        if ! pgrep -x SyncCastMenuBar >/dev/null 2>&1; then
            pkill -9 -f '/Applications/SyncCast.app/Contents/Resources/sidecar/syncast-sidecar' 2>/dev/null || true
            pkill -9 -f '/Applications/SyncCast.app/Contents/Resources/owntone/owntone' 2>/dev/null || true
            return 0
        fi
        sleep 0.25
    done
    pkill -9 -f '/Applications/SyncCast.app/Contents/Resources/sidecar/syncast-sidecar' 2>/dev/null || true
    pkill -9 -f '/Applications/SyncCast.app/Contents/Resources/owntone/owntone' 2>/dev/null || true
    echo "WARN: SyncCast did not quit cleanly." >&2
    return 1
}

OLD_BG="$(read_default_or_unset "$BG_KEY")"
OLD_INTERVAL="$(read_default_or_unset "$INTERVAL_KEY")"
OLD_DELAY="$(read_default_or_unset "$DELAY_KEY")"
OLD_LOCK="$(read_default_or_unset "$LOCK_KEY")"
OLD_ENV_INITIAL_MODE="$(read_launch_env SYNCAST_INITIAL_MODE)"
OLD_ENV_AUTO_TEST="$(read_launch_env SYNCAST_AUTO_TEST)"
OLD_ENV_ACTIVE_CALIBRATION="$(read_launch_env SYNCAST_ENABLE_ACTIVE_CALIBRATION)"
OLD_ENV_AUDIBLE_PROBES="$(read_launch_env SYNCAST_ALLOW_AUDIBLE_PROBES)"
OLD_ENV_AUDIBLE_CONFIRM="$(read_launch_env SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST)"
OLD_ENV_ACTIVE_PROBE_SESSION="$(read_launch_env SYNCAST_ACTIVE_PROBE_LAB_SESSION)"
OLD_ENV_ACTIVE_PROBE_SESSION_FILE="$(read_launch_env SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE)"
APP_WAS_RUNNING=0
if pgrep -x SyncCastMenuBar >/dev/null 2>&1; then
    APP_WAS_RUNNING=1
fi
APP_STOPPED_FOR_TEST=0
ACOUSTIC_SETUP_PASSED=0

cleanup() {
    local status=$?
    local cleanup_failed=0
    trap - EXIT
    if (( ACOUSTIC_SETUP_PASSED == 1 )); then
        restore_launch_env SYNCAST_INITIAL_MODE "$OLD_ENV_INITIAL_MODE"
        restore_launch_env SYNCAST_AUTO_TEST "$OLD_ENV_AUTO_TEST"
        restore_launch_env SYNCAST_ENABLE_ACTIVE_CALIBRATION "$OLD_ENV_ACTIVE_CALIBRATION"
        restore_launch_env SYNCAST_ALLOW_AUDIBLE_PROBES "$OLD_ENV_AUDIBLE_PROBES"
        restore_launch_env SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST "$OLD_ENV_AUDIBLE_CONFIRM"
        restore_launch_env SYNCAST_ACTIVE_PROBE_LAB_SESSION "$OLD_ENV_ACTIVE_PROBE_SESSION"
        restore_launch_env SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE "$OLD_ENV_ACTIVE_PROBE_SESSION_FILE"
        remove_active_probe_session_file
        restore_default "$BG_KEY" "$OLD_BG"
        restore_default "$INTERVAL_KEY" "$OLD_INTERVAL"
        restore_default "$DELAY_KEY" "$OLD_DELAY"
        restore_default "$LOCK_KEY" "$OLD_LOCK"
        if ! quit_syncast; then
            cleanup_failed=1
        fi
    fi
    if ! syncast_restore_acoustic_default_output; then
        cleanup_failed=1
    fi
    syncast_cleanup_coreaudio_default_output_probe
    if [[ "$APP_WAS_RUNNING" == "1" && "$APP_STOPPED_FOR_TEST" == "1" ]]; then
        if ! open "$APP" >/dev/null 2>&1; then
            echo "WARN: failed to reopen SyncCast after test cleanup." >&2
            cleanup_failed=1
        fi
    fi
    if (( cleanup_failed == 1 && status == 0 )); then
        exit 6
    fi
    exit "$status"
}
trap cleanup EXIT

if [[ ! -d "$APP" ]]; then
    echo "ERROR: $APP not found; install SyncCast first." >&2
    exit 1
fi
if (( APP_WAS_RUNNING == 1 )); then
    if ! quit_syncast; then
        echo "ERROR: SyncCast was running and did not quit cleanly; refusing to change default output for acoustic test." >&2
        exit 6
    fi
    APP_STOPPED_FOR_TEST=1
fi
syncast_prepare_ordinary_default_output_for_acoustic_test "$TARGETS" || exit $?
ACOUSTIC_SETUP_PASSED=1

defaults write "$DOMAIN" "$BG_KEY" -bool true
defaults write "$DOMAIN" "$INTERVAL_KEY" -int 3600
defaults write "$DOMAIN" "$LOCK_KEY" -int 0
if [[ "$OLD_DELAY" != "__unset__" ]]; then
    defaults write "$DOMAIN" "$DELAY_KEY" -int "$OLD_DELAY"
fi

rm -f "$SOCKET"
if ! quit_syncast; then
    echo "ERROR: SyncCast did not quit cleanly before test launch." >&2
    exit 6
fi

START_OFFSET=0
if [[ -f "$LOG" ]]; then
    START_OFFSET="$(stat -f '%z' "$LOG")"
fi

launchctl setenv SYNCAST_INITIAL_MODE wholehome
launchctl setenv SYNCAST_AUTO_TEST "$TARGETS"
launchctl setenv SYNCAST_ENABLE_ACTIVE_CALIBRATION 1
launchctl setenv SYNCAST_ALLOW_AUDIBLE_PROBES 1
launchctl setenv SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST 1
printf '%s\n' "$ACTIVE_PROBE_SESSION_TOKEN" > "$ACTIVE_PROBE_SESSION_FILE"
chmod 600 "$ACTIVE_PROBE_SESSION_FILE" >/dev/null 2>&1 || true
launchctl setenv SYNCAST_ACTIVE_PROBE_LAB_SESSION "$ACTIVE_PROBE_SESSION_TOKEN"
launchctl setenv SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE "$ACTIVE_PROBE_SESSION_FILE"
open "$APP"

echo "event_resync_test starting"
echo "  targets : $TARGETS"
echo "  timeout : ${TIMEOUT}s"
echo "  drift   : ${DRIFT_CYCLES} cycles @ ${DRIFT_INTERVAL}s"
echo "  settle  : ${DRIFT_SETTLE}s before drift"
echo "  log     : $LOG"
echo "  socket  : $SOCKET"
printf '%s\n' "$SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT"
echo

deadline=$((SECONDS + TIMEOUT))
read_offset="$START_OFFSET"
event_seen=0
done_seen=0
applied_seen=0
failed_seen=0
router_start_failed=0
router_no_display=0
mic_ready_seen=0
probe_anchor_seen=0
SUMMARY_LOG=""
NEW_LOG=""

read_new_log() {
    NEW_LOG="$(python3 - "$LOG" "$read_offset" <<'PYEOF'
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
}

wait_for_post_apply_validation_if_scheduled() {
    local scheduled=0
    if printf '%s\n' "$SUMMARY_LOG" \
        | grep -q 'autoCalib post-apply validation scheduled'; then
        scheduled=1
    else
        sleep 6
        read_new_log
        local probe_log="$NEW_LOG"
        local probe_lines
        probe_lines="$(
            printf '%s\n' "$probe_log" \
                | grep -E 'autoCalib post-apply validation|autoCalib:|ActiveCalib] DONE|mic_ready first_host=|probe_anchor=|airplayDelay applied' \
                || true
        )"
        if [[ -n "$probe_lines" ]]; then
            SUMMARY_LOG+="${probe_lines}"$'\n'
            printf '%s\n' "$probe_lines"
        fi
        if printf '%s\n' "$probe_log" \
            | grep -q 'autoCalib post-apply validation scheduled'; then
            scheduled=1
        fi
    fi
    if (( scheduled == 0 )); then
        return 0
    fi

    echo
    echo "Waiting for post-apply settle validation before drift..."
    local post_deadline=$((SECONDS + 260))
    while (( SECONDS < post_deadline )); do
        read_new_log
        local post_log="$NEW_LOG"
        local post_lines
        post_lines="$(
            printf '%s\n' "$post_log" \
                | grep -E 'autoCalib post-apply validation|autoCalib:|ActiveCalib] DONE|mic_ready first_host=|probe_anchor=|airplayDelay applied' \
                || true
        )"
        if [[ -n "$post_lines" ]]; then
            SUMMARY_LOG+="${post_lines}"$'\n'
            printf '%s\n' "$post_lines"
        fi
        if printf '%s\n' "$post_log" \
            | grep -q 'autoCalib post-apply validation finished'; then
            return 0
        fi
        if printf '%s\n' "$post_log" \
            | grep -Eq 'autoCalib: failed|autoCalib event .*aborted'; then
            echo "FAIL: post-apply validation failed or aborted." >&2
            exit 2
        fi
        sleep 3
    done
    echo "FAIL: post-apply validation did not finish before timeout." >&2
    exit 2
}

while (( SECONDS < deadline )); do
    read_new_log
    MATCHED_LINES="$(
        printf '%s\n' "$NEW_LOG" \
            | grep -E 'reconcile: router.start FAILED|autoCalib event|autoCalib post-apply validation|autoCalib:|ActiveCalib] DONE|mic_ready first_host=|probe_anchor=|ContActiveCalib].*target=0ms drift=-|airplayDelay applied|airplayDelay auto-apply aborted|bgCalib:' \
            || true
    )"
    if [[ -n "$MATCHED_LINES" ]]; then
        SUMMARY_LOG+="${MATCHED_LINES}"$'\n'
    fi

    if printf '%s\n' "$NEW_LOG" | grep -q 'autoCalib event running'; then
        event_seen=1
    fi
    if printf '%s\n' "$NEW_LOG" | grep -q '\[ActiveCalib\] DONE'; then
        done_seen=1
    fi
    if printf '%s\n' "$NEW_LOG" | grep -Eq 'autoCalib: applied'; then
        applied_seen=1
    fi
    if printf '%s\n' "$NEW_LOG" | grep -q 'mic_ready first_host='; then
        mic_ready_seen=1
    fi
    if printf '%s\n' "$NEW_LOG" | grep -q 'probe_anchor='; then
        probe_anchor_seen=1
    fi
    if printf '%s\n' "$NEW_LOG" | grep -q 'reconcile: router.start FAILED:'; then
        router_start_failed=1
        if printf '%s\n' "$NEW_LOG" | grep -q 'reconcile: router.start FAILED: no display available'; then
            router_no_display=1
        fi
    fi
    if printf '%s\n' "$NEW_LOG" \
        | grep -Eq 'autoCalib: failed|autoCalib: recommended .* rejected|autoCalib: verify result ignored|autoCalib event .*aborted|airplayDelay auto-apply aborted|ContActiveCalib].*target=0ms drift=-'; then
        failed_seen=1
    fi
    if (( router_start_failed == 1 )); then
        break
    fi
    if (( failed_seen == 1 )); then
        break
    fi
    if (( event_seen == 1 && done_seen == 1 && applied_seen == 1 )); then
        break
    fi
    sleep 3
done

printf '%s\n' "$SUMMARY_LOG" | sed '/^$/d'

echo
if (( router_start_failed == 1 )); then
    echo "BLOCKED: SyncCast could not start its capture/router backend." >&2
    if (( router_no_display == 1 )); then
        echo "         ScreenCaptureKit reported no display available. Wake/unlock the display, or use the non-SCK Direct Stereo / Process Tap path for this class of test." >&2
    else
        echo "         See the router.start FAILED line above for the backend error." >&2
    fi
    exit 3
fi

if (( failed_seen == 0 && event_seen == 1 && done_seen == 1 && applied_seen == 1 )); then
    if (( mic_ready_seen == 0 || probe_anchor_seen == 0 )); then
        echo "FAIL: trusted apply completed without observing mic-ready-gated probe logs." >&2
        echo "      Expected both 'mic_ready first_host=' and 'probe_anchor=' before accepting acoustic evidence." >&2
        exit 2
    fi
    echo "PASS: event-driven Auto Calibrate ran to completion and applied a trusted delay."
    printf 'Current airplayDelayMs: '
    defaults read "$DOMAIN" "$DELAY_KEY" 2>/dev/null || true
    wait_for_post_apply_validation_if_scheduled
    if (( DRIFT_CYCLES > 0 )); then
        echo
        if (( DRIFT_SETTLE > 0 )); then
            echo "Waiting ${DRIFT_SETTLE}s for post-apply transport settle..."
            sleep "$DRIFT_SETTLE"
        fi
        echo "Running no-apply drift validation..."
        bash "$SCRIPT_DIR/drift_test.sh" "$DRIFT_CYCLES" "$DRIFT_INTERVAL"
    fi
    exit 0
fi

echo "FAIL: did not observe event-driven Auto Calibrate run, complete, and apply a trusted delay." >&2
echo "      Check that SyncCast has microphone permission and that targets select one local output plus one AirPlay receiver." >&2
exit 2
