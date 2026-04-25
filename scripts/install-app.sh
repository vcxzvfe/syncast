#!/usr/bin/env bash
# Install the freshly built SyncCast.app to /Applications and re-sign in
# place. Required because macOS Tahoe's TCC silently denies Screen
# Recording (and other categories) for apps living in non-standard
# paths like /Users/<you>/syncast/dist/.
#
# Use after `./scripts/package-app.sh`. Idempotent — re-running just
# replaces the existing /Applications/SyncCast.app.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/dist/SyncCast.app"
DST="/Applications/SyncCast.app"

log() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -d "$SRC" ]] || fail "no $SRC — run scripts/package-app.sh first"

log "Stopping any running instance"
pkill -9 -f /Applications/SyncCast.app 2>/dev/null || true
pkill -9 -f /Users/.*/syncast/dist/SyncCast.app 2>/dev/null || true
pkill -9 -f syncast-sidecar 2>/dev/null || true
sleep 1

log "Replacing $DST"
rm -rf "$DST"
cp -R "$SRC" "$DST"

log "Removing quarantine attribute"
xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true

# Re-sign in place. install-app.sh deliberately re-runs codesign so the
# signature applies to the FINAL bundle path — codesign's `-deep` mode
# embeds the bundle's own absolute path into resource manifests; signing
# at /Users/.../dist and then moving to /Applications can leave subtle
# resource-rule mismatches.
SIGN_IDENTITY="-"
SIGN_LABEL="ad-hoc"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"SyncCast Dev"'; then
    SIGN_IDENTITY="SyncCast Dev"
    SIGN_LABEL="SyncCast Dev (self-signed)"
fi
log "Re-codesigning with $SIGN_LABEL"
codesign --force --deep --sign "$SIGN_IDENTITY" --identifier io.syncast.menubar "$DST"

log "Verifying signature"
codesign --verify --verbose=2 "$DST" 2>&1 | tail -3

log "Done. Launch with:  open $DST"

cat <<'EOF'

If this is a FIRST install (or the cert just changed), you'll likely
need to grant Screen Recording one more time:

  1. Open SyncCast (System Settings → Privacy → Screen Recording panel
     should appear automatically when the app first calls SCK).
  2. Toggle SyncCast ON.
  3. Click "Quit & Reopen" if prompted.

After that, future rebuilds keep the grant — that's the whole point of
using a stable signing identity.
EOF
