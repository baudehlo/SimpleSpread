#!/usr/bin/env bash
# Code-sign an embedded Sparkle.framework inside-out, then it's ready for the
# outer app signature. Usage: ./scripts/sign-sparkle.sh <App.app> <identity> [entitlements.plist]
#   identity "-" = ad-hoc (local builds).
set -euo pipefail

APP_DIR="${1:?app bundle path required}"
IDENTITY="${2:?signing identity required (\"-\" for ad-hoc)}"

FW="${APP_DIR}/Contents/Frameworks/Sparkle.framework"
[[ -d "${FW}" ]] || { echo "error: ${FW} not found (embed Sparkle first)" >&2; exit 1; }

V="${FW}/Versions/B"
# Hardened runtime for Developer ID; harmless for ad-hoc.
OPTS=(--force --options runtime --timestamp)
if [[ "${IDENTITY}" == "-" ]]; then OPTS=(--force); fi

echo "==> Signing Sparkle helpers (inside-out)"
codesign "${OPTS[@]}" --sign "${IDENTITY}" "${V}/XPCServices/Downloader.xpc"
codesign "${OPTS[@]}" --sign "${IDENTITY}" "${V}/XPCServices/Installer.xpc"
codesign "${OPTS[@]}" --sign "${IDENTITY}" "${V}/Autoupdate"
codesign "${OPTS[@]}" --sign "${IDENTITY}" "${V}/Updater.app"
codesign "${OPTS[@]}" --sign "${IDENTITY}" "${FW}"
echo "==> Sparkle signed with identity: ${IDENTITY}"
