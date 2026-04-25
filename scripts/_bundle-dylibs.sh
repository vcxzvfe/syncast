#!/usr/bin/env bash
# Recursively gather every dylib in the load-time dependency graph of a
# Mach-O binary, copy them into a Frameworks dir, rewrite install names.
#
# Usage:  _bundle-dylibs.sh <root-binary> <frameworks-dir> <new-prefix>
#
# Skips Apple system libraries (/usr/lib, /System/, /Library/Apple/).
# Resolves @rpath/@loader_path/@executable_path heuristically against the
# Homebrew prefix (good enough for our use — OwnTone's deps are all brew).
#
# Compatible with macOS's bash 3.2: no associative arrays. We use a sorted
# file as the visited-set.

set -euo pipefail

ROOT="$1"
FW="$2"
NEW_PREFIX="$3"

[[ -f "$ROOT" ]] || { echo "no such file: $ROOT" >&2; exit 1; }
mkdir -p "$FW"

VISITED="$(mktemp)"
QUEUE="$(mktemp)"
trap 'rm -f "$VISITED" "$QUEUE" "$QUEUE.new"' EXIT

is_system() {
    case "$1" in
        /usr/lib/*|/System/*|/Library/Apple/*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_dep() {
    # Echoes a real filesystem path or nothing.
    local d="$1"
    case "$d" in
        @rpath/*|@loader_path/*|@executable_path/*)
            local base="${d##*/}"
            local cand
            for cand in "$(brew --prefix)/lib/$base" "$(brew --prefix)/Cellar"/*/*/lib/"$base"; do
                if [[ -f "$cand" ]]; then echo "$cand"; return; fi
            done
            return
            ;;
        /*)
            if [[ -f "$d" ]]; then echo "$d"; fi
            return
            ;;
    esac
}

# Seed the queue with the root.
echo "$ROOT" > "$QUEUE"

# BFS until empty.
while [[ -s "$QUEUE" ]]; do
    : > "$QUEUE.new"
    while read -r cur; do
        [[ -z "$cur" ]] && continue
        if grep -qxF -- "$cur" "$VISITED"; then continue; fi
        echo "$cur" >> "$VISITED"
        # otool -L lists deps; first line is the file name itself.
        otool -L "$cur" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
            [[ -z "$dep" ]] && continue
            if is_system "$dep"; then continue; fi
            if [[ "$dep" == "$cur" ]]; then continue; fi
            resolved="$(resolve_dep "$dep")"
            [[ -z "$resolved" ]] && continue
            target="$FW/$(basename "$resolved")"
            if [[ ! -f "$target" ]]; then
                cp -L "$resolved" "$target"
                chmod u+w "$target"
            fi
            # Enqueue the resolved path for further deps.
            echo "$resolved" >> "$QUEUE.new"
        done
    done < "$QUEUE"
    mv "$QUEUE.new" "$QUEUE"
done

# Rewrite install names everywhere.
rewrite() {
    local file="$1"
    local id_basename
    id_basename="$(basename "$file")"
    install_name_tool -id "$NEW_PREFIX/$id_basename" "$file" 2>/dev/null || true
    otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
        [[ -z "$dep" ]] && continue
        if is_system "$dep"; then continue; fi
        if [[ "$dep" == "$file" ]]; then continue; fi
        local base
        base="$(basename "$dep")"
        if [[ -f "$FW/$base" ]]; then
            install_name_tool -change "$dep" "$NEW_PREFIX/$base" "$file" 2>/dev/null || true
        fi
    done
}

rewrite "$ROOT"
for f in "$FW"/*.dylib; do
    [[ -f "$f" ]] || continue
    rewrite "$f"
done

count=$(ls "$FW" 2>/dev/null | wc -l | tr -d ' ')
echo "[bundle-dylibs] copied $count files into $FW"
