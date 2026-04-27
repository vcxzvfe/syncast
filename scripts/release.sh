#!/usr/bin/env bash
# One-command release for SyncCast.
#
# Reads VERSION (single source of truth), optionally bumps it, syncs the
# version into apps/menubar/Resources/Info.plist, tags the commit, builds
# the .app, zips it, and creates a GitHub Release with the asset attached.
#
# Usage:
#   bash scripts/release.sh [--bump major|minor|patch|alpha-rev] [--draft] [--notes "..."]
#   bash scripts/release.sh --help
#
# Defaults:
#   - No bump (uses VERSION as-is)
#   - Asset uploaded: dist/SyncCast.app.zip
#   - Prerelease flag set automatically when VERSION matches alpha|beta|rc
#   - Minimal default release notes (override with --notes)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION_FILE="$REPO_ROOT/VERSION"
PLIST="$REPO_ROOT/apps/menubar/Resources/Info.plist"

log()  { printf '\033[1;34m[release]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[release]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[release]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- args -----------------------------------------------------------------
BUMP=""
DRAFT="0"
NOTES=""

usage() {
  cat <<'USAGE'
Usage: bash scripts/release.sh [options]

Options:
  --bump <kind>    Bump VERSION before tagging. <kind> is one of:
                       major       0.1.0       -> 1.0.0  (strips prerelease)
                       minor       0.1.0       -> 0.2.0
                       patch       0.1.0       -> 0.1.1
                       alpha-rev   0.1.0-alpha -> 0.1.0-alpha.1
                                   0.1.0-alpha.1 -> 0.1.0-alpha.2
  --draft          Create the GitHub release as a draft.
  --notes "..."    Custom release notes body (default: minimal alpha notice).
  -h, --help       Show this help and exit.

What it does (in order):
  1. Sanity-check working tree (must be clean).
  2. Optionally bump VERSION and commit.
  3. Sync CFBundleShortVersionString in Info.plist (commit if changed).
  4. Tag vX.Y.Z and push tag + main.
  5. Build release Swift binary, run scripts/package-app.sh.
  6. Zip dist/SyncCast.app -> dist/SyncCast.app.zip via ditto.
  7. gh release create with the zip attached.

Prereqs:
  - macOS host with Xcode CLT, Swift, Python venv at sidecar/.venv.
  - OwnTone built (scripts/build-owntone.sh).
  - gh authed (gh auth status).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bump)
      [[ $# -ge 2 ]] || fail "--bump needs a value (major|minor|patch|alpha-rev)"
      BUMP="$2"
      shift 2
      ;;
    --draft)
      DRAFT="1"
      shift
      ;;
    --notes)
      [[ $# -ge 2 ]] || fail "--notes needs a value"
      NOTES="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1 (try --help)"
      ;;
  esac
done

# ---- sanity ---------------------------------------------------------------
[[ -f "$VERSION_FILE" ]] || fail "VERSION file missing at $VERSION_FILE"
[[ -f "$PLIST" ]]        || fail "Info.plist missing at $PLIST"

# Must be inside the git repo root.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not inside a git repo"
GIT_TOPLEVEL="$(git rev-parse --show-toplevel)"
[[ "$GIT_TOPLEVEL" == "$REPO_ROOT" ]] || fail "must be run from repo root ($GIT_TOPLEVEL != $REPO_ROOT)"

# Working tree must be clean (no staged or unstaged changes).
if ! git diff --quiet || ! git diff --cached --quiet; then
  fail "working tree is dirty — commit or stash first"
fi

# gh CLI present + authed.
command -v gh >/dev/null 2>&1 || fail "gh CLI not installed (https://cli.github.com)"
gh auth status >/dev/null 2>&1 || fail "gh not authed — run: gh auth login"

# PyInstaller venv present (package-app.sh would fail later, but warn early).
if [[ ! -d "$REPO_ROOT/sidecar/.venv" ]]; then
  fail "sidecar/.venv missing — run scripts/bootstrap.sh first"
fi

# ---- bump (optional) ------------------------------------------------------
read_version() { tr -d '[:space:]' < "$VERSION_FILE"; }
write_version() {
  printf '%s\n' "$1" > "$VERSION_FILE"
}

bump_version() {
  local cur="$1" kind="$2"
  case "$kind" in
    major)
      # Strip any prerelease suffix, then bump major.
      local base="${cur%%-*}"
      local M="${base%%.*}"
      M=$((M + 1))
      printf '%s.0.0\n' "$M"
      ;;
    minor)
      local base="${cur%%-*}"
      local M="${base%%.*}"
      local rest="${base#*.}"
      local m="${rest%%.*}"
      m=$((m + 1))
      printf '%s.%s.0\n' "$M" "$m"
      ;;
    patch)
      local base="${cur%%-*}"
      local M="${base%%.*}"
      local rest="${base#*.}"
      local m="${rest%%.*}"
      local p="${rest#*.}"
      p=$((p + 1))
      printf '%s.%s.%s\n' "$M" "$m" "$p"
      ;;
    alpha-rev)
      # 0.1.0-alpha       -> 0.1.0-alpha.1
      # 0.1.0-alpha.N     -> 0.1.0-alpha.(N+1)
      # Anything else     -> error
      if [[ "$cur" =~ ^([^-]+)-alpha$ ]]; then
        printf '%s-alpha.1\n' "${BASH_REMATCH[1]}"
      elif [[ "$cur" =~ ^([^-]+)-alpha\.([0-9]+)$ ]]; then
        local b="${BASH_REMATCH[1]}"
        local n="${BASH_REMATCH[2]}"
        n=$((n + 1))
        printf '%s-alpha.%s\n' "$b" "$n"
      else
        fail "alpha-rev: current version '$cur' is not -alpha or -alpha.N"
      fi
      ;;
    "")
      printf '%s\n' "$cur"
      ;;
    *)
      fail "unknown --bump kind: $kind"
      ;;
  esac
}

CURRENT="$(read_version)"
[[ -n "$CURRENT" ]] || fail "VERSION file is empty"

if [[ -n "$BUMP" ]]; then
  NEW_VERSION="$(bump_version "$CURRENT" "$BUMP" | tr -d '[:space:]')"
  if [[ "$NEW_VERSION" != "$CURRENT" ]]; then
    log "Bumping VERSION: $CURRENT -> $NEW_VERSION ($BUMP)"
    write_version "$NEW_VERSION"
    git add "$VERSION_FILE"
    git commit -m "chore: bump version to v$NEW_VERSION"
  else
    warn "bump produced same version ($CURRENT); skipping commit"
  fi
fi

VERSION="$(read_version)"
[[ -n "$VERSION" ]] || fail "VERSION file is empty after bump"
TAG="v$VERSION"

# ---- sync Info.plist ------------------------------------------------------
PLIST_BUDDY="/usr/libexec/PlistBuddy"
[[ -x "$PLIST_BUDDY" ]] || fail "PlistBuddy not found at $PLIST_BUDDY (macOS only)"

CURRENT_PLIST_VER="$("$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || true)"
if [[ "$CURRENT_PLIST_VER" != "$VERSION" ]]; then
  log "Syncing Info.plist CFBundleShortVersionString: $CURRENT_PLIST_VER -> $VERSION"
  "$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  git add "$PLIST"
  git commit -m "chore: sync Info.plist version to v$VERSION"
else
  log "Info.plist version already $VERSION; no sync commit"
fi

# ---- already-released guard ----------------------------------------------
# If HEAD is already at the tag we'd create, abort with a hint.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  EXISTING_TAG_SHA="$(git rev-list -n 1 "$TAG")"
  HEAD_SHA="$(git rev-parse HEAD)"
  if [[ "$EXISTING_TAG_SHA" == "$HEAD_SHA" ]]; then
    fail "tag $TAG already exists at HEAD — already released. Use --bump to make a new release, or 'git tag -d $TAG' to recreate."
  else
    fail "tag $TAG already exists at $EXISTING_TAG_SHA (different from HEAD). Use --bump or 'git tag -d $TAG && git push --delete origin $TAG'."
  fi
fi

# ---- tag + push -----------------------------------------------------------
log "Tagging $TAG"
git tag -a "$TAG" -m "$TAG"

log "Pushing main + tag to origin"
git push origin main
git push origin "$TAG"

# ---- build ----------------------------------------------------------------
log "Building Swift release binary"
( cd "$REPO_ROOT/apps/menubar" && swift build -c release )

log "Running scripts/package-app.sh"
bash "$REPO_ROOT/scripts/package-app.sh"

APP="$REPO_ROOT/dist/SyncCast.app"
[[ -d "$APP" ]] || fail "package-app.sh did not produce $APP"

# ---- zip ------------------------------------------------------------------
log "Creating dist/SyncCast.app.zip via ditto"
(
  cd "$REPO_ROOT/dist"
  rm -f SyncCast.app.zip
  /usr/bin/ditto -c -k --keepParent --sequesterRsrc SyncCast.app SyncCast.app.zip
)
ZIP="$REPO_ROOT/dist/SyncCast.app.zip"
[[ -f "$ZIP" ]] || fail "ditto did not produce $ZIP"
log "Asset: $ZIP ($(du -h "$ZIP" | awk '{print $1}'))"

# ---- gh release -----------------------------------------------------------
PRERELEASE_FLAG=""
if printf '%s' "$VERSION" | grep -qE '(alpha|beta|rc)'; then
  PRERELEASE_FLAG="--prerelease"
fi

DRAFT_FLAG=""
if [[ "$DRAFT" = "1" ]]; then
  DRAFT_FLAG="--draft"
fi

DEFAULT_NOTES="Alpha. Self-signed, experimental, use at your own risk."
RELEASE_NOTES="${NOTES:-$DEFAULT_NOTES}"

log "Creating GitHub release $TAG${PRERELEASE_FLAG:+ (prerelease)}${DRAFT_FLAG:+ (draft)}"
# shellcheck disable=SC2086
gh release create "$TAG" "$ZIP" \
  --title "$TAG" \
  $PRERELEASE_FLAG $DRAFT_FLAG \
  --notes "$RELEASE_NOTES"

RELEASE_URL="$(gh release view "$TAG" --json url --jq '.url' 2>/dev/null || true)"
if [[ -n "$RELEASE_URL" ]]; then
  log "Release URL: $RELEASE_URL"
fi
log "Done: shipped $TAG with asset $(basename "$ZIP")"
