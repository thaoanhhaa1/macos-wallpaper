#!/usr/bin/env bash
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-wallpaper-notary}"

if [[ "$#" -eq 0 ]]; then
  echo "usage: $0 <WallpaperApp.app|file.dmg> [...]" >&2
  exit 1
fi

for target in "$@"; do
  if [[ ! -e "$target" ]]; then
    echo "Notarization target not found: $target" >&2
    exit 1
  fi

  submit_target="$target"
  temporary_zip=""

  if [[ -d "$target" && "$target" == *.app ]]; then
    temporary_zip="$(mktemp -d)/$(basename "$target").zip"
    ditto -c -k --keepParent "$target" "$temporary_zip"
    submit_target="$temporary_zip"
  fi

  echo "Submitting $(basename "$target") for notarization…" >&2
  xcrun notarytool submit "$submit_target" \
    --keychain-profile "$PROFILE" \
    --wait

  if [[ -n "$temporary_zip" ]]; then
    rm -rf "$(dirname "$temporary_zip")"
  fi

  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
  echo "Notarized and stapled: $target" >&2
done
