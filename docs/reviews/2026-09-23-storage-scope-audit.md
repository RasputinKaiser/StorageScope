# StorageScope 0.7.1 broad review

## Scope and provenance

The public latest release is `v0.7.1`, published July 2, 2026. This review targets the current local `codex/phase4` checkout at `03f3937d123edc2f736276679c4b6cee11a8ac06`, including its pre-existing uncommitted changes. It is not an audit of the downloaded release binary.

Three reviewers were configured as `gpt-6-luna`; three implementation workers were configured as `gpt-6-sol`. Exact runtime model slugs were not exposed. Review covered scanner and duplicate integrity, incremental persistence, search and cleanup workflows, packaging, and diagnostic privacy. The original workspace was copied to an isolated validation checkout, and original-file hashes were retained to prevent overwriting concurrent edits on reintegration.

## Baseline

The initial source snapshot built successfully. Its full debug suite ran 241 tests across 26 suites and failed with nine issues:

- One cache byte-budget assertion failed: the approximate size was 596 bytes against the test's 512-byte bound.
- One differential scanner assertion still expected hard-link aliases in duplicate candidates.
- Four rollback assertions still expected recovery to stop after its first restore failure.
- Three known-issue blocks unexpectedly passed because the existing local integrity work had fixed their underlying behavior.

The integrity and rollback implementation was already present before this review. The corresponding tests are strengthened to check the intended behavior directly; no failures are suppressed or converted to expected failures.

## Improvements

- Search navigation resets after changing or clearing the query, changing applicable filters, changing views, or replacing scan results. It cycles through applicable displayed matches and reveals ancestors for Folder Tree results. Find menu availability uses the same scope.
- Duplicate Review All Sizes now shows scanner-retained unverified groups below 100 MB; a 20 MB regression verifies both All Sizes inclusion and >100 MB exclusion.
- Trash review checks for disappeared candidates before presenting an actionable batch and reports the missing targets.
- Duplicate cache byte limits honor the supplied bound. Byte-driven eviction removes enough old entries to satisfy that bound without applying the count-driven eviction floor. Persist recreates an externally deleted cache even when no entries changed.
- App Store packaging defaults to a release build while preserving an explicit configuration override.
- Bookmark failure diagnostics treat paths and error descriptions as private. Notarization console output redacts the supplied image/key paths and preserves tool failure exit statuses.
- Regression coverage directly checks hard-link exclusion, zero-read persisted warm verification, same-size rewrites with restored modification times, replacement aliases, cache bounds, and complete rollback attempts.

## Validation

- Initial integrated run: 249 tests in 26 suites, one failure in a new fixture assertion caused by `/var` versus `/private/var` URL aliases. The test now compares resolved filesystem paths.
- Release duplicate benchmark (`StorageScopeBenchmark --duplicate-proof --repeat 2`): 202.2 MB naive full-hash denominator; cold verification read 4.1 MB (97.99% reduction) with two peak open files; same-process warm verification read zero bytes with zero open files. This is a synthetic scanner fixture without app snapshot callbacks. The repeat reuses its cache instance; disk-reload behavior is checked separately by the proof test.
- Release mock tests, shell syntax, entitlement/privacy plist validation, and whitespace checks passed.
- Final full debug audit passed: 251 tests across 26 suites, plus the public-file scan, packaging mocks, shell syntax, and plist checks.
- An intermediate full-suite run timed out in the pre-existing ranked keyboard-selection test while waiting for its scan. Its isolated two-test suite passed in 0.047 seconds, and the final full concurrent suite passed in 7.188 seconds. No timeout was increased and no test was disabled. The audit now preserves Swift test output instead of discarding it.
- Optimized release app build passed. The assembled app passed `codesign --verify --deep --strict`; its bundle version remains 0.7.1. This local ad hoc signature is not a notarized release.
- Native UI smoke check targeted the exact newly built app bundle, using a synthetic 25-item fixture with display redaction. Confirmed first/next result selection, replacement-query reset to the first visible row, automatic expansion and selection of the ninth item in a 10-item duplicate group, and re-expansion of collapsed Folder Tree ancestors by Cmd+G.
- Mixed missing-target sheet/alert presentation, VoiceOver, and a downloaded release binary were not exercised in this UI pass. Missing-target behavior is covered by store tests.
- Before integration, every original file being changed matched its initial snapshot hash. The 20 changed/new files were copied back and verified byte-for-byte; existing unrelated workspace changes were preserved.

## Release boundary

These are local changes. No release, upload, notarization, push, or pull request was performed. Shell release tests use mocks; their success does not establish Apple signing or notarization acceptance.

## Deferred finding

`DuplicateHashCache.persistThrowing()` now recreates a deleted backing file, but its unchanged-generation fast path does not detect an external replacement or truncation when the path still exists. This is a cache durability/performance follow-up. The review did not establish incorrect duplicate results from this case; a future change should track last-written file metadata and add an external-replacement regression before broadening the persistence contract.
