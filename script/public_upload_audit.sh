#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
audit_scratch_path="${STORAGESCOPE_AUDIT_SCRATCH_PATH:-${TMPDIR:-/tmp}/StorageScope/public-upload-audit-spm}"

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

python3 - "$candidate_file" "$secret_hits" <<'PY'
import hashlib
import pathlib
import re
import sys

candidate_file = pathlib.Path(sys.argv[1])
secret_hits = pathlib.Path(sys.argv[2])
blocked_identity_hashes = {
    # SHA-256 of a private normalized alphanumeric identity string.
    "b817248613f0cf4b0f4eb4e8abe657a388a5cc5b7af888a60a63e89f25bad262": 12,
}
text_suffixes = {
    "",
    ".c",
    ".css",
    ".entitlements",
    ".h",
    ".html",
    ".json",
    ".md",
    ".plist",
    ".sh",
    ".swift",
    ".txt",
    ".xcprivacy",
    ".yaml",
    ".yml",
}
max_identity_scan_bytes = 2_000_000

hits = []
for raw_candidate in candidate_file.read_text().splitlines():
    candidate = pathlib.Path(raw_candidate)
    if not candidate.is_file():
        continue
    if candidate.suffix.lower() not in text_suffixes:
        continue
    if candidate.stat().st_size > max_identity_scan_bytes:
        continue

    try:
        text = candidate.read_text(errors="ignore")
    except OSError:
        continue

    normalized = re.sub(r"[^a-z0-9]", "", text.lower())
    for blocked_hash, width in blocked_identity_hashes.items():
        for index in range(0, max(0, len(normalized) - width + 1)):
            window = normalized[index:index + width]
            if hashlib.sha256(window.encode()).hexdigest() == blocked_hash:
                hits.append(f"{candidate}: private identity hash match")
                break

if hits:
    with secret_hits.open("a") as handle:
        for hit in hits:
            handle.write(hit + "\n")
PY

if [[ -s "$secret_hits" ]]; then
  echo "possible sensitive/public-unfriendly text found:" >&2
  cat "$secret_hits" >&2
  exit 1
fi

swift test --scratch-path "$audit_scratch_path" >/dev/null
plutil -lint Config/StorageScope.entitlements Resources/PrivacyInfo.xcprivacy >/dev/null
bash -n script/build_and_run.sh script/export_dmg.sh script/package_app_store.sh script/public_upload_audit.sh

echo "public upload audit passed"
