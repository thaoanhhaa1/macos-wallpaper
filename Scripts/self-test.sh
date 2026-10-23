#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$("$ROOT/Scripts/build.sh" | tail -n 1)"
REPORT="$ROOT/Build/feasibility-report.json"

mkdir -p "$ROOT/Build"

"$APP/Contents/MacOS/WallpaperSpike" --self-test --report "$REPORT"
