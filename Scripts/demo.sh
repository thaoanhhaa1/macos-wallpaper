#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$("$ROOT/Scripts/build.sh" | tail -n 1)"

LEVEL="${1:-belowDesktopIcons}"
DISPLAY_ID="${2:-}"
DURATION="${3:-20}"

ARGS=(--demo --duration "$DURATION" --level "$LEVEL")
if [[ -n "$DISPLAY_ID" ]]; then
  ARGS+=(--display "$DISPLAY_ID")
fi

echo "Showing the test pattern for ${DURATION}s at level '$LEVEL'. Watch the desktop, then report what you see."
"$APP/Contents/MacOS/WallpaperSpike" "${ARGS[@]}"
