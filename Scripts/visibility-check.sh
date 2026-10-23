#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$("$ROOT/Scripts/build.sh" | tail -n 1)"
TOOL="$ROOT/Build/display-capture"
OUT="$ROOT/Build/visibility"
DURATION="${1:-6}"
LEVELS=(belowDesktopIcons aboveDesktopPicture justBelowNormal normal)

mkdir -p "$OUT"
swiftc -O -parse-as-library "$ROOT/Tools/display-capture.swift" -o "$TOOL" >&2

echo "Capturing each strategy for ${DURATION}s. The screen may briefly show the test pattern."
echo "This check requires Screen Recording permission for the terminal."
echo

printf '%-22s %-10s %-12s %-10s %s\n' "strategy" "verdict" "bright-color" "saturated" "display"
for LEVEL in "${LEVELS[@]}"; do
  LOG="$OUT/$LEVEL.log"
  PNG="$OUT/$LEVEL.png"
  STATS="$OUT/$LEVEL-stats.txt"

  "$APP/Contents/MacOS/WallpaperSpike" --demo --duration "$DURATION" --level "$LEVEL" >"$LOG" 2>&1 &
  PID=$!

  DISPLAY_ID=""
  for _ in 1 2 3 4 5; do
    sleep 0.6
    DISPLAY_ID="$(sed -n 's/.*displayID=\([0-9][0-9]*\).*/\1/p' "$LOG" | head -1)"
    [[ -n "$DISPLAY_ID" ]] && break
  done

  if [[ -z "$DISPLAY_ID" ]]; then
    printf '%-22s %s\n' "$LEVEL" "no display id in log"
    wait "$PID" || true
    continue
  fi

  if ! "$TOOL" "$DISPLAY_ID" "$PNG" >"$STATS" 2>&1; then
    screencapture -x -D "$DISPLAY_ID" "$PNG"
    "$TOOL" --analyze "$PNG" >"$STATS" 2>&1
  fi

  wait "$PID" || true

  VERDICT="$(sed -n 's/.*verdict=\([A-Z_]*\).*/\1/p' "$STATS" | tail -1)"
  BRIGHT="$(sed -n 's/.*bright_color=\([0-9.]*\).*/\1/p' "$STATS" | tail -1)"
  SATURATED="$(sed -n 's/.*saturated=\([0-9.]*\).*/\1/p' "$STATS" | tail -1)"
  printf '%-22s %-10s %-12s %-10s %s\n' "$LEVEL" "${VERDICT:-ERROR}" "${BRIGHT:-?}%" "${SATURATED:-?}%" "$DISPLAY_ID"
done

echo
echo "Output: $OUT"
echo "Interpretation: a visible video fixture should report bright-color above 10%."
echo "On macOS 26+, a physical display can show a negative-level window that ScreenCaptureKit/screencapture omit from captures."
echo "If only 'normal' is VISIBLE, do NOT conclude the surface is invisible: run Scripts/demo.sh and confirm on the physical display."
