#!/usr/bin/env bash
# Insert a signed release <item> into appcast.xml for a new DMG.
# Usage: ./scripts/update-appcast.sh <dmg> <version> <download-url> <appcast.xml> [notes-file]
# Requires SPARKLE_PRIVATE_KEY in the environment (the EdDSA private key string).
set -euo pipefail

DMG="${1:?dmg path required}"
VERSION="${2:?version required}"
DOWNLOAD_URL="${3:?download url required}"
APPCAST="${4:?appcast path required}"
NOTES_FILE="${5:-}"

: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY must be set}"

SIGN_TOOL="$(find .build/artifacts -type f -name sign_update -path '*bin*' | head -n1)"
[[ -n "${SIGN_TOOL}" ]] || { echo "error: sign_update not found — run 'swift build' first" >&2; exit 1; }

# Pass the key via a file (--ed-key-file), matching the `generate_keys -x`
# export format stored in the secret; `-s` (raw string) is deprecated and
# expects a different encoding.
KEYFILE="$(mktemp)"
trap 'rm -f "${KEYFILE}"' EXIT
printf '%s' "${SPARKLE_PRIVATE_KEY}" > "${KEYFILE}"

# e.g.  sparkle:edSignature="…" length="12345"
ATTRS="$("${SIGN_TOOL}" --ed-key-file "${KEYFILE}" "${DMG}")"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

DESCRIPTION=""
if [[ -n "${NOTES_FILE}" && -f "${NOTES_FILE}" ]]; then
  DESCRIPTION="      <description><![CDATA[$(cat "${NOTES_FILE}")]]></description>"$'\n'
fi

ITEM="    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>${PUBDATE}</pubDate>
${DESCRIPTION}      <enclosure url=\"${DOWNLOAD_URL}\" type=\"application/octet-stream\" ${ATTRS} />
    </item>"

# Insert the new (newest) item immediately after <language>en</language>.
python3 - "$APPCAST" "$ITEM" <<'PY'
import sys
path, item = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    xml = f.read()
marker = "<language>en</language>"
idx = xml.index(marker) + len(marker)
xml = xml[:idx] + "\n" + item + xml[idx:]
with open(path, "w", encoding="utf-8") as f:
    f.write(xml)
PY

echo "==> Inserted appcast item for ${VERSION} (${DOWNLOAD_URL})"
