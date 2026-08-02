//
//  AppDelegate.swift
//  MicGuard
//
//  Manages app lifecycle and coordinates core services
//

import Cocoa
import Combine
import CoreAudio

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusBarController: StatusBarController?
    private var audioDeviceManager: AudioDeviceManager?
    private var deviceWatchdog: DeviceWatchdog?
    private var outputDeviceWatchdog: OutputDeviceWatchdog?
    private var volumeGuard: VolumeGuard?
    private var activityMonitor: ActivityMonitor?
    private var clamshellMonitor: ClamshellMonitor?
    
    private let preferencesManager = PreferencesManager.shared
    private let statsManager = StatsManager.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - App Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        MGLog.debug("[MicGuard.App] === BUILD MARKER 2026-05-15-diag1 — launching ===")
        // Initialize core audio manager
        audioDeviceManager = AudioDeviceManager()

        // Lid tracking — in clamshell mode the built-in mic stays enumerated but
        // is physically unusable; the input watchdog must fall through past it.
        clamshellMonitor = ClamshellMonitor()
        clamshellMonitor?.onLidStateChanged = { [weak self] closed in
            guard let self = self else { return }
            MGLog.debug("[MicGuard.AppDelegate] clamshell changed closed=\(closed) — re-evaluating input routing")
            let beforeUID = self.audioDeviceManager?.defaultInputDevice?.uid
            self.deviceWatchdog?.reevaluateEnforcement()
            self.handleInputAutoSwitch()
            self.updateActivityMonitorDeviceOverride()
            // Tell the user why their mic just changed — but only when the lid
            // event actually rerouted input. A lid flip with no routing change
            // stays silent. Called last so it preempts any auto-switch flash.
            let afterUID = self.audioDeviceManager?.defaultInputDevice?.uid
            if beforeUID != afterUID {
                self.statusBarController?.flashLabel(closed ? "LID CLOSED" : "LID OPENED", background: .systemGreen)
            }
        }

        // Initialize watchdogs and guards
        setupDeviceWatchdog()
        setupOutputDeviceWatchdog()
        setupVolumeGuard()
        setupActivityMonitor()
        
        // Setup menu bar UI
        statusBarController = StatusBarController(
            audioDeviceManager: audioDeviceManager!,
            preferencesManager: preferencesManager,
            statsManager: statsManager,
            activityMonitor: activityMonitor
        )
        
        // Start monitoring if locks were previously enabled
        applyStoredPreferences()
        
        // Setup notification observers
        setupNotificationObservers()
        
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Clean up watchdogs and guards
        deviceWatchdog?.stopWatching()
        outputDeviceWatchdog?.stopWatching()
        volumeGuard?.stopGuarding()
        activityMonitor?.stopMonitoring()
        
        // Force cleanup of CoreAudio listeners to prevent memory leaks
        // This ensures listeners are removed even on force-quit
        audioDeviceManager = nil
        
    }
    
    // MARK: - Setup Methods
    
    private func setupDeviceWatchdog() {
        guard let audioManager = audioDeviceManager else { return }

        deviceWatchdog = DeviceWatchdog(audioDeviceManager: audioManager)
        deviceWatchdog?.autoResumeEnabled = preferencesManager.autoResumeOnTopPriorityPick
        deviceWatchdog?.isDeviceUsable = { [weak self] device in
            self?.isUsableInput(device) ?? true
        }

        // Wire up name-based device matching
        deviceWatchdog?.nameForUID = { [weak self] uid in
            self?.preferencesManager.cachedDeviceName(for: uid)
        }
        deviceWatchdog?.onDeviceUIDUpdated = { [weak self] oldUID, newUID in
            self?.preferencesManager.replaceDeviceUID(oldUID: oldUID, newUID: newUID)
        }

        deviceWatchdog?.onDeviceHijackBlocked = { [weak self] from, to in
            MGLog.debug("[MicGuard.AppDelegate] INPUT HELD — reverted from \(from) to \(to)")
            self?.statsManager.increment(stat: .hijacksBlocked)
            self?.statusBarController?.flashLabel("INPUT HELD")
        }

        deviceWatchdog?.onFightDetected = { attempted, preferred in
            MGLog.debug("[MicGuard.AppDelegate] input fight detected — \(attempted) vs \(preferred)")
            NotificationCenter.default.post(name: .watchdogFightDetected, object: nil, userInfo: [
                "direction": "input", "attempted": attempted, "preferred": preferred,
            ])
        }

        deviceWatchdog?.onYielded = { [weak self] accepted, _ in
            MGLog.debug("[MicGuard.AppDelegate] INPUT CHANGED — yielded to \(accepted)")
            self?.statusBarController?.flashLabel("INPUT CHANGED", background: .systemGreen)
            NotificationCenter.default.post(name: .watchdogYieldStateChanged, object: nil, userInfo: [
                "direction": "input", "yielded": true,
            ])
        }

        deviceWatchdog?.onProtectionResumed = { [weak self] in
            MGLog.debug("[MicGuard.AppDelegate] INPUT LOCK ON — protection resumed")
            self?.statusBarController?.flashLabel("INPUT LOCK ON", background: .systemGreen)
            NotificationCenter.default.post(name: .watchdogYieldStateChanged, object: nil, userInfo: [
                "direction": "input", "yielded": false,
            ])
        }

        deviceWatchdog?.onDeviceMatchAmbiguous = { _, _ in
            // Ambiguous name match — multiple devices share the same name
        }
    }
    
    private func setupOutputDeviceWatchdog() {
        guard let audioManager = audioDeviceManager else { return }

        outputDeviceWatchdog = OutputDeviceWatchdog(audioDeviceManager: audioManager)
        outputDeviceWatchdog?.autoResumeEnabled = preferencesManager.autoResumeOnTopPriorityPick

        outputDeviceWatchdog?.nameForUID = { [weak self] uid in
            self?.preferencesManager.cachedDeviceName(for: uid)
        }
        outputDeviceWatchdog?.onDeviceUIDUpdated = { [weak self] oldUID, newUID in
            self?.preferencesManager.replaceOutputDeviceUID(oldUID: oldUID, newUID: newUID)
        }

        outputDeviceWatchdog?.onDeviceHijackBlocked = { [weak self] from, to in
            MGLog.debug("[MicGuard.AppDelegate] OUTPUT HELD — reverted from \(from) to \(to)")
            self?.statsManager.increment(stat: .outputHijacksBlocked)
            self?.statusBarController?.flashLabel("OUTPUT HELD")
        }

        outputDeviceWatchdog?.onFightDetected = { attempted, preferred in
            MGLog.debug("[MicGuard.AppDelegate] output fight detected — \(attempted) vs \(preferred)")
            NotificationCenter.default.post(name: .watchdogFightDetected, object: nil, userInfo: [
                "direction": "output", "attempted": attempted, "preferred": preferred,
            ])
        }

        outputDeviceWatchdog?.onYielded = { [weak self] accepted, _ in
            MGLog.debug("[MicGuard.AppDelegate] OUTPUT CHANGED — yielded to \(accepted)")
            self?.statusBarController?.flashLabel("OUTPUT CHANGED", background: .systemGreen)
            NotificationCenter.default.post(name: .watchdogYieldStateChanged, object: nil, userInfo: [
                "direction": "output", "yielded": true,
            ])
        }

        outputDeviceWatchdog?.onProtectionResumed = { [weak self] in
            MGLog.debug("[MicGuard.AppDelegate] OUTPUT LOCK ON — protection resumed")
            self?.statusBarController?.flashLabel("OUTPUT LOCK ON", background: .systemGreen)
            NotificationCenter.default.post(name: .watchdogYieldStateChanged, object: nil, userInfo: [
                "direction": "output", "yielded": false,
            ])
        }

        outputDeviceWatchdog?.onDeviceMatchAmbiguous = { _, _ in
            // Ambiguous name match — multiple output devices share the same name
        }
    }

    private func setupVolumeGuard() {
        guard let audioManager = audioDeviceManager else { return }
        
        volumeGuard = VolumeGuard(audioDeviceManager: audioManager)
        
        volumeGuard?.onVolumeCorrected = { [weak self] _, _ in
            self?.statsManager.increment(stat: .volumeCorrections)
            self?.statusBarController?.pulseIcon()
        }
    }
    
    private func setupActivityMonitor() {
        guard let audioManager = audioDeviceManager else { return }

        activityMonitor = ActivityMonitor(audioDeviceManager: audioManager)
        
        // Listen to meeting end events
        activityMonitor?.onMeetingEnded = { [weak self] in
            guard let self = self,
                  self.preferencesManager.volumeControlStrategy == .resetWhenMicStops else { return }
            
                guard let device = self.audioDeviceManager?.defaultInputDevice,
                  let currentVolume = self.audioDeviceManager?.getInputVolume(for: device) else { return }
            
            let targetLevel = self.preferencesManager.targetVolume
            
            if currentVolume < targetLevel {
                self.volumeGuard?.setVolume(level: targetLevel)
                self.statsManager.increment(stat: .volumeResets)
            }
        }
    }
    
    private func applyStoredPreferences() {
        MGLog.debug("[MicGuard.App] applyStoredPreferences: lockEnabled=\(preferencesManager.inputDeviceLockEnabled) priority=\(preferencesManager.preferredInputDeviceOrder)")
        // Master pause: nothing enforces. ActivityMonitor stays on — the On Air
        // indicator is passive observation, not enforcement.
        guard !preferencesManager.appPaused else {
            activityMonitor?.startMonitoring()
            MGLog.debug("[MicGuard.App] applyStoredPreferences: app is PAUSED — no guards started")
            return
        }
        // Apply input device lock if enabled
        if preferencesManager.inputDeviceLockEnabled {
            let priorityOrder = preferencesManager.preferredInputDeviceOrder
            if !priorityOrder.isEmpty {
                deviceWatchdog?.startWatching(devicePriorityOrder: priorityOrder)
            } else {
                MGLog.debug("[MicGuard.App] applyStoredPreferences: lock enabled but priority is empty — watchdog NOT started")
            }
        } else {
            MGLog.debug("[MicGuard.App] applyStoredPreferences: lock is DISABLED — watchdog NOT started")
        }
        updateActivityMonitorDeviceOverride()

        // Apply output device lock if enabled
        if preferencesManager.outputDeviceLockEnabled {
            let priorityOrder = preferencesManager.preferredOutputDeviceOrder
            if !priorityOrder.isEmpty {
                outputDeviceWatchdog?.startWatching(devicePriorityOrder: priorityOrder)
            }
        }

        // Apply volume control strategy
        applyVolumeControlStrategy()
    }
    
    private func applyVolumeControlStrategy() {
        let strategy = preferencesManager.volumeControlStrategy
        let targetVol = preferencesManager.targetVolume

        // ActivityMonitor ALWAYS runs (for ON AIR indicator and input level display)
        activityMonitor?.startMonitoring()

        guard !preferencesManager.appPaused else {
            volumeGuard?.stopGuarding()
            return
        }

        switch strategy {
        case .none:
            volumeGuard?.stopGuarding()
            
        case .lockVolume:
            volumeGuard?.startGuarding(targetVolume: targetVol)
            
        case .resetWhenMicStops:
            volumeGuard?.stopGuarding()
        }
    }
    
    private func setupNotificationObservers() {
        // Auto-switch output device on connect. Also refresh the ActivityMonitor
        // override — a stale device reference there breaks meeting-end detection.
        audioDeviceManager?.devicesChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleInputAutoSwitch()
                self?.handleOutputAutoSwitch()
                self?.updateActivityMonitorDeviceOverride()
                self?.scheduleDelayedAutoSwitchChecks()
            }
            .store(in: &cancellables)

        // User clicked Re-apply in the popover — clear any yielded watchdog state.
        NotificationCenter.default.publisher(for: .userRequestedResumeInputProtection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.deviceWatchdog?.resumeProtection()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .userRequestedResumeOutputProtection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.outputDeviceWatchdog?.resumeProtection()
            }
            .store(in: &cancellables)

        // User accepted the "stop fighting?" offer — yield deliberately, and if the
        // offer named the device they were trying to use, switch to it for them.
        NotificationCenter.default.publisher(for: .userRequestedYieldInputProtection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                self.deviceWatchdog?.yieldNow()
                if let name = notification.userInfo?["deviceName"] as? String,
                   let device = self.audioDeviceManager?.inputDevices(withName: name).first {
                    _ = self.audioDeviceManager?.setDefaultInputDevice(device)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .userRequestedYieldOutputProtection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                self.outputDeviceWatchdog?.yieldNow()
                if let name = notification.userInfo?["deviceName"] as? String,
                   let device = self.audioDeviceManager?.outputDevices(withName: name).first {
                    _ = self.audioDeviceManager?.setDefaultOutputDevice(device)
                }
            }
            .store(in: &cancellables)

        // Apply per-device output volume when the system output changes.
        // Set-once-on-activation semantic: we nudge the device's volume to the
        // user's saved default exactly once when it becomes the default output,
        // then leave it alone (no continuous enforcement). Lets users have
        // wildly different speakers without manually balancing every switch.
        audioDeviceManager?.defaultOutputChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device in
                self?.applyDefaultVolumeIfSet(for: device)
            }
            .store(in: &cancellables)

        // Observe preferences changes via Combine
        preferencesManager.preferencesChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] key in
                self?.handlePreferenceChange(key: key)
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.addObserver(
            forName: .preferredInputDeviceChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let _ = notification.object as? String else { return }

            // Update device watchdog if enabled. A running watchdog gets the new
            // order in place — a stop/start cycle would wipe yielded state and the
            // override counter, so any list edit would silently re-arm enforcement.
            if self.preferencesManager.inputDeviceLockEnabled, !self.preferencesManager.appPaused {
                let priorityOrder = self.preferencesManager.preferredInputDeviceOrder
                if priorityOrder.isEmpty {
                    self.deviceWatchdog?.stopWatching()
                    // stopWatching clears yield without firing onProtectionResumed —
                    // sync the popover mirror so it doesn't show a dead "Paused".
                    NotificationCenter.default.post(name: .watchdogYieldStateChanged, object: nil, userInfo: [
                        "direction": "input", "yielded": false,
                    ])
                } else if self.deviceWatchdog?.isWatching == true {
                    self.deviceWatchdog?.updateDevicePriorityOrder(priorityOrder)
                } else {
                    self.deviceWatchdog?.startWatching(devicePriorityOrder: priorityOrder)
                }
            }
            self.updateActivityMonitorDeviceOverride()
        }

        NotificationCenter.default.addObserver(
            forName: .preferredOutputDeviceChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let _ = notification.object as? String else { return }

            // Update output device watchdog if enabled — same in-place update as input
            // so yielded state survives list edits.
            if self.preferencesManager.outputDeviceLockEnabled, !self.preferencesManager.appPaused {
                let priorityOrder = self.preferencesManager.preferredOutputDeviceOrder
                if priorityOrder.isEmpty {
                    self.outputDeviceWatchdog?.stopWatching()
                    NotificationCenter.default.post(name: .watchdogYieldStateChanged, object: nil, userInfo: [
                        "direction": "output", "yielded": false,
                    ])
                } else if self.outputDeviceWatchdog?.isWatching == true {
                    self.outputDeviceWatchdog?.updateDevicePriorityOrder(priorityOrder)
                } else {
                    self.outputDeviceWatchdog?.startWatching(devicePriorityOrder: priorityOrder)
                }
            }
        }
    }
    
    /// A device the input watchdog / auto-switch may route to. The built-in mic
    /// is physically unusable while the lid is closed even though CoreAudio
    /// keeps it enumerated and alive.
    private func isUsableInput(_ device: AudioDevice) -> Bool {
        guard clamshellMonitor?.isLidClosed == true else { return true }
        return device.transportType != kAudioDeviceTransportTypeBuiltIn
    }

    /// macOS often routes the default AFTER the device-list event — AirPods finish
    /// HFP negotiation 2-5s post-connect and only then flip the default input.
    /// Auto-switch at the list event alone sees "already on the top device" and
    /// does nothing, so the late flip wins. Re-run a few times so the settled
    /// routing loses to the priority order (mirrors the watchdog's delayed checks).
    private func scheduleDelayedAutoSwitchChecks() {
        for delay in [0.5, 2.0, 5.0] {
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                self?.handleInputAutoSwitch()
                self?.handleOutputAutoSwitch()
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func handleInputAutoSwitch() {
        guard !preferencesManager.appPaused,
              preferencesManager.inputAutoSwitchEnabled,
              let audioManager = audioDeviceManager else { return }

        // Respect a yielded lock: the user deliberately chose a non-preferred
        // device — unrelated device-list churn must not snatch it back.
        guard deviceWatchdog?.isYielded != true else { return }

        let priorityOrder = preferencesManager.preferredInputDeviceOrder
        guard !priorityOrder.isEmpty else { return }

        var bestDevice: AudioDevice?
        for uid in priorityOrder {
            if let device = audioManager.device(forUID: uid), device.isInput, isUsableInput(device) {
                bestDevice = device
                break
            }
            if let name = preferencesManager.cachedDeviceName(for: uid) {
                let matches = audioManager.inputDevices(withName: name)
                if matches.count == 1, isUsableInput(matches[0]) {
                    bestDevice = matches[0]
                    preferencesManager.replaceDeviceUID(oldUID: uid, newUID: matches[0].uid)
                    break
                }
            }
        }

        guard let target = bestDevice,
              let current = audioManager.defaultInputDevice,
              current.uid != target.uid else { return }

        // Auto-switch is MicGuard routing to a preferred device on connect — not a
        // blocked hijack. Green feedback, no hijack stat.
        MGLog.debug("[MicGuard.AppDelegate] INPUT SWITCHED (auto-switch) — \(current.name) → \(target.name)")
        _ = audioManager.setDefaultInputDevice(target)
        statusBarController?.flashLabel("INPUT SWITCHED", background: .systemGreen)
    }

    private func applyDefaultVolumeIfSet(for device: AudioDevice?) {
        guard !preferencesManager.appPaused,
              let device = device,
              let manager = audioDeviceManager,
              let target = preferencesManager.outputDeviceVolume(for: device.uid) else { return }
        let ok = manager.setOutputVolume(target, for: device)
        MGLog.debug("[MicGuard.AppDelegate] applied per-device output volume \(Int(target * 100))% to \(device.name) ok=\(ok)")
    }

    private func handleOutputAutoSwitch() {
        guard !preferencesManager.appPaused,
              preferencesManager.outputAutoSwitchEnabled,
              let audioManager = audioDeviceManager else { return }

        // Respect a yielded lock — same rationale as handleInputAutoSwitch.
        guard outputDeviceWatchdog?.isYielded != true else { return }

        let priorityOrder = preferencesManager.preferredOutputDeviceOrder
        guard !priorityOrder.isEmpty else { return }

        // Find the highest-priority connected output device
        var bestDevice: AudioDevice?
        for uid in priorityOrder {
            if let device = audioManager.device(forUID: uid), device.isOutput {
                bestDevice = device
                break
            }
            // Try name-based fallback
            if let name = preferencesManager.cachedDeviceName(for: uid) {
                let matches = audioManager.outputDevices(withName: name)
                if matches.count == 1 {
                    bestDevice = matches[0]
                    preferencesManager.replaceOutputDeviceUID(oldUID: uid, newUID: matches[0].uid)
                    break
                }
            }
        }

        guard let target = bestDevice,
              let current = audioManager.defaultOutputDevice,
              current.uid != target.uid else { return }

        MGLog.debug("[MicGuard.AppDelegate] OUTPUT SWITCHED (auto-switch) — \(current.name) → \(target.name)")
        _ = audioManager.setDefaultOutputDevice(target)
        statusBarController?.flashLabel("OUTPUT SWITCHED", background: .systemGreen)
    }

    /// Tells ActivityMonitor which device to treat as the "in use" source for the On Air indicator.
    /// When the input lock is active, we track the locked device directly so the indicator stays
    /// correct even if macOS briefly switches the system default to AirPods.
    private func updateActivityMonitorDeviceOverride() {
        // While paused nothing is enforced, so the "locked device" concept doesn't
        // apply — monitor the actual system default for the On Air indicator.
        guard !preferencesManager.appPaused else {
            activityMonitor?.overrideMonitoredDevice = nil
            return
        }
        guard preferencesManager.inputDeviceLockEnabled else {
            activityMonitor?.overrideMonitoredDevice = nil
            MGLog.debug("[MicGuard.App] override cleared (lock disabled)")
            return
        }
        let priorityOrder = preferencesManager.preferredInputDeviceOrder
        for uid in priorityOrder {
            if let device = audioDeviceManager?.device(forUID: uid), device.isInput, isUsableInput(device) {
                activityMonitor?.overrideMonitoredDevice = device
                MGLog.debug("[MicGuard.App] override set to \(device.name)")
                return
            }
            if let name = preferencesManager.cachedDeviceName(for: uid),
               let device = audioDeviceManager?.inputDevices(withName: name).first,
               isUsableInput(device) {
                activityMonitor?.overrideMonitoredDevice = device
                MGLog.debug("[MicGuard.App] override set to \(device.name) (name-matched)")
                return
            }
        }
        activityMonitor?.overrideMonitoredDevice = nil
        MGLog.debug("[MicGuard.App] override cleared (no preferred device available)")
    }

    private func handlePreferenceChange(key: String) {
        // Handle Target Volume Change
        if key == "TargetVolume" {
            let newVolume = preferencesManager.targetVolume
            volumeGuard?.updateTargetVolume(newVolume)
            
            // Explicitly set the volume immediately for better UX
            // This ensures the slider feels responsive even if locking is disabled
            volumeGuard?.setVolume(level: newVolume)
        }
        
        // Handle Volume Strategy Change
        if key == "VolumeControlStrategy" {
            applyVolumeControlStrategy()
        }
        
        // Handle Input Device Lock Toggle
        if key == "InputDeviceLockEnabled" {
            if preferencesManager.inputDeviceLockEnabled, !preferencesManager.appPaused {
                let priorityOrder = preferencesManager.preferredInputDeviceOrder
                if !priorityOrder.isEmpty {
                    deviceWatchdog?.startWatching(devicePriorityOrder: priorityOrder)
                }
            } else {
                deviceWatchdog?.stopWatching()
            }
            updateActivityMonitorDeviceOverride()
        }

        // Handle master pause toggle
        if key == "AppPaused" {
            if preferencesManager.appPaused {
                deviceWatchdog?.stopWatching()
                outputDeviceWatchdog?.stopWatching()
                volumeGuard?.stopGuarding()
                updateActivityMonitorDeviceOverride()
                // stopWatching clears yield internally without firing callbacks.
                for direction in ["input", "output"] {
                    NotificationCenter.default.post(name: .watchdogYieldStateChanged, object: nil, userInfo: [
                        "direction": direction, "yielded": false,
                    ])
                }
                MGLog.debug("[MicGuard.App] paused — all enforcement stopped")
            } else {
                MGLog.debug("[MicGuard.App] resumed — re-applying stored preferences")
                applyStoredPreferences()
            }
        }

        // Handle auto-resume toggle change
        if key == "AutoResumeOnTopPriorityPick" {
            let enabled = preferencesManager.autoResumeOnTopPriorityPick
            deviceWatchdog?.autoResumeEnabled = enabled
            outputDeviceWatchdog?.autoResumeEnabled = enabled
        }

        // Handle Output Device Lock Toggle
        if key == "OutputDeviceLockEnabled" {
            if preferencesManager.outputDeviceLockEnabled, !preferencesManager.appPaused {
                let priorityOrder = preferencesManager.preferredOutputDeviceOrder
                if !priorityOrder.isEmpty {
                    outputDeviceWatchdog?.startWatching(devicePriorityOrder: priorityOrder)
                }
            } else {
                outputDeviceWatchdog?.stopWatching()
            }
        }
    }
}
