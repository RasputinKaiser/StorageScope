#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
FIXTURE_STALE_MODE="${2:-}"
APP_NAME="StorageScope"
BUNDLE_ID="com.rasputinkaiser.StorageScope"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_DIST_ROOT="${TMPDIR:-/tmp}/StorageScope"
DEFAULT_FIXTURE_ROOT="$HOME/Library/Containers/$BUNDLE_ID/Data/tmp/StorageScope/fixture-scan"
DIST_DIR="${STORAGESCOPE_DIST_DIR:-$DEFAULT_DIST_ROOT/dist}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Config/StorageScope.entitlements"
SIGN_IDENTITY="${STORAGESCOPE_SIGN_IDENTITY:--}"
CODESIGN_OPTIONS="${STORAGESCOPE_CODESIGN_OPTIONS:-runtime}"
PROVISIONING_PROFILE="${STORAGESCOPE_PROVISIONING_PROFILE:-}"
SKIP_SIGNING="${STORAGESCOPE_SKIP_SIGNING:-0}"
FIXTURE_ROOT="${STORAGESCOPE_FIXTURE_ROOT:-$DEFAULT_FIXTURE_ROOT}"

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

clean_bundle_metadata() {
  if ! command -v xattr >/dev/null 2>&1; then
    return
  fi

  for _ in 1 2 3; do
    xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
    while IFS= read -r -d '' bundle_item; do
      xattr -c "$bundle_item" >/dev/null 2>&1 || true
      xattr -d "com.apple.FinderInfo" "$bundle_item" >/dev/null 2>&1 || true
      xattr -d "com.apple.fileprovider.fpfs#P" "$bundle_item" >/dev/null 2>&1 || true
    done < <(find "$APP_BUNDLE" -print0)
    sleep 0.05
  done
}

sign_bundle() {
  if [[ "$SKIP_SIGNING" == "1" ]]; then
    return
  fi

  if ! command -v codesign >/dev/null 2>&1; then
    return
  fi

  local sign_args=(--force --deep --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY")
  if [[ -n "$CODESIGN_OPTIONS" ]]; then
    sign_args=(--force --deep --options "$CODESIGN_OPTIONS" --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY")
  fi

  clean_bundle_metadata
  if ! codesign "${sign_args[@]}" "$APP_BUNDLE"; then
    clean_bundle_metadata
    codesign "${sign_args[@]}" "$APP_BUNDLE"
  fi
}

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" "$APP_RESOURCES/PrivacyInfo.xcprivacy"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
if [[ -n "$PROVISIONING_PROFILE" ]]; then
  cp "$PROVISIONING_PROFILE" "$APP_CONTENTS/embedded.provisionprofile"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>StorageScope</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright (c) 2026 RasputinKaiser. All rights reserved.</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

sign_bundle

open_app() {
  /usr/bin/open -n -F "$@" "$APP_BUNDLE"
}

write_sized_file() {
  local path="$1"
  local size="$2"
  /usr/bin/truncate -s "$size" "$path"
}

prepare_fixture_scan_root() {
  rm -rf "$FIXTURE_ROOT"
  mkdir -p "$FIXTURE_ROOT/Media Projects" "$FIXTURE_ROOT/Caches/BuildCache" "$FIXTURE_ROOT/Downloads" "$FIXTURE_ROOT/Archives" "$FIXTURE_ROOT/Duplicates"

  write_sized_file "$FIXTURE_ROOT/Media Projects/interview-master.mov" 1450000000
  write_sized_file "$FIXTURE_ROOT/Media Projects/render-preview.mov" 560000000
  write_sized_file "$FIXTURE_ROOT/Caches/BuildCache/module-cache.bin" 240000000
  write_sized_file "$FIXTURE_ROOT/Downloads/StorageScope-demo.dmg" 320000000
  write_sized_file "$FIXTURE_ROOT/Archives/release-backup.zip" 180000000
  write_sized_file "$FIXTURE_ROOT/Duplicates/copy-a.bin" 125000000
  cp "$FIXTURE_ROOT/Duplicates/copy-a.bin" "$FIXTURE_ROOT/Duplicates/copy-b.bin"
  touch -t 202401010101 "$FIXTURE_ROOT/Media Projects/interview-master.mov"

  echo "$FIXTURE_ROOT"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --fixture-scan|fixture-scan)
    fixture_path="$(prepare_fixture_scan_root)"
    open_args=(--env "STORAGESCOPE_ENABLE_DEVELOPER_SCAN=1" --env "STORAGESCOPE_DEVELOPER_SCAN_PATH=$fixture_path")
    if [[ "$FIXTURE_STALE_MODE" == "--mark-stale" ]]; then
      open_args+=(--env "STORAGESCOPE_DEVELOPER_MARK_RESULTS_STALE=1")
    fi
    open_app "${open_args[@]}"
    echo "$fixture_path"
    ;;
  --verify|verify)
    if command -v codesign >/dev/null 2>&1; then
      codesign --verify --deep --strict "$APP_BUNDLE"
    fi
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --build-only|build-only)
    echo "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--fixture-scan [--mark-stale]|--verify|--build-only]" >&2
    exit 2
    ;;
esac
