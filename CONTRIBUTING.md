# Contributing

Thanks for taking a look at StorageScope.

## Development Setup

1. Install Xcode command line tools.
2. Clone the repository.
3. Run `swift test`.
4. Run `./script/build_and_run.sh --verify` for a packaged-app smoke check.

## Before Opening A Pull Request

Run:

```bash
./script/public_upload_audit.sh
./script/build_and_run.sh --verify
```

Keep generated app bundles, DMGs, packages, local scan outputs, Codex state, signing files, and provisioning profiles out of commits.

## Code Style

- Prefer small, focused changes.
- Keep storage scan behavior local-first and sandbox-aware.
- Add tests for scanner, cleanup, duplicate detection, or file-operation safety changes.
- Avoid adding network calls, analytics, or telemetry without a clear user-facing design and privacy update.

## Reporting Issues

Please include macOS version, StorageScope build source, scan scope, expected behavior, actual behavior, and whether the app had folder access or Full Disk Access.
