#!/usr/bin/env bash
# Code-sign macOS/iOS dynamic libraries with a Developer ID Application identity,
# so the lib loads into Hardened-Runtime / Library-Validation hosts (DAWs,
# notarized apps). The consuming app re-signs on embed; we do NOT notarize here.
#
# Requires the signing identity to already be imported into a keychain
# (see the `apple-import-cert` step in the workflow).
#
# Usage: sign-macos.sh <dir>
#   signs every .dylib / .framework under <dir>
# Env:   APPLE_SIGN_IDENTITY  e.g. "Developer ID Application: Tanh Lab (TEAMID)"
set -euo pipefail

DIR="$1"
: "${APPLE_SIGN_IDENTITY:?set APPLE_SIGN_IDENTITY}"

sign_one() {
  local f="$1"
  codesign --force --timestamp --options runtime --sign "$APPLE_SIGN_IDENTITY" "$f"
  codesign --verify --strict --verbose=2 "$f"
  echo "signed: $f"
}

found=0
while IFS= read -r -d '' f; do found=1; sign_one "$f"; done \
  < <(find "$DIR" \( -name '*.dylib' -o -name '*.framework' \) -print0)

[ "$found" -eq 1 ] || echo "WARN: no .dylib/.framework found under $DIR (static build?)"
