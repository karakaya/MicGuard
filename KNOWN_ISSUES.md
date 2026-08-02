# Known Issues

**"Reset When Mic Not In Use" misses overlapping apps**
`isDeviceRunning` is device-level — if Discord holds the mic while you leave a Zoom call, the device stays "running" and the reset never fires. Use "Lock Input Volume" instead if you're in persistent voice calls.

**Notifications are disabled**
The `NotificationManager` class exists but isn't wired up. Running outside Xcode caused a bundle ID crash, so it's been left dormant.

**ProcessMonitor uses hardcoded bundle IDs**
New audio apps aren't detected until added. Unknown apps fall back to `.nonRTC`.

**Device name-based matching is ambiguous**
When a device reconnects with a new UID, matching falls back to name. If two devices share the same name, the watchdog refuses to guess (`onDeviceMatchAmbiguous` fires but isn't surfaced in the UI) and the stale priority entry stays a ghost until the user re-picks the device. Connected devices do still appear in the list.

**Unsettable-device tracking is per-session only**
Devices macOS silently refuses to set as default (BlackHole, Teams Audio, aggregates) are dimmed in the picker and skipped by watchdog enforcement after two failed sets, but both trackers are rebuilt from scratch each launch.

**CoreAudio listener lifecycle is fragile**
Per-device listeners can fail silently if a device ID becomes invalid between registration and removal. Rapid hot-plug scenarios are not well tested.

**VolumeGuard anti-fight throttle can defer corrections**
When an app aggressively fights the volume lock, the 10-corrections-per-5s throttle intentionally pauses corrections until the window resets. (The debounce itself is deadline-capped, so continuous churn can no longer starve corrections entirely.)

**`PopoverViewModel` and `PopoverContentView` are large**
The view model is ~700 lines and the root content view is ~860 lines. Both could be split further (Input / Output / Settings sections are colocated for now).

**Test coverage gaps**
`VolumeGuard` anti-fight throttling, `PopoverViewModel` device-list resolution, and CoreAudio listener lifecycle have no test coverage. (Watchdog fight-detection / yield / auto-resume transitions and the VolumeGuard debounce deadline are covered in `WatchdogYieldTests` / `VolumeGuardTests`.)
