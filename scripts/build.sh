#!/usr/bin/env bash
# Build all Swift packages and verify Python sidecar imports cleanly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }

build_pkg() {
  local pkg="$1"
  log "swift build  in  $pkg"
  ( cd "$pkg" && swift build -c debug )
}

run_tests() {
  local pkg="$1"
  log "swift test   in  $pkg"
  ( cd "$pkg" && swift test --parallel )
}

build_pkg core/discovery
build_pkg core/router
build_pkg tools/syncast-discover
build_pkg apps/menubar

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  run_tests core/discovery
  run_tests core/router
fi

if [[ -d sidecar/.venv ]]; then
  log "Python sidecar import smoke test"
  sidecar/.venv/bin/python -c "import syncast_sidecar; print('ok', syncast_sidecar.__version__)"
  if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
    log "pytest"
    ( cd sidecar && .venv/bin/pytest -q )
  fi
fi

log "all builds OK"
