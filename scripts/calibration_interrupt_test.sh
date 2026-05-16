#!/usr/bin/env bash
# Verify calibration fail-closed behavior when routing changes mid-measurement.
#
# This starts SyncCast in whole-home mode, enables a local output plus an
# AirPlay receiver, schedules one benign AirPlay volume change while the first
# event-driven Auto Calibrate run is expected to be in flight, and requires:
#   1. the in-flight calibration notices the route revision change,
#   2. no stale pre-mutation result is applied after the mutation, and
#   3. the pending event-driven calibration recovers and applies a trusted delay.
#
# Usage:
#   bash scripts/calibration_interrupt_test.sh [targets] [action] [timeout_sec] [drift_cycles] [drift_interval_sec]
#
# Example:
#   bash scripts/calibration_interrupt_test.sh display,xiaomi volume:xiaomi:0.37:40 260 1 60
#
# Active acoustic lab harness: can emit audible/high-band probes. Require
# SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST=1 plus a fresh session token file to avoid
# accidental runs from stale launchctl environment.

set -euo pipefail

TARGETS="${1:-display,xiaomi}"
ACTION="${2:-volume:xiaomi:0.37:40}"
TIMEOUT="${3:-260}"
DRIFT_CYCLES="${4:-0}"
DRIFT_INTERVAL="${5:-60}"
DRIFT_SETTLE="${SYNCAST_DRIFT_SETTLE_SEC:-20}"
CAPTURE_BACKEND="${SYNCAST_TEST_CAPTURE_BACKEND:-}"
TAP_AUDIO_PROBE="${SYNCAST_TAP_CALIBRATION_PROBE:-0}"
CONFIRM_AUDIBLE_PROBE_TEST="${SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST:-0}"
ACTIVE_PROBE_SESSION_FILE="${SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE:-/private/tmp/syncast-active-probe-$(id -u).allow}"
ACTIVE_PROBE_SESSION_TOKEN="syncast-active-probe-$$-${RANDOM:-0}-$(date +%s)"

if [[ "$ACTION" == *","* ]]; then
    echo "ERROR: calibration_interrupt_test expects exactly one action." >&2
    exit 4
fi
IFS=':' read -r ACTION_VERB ACTION_TARGET ACTION_VALUE ACTION_DELAY <<< "$ACTION"
ACTION_VERB="$(printf '%s' "${ACTION_VERB:-}" | tr '[:upper:]' '[:lower:]')"
if [[ "$ACTION_VERB" != "volume" ]]; then
    echo "ERROR: route-interrupt action must be a benign volume change (got '$ACTION')." >&2
    exit 4
fi
if ! [[ "${ACTION_VALUE:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    ! awk -v v="$ACTION_VALUE" 'BEGIN { exit !((v + 0) > 0.01 && (v + 0) <= 1.0) }'; then
    echo "ERROR: route-interrupt volume must be in (0.01, 1.0] (got '$ACTION')." >&2
    exit 4
fi
if ! [[ "${ACTION_DELAY:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "ERROR: route-interrupt action delay must be numeric (got '$ACTION')." >&2
    exit 4
fi
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || (( TIMEOUT < 120 )); then
    echo "ERROR: timeout_sec must be an integer >= 120 (got '$TIMEOUT')" >&2
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
case "$CAPTURE_BACKEND" in
    ""|"sck"|"tap")
        ;;
    *)
        echo "ERROR: SYNCAST_TEST_CAPTURE_BACKEND must be empty, sck, or tap (got '$CAPTURE_BACKEND')" >&2
        exit 4
        ;;
esac
case "$TAP_AUDIO_PROBE" in
    0|1)
        ;;
    *)
        echo "ERROR: SYNCAST_TAP_CALIBRATION_PROBE must be 0 or 1 (got '$TAP_AUDIO_PROBE')" >&2
        exit 4
        ;;
esac

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
SOUND_FILE="${SYNCAST_TAP_CALIBRATION_SOUND:-/System/Library/Sounds/Glass.aiff}"
SOUND_VOLUME="${SYNCAST_TAP_CALIBRATION_VOLUME:-0.003}"
AUDIO_PROBE_PID=""

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

start_audio_probe_if_needed() {
    if [[ "$CAPTURE_BACKEND" != "tap" || "$TAP_AUDIO_PROBE" != "1" ]]; then
        return 0
    fi
    if [[ ! -f "$SOUND_FILE" ]]; then
        echo "ERROR: tap calibration audio probe file not found: $SOUND_FILE" >&2
        return 4
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

OLD_BG="$(read_default_or_unset "$BG_KEY")"
OLD_INTERVAL="$(read_default_or_unset "$INTERVAL_KEY")"
OLD_DELAY="$(read_default_or_unset "$DELAY_KEY")"
OLD_LOCK="$(read_default_or_unset "$LOCK_KEY")"
OLD_ENV_INITIAL_MODE="$(read_launch_env SYNCAST_INITIAL_MODE)"
OLD_ENV_AUTO_TEST="$(read_launch_env SYNCAST_AUTO_TEST)"
OLD_ENV_AUTO_TEST_ACTIONS="$(read_launch_env SYNCAST_AUTO_TEST_ACTIONS)"
OLD_ENV_CAPTURE_BACKEND="$(read_launch_env SYNCAST_CAPTURE_BACKEND)"
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
    stop_audio_probe
    if (( ACOUSTIC_SETUP_PASSED == 1 )); then
        restore_launch_env SYNCAST_INITIAL_MODE "$OLD_ENV_INITIAL_MODE"
        restore_launch_env SYNCAST_AUTO_TEST "$OLD_ENV_AUTO_TEST"
        restore_launch_env SYNCAST_AUTO_TEST_ACTIONS "$OLD_ENV_AUTO_TEST_ACTIONS"
        restore_launch_env SYNCAST_CAPTURE_BACKEND "$OLD_ENV_CAPTURE_BACKEND"
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
launchctl setenv SYNCAST_AUTO_TEST_ACTIONS "$ACTION"
launchctl setenv SYNCAST_ENABLE_ACTIVE_CALIBRATION 1
launchctl setenv SYNCAST_ALLOW_AUDIBLE_PROBES 1
launchctl setenv SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST 1
printf '%s\n' "$ACTIVE_PROBE_SESSION_TOKEN" > "$ACTIVE_PROBE_SESSION_FILE"
chmod 600 "$ACTIVE_PROBE_SESSION_FILE" >/dev/null 2>&1 || true
launchctl setenv SYNCAST_ACTIVE_PROBE_LAB_SESSION "$ACTIVE_PROBE_SESSION_TOKEN"
launchctl setenv SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE "$ACTIVE_PROBE_SESSION_FILE"
if [[ -n "$CAPTURE_BACKEND" ]]; then
    launchctl setenv SYNCAST_CAPTURE_BACKEND "$CAPTURE_BACKEND"
fi
start_audio_probe_if_needed || exit $?
open "$APP"

echo "calibration_interrupt_test starting"
echo "  targets : $TARGETS"
echo "  action  : $ACTION"
echo "  timeout : ${TIMEOUT}s"
echo "  drift   : ${DRIFT_CYCLES} cycles @ ${DRIFT_INTERVAL}s"
if [[ -n "$CAPTURE_BACKEND" ]]; then
    echo "  capture : $CAPTURE_BACKEND"
    if [[ "$CAPTURE_BACKEND" == "tap" ]]; then
        if [[ "$TAP_AUDIO_PROBE" == "1" ]]; then
            echo "  probe   : enabled, $SOUND_FILE @ volume $SOUND_VOLUME"
        else
            echo "  probe   : disabled; relying on existing non-SyncCast audio for tap callbacks"
        fi
    fi
fi
echo "  log     : $LOG"
echo "  socket  : $SOCKET"
printf '%s\n' "$SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT"
echo

deadline=$((SECONDS + TIMEOUT))
read_offset="$START_OFFSET"
event_running_seen=0
action_seen=0
action_after_event_seen=0
action_invalid=0
action_too_late=0
deferred_seen=0
route_change_seen=0
route_restore_skipped_seen=0
route_context_failure_seen=0
recovery_event_seen=0
recovery_applied=0
post_scheduled=0
post_finished=0
post_validation_warning=0
router_start_failed=0
router_no_display=0
unexpected_failure=0
stale_apply_seen=0
tap_audio_seen=0
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

while (( SECONDS < deadline )); do
    read_new_log
    MATCHED_LINES="$(
        printf '%s\n' "$NEW_LOG" \
            | grep -E 'AUTO_TEST_ACTION|reconcile: router.start FAILED|autoCalib event|autoCalib post-apply validation|autoCalib:|ActiveCalib] DONE|mic_ready first_host=|probe_anchor=|airplayDelay applied|calibration routing restore skipped|calibration route context changed|capture report @ .*backend=tap|backend=tap' \
            || true
    )"
    if [[ -n "$MATCHED_LINES" ]]; then
        SUMMARY_LOG+="${MATCHED_LINES}"$'\n'
    fi

    if [[ -n "$MATCHED_LINES" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$CAPTURE_BACKEND" == "tap" ]] &&
                printf '%s\n' "$line" | grep -Eq 'backend=tap seen=[1-9][0-9]* written=[1-9][0-9]* ticks=[1-9][0-9]*'; then
                tap_audio_seen=1
                continue
            fi
            if [[ "$line" == *"mic_ready first_host="* ]]; then
                mic_ready_seen=1
                continue
            fi
            if [[ "$line" == *"probe_anchor="* ]]; then
                probe_anchor_seen=1
                continue
            fi
            if [[ "$line" == *"reconcile: router.start FAILED:"* ]]; then
                router_start_failed=1
                if [[ "$line" == *"no display available"* ]]; then
                    router_no_display=1
                fi
                break
            fi
            if [[ "$line" == *"AUTO_TEST_ACTION:"* ]]; then
                if printf '%s\n' "$line" | grep -Eq 'invalid|unknown verb|no device matched'; then
                    action_invalid=1
                    break
                fi
                if printf '%s\n' "$line" | grep -q 'setting volume'; then
                    action_seen=1
                    if (( event_running_seen == 1 )); then
                        action_after_event_seen=1
                    fi
                fi
                continue
            fi
            if [[ "$line" == *"autoCalib event running"* ]]; then
                if (( action_seen == 0 )); then
                    event_running_seen=1
                elif (( route_change_seen == 1 )); then
                    recovery_event_seen=1
                fi
                continue
            fi
            if (( action_seen == 1 )) &&
                [[ "$line" == *"autoCalib event deferred: calibration already running"* ]]; then
                deferred_seen=1
                continue
            fi
            if [[ "$line" == *"calibration routing restore skipped because route revision changed"* ]]; then
                route_restore_skipped_seen=1
                continue
            fi
            if [[ "$line" == *"calibration route context changed during measurement"* ]]; then
                route_change_seen=1
                route_context_failure_seen=1
                continue
            fi
            if printf '%s\n' "$line" | grep -q 'autoCalib: applied'; then
                if (( action_seen == 0 )); then
                    action_too_late=1
                    break
                fi
                if (( route_context_failure_seen == 0 ||
                      recovery_event_seen == 0 )); then
                    stale_apply_seen=1
                    break
                fi
                recovery_applied=1
                continue
            fi
            if (( route_change_seen == 1 )) &&
                printf '%s\n' "$line" | grep -q 'autoCalib post-apply validation scheduled'; then
                post_scheduled=1
                continue
            fi
            if (( route_change_seen == 1 )) &&
                printf '%s\n' "$line" | grep -q 'autoCalib post-apply validation finished'; then
                post_finished=1
                continue
            fi
            if (( recovery_applied == 1 && post_scheduled == 1 )) &&
                printf '%s\n' "$line" | grep -q 'autoCalib: failed'; then
                post_validation_warning=1
                continue
            fi
            if printf '%s\n' "$line" | grep -q 'autoCalib: failed' &&
                ! printf '%s\n' "$line" | grep -q 'calibration route context changed during measurement'; then
                unexpected_failure=1
                break
            fi
        done <<< "$MATCHED_LINES"
    fi
    if (( router_start_failed == 1 ||
          action_invalid == 1 ||
          action_too_late == 1 ||
          stale_apply_seen == 1 ||
          unexpected_failure == 1 )); then
        break
    fi
    if (( action_after_event_seen == 1 &&
          route_change_seen == 1 &&
          recovery_event_seen == 1 &&
          recovery_applied == 1 )); then
        if (( post_scheduled == 0 || post_finished == 1 )); then
            break
        fi
    fi
    sleep 3
done

printf '%s\n' "$SUMMARY_LOG" | sed '/^$/d'

echo
if (( router_start_failed == 1 )); then
    echo "BLOCKED: SyncCast could not start its capture/router backend." >&2
    if (( router_no_display == 1 )); then
        echo "         ScreenCaptureKit reported no display available. Wake/unlock the display, or use the non-SCK Direct Stereo / Process Tap path for this class of test." >&2
    fi
    exit 3
fi
if (( action_invalid == 1 )); then
    echo "FAIL: scripted action was invalid or did not match a device." >&2
    exit 2
fi
if (( action_too_late == 1 )); then
    echo "FAIL: the first calibration applied before the scripted action; reduce the action delay." >&2
    exit 2
fi
if (( stale_apply_seen == 1 )); then
    echo "FAIL: stale calibration result applied after the route mutation." >&2
    exit 2
fi
if (( unexpected_failure == 1 )); then
    echo "FAIL: observed an unexpected calibration failure." >&2
    exit 2
fi
if (( event_running_seen == 0 || action_seen == 0 || action_after_event_seen == 0 )); then
    echo "FAIL: did not observe a scripted action during an in-flight calibration run." >&2
    exit 2
fi
if (( route_context_failure_seen == 0 )); then
    echo "FAIL: did not observe route-revision fail-closed behavior." >&2
    exit 2
fi
if (( route_restore_skipped_seen == 0 )); then
    echo "WARN: did not observe routing-restore-skip log; route-context failure still proved stale result rejection."
fi
if (( deferred_seen == 0 )); then
    echo "FAIL: did not observe the mutation being deferred while calibration was running." >&2
    exit 2
fi
if (( recovery_event_seen == 0 || recovery_applied == 0 )); then
    echo "FAIL: route-change abort did not recover with a trusted follow-up calibration." >&2
    exit 2
fi
if (( mic_ready_seen == 0 || probe_anchor_seen == 0 )); then
    echo "FAIL: trusted recovery completed without observing mic-ready-gated probe logs." >&2
    echo "      Expected both 'mic_ready first_host=' and 'probe_anchor=' before accepting acoustic evidence." >&2
    exit 2
fi
if [[ "$CAPTURE_BACKEND" == "tap" && "$tap_audio_seen" != "1" ]]; then
    echo "BLOCKED: route-interrupt behavior passed, but Process Tap did not produce nonzero callback diagnostics." >&2
    echo "         Keep this as a control-loop result only; Tap-backed AirPlay calibration is not proven." >&2
    exit 3
fi

echo "PASS: mid-calibration route change failed closed, then recovered with a trusted apply."
if (( post_validation_warning == 1 )); then
    echo "WARN: post-apply validation reported an acoustic-confidence failure after the trusted recovery apply."
fi
printf 'Current airplayDelayMs: '
defaults read "$DOMAIN" "$DELAY_KEY" 2>/dev/null || true

if (( DRIFT_CYCLES > 0 )); then
    echo
    if (( DRIFT_SETTLE > 0 )); then
        echo "Waiting ${DRIFT_SETTLE}s for post-recovery transport settle..."
        sleep "$DRIFT_SETTLE"
    fi
    echo "Running no-apply drift validation..."
    bash "$SCRIPT_DIR/drift_test.sh" "$DRIFT_CYCLES" "$DRIFT_INTERVAL"
fi
