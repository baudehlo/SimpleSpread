#!/usr/bin/env bash
# Embed Sparkle.framework into a built .app and wire its Info.plist keys.
# Usage: ./scripts/embed-sparkle.sh <App.app> <feed-url> [public-ed-key]
#
# The framework is taken from the resolved SwiftPM binary artifact, so run
# `swift build` (which resolves Sparkle) before calling this.
set -euo pipefail

APP_DIR="${1:?app bundle path required}"
FEED_URL="${2:?appcast feed URL required}"
PUBLIC_KEY="${3:-${SPARKLE_PUBLIC_KEY:-}}"

CONTENTS="${APP_DIR}/Contents"
BINARY="${CONTENTS}/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${CONTENTS}/Info.plist")"

# Locate Sparkle.framework in the SPM artifacts (arch-agnostic slice name).
FRAMEWORK="$(find .build/artifacts -type d -name 'Sparkle.framework' -path '*macos*' | head -n1)"
if [[ -z "${FRAMEWORK}" ]]; then
  echo "error: Sparkle.framework not found under .build/artifacts — run 'swift build' first" >&2
  exit 1
fi

echo "==> Embedding $(basename "${FRAMEWORK}") from ${FRAMEWORK}"
mkdir -p "${CONTENTS}/Frameworks"
rm -rf "${CONTENTS}/Frameworks/Sparkle.framework"
cp -R "${FRAMEWORK}" "${CONTENTS}/Frameworks/Sparkle.framework"

# The SwiftPM binary loads @rpath/Sparkle.framework; point @rpath at Frameworks.
if ! otool -l "${BINARY}" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "${BINARY}"
fi

# Sparkle Info.plist keys.
PLIST="${CONTENTS}/Info.plist"
set_key() { /usr/libexec/PlistBuddy -c "Delete :$1" "${PLIST}" 2>/dev/null || true
            /usr/libexec/PlistBuddy -c "Add :$1 $2" "${PLIST}"; }
set_key "SUFeedURL"              "string ${FEED_URL}"
set_key "SUEnableAutomaticChecks" "bool true"
set_key "SUScheduledCheckInterval" "integer 86400"
# Mandatory for sandboxed apps: launch Sparkle's Installer XPC service to
# perform the in-place update (paired with the mach-lookup entitlements).
set_key "SUEnableInstallerLauncherService" "bool true"
if [[ -n "${PUBLIC_KEY}" ]]; then
  set_key "SUPublicEDKey" "string ${PUBLIC_KEY}"
  echo "==> SUPublicEDKey set"
else
  echo "==> No SPARKLE_PUBLIC_KEY — omitting SUPublicEDKey (dev build; updates won't verify)"
fi

echo "==> Sparkle embedded."
