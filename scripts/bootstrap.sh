#!/usr/bin/env bash
# SyncCast bootstrap — install the native deps SyncCast needs to run.
#
# Idempotent: re-running is safe.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log() { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "SyncCast is macOS-only."
fi

if ! command -v brew >/dev/null 2>&1; then
  fail "Homebrew not found. Install from https://brew.sh and re-run."
fi

# 1. Silent virtual audio device.
#
# Both the local Stereo sink path and whole-home mode need ONE silent virtual
# output device. Two are accepted, in this preference order:
#
#   1. SyncCast's own driver (drivers/SyncCastAudio, UID SyncCastAudio_UID) —
#      installed with `sudo bash scripts/install-driver.sh`, or from the app's
#      「安装 SyncCast 音频驱动」 menu item. Preferred: output-only, named
#      "SyncCast", and not shared with whatever else the user set up.
#   2. BlackHole 2ch — the fallback, kept working for machines that never ran
#      the sudo-requiring driver install.
#
# So BlackHole is OPTIONAL. This script installs it only when SyncCast's own
# driver is absent, and never uninstalls anything. If you already have the
# SyncCast driver loaded you can remove BlackHole:
#   sudo rm -rf /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver && sudo killall coreaudiod
if [[ -d /Library/Audio/Plug-Ins/HAL/SyncCastAudio.driver ]]; then
  log "SyncCast audio driver already installed — BlackHole is not needed."
elif system_profiler SPAudioDataType 2>/dev/null | grep -qi 'BlackHole 2ch'; then
  log "BlackHole 2ch already installed (fallback sink)."
  log "  Optional upgrade: sudo bash scripts/install-driver.sh, then you may"
  log "  uninstall BlackHole."
else
  log "No silent sink found. Installing BlackHole 2ch as the fallback…"
  log "  (Recommended instead/afterwards: sudo bash scripts/install-driver.sh)"
  brew install --cask blackhole-2ch
fi

# 2. OwnTone — AirPlay 2 multi-target sender (ADR-006).
# OwnTone has no Homebrew formula or .pkg installer for macOS as of 2026-04;
# we build from source. The build itself is handled by build-owntone.sh.
OWNTONE_BIN="$HOME/owntone_data/usr/sbin/owntone"
if [[ ! -x "$OWNTONE_BIN" ]] && ! command -v owntone >/dev/null 2>&1; then
  log "OwnTone not found. Running build-owntone.sh — this takes 5–10 minutes
        and asks for sudo once (for /usr/local/bin symlinks of bison/flex
        and for libinotify-kqueue install)."
  "$REPO_ROOT/scripts/build-owntone.sh"
else
  log "OwnTone already present (looking for $OWNTONE_BIN or owntone in PATH)."
fi

# 3. Python 3.11+. The system /usr/bin/python3 on older macOS is 3.9; pyatv
#    and our type-annotated code need 3.11.
PYTHON=""
for cand in python3.12 python3.11 python3; do
  if command -v "$cand" >/dev/null 2>&1; then
    ver="$("$cand" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
    major="${ver%%.*}"
    minor="${ver##*.}"
    if (( major > 3 || (major == 3 && minor >= 11) )); then
      PYTHON="$cand"
      break
    fi
  fi
done
if [[ -z "$PYTHON" ]]; then
  log "No Python ≥ 3.11 found. Installing python@3.12 via Homebrew…"
  brew install python@3.12
  PYTHON="$(brew --prefix python@3.12)/bin/python3.12"
fi
log "Using Python at: $PYTHON"

if [[ ! -d sidecar/.venv ]]; then
  log "Creating Python venv for sidecar…"
  "$PYTHON" -m venv sidecar/.venv
fi
log "Installing sidecar Python deps…"
"$REPO_ROOT/sidecar/.venv/bin/pip" install -q --upgrade pip wheel
"$REPO_ROOT/sidecar/.venv/bin/pip" install -q -e "$REPO_ROOT/sidecar[dev]"

# 4. Reminder for the user.
cat <<'EOF'

Next steps:
  • Recommended: install SyncCast's own audio driver —
        sudo bash scripts/install-driver.sh
    It is preferred over BlackHole by BOTH the local Stereo sink path and
    whole-home mode, and once it is loaded BlackHole can be uninstalled:
        sudo rm -rf /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver
        sudo killall coreaudiod
  • You never need to select the silent device by hand. Entering whole-home
    mode switches the system output to  "AirPlay 全屋"  (a SyncCast-owned
    wrapper around whichever silent device is installed) and restores your
    previous output on exit. Note that the macOS volume slider is greyed out
    while it is selected — use SyncCast's own panel for volume.
  • If you want the Mac mini in your group, enable
    System Settings → General → AirDrop & Handoff → AirPlay Receiver
    on that Mac and set "Allow AirPlay for: Anyone on the same network".

Run:
  ./scripts/build.sh    to build all Swift packages
  ./scripts/dev-run.sh  to launch SyncCast in development mode
EOF
