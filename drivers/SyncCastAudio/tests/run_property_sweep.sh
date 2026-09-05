#!/usr/bin/env bash
#
# Build and run the SyncCastAudio property/IO sweep (tests/property_sweep.c)
# three ways:
#
#   plain   against the REAL bundle that build.sh produced, i.e. the exact
#           Mach-O that gets installed into /Library/Audio/Plug-Ins/HAL.
#   asan    driver + harness recompiled with -fsanitize=address,undefined, so
#           every property buffer the driver writes into sits inside an ASan
#           redzone and any overrun or UB aborts the run.
#   tsan    driver + harness recompiled with -fsanitize=thread, which is what
#           actually judges the gPlugIn_StateMutex / gDevice_IOMutex split:
#           the harness drives GetZeroTimeStamp on one thread while four more
#           hammer the property getters and setters.
#
# Sanitized builds are single-arch (the host arch) — a universal build cannot
# be sanitized in one clang invocation, and the bug classes here are not
# arch-specific.
#
# Usage:
#   bash drivers/SyncCastAudio/tests/run_property_sweep.sh [io seconds]
#
# Exit status is non-zero if any check fails or any sanitizer fires.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
IO_SECONDS="${1:-2}"

SOURCES=(
    "$DRIVER_DIR/Source/SyncCastAudioPlugIn.c"
    "$DRIVER_DIR/Source/SyncCastAudioProperties.c"
    "$DRIVER_DIR/Source/SyncCastAudioStreamControls.c"
)
COMMON_FLAGS=(
    -g -O1
    -Wall -Wextra -Werror -Wno-unused-parameter
    -mmacosx-version-min=14.0
    -fvisibility=default
    -I "$DRIVER_DIR/Source"
    -framework CoreFoundation -framework CoreAudio
)

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

FAILED=0

run_case() {
    local theName="$1"; shift
    local theBinary="$1"; shift
    local theDylib="$1"; shift

    echo
    echo "### $theName"
    if ! "$theBinary" "$theDylib" "$IO_SECONDS"; then
        echo "### $theName: FAILED"
        FAILED=1
    else
        echo "### $theName: ok"
    fi
}

# --- plain, against the shipped bundle -----------------------------------

REAL_BUNDLE="$DRIVER_DIR/build/SyncCastAudio.driver/Contents/MacOS/SyncCastAudio"
if [[ ! -x "$REAL_BUNDLE" ]]; then
    echo "==> building the driver first"
    bash "$DRIVER_DIR/build.sh" >/dev/null
fi

echo "==> compiling the harness (plain)"
clang "${COMMON_FLAGS[@]}" -o "$BUILD_DIR/sweep_plain" "$SCRIPT_DIR/property_sweep.c" || exit 2
run_case "plain harness vs the installed-shape universal bundle" "$BUILD_DIR/sweep_plain" "$REAL_BUNDLE"

# --- ASan + UBSan --------------------------------------------------------

echo
echo "==> compiling driver + harness with -fsanitize=address,undefined"
SAN_FLAGS=(-fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer)
clang "${COMMON_FLAGS[@]}" "${SAN_FLAGS[@]}" -bundle -o "$BUILD_DIR/SyncCastAudio_asan.bundle" "${SOURCES[@]}" || exit 2
clang "${COMMON_FLAGS[@]}" "${SAN_FLAGS[@]}" -o "$BUILD_DIR/sweep_asan" "$SCRIPT_DIR/property_sweep.c" || exit 2
ASAN_OPTIONS="abort_on_error=1:detect_stack_use_after_return=1" \
UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1" \
    run_case "ASan + UBSan" "$BUILD_DIR/sweep_asan" "$BUILD_DIR/SyncCastAudio_asan.bundle"

# --- TSan ----------------------------------------------------------------

echo
echo "==> compiling driver + harness with -fsanitize=thread"
clang "${COMMON_FLAGS[@]}" -fsanitize=thread -bundle -o "$BUILD_DIR/SyncCastAudio_tsan.bundle" "${SOURCES[@]}" || exit 2
clang "${COMMON_FLAGS[@]}" -fsanitize=thread -o "$BUILD_DIR/sweep_tsan" "$SCRIPT_DIR/property_sweep.c" || exit 2
TSAN_OPTIONS="halt_on_error=1:second_deadlock_stack=1" \
    run_case "TSan" "$BUILD_DIR/sweep_tsan" "$BUILD_DIR/SyncCastAudio_tsan.bundle"

echo
if [[ "$FAILED" == "0" ]]; then
    echo "ALL PASS"
else
    echo "FAILURES — see above"
fi
exit "$FAILED"
