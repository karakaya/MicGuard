# CLAUDE.md

See [AI_CONTEXT.md](AI_CONTEXT.md) for full project context, architecture, data flows, and contribution guide.

## Quick Reference

```bash
swift build          # Build via SPM
swift test           # Run all tests
scripts/release.sh 1.3   # Cut a release locally: build, notarize, DMG, GitHub release (see RELEASING.md)
```

- The menu-bar UI is a SwiftUI popover (`MicGuard/UI/MenuPopover/`) hosted in an `NSPopover`. State lives on `PopoverViewModel` (`@MainActor ObservableObject`).
- `Package.swift` explicitly lists all source files — update it when adding new files.
- For sliders / continuous controls, commit to `PreferencesManager` on edit-end (mouse-up), not on every tick — the chain `UserDefaults → Combine → CoreAudio` is expensive.
- CoreAudio listener cleanup in `applicationWillTerminate` is critical — `AudioDeviceManager` is set to `nil` so listener removal runs even on force-quit.
- Use `MGLog.debug(...)` for diagnostics — it compiles out in Release. Don't add `print()` calls.
- `NotificationManager` is dormant (bundle-identifier crash outside Xcode).
