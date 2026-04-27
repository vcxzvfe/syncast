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
mkdir -p "$RES_DIR"
cp -f "$REPO_ROOT/apps/menubar/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
# SwiftPM resource bundle (Assets.xcassets — menubar template image)
# Bundle.module loads from <binary-dir>/<Target>_<Target>.bundle. We add a
# minimal Info.plist at root so codesign accepts the bundle as shallow.
SPM_BUNDLE="$REPO_ROOT/apps/menubar/.build/release/SyncCastMenuBar_SyncCastMenuBar.bundle"
if [[ -d "$SPM_BUNDLE" ]]; then
  DEST_BUNDLE="$MACOS_DIR/SyncCastMenuBar_SyncCastMenuBar.bundle"
  cp -R "$SPM_BUNDLE" "$DEST_BUNDLE"
  cat > "$DEST_BUNDLE/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIdentifier</key><string>com.syncast.SyncCastMenuBar.resources</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>SyncCastMenuBar_SyncCastMenuBar</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleSignature</key><string>????</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
fi
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
    "@executable_path/../../Frameworks"

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
# NOTE: do NOT pass --options runtime for ad-hoc dev builds. On macOS Tahoe
# the combination "ad-hoc + hardened runtime" causes TCC to auto-deny
# microphone / screen-recording requests without showing a prompt. For a
# real distribution build we'd sign with a Developer ID + notarize, which
# does NEED hardened runtime. Track that for the v1 .pkg release.
# Pick the strongest stable signing identity we have.
#
# 1) Apple Developer ID — best, but most users don't have one.
# 2) "SyncCast Dev" — a self-signed Code Signing cert from Keychain
#    Assistant. With this, TCC anchors permission grants to the cert
#    identity (not per-build CDHash), so Screen Recording, Microphone,
#    etc. survive every rebuild. Strongly recommended for development.
# 3) Ad-hoc (-) — the fallback. Works once but TCC re-prompts on every
#    rebuild because each ad-hoc CDHash is treated as a fresh app.
SIGN_IDENTITY="-"
SIGN_LABEL="ad-hoc (TCC will re-prompt every rebuild)"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"SyncCast Dev"'; then
    SIGN_IDENTITY="SyncCast Dev"
    SIGN_LABEL="self-signed cert: SyncCast Dev (TCC stable across rebuilds)"
fi

log "Codesigning with $SIGN_LABEL"
codesign --force --deep --sign "$SIGN_IDENTITY" --identifier io.syncast.menubar "$APP" || true

log "Done: $APP"
ls -la "$APP/Contents/MacOS"
ls -la "$APP/Contents/Resources"
du -sh "$APP"
