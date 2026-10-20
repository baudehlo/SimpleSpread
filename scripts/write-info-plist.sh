#!/usr/bin/env bash
# Write SimpleSpread's Info.plist into an assembled .app bundle.
# The one source of the app's Info.plist, used by scripts/build-app.sh and
# by the release workflow (.github/workflows/build.yml).
# Usage: write-info-plist.sh <path/to/SimpleSpread.app> <version>
set -euo pipefail

APP_DIR="$1"
VERSION="$2"
APP_NAME="SimpleSpread"
BINARY_NAME="SimpleSpread"
BUNDLE_ID="com.kikiplan.simplespread"

PLIST="${APP_DIR}/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Clear dict"                                                 "$PLIST" >/dev/null 2>&1 || true
"$PB" -c "Add :CFBundleName               string ${APP_NAME}"         "$PLIST"
"$PB" -c "Add :CFBundleDisplayName        string ${APP_NAME}"         "$PLIST"
"$PB" -c "Add :CFBundleIdentifier         string ${BUNDLE_ID}"        "$PLIST"
"$PB" -c "Add :CFBundleVersion            string ${VERSION}"          "$PLIST"
"$PB" -c "Add :CFBundleShortVersionString string ${VERSION}"          "$PLIST"
"$PB" -c "Add :CFBundleExecutable         string ${BINARY_NAME}"      "$PLIST"
"$PB" -c "Add :CFBundleIconFile           string AppIcon"             "$PLIST"
"$PB" -c "Add :CFBundlePackageType        string APPL"                "$PLIST"
"$PB" -c "Add :NSHighResolutionCapable    bool   true"                "$PLIST"
"$PB" -c "Add :NSPrincipalClass           string NSApplication"       "$PLIST"
"$PB" -c "Add :LSMinimumSystemVersion     string 14.0"                "$PLIST"
# Document types: xlsx, legacy xls (imported to xlsx), and csv.
"$PB" -c "Add :CFBundleDocumentTypes array"                            "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string Excel Workbook" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Editor" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:0:LSHandlerRank string Default" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array"       "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string org.openxmlformats.spreadsheetml.sheet" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:1:CFBundleTypeName string CSV Document" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:1:CFBundleTypeRole string Editor" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:1:LSHandlerRank string Default" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:1:LSItemContentTypes array"       "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:1:LSItemContentTypes:0 string public.comma-separated-values-text" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:2:CFBundleTypeName string Excel 97-2003 Workbook" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:2:CFBundleTypeRole string Viewer" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:2:LSHandlerRank string Alternate" "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:2:LSItemContentTypes array"       "$PLIST"
"$PB" -c "Add :CFBundleDocumentTypes:2:LSItemContentTypes:0 string com.microsoft.excel.xls" "$PLIST"
