#!/usr/bin/env bash
# Run a full no-probe passive drift evidence session:
#   1. no-mic preflight/readiness gate
#   2. passive drift monitor over real program audio
#   3. offline summary
#   4. conservative no-write delay decision
#
# Requirements:
#   - SyncCast is already running in Whole-home mode, OR
#     SYNCAST_PASSIVE_AUTO_START_TARGETS is set to a comma-separated
#     local+AirPlay target list such as display,xiaomi.
#   - A real program audio source is playing; this script emits no sound.
#   - Microphone permission is available for the selected calibration mic.
#
# Usage:
#   bash scripts/passive_drift_session.sh [samples] [interval_sec] [duration_sec] [output_root]
#
# Optional env:
#   SYNCAST_PASSIVE_BASELINE_REPORT=/path/to/known-good-monitor.json
#   SYNCAST_PASSIVE_BASELINE_OFFSET_MS=123.4
#   SYNCAST_PASSIVE_BASELINE_STORE=/path/to/passive-baselines.json
#   SYNCAST_PASSIVE_BASELINE_MODE=auto|record|decide
#   SYNCAST_PASSIVE_BASELINE_MARK_MODE=mark|dry-run|off
#   SYNCAST_PASSIVE_CONTROL_STATE=/path/to/passive-control-state.json
#   SYNCAST_PASSIVE_MAX_REPEAT_DELTA_MS=8
#   SYNCAST_PASSIVE_MAX_PENDING_AGE_SEC=1800
#   SYNCAST_PASSIVE_SOCKET=/tmp/syncast-501.calibration.sock
#   SYNCAST_PASSIVE_AUTO_START_TARGETS=display,xiaomi
#   SYNCAST_PASSIVE_AUTO_START_TIMEOUT_SEC=90
#   SYNCAST_PASSIVE_AUTO_CAPTURE_BACKEND=tap|sck
#   SYNCAST_PASSIVE_AUTO_LAUNCH_MODE=auto|open|exec|headless
#   SYNCAST_PASSIVE_HEADLESS_BINARY=/path/to/SyncCastPassiveHeadless
#   SYNCAST_PASSIVE_HEADLESS_MIC=logitech
#   SYNCAST_PASSIVE_HEADLESS_RUN_SECONDS=7200
#   SYNCAST_PASSIVE_HEADLESS_SETTLE_SEC=auto-start-timeout-minus-3
#   SYNCAST_PASSIVE_APPLY_MODE=dry-run|off
#   SYNCAST_PASSIVE_WORKFLOW_GUARD=enforce|warn|off
#   SYNCAST_PASSIVE_READINESS_ONLY=1

set -euo pipefail

SAMPLES="${1:-6}"
INTERVAL_SEC="${2:-60}"
DURATION_SEC="${3:-4}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_ROOT="${4:-/tmp/syncast-passive-drift-$STAMP}"
SOCKET="${SYNCAST_PASSIVE_SOCKET:-/tmp/syncast-$(id -u).calibration.sock}"
MAX_DELAY_MS="${SYNCAST_PASSIVE_MAX_DELAY_MS:-3500}"
BASELINE_REPORT="${SYNCAST_PASSIVE_BASELINE_REPORT:-}"
BASELINE_OFFSET_MS="${SYNCAST_PASSIVE_BASELINE_OFFSET_MS:-}"
BASELINE_STORE="${SYNCAST_PASSIVE_BASELINE_STORE:-}"
BASELINE_MODE="${SYNCAST_PASSIVE_BASELINE_MODE:-auto}"
BASELINE_MARK_MODE="${SYNCAST_PASSIVE_BASELINE_MARK_MODE:-mark}"
CONTROL_STATE="${SYNCAST_PASSIVE_CONTROL_STATE:-}"
MAX_REPEAT_DELTA_MS="${SYNCAST_PASSIVE_MAX_REPEAT_DELTA_MS:-8}"
MAX_PENDING_AGE_SEC="${SYNCAST_PASSIVE_MAX_PENDING_AGE_SEC:-1800}"
AUTO_START_TARGETS="${SYNCAST_PASSIVE_AUTO_START_TARGETS:-}"
AUTO_START_TIMEOUT="${SYNCAST_PASSIVE_AUTO_START_TIMEOUT_SEC:-90}"
AUTO_CAPTURE_BACKEND="${SYNCAST_PASSIVE_AUTO_CAPTURE_BACKEND:-}"
AUTO_LAUNCH_MODE="${SYNCAST_PASSIVE_AUTO_LAUNCH_MODE:-auto}"
PASSIVE_APPLY_MODE="${SYNCAST_PASSIVE_APPLY_MODE:-dry-run}"
WORKFLOW_GUARD_MODE="${SYNCAST_PASSIVE_WORKFLOW_GUARD:-enforce}"
READINESS_ONLY="${SYNCAST_PASSIVE_READINESS_ONLY:-0}"

READINESS_JSON="$OUTPUT_ROOT/readiness.json"
WORKFLOW_GUARD_JSON="$OUTPUT_ROOT/workflow_guard.json"
CAPTURE_PREFLIGHT_JSON="$OUTPUT_ROOT/capture_preflight.json"
PREFLIGHT_JSON="$OUTPUT_ROOT/preflight.json"
AUTO_START_CAPTURE_PREFLIGHT_JSON="$OUTPUT_ROOT/auto_start_capture_preflight.json"
AUTO_START_PREFLIGHT_JSON="$OUTPUT_ROOT/auto_start_preflight.json"
AUTO_START_SETUP_JSON="$OUTPUT_ROOT/auto_start_setup.json"
MONITOR_JSON="$OUTPUT_ROOT/monitor.json"
SAMPLES_JSONL="$OUTPUT_ROOT/samples.jsonl"
SUMMARY_TXT="$OUTPUT_ROOT/summary.txt"
SUMMARY_JSON="$OUTPUT_ROOT/summary.json"
DECISION_JSON="$OUTPUT_ROOT/decision.json"
DECISION_ERR="$OUTPUT_ROOT/decision.stderr"
AUDIT_JSON="$OUTPUT_ROOT/audit.json"
MANIFEST_JSON="$OUTPUT_ROOT/manifest.json"
FINALIZE_JSON="$OUTPUT_ROOT/finalize.json"
FINALIZE_ERR="$OUTPUT_ROOT/finalize.stderr"
BASELINE_MARK_JSON="$OUTPUT_ROOT/passive_baseline_mark.json"
BASELINE_MARK_ERR="$OUTPUT_ROOT/passive_baseline_mark.stderr"
GATE_JSON="$OUTPUT_ROOT/correction_gate.json"
GATE_ERR="$OUTPUT_ROOT/correction_gate.stderr"
APPLY_JSON="$OUTPUT_ROOT/passive_apply.json"
APPLY_ERR="$OUTPUT_ROOT/passive_apply.stderr"
CONTROL_REPORT_JSON="$OUTPUT_ROOT/control_report.json"
CONTROL_REPORT_ERR="$OUTPUT_ROOT/control_report.stderr"
HEADLESS_STATUS_JSON="$OUTPUT_ROOT/headless_status.json"
CAPTURE_ROOT="$OUTPUT_ROOT/captures"
APP="/Applications/SyncCast.app"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HEADLESS_BINARY="${SYNCAST_PASSIVE_HEADLESS_BINARY:-$REPO_ROOT/core/router/.build/debug/SyncCastPassiveHeadless}"
HEADLESS_MIC="${SYNCAST_PASSIVE_HEADLESS_MIC:-}"
HEADLESS_RUN_SECONDS="${SYNCAST_PASSIVE_HEADLESS_RUN_SECONDS:-7200}"
if [[ -n "${SYNCAST_PASSIVE_HEADLESS_SETTLE_SEC:-}" ]]; then
  HEADLESS_SETTLE_SECONDS="$SYNCAST_PASSIVE_HEADLESS_SETTLE_SEC"
elif [[ "$AUTO_START_TIMEOUT" =~ ^[0-9]+$ ]] && (( AUTO_START_TIMEOUT > 6 )); then
  HEADLESS_SETTLE_SECONDS="$((AUTO_START_TIMEOUT - 3))"
else
  HEADLESS_SETTLE_SECONDS="$AUTO_START_TIMEOUT"
fi
source "$SCRIPT_DIR/coreaudio_default_output_guard.sh"

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

AUTO_START_ARMED=0
AUTO_START_LAUNCH_ATTEMPTED=0
AUTO_START_DID_LAUNCH=0
AUTO_START_DIRECT_PID=""
AUTO_START_LAUNCH_METHOD_USED=""
AUTO_START_LAUNCH_ENV_OK=0
AUTO_START_APP_WAS_RUNNING=0
AUTO_START_ACOUSTIC_SETUP=0
AUTO_START_DEFAULT_OUTPUT_SETUP_SKIPPED=0
OLD_ENV_INITIAL_MODE=""
OLD_ENV_AUTO_TEST=""
OLD_ENV_CAPTURE_BACKEND=""
OLD_ENV_ACTIVE_CALIBRATION=""
OLD_ENV_AUDIBLE_PROBES=""

update_manifest_auto_start_side_effects() {
  [[ -f "$MANIFEST_JSON" ]] || return 0
  PYTHONPATH=scripts python3 -c '
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text())
except Exception:
    sys.exit(0)
if not isinstance(payload, dict):
    sys.exit(0)

def flag(index: int) -> bool:
    return sys.argv[index] == "1"

requested_method = sys.argv[9] or ""
used_method = sys.argv[10] or ""
headless = requested_method == "headless" or used_method == "headless"
payload["launchesApp"] = not headless
payload["launchesHeadlessRuntime"] = headless
payload["appLaunchAttempted"] = flag(8)
payload["appLaunched"] = flag(2) and not headless
payload["headlessRuntimeLaunched"] = flag(2) and headless
payload["launchMethodRequested"] = requested_method or None
payload["launchMethodUsed"] = used_method or None
payload["launchEnvironmentApplied"] = False if headless else flag(11)
payload["appWasRunningBeforeAutoStart"] = flag(3)
payload["changesRoutes"] = True
payload["changesLaunchEnvironment"] = False if headless else True
payload["mayChangeDefaultOutput"] = True
payload["defaultOutputSetupSkipped"] = flag(12)
payload["changesDefaultOutput"] = False if flag(12) else flag(5)
payload["defaultOutputReadFailed"] = False if flag(12) else flag(7)
payload["defaultOutputVerified"] = False if flag(12) else not flag(7)
report = sys.argv[6]
payload["defaultOutputReport"] = report or None
payload["autoStartSideEffectsUpdated"] = True
payload["autoStartAcousticSetupCompleted"] = flag(4)
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
' "$MANIFEST_JSON" \
    "$AUTO_START_DID_LAUNCH" \
    "$AUTO_START_APP_WAS_RUNNING" \
    "$AUTO_START_ACOUSTIC_SETUP" \
    "${SYNCAST_ACOUSTIC_DEFAULT_CHANGED:-0}" \
    "${SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT:-}" \
    "${SYNCAST_ACOUSTIC_DEFAULT_READ_FAILED:-0}" \
    "$AUTO_START_LAUNCH_ATTEMPTED" \
    "$AUTO_LAUNCH_MODE" \
    "$AUTO_START_LAUNCH_METHOD_USED" \
    "$AUTO_START_LAUNCH_ENV_OK" \
    "$AUTO_START_DEFAULT_OUTPUT_SETUP_SKIPPED" || true
}

write_auto_start_setup_artifact() {
  local verdict="$1"
  local reason="$2"
  PYTHONPATH=scripts python3 -c '
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
stdout_path = path.parent / "syncast_direct_launch.stdout"
stderr_path = path.parent / "syncast_direct_launch.stderr"
headless_stdout_path = path.parent / "syncast_headless_launch.stdout"
headless_stderr_path = path.parent / "syncast_headless_launch.stderr"
headless_status_path = path.parent / "headless_status.json"
def tail(path: Path, limit: int = 4000):
    if not path.exists():
        return None
    text = path.read_text(errors="replace")
    return text[-limit:]

requested_method = sys.argv[13] or ""
used_method = sys.argv[14] or ""
headless = requested_method == "headless" or used_method == "headless"
payload = {
    "schema": "syncast.passive_auto_start_setup.v1",
    "createdUnix": round(time.time(), 3),
    "verdict": sys.argv[2],
    "reason": sys.argv[3] or None,
    "autoStartTargets": sys.argv[4] or None,
    "autoCaptureBackend": sys.argv[5] or None,
    "launchesApp": not headless,
    "launchesHeadlessRuntime": headless,
    "appLaunchAttempted": sys.argv[7] == "1",
    "appLaunched": (sys.argv[8] == "1") and not headless,
    "headlessRuntimeLaunched": (sys.argv[8] == "1") and headless,
    "appWasRunningBeforeAutoStart": sys.argv[9] == "1",
    "launchMethodRequested": requested_method or None,
    "launchMethodUsed": used_method or None,
    "launchEnvironmentApplied": False if headless else sys.argv[15] == "1",
    "changesRoutes": True,
    "changesLaunchEnvironment": False if headless else True,
    "mayChangeDefaultOutput": True,
    "defaultOutputSetupSkipped": sys.argv[16] == "1",
    "changesDefaultOutput": False if sys.argv[16] == "1" else sys.argv[10] == "1",
    "defaultOutputReport": sys.argv[11] or None,
    "defaultOutputReadFailed": False if sys.argv[16] == "1" else sys.argv[12] == "1",
    "defaultOutputVerified": False if sys.argv[16] == "1" else sys.argv[12] != "1",
    "directLaunchStdout": str(stdout_path) if stdout_path.exists() else None,
    "directLaunchStderr": str(stderr_path) if stderr_path.exists() else None,
    "directLaunchStdoutTail": tail(stdout_path),
    "directLaunchStderrTail": tail(stderr_path),
    "headlessLaunchStdout": str(headless_stdout_path) if headless_stdout_path.exists() else None,
    "headlessLaunchStderr": str(headless_stderr_path) if headless_stderr_path.exists() else None,
    "headlessLaunchStdoutTail": tail(headless_stdout_path),
    "headlessLaunchStderrTail": tail(headless_stderr_path),
    "headlessStatus": str(headless_status_path) if headless_status_path.exists() else None,
    "headlessStatusJson": headless_status_path.exists(),
    "emitsAudio": False,
    "appliesDelay": False,
    "opensMicrophone": False,
}
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
' "$AUTO_START_SETUP_JSON" \
    "$verdict" \
    "$reason" \
    "$AUTO_START_TARGETS" \
    "$AUTO_CAPTURE_BACKEND" \
    "1" \
    "$AUTO_START_LAUNCH_ATTEMPTED" \
    "$AUTO_START_DID_LAUNCH" \
    "$AUTO_START_APP_WAS_RUNNING" \
    "${SYNCAST_ACOUSTIC_DEFAULT_CHANGED:-0}" \
    "${SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT:-}" \
    "${SYNCAST_ACOUSTIC_DEFAULT_READ_FAILED:-0}" \
    "$AUTO_LAUNCH_MODE" \
    "$AUTO_START_LAUNCH_METHOD_USED" \
    "$AUTO_START_LAUNCH_ENV_OK" \
    "$AUTO_START_DEFAULT_OUTPUT_SETUP_SKIPPED"
}

set_open_launch_environment() {
  local rc=0
  launchctl setenv SYNCAST_INITIAL_MODE wholehome >/dev/null 2>&1 || rc=1
  launchctl setenv SYNCAST_AUTO_TEST "$AUTO_START_TARGETS" >/dev/null 2>&1 || rc=1
  if [[ -n "$AUTO_CAPTURE_BACKEND" ]]; then
    launchctl setenv SYNCAST_CAPTURE_BACKEND "$AUTO_CAPTURE_BACKEND" >/dev/null 2>&1 || rc=1
  fi
  launchctl unsetenv SYNCAST_ENABLE_ACTIVE_CALIBRATION >/dev/null 2>&1 || true
  launchctl unsetenv SYNCAST_ALLOW_AUDIBLE_PROBES >/dev/null 2>&1 || true
  launchctl unsetenv SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST >/dev/null 2>&1 || true
  launchctl unsetenv SYNCAST_ACTIVE_PROBE_LAB_SESSION >/dev/null 2>&1 || true
  launchctl unsetenv SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE >/dev/null 2>&1 || true
  if [[ "$rc" -eq 0 ]]; then
    AUTO_START_LAUNCH_ENV_OK=1
  else
    AUTO_START_LAUNCH_ENV_OK=0
  fi
  return "$rc"
}

launch_syncast_with_open() {
  local env_rc open_rc
  AUTO_START_LAUNCH_METHOD_USED="open"
  set +e
  set_open_launch_environment
  env_rc=$?
  if [[ "$env_rc" -eq 0 ]]; then
    open "$APP"
    open_rc=$?
  else
    open_rc=1
  fi
  set -e
  if [[ "$env_rc" -ne 0 ]]; then
    return 11
  fi
  return "$open_rc"
}

launch_syncast_with_exec() {
  local executable="$APP/Contents/MacOS/SyncCastMenuBar"
  if [[ ! -x "$executable" ]]; then
    return 127
  fi
  AUTO_START_LAUNCH_METHOD_USED="exec"
  AUTO_START_LAUNCH_ENV_OK=1
  mkdir -p "$OUTPUT_ROOT"
  (
    export SYNCAST_INITIAL_MODE=wholehome
    export SYNCAST_AUTO_TEST="$AUTO_START_TARGETS"
    if [[ -n "$AUTO_CAPTURE_BACKEND" ]]; then
      export SYNCAST_CAPTURE_BACKEND="$AUTO_CAPTURE_BACKEND"
    else
      unset SYNCAST_CAPTURE_BACKEND
    fi
    unset SYNCAST_ENABLE_ACTIVE_CALIBRATION
    unset SYNCAST_ALLOW_AUDIBLE_PROBES
    unset SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST
    unset SYNCAST_ACTIVE_PROBE_LAB_SESSION
    unset SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE
    cd "$APP/Contents/MacOS" || exit 1
    exec "$executable"
  ) > "$OUTPUT_ROOT/syncast_direct_launch.stdout" \
    2> "$OUTPUT_ROOT/syncast_direct_launch.stderr" &
  AUTO_START_DIRECT_PID=$!
  sleep 1
  if ! kill -0 "$AUTO_START_DIRECT_PID" >/dev/null 2>&1; then
    return 12
  fi
  return 0
}

ensure_headless_binary() {
  if [[ -x "$HEADLESS_BINARY" ]]; then
    return 0
  fi
  swift build --package-path "$REPO_ROOT/core/router" \
    --product SyncCastPassiveHeadless >/dev/null
}

launch_syncast_with_headless() {
  AUTO_START_LAUNCH_METHOD_USED="headless"
  AUTO_START_LAUNCH_ENV_OK=1
  mkdir -p "$OUTPUT_ROOT"
  ensure_headless_binary || return $?
  if [[ ! -x "$HEADLESS_BINARY" ]]; then
    return 127
  fi
  (
    export SYNCAST_HEADLESS_TARGETS="$AUTO_START_TARGETS"
    export SYNCAST_HEADLESS_SOCKET="$SOCKET"
    export SYNCAST_HEADLESS_RUN_SECONDS="$HEADLESS_RUN_SECONDS"
    export SYNCAST_HEADLESS_SETTLE_SECONDS="$HEADLESS_SETTLE_SECONDS"
    export SYNCAST_HEADLESS_STATUS_PATH="$HEADLESS_STATUS_JSON"
    if [[ -n "$HEADLESS_MIC" ]]; then
      export SYNCAST_HEADLESS_MIC="$HEADLESS_MIC"
    else
      unset SYNCAST_HEADLESS_MIC
    fi
    if [[ -n "$AUTO_CAPTURE_BACKEND" ]]; then
      export SYNCAST_CAPTURE_BACKEND="$AUTO_CAPTURE_BACKEND"
    else
      unset SYNCAST_CAPTURE_BACKEND
    fi
    unset SYNCAST_ENABLE_ACTIVE_CALIBRATION
    unset SYNCAST_ALLOW_AUDIBLE_PROBES
    unset SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST
    unset SYNCAST_ACTIVE_PROBE_LAB_SESSION
    unset SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE
    exec "$HEADLESS_BINARY"
  ) > "$OUTPUT_ROOT/syncast_headless_launch.stdout" \
    2> "$OUTPUT_ROOT/syncast_headless_launch.stderr" &
  AUTO_START_DIRECT_PID=$!
  sleep 1
  if ! kill -0 "$AUTO_START_DIRECT_PID" >/dev/null 2>&1; then
    return 12
  fi
  return 0
}

launch_syncast_for_auto_start() {
  local rc
  AUTO_START_LAUNCH_ATTEMPTED=1
  case "$AUTO_LAUNCH_MODE" in
    open)
      launch_syncast_with_open
      return $?
      ;;
    exec)
      launch_syncast_with_exec
      return $?
      ;;
    headless)
      launch_syncast_with_headless
      return $?
      ;;
    auto)
      launch_syncast_with_open
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        return 0
      fi
      launch_syncast_with_exec
      return $?
      ;;
  esac
  return 2
}

cleanup_auto_start() {
  local status=$?
  if (( AUTO_START_ARMED == 1 )); then
    restore_launch_env SYNCAST_INITIAL_MODE "$OLD_ENV_INITIAL_MODE"
    restore_launch_env SYNCAST_AUTO_TEST "$OLD_ENV_AUTO_TEST"
    restore_launch_env SYNCAST_CAPTURE_BACKEND "$OLD_ENV_CAPTURE_BACKEND"
    restore_launch_env SYNCAST_ENABLE_ACTIVE_CALIBRATION "$OLD_ENV_ACTIVE_CALIBRATION"
    restore_launch_env SYNCAST_ALLOW_AUDIBLE_PROBES "$OLD_ENV_AUDIBLE_PROBES"
    restore_launch_env SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST "$OLD_ENV_AUDIBLE_CONFIRM"
    restore_launch_env SYNCAST_ACTIVE_PROBE_LAB_SESSION "$OLD_ENV_ACTIVE_PROBE_SESSION"
    restore_launch_env SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE "$OLD_ENV_ACTIVE_PROBE_SESSION_FILE"
    if (( AUTO_START_DID_LAUNCH == 1 )); then
      if [[ -n "$AUTO_START_DIRECT_PID" ]]; then
        kill "$AUTO_START_DIRECT_PID" >/dev/null 2>&1 || true
      fi
      quit_syncast || true
    fi
    if (( AUTO_START_ACOUSTIC_SETUP == 1 )); then
      syncast_restore_acoustic_default_output || true
    fi
    syncast_cleanup_coreaudio_default_output_probe
    if (( AUTO_START_APP_WAS_RUNNING == 1 )); then
      open "$APP" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}

run_auto_start_preflight_pair() {
  local capture_preflight_rc preflight_rc
  set +e
  PYTHONPATH=scripts python3 scripts/passive_capture_estimate.py \
    --socket "$SOCKET" \
    --preflight-only \
    --cycles 3 \
    --duration-sec "$DURATION_SEC" \
    --max-delay-ms "$MAX_DELAY_MS" \
    --report-path "$AUTO_START_CAPTURE_PREFLIGHT_JSON" \
    > /dev/null 2>&1
  capture_preflight_rc=$?
  PYTHONPATH=scripts python3 scripts/passive_drift_monitor.py \
    --socket "$SOCKET" \
    --preflight-only \
    --samples "$SAMPLES" \
    --cycles 3 \
    --duration-sec "$DURATION_SEC" \
    --max-delay-ms "$MAX_DELAY_MS" \
    --report-path "$AUTO_START_PREFLIGHT_JSON" \
    > /dev/null 2>&1
  preflight_rc=$?
  set -e
  if [[ "$capture_preflight_rc" -eq 0 && "$preflight_rc" -eq 0 ]]; then
    return 0
  fi
  return 1
}

wait_for_auto_start_preflight() {
  local readiness_rc pair_rc
  local readiness_process="SyncCastMenuBar"
  local readiness_app="$APP"
  if [[ "$AUTO_START_LAUNCH_METHOD_USED" == "headless" ]]; then
    readiness_process="SyncCastPassiveHeadless"
    readiness_app="$HEADLESS_BINARY"
  fi
  set +e
  PYTHONPATH=scripts python3 scripts/passive_readiness_report.py \
    --socket "$SOCKET" \
    --app "$readiness_app" \
    --process-name "$readiness_process" \
    --wait-sec "$AUTO_START_TIMEOUT" \
    --interval-sec 3 \
    --output "$READINESS_JSON" \
    > /dev/null 2>&1
  readiness_rc=$?
  set -e
  set +e
  run_auto_start_preflight_pair
  pair_rc=$?
  set -e
  if [[ "$readiness_rc" -eq 0 && "$pair_rc" -eq 0 ]]; then
    return 0
  fi
  echo "ERROR: passive auto-start did not reach ready preflight within ${AUTO_START_TIMEOUT}s." >&2
  echo "       Readiness artifact         : $READINESS_JSON" >&2
  echo "       Last capture preflight artifact: $AUTO_START_CAPTURE_PREFLIGHT_JSON" >&2
  echo "       Last drift preflight artifact  : $AUTO_START_PREFLIGHT_JSON" >&2
  return 2
}

prepare_auto_start_if_requested() {
  [[ -n "$AUTO_START_TARGETS" ]] || return 0
  if [[ ! "$AUTO_START_TIMEOUT" =~ ^[0-9]+$ ]] || (( AUTO_START_TIMEOUT < 15 )); then
    echo "ERROR: SYNCAST_PASSIVE_AUTO_START_TIMEOUT_SEC must be an integer >= 15" >&2
    exit 2
  fi
  case "$AUTO_CAPTURE_BACKEND" in
    ""|tap|sck) ;;
    *)
      echo "ERROR: SYNCAST_PASSIVE_AUTO_CAPTURE_BACKEND must be tap, sck, or empty" >&2
      exit 2
      ;;
  esac
  case "$AUTO_LAUNCH_MODE" in
    auto|open|exec|headless) ;;
    *)
      echo "ERROR: SYNCAST_PASSIVE_AUTO_LAUNCH_MODE must be auto, open, exec, or headless" >&2
      exit 2
      ;;
  esac
  if [[ "$AUTO_LAUNCH_MODE" != "headless" && ! -d "$APP" ]]; then
    echo "ERROR: $APP not found; install SyncCast first." >&2
    exit 2
  fi
  AUTO_START_ARMED=1
  trap cleanup_auto_start EXIT
  OLD_ENV_INITIAL_MODE="$(read_launch_env SYNCAST_INITIAL_MODE)"
  OLD_ENV_AUTO_TEST="$(read_launch_env SYNCAST_AUTO_TEST)"
  OLD_ENV_CAPTURE_BACKEND="$(read_launch_env SYNCAST_CAPTURE_BACKEND)"
  OLD_ENV_ACTIVE_CALIBRATION="$(read_launch_env SYNCAST_ENABLE_ACTIVE_CALIBRATION)"
  OLD_ENV_AUDIBLE_PROBES="$(read_launch_env SYNCAST_ALLOW_AUDIBLE_PROBES)"
  OLD_ENV_AUDIBLE_CONFIRM="$(read_launch_env SYNCAST_CONFIRM_AUDIBLE_PROBE_TEST)"
  OLD_ENV_ACTIVE_PROBE_SESSION="$(read_launch_env SYNCAST_ACTIVE_PROBE_LAB_SESSION)"
  OLD_ENV_ACTIVE_PROBE_SESSION_FILE="$(read_launch_env SYNCAST_ACTIVE_PROBE_LAB_SESSION_FILE)"
  if pgrep -x SyncCastMenuBar >/dev/null 2>&1; then
    AUTO_START_APP_WAS_RUNNING=1
  fi
  if ! quit_syncast; then
    echo "ERROR: SyncCast did not quit cleanly before passive auto-start." >&2
    return 2
  fi
  local prepare_rc=0
  if [[ "$READINESS_ONLY" == "1" ]]; then
    AUTO_START_DEFAULT_OUTPUT_SETUP_SKIPPED=1
    export SYNCAST_ACOUSTIC_DEFAULT_CHANGED=0
    export SYNCAST_ACOUSTIC_DEFAULT_READ_FAILED=0
    export SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT="  default-output-setup: skipped for readiness-only bootstrap"
  else
    set +e
    syncast_prepare_ordinary_default_output_for_acoustic_test "$AUTO_START_TARGETS"
    prepare_rc=$?
    set -e
    if [[ "$prepare_rc" -ne 0 ]]; then
      update_manifest_auto_start_side_effects
      write_auto_start_setup_artifact \
        "capture_failed" \
        "CoreAudio default-output setup failed before launching SyncCast"
      return "$prepare_rc"
    fi
    AUTO_START_ACOUSTIC_SETUP=1
  fi
  update_manifest_auto_start_side_effects
  write_auto_start_setup_artifact "preflight_ok" ""
  rm -f "$SOCKET"
  local launch_rc
  set +e
  launch_syncast_for_auto_start
  launch_rc=$?
  set -e
  if [[ "$launch_rc" -ne 0 ]]; then
    update_manifest_auto_start_side_effects
    write_auto_start_setup_artifact \
      "capture_failed" \
      "failed to launch SyncCast before passive readiness"
    return "$launch_rc"
  fi
  AUTO_START_DID_LAUNCH=1
  update_manifest_auto_start_side_effects
  write_auto_start_setup_artifact "preflight_ok" ""
  echo "Passive auto-start"
  echo "  targets     : $AUTO_START_TARGETS"
  echo "  timeout_sec : $AUTO_START_TIMEOUT"
  echo "  active tones: disabled"
  if [[ -n "$AUTO_CAPTURE_BACKEND" ]]; then
    echo "  capture     : $AUTO_CAPTURE_BACKEND"
  fi
  echo "  launch      : $AUTO_START_LAUNCH_METHOD_USED"
  printf '%s\n' "$SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT"
  echo
  wait_for_auto_start_preflight
}

run_control_report() {
  local report_rc
  set +e
  PYTHONPATH=scripts python3 scripts/passive_control_report.py "$OUTPUT_ROOT" \
    --output "$CONTROL_REPORT_JSON" \
    > /dev/null 2> "$CONTROL_REPORT_ERR"
  report_rc=$?
  set -e
  echo "Control report JSON: $CONTROL_REPORT_JSON"
  case "$report_rc" in
    0)
      echo "Control report verdict: usable no-write passive control state"
      ;;
    4)
      echo "Control report verdict: capture failed before usable evidence"
      ;;
    *)
      echo "Control report verdict: not ready for passive control (exit $report_rc)"
      ;;
  esac
  return "$report_rc"
}

exit_with_control_report() {
  local primary_rc="$1"
  local report_rc
  set +e
  run_control_report
  report_rc=$?
  set -e
  if [[ "$primary_rc" -eq 0 && "$report_rc" -ne 0 ]]; then
    exit "$report_rc"
  fi
  exit "$primary_rc"
}

write_readiness_report() {
  local readiness_rc
  local readiness_process="SyncCastMenuBar"
  local readiness_app="$APP"
  if [[ "$AUTO_START_LAUNCH_METHOD_USED" == "headless" ]]; then
    readiness_process="SyncCastPassiveHeadless"
    readiness_app="$HEADLESS_BINARY"
  fi
  set +e
  PYTHONPATH=scripts python3 scripts/passive_readiness_report.py \
    --socket "$SOCKET" \
    --app "$readiness_app" \
    --process-name "$readiness_process" \
    --output "$READINESS_JSON" \
    > /dev/null 2>&1
  readiness_rc=$?
  set -e
  return 0
}

run_workflow_guard() {
  local guard_rc
  set +e
  PYTHONPATH=scripts python3 scripts/passive_workflow_guard.py "$READINESS_JSON" \
    --baseline-store "$BASELINE_STORE" \
    --baseline-report "$BASELINE_REPORT" \
    --baseline-offset-ms "$BASELINE_OFFSET_MS" \
    --baseline-mode "$BASELINE_MODE" \
    --control-state "$CONTROL_STATE" \
    --passive-apply-mode "$PASSIVE_APPLY_MODE" \
    --mode "$WORKFLOW_GUARD_MODE" \
    --output "$WORKFLOW_GUARD_JSON" \
    > /dev/null 2>&1
  guard_rc=$?
  set -e
  echo "Workflow guard JSON: $WORKFLOW_GUARD_JSON"
  case "$guard_rc" in
    0)
      echo "Workflow guard verdict: allowed or warning"
      ;;
    3)
      echo "Workflow guard verdict: blocked before microphone access"
      ;;
    *)
      echo "Workflow guard verdict: failed to evaluate workflow guard (exit $guard_rc)"
      ;;
  esac
  return "$guard_rc"
}

run_passive_apply_dry_run() {
  [[ "$PASSIVE_APPLY_MODE" == "dry-run" ]] || return 0
  local apply_rc
  set +e
  PYTHONPATH=scripts python3 scripts/passive_apply_candidate.py "$OUTPUT_ROOT" \
    --socket "$SOCKET" \
    --output "$APPLY_JSON" \
    > /dev/null 2> "$APPLY_ERR"
  apply_rc=$?
  set -e
  echo "Passive apply JSON: $APPLY_JSON"
  case "$apply_rc" in
    0)
      echo "Passive apply verdict: app-side dry-run accepted candidate"
      ;;
    3)
      echo "Passive apply verdict: app-side dry-run rejected candidate (exit $apply_rc)"
      ;;
    *)
      echo "Passive apply verdict: failed to evaluate app-side dry-run (exit $apply_rc)"
      ;;
  esac
  return "$apply_rc"
}

run_passive_baseline_mark() {
  [[ "$BASELINE_MARK_MODE" != "off" ]] || return 0
  local args=()
  if [[ "$BASELINE_MARK_MODE" == "dry-run" ]]; then
    args+=("--dry-run")
  fi
  local mark_rc
  set +e
  PYTHONPATH=scripts python3 scripts/passive_mark_baseline_valid.py "$OUTPUT_ROOT" \
    --socket "$SOCKET" \
    --output "$BASELINE_MARK_JSON" \
    "${args[@]}" \
    > /dev/null 2> "$BASELINE_MARK_ERR"
  mark_rc=$?
  set -e
  echo "Baseline mark JSON: $BASELINE_MARK_JSON"
  case "$mark_rc" in
    0)
      if [[ "$BASELINE_MARK_MODE" == "dry-run" ]]; then
        echo "Baseline mark verdict: app-side dry-run accepted baseline context"
      else
        echo "Baseline mark verdict: app sync context marked valid"
      fi
      ;;
    3)
      echo "Baseline mark verdict: app-side runtime guard rejected baseline mark (exit $mark_rc)"
      ;;
    *)
      echo "Baseline mark verdict: failed to evaluate baseline mark (exit $mark_rc)"
      ;;
  esac
  return "$mark_rc"
}

run_audit_and_exit() {
  set +e
  PYTHONPATH=scripts python3 scripts/passive_session_audit.py "$OUTPUT_ROOT" > "$AUDIT_JSON"
  local audit_rc=$?
  set -e
  echo "Audit JSON   : $AUDIT_JSON"
  case "$audit_rc" in
    0)
      echo "Audit verdict: usable passive session"
      ;;
    4)
      echo "Audit verdict: capture failed before usable evidence"
      ;;
    *)
      echo "Audit verdict: not ready for passive control (exit $audit_rc)"
      ;;
  esac
  if [[ "$audit_rc" -eq 0 && -n "$BASELINE_STORE" ]]; then
    set +e
    PYTHONPATH=scripts python3 scripts/passive_session_finalize.py "$OUTPUT_ROOT" \
      --store "$BASELINE_STORE" \
      --mode "$BASELINE_MODE" \
      --output "$FINALIZE_JSON" \
      > /dev/null 2> "$FINALIZE_ERR"
    local finalize_rc=$?
    set -e
    echo "Finalize JSON: $FINALIZE_JSON"
    case "$finalize_rc" in
      0)
        echo "Finalize verdict: baseline store updated or matched decision emitted"
        ;;
      *)
        echo "Finalize verdict: baseline finalization not applicable (exit $finalize_rc)"
        ;;
    esac
    if [[ "$finalize_rc" -eq 0 ]]; then
      if PYTHONPATH=scripts python3 -c '
import json, sys
payload = json.load(open(sys.argv[1]))
sys.exit(0 if payload.get("verdict") == "recorded" else 1)
' "$FINALIZE_JSON"; then
        set +e
        run_passive_baseline_mark
        local mark_rc=$?
        set -e
        if [[ "$mark_rc" -ne 0 ]]; then
          exit_with_control_report "$mark_rc"
        fi
      fi
    fi
    if [[ "$finalize_rc" -eq 0 && -n "$CONTROL_STATE" ]]; then
      if PYTHONPATH=scripts python3 -c '
import json, sys
payload = json.load(open(sys.argv[1]))
sys.exit(0 if payload.get("verdict") == "decided" else 1)
' "$FINALIZE_JSON"; then
        set +e
        PYTHONPATH=scripts python3 scripts/passive_correction_gate.py "$FINALIZE_JSON" \
          --state "$CONTROL_STATE" \
          --output "$GATE_JSON" \
          --max-repeat-delta-ms "$MAX_REPEAT_DELTA_MS" \
          --max-pending-age-sec "$MAX_PENDING_AGE_SEC" \
          > /dev/null 2> "$GATE_ERR"
        local gate_rc=$?
        set -e
        echo "Correction gate JSON: $GATE_JSON"
        case "$gate_rc" in
          0)
            echo "Correction gate verdict: repeated passive correction is ready as an apply candidate"
            set +e
            run_passive_apply_dry_run
            local apply_rc=$?
            set -e
            if [[ "$apply_rc" -ne 0 ]]; then
              exit_with_control_report "$apply_rc"
            fi
            ;;
          3)
            echo "Correction gate verdict: pending repeat confirmation"
            ;;
          *)
            echo "Correction gate verdict: failed to evaluate correction gate (exit $gate_rc)"
            ;;
        esac
        exit_with_control_report "$gate_rc"
      else
        echo "Correction gate: skipped because finalize did not emit a stored-baseline decision"
      fi
    fi
    exit_with_control_report "$finalize_rc"
  fi
  exit_with_control_report "$audit_rc"
}

on_interrupt() {
  local sig="$1"
  echo
  echo "Passive drift session interrupted by $sig; auditing available artifacts."
  run_audit_and_exit
}

if [[ -n "$BASELINE_REPORT" && -n "$BASELINE_OFFSET_MS" ]]; then
  echo "ERROR: set only one of SYNCAST_PASSIVE_BASELINE_REPORT or SYNCAST_PASSIVE_BASELINE_OFFSET_MS" >&2
  exit 2
fi
if [[ -n "$BASELINE_STORE" && ( -n "$BASELINE_REPORT" || -n "$BASELINE_OFFSET_MS" ) ]]; then
  echo "ERROR: SYNCAST_PASSIVE_BASELINE_STORE cannot be combined with baseline report/offset env vars" >&2
  exit 2
fi
if [[ -n "$AUTO_START_TARGETS" ]]; then
  if [[ ! "$AUTO_START_TIMEOUT" =~ ^[0-9]+$ ]] || (( AUTO_START_TIMEOUT < 15 )); then
    echo "ERROR: SYNCAST_PASSIVE_AUTO_START_TIMEOUT_SEC must be an integer >= 15" >&2
    exit 2
  fi
  case "$AUTO_CAPTURE_BACKEND" in
    ""|tap|sck) ;;
    *)
      echo "ERROR: SYNCAST_PASSIVE_AUTO_CAPTURE_BACKEND must be tap, sck, or empty" >&2
      exit 2
      ;;
  esac
case "$AUTO_LAUNCH_MODE" in
  auto|open|exec|headless) ;;
  *)
    echo "ERROR: SYNCAST_PASSIVE_AUTO_LAUNCH_MODE must be auto, open, exec, or headless" >&2
    exit 2
    ;;
esac
fi
case "$PASSIVE_APPLY_MODE" in
  dry-run|off) ;;
  *)
    echo "ERROR: SYNCAST_PASSIVE_APPLY_MODE must be dry-run or off" >&2
    exit 2
    ;;
esac
case "$WORKFLOW_GUARD_MODE" in
  enforce|warn|off) ;;
  *)
    echo "ERROR: SYNCAST_PASSIVE_WORKFLOW_GUARD must be enforce, warn, or off" >&2
    exit 2
    ;;
esac
case "$BASELINE_MODE" in
  auto|record|decide) ;;
  *)
    echo "ERROR: SYNCAST_PASSIVE_BASELINE_MODE must be auto, record, or decide" >&2
    exit 2
    ;;
esac
case "$BASELINE_MARK_MODE" in
  mark|dry-run|off) ;;
  *)
    echo "ERROR: SYNCAST_PASSIVE_BASELINE_MARK_MODE must be mark, dry-run, or off" >&2
    exit 2
    ;;
esac
case "$READINESS_ONLY" in
  0|1) ;;
  *)
    echo "ERROR: SYNCAST_PASSIVE_READINESS_ONLY must be 0 or 1" >&2
    exit 2
    ;;
esac

mkdir -p "$OUTPUT_ROOT"

PYTHONPATH=scripts python3 -c '
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
auto_start_requested = bool(sys.argv[15])
launch_method = sys.argv[19] if auto_start_requested else None
headless_requested = launch_method == "headless"
payload = {
    "schema": "syncast.passive_drift_session.v1",
    "createdUnix": round(time.time(), 3),
    "script": "scripts/passive_drift_session.sh",
    "socket": sys.argv[2],
    "samples": int(sys.argv[3]),
    "intervalSec": float(sys.argv[4]),
    "durationSec": float(sys.argv[5]),
    "maxDelayMs": int(float(sys.argv[6])),
    "baselineReport": sys.argv[7] or None,
    "baselineOffsetMs": None if not sys.argv[8] else float(sys.argv[8]),
    "baselineStore": sys.argv[9] or None,
        "baselineMode": sys.argv[10],
        "baselineMarkMode": sys.argv[11],
        "controlState": sys.argv[12] or None,
        "workflowGuardMode": sys.argv[20],
        "maxRepeatDeltaMs": float(sys.argv[13]),
    "maxPendingAgeSec": float(sys.argv[14]),
    "autoStartTargets": sys.argv[15] or None,
    "autoStartTimeoutSec": None if not sys.argv[15] else int(sys.argv[16]),
    "autoCaptureBackend": sys.argv[17] or None,
    "passiveApplyMode": sys.argv[18],
    "readinessOnly": sys.argv[21] == "1",
    "emitsAudio": False,
    "appliesDelay": False,
    "opensMicrophoneOnlyAfterPreflight": True,
    "launchesApp": auto_start_requested and not headless_requested,
    "launchesHeadlessRuntime": auto_start_requested and headless_requested,
    "appLaunchAttempted": False,
    "appLaunched": False,
    "headlessRuntimeLaunched": False,
    "launchMethodRequested": launch_method,
    "launchMethodUsed": None,
    "launchEnvironmentApplied": False if headless_requested else (None if auto_start_requested else False),
    "appWasRunningBeforeAutoStart": None if auto_start_requested else False,
    "changesRoutes": auto_start_requested,
    "changesLaunchEnvironment": auto_start_requested and not headless_requested,
    "mayChangeDefaultOutput": auto_start_requested,
    "changesDefaultOutput": None if auto_start_requested else False,
    "defaultOutputReadFailed": None if auto_start_requested else False,
    "defaultOutputVerified": None if auto_start_requested else True,
    "defaultOutputSetupSkipped": False,
    "defaultOutputReport": None,
    "autoStartSideEffectsUpdated": False if auto_start_requested else True,
    "autoStartAcousticSetupCompleted": None if auto_start_requested else False,
    "workflow": [
        "readiness_report",
        "workflow_guard",
        "auto_start_setup_if_requested",
        "auto_start_capture_preflight_if_requested",
        "auto_start_preflight_if_requested",
        "capture_preflight",
        "preflight",
        "monitor",
        "summary",
        "decision",
        "audit",
        "finalize_if_baseline_store",
        "passive_baseline_mark_if_recorded",
        "correction_gate_if_control_state",
        "passive_apply_dry_run_if_candidate_ready",
        "control_report",
    ],
    "artifacts": {
        "readiness": "readiness.json",
        "workflowGuard": "workflow_guard.json",
        "autoStartSetup": "auto_start_setup.json",
        "headlessStatus": "headless_status.json",
        "capturePreflight": "capture_preflight.json",
        "preflight": "preflight.json",
        "autoStartCapturePreflight": "auto_start_capture_preflight.json",
        "autoStartPreflight": "auto_start_preflight.json",
        "monitor": "monitor.json",
        "samples": "samples.jsonl",
        "summary": "summary.json",
        "decision": "decision.json",
        "finalize": "finalize.json",
        "passiveBaselineMark": "passive_baseline_mark.json",
        "correctionGate": "correction_gate.json",
        "passiveApply": "passive_apply.json",
        "audit": "audit.json",
        "controlReport": "control_report.json",
    },
}
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
' "$MANIFEST_JSON" "$SOCKET" "$SAMPLES" "$INTERVAL_SEC" "$DURATION_SEC" \
  "$MAX_DELAY_MS" "$BASELINE_REPORT" "$BASELINE_OFFSET_MS" \
  "$BASELINE_STORE" "$BASELINE_MODE" "$BASELINE_MARK_MODE" "$CONTROL_STATE" \
  "$MAX_REPEAT_DELTA_MS" "$MAX_PENDING_AGE_SEC" "$AUTO_START_TARGETS" \
  "$AUTO_START_TIMEOUT" "$AUTO_CAPTURE_BACKEND" "$PASSIVE_APPLY_MODE" \
  "$AUTO_LAUNCH_MODE" "$WORKFLOW_GUARD_MODE" "$READINESS_ONLY"

trap 'on_interrupt INT' INT
trap 'on_interrupt TERM' TERM

write_readiness_report

if ! prepare_auto_start_if_requested; then
  echo
  echo "Passive auto-start failed before usable capture; auditing available artifacts."
  if [[ ! -f "$READINESS_JSON" ]]; then
    write_readiness_report
  fi
  run_audit_and_exit
fi

write_readiness_report

if [[ "$READINESS_ONLY" == "1" ]]; then
  echo "Passive readiness-only session"
  echo "  socket      : $SOCKET"
  echo "  output_root : $OUTPUT_ROOT"
  echo "  emits audio : no"
  echo "  opens mic   : no"
  echo "  applies delay: no"
  echo "  manifest   : $MANIFEST_JSON"
  echo
  exit_with_control_report 0
fi

if ! run_workflow_guard; then
  echo
  echo "Passive readiness workflow guard blocked before microphone access; auditing available artifacts."
  run_audit_and_exit
fi

echo "Passive drift session"
echo "  socket      : $SOCKET"
echo "  output_root : $OUTPUT_ROOT"
echo "  samples     : $SAMPLES"
echo "  interval_sec: $INTERVAL_SEC"
echo "  duration_sec: $DURATION_SEC"
echo "  max_delay_ms: $MAX_DELAY_MS"
echo "  emits audio : no"
echo "  applies delay: no"
echo "  manifest   : $MANIFEST_JSON"
if [[ -n "$BASELINE_STORE" ]]; then
  echo "  baseline store: $BASELINE_STORE ($BASELINE_MODE)"
  echo "  baseline mark : $BASELINE_MARK_MODE"
fi
if [[ -n "$CONTROL_STATE" ]]; then
  echo "  control state : $CONTROL_STATE (repeat delta <= ${MAX_REPEAT_DELTA_MS}ms, pending age <= ${MAX_PENDING_AGE_SEC}s)"
fi
if [[ -n "$AUTO_START_TARGETS" ]]; then
  echo "  auto-start : $AUTO_START_TARGETS"
fi
echo "  apply mode : $PASSIVE_APPLY_MODE"
echo "  workflow guard: $WORKFLOW_GUARD_MODE"
echo

set +e
PYTHONPATH=scripts python3 scripts/passive_capture_estimate.py \
  --socket "$SOCKET" \
  --preflight-only \
  --cycles 3 \
  --duration-sec "$DURATION_SEC" \
  --max-delay-ms "$MAX_DELAY_MS" \
  --report-path "$CAPTURE_PREFLIGHT_JSON"
CAPTURE_PREFLIGHT_RC=$?
PYTHONPATH=scripts python3 scripts/passive_drift_monitor.py \
  --socket "$SOCKET" \
  --preflight-only \
  --samples "$SAMPLES" \
  --cycles 3 \
  --duration-sec "$DURATION_SEC" \
  --max-delay-ms "$MAX_DELAY_MS" \
  --report-path "$PREFLIGHT_JSON"
PREFLIGHT_RC=$?
set -e

if [[ "$CAPTURE_PREFLIGHT_RC" -ne 0 || "$PREFLIGHT_RC" -ne 0 ]]; then
  echo
  echo "Capture preflight failed before mic access: $CAPTURE_PREFLIGHT_JSON"
  echo "Preflight failed before mic access: $PREFLIGHT_JSON"
  run_audit_and_exit
fi

echo
echo "Capture preflight OK: $CAPTURE_PREFLIGHT_JSON"
echo "Preflight OK: $PREFLIGHT_JSON"
echo

set +e
PYTHONPATH=scripts python3 scripts/passive_drift_monitor.py \
  --socket "$SOCKET" \
  --samples "$SAMPLES" \
  --interval-sec "$INTERVAL_SEC" \
  --cycles 3 \
  --duration-sec "$DURATION_SEC" \
  --max-delay-ms "$MAX_DELAY_MS" \
  --output-root "$CAPTURE_ROOT" \
  --report-path "$MONITOR_JSON" \
  --jsonl-path "$SAMPLES_JSONL"
MONITOR_RC=$?
set -e

echo
echo "Monitor report: $MONITOR_JSON"
echo "Samples JSONL : $SAMPLES_JSONL"
echo "Monitor exit  : $MONITOR_RC"
echo

if [[ ! -s "$MONITOR_JSON" ]]; then
  echo "Monitor report missing or empty; auditing partial session."
  run_audit_and_exit
fi

set +e
PYTHONPATH=scripts python3 scripts/passive_drift_summary.py "$MONITOR_JSON" > "$SUMMARY_TXT"
SUMMARY_TEXT_RC=$?
PYTHONPATH=scripts python3 scripts/passive_drift_summary.py "$MONITOR_JSON" --json > "$SUMMARY_JSON"
SUMMARY_JSON_RC=$?
set -e

echo "Summary text : $SUMMARY_TXT"
echo "Summary JSON : $SUMMARY_JSON"
echo "Summary exits: text=$SUMMARY_TEXT_RC json=$SUMMARY_JSON_RC"
echo

if [[ "$SUMMARY_TEXT_RC" -ne 0 || "$SUMMARY_JSON_RC" -ne 0 ]]; then
  echo "Summary generation failed; auditing available artifacts."
  run_audit_and_exit
fi

DECISION_ARGS=("$MONITOR_JSON")
if [[ -n "$BASELINE_REPORT" ]]; then
  DECISION_ARGS+=("--baseline-report" "$BASELINE_REPORT")
elif [[ -n "$BASELINE_OFFSET_MS" ]]; then
  DECISION_ARGS+=("--baseline-offset-ms" "$BASELINE_OFFSET_MS")
fi

set +e
PYTHONPATH=scripts python3 scripts/passive_delay_decision.py "${DECISION_ARGS[@]}" \
  > "$DECISION_JSON" 2> "$DECISION_ERR"
DECISION_RC=$?
set -e

if [[ ! -s "$DECISION_JSON" && -s "$DECISION_ERR" ]]; then
  cp "$DECISION_ERR" "$DECISION_JSON"
fi

echo "Decision JSON: $DECISION_JSON"
case "$DECISION_RC" in
  0)
    echo "Decision verdict: usable no-write decision"
    ;;
  3)
    echo "Decision verdict: valid evidence but not applicable for delay control"
    ;;
  *)
    echo "Decision verdict: failed to evaluate decision (exit $DECISION_RC)"
    ;;
esac

run_audit_and_exit
