#!/usr/bin/env bash
# Verify event-driven Auto Calibrate after a scripted route mutation.
#
# This starts SyncCast in whole-home mode, toggles the requested local/AirPlay
# targets, waits for an initial trusted calibration, then executes a dev-only
# `SYNCAST_AUTO_TEST_ACTIONS` mutation such as an AirPlay volume change. It
# requires a new event-driven calibration after that mutation and can run a
# no-apply drift validation afterward.
#
# Usage:
#   bash scripts/event_mutation_test.sh [targets] [actions] [timeout_sec] [drift_cycles] [drift_interval_sec]
#
# Example:
#   bash scripts/event_mutation_test.sh display,xiaomi volume:xiaomi:0.70:260 900 3 60
#   bash scripts/event_mutation_test.sh display,xiaomi mute:xiaomi:on:260,mute:xiaomi:off:340 1000 3 60
#
# Active acoustic lab harness: can emit audible/high-band probes. Require
# SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST=1 plus a fresh session token file to avoid
# accidental runs from stale launchctl environment.

set -euo pipefail

TARGETS="${1:-display,xiaomi}"
ACTIONS="${2:-volume:xiaomi:0.70:260}"
TIMEOUT="${3:-900}"
DRIFT_CYCLES="${4:-3}"
DRIFT_INTERVAL="${5:-60}"
DRIFT_SETTLE="${SYNCAST_DRIFT_SETTLE_SEC:-20}"
CONFIRM_AUDIBLE_PROBE_TEST="${SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST:-0}"
ACTIVE_PROBE_SESSION_FILE="${SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE:-/private/tmp/syncast-active-probe-$(id -u).allow}"
ACTIVE_PROBE_SESSION_TOKEN="syncast-active-probe-$$-${RANDOM:-0}-$(date +%s)"

parse_action_bool() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on|mute|muted|enable|enabled)
            printf '1'
            ;;
        0|false|no|off|unmute|unmuted|disable|disabled)
            printf '0'
            ;;
        *)
            printf 'unknown'
            ;;
    esac
}

action_makes_route_inaudible() {
    local spec="$1"
    local verb target value delay
    IFS=':' read -r verb target value delay <<< "$spec"
    verb="$(printf '%s' "$verb" | tr '[:upper:]' '[:lower:]')"
    case "$verb" in
        mute)
            [[ "$(parse_action_bool "$value")" == "1" ]] && printf '1' || printf '0'
            ;;
        disable)
            printf '1'
            ;;
        enable)
            printf '0'
            ;;
        volume)
            if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
                awk -v v="$value" 'BEGIN { exit !((v + 0) <= 0.01) }'; then
                printf '1'
            else
                printf '0'
            fi
            ;;
        *)
            printf '0'
            ;;
    esac
}

IFS=',' read -r -a ACTION_SPECS <<< "$ACTIONS"
ACTION_COUNT=0
ACTION_INAUDIBLE=(0)
for action in "${ACTION_SPECS[@]}"; do
    trimmed="${action//[[:space:]]/}"
    if [[ -n "$trimmed" ]]; then
        ACTION_COUNT=$((ACTION_COUNT + 1))
        ACTION_INAUDIBLE[$ACTION_COUNT]="$(action_makes_route_inaudible "$trimmed")"
    fi
done

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
                defaults write "$DOMAIN" "$key" "$value"
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
OLD_ENV_AUTO_TEST_ACTIONS="$(read_launch_env SYNCAST_AUTO_TEST_ACTIONS)"
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
        restore_launch_env SYNCAST_AUTO_TEST_ACTIONS "$OLD_ENV_AUTO_TEST_ACTIONS"
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
launchctl setenv SYNCAST_AUTO_TEST_ACTIONS "$ACTIONS"
launchctl setenv SYNCAST_ENABLE_ACTIVE_CALIBRATION 1
launchctl setenv SYNCAST_ALLOW_AUDIBLE_PROBES 1
launchctl setenv SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST 1
printf '%s\n' "$ACTIVE_PROBE_SESSION_TOKEN" > "$ACTIVE_PROBE_SESSION_FILE"
chmod 600 "$ACTIVE_PROBE_SESSION_FILE" >/dev/null 2>&1 || true
launchctl setenv SYNCAST_ACTIVE_PROBE_LAB_SESSION "$ACTIVE_PROBE_SESSION_TOKEN"
launchctl setenv SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE "$ACTIVE_PROBE_SESSION_FILE"
open "$APP"

echo "event_mutation_test starting"
echo "  targets : $TARGETS"
echo "  actions : $ACTIONS"
echo "  timeout : ${TIMEOUT}s"
echo "  drift   : ${DRIFT_CYCLES} cycles @ ${DRIFT_INTERVAL}s"
echo "  log     : $LOG"
echo "  socket  : $SOCKET"
printf '%s\n' "$SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT"
echo

deadline=$((SECONDS + TIMEOUT))
read_offset="$START_OFFSET"
initial_applied=0
mutation_seen=0
action_seen_count=0
mutation_event_seen=0
mutation_applied=0
mutation_post_scheduled=0
mutation_post_finished=0
router_start_failed=0
fatal_failure_seen=0
recovery_failure_seen=0
route_intentionally_inaudible=0
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
            | grep -E 'AUTO_TEST_ACTION|reconcile: router.start FAILED|autoCalib event|autoCalib post-apply validation|autoCalib:|ActiveCalib] DONE|mic_ready first_host=|probe_anchor=|airplayDelay applied|bgCalib:' \
            || true
    )"
    if [[ -n "$MATCHED_LINES" ]]; then
        SUMMARY_LOG+="${MATCHED_LINES}"$'\n'
    fi

    if [[ -n "$MATCHED_LINES" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$line" == *"reconcile: router.start FAILED:"* ]]; then
                router_start_failed=1
                break
            fi
            if [[ "$line" == *"mic_ready first_host="* ]]; then
                mic_ready_seen=1
                continue
            fi
            if [[ "$line" == *"probe_anchor="* ]]; then
                probe_anchor_seen=1
                continue
            fi
            if [[ "$line" == *"AUTO_TEST_ACTION:"* ]]; then
                if printf '%s\n' "$line" | grep -Eq 'invalid|unknown verb|no device matched'; then
                    fatal_failure_seen=1
                    break
                fi
                if ! printf '%s\n' "$line" | grep -Eq 'setting volume|setting mute|enabling|disabling'; then
                    continue
                fi
                action_seen_count=$((action_seen_count + 1))
                mutation_seen=1
                if (( action_seen_count > ACTION_COUNT )); then
                    action_seen_count="$ACTION_COUNT"
                fi
                route_intentionally_inaudible="${ACTION_INAUDIBLE[$action_seen_count]:-0}"
                mutation_event_seen=0
                mutation_applied=0
                mutation_post_scheduled=0
                mutation_post_finished=0
                continue
            fi
            if printf '%s\n' "$line" | grep -Eq 'autoCalib: failed|autoCalib event .*aborted|airplayDelay auto-apply aborted'; then
                if (( action_seen_count == 0 )); then
                    fatal_failure_seen=1
                    break
                fi
                if (( route_intentionally_inaudible == 0 )); then
                    fatal_failure_seen=1
                    break
                fi
                recovery_failure_seen=1
                continue
            fi
            if printf '%s\n' "$line" | grep -Eq 'autoCalib: applied'; then
                if (( action_seen_count == 0 )); then
                    initial_applied=1
                elif (( mutation_seen == 1 )); then
                    mutation_applied=1
                fi
                continue
            fi
            if (( mutation_seen == 1 )) &&
                printf '%s\n' "$line" | grep -Eq 'autoCalib event running reason=volume changed|autoCalib event running reason=mute toggled|autoCalib event running reason=mute changed|autoCalib event running reason=device toggled'; then
                mutation_event_seen=1
                continue
            fi
            if (( mutation_seen == 1 )) &&
                printf '%s\n' "$line" | grep -q 'autoCalib post-apply validation scheduled'; then
                mutation_post_scheduled=1
                continue
            fi
            if (( mutation_seen == 1 )) &&
                printf '%s\n' "$line" | grep -q 'autoCalib post-apply validation finished'; then
                mutation_post_finished=1
                continue
            fi
        done <<< "$MATCHED_LINES"
    fi
    if (( router_start_failed == 1 || fatal_failure_seen == 1 )); then
        break
    fi
    if (( initial_applied == 1 && action_seen_count >= ACTION_COUNT && route_intentionally_inaudible == 0 && mutation_event_seen == 1 && mutation_applied == 1 )); then
        if (( mutation_post_scheduled == 0 || mutation_post_finished == 1 )); then
            break
        fi
    fi
    sleep 3
done

printf '%s\n' "$SUMMARY_LOG" | sed '/^$/d'

echo
if (( router_start_failed == 1 )); then
    echo "BLOCKED: SyncCast could not start its capture/router backend." >&2
    exit 3
fi
if (( fatal_failure_seen == 1 )); then
    echo "FAIL: observed a calibration failure during event mutation test." >&2
    exit 2
fi
if (( route_intentionally_inaudible == 1 )); then
    echo "FAIL: final scripted action left the route intentionally inaudible; no trusted recovery apply is possible." >&2
    exit 2
fi
if (( initial_applied == 0 || action_seen_count < ACTION_COUNT || mutation_event_seen == 0 || mutation_applied == 0 )); then
    echo "FAIL: did not observe initial apply, mutation, mutation-triggered calibration, and trusted apply." >&2
    exit 2
fi
if (( mic_ready_seen == 0 || probe_anchor_seen == 0 )); then
    echo "FAIL: trusted mutation calibration completed without observing mic-ready-gated probe logs." >&2
    echo "      Expected both 'mic_ready first_host=' and 'probe_anchor=' before accepting acoustic evidence." >&2
    exit 2
fi

if (( recovery_failure_seen == 1 )); then
    echo "NOTE: observed fail-closed calibration after scripted mutation; final mutation recovery still passed."
fi
echo "PASS: scripted mutation triggered a trusted event-driven calibration."
printf 'Current airplayDelayMs: '
defaults read "$DOMAIN" "$DELAY_KEY" 2>/dev/null || true

if (( DRIFT_CYCLES > 0 )); then
    echo
    if (( DRIFT_SETTLE > 0 )); then
        echo "Waiting ${DRIFT_SETTLE}s for post-mutation transport settle..."
        sleep "$DRIFT_SETTLE"
    fi
    echo "Running no-apply drift validation..."
    bash "$SCRIPT_DIR/drift_test.sh" "$DRIFT_CYCLES" "$DRIFT_INTERVAL"
fi
