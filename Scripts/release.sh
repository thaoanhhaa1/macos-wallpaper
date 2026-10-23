#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${MODE:-developer-id}"
TEAM_ID="${DEVELOPMENT_TEAM:-}"

if [[ "$MODE" != "developer-id" ]]; then
  echo "Only the Developer ID distribution mode is implemented." >&2
  echo "Use MODE=developer-id and see DISTRIBUTION.md for the Mac App Store evaluation." >&2
  exit 1
fi

if [[ -z "$TEAM_ID" ]]; then
  echo "DEVELOPMENT_TEAM is required, for example:" >&2
  echo "  DEVELOPMENT_TEAM=ABCDE12345 ./Scripts/release.sh" >&2
  exit 1
fi

SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-Developer ID Application}"

identities="$(security find-identity -v -p codesigning)"
if [[ "$identities" != *"$SIGN_IDENTITY"* ]]; then
  echo "No $SIGN_IDENTITY identity found in the keychain." >&2
  echo "Install the certificate from your Apple Developer account before releasing." >&2
  exit 1
fi

APP="$("$ROOT/Scripts/build-release.sh" | tail -n 1)"
echo "Built and signed: $APP" >&2

"$ROOT/Scripts/notarize.sh" "$APP"

DMG="$("$ROOT/Scripts/create-dmg.sh" "$APP" | tail -n 1)"
echo "Created: $DMG" >&2

"$ROOT/Scripts/notarize.sh" "$DMG"
"$ROOT/Scripts/verify-release.sh" "$APP" "$DMG"

echo "$DMG"
