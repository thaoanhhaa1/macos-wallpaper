#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT/Build/DerivedData"
APP="$DERIVED_DATA/Build/Products/Debug/WallpaperSpike.app"
ARCH="$(uname -m)"

xcodebuild \
  -project "$ROOT/WallpaperSpike/WallpaperSpike.xcodeproj" \
  -scheme WallpaperSpike \
  -configuration Debug \
  -destination "platform=macOS,arch=$ARCH" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  build >&2

echo "$APP"
