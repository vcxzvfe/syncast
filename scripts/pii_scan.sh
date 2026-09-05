#!/usr/bin/env bash
# scripts/pii_scan.sh — fail the build if personal information reached a
# tracked file.
#
# This repository is public. Nothing tracked here — docs, ADRs, code comments,
# tests, fixtures — may carry a real person's name, a home directory path, a
# private LAN address, a real hardware MAC or CoreAudio UID, or a mDNS
# hostname. This script is the mechanical half of that rule; the judgement
# half is still a human reading the diff.
#
# Usage:
#   bash scripts/pii_scan.sh            # scan tracked files
#   bash scripts/pii_scan.sh --staged   # scan the staged snapshot instead
#
# Exit codes:
#   0  clean
#   1  at least one non-allowlisted hit (the hits are printed to stderr)
#
# Allowlist: scripts/pii_allowlist.txt — one "path-prefix:regex" per line,
# '#' comments. A hit is suppressed only when its file matches the path prefix
# AND its line matches the regex. Keep the list short and justify every entry.
#
# Two things learned the hard way and encoded here:
#   * Apple's git grep does not honour `\b`, so patterns use explicit
#     character classes rather than word boundaries.
#   * 学校 ("school") is a substring of 声学校准 ("acoustic calibration"),
#     which appears throughout the Chinese research notes. It is therefore
#     matched only as 在学校 / 学校里 / 学校的.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

ALLOWLIST="${PII_ALLOWLIST:-scripts/pii_allowlist.txt}"

# --- patterns -----------------------------------------------------------
# POSIX extended regex, matched case-sensitively unless the class says
# otherwise (so that e.g. a legitimate CamelCase identifier is not caught by
# a lowercase-only pattern).
PATTERNS=(
  # names / account short name
  '[Zz]ifan'
  '<you>'
  '<you>de[A-Za-z-]*'
  # home directory paths — the anonymised forms are allowlisted
  '/Users/[A-Za-z0-9._-]+/'
  # e-mail
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.(com|org|net|at|edu|io|dev)'
  # private LAN, link-local, tailscale, mDNS hostnames
  '192\.168\.[0-9]{1,3}\.[0-9]{1,3}'
  '10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
  '172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}'
  '[A-Za-z0-9-]+\.ts\.net'
  '[A-Za-z0-9-]+\.local[^a-zA-Z_]'
  # known real hardware identifiers that were once in this tree
  '00000000-0000-0000-0000-000000000001'
  '5E02142BB71[01]'
  '5[Ee]:02:14:2[Bb]:[Bb]7:1[01]'
  '6694[Dd]85[Bb]{3}1[Ee]'
  '66:94:[Dd]8:5[Bb]:[Bb][Bb]:1[Ee]'
  '2202428899329|2202428899329'
  '10336302135476[89]'
  '22[Dd][Dd]023473[Dd][Dd]'
  '[Dd][Cc][Aa]3[Aa]20812[Aa]3'
  'Sound-6853'
  # workplace / city / the owner's routine
  '<workplace>'
  '<city>'
  '<city>'
  '在学校|学校里|学校的'
  '办公室'
  '宿舍'
  # generic shapes — these catch NEW hardware, not just the known values
  '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}'
  '[0-9A-F]{8}-0000-0000-[0-9A-F]{4}-[0-9A-F]{12}'
)

# --- scan ---------------------------------------------------------------
if [ "${1:-}" = "--staged" ]; then
  GREP() { git grep -n -I -E --cached -e "$1" -- "${@:2}"; }
  SCOPE="staged snapshot"
else
  GREP() { git grep -n -I -E -e "$1" -- "${@:2}"; }
  SCOPE="tracked files"
fi

tmp="$(mktemp)"
filtered="$(mktemp)"
trap 'rm -f "$tmp" "$filtered"' EXIT

for p in "${PATTERNS[@]}"; do
  # A pattern with no match exits 1; that is the normal case, not an error.
  GREP "$p" . 2>/dev/null >>"$tmp" || true
done

# This script must never report itself or its allowlist: both necessarily
# contain the patterns they exist to forbid.
sort -u "$tmp" \
  | grep -v -e '^scripts/pii_scan\.sh:' -e '^scripts/pii_allowlist\.txt:' \
  >"$filtered" || true

if [ ! -s "$filtered" ]; then
  echo "pii_scan: clean ($SCOPE)"
  exit 0
fi

# Drop allowlisted lines.
while IFS= read -r line; do
  file="${line%%:*}"
  allowed=0
  if [ -f "$ALLOWLIST" ]; then
    while IFS= read -r rule; do
      case "$rule" in ''|'#'*) continue;; esac
      rpath="${rule%%:*}"
      rre="${rule#*:}"
      case "$file" in
        "$rpath"*)
          if printf '%s\n' "$line" | grep -Eq -- "$rre"; then
            allowed=1
            break
          fi
          ;;
      esac
    done <"$ALLOWLIST"
  fi
  [ "$allowed" -eq 1 ] || printf '%s\n' "$line"
done <"$filtered" >"$tmp"

if [ -s "$tmp" ]; then
  echo "pii_scan: FAIL — personal information in $SCOPE:" >&2
  cat "$tmp" >&2
  echo >&2
  echo "This repository is public. Replace the values above with neutral" >&2
  echo "placeholders, or add a justified entry to $ALLOWLIST." >&2
  exit 1
fi

echo "pii_scan: clean ($SCOPE, allowlist applied)"
