#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
audit_scratch_path="${STORAGESCOPE_AUDIT_SCRATCH_PATH:-${TMPDIR:-/tmp}/StorageScope/public-upload-audit-spm}"
identity_blocklist_path="${STORAGESCOPE_PUBLIC_BLOCKLIST_FILE:-.codex/public-identity-blocklist.txt}"

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
  '^\.storagescope-'
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
sensitive_pattern='(secret|token|password|passwd|api[_-]?key|private[_-]?key|client[_-]?secret|bearer|authorization|oauth|stripe|paypal|gumroad|/Users/|@gmail|@icloud|ssh-rsa|BEGIN (RSA|OPENSSH|PRIVATE)|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,})'

# Env var NAMES (uppercase ALL_CAPS_WITH_UNDERSCORES in shell scripts) that reference runtime
# credentials the maintainer supplies locally. These match sensitive_pattern via `api[_-]?key`
# but carry no checked-in secret value — they're declared as $VAR or VAR= references in shell.
# Listed here so a future PR can add a credential ref without tripping the audit; expand as new
# runtime-only credentials are introduced.
# Env var NAMES (uppercase ALL_CAPS_WITH_UNDERSCORES) that reference runtime credentials
# the maintainer supplies locally. They match sensitive_pattern via \bapi[_-]?key\b or other
# patterns but carry no checked-in secret value — they're declared as $VAR or VAR= in shell,
# or bullet-listed as the variable name in markdown contribution docs. Listed here so a future
# PR can reference these variables without tripping the audit; expand as new runtime-only
# credentials are introduced. The pattern deliberately omits a file-extension discriminator
# so shell scripts, markdown, and any future doc surface are all covered.
safe_env_var_ref_patterns=(
  '^[^:]+:[0-9]+:.*\bAPP_STORE_CONNECT_API_KEY_(ID|FILEPATH)\b'
  '^[^:]+:[0-9]+:.*\bAPP_STORE_CONNECT_API_ISSUER_ID\b'
  '^[^:]+:[0-9]+:.*\bSTORAGESCOPE_SIGN_IDENTITY\b'
)

while IFS= read -r candidate; do
  if [[ "$candidate" == "script/public_upload_audit.sh" ]]; then
    continue
  fi

  if [[ -f "$candidate" ]]; then
    grep -E -H -n -i "$sensitive_pattern" "$candidate" >>"$secret_hits" || true
  fi
done <"$candidate_file"

# Drop false positives: shell-script lines whose only match is a reference to a known
# runtime-only env var name (no value committed). This preserves the audit's ability to
# catch real hardcoded values while allowing maintainer scripts to reference credentials
# that are supplied in the local shell at release time.
filtered_hits="$(mktemp)"
trap 'rm -f "$candidate_file" "$secret_hits" "$filtered_hits"' EXIT
cp "$secret_hits" "$filtered_hits"
for pattern in "${safe_env_var_ref_patterns[@]}"; do
  grep -vE "$pattern" "$filtered_hits" > "$filtered_hits.tmp" || true
  mv "$filtered_hits.tmp" "$filtered_hits"
done
mv "$filtered_hits" "$secret_hits"

python3 - "$candidate_file" "$secret_hits" "$identity_blocklist_path" <<'PY'
import pathlib
import re
import sys

candidate_file = pathlib.Path(sys.argv[1])
secret_hits = pathlib.Path(sys.argv[2])
identity_blocklist_path = pathlib.Path(sys.argv[3])
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

if not identity_blocklist_path.is_file():
    sys.exit(0)

blocked_tokens = set()
for raw_token in identity_blocklist_path.read_text().splitlines():
    token = raw_token.strip()
    if not token or token.startswith("#"):
        continue
    normalized_token = re.sub(r"[^a-z0-9]", "", token.lower())
    if normalized_token:
        blocked_tokens.add(normalized_token)

if not blocked_tokens:
    sys.exit(0)

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
    for blocked_token in blocked_tokens:
        if blocked_token in normalized:
            hits.append(f"{candidate}: private identity blocklist match")
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
bash -n script/build_and_run.sh script/export_dmg.sh script/package_app_store.sh script/public_upload_audit.sh script/benchmark_scan.sh

echo "public upload audit passed"
