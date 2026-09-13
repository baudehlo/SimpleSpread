#!/usr/bin/env bash
# Build a signed (ad-hoc) SimpleSpread.app and DMG for local use.
# Usage: ./scripts/build-app.sh [version]
#   version defaults to "dev"
set -euo pipefail

VERSION="${1:-dev}"
APP_NAME="SimpleSpread"
BINARY_NAME="SimpleSpread"
BUNDLE_ID="com.kikiplan.simplespread"
DMG_NAME="SimpleSpread-v${VERSION}.dmg"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

APP_DIR="${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"

echo "==> Building release binary (arm64)..."
swift build -c release --arch arm64

echo "==> Generating icon.png..."
if [[ ! -f icon.png ]]; then
  swift scripts/generate-icon.swift icon.png
fi

echo "==> Generating AppIcon.icns..."
rm -rf AppIcon.iconset
mkdir -p AppIcon.iconset
sips -z 16   16   icon.png --out AppIcon.iconset/icon_16x16.png      2>/dev/null
sips -z 32   32   icon.png --out AppIcon.iconset/icon_16x16@2x.png   2>/dev/null
sips -z 32   32   icon.png --out AppIcon.iconset/icon_32x32.png      2>/dev/null
sips -z 64   64   icon.png --out AppIcon.iconset/icon_32x32@2x.png   2>/dev/null
sips -z 128  128  icon.png --out AppIcon.iconset/icon_128x128.png    2>/dev/null
sips -z 256  256  icon.png --out AppIcon.iconset/icon_128x128@2x.png 2>/dev/null
sips -z 256  256  icon.png --out AppIcon.iconset/icon_256x256.png    2>/dev/null
sips -z 512  512  icon.png --out AppIcon.iconset/icon_256x256@2x.png 2>/dev/null
sips -z 512  512  icon.png --out AppIcon.iconset/icon_512x512.png    2>/dev/null
sips -z 1024 1024 icon.png --out AppIcon.iconset/icon_512x512@2x.png 2>/dev/null
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset

echo "==> Assembling ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp ".build/release/${BINARY_NAME}" "${CONTENTS}/MacOS/${BINARY_NAME}"
cp AppIcon.icns "${CONTENTS}/Resources/AppIcon.icns"

PLIST="${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Clear dict"                                                 "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleName               string ${APP_NAME}"         "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName        string ${APP_NAME}"         "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier         string ${BUNDLE_ID}"        "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion            string ${VERSION}"          "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}"          "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable         string ${BINARY_NAME}"      "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile           string AppIcon"             "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType        string APPL"                "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable    bool   true"                "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSPrincipalClass           string NSApplication"       "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion     string 14.0"                "$PLIST"
# Document types: xlsx (viewer/editor) and csv (importer).
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes array"                            "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string Excel Workbook" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Editor" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array"       "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string org.openxmlformats.spreadsheetml.sheet" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:1:CFBundleTypeName string CSV Document" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:1:CFBundleTypeRole string Editor" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:1:LSItemContentTypes array"       "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:1:LSItemContentTypes:0 string public.comma-separated-values-text" "$PLIST"

echo "==> Ad-hoc signing..."
codesign --deep --force --sign - "$APP_DIR"

echo "==> Creating ${DMG_NAME}..."
STAGING="$(mktemp -d)"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_NAME"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_NAME"
rm -rf "$STAGING"

echo
echo "Done: ${REPO_ROOT}/${DMG_NAME}"
echo "To install: open ${DMG_NAME} and drag ${APP_NAME} to Applications."
