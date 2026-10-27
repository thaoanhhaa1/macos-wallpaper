#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "release policy violation: $*" >&2
  exit 1
}

if git ls-files | grep -Eq '(^|/)(Build|DerivedData)/|\.(app|dmg|xcarchive)(/|$)'; then
  fail "build artifacts must never be committed to the repository"
fi

grep -q 'Refusing to release an unsandboxed build' Scripts/release.sh \
  || fail "Scripts/release.sh must refuse unsandboxed releases"
grep -q 'SANDBOX:-1' Scripts/release.sh \
  || fail "Scripts/release.sh must default to a sandboxed release"

for script in Scripts/build-release.sh Scripts/build-app.sh; do
  grep -q 'SANDBOX="${SANDBOX:-1}"' "$script" \
    || fail "$script must default SANDBOX to 1"
done

grep -q 'com.apple.security.app-sandbox' Scripts/verify-release.sh \
  || fail "Scripts/verify-release.sh must require the App Sandbox entitlement"
grep -q 'com.apple.security.get-task-allow' Scripts/verify-release.sh \
  || fail "Scripts/verify-release.sh must reject the get-task-allow entitlement"
grep -q 'codesign --verify --deep --strict' Scripts/verify-release.sh \
  || fail "Scripts/verify-release.sh must verify the code signature"

grep -q 'verify-release.sh' Scripts/create-dmg.sh \
  || fail "Scripts/create-dmg.sh must verify the app before packaging"

/usr/libexec/PlistBuddy \
  -c "Print :com.apple.security.app-sandbox" \
  WallpaperApp/WallpaperApp-Sandbox.entitlements 2>/dev/null \
  | grep -q 'true' \
  || fail "the sandbox entitlements must enable com.apple.security.app-sandbox"

echo "Release policy checks passed." >&2
