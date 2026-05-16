#!/usr/bin/env bash
# Shared CoreAudio default-output helpers for hardware smoke tests.
#
# Acoustic Local + AirPlay tests must start from one ordinary macOS
# default output. If the user has manually selected a Multi-Output Device,
# the microphone hears an extra uncontrolled playback timeline and the
# calibration result is not evidence.

syncast_coreaudio_guard_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

SYNCAST_COREAUDIO_DEFAULT_OUTPUT_PROBE="${SYNCAST_COREAUDIO_DEFAULT_OUTPUT_PROBE:-${TMPDIR:-/tmp}/syncast-coreaudio-default-output.$(id -u).$$}"

syncast_coreaudio_default_output_probe() {
    local script_dir helper probe tmp_probe
    script_dir="$(syncast_coreaudio_guard_dir)"
    helper="$script_dir/coreaudio_default_output.c"
    probe="$SYNCAST_COREAUDIO_DEFAULT_OUTPUT_PROBE"
    tmp_probe="${probe}.tmp"
    if [[ ! -f "$helper" ]]; then
        echo "ERROR: $helper not found." >&2
        return 1
    fi
    if [[ -x "$probe" ]]; then
        printf '%s\n' "$probe"
        return 0
    fi
    if ! cc "$helper" \
        -framework CoreAudio \
        -framework CoreFoundation \
        -o "$tmp_probe"; then
        rm -f "$tmp_probe"
        return 1
    fi
    chmod 700 "$tmp_probe" 2>/dev/null || true
    if ! mv -f "$tmp_probe" "$probe"; then
        rm -f "$tmp_probe"
        return 1
    fi
    printf '%s\n' "$probe"
}

syncast_cleanup_coreaudio_default_output_probe() {
    rm -f "$SYNCAST_COREAUDIO_DEFAULT_OUTPUT_PROBE" "${SYNCAST_COREAUDIO_DEFAULT_OUTPUT_PROBE}.tmp"
}

syncast_read_default_output() {
    local probe
    probe="$(syncast_coreaudio_default_output_probe)" || return 1
    "$probe"
}

syncast_list_output_devices() {
    local probe
    probe="$(syncast_coreaudio_default_output_probe)" || return 1
    "$probe" --list-output-devices
}

syncast_set_default_output_uid() {
    local uid="$1"
    local probe
    probe="$(syncast_coreaudio_default_output_probe)" || return 1
    "$probe" --set-default-uid "$uid"
}

syncast_default_output_uid() {
    printf '%s\n' "$1" | awk -F '\t' '{print $2}'
}

syncast_default_output_name() {
    printf '%s\n' "$1" | awk -F '\t' '{print $3}'
}

syncast_default_output_is_forbidden_for_acoustic_test() {
    local output="$1"
    local uid name
    uid="$(syncast_default_output_uid "$output")"
    name="$(syncast_default_output_name "$output")"
    if [[ -z "$uid" && -z "$name" ]]; then
        return 0
    fi
    if printf '%s\n' "$output" | grep -Eq $'\tclass=aagg|\tsubdevices=[1-9]'; then
        return 0
    fi
    case "$uid" in
        io.syncast.directaggregate.v1.*|*AMS2_StackedOutput*)
            return 0
            ;;
    esac
    case "$name" in
        *"Multi-Output"*|*"多输出"*|*"多重输出"*)
            return 0
            ;;
    esac
    return 1
}

syncast_device_line_matches_token() {
    local line="$1"
    local token="$2"
    local uid name haystack
    uid="$(syncast_default_output_uid "$line")"
    name="$(syncast_default_output_name "$line")"
    haystack="$(printf '%s %s' "$uid" "$name" | tr '[:upper:]' '[:lower:]')"
    token="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')"
    [[ -z "$token" ]] && return 1
    if [[ "$haystack" == *"$token"* ]]; then
        return 0
    fi
    case "$token" in
        mbp|macbook|built-in|builtin)
            [[ "$haystack" == *"macbook"* || "$haystack" == *"built-in"* || "$haystack" == *"扬声器"* ]]
            ;;
        display|monitor|pg27)
            [[ "$haystack" == *"display"* || "$haystack" == *"monitor"* || "$haystack" == *"pg27"* ]]
            ;;
        *)
            return 1
            ;;
    esac
}

syncast_device_line_is_ordinary_output() {
    local line="$1"
    local uid name haystack
    uid="$(syncast_default_output_uid "$line")"
    name="$(syncast_default_output_name "$line")"
    haystack="$(printf '%s %s' "$uid" "$name" | tr '[:upper:]' '[:lower:]')"
    [[ -z "$uid" ]] && return 1
    syncast_default_output_is_forbidden_for_acoustic_test "$line" && return 1
    case "$haystack" in
        *blackhole*|*soundflower*|*loopback*)
            return 1
            ;;
    esac
    return 0
}

syncast_choose_ordinary_output_for_targets() {
    local targets="$1"
    local devices token line best=""
    devices="$(syncast_list_output_devices)" || return 1
    IFS=',' read -r -a target_tokens <<< "$targets"
    for token in "${target_tokens[@]}"; do
        token="${token//[[:space:]]/}"
        [[ -z "$token" ]] && continue
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if syncast_device_line_is_ordinary_output "$line" &&
                syncast_device_line_matches_token "$line" "$token"; then
                printf '%s\n' "$line"
                return 0
            fi
        done <<< "$devices"
    done
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if syncast_device_line_is_ordinary_output "$line" &&
            syncast_device_line_matches_token "$line" "mbp"; then
            printf '%s\n' "$line"
            return 0
        fi
    done <<< "$devices"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if syncast_device_line_is_ordinary_output "$line"; then
            best="$line"
            break
        fi
    done <<< "$devices"
    [[ -n "$best" ]] || return 1
    printf '%s\n' "$best"
}

SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT=""
SYNCAST_ACOUSTIC_RESTORE_DEFAULT_UID=""
SYNCAST_ACOUSTIC_DEFAULT_CHANGED=0
SYNCAST_ACOUSTIC_DEFAULT_READ_FAILED=0

syncast_prepare_ordinary_default_output_for_acoustic_test() {
    local targets="${1:-}"
    local output uid candidate candidate_uid new_output
    SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT=""
    SYNCAST_ACOUSTIC_RESTORE_DEFAULT_UID=""
    SYNCAST_ACOUSTIC_DEFAULT_CHANGED=0
    SYNCAST_ACOUSTIC_DEFAULT_READ_FAILED=0
    if ! output="$(syncast_read_default_output 2>&1)"; then
        SYNCAST_ACOUSTIC_DEFAULT_READ_FAILED=1
        SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT="  default-read-error: $output"
        printf '%s\n' "$output" >&2
        if [[ "${SYNCAST_ALLOW_DEFAULT_OUTPUT_READ_FAILURE:-0}" == "1" ]]; then
            SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT=$'WARN: acoustic test running with unverified default output because SYNCAST_ALLOW_DEFAULT_OUTPUT_READ_FAILURE=1\n'"$SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT"
            return 0
        fi
        echo "ERROR: could not read CoreAudio default output; refusing acoustic test." >&2
        return 4
    fi
    if ! syncast_default_output_is_forbidden_for_acoustic_test "$output"; then
        SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT="  default : $output"
        return 0
    fi
    if [[ "${SYNCAST_ALLOW_MULTI_OUTPUT_DEFAULT:-0}" == "1" ]]; then
        SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT=$'WARN: acoustic test running with non-ordinary default output because SYNCAST_ALLOW_MULTI_OUTPUT_DEFAULT=1\n'"  default : $output"
        return 0
    fi
    if [[ "${SYNCAST_ACOUSTIC_AUTO_DEFAULT:-1}" != "1" ]]; then
        echo "ERROR: acoustic Local + AirPlay tests require one ordinary macOS default output." >&2
        echo "       Current default appears to be a Multi-Output/SyncCast aggregate:" >&2
        echo "       $output" >&2
        return 4
    fi
    if ! candidate="$(syncast_choose_ordinary_output_for_targets "$targets")"; then
        echo "ERROR: could not find an ordinary CoreAudio output to use for acoustic test." >&2
        echo "       Current default is forbidden: $output" >&2
        return 4
    fi
    uid="$(syncast_default_output_uid "$output")"
    candidate_uid="$(syncast_default_output_uid "$candidate")"
    SYNCAST_ACOUSTIC_RESTORE_DEFAULT_UID="$uid"
    SYNCAST_ACOUSTIC_DEFAULT_CHANGED=1
    if ! new_output="$(syncast_set_default_output_uid "$candidate_uid")"; then
        echo "ERROR: failed to switch default output for acoustic test." >&2
        echo "       from: $output" >&2
        echo "       to  : $candidate" >&2
        return 4
    fi
    if syncast_default_output_is_forbidden_for_acoustic_test "$new_output"; then
        echo "ERROR: default output switch still resolved to a forbidden output: $new_output" >&2
        return 4
    fi
    SYNCAST_ACOUSTIC_DEFAULT_OUTPUT_REPORT=$'  default : '"$new_output"$'\n  previous: '"$output"$'\n  default-restore: scheduled'
    return 0
}

syncast_restore_acoustic_default_output() {
    if [[ "${SYNCAST_ACOUSTIC_DEFAULT_CHANGED:-0}" != "1" ||
          -z "${SYNCAST_ACOUSTIC_RESTORE_DEFAULT_UID:-}" ]]; then
        return 0
    fi
    local restored restored_uid
    if ! restored="$(syncast_set_default_output_uid "$SYNCAST_ACOUSTIC_RESTORE_DEFAULT_UID")"; then
        echo "WARN: failed to restore previous CoreAudio default output UID $SYNCAST_ACOUSTIC_RESTORE_DEFAULT_UID" >&2
        return 1
    fi
    restored_uid="$(syncast_default_output_uid "$restored")"
    if [[ "$restored_uid" != "$SYNCAST_ACOUSTIC_RESTORE_DEFAULT_UID" ]]; then
        echo "WARN: attempted to restore CoreAudio default output UID $SYNCAST_ACOUSTIC_RESTORE_DEFAULT_UID but current default is $restored" >&2
        return 1
    fi
    SYNCAST_ACOUSTIC_DEFAULT_CHANGED=0
    return 0
}

syncast_require_ordinary_default_output_for_acoustic_test() {
    local output
    if ! output="$(syncast_read_default_output)"; then
        echo "ERROR: could not read CoreAudio default output; refusing acoustic test." >&2
        return 4
    fi
    if syncast_default_output_is_forbidden_for_acoustic_test "$output"; then
        if [[ "${SYNCAST_ALLOW_MULTI_OUTPUT_DEFAULT:-0}" == "1" ]]; then
            echo "WARN: acoustic test running with non-ordinary default output because SYNCAST_ALLOW_MULTI_OUTPUT_DEFAULT=1"
            echo "  default : $output"
            return 0
        fi
        echo "ERROR: acoustic Local + AirPlay tests require one ordinary macOS default output." >&2
        echo "       Current default appears to be a Multi-Output/SyncCast aggregate:" >&2
        echo "       $output" >&2
        echo "       Switch System Settings -> Sound -> Output to one normal device," >&2
        echo "       then let SyncCast own the selected local outputs and AirPlay receivers." >&2
        return 4
    fi
    echo "  default : $output"
    return 0
}
