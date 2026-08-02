//
//  DeviceWatchdog.swift
//  MicGuard
//
//  Monitors system default device changes and enforces user's preferred device
//

import Foundation
import Combine
import AppKit

// MARK: - Protocol for Testability

protocol DeviceWatchdogProtocol {
    var isWatching: Bool { get }
    var devicePriorityOrder: [String] { get }

    func startWatching(devicePriorityOrder: [String])
    func stopWatching()
    func updateDevicePriorityOrder(_ order: [String])

    var onDeviceHijackBlocked: ((String, String) -> Void)? { get set }
    /// Fires when repeated overrides hit the yield threshold: (attemptedDeviceName, preferredDeviceName).
    /// CoreAudio can't attribute the change to a user vs. an app, so the watchdog KEEPS
    /// enforcing — the caller surfaces an explicit "stop fighting?" choice and calls
    /// `yieldNow()` only if the user consents.
    var onFightDetected: ((String, String) -> Void)? { get set }
    /// Fires when the watchdog enters yielded state via `yieldNow()`: (acceptedDeviceName, formerPreferred).
    /// Caller should surface "INPUT/OUTPUT CHANGED" feedback and expose a way to resume.
    var onYielded: ((String, String) -> Void)? { get set }
    /// Fires when the watchdog transitions from yielded → protecting again.
    /// Whether triggered by user (Re-apply) or auto-resume, caller can flash "LOCK ON".
    var onProtectionResumed: (() -> Void)? { get set }

    /// Resolves a cached name for a given UID (provided by PreferencesManager)
    var nameForUID: ((String) -> String?)? { get set }
    /// Called when a device is matched by name and its stored UID needs updating: (oldUID, newUID)
    var onDeviceUIDUpdated: ((String, String) -> Void)? { get set }
    /// Called when multiple devices share the same name, making name-based matching ambiguous: (name, count)
    var onDeviceMatchAmbiguous: ((String, Int) -> Void)? { get set }

    /// Clear the yielded state and resume enforcement immediately.
    func resumeProtection()

    /// Enter yielded state deliberately — the user consented to stop fighting.
    func yieldNow()

    /// Whether the watchdog is currently yielded (not enforcing).
    var isYielded: Bool { get }
}

// MARK: - BaseDeviceWatchdog

/// Common logic for input and output device watchdogs.
/// Subclasses provide direction-specific hooks via closures.
class BaseDeviceWatchdog: DeviceWatchdogProtocol {

    // MARK: - Properties

    let audioDeviceManager: AudioDeviceManaging
    var cancellables = Set<AnyCancellable>()

    private(set) var isWatching: Bool = false
    private(set) var preferredDeviceUID: String?
    private(set) var devicePriorityOrder: [String] = []

    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval

    // Periodic verification: macOS (especially Bluetooth/AirPods routing) can switch the default
    // device without reliably firing kAudioHardwarePropertyDefaultInputDevice. Poll every 3s as
    // a safety net so the lock catches any switch that slips past the event-driven path.
    private var verificationTimer: Timer?
    private let verificationInterval: TimeInterval = 3.0

    var onDeviceHijackBlocked: ((String, String) -> Void)?
    var onFightDetected: ((String, String) -> Void)?
    var onYielded: ((String, String) -> Void)?
    var onProtectionResumed: (() -> Void)?
    var nameForUID: ((String) -> String?)?
    var onDeviceUIDUpdated: ((String, String) -> Void)?
    var onDeviceMatchAmbiguous: ((String, Int) -> Void)?

    // Yield-after-N-hijacks: when the user fights us repeatedly, stop fighting back.
    // Lets them deliberately use a non-preferred device without MicGuard nagging.
    /// When false, the watchdog always reverts — never yields. Set from preference.
    var autoYieldEnabled: Bool = true
    /// When true, the watchdog auto-resumes from yielded state the moment the user
    /// picks the top-priority device (from anywhere — System Settings, popover, etc).
    var autoResumeEnabled: Bool = false
    private(set) var isYielded: Bool = false
    private var recentHijackTimestamps: [Date] = []
    // Anchor for the flap filter: the last OBSERVED override event, recorded or not.
    // Anchoring on the last recorded event instead lets a storm longer than
    // yieldMinSpread record a second timestamp and trip the threshold.
    private var lastOverrideEventAt: Date?
    private let yieldThresholdCount: Int = 2
    private let yieldWindow: TimeInterval = 10.0
    private let yieldMinSpread: TimeInterval = 1.0  // filters out Bluetooth flap storms

    // Devices whose setDefaultDevice reported success but the default didn't
    // change — macOS silently refuses some virtual/aggregate devices. After
    // enough consecutive refusals the device is skipped so enforcement falls
    // through to the next priority entry instead of retrying forever.
    // Cleared on device-list changes so re-enumerated hardware gets a clean retry.
    private var stickFailureCounts: [String: Int] = [:]
    private let maxStickFailures = 2
    // Default-device UIDs seen in change events since our last set attempt.
    // Distinguishes a silent refusal (the attempted device never appears — no
    // event carried it) from a post-set re-override (it appeared, then macOS
    // or an app moved off it). Only refusals count toward stickFailureCounts.
    private var observedDefaultUIDsSinceSet: Set<String> = []

    // Cooldown between "stop fighting?" offers so a persistent hijacker doesn't
    // re-surface the banner on every second blocked switch after the user
    // already chose to keep protecting.
    private var lastFightOfferAt: Date?
    private let fightOfferCooldown: TimeInterval = 300

    // Hijacks that fire within this window after a device-list change are OS-initiated
    // routing (AirPods connecting, USB mic plugged in, etc.) — not user clicks. We still
    // revert during the window; we just don't let them count toward the yield threshold.
    private var lastDeviceListChangeAt: Date?
    private let deviceListFluxWindow: TimeInterval = 5.0

    // MARK: - Direction hooks (set by subclasses)

    var deviceChangedPublisher: (() -> PassthroughSubject<AudioDevice?, Never>)!
    var getDefaultDevice: (() -> AudioDevice?)!
    var setDefaultDevice: ((AudioDevice) -> Bool)!
    var devicesWithName: ((String) -> [AudioDevice])!
    var selectBestDevice: (() -> AudioDevice?)!
    var deviceMatchesDirection: ((AudioDevice) -> Bool)!

    /// Optional external usability filter (e.g. clamshell mode makes the built-in
    /// mic unusable while it stays enumerated). nil means every device is usable.
    var isDeviceUsable: ((AudioDevice) -> Bool)?

    // MARK: - Initialization

    init(audioDeviceManager: AudioDeviceManaging, debounceInterval: TimeInterval = 0.1) {
        self.audioDeviceManager = audioDeviceManager
        self.debounceInterval = debounceInterval
    }

    // MARK: - Public Methods

    func startWatching(devicePriorityOrder: [String]) {
        self.devicePriorityOrder = devicePriorityOrder
        self.preferredDeviceUID = devicePriorityOrder.first

        MGLog.debug("[MicGuard.Watchdog] startWatching priority=\(devicePriorityOrder)")

        guard !isWatching else {
            MGLog.debug("[MicGuard.Watchdog] startWatching: already watching, only priority updated")
            return
        }
        isWatching = true

        deviceChangedPublisher()
            .sink { [weak self] newDevice in
                self?.handleDeviceChange(newDevice: newDevice)
            }
            .store(in: &cancellables)

        audioDeviceManager.devicesChangedPublisher
            .sink { [weak self] in
                self?.handleDeviceListChange()
            }
            .store(in: &cancellables)

        enforcePreferredDevice()
        startVerificationTimer()
    }

    func stopWatching() {
        isWatching = false
        isYielded = false
        recentHijackTimestamps.removeAll()
        lastOverrideEventAt = nil
        lastFightOfferAt = nil
        lastDeviceListChangeAt = nil
        stickFailureCounts.removeAll()
        observedDefaultUIDsSinceSet.removeAll()
        cancellables.removeAll()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        stopVerificationTimer()
    }

    func updatePreferredDevice(uid: String) {
        updateDevicePriorityOrder([uid])
    }

    func updateDevicePriorityOrder(_ order: [String]) {
        devicePriorityOrder = order
        preferredDeviceUID = order.first

        if isWatching {
            enforcePreferredDevice()
        }
    }

    // MARK: - Device Change Handling

    private func handleDeviceChange(newDevice: AudioDevice?) {
        MGLog.debug("[MicGuard.Watchdog] handleDeviceChange newDevice=\(newDevice?.name ?? "nil") isWatching=\(isWatching) isYielded=\(isYielded)")

        if let uid = newDevice?.uid {
            observedDefaultUIDsSinceSet.insert(uid)
        }

        guard isWatching else { return }

        // Coalesce rapid-fire default-change events (Bluetooth flaps fire several
        // within milliseconds) so we act once on the settled state.
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.processDeviceChange()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func processDeviceChange() {
        guard isWatching else { return }

        // Re-read at fire time — the event's snapshot may be stale after the
        // debounce delay (device list refreshes race the default-change listener).
        let newDevice = getDefaultDevice()

        // While yielded: check whether the user just navigated back to the top-priority
        // device. If so AND auto-resume is enabled, exit yielded state and resume
        // enforcement. The user's action signals they've "come home" to their preferred.
        // Strictly priority #1 — not "best available" (whose fallback is the current
        // default, which would make ANY change auto-resume) — and never during the
        // flux window, where the change is OS routing rather than a user pick.
        if isYielded {
            if autoResumeEnabled,
               !isInDeviceListFluxWindow,
               let topUID = devicePriorityOrder.first,
               let topDevice = findDeviceByUIDOrName(topUID),
               newDevice?.uid == topDevice.uid {
                MGLog.debug("[MicGuard.Watchdog] auto-resume: user picked top-priority \(topDevice.name)")
                resumeProtection()
            }
            return
        }

        // A nil default is a transient state (device list mid-refresh, lid
        // transition). Don't treat it as a hijack — re-check shortly, silently.
        guard let currentDevice = newDevice else {
            MGLog.debug("[MicGuard.Watchdog] processDeviceChange: default unresolved, scheduling re-check")
            scheduleDelayedCheck(after: 0.3)
            return
        }

        // Always enforce — including when System Settings is frontmost.
        // Lock means "hold the priority device, period." If the user wants to switch,
        // they can do so via MicGuard's popover (which calls setDefault directly,
        // bypassing this enforcement path because the new device becomes #1 priority).

        guard let bestDevice = selectBestDevice() else {
            MGLog.debug("[MicGuard.Watchdog] processDeviceChange: selectBestDevice returned nil — priority=\(devicePriorityOrder)")
            return
        }

        MGLog.debug("[MicGuard.Watchdog] processDeviceChange bestDevice=\(bestDevice.name) priorityOrder=\(devicePriorityOrder)")

        // If the default keeps getting changed away from our preferred device,
        // surface a "stop fighting?" offer — but NEVER yield silently. CoreAudio
        // can't tell a user's System Settings click from an app's programmatic
        // set, and silently yielding hands the win to the exact hijackers this
        // app exists to block. Enforcement continues until the user consents.
        if currentDevice.uid != bestDevice.uid {
            // Default changes right after a device-list change are macOS re-routing
            // (notably AirPods finishing HFP negotiation 2-5s after connect), not
            // user clicks: revert silently and don't count toward the yield threshold.
            let systemInitiated = isInDeviceListFluxWindow
            if !systemInitiated, shouldOfferYieldForRepeatedOverride() {
                MGLog.debug("[MicGuard.Watchdog] fight detected — offering yield, still enforcing")
                onFightDetected?(currentDevice.name, bestDevice.name)
            }
            enforcePreferredDevice(announce: !systemInitiated)
        }
    }

    private var isInDeviceListFluxWindow: Bool {
        guard let fluxStart = lastDeviceListChangeAt else { return false }
        return Date().timeIntervalSince(fluxStart) < deviceListFluxWindow
    }

    /// Returns true when the default has been overridden ≥ N times inside the
    /// yieldWindow, with at least `yieldMinSpread` between observed events
    /// (filters out Bluetooth flap storms of any duration — the anchor is the
    /// last observed event, so back-to-back flips collapse to one record).
    /// Returns false when `autoYieldEnabled` is off — no offer is ever made.
    /// Caller is responsible for excluding system-initiated changes (flux window).
    private func shouldOfferYieldForRepeatedOverride() -> Bool {
        guard autoYieldEnabled else { return false }

        let now = Date()

        recentHijackTimestamps.removeAll { now.timeIntervalSince($0) > yieldWindow }

        // Ignore events that fire too fast after the previous one — that's
        // Bluetooth renegotiation, not a user. The anchor advances on every
        // observed event, so a long storm still counts as a single override.
        let sinceLastEvent = lastOverrideEventAt.map { now.timeIntervalSince($0) }
        lastOverrideEventAt = now
        if let spread = sinceLastEvent, spread < yieldMinSpread {
            return false
        }
        recentHijackTimestamps.append(now)
        if recentHijackTimestamps.count >= yieldThresholdCount {
            // Re-arm the streak, and rate-limit offers: a persistent hijacker
            // reaches the threshold every other blocked switch, which would
            // otherwise re-prompt a user who already chose "keep protecting".
            recentHijackTimestamps.removeAll()
            if let last = lastFightOfferAt, now.timeIntervalSince(last) < fightOfferCooldown {
                return false
            }
            lastFightOfferAt = now
            return true
        }
        return false
    }

    func yieldNow() {
        guard isWatching, !isYielded else { return }
        isYielded = true
        recentHijackTimestamps.removeAll()
        lastOverrideEventAt = nil
        let acceptedName = getDefaultDevice()?.name ?? "current device"
        let preferredName = selectBestDevice()?.name ?? "preferred device"
        MGLog.debug("[MicGuard.Watchdog] yieldNow — user chose to stop fighting")
        onYielded?(acceptedName, preferredName)
    }

    func resumeProtection() {
        guard isYielded else { return }
        MGLog.debug("[MicGuard.Watchdog] resumeProtection — clearing yield state")
        isYielded = false
        recentHijackTimestamps.removeAll()
        lastOverrideEventAt = nil
        lastFightOfferAt = nil
        onProtectionResumed?()
        if isWatching {
            enforcePreferredDevice()
        }
    }

    /// Re-run enforcement against current device availability.
    /// Used when an external signal changes which devices are usable
    /// (e.g. clamshell open/close) without any CoreAudio event firing.
    func reevaluateEnforcement() {
        guard isWatching, !isYielded else { return }
        enforcePreferredDevice()
    }

    func handleDeviceListChange() {
        MGLog.debug("[MicGuard.Watchdog] handleDeviceListChange isWatching=\(isWatching)")
        lastDeviceListChangeAt = Date()
        // Re-enumerated hardware gets a clean retry at being set as default.
        stickFailureCounts.removeAll()
        guard isWatching, !isYielded else { return }

        if let bestDevice = selectBestDevice() {
            let currentDefault = getDefaultDevice()
            MGLog.debug("[MicGuard.Watchdog] handleDeviceListChange best=\(bestDevice.name) current=\(currentDefault?.name ?? "nil")")
            if currentDefault?.uid != bestDevice.uid {
                enforcePreferredDevice()
            }
        }

        // macOS often changes the default device *after* the device-list change event fires
        // (observed with AirPods and other Bluetooth devices). Schedule two delayed checks so
        // we catch the switch even when kAudioHardwarePropertyDefaultInputDevice doesn't fire.
        scheduleDelayedCheck(after: 0.3)
        scheduleDelayedCheck(after: 1.0)
    }

    private func scheduleDelayedCheck(after delay: TimeInterval) {
        // One-shot timer in .common mode so it fires even while NSMenu is tracking.
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, self.isWatching, !self.isYielded else { return }
            guard let bestDevice = self.selectBestDevice() else { return }
            let currentDefault = self.getDefaultDevice()
            if currentDefault?.uid != bestDevice.uid {
                self.enforcePreferredDevice()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// `announce: true` fires `onDeviceHijackBlocked` (menu-bar flash + stat) —
    /// only for user-initiated hijacks. System-initiated routing (device-list
    /// flux, delayed checks, verification timer, startup) enforces silently.
    func enforcePreferredDevice(announce: Bool = false) {
        guard !isYielded else {
            MGLog.debug("[MicGuard.Watchdog] enforcePreferredDevice: yielded, skipping")
            return
        }
        guard let bestDevice = selectBestDevice() else {
            MGLog.debug("[MicGuard.Watchdog] enforcePreferredDevice: no best device, skipping")
            return
        }

        let currentDefault = getDefaultDevice()
        guard currentDefault?.uid != bestDevice.uid else {
            MGLog.debug("[MicGuard.Watchdog] enforcePreferredDevice: already on \(bestDevice.name), nothing to do")
            return
        }

        let attemptedDeviceName = currentDefault?.name ?? "Unknown"
        MGLog.debug("[MicGuard.Watchdog] enforcePreferredDevice: switching from \(attemptedDeviceName) to \(bestDevice.name) announce=\(announce)")

        // Cleared before the set so the change event for THIS set (delivered
        // synchronously or async depending on the backend) lands in the set.
        observedDefaultUIDsSinceSet.removeAll()
        let setResult = setDefaultDevice(bestDevice)
        MGLog.debug("[MicGuard.Watchdog] enforcePreferredDevice: setDefaultDevice returned \(setResult)")

        if setResult {
            if announce {
                onDeviceHijackBlocked?(attemptedDeviceName, bestDevice.name)
            }
            // Whether the set actually stuck is decided on a delay — an immediate
            // getDefaultDevice() read races macOS re-overrides and mid-hotplug
            // cache refreshes and would mis-mark settable devices as refused.
            scheduleEnforcementVerification(attempted: bestDevice)
        }
    }

    private func scheduleEnforcementVerification(attempted: AudioDevice) {
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self, self.isWatching, !self.isYielded else { return }
            let currentDefault = self.getDefaultDevice()
            if currentDefault?.uid == attempted.uid {
                self.stickFailureCounts[attempted.uid] = nil
                return
            }
            // The default is elsewhere. If a change event ever carried the
            // attempted device, the set DID stick and something re-overrode it
            // (AirPods-style) — re-apply without penalty. If no event ever showed
            // it, macOS silently refused the set (noErr, default unmoved): count
            // it toward the session skip-list so enforcement can fall through.
            if !self.observedDefaultUIDsSinceSet.contains(attempted.uid) {
                let failures = (self.stickFailureCounts[attempted.uid] ?? 0) + 1
                self.stickFailureCounts[attempted.uid] = failures
                MGLog.debug("[MicGuard.Watchdog] verification: set never stuck for \(attempted.name) (\(failures)/\(self.maxStickFailures))")
            }
            self.enforcePreferredDevice()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startVerificationTimer() {
        stopVerificationTimer()
        // Use .common mode so the timer fires even while NSMenu's eventTracking loop is active.
        // Timer.scheduledTimer uses .defaultRunLoopMode which is suspended during menu display.
        let timer = Timer(timeInterval: verificationInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.isWatching, !self.isYielded else { return }
            guard let bestDevice = self.selectBestDevice() else { return }
            let currentDefault = self.getDefaultDevice()
            if currentDefault?.uid != bestDevice.uid {
                MGLog.debug("[MicGuard.Watchdog] verificationTimer: drift detected, current=\(currentDefault?.name ?? "nil") best=\(bestDevice.name)")
                self.enforcePreferredDevice()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        verificationTimer = timer
        MGLog.debug("[MicGuard.Watchdog] verificationTimer started (\(verificationInterval)s interval, .common mode)")
    }

    private func stopVerificationTimer() {
        verificationTimer?.invalidate()
        verificationTimer = nil
    }

    /// Whether the device was refused as default enough times this session to skip.
    func isMarkedUnsettable(_ uid: String) -> Bool {
        (stickFailureCounts[uid] ?? 0) >= maxStickFailures
    }

    // MARK: - Name-Based Matching Helpers

    /// Try to find a device by UID first, then fall back to name match. Updates UID if matched by name.
    /// Only returns devices matching this watchdog's direction — `device(forUID:)`
    /// searches both input and output lists, so an input watchdog must not accept
    /// an output-only device (and vice versa).
    func findDeviceByUIDOrName(_ uid: String) -> AudioDevice? {
        if let device = audioDeviceManager.device(forUID: uid), deviceMatchesDirection(device) {
            return device
        }

        if let name = nameForUID?(uid) {
            let nameMatches = devicesWithName(name)
            if nameMatches.count == 1 {
                let matchedDevice = nameMatches[0]
                if let index = devicePriorityOrder.firstIndex(of: uid) {
                    devicePriorityOrder[index] = matchedDevice.uid
                    preferredDeviceUID = devicePriorityOrder.first
                }
                onDeviceUIDUpdated?(uid, matchedDevice.uid)
                return matchedDevice
            } else if nameMatches.count > 1 {
                onDeviceMatchAmbiguous?(name, nameMatches.count)
            }
        }

        return nil
    }
}

// MARK: - DeviceWatchdog (Input)

class DeviceWatchdog: BaseDeviceWatchdog {

    override init(audioDeviceManager: AudioDeviceManaging, debounceInterval: TimeInterval = 0.1) {
        super.init(audioDeviceManager: audioDeviceManager, debounceInterval: debounceInterval)

        deviceChangedPublisher = { [unowned self] in self.audioDeviceManager.defaultInputChangedPublisher }
        getDefaultDevice = { [unowned self] in self.audioDeviceManager.defaultInputDevice }
        setDefaultDevice = { [unowned self] in self.audioDeviceManager.setDefaultInputDevice($0) }
        devicesWithName = { [unowned self] in self.audioDeviceManager.inputDevices(withName: $0) }
        deviceMatchesDirection = { $0.isInput }
        selectBestDevice = { [unowned self] in self.selectBestAvailableDevice() }
    }

    /// Select the best available device from the priority list
    private func selectBestAvailableDevice() -> AudioDevice? {
        for uid in devicePriorityOrder {
            if let device = findDeviceByUIDOrName(uid),
               isDeviceUsable?(device) ?? true,
               !isMarkedUnsettable(device.uid) {
                return device
            }
        }
        // If no devices in priority list are available, return system default
        return audioDeviceManager.defaultInputDevice
    }
}

// MARK: - OutputDeviceWatchdog

class OutputDeviceWatchdog: BaseDeviceWatchdog {

    override init(audioDeviceManager: AudioDeviceManaging, debounceInterval: TimeInterval = 0.1) {
        super.init(audioDeviceManager: audioDeviceManager, debounceInterval: debounceInterval)

        deviceChangedPublisher = { [unowned self] in self.audioDeviceManager.defaultOutputChangedPublisher }
        getDefaultDevice = { [unowned self] in self.audioDeviceManager.defaultOutputDevice }
        setDefaultDevice = { [unowned self] in self.audioDeviceManager.setDefaultOutputDevice($0) }
        devicesWithName = { [unowned self] in self.audioDeviceManager.outputDevices(withName: $0) }
        deviceMatchesDirection = { $0.isOutput }
        selectBestDevice = { [unowned self] in self.selectPreferredDevice() }
    }

    /// Select the best available output device from the priority list
    private func selectPreferredDevice() -> AudioDevice? {
        for uid in devicePriorityOrder {
            if let device = findDeviceByUIDOrName(uid),
               isDeviceUsable?(device) ?? true,
               !isMarkedUnsettable(device.uid) {
                return device
            }
        }
        return audioDeviceManager.defaultOutputDevice
    }
}
