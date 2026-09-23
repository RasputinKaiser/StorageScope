#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/storagescope-release-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/script" "$TEST_ROOT/bin" "$TEST_ROOT/dist" "$TEST_ROOT/packages"
cp "$ROOT_DIR/script/package_app_store.sh" "$TEST_ROOT/script/package_app_store.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cat >"$TEST_ROOT/script/build_and_run.sh" <<'MOCK'
#!/bin/bash
printf 'build:%s:%s\n' "${STORAGESCOPE_BUILD_CONFIGURATION:-unset}" "$*" >>"$MOCK_CALLS"
exit "${MOCK_BUILD_STATUS:-0}"
MOCK

cat >"$TEST_ROOT/bin/codesign" <<'MOCK'
#!/bin/bash
printf 'codesign:%s\n' "$*" >>"$MOCK_CALLS"
if [[ "${1:-}" == "-dv" ]]; then
  echo 'Authority=Developer ID Application: Mock (TEAMID)' >&2
else
  printf 'diagnostic DMG=%s KEY=%s\n' "${MOCK_DMG:-}" "${MOCK_KEY:-}" >&2
fi
MOCK

cat >"$TEST_ROOT/bin/productbuild" <<'MOCK'
#!/bin/bash
printf 'productbuild:%s\n' "$*" >>"$MOCK_CALLS"
for argument in "$@"; do
  package_path="$argument"
done
touch "$package_path"
MOCK

cat >"$TEST_ROOT/bin/pkgutil" <<'MOCK'
#!/bin/bash
printf 'pkgutil:%s\n' "$*" >>"$MOCK_CALLS"
test -f "$2"
MOCK

cat >"$TEST_ROOT/bin/xcrun" <<'MOCK'
#!/bin/bash
printf 'xcrun:%s\n' "$*" >>"$MOCK_CALLS"
printf 'diagnostic DMG=%s KEY=%s\n' "$MOCK_DMG" "$MOCK_KEY" >&2
if [[ "${1:-}" == "notarytool" ]]; then
  exit "${MOCK_NOTARY_STATUS:-0}"
fi
MOCK
chmod +x "$TEST_ROOT/script/build_and_run.sh" "$TEST_ROOT/bin/"*

export PATH="$TEST_ROOT/bin:$PATH"
export STORAGESCOPE_SIGN_IDENTITY='Mock Application Identity'
export STORAGESCOPE_INSTALLER_IDENTITY='Mock Installer Identity'
export STORAGESCOPE_DIST_DIR="$TEST_ROOT/dist"
export STORAGESCOPE_PACKAGE_DIR="$TEST_ROOT/packages"
export MOCK_CALLS="$TEST_ROOT/calls"

# The package script must select release itself, while retaining the documented
# environment override consumed by build_and_run.sh.
: >"$MOCK_CALLS"
(
  unset STORAGESCOPE_BUILD_CONFIGURATION
  bash "$TEST_ROOT/script/package_app_store.sh" >"$TEST_ROOT/package-output" 2>&1
)
grep -Fqx 'build:release:--build-only' "$MOCK_CALLS" || fail 'package default did not request a release build'
grep -Fq 'productbuild:' "$MOCK_CALLS" || fail 'package step was not reached'
test -f "$TEST_ROOT/packages/StorageScope.pkg" || fail 'mock package was not produced'

: >"$MOCK_CALLS"
STORAGESCOPE_BUILD_CONFIGURATION=debug bash "$TEST_ROOT/script/package_app_store.sh" >"$TEST_ROOT/package-output" 2>&1
grep -Fqx 'build:debug:--build-only' "$MOCK_CALLS" || fail 'explicit build configuration was not preserved'

: >"$MOCK_CALLS"
if MOCK_BUILD_STATUS=23 bash "$TEST_ROOT/script/package_app_store.sh" >"$TEST_ROOT/package-output" 2>&1; then
  fail 'package continued after a build failure'
else
  status=$?
  [[ "$status" -eq 23 ]] || fail "package returned $status instead of build failure 23"
fi
if grep -Fq 'productbuild:' "$MOCK_CALLS"; then
  fail 'package step ran after build failure'
fi

# No real codesign or Apple service is called. Mocks deliberately print both
# private paths so the command-output redactor is exercised as well.
export MOCK_DMG="$TEST_ROOT/private disk image.dmg"
export MOCK_KEY="$TEST_ROOT/private key.p8"
touch "$MOCK_DMG" "$MOCK_KEY"
export APP_STORE_CONNECT_API_KEY_ID='MOCK-KEY-ID-123456'
export APP_STORE_CONNECT_API_ISSUER_ID='MOCK-ISSUER-ID-123456'
export APP_STORE_CONNECT_API_KEY_FILEPATH="$MOCK_KEY"
: >"$MOCK_CALLS"
bash "$ROOT_DIR/script/notarize_dmg.sh" "$MOCK_DMG" >"$TEST_ROOT/notary-output" 2>&1
if grep -Fq "$MOCK_DMG" "$TEST_ROOT/notary-output" || grep -Fq "$MOCK_KEY" "$TEST_ROOT/notary-output"; then
  fail 'notarization console exposed a private path'
fi
grep -Fq '[DMG path]' "$TEST_ROOT/notary-output" || fail 'DMG path redaction was not visible'
grep -Fq '[API key path]' "$TEST_ROOT/notary-output" || fail 'API key path redaction was not visible'
grep -Fq 'xcrun:notarytool submit' "$MOCK_CALLS" || fail 'mock submission was not reached'

: >"$MOCK_CALLS"
if MOCK_NOTARY_STATUS=19 bash "$ROOT_DIR/script/notarize_dmg.sh" "$MOCK_DMG" >"$TEST_ROOT/notary-output" 2>&1; then
  fail 'notarization continued after a submission failure'
else
  status=$?
  [[ "$status" -eq 19 ]] || fail "notarization returned $status instead of submission failure 19"
fi
if grep -Fq "$MOCK_DMG" "$TEST_ROOT/notary-output" || grep -Fq "$MOCK_KEY" "$TEST_ROOT/notary-output"; then
  fail 'failed notarization console exposed a private path'
fi
grep -Fq 'xcrun:notarytool submit' "$MOCK_CALLS" || fail 'failed mock submission was not reached'
if grep -Fq 'xcrun:stapler' "$MOCK_CALLS"; then
  fail 'stapler ran after a failed submission'
fi

echo 'Release packaging and notarization mock tests passed.'
