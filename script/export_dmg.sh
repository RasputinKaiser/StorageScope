#!/bin/bash
set -euo pipefail

APP_NAME="StorageScope"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
VERSION="${STORAGESCOPE_VERSION:-$(tr -d '[:space:]' <"$VERSION_FILE")}"
DEFAULT_BUILD_ROOT="${TMPDIR:-/tmp}/StorageScope/dmg-build"
BUILD_ROOT="${STORAGESCOPE_DMG_BUILD_DIR:-$DEFAULT_BUILD_ROOT}"
DIST_DIR="$BUILD_ROOT/dist"
STAGE_DIR="$BUILD_ROOT/stage"
EXPORT_DIR="${STORAGESCOPE_EXPORT_DIR:-$ROOT_DIR/exports}"
VOLUME_NAME="${STORAGESCOPE_VOLUME_NAME:-StorageScope}"
DMG_PATH="$EXPORT_DIR/$APP_NAME-$VERSION.dmg"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

cd "$ROOT_DIR"

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "hdiutil is required to create a macOS DMG." >&2
  exit 2
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$EXPORT_DIR"

export STORAGESCOPE_DIST_DIR="$DIST_DIR"
export STORAGESCOPE_BUILD_CONFIGURATION="${STORAGESCOPE_BUILD_CONFIGURATION:-release}"
bash "$ROOT_DIR/script/build_and_run.sh" --build-only >/dev/null

codesign --verify --deep --strict "$APP_BUNDLE"
test -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
test -f "$APP_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"
plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

cp -R "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
# Re-verify staged bundle in case cp -R drops signature/entitlement xattrs.
codesign --verify --deep --strict "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"
cp "$ROOT_DIR/Resources/DMG-README.txt" "$STAGE_DIR/README.txt"

find "$STAGE_DIR" -name ".DS_Store" -delete
xattr -cr "$STAGE_DIR" >/dev/null 2>&1 || true

rm -f "$DMG_PATH" "$DMG_PATH.sha256"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

hdiutil verify "$DMG_PATH" >/dev/null
shasum -a 256 "$DMG_PATH" >"$DMG_PATH.sha256"

echo "$DMG_PATH"
