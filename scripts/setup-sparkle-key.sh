#!/usr/bin/env bash
# One-time: generate the Sparkle EdDSA signing key for release signing.
# Run after `swift build` (which resolves Sparkle's tools).
set -euo pipefail

GEN="$(find .build/artifacts -type f -name generate_keys -path '*bin*' | head -n1)"
[[ -n "${GEN}" ]] || { echo "error: generate_keys not found — run 'swift build' first" >&2; exit 1; }

echo "==> Generating a Sparkle EdDSA key (private key stored in your login Keychain)."
echo "    The public key is printed below; add it as the repo variable SPARKLE_PUBLIC_KEY."
echo
"${GEN}"

echo
echo "==> To provide the private key to CI, export it and add it as the secret SPARKLE_PRIVATE_KEY:"
echo "      ${GEN} -x sparkle_private_key.txt      # writes the private key to a file"
echo "      gh secret set SPARKLE_PRIVATE_KEY < sparkle_private_key.txt"
echo "      rm sparkle_private_key.txt             # then delete the local copy"
echo
echo "    And set the public key as a repo variable (non-sensitive):"
echo "      gh variable set SPARKLE_PUBLIC_KEY --body '<the SUPublicEDKey printed above>'"
echo
echo "See docs/UPDATES.md for the full release checklist."
