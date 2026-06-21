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


## Notarization (for maintainers)

StorageScope is distributed outside the Mac App Store, so the DMG must be
notarized by Apple before users can open it without a Gatekeeper warning.
Notarization is a maintainer-only workflow and is never run in CI.

### One-time credential setup

1. Sign in to App Store Connect as the team Account Holder or Admin:
   https://appstoreconnect.apple.com/access/integrations/api
2. Create an API key with **Developer ID** access (the **App Manager** role or
   above grants this). The key name is visible only to your team.
3. Download the `AuthKey_<KEY_ID>.p8` file Apple generates. Apple does not let
   you re-download it later — store it somewhere private on your Mac.
4. Note the **Issuer ID** (shown at the top of the API keys page, UUID-shaped)
   and the **Key ID** (UUID-shaped, shown next to the key name).

The `.p8` file and these identifiers are tied to your Apple Developer Program
membership. Rotate the key immediately if any of them are compromised.

### Required environment variables

Export the following in your shell (e.g. in `~/.zshenv` or a per-session
export). Never check them into the repository — `*.p8` files are gitignored.

- `APP_STORE_CONNECT_API_KEY_ID` — UUID-shaped App Store Connect key id
- `APP_STORE_CONNECT_API_ISSUER_ID` — UUID-shaped App Store Connect issuer id
- `APP_STORE_CONNECT_API_KEY_FILEPATH` — absolute path to the downloaded
  `AuthKey_<KEY_ID>.p8` file

### Producing a Developer ID-signed DMG

`script/export_dmg.sh` ad-hoc signs by default. Notarization requires a
Developer ID Application signature, so re-export with the signing identity
set:

```bash
STORAGESCOPE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./script/export_dmg.sh
```

The script prints the path to the resulting DMG (e.g.
`exports/StorageScope-0.3.0.dmg`).

### Submitting to Apple's notary service

With credentials exported and a Developer ID-signed DMG in hand:

```bash
./script/notarize_dmg.sh exports/StorageScope-0.3.0.dmg
```

The script will:

1. Validate the DMG exists and is Developer ID-signed (rejects ad-hoc DMGs).
2. Submit the DMG to `xcrun notarytool` and block on `--wait` until Apple
   finishes processing.
3. Staple the resulting notarization ticket to the DMG via `xcrun stapler`.
4. Re-validate via `xcrun stapler validate` and `codesign --verify`.

On success the DMG is ready for direct distribution.

### Rotating or revoking credentials

If a key is leaked or a maintainer leaves the team, revoke the key in App
Store Connect (Users and Access > Integrations > API Keys), generate a new
one, and update your local environment. Old DMGs that were notarized under
the previous key remain valid; only future submissions are affected.
