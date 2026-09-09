#!/usr/bin/env bash
# Rebuild Resources/AppIcon.icns from Resources/icon-source.png.
#
# The .icns is COMMITTED, and this script exists so that it is reproducible rather than a binary
# somebody once made -- `bundle.sh` never runs it. Run it when the artwork changes, and commit both
# the source and the result.
#
# Both bundles get the same icon on purpose: the daemon and the menu are one tool with two
# processes, and a user who meets them in Finder or in System Settings should not have to learn that.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SOURCE="$ROOT/Resources/icon-source.png"
OUT="$ROOT/Resources/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ ! -f "$SOURCE" ]]; then
  echo "error: $SOURCE does not exist" >&2
  exit 1
fi

echo "==> cutting the squircle out of $(basename "$SOURCE")"
swiftc -O "$ROOT/Scripts/icon.swift" -o "$WORK/icon"
"$WORK/icon" "$SOURCE" "$WORK/AppIcon.iconset"

echo "==> iconutil"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$OUT"

echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))"
