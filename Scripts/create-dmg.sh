#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-}"
DMG="${2:-$ROOT/Build/Wallpaper.dmg}"
STAGE="$ROOT/Build/DMGStage"

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: $0 <WallpaperApp.app> [output.dmg]" >&2
  exit 1
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

ditto "$APP" "$STAGE/WallpaperApp.app"
ln -s /Applications "$STAGE/Applications"
if [[ -f "$ROOT/Distribution/Uninstall Wallpaper.txt" ]]; then
  cp "$ROOT/Distribution/Uninstall Wallpaper.txt" "$STAGE/Uninstall Wallpaper.txt"
fi

hdiutil create \
  -volname "Wallpaper" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG" >&2

echo "$DMG"
