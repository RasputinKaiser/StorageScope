#!/usr/bin/env bash
set -euo pipefail

APP_NAME="StorageScope"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_DIST_ROOT="${TMPDIR:-/tmp}/StorageScope"
DIST_DIR="${STORAGESCOPE_DIST_DIR:-$DEFAULT_DIST_ROOT/app-store-dist}"
PACKAGE_DIR="${STORAGESCOPE_PACKAGE_DIR:-$DEFAULT_DIST_ROOT/packages}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
PKG_PATH="$PACKAGE_DIR/$APP_NAME.pkg"

if [[ -z "${STORAGESCOPE_SIGN_IDENTITY:-}" ]]; then
  cat >&2 <<'EOF'
Set STORAGESCOPE_SIGN_IDENTITY to your Mac App Store application signing identity.
Example: STORAGESCOPE_SIGN_IDENTITY="3rd Party Mac Developer Application: Your Name (TEAMID)"
EOF
  exit 2
fi

if [[ -z "${STORAGESCOPE_INSTALLER_IDENTITY:-}" ]]; then
  cat >&2 <<'EOF'
Set STORAGESCOPE_INSTALLER_IDENTITY to your Mac App Store installer signing identity.
Example: STORAGESCOPE_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAMID)"
EOF
  exit 2
fi

mkdir -p "$DIST_DIR" "$PACKAGE_DIR"

export STORAGESCOPE_DIST_DIR="$DIST_DIR"
"$ROOT_DIR/script/build_and_run.sh" --build-only >/dev/null

codesign --verify --deep --strict "$APP_BUNDLE"
codesign --display --entitlements :- "$APP_BUNDLE" >/dev/null

rm -f "$PKG_PATH"
productbuild \
  --component "$APP_BUNDLE" /Applications \
  --sign "$STORAGESCOPE_INSTALLER_IDENTITY" \
  "$PKG_PATH"

pkgutil --check-signature "$PKG_PATH" >/dev/null

echo "$PKG_PATH"
