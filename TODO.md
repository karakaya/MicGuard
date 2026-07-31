# TODO

## Feature: Fall through to next priority device when preferred device is unusable

**Status: clamshell case shipped.** `ClamshellMonitor` (IOKit interest notification on `IOPMrootDomain`, re-reads `AppleClamshellState` on any message) feeds the input watchdog's `isDeviceUsable` hook, which skips built-in-transport devices while the lid is closed. Auto-switch and the ActivityMonitor override apply the same filter. System-initiated reverts (device-list flux window) no longer flash "INPUT HELD" or count as hijack stats. Needs verification on real hardware: close lid with external display, confirm fallthrough to next priority device and no menu-bar flash.

### Remaining (general case)

Generalized "device unreachable" detection beyond lid close is still open:

- USB hub sleep, AirPods out of range, dock disconnects without device removal.
- Would need a heuristic (sustained absence of input signal, failure to set as default) — fragile; revisit if reports come in.

## Feature: Smart initial device-priority order

On first launch (and whenever a brand-new UID is appended to the priority list), `addDeviceToOrder` in `PreferencesManager.swift` appends to the tail. The first time the user opens MicGuard, the saved order is therefore whatever sequence CoreAudio happened to enumerate devices in — effectively arbitrary. The lock then snaps the system default to the top of that list (`PopoverViewModel.swift:419`), which means a user with Continuity enabled can land on their iPhone microphone the moment they install the app. Worst possible first impression.

### Proposed ranking (best → worst)

Bucket by `transportType` on insert instead of appending blindly. Order based on inferred intent:

1. **External / real microphone** — anything not in the buckets below. The strongest signal of "deliberate choice": if you plugged in a USB / XLR / HDMI / Thunderbolt mic, you meant it.
2. **MacBook built-in** (`kAudioDeviceTransportTypeBuiltIn`) — sensible default fallback when no external is connected.
3. **Bluetooth / AirPods** (`kAudioDeviceTransportTypeBluetooth`, `kAudioDeviceTransportTypeBluetoothLE`) — intentional wearable, but lower quality than a wired mic and not always present.
4. **iPhone via Continuity** (`kAudioDeviceTransportTypeContinuityCapture`, `kAudioDeviceTransportTypeContinuityCaptureWired`) — convenience feature, rarely the device the user actually wants for calls.
5. **Virtual / aggregate** (`kAudioDeviceTransportTypeVirtual`, `kAudioDeviceTransportTypeAggregate`) — already classified as `isLikelyUnsettable` in `AudioDeviceManager.swift:36`. Almost never the real mic.

The detection trick: bucket #1 ("external") is defined as "anything *not* in buckets 2–5" rather than enumerating known external transport types. That way an unknown future transport type still defaults to "treat as a real mic" rather than getting accidentally demoted.

### Scope notes

- **New devices only.** Do not re-bucket existing saved orders on upgrade — a user who has deliberately reordered must not have their list rewritten. Only newly-appended UIDs flow through the bucketing logic.
- **Optional "Reset to recommended order" button** in Settings for users who want to opt back in to the new ordering after upgrade.
- **Schema-stability note:** the priority list is the user's source of truth. Any future refactor that touches the storage shape needs a migration path that preserves it. Worth a comment at the `preferredInputDeviceOrder` / `preferredOutputDeviceOrder` declaration site so it's not forgotten.
- **Lock-enabled-on-first-launch** is a separate question. Could ship lock off until the user confirms, even after the smart-seed lands. Decide closer to implementation.
- **Both inputs and outputs.** Same logic applies to `preferredOutputDeviceOrder` — AirPods-vs-built-in-speakers has the same "what did the user actually mean" problem.
