#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "public upload audit must run inside a git repository" >&2
  exit 2
fi

candidate_file="$(mktemp)"
trap 'rm -f "$candidate_file"' EXIT

{
  git ls-files
  git ls-files --others --exclude-standard
} | sort -u >"$candidate_file"

blocked_patterns=(
  '^\.codex/'
  '^\.build/'
  '^\.swiftpm/'
  '^dist/'
  '^exports/'
  '^DerivedData/'
  '^state\.yaml$'
  '(^|/)\.DS_Store$'
  '\.p12$'
  '\.cer$'
  '\.certSigningRequest$'
  '\.mobileprovision$'
  '\.provisionprofile$'
  '\.xcarchive(/|$)'
  '\.ipa$'
  '\.pkg$'
)

for pattern in "${blocked_patterns[@]}"; do
  if grep -E "$pattern" "$candidate_file" >/dev/null; then
    echo "blocked local artifact would be uploaded:" >&2
    grep -E "$pattern" "$candidate_file" >&2
    exit 1
  fi
done

secret_hits="$(mktemp)"
trap 'rm -f "$candidate_file" "$secret_hits"' EXIT
sensitive_pattern='(secret|token|password|passwd|api[_-]?key|private[_-]?key|client[_-]?secret|bearer|authorization|oauth|stripe|paypal|gumroad|/Users/|@gmail|@icloud|ssh-rsa|BEGIN (RSA|OPENSSH|PRIVATE)|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9])'

while IFS= read -r candidate; do
  if [[ "$candidate" == "script/public_upload_audit.sh" ]]; then
    continue
  fi

  if [[ -f "$candidate" ]]; then
    rg -n -i "$sensitive_pattern" "$candidate" >>"$secret_hits" || true
  fi
done <"$candidate_file"

if [[ -s "$secret_hits" ]]; then
  echo "possible sensitive/public-unfriendly text found:" >&2
  cat "$secret_hits" >&2
  exit 1
fi

swift test >/dev/null
plutil -lint Config/StorageScope.entitlements Resources/PrivacyInfo.xcprivacy >/dev/null
bash -n script/build_and_run.sh script/export_dmg.sh script/package_app_store.sh script/public_upload_audit.sh

echo "public upload audit passed"
