#!/usr/bin/env bash
#
# Build SyncCastAudio.driver — the userland AudioServerPlugIn that gives
# SyncCast's local Stereo path a real macOS system volume.
#
# Output: drivers/SyncCastAudio/build/SyncCastAudio.driver
#
# Signing:
#   default                        ad-hoc (`codesign -s -`)
#   SYNCAST_USE_SYNCCAST_DEV=1     the stable self-signed "SyncCast Dev" cert,
#                                  matching scripts/install-app.sh. Use it when
#                                  you want the driver and the app to share an
#                                  identity; an ad-hoc signature is re-minted on
#                                  every build, which is fine for the driver
#                                  (coreaudiod does not keep TCC grants for it)
#                                  but noisy in logs.
#
# This script does NOT install. Installing writes to /Library and restarts
# coreaudiod, which needs sudo — see scripts/install-driver.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
BUNDLE="$BUILD_DIR/SyncCastAudio.driver"
USE_DEV_CERT="${SYNCAST_USE_SYNCCAST_DEV:-0}"
DEV_CERT_NAME="${SYNCAST_DEV_CERT_NAME:-SyncCast Dev}"

SOURCES=(
    "$SCRIPT_DIR/Source/SyncCastAudioPlugIn.c"
    "$SCRIPT_DIR/Source/SyncCastAudioProperties.c"
    "$SCRIPT_DIR/Source/SyncCastAudioStreamControls.c"
)

echo "==> cleaning $BUILD_DIR"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

echo "==> compiling"
# -bundle: an AudioServerPlugIn is a CFBundle loaded into coreaudiod, not a
# dylib. -fvisibility=default keeps SyncCastAudio_Create exported so CFPlugIn
# can find it by name (the Info.plist factory entry is a symbol lookup).
clang \
    -bundle \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min=14.0 \
    -O2 \
    -Wall -Wextra -Werror \
    -Wno-unused-parameter \
    -fvisibility=default \
    -framework CoreFoundation \
    -framework CoreAudio \
    -I "$SCRIPT_DIR/Source" \
    -o "$BUNDLE/Contents/MacOS/SyncCastAudio" \
    "${SOURCES[@]}"

cp "$SCRIPT_DIR/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"

echo "==> validating bundle"
plutil -lint "$BUNDLE/Contents/Info.plist"
# The factory symbol must be exported under exactly this name or the HAL loads
# the bundle and then finds nothing.
if ! nm -gU "$BUNDLE/Contents/MacOS/SyncCastAudio" | grep -q "_SyncCastAudio_Create"; then
    echo "ERROR: SyncCastAudio_Create is not exported" >&2
    exit 1
fi

echo "==> signing"
if [[ "$USE_DEV_CERT" == "1" ]]; then
    if ! security find-certificate -c "$DEV_CERT_NAME" >/dev/null 2>&1; then
        echo "ERROR: certificate '$DEV_CERT_NAME' not found; run scripts/install-app.sh once to create it, or unset SYNCAST_USE_SYNCCAST_DEV" >&2
        exit 1
    fi
    codesign --force --sign "$DEV_CERT_NAME" --timestamp=none "$BUNDLE"
else
    codesign --force --sign - --timestamp=none "$BUNDLE"
fi
codesign -dv "$BUNDLE" 2>&1 | sed 's/^/    /'

echo
echo "built: $BUNDLE"
echo "install with: sudo bash scripts/install-driver.sh"
