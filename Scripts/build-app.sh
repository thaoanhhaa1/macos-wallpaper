#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT/Build/AppDerivedData"
APP="$DERIVED_DATA/Build/Products/Debug/WallpaperApp.app"
ARCH="$(uname -m)"

xcodebuild \
  -project "$ROOT/WallpaperApp/WallpaperApp.xcodeproj" \
  -scheme WallpaperApp \
  -configuration Debug \
  -destination "platform=macOS,arch=$ARCH" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  build >&2

echo "$APP"
