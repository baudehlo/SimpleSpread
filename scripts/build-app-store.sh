#!/usr/bin/env bash
# Build SimpleSpread for the Mac App Store: no Sparkle (the App Store
# updates it), App Store entitlements, signed for distribution and packaged
# as the .pkg App Store Connect takes. Shares its bundle ID, and its App
# Store record, with the iPad app (Universal Purchase; docs/IPAD.md).
#
# Usage: ./scripts/build-app-store.sh <version> <build-number>
# Environment:
#   TEAM_ID             Apple developer team ID
#   APP_SIGN_IDENTITY   "Apple Distribution: Name (TEAMID)"
#   PKG_SIGN_IDENTITY   "3rd Party Mac Developer Installer: Name (TEAMID)"
#   PROFILE             path to the Mac App Store provisioning profile
#                       (.provisionprofile) for com.kikiplan.simplespread
# Without the signing variables it stops after building an unsigned .app
# (to check the build). Upload the .pkg with Transporter, or:
#   xcrun altool --upload-package SimpleSpread-<version>.pkg --type macos \
#     --apiKey <key id> --apiIssuer <issuer id>
set -euo pipefail

VERSION="${1:?usage: build-app-store.sh <version> <build-number>}"
BUILD="${2:?usage: build-app-store.sh <version> <build-number>}"
APP_NAME="SimpleSpread"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

OUT="build/app-store"
APP_DIR="${OUT}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
PKG="${OUT}/${APP_NAME}-${VERSION}.pkg"

echo "==> Building release binary without Sparkle (arm64 + x86_64)..."
# A separate build directory: the flag changes the package graph.
SIMPLESPREAD_APP_STORE=1 swift build -c release --arch arm64 --arch x86_64 \
  --build-path .build/app-store --product SimpleSpread
BINARY="$(SIMPLESPREAD_APP_STORE=1 swift build -c release --arch arm64 --arch x86_64 \
  --build-path .build/app-store --product SimpleSpread --show-bin-path)/SimpleSpread"

echo "==> Icon..."
if [[ ! -f icon.png ]]; then swift scripts/generate-icon.swift icon.png; fi
rm -rf AppIcon.iconset && mkdir -p AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z $size $size icon.png --out "AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) icon.png --out "AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset

echo "==> Assembling ${APP_DIR}..."
rm -rf "$OUT" && mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "$BINARY" "${CONTENTS}/MacOS/${APP_NAME}"
cp AppIcon.icns "${CONTENTS}/Resources/AppIcon.icns"
# The same privacy manifest as the iPad app: nothing collected, and the
# required-reason APIs (preferences, file dates) are the same on the Mac.
cp iOS/SimpleSpread/PrivacyInfo.xcprivacy "${CONTENTS}/Resources/PrivacyInfo.xcprivacy"
"${SCRIPT_DIR}/write-info-plist.sh" "$APP_DIR" "$VERSION"
PB=/usr/libexec/PlistBuddy
PLIST="${CONTENTS}/Info.plist"
# App Store Connect wants a build number that only goes up, a category,
# and the encryption answer.
"$PB" -c "Set :CFBundleVersion ${BUILD}" "$PLIST"
"$PB" -c "Add :LSApplicationCategoryType string public.app-category.productivity" "$PLIST"
"$PB" -c "Add :ITSAppUsesNonExemptEncryption bool false" "$PLIST"

if [[ -z "${APP_SIGN_IDENTITY:-}" || -z "${PKG_SIGN_IDENTITY:-}" || -z "${PROFILE:-}" || -z "${TEAM_ID:-}" ]]; then
  echo
  echo "Built ${APP_DIR} (unsigned: set TEAM_ID, APP_SIGN_IDENTITY, PKG_SIGN_IDENTITY and PROFILE to sign and package)."
  exit 0
fi

echo "==> Embedding the provisioning profile..."
cp "$PROFILE" "${CONTENTS}/embedded.provisionprofile"

# A profile fresh from Downloads carries com.apple.quarantine, which App
# Store Connect rejects (ITMS-91109). Signing must come after this.
xattr -cr "$APP_DIR"

echo "==> Signing for the App Store..."
ENTITLEMENTS="$(mktemp)"
sed "s/TEAM_ID/${TEAM_ID}/g" entitlements-appstore.plist > "$ENTITLEMENTS"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
  --sign "$APP_SIGN_IDENTITY" "$APP_DIR"
rm -f "$ENTITLEMENTS"
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "==> Packaging ${PKG}..."
productbuild --component "$APP_DIR" /Applications --sign "$PKG_SIGN_IDENTITY" "$PKG"

echo
echo "Done: ${REPO_ROOT}/${PKG}"
echo "Upload it with Transporter, or xcrun altool --upload-package (see the header of this script)."
