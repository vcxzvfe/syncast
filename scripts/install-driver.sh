#!/usr/bin/env bash
#
# Install SyncCastAudio.driver into /Library/Audio/Plug-Ins/HAL and restart
# coreaudiod so macOS picks it up.
#
# The driver is the virtual output device that carries SyncCast's system
# volume: with it installed, the macOS volume slider / F11 / F12 / HUD /
# LinearMouse control SyncCast's local Stereo output natively, and SyncCast
# never touches the media keys.
#
# Usage:
#   sudo bash scripts/install-driver.sh            # build if needed, install
#   sudo bash scripts/install-driver.sh --uninstall
#
# The menubar app runs this same script through
# `osascript ... with administrator privileges`, so there is exactly one
# install path to keep working.
#
# WARNING: restarting coreaudiod interrupts ALL audio on the machine for a
# second or two, and every app re-opens its output afterwards. That is
# unavoidable — the HAL only scans the plug-in directory at coreaudiod start.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DRIVER_SRC_DIR="$REPO_ROOT/drivers/SyncCastAudio"
BUILT_DRIVER="$DRIVER_SRC_DIR/build/SyncCastAudio.driver"
# Bundled mode: package-app.sh copies this script into the .app next to a
# prebuilt SyncCastAudio.driver, so the in-app install action works with no
# source checkout on the machine. Detected by the sibling driver, not by a
# flag, so there is nothing for a caller to get wrong.
if [[ -d "$SCRIPT_DIR/SyncCastAudio.driver" ]]; then
    BUILT_DRIVER="$SCRIPT_DIR/SyncCastAudio.driver"
    DRIVER_SRC_DIR=""
fi
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
INSTALLED_DRIVER="$HAL_DIR/SyncCastAudio.driver"
UNINSTALL=0

if [[ "${1:-}" == "--uninstall" ]]; then
    UNINSTALL=1
elif [[ -n "${1:-}" ]]; then
    echo "ERROR: unknown argument '$1' (expected --uninstall or nothing)" >&2
    exit 2
fi

if [[ "$(id -u)" != "0" ]]; then
    echo "ERROR: this script writes to $HAL_DIR and restarts coreaudiod; run it with sudo." >&2
    exit 3
fi

# Build the driver as a real (non-root) user.
#
# This script always runs as root, and there are two ways in: `sudo bash
# scripts/install-driver.sh`, which sets SUDO_USER, and the menubar app's
# `osascript ... with administrator privileges`, which does NOT — it hands us a
# bare root shell. Building there as root leaves a root-owned build/ in the
# developer's checkout that the next ordinary `bash build.sh` cannot overwrite,
# and signs with root's keychain rather than the user's.
build_driver() {
    local theBuildUser="${SUDO_USER:-}"
    if [[ -z "$theBuildUser" ]]; then
        # No SUDO_USER: fall back to whoever owns the console (the logged-in
        # GUI user), which is who the osascript prompt was shown to.
        theBuildUser="$(stat -f %Su /dev/console 2>/dev/null || true)"
    fi
    if [[ -z "$theBuildUser" || "$theBuildUser" == "root" ]]; then
        echo "ERROR: cannot determine a non-root user to build as, and refusing to" >&2
        echo "       build in $DRIVER_SRC_DIR as root (it would leave root-owned" >&2
        echo "       artefacts in the checkout)." >&2
        echo "       Build it yourself first and re-run this script:" >&2
        echo "           bash $DRIVER_SRC_DIR/build.sh" >&2
        echo "       or install a prebuilt SyncCastAudio.driver next to this script." >&2
        exit 5
    fi
    echo "==> building as $theBuildUser"
    # sudo scrubs the environment, so the one build-affecting variable is
    # forwarded explicitly.
    sudo -u "$theBuildUser" \
        "SYNCAST_USE_SYNCCAST_DEV=${SYNCAST_USE_SYNCCAST_DEV:-0}" \
        bash "$DRIVER_SRC_DIR/build.sh"
}

restart_coreaudiod() {
    echo "==> restarting coreaudiod (all audio briefly stops)"
    launchctl kickstart -k system/com.apple.audio.coreaudiod
}

if [[ "$UNINSTALL" == "1" ]]; then
    if [[ -d "$INSTALLED_DRIVER" ]]; then
        echo "==> removing $INSTALLED_DRIVER"
        rm -rf "$INSTALLED_DRIVER"
        restart_coreaudiod
        echo "uninstalled. SyncCast falls back to BlackHole (if installed) or to the legacy Direct Stereo path."
    else
        echo "not installed; nothing to do."
    fi
    exit 0
fi

if [[ -n "$DRIVER_SRC_DIR" ]]; then
    # Source checkout present: ALWAYS rebuild. A build/ left over from an
    # earlier edit looks exactly like a fresh one, so "build only if missing"
    # silently installs stale code — the single worst failure mode here,
    # because the symptom (an old bug still present after a fix) points
    # everywhere except at the installer.
    echo "==> rebuilding from source"
    build_driver
elif [[ ! -d "$BUILT_DRIVER" ]]; then
    echo "ERROR: no driver bundled next to this script and no source tree to build from." >&2
    exit 4
fi

if [[ ! -x "$BUILT_DRIVER/Contents/MacOS/SyncCastAudio" ]]; then
    echo "ERROR: $BUILT_DRIVER looks incomplete (no executable). Build it with drivers/SyncCastAudio/build.sh" >&2
    exit 4
fi

echo "==> verifying signature before installing"
codesign --verify --strict "$BUILT_DRIVER"

mkdir -p "$HAL_DIR"
echo "==> installing to $INSTALLED_DRIVER"
rm -rf "$INSTALLED_DRIVER"
# -R preserves the bundle; ownership must be root:wheel or coreaudiod refuses
# to load it.
cp -R "$BUILT_DRIVER" "$INSTALLED_DRIVER"
chown -R root:wheel "$INSTALLED_DRIVER"
# Directories traversable, files readable; only the Mach-O needs the exec bit.
# `chmod -R 755` would make Info.plist and _CodeSignature world-executable.
find "$INSTALLED_DRIVER" -type d -exec chmod 755 {} +
find "$INSTALLED_DRIVER" -type f -exec chmod 644 {} +
chmod 755 "$INSTALLED_DRIVER/Contents/MacOS/SyncCastAudio"

restart_coreaudiod

echo
echo "installed from: $BUILT_DRIVER"
echo "Restart SyncCast so it picks the new sink up (the path is"
echo "resolved once per launch), then check 系统设置 → 声音 for a \"SyncCast\" output."
