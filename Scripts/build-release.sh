#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="$ROOT/Build/WallpaperApp.xcarchive"
EXPORT_DIR="$ROOT/Build/ReleaseExport"
TEAM_ID="${DEVELOPMENT_TEAM:-}"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-Developer ID Application}"
SANDBOX="${SANDBOX:-1}"

if [[ -z "$TEAM_ID" ]]; then
  echo "DEVELOPMENT_TEAM is required, for example:" >&2
  echo "  DEVELOPMENT_TEAM=ABCDE12345 ./Scripts/build-release.sh" >&2
  exit 1
fi

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

export_options="$EXPORT_DIR/ExportOptions.plist"
cat > "$export_options" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string></string>
	<key>teamID</key>
	<string></string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST

plutil -replace signingCertificate -string "$SIGN_IDENTITY" "$export_options"
plutil -replace teamID -string "$TEAM_ID" "$export_options"

case "$SANDBOX" in
  0)
    echo "WARNING: building an unsandboxed release for local development only." >&2
    echo "Unsandboxed artifacts are rejected by Scripts/verify-release.sh." >&2
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

xcodebuild archive \
  -project "$ROOT/WallpaperApp/WallpaperApp.xcodeproj" \
  -scheme WallpaperApp \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" \
  -quiet \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  "${sandbox_settings[@]}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" >&2

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$export_options" \
  -exportPath "$EXPORT_DIR" \
  -quiet >&2

APP="$EXPORT_DIR/WallpaperApp.app"
if [[ ! -d "$APP" ]]; then
  echo "Export did not produce WallpaperApp.app" >&2
  exit 1
fi

echo "$APP"
