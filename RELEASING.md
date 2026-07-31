# Releasing MicGuard

Everything runs locally — same flow as local-cloud-browser. No CI, no secrets in workflows. Signing identity and notarization credentials live in the login keychain.

## Cutting a release

```bash
scripts/release.sh 1.3
```

The script, in order:

1. Refuses a dirty working tree or an existing tag
2. Runs `swift test`
3. Bumps `CFBundleShortVersionString` to the given version and `CFBundleVersion` by +1 in `MicGuard/App/Info.plist` (source of truth), syncs `project.yml`
4. Builds a universal Release binary (arm64 + x86_64) via `xcodegen` + `xcodebuild`
5. Signs the app with `Developer ID Application: Milan Karakaya (MQXW376WC6)` (hardened runtime)
6. Notarizes (`xcrun notarytool submit --keychain-profile notarytool --wait`) and staples the app
7. Stages app + `/Applications` symlink, builds `MicGuard-<version>.dmg`, signs, notarizes, staples the DMG, verifies with `spctl` (`accepted, source=Notarized Developer ID`)
8. Commits `Release v<version>`, tags `v<version>` at that commit, pushes — tag matches the exact binary
9. Creates the GitHub release with the DMG attached
10. Triggers the tap's `bump.yml` so the Homebrew cask updates immediately; the tap's 6-hourly cron would catch it anyway

## One-time prerequisites (already set up on this machine)

- `Developer ID Application` certificate in the login keychain
- Notarization profile: `xcrun notarytool store-credentials notarytool` (Apple ID + app-specific password, stored in keychain)
- `gh` CLI authenticated

## Naming and versioning conventions

Load-bearing — the Homebrew cask and the tap's bump workflow parse these:

| Thing | Format | Example |
|---|---|---|
| Version | `MAJOR.MINOR` or `MAJOR.MINOR.PATCH` | `1.3` |
| Git tag | `v<version>` | `v1.3` |
| `CFBundleShortVersionString` | equals tag without `v` | `1.3` |
| `CFBundleVersion` | integer, +1 every release | `3` |
| Release asset | `MicGuard-<version>.dmg` | `MicGuard-1.3.dmg` |
| DMG volume name | `MicGuard` | |
| App bundle inside DMG | `MicGuard.app` | |
| GitHub release title | `MicGuard <version>` | `MicGuard 1.3` |
| Homebrew cask | `micguard` in [milan0x/homebrew-tap](https://github.com/milan0x/homebrew-tap) | `brew install --cask milan0x/tap/micguard` |

The tap's bump workflow derives the download URL from the cask's `url` template and the latest release tag — renaming the DMG asset or changing the tag scheme silently breaks `brew install`.
