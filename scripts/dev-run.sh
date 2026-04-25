#!/usr/bin/env bash
# Run SyncCast in dev mode (no notarized .app yet).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log() { printf '\033[1;34m[dev-run]\033[0m %s\n' "$*"; }

# 1. Sidecar in the background.
if [[ -d sidecar/.venv ]]; then
  log "Launching sidecar"
  sidecar/.venv/bin/syncast-sidecar \
    --socket /tmp/syncast-$UID.sock \
    --audio-socket /tmp/syncast-$UID.audio.sock \
    --log-level info &
  SIDECAR_PID=$!
  trap 'kill "$SIDECAR_PID" 2>/dev/null || true' EXIT
fi

# 2. Menubar app in the foreground.
log "swift run SyncCastMenuBar"
( cd apps/menubar && swift run -c debug )
