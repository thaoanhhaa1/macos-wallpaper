#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "usage: $0 <WallpaperApp.app|file.dmg> [...]" >&2
  exit 1
fi

verify_app() {
  local app="$1"
  local label
  label="$(basename "$app")"

  codesign --verify --deep --strict --verbose=2 "$app"

  local signature_info
  signature_info="$(codesign -d --verbose=4 "$app" 2>&1)"
  if [[ "$signature_info" != *"flags="*"runtime"* ]]; then
    echo "Hardened runtime is not enabled for $label" >&2
    return 1
  fi
  if [[ "$signature_info" != *"Authority=Developer ID Application"* ]]; then
    echo "$label is not signed with a Developer ID Application certificate" >&2
    return 1
  fi

  local debug_files
  debug_files="$(find "$app" \
    \( -name '*.debug.dylib' -o -name '__preview.dylib' -o -name 'wallpaper-fixture.mp4' \) \
    -print -quit)"
  if [[ -n "$debug_files" ]]; then
    echo "Debug-only file present in $label: ${debug_files#"$app"/}" >&2
    return 1
  fi

  local entitlements_file
  entitlements_file="$(mktemp)"
  codesign -d --entitlements :- "$app" > "$entitlements_file" 2>/dev/null || true
  local sandbox_value
  sandbox_value="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$entitlements_file" 2>/dev/null || true)"
  local get_task_allow_value
  get_task_allow_value="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "$entitlements_file" 2>/dev/null || true)"
  rm -f "$entitlements_file"

  if [[ "$sandbox_value" != "true" ]]; then
    echo "App Sandbox is not enabled for $label" >&2
    return 1
  fi
  if [[ "$get_task_allow_value" == "true" ]]; then
    echo "get-task-allow entitlement must not be present in $label" >&2
    return 1
  fi

  spctl --assess --type execute --verbose=4 "$app"
}

verify_dmg() {
  local dmg="$1"
  local mount_point
  mount_point="$(mktemp -d)"

  hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$dmg" >/dev/null

  local app
  app="$(find "$mount_point" -maxdepth 2 -type d -name '*.app' -print -quit)"
  if [[ -z "$app" ]]; then
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    rmdir "$mount_point" 2>/dev/null || true
    echo "No application bundle found in $dmg" >&2
    return 1
  fi

  local status=0
  xcrun stapler validate "$app" || status=$?
  if [[ "$status" -eq 0 ]]; then
    verify_app "$app" || status=$?
  fi

  hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  rmdir "$mount_point" 2>/dev/null || true
  return "$status"
}

for target in "$@"; do
  if [[ ! -e "$target" ]]; then
    echo "Verification target not found: $target" >&2
    exit 1
  fi

  echo "== $(basename "$target") ==" >&2
  xcrun stapler validate "$target"

  if [[ -d "$target" && "$target" == *.app ]]; then
    verify_app "$target"
  elif [[ "$target" == *.dmg ]]; then
    spctl --assess --type install --verbose=4 "$target"
    verify_dmg "$target"
  else
    spctl --assess --type install --verbose=4 "$target"
  fi

  echo "OK: $(basename "$target")" >&2
done
