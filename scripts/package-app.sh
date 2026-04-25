#!/usr/bin/env bash
# Package SyncCast as a macOS .app bundle.
#
# Stages (each stage is independently re-runnable):
#   1) build the Swift menubar executable in release mode
#   2) lay out a .app bundle skeleton with Info.plist
#   3) bundle the Python sidecar via PyInstaller (one-file binary)
#   4) bundle the OwnTone binary + every dylib it dynamically links to,
#      rewriting their install names to @executable_path/../Frameworks/
#   5) ad-hoc codesign so Gatekeeper at least opens it on the build machine
#
# Output: dist/SyncCast.app
#
# Limitations of v0.1: not notarized, not universal2 (host arch only),
# not stripped, no first-run wizard yet. Good enough to double-click and
# verify the architecture works.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DIST="$REPO_ROOT/dist"
APP="$DIST/SyncCast.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
FW_DIR="$CONTENTS/Frameworks"
SIDECAR_DIR="$CONTENTS/Resources/sidecar"
OWNTONE_DIR="$CONTENTS/Resources/owntone"

OWNTONE_PREFIX="$HOME/owntone_data"
OWNTONE_BIN_SRC="$OWNTONE_PREFIX/usr/sbin/owntone"

log() { printf '\033[1;34m[pkg]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[pkg]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS only"
[[ -x "$OWNTONE_BIN_SRC" ]] || fail "OwnTone not built. Run scripts/build-owntone.sh first."
[[ -d "$REPO_ROOT/sidecar/.venv" ]] || fail "Python venv missing. Run scripts/bootstrap.sh first."

# ---- 1) build Swift binary ------------------------------------------------
log "Building Swift menubar binary (release)…"
( cd apps/menubar && swift build -c release )
SWIFT_BIN="$REPO_ROOT/apps/menubar/.build/release/SyncCastMenuBar"
[[ -x "$SWIFT_BIN" ]] || fail "Swift build did not produce $SWIFT_BIN"

# ---- 2) bundle skeleton ---------------------------------------------------
log "Laying out .app bundle at $APP"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$FW_DIR" "$SIDECAR_DIR" "$OWNTONE_DIR"
cp "$SWIFT_BIN" "$MACOS_DIR/SyncCastMenuBar"
cp "$REPO_ROOT/apps/menubar/Resources/Info.plist" "$CONTENTS/Info.plist"
cat > "$CONTENTS/PkgInfo" <<'EOF'
APPL????
EOF

# ---- 3) Python sidecar via PyInstaller ------------------------------------
log "Bundling Python sidecar with PyInstaller…"
"$REPO_ROOT/sidecar/.venv/bin/pip" install -q pyinstaller || true
PYINST="$REPO_ROOT/sidecar/.venv/bin/pyinstaller"
if [[ ! -x "$PYINST" ]]; then
  fail "PyInstaller install failed; check sidecar venv"
fi
( cd sidecar && \
    "$PYINST" --noconfirm --clean --onefile \
        --name syncast-sidecar \
        --paths src \
        --collect-all pyatv \
        --distpath dist-pyinstaller \
        src/syncast_sidecar/__main__.py )
cp "$REPO_ROOT/sidecar/dist-pyinstaller/syncast-sidecar" "$SIDECAR_DIR/syncast-sidecar"
chmod +x "$SIDECAR_DIR/syncast-sidecar"

# ---- 4) OwnTone binary + dylib closure ------------------------------------
log "Bundling OwnTone + dylib closure…"
cp "$OWNTONE_BIN_SRC" "$OWNTONE_DIR/owntone"
# Recursively find the dylib closure starting from OwnTone, rewrite
# install names to @executable_path/../Frameworks/<name>.
"$REPO_ROOT/scripts/_bundle-dylibs.sh" \
    "$OWNTONE_DIR/owntone" \
    "$FW_DIR" \
    "@executable_path/../Frameworks"

# Ship libinotify + the OwnTone resource files (htdocs, default config).
if [[ -d "$OWNTONE_PREFIX/usr/share/owntone" ]]; then
    mkdir -p "$OWNTONE_DIR/share"
    cp -R "$OWNTONE_PREFIX/usr/share/owntone" "$OWNTONE_DIR/share/owntone"
fi

# Ship a config template; the real config goes to ~/Library/Application Support
# at first run.
if [[ -f "$OWNTONE_PREFIX/etc/owntone.conf" ]]; then
    cp "$OWNTONE_PREFIX/etc/owntone.conf" "$OWNTONE_DIR/owntone.conf.template"
fi

# ---- 5) ad-hoc codesign ---------------------------------------------------
log "Ad-hoc codesigning…"
codesign --force --deep --sign - --options runtime "$APP" || true

log "Done: $APP"
ls -la "$APP/Contents/MacOS"
ls -la "$APP/Contents/Resources"
du -sh "$APP"
