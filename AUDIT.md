# MicGuard Audit — 2026-06-12

Full code + UX review (core engine, app/UI/persistence, product). All findings
verified against actual code. Items already tracked in KNOWN_ISSUES.md / TODO.md
are excluded unless the reality turned out worse than documented.
Test suite at time of audit: 111/111 passing.

## Critical — feature correctness

- [ ] **"Reset When Mic Stops" fires mid-meeting.** `ActivityMonitor.pollInputLevel()`
  (`Core/ActivityMonitor.swift:177-201`) computes real mic activity
  (`checkAnyMicInUse()`) but never uses it — meeting start/end is keyed on changes
  to the volume *setting* (`kAudioDevicePropertyVolumeScalar`), not the live signal.
  When Zoom's AGC lowers the input volume and it stabilizes for 2s, `onMeetingEnded`
  fires during the call and AppDelegate (`App/AppDelegate.swift:159-172`) snaps the
  volume back up mid-meeting. A meeting where the volume setting never changes never
  registers as started. (Worse than KNOWN_ISSUES describes; AI_CONTEXT's data-flow
  description doesn't match the code.)
  Fix: gate `onMeetingEnded` on the `isRunning` true→false transition — the value is
  already computed three lines above.

- [ ] **VolumeGuard's anti-fight throttle is unreachable dead code.**
  (`Core/VolumeGuard.swift:41-44, 72, 233-253, 284-294`.) Corrections are counted only
  inside the debounced work item and every new fight event cancels the pending item —
  with 2.5s debounce in a 5s window the counter maxes at 2; the threshold is 10.
  `onThrottleStateChanged` can never fire. Worse: an app adjusting volume more often
  than every 2.5s prevents the correction from ever executing — the "lock" only lands
  after the fight stops.
  Fix: leading-edge debounce (correct immediately, suppress for the interval) and
  count corrections at detection time — or size the threshold to what the debounce
  actually permits.

- [ ] **Legacy preferences migration has been dead since day one.**
  `migrateOldPreferences()` (`Utilities/PreferencesManager.swift:370`) checks
  `defaults.string(forKey:) == nil`, but `registerDefaults()` runs first (`:146`) and
  the registration domain makes that never nil. Upgraders from builds with
  `InputVolumeLockEnabled` / `AutoResetEnabled` / `LockedInputVolume` /
  `DefaultResetVolume` silently lose settings. Related trap: the
  `volumeControlStrategy` getter fallback (`:252`) returns `.none`, contradicting the
  registered default.
  Fix: check the persistent domain (or the old keys directly), or migrate before
  registering defaults.

## Medium

- [ ] **Watchdog can fight another app indefinitely.** (`Core/DeviceWatchdog.swift:227-341`.)
  Two holes around the (sound) flux-window logic: `yieldMinSpread` (1s) drops fast
  overrides *without counting them*, so a fast re-setter never trips auto-yield and is
  reverted forever with no rate limit; and the timer paths (3s verification, 0.4s
  post-set check, 0.3s/1.0s delayed checks) call `enforcePreferredDevice()` directly,
  bypassing `shouldYieldToRepeatedOverride()` — exactly in the Bluetooth scenario they
  exist for. Fix: global enforcement rate-limit + route timer reverts through yield
  bookkeeping.

- [ ] **Debounced volume correction targets a stale device** captured 2.5s earlier
  (`Core/VolumeGuard.swift:221, 239`) — wrong or dead `AudioObjectID` if the default
  changed meanwhile. Fix: re-fetch `defaultInputDevice` inside the work item.

- [ ] **`isSettingVolume` self-event suppression is a no-op** (`Core/VolumeGuard.swift:137-139,
  163-167, 238-240`) — set/cleared synchronously around an async listener, so it's
  always false by the time the guard runs. Currently masked by the drift-tolerance
  check. Fix: delete the flag and rely on expected-value suppression, or use a
  deadline (`suppressEventsUntil`).

- [ ] **Stale device-cache window on unplug.** (`Core/AudioDeviceManager.swift:103-111,
  587-595` + `DeviceWatchdog.swift:351-372`.) Default-change listeners resolve against
  the cached `inputDevices` list; CoreAudio doesn't order default-changed vs
  devices-changed notifications, so enforcement can run against a list still containing
  the unplugged device and set a dead/recycled ID as system default. Fix:
  `refreshDeviceList()` at the top of the default-change listener blocks, or fall back
  to building the device from the live ID on cache miss.

- [ ] **Global event monitor leaks once per Esc-close/reopen.**
  (`UI/StatusBarController.swift:177-189`.) The popover is `.transient` with no
  `NSPopoverDelegate`, so transient dismissal skips `closePopover()` and the next open
  overwrites `eventMonitor`, orphaning the old one for the session. Fix: add a popover
  delegate, tear down in `popoverDidClose`, and remove any existing monitor before
  installing a new one.

- [ ] **UID re-matching doesn't migrate per-device custom volumes.**
  (`Utilities/PreferencesManager.swift:522-536` vs `:482-499`.) `replaceOutputDeviceUID`
  migrates priority order, cached name, and preferred UID — but not
  `OutputDeviceVolumes`, so set-on-activation silently stops working for exactly the
  devices that need UID migration (AirPods, USB re-enumeration), and stale entries
  accumulate. Fix: move `dict[oldUID]` → `dict[newUID]`.

- [ ] **Launch at Login can silently desync.** (`Utilities/PreferencesManager.swift:273-282,
  554-568`.) Getter reads UserDefaults, never `SMAppService.mainApp.status`
  (`LaunchAtLoginManager.isEnabled` exists and is never called); `setLaunchAtLogin`'s
  empty catch swallows registration failures with no rollback. Fix: derive published
  state from `SMAppService` on `refreshAll()`, surface/roll back failures.

## Low

- [ ] `ActivityMonitor` polling timer uses `Timer.scheduledTimer` default mode and stalls
  during menu/popover tracking (`Core/ActivityMonitor.swift:110`) — the watchdog already
  fixed this with `.common` mode + comment (`DeviceWatchdog.swift:267/327`).
- [ ] `ProcessMonitor` attribution is presence-based (a known RTC app merely *running*
  outranks the actual mic user) and returns `.nonRTC` for unknowns while the doc comment
  promises `.none` (`Core/ProcessMonitor.swift:54-97`). Real fix when wanted:
  `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput` (macOS 14+).
- [ ] `applicationWillTerminate` comment claims `audioDeviceManager = nil` forces listener
  cleanup — it can't (five strong refs alive); the manager's own `willTerminate`
  observer does the real work. Fix the comment before someone deletes the observer
  (`App/AppDelegate.swift:63-65`).
- [ ] Stale trailing `applyBaseState` can clobber a new flash within its 0.4s window —
  guard with `if !isFlashing` (`UI/OnAirIndicator.swift:79-81`).
- [ ] Auto-switch events masquerade as blocked hijacks — same stat counter and same red
  "HELD" flash as real blocks; stats become misleading (`App/AppDelegate.swift:333-334, 376-377`).
- [ ] UserDefaults write churn: `cacheDeviceName` rewrites the whole dict unconditionally
  on every device-change event, popover open or not (`UI/MenuPopover/PopoverViewModel.swift:308-312`
  + `PreferencesManager.swift:469-473`). Skip when unchanged.
- [ ] NotificationManager latent bugs beyond documented dormancy: `isAuthorized` never
  re-read via `getNotificationSettings` (granted permission lost on relaunch) and is
  written from a background callback thread unsynchronized (`Utilities/NotificationManager.swift:20-30`).
- [ ] Dead surface: `showInMenuBar` pref (registered, tested, used nowhere);
  `.inputDeviceLockChanged`/`.outputDeviceLockChanged` posted with zero observers;
  three notification names declared, never posted; `resetToDefaults()` never called
  (and wouldn't refresh UI or unregister login item if it were); unused
  `@State showSnoozeMenu` (abandoned snooze).
- [ ] Ignored `OSStatus` from `AudioObjectAddPropertyListenerBlock` silently degrades
  event-driven detection to the 2s poll (`Core/AudioDeviceManager.swift:482, 535, 573`).
- [ ] `BaseDeviceWatchdog.debounceWorkItem`/`debounceInterval` threaded everywhere, never
  debounce anything; `startWatching` while watching skips `enforcePreferredDevice()`
  unlike `updateDevicePriorityOrder` (masked by AppDelegate's stop-first pattern).
- [ ] Build setup: `project.yml` has `MARKETING_VERSION: "1.0"` vs pbxproj `1.2` —
  regenerating with xcodegen reverts the version (shipping version survives only via
  hardcoded Info.plist). No shared Xcode scheme checked in. Worth a CLAUDE.md note that
  `swift build`/`swift run` is compile/test only — unbundled executable means nil bundle
  ID, broken SMAppService, no LSUIElement.

## Tests — green but blind where it matters

- The pure-logic tests are real (priority fallback, UID migration, ambiguity callback).
- Several are tautological: `testOnVolumeCorrectedCallback`, `testMeetingStartedCallback`,
  `testMeetingEndedCallback`, `testThrottleCallbackSetup`, `testShouldNotThrottleUnderLimit`
  just invoke the closure they assigned one line earlier.
- VolumeGuard's core path is structurally untestable: drift/debounce/throttle live behind
  a private CoreAudio listener; `MockAudioDeviceManager.simulateVolumeChange` only mutates
  a dictionary. That's why the critical findings went unnoticed.
- [ ] Add a volume-changed seam to the manager protocol (e.g. `volumeChangedPublisher`),
  then the three highest-value tests:
  1. Auto-yield state machine incl. flux-window behavior (pins commit `7732dc0`)
  2. Mic running→stopped drives `onMeetingEnded` — **fails today**, pins critical #1
  3. Sustained fight engages throttle — **fails today**, pins critical #2
- Mock fidelity: `setDefaultInputDevice` publishes synchronously and always succeeds;
  the real HAL is async and can re-override — fight loops are structurally invisible.

## UX

- [ ] **Icon never answers "am I protected?"** Two base states only (idle, on-air) —
  identical whether locks are armed, off, or the watchdog has *yielded and stopped
  enforcing*. Add a dimmed/slashed state for unguarded and a distinct one for yielded
  (`onYielded` callback already exists). This is product, not polish.
- [ ] About dialog hardcodes "Version 1.0" / "© 2025" while the app is 1.2
  (`UI/MenuPopover/PopoverViewModel.swift:681`) — read `CFBundleShortVersionString`
  from the bundle. Also activate the app before `NSAlert.runModal()` or the alert can
  open behind the frontmost app in an LSUIElement app (`:693`).
- [ ] "Show notifications" toggle is wired to a preference nothing reads — a visible
  no-op control. Hide until notifications are real (`UI/MenuPopover/PopoverContentView.swift:681-690`).
- [ ] Settings IA: ⌘, opens an empty `Settings { EmptyView() }` scene (`App/MicGuardApp.swift:15-17`).
  Move Launch at Login, stats, auto-yield/auto-resume, hide-virtual, indicator style into
  a real Settings window; keep the popover to status + priority + volume strategy. Reword
  "Stop fighting after 2 manual overrides" / "Auto-resume protection on top device" into
  user language ("When I switch devices manually: …").
- [ ] Flash labels resize the status item — the whole menu bar reflows twice per flash and
  off-cycles render a blank hole (image nil + alpha-0 title). The `pulse()` path already
  avoids this by design; flashes should meet the same bar (`UI/OnAirIndicator.swift:53-86`).
- [ ] Right-click menu: "Reactivate Input/Output Lock" enabled when nothing is yielded
  (silent no-op); menu lacks About and Launch at Login (`UI/StatusBarController.swift:80-115`).
- [ ] No first-run moment: nothing opens on first launch while the volume strategy defaults
  to *active* (resetWhenMicStops @ 75%) — MicGuard's first observable act can be silently
  changing the user's volume. One `popover.show()` on first launch shows the entire value
  prop. (TODO covers smart priority ordering; this is the missing first-open beat.)
- [ ] Accessibility: chevron/xmark/pencil icon buttons have `.help()` but no
  `.accessibilityLabel` (`UI/MenuPopover/DevicePriorityListView.swift:136-157`,
  `PopoverContentView.swift:533-544`); hand-rolled radio rows (`VolumeStrategyRow`,
  `MicIndicatorOption`) lack `.isSelected` traits; the on-air pill image passes
  `accessibilityDescription: nil` (`UI/OnAirIndicator.swift:187`). Check `lockFocus`-composed
  images for retina blur.
- [ ] Priority list is chevron-only reordering while AI_CONTEXT.md claims drag — add
  `onMove` or fix the doc.
- [ ] Popover forces `minHeight: 500` — dead space on sparse tabs (`PopoverContentView.swift:68`).
  README screenshot is stale (shows an input-level readout that no longer exists).

## Product direction

**Differentiator: enforcement, not indication.** macOS's built-in indicator says the mic
is hot; it does nothing about AirPods stealing input or AGC rewriting gain. The priority
watchdog + volume guard + per-device output levels are the moat. "None — rely on macOS's
indicator" as an option is the right confidence; the orange-pill style that duplicates the
native dot centimeters away arguably isn't.

Worth building (only these):
1. **Snooze/pause** (1h / until tomorrow) — auto-yield covers accidental fights; snooze
   covers intentional ones (screen shares, troubleshooting). The `showSnoozeMenu` stub
   shows it was conceived. Right-click menu + popover header.
2. **Tiny event log** — last ~10 actions with timestamps ("14:02 reverted input AirPods →
   FIFINE"). All callbacks already exist. Makes invisible value visible; "3 hijacks
   blocked today" in the header is the retention version.
3. **Guard-state in the icon** (above).

Explicitly do NOT build: per-app rules engine (maintenance treadmill on private behavior);
anything requiring mic permission (zero-permission is the brand); a floating on-air overlay
(the menu bar is the right placement); richer mic-attribution to one-up the system
indicator (TCC/private-API scraping, and it concedes the wrong framing — MicGuard is an
enforcer, not an indicator).

## Done well (keep doing these)

- Thread discipline: every CoreAudio listener hops to main immediately; core state is
  main-confined; `@MainActor` UI classes with `nonisolated` cross-thread entry points.
- Listener lifecycle: deinit + willTerminate observer + per-device keying, removal
  addresses exactly mirror registration (including VolumeGuard's channel fallback).
- Idempotent enforcement: UID comparison before every set — the watchdog can't
  self-oscillate; the `.common`-run-loop-mode timer fix shows real field experience.
- The yield state machine is humane guard design (green "I let you" vs red "I blocked
  them", Re-apply clears yield, disabling auto-yield clears stale yield).
- Zero-permission architecture, articulated in README/About — the single best trust
  decision in the app.
- Device list handles the ugly real world: disconnected devices stay promotable,
  unsettable virtual devices get dimmed with an inline explainer, name-based UID
  re-matching survives reconnects.
