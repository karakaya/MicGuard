# AI Context for MicGuard

This file provides context for AI assistants working on this codebase. If you're using Claude Code, Cursor, Copilot, or similar tools — this is for you.

## Overview

Native macOS menu bar app (Swift, AppKit shell + SwiftUI popover, CoreAudio). Prevents OS and apps from hijacking audio device selection or volume levels. Zero external dependencies.

**Build:** `swift build` | **Test:** `swift test` | **Run:** Xcode Cmd+R

## Architecture

Layered components with dependency injection and Combine-based reactive communication. UI is a SwiftUI popover hosted in an `NSPopover` attached to an `NSStatusItem`.

**Initialization order** (`AppDelegate.applicationDidFinishLaunching`):
1. `AudioDeviceManager` — CoreAudio wrapper (device enumeration, volume control, listener registration, publishes `devicesChangedPublisher` / `defaultInputChangedPublisher` / `defaultOutputChangedPublisher`)
2. `DeviceWatchdog` and `OutputDeviceWatchdog` — both subclass `BaseDeviceWatchdog`; enforce preferred device via priority-ordered list, with optional auto-yield on repeated override and auto-resume on top-priority pick
3. `VolumeGuard` — enforces target input volume using CoreAudio property listeners
4. `ActivityMonitor` — detects mic-in-use state via CoreAudio running state + polling fallback; supports `overrideMonitoredDevice` so the On Air indicator stays correct when the locked device differs from the system default
5. `StatusBarController` — owns the `NSStatusItem`, `NSPopover`, `OnAirIndicator`, and constructs `PopoverViewModel` for the SwiftUI UI

**Source layout:**
- `MicGuard/App/` — Entry point and lifecycle (`AppDelegate` coordinates everything)
- `MicGuard/Core/` — `AudioDeviceManager`, `DeviceWatchdog` (file contains `BaseDeviceWatchdog`, `DeviceWatchdog`, `OutputDeviceWatchdog`), `VolumeGuard`, `ActivityMonitor`, `ProcessMonitor`
- `MicGuard/UI/` — `StatusBarController` (thin shell, ~220 lines), `OnAirIndicator` (menu-bar icon states, flash labels, pulse)
- `MicGuard/UI/MenuPopover/` — `PopoverViewModel` (`@MainActor ObservableObject` bridging managers to SwiftUI), `PopoverContentView` (tabbed root view: Input / Output / Settings), `DevicePriorityListView` (drag-reorderable device list)
- `MicGuard/Utilities/` — `PreferencesManager`, `StatsManager`, `NotificationManager` (dormant), `MGLog` (debug-only logger, compiled out in Release)
- `MicGuardTests/Mocks/` — `MockAudioDeviceManager` for protocol-based testing

## Data Flows

**Device hijack prevention:** User sets device priority → watchdog subscribes to `defaultInputChangedPublisher` / `defaultOutputChangedPublisher` → CoreAudio fires on device change → watchdog checks against priority list → calls `setDefaultInputDevice()` / `setDefaultOutputDevice()` → fires `onDeviceHijackBlocked` → stats increment + `INPUT HELD` / `OUTPUT HELD` flash on the status item.

**Master pause** (`appPaused` preference, persisted): one-tap kill switch at the top of the popover. Stops both watchdogs and the volume guard, suppresses auto-switch and per-device output volume, and shows a slashed/dimmed menu-bar mic (`OnAirIndicator.setAppPaused`). Every enforcement start-path in `AppDelegate` guards on it; ActivityMonitor keeps running (the On Air indicator is passive observation). Resume re-runs `applyStoredPreferences()`.

**Smart protection (consent-based yield):**
- *Fight detection* (always on; the old toggle was removed): CoreAudio can't attribute a default-device change to a user vs. an app, so the watchdog NEVER yields silently — a silent yield would surrender to the exact hijackers (Zoom/Teams retry loops) the app exists to block. After repeated overrides hit the threshold, it fires `onFightDetected` and keeps enforcing; the popover shows a `FightOfferBanner` ("Keep holding" / "Use X"). Only an explicit user choice calls `yieldNow()`.
- *Yield state* is first-class: `watchdogYieldStateChanged` notifications keep `PopoverViewModel.isInputYielded/isOutputYielded` truthful (status line shows "Paused" + Resume button, never a false "Enforcing"). Yield survives priority-list edits (AppDelegate updates a running watchdog in place instead of stop/start). `handleInputAutoSwitch`/`handleOutputAutoSwitch` skip while yielded. Cleared via the `userRequestedResumeInputProtection` / `userRequestedResumeOutputProtection` notifications (popover Resume/Re-apply buttons, right-click menu, or clicking a device row — a deliberate pick re-arms the lock).
- *Auto-resume* (`autoResumeOnTopPriorityPick`, default off): resumes only when the new default is strictly priority #1 (resolved through name matching), never on the best-available or fallback device, and never inside the device-list flux window.
- *Unsettable fallthrough*: when `setDefaultDevice` reports success but the default doesn't move (macOS silently refuses Teams Audio / BlackHole / aggregates), the watchdog counts the failure and after 2 skips that device for the session, falling through to the next priority entry instead of retrying forever. Counts reset on device-list changes.

**Volume lock:** `VolumeGuard` attaches a CoreAudio listener to the device volume property → detects drift beyond tolerance (`0.01`) → debounces (default 2.5s, with a hard deadline: continuous churn such as conferencing auto-gain cannot postpone the correction past first-drift + interval) → corrects volume → anti-fight throttle (max 10 corrections per 5s window). On a default-device switch it re-applies the target after a 0.5s settle, so a device left at the wrong gain doesn't sit there until something else trips the listener.

**Smart reset:** `ActivityMonitor` checks `isDeviceRunning` (device-level, not per-app) → when mic stops → `onMeetingEnded` fires → if strategy is `resetWhenMicStops` and current volume < target → resets volume.

**Per-device output volume:** When `defaultOutputChangedPublisher` fires, `AppDelegate` looks up a per-UID target via `preferencesManager.outputDeviceVolume(for:)` and sets the device volume **once** (set-on-activation; no continuous enforcement). Lets users keep wildly different levels for headphones vs. speakers without rebalancing every switch.

**Preference propagation:** UI change → `PreferencesManager` writes UserDefaults + publishes key via `preferencesChangedPublisher` → `AppDelegate.handlePreferenceChange(key:)` dispatches to the right guard component. A few legacy `NotificationCenter` names (`preferredInputDeviceChanged`, `preferredOutputDeviceChanged`) are still used for device-order updates.

## Where to Add New Code

**New enforcement feature:** Add to `MicGuard/Core/`. Create protocol for testability. Inject `AudioDeviceManager`. Wire callbacks in `AppDelegate`. Register cleanup in `applicationWillTerminate`.

**New UI control:** Add to the SwiftUI views under `MicGuard/UI/MenuPopover/`. Expose state via `@Published` on `PopoverViewModel` and a write-through method that calls `PreferencesManager`. Avoid writing volume / continuous values to `PreferencesManager` on every drag tick — gate the commit on `onEditingChanged: false` (mouse-up) to keep the UserDefaults → Combine → CoreAudio chain quiet.

**New preference:** Add key + getter/setter to `PreferencesManager`, expose on the `PreferencesManaging` protocol, publish the key via `preferencesChangedPublisher`, and handle it in `AppDelegate.handlePreferenceChange(key:)`.

**New test:** Add `{Component}Tests.swift` in `MicGuardTests`. Use `MockAudioDeviceManager` for deterministic testing.

## Known Limitations

**"Reset When Mic Not In Use" misses overlapping app usage:** `isDeviceRunning` is device-level — if Discord holds the mic while you leave a Zoom call, the device stays "running" and the reset never triggers. Users in persistent voice calls should use "Lock Input Volume" instead.

**Notifications disabled:** `NotificationManager` exists but is not wired up in `AppDelegate` (commented out due to a bundle-identifier crash when running outside Xcode).

**CoreAudio listener lifecycle is fragile:** Listeners registered per-device can fail silently if a device ID becomes invalid between registration and removal. Always check removal status.

**ProcessMonitor uses hardcoded bundle IDs:** New audio apps won't be detected until bundle IDs are added. Falls back to `.nonRTC` for unknown apps.

**Name-based device matching is ambiguous:** When a device reconnects with a new UID, matching falls back to its display name. With two devices sharing a name, the watchdog refuses to guess (`onDeviceMatchAmbiguous` fires but isn't surfaced in the UI) and that priority entry stays unresolved. The popover list still shows connected devices in this case (they're appended as new entries), but the stale entry remains a ghost until the user re-picks the device.

**Unsettable-device tracking is per-session only:** Devices macOS silently refuses to set as default (BlackHole, Teams Audio, aggregates) are tracked in two session-scoped sets — `PopoverViewModel.unsettableUIDs` (dims them in the UI) and the watchdogs' stick-failure counts (skips them during enforcement). Neither persists across launches.

**No anti-fight throttle test coverage:** `VolumeGuard`'s 10-corrections-per-5s throttle works but has no unit tests (debounce deadline and device-switch enforcement are covered).

## Conventions

- Protocols: `AudioDeviceManaging`, `DeviceWatchdogProtocol`, `VolumeGuardProtocol`, `PreferencesManaging`, `StatsManaging`
- Cross-component: closure callbacks on the core components (`onDeviceHijackBlocked`, `onYielded`, `onProtectionResumed`, `onVolumeCorrected`, `onMeetingEnded`); Combine `PassthroughSubject` publishers on `AudioDeviceManager` and `PreferencesManager`
- Logging: `MGLog.debug("...")` only — backed by `NSLog` in DEBUG, compiled out entirely in Release. Don't use `print()`.
- Volume values: `Float` 0.0–1.0, clamped via `max(0, min(1, value))`
- `Package.swift` explicitly lists every source file — update it when adding new files
- UI uses SwiftUI inside the popover and `@MainActor` on `StatusBarController` / `PopoverViewModel`. `OnAirIndicator` still uses AppKit (`NSStatusItem` / `NSImage`) for the menu-bar icon itself.

## Release & Versioning

Full process: [RELEASING.md](RELEASING.md). Releases are cut entirely locally — no CI, no secrets in workflows (same model as local-cloud-browser). Run `scripts/release.sh <version>`: test → version bump → universal build → Developer ID sign → notarize + staple (app and DMG, via the `notarytool` keychain profile) → commit + tag `v<version>` + push → GitHub release with DMG → Homebrew cask bump in [milan0x/homebrew-tap](https://github.com/milan0x/homebrew-tap).

**When the user asks to ship / release / publish a new version:** run `scripts/release.sh <version>` (pick the next version yourself if the user didn't name one — bump MINOR for features, PATCH for fixes). Do not hand-roll the steps. Notarization waits are built into the script (`notarytool submit --wait`) — let it block until Apple returns `Accepted`; do not create the GitHub release before both the app and the DMG are notarized and stapled. If the script fails partway, fix the cause and finish the remaining steps manually in script order, keeping every name in the table below exact.

Naming is load-bearing — the cask and the tap's bump workflow parse these exact formats:

- Version `MAJOR.MINOR[.PATCH]`; git tag `v<version>`; `CFBundleShortVersionString` must equal the tag without `v`; `CFBundleVersion` is an integer incremented every release.
- Release asset must be named `MicGuard-<version>.dmg`, containing `MicGuard.app`, volume name `MicGuard`, release title `MicGuard <version>`.
- `MicGuard/App/Info.plist` is the version source of truth (`GENERATE_INFOPLIST_FILE: false`); `project.yml`'s `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` are kept in sync by the release script but are not authoritative.
- The tap's `bump.yml` cron derives the download URL from the cask's `url` template + latest release tag — renaming the asset or changing the tag scheme silently breaks cask updates.
