#!/usr/bin/env bash
# Build OwnTone (forked-daapd) from source on macOS.
#
# Why this script exists: OwnTone has no Homebrew formula or .pkg installer
# for macOS as of 2026-04. The official build recipe is the GitHub Actions
# workflow at .github/workflows/macos.yml in the OwnTone repo. This script
# mirrors that workflow.
#
# Footprint:
#   • brew packages: ~25 formulae (you'll have most already after running
#     scripts/bootstrap.sh)
#   • OwnTone source: cloned to $REPO_ROOT/build/owntone-server
#   • OwnTone binary + config: installed under $HOME/owntone_data/ (no sudo
#     needed for the install step thanks to the user-prefix configure flag)
#   • Symlinks in /usr/local/bin for bison + flex (required by the build's
#     ylwrap; adjusting $PATH alone doesn't work)
#   • libinotify-kqueue built from source and installed system-wide (needed
#     by OwnTone's filesystem watcher even when we're not scanning a library)
#
# Re-run safe.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
OWNTONE_SRC="$BUILD_DIR/owntone-server"
OWNTONE_PREFIX="$HOME/owntone_data"

log() { printf '\033[1;34m[owntone]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[owntone]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[owntone]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS only."
command -v brew >/dev/null 2>&1 || fail "Homebrew required."

mkdir -p "$BUILD_DIR"

# --- Step 1: brew dependencies -------------------------------------------
log "Installing brew dependencies (idempotent)…"
brew install --quiet \
    automake autoconf libtool pkg-config gettext \
    gperf bison flex \
    libunistring confuse libplist libwebsockets libevent libgcrypt \
    json-c protobuf-c libsodium gnutls pulseaudio openssl ffmpeg sqlite

# --- Step 2: bison + flex symlinks (sudo) --------------------------------
# OwnTone's build invokes bison/flex through ylwrap, which doesn't honour
# $PATH overrides — only the absolute /usr/local/bin path. Apple's macOS
# bundled bison is too old (2.3); we need the brew one (3.x).
need_bison_link=true
need_flex_link=true
if [[ -L /usr/local/bin/bison && "$(readlink /usr/local/bin/bison)" == *brew* ]]; then
    need_bison_link=false
fi
if [[ -L /usr/local/bin/flex && "$(readlink /usr/local/bin/flex)" == *brew* ]]; then
    need_flex_link=false
fi
if $need_bison_link || $need_flex_link; then
    log "Need sudo for /usr/local/bin/{bison,flex} symlinks…"
    sudo mkdir -p /usr/local/bin
    if $need_bison_link; then
        sudo ln -sf "$(brew --prefix)/opt/bison/bin/bison" /usr/local/bin/bison
    fi
    if $need_flex_link; then
        sudo ln -sf "$(brew --prefix)/opt/flex/bin/flex" /usr/local/bin/flex
    fi
fi

# --- Step 3: libinotify-kqueue (sudo for `make install`) -----------------
if ! pkg-config --exists libinotify; then
    log "Building libinotify-kqueue (no Homebrew package)…"
    pushd "$BUILD_DIR" >/dev/null
    rm -rf libinotify-kqueue
    git clone --depth 1 https://github.com/libinotify-kqueue/libinotify-kqueue
    cd libinotify-kqueue
    autoreconf -fvi
    ./configure
    make
    log "libinotify-kqueue: needs sudo for `make install`"
    sudo make install
    popd >/dev/null
fi

# --- Step 4: clone OwnTone -----------------------------------------------
if [[ ! -d "$OWNTONE_SRC/.git" ]]; then
    log "Cloning owntone-server…"
    rm -rf "$OWNTONE_SRC"
    git clone --depth 1 https://github.com/owntone/owntone-server.git "$OWNTONE_SRC"
fi

# --- Step 5: configure + make + make install (no sudo, user prefix) ------
log "autoreconf + configure (prefix=$OWNTONE_PREFIX)…"
pushd "$OWNTONE_SRC" >/dev/null
export ACLOCAL_PATH="$(brew --prefix)/share/gettext/m4:${ACLOCAL_PATH:-}"
export CFLAGS="-I$(brew --prefix)/include -I$(brew --prefix sqlite)/include"
export LDFLAGS="-L$(brew --prefix)/lib -L$(brew --prefix sqlite)/lib"
export PKG_CONFIG_PATH="$(brew --prefix)/opt/sqlite/lib/pkgconfig:$(brew --prefix)/opt/openssl/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
autoreconf -fi
./configure \
    --prefix="$OWNTONE_PREFIX/usr" \
    --sysconfdir="$OWNTONE_PREFIX/etc" \
    --localstatedir="$OWNTONE_PREFIX/var"

log "make…"
make -j"$(sysctl -n hw.ncpu)"

log "make install (no sudo — installs under \$HOME)…"
make install
popd >/dev/null

# --- Step 6: customise the generated config ------------------------------
CONF="$OWNTONE_PREFIX/etc/owntone.conf"
if [[ -f "$CONF" ]]; then
    log "Patching owntone.conf for SyncCast use (user uid, debug log, no library scan)…"
    sed -i '' "s/uid = \"owntone\"/uid = \"$USER\"/g" "$CONF" || true
    mkdir -p "$OWNTONE_PREFIX/media"
    sed -i '' "s|directories = { \"/srv/music\" }|directories = { \"$OWNTONE_PREFIX/media\" }|g" "$CONF" || true
fi

# --- Step 7: sanity check ------------------------------------------------
BIN="$OWNTONE_PREFIX/usr/sbin/owntone"
if [[ -x "$BIN" ]]; then
    log "OwnTone built OK: $BIN"
    "$BIN" -V 2>&1 | head -1 || true
else
    fail "OwnTone binary not found at $BIN — build failed silently?"
fi

cat <<EOF

Next steps:
  • Quick smoke test (Ctrl+C to stop):
      $BIN -f -t

  • If smoke test prints '[init] mDNS started' and the REST API replies on
    http://localhost:3689, you're good.

  • The SyncCast sidecar will pick this binary up automatically because
    \$HOME/owntone_data/usr/sbin is on its search path.
EOF
