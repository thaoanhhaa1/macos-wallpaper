#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT/Build/AppDerivedData"
APP="$DERIVED_DATA/Build/Products/Debug/WallpaperApp.app"
ARCH="$(uname -m)"
SANDBOX="${SANDBOX:-1}"

case "$SANDBOX" in
  0)
    sandbox_settings=(
      "ENABLE_APP_SANDBOX=NO"
      "CODE_SIGN_ENTITLEMENTS="
    )
    ;;
  1)
    sandbox_settings=(
      "ENABLE_APP_SANDBOX=YES"
      "CODE_SIGN_ENTITLEMENTS=WallpaperApp-Sandbox.entitlements"
    )
    ;;
  *)
    echo "SANDBOX must be 0 or 1." >&2
    exit 1
    ;;
esac

xcodebuild \
  -project "$ROOT/WallpaperApp/WallpaperApp.xcodeproj" \
  -scheme WallpaperApp \
  -configuration Debug \
  -destination "platform=macOS,arch=$ARCH" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  "${sandbox_settings[@]}" \
  build >&2

echo "$APP"
