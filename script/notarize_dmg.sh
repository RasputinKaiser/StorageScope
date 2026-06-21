#!/bin/bash
set -euo pipefail

# notarize_dmg.sh — Submit a Developer ID-signed DMG to Apple's notary service
# and staple the resulting ticket to the DMG.
#
# Usage:
#   ./script/notarize_dmg.sh exports/StorageScope-0.4.0.dmg
#
# Required environment variables (export them in your shell — never commit):
#   APP_STORE_CONNECT_API_KEY_ID       App Store Connect API key id (UUID-shaped)
#   APP_STORE_CONNECT_API_ISSUER_ID    App Store Connect issuer id (UUID-shaped)
#   APP_STORE_CONNECT_API_KEY_FILEPATH Path to the AuthKey_<KEY_ID>.p8 file

DMG_PATH="${1:-}"

if [[ $# -lt 1 ]]; then
  cat >&2 <<'EOF'
usage: ./script/notarize_dmg.sh <path-to-dmg>

Submits a Developer ID-signed DMG to Apple's notary service via xcrun notarytool,
then staples the notarization ticket and validates the result.

Requires the following environment variables to be exported:
  APP_STORE_CONNECT_API_KEY_ID
  APP_STORE_CONNECT_API_ISSUER_ID
  APP_STORE_CONNECT_API_KEY_FILEPATH

Produce a Developer ID-signed DMG first:
  STORAGESCOPE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./script/export_dmg.sh
EOF
  exit 2
fi

if [[ -z "$DMG_PATH" ]]; then
  echo "DMG path argument is required." >&2
  exit 2
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG does not exist: $DMG_PATH" >&2
  exit 2
fi

if [[ "$DMG_PATH" != *.dmg ]]; then
  echo "Path must end in .dmg: $DMG_PATH" >&2
  exit 2
fi

# --- Validate App Store Connect credentials -------------------------------
# The script reads credentials only from the environment; it will never accept
# them on the command line or from a file checked into the repo.
REQ_VARS=(
  APP_STORE_CONNECT_API_KEY_ID
  APP_STORE_CONNECT_API_ISSUER_ID
  APP_STORE_CONNECT_API_KEY_FILEPATH
)
missing=()
for var in "${REQ_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    missing+=("$var")
  fi
done

if [[ ${#missing[@]} -gt 0 ]] || [[ ! -f "${APP_STORE_CONNECT_API_KEY_FILEPATH:-}" ]]; then
  cat >&2 <<'EOF'
Missing App Store Connect notary credentials.

Export the following before running this script (do not commit them):
  APP_STORE_CONNECT_API_KEY_ID       UUID-shaped issuer key id
  APP_STORE_CONNECT_API_ISSUER_ID   UUID-shaped issuer id
  APP_STORE_CONNECT_API_KEY_FILEPATH Path to the AuthKey_<KEY_ID>.p8 file

Generate a key with Developer ID access at:
  https://appstoreconnect.apple.com/access/integrations/api
EOF
  exit 2
fi

# Redact identity strings before echoing to avoid leaking credentials in logs.
redact() {
  local value="$1"
  if [[ ${#value} -le 8 ]]; then
    echo "***"
  else
    echo "${value:0:8}..."
  fi
}

echo "Notarizing DMG: $DMG_PATH"
echo "  API key id:   $(redact "$APP_STORE_CONNECT_API_KEY_ID")"
echo "  Issuer id:    $(redact "$APP_STORE_CONNECT_API_ISSUER_ID")"
echo "  Key filepath: $APP_STORE_CONNECT_API_KEY_FILEPATH"

# --- Verify DMG is Developer ID-signed (not ad-hoc) ------------------------
if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign is required to verify the DMG signature." >&2
  exit 2
fi

if ! codesign --verify --deep --strict "$DMG_PATH" 2>/dev/null; then
  cat >&2 <<'EOF'
DMG must be Developer ID-signed before notarization.
Re-export with STORAGESCOPE_SIGN_IDENTITY set, e.g.:
  STORAGESCOPE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./script/export_dmg.sh
EOF
  exit 2
fi

# Ad-hoc signed DMGs may pass codesign --verify for a `-` identity but are not
# acceptable to notarytool. Verify a Developer ID Application authority is present.
sign_authority="$(codesign -dv --verbose=2 "$DMG_PATH" 2>&1 \
  | grep -o 'Developer ID Application.*' || true)"
if [[ -z "$sign_authority" ]]; then
  cat >&2 <<'EOF'
DMG must be Developer ID-signed before notarization.
Re-export with STORAGESCOPE_SIGN_IDENTITY set, e.g.:
  STORAGESCOPE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./script/export_dmg.sh
EOF
  exit 2
fi

echo "DMG signature verified: $sign_authority"

# --- Submit to Apple's notary service --------------------------------------
# --wait blocks until Apple finishes processing the submission.
echo "Submitting to Apple's notary service..."
xcrun notarytool submit "$DMG_PATH" \
  --key "$APP_STORE_CONNECT_API_KEY_FILEPATH" \
  --key-id "$APP_STORE_CONNECT_API_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_API_ISSUER_ID" \
  --wait

# --- Staple the notarization ticket ----------------------------------------
echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

# --- Verify notarization + signing -----------------------------------------
echo "Validating staple and signature..."
xcrun stapler validate "$DMG_PATH"
codesign --verify --deep --strict "$DMG_PATH"

echo "Notarization complete."
echo "$DMG_PATH"
