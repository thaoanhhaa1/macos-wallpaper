#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "usage: $0 <WallpaperApp.app|file.dmg> [...]" >&2
  exit 1
fi

for target in "$@"; do
  if [[ ! -e "$target" ]]; then
    echo "Verification target not found: $target" >&2
    exit 1
  fi

  echo "== $(basename "$target") ==" >&2
  xcrun stapler validate "$target"

  if [[ -d "$target" && "$target" == *.app ]]; then
    codesign --verify --deep --strict --verbose=2 "$target"
    signature_info="$(codesign -d --verbose=4 "$target" 2>&1)"
    if [[ "$signature_info" != *"flags="*"runtime"* ]]; then
      echo "Hardened runtime is not enabled for $target" >&2
      exit 1
    fi
    spctl --assess --type execute --verbose=4 "$target"
  else
    spctl --assess --type install --verbose=4 "$target"
  fi

  echo "OK: $(basename "$target")" >&2
done
