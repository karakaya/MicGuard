//
//  PreferencesManager.swift
//  MicGuard
//
//  Manages app preferences using UserDefaults
//

import Foundation
import Combine

// MARK: - Volume Control Strategy

enum MicInUseIndicatorStyle: String, CaseIterable {
    case orangePill
    case redTint
    case none
}

enum VolumeControlStrategy: String, CaseIterable {
    case none
    case lockVolume
    case resetWhenMicStops
    
    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .lockVolume:
            return "Lock Input Volume (Continuous Protection)"
        case .resetWhenMicStops:
            return "Reset When Mic Stops"
        }
    }
}

// MARK: - Protocol for Testability

protocol PreferencesManaging: AnyObject {
    // Input Device Preferences
    var preferredInputDeviceUID: String? { get set }
    var preferredInputDeviceOrder: [String] { get set }
    var inputDeviceLockEnabled: Bool { get set }
    var inputAutoSwitchEnabled: Bool { get set }

    // Output Device Preferences
    var preferredOutputDeviceUID: String? { get set }
    var preferredOutputDeviceOrder: [String] { get set }
    var outputDeviceLockEnabled: Bool { get set }
    var outputAutoSwitchEnabled: Bool { get set }

    // Volume Preferences
    var volumeControlStrategy: VolumeControlStrategy { get set }
    var targetVolume: Float { get set }

    // App Settings
    var launchAtLogin: Bool { get set }
    var showInMenuBar: Bool { get set }
    var showNotifications: Bool { get set }
    /// Master kill switch: while true, every enforcement feature is off.
    var appPaused: Bool { get set }
    var showStats: Bool { get set }
    var micInUseIndicatorStyle: MicInUseIndicatorStyle { get set }
    var autoYieldOnRepeatedOverride: Bool { get set }
    var autoResumeOnTopPriorityPick: Bool { get set }
    var hideVirtualDevices: Bool { get set }

    // Input device order management
    func moveDevice(uid: String, direction: MoveDirection)
    func addDeviceToOrder(_ uid: String)
    func removeDeviceFromOrder(_ uid: String)

    // Output device order management
    func moveOutputDevice(uid: String, direction: MoveDirection)
    func addOutputDeviceToOrder(_ uid: String)
    func removeOutputDeviceFromOrder(_ uid: String)

    // Device name cache (for showing names when disconnected)
    func cacheDeviceName(uid: String, name: String)
    func cachedDeviceName(for uid: String) -> String?

    // Per-output-device default volume (0.0–1.0).
    // Applied once when the device becomes the system output.
    func outputDeviceVolume(for uid: String) -> Float?
    func setOutputDeviceVolume(_ volume: Float?, for uid: String)

    // UID migration (for name-based device matching after reconnection)
    func replaceDeviceUID(oldUID: String, newUID: String)
    func replaceOutputDeviceUID(oldUID: String, newUID: String)

    // Observable changes
    var preferencesChangedPublisher: PassthroughSubject<String, Never> { get }
}

// MARK: - UserDefaults Keys

private enum PreferenceKey: String {
    // Input Device Preferences
    case preferredInputDeviceUID = "PreferredInputDeviceUID"
    case preferredInputDeviceOrder = "PreferredInputDeviceOrder"
    case inputDeviceLockEnabled = "InputDeviceLockEnabled"
    case inputAutoSwitchEnabled = "InputAutoSwitchEnabled"

    // Output Device Preferences
    case preferredOutputDeviceUID = "PreferredOutputDeviceUID"
    case preferredOutputDeviceOrder = "PreferredOutputDeviceOrder"
    case outputDeviceLockEnabled = "OutputDeviceLockEnabled"
    case outputAutoSwitchEnabled = "OutputAutoSwitchEnabled"
    
    // Volume Preferences
    case volumeControlStrategy = "VolumeControlStrategy"
    case targetVolume = "TargetVolume"
    
    // Device Name Cache
    case deviceNameCache = "DeviceNameCache"

    // Per-output-device default volume (UID → Float scalar)
    case outputDeviceVolumes = "OutputDeviceVolumes"

    // App Settings
    case launchAtLogin = "LaunchAtLogin"
    case showInMenuBar = "ShowInMenuBar"
    case showNotifications = "ShowNotifications"
    case appPaused = "AppPaused"
    case showStats = "ShowStats"
    case micInUseIndicatorStyle = "MicInUseIndicatorStyle"
    case autoYieldOnRepeatedOverride = "AutoYieldOnRepeatedOverride"
    case autoResumeOnTopPriorityPick = "AutoResumeOnTopPriorityPick"
    case hideVirtualDevices = "HideVirtualDevices"
}

// MARK: - PreferencesManager Implementation

class PreferencesManager: PreferencesManaging {
    
    // MARK: - Singleton
    
    static let shared = PreferencesManager()
    
    // MARK: - Properties
    
    private let defaults: UserDefaults
    let preferencesChangedPublisher = PassthroughSubject<String, Never>()
    
    // MARK: - Initialization
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Migration MUST run before registerDefaults(): string(forKey:) consults the
        // registration domain, so registering first makes the "new key not set yet"
        // guard in the migration permanently false and the migration dead code.
        migrateOldPreferences()
        registerDefaults()
    }
    
    private func registerDefaults() {
        defaults.register(defaults: [
            PreferenceKey.inputDeviceLockEnabled.rawValue: false,
            PreferenceKey.inputAutoSwitchEnabled.rawValue: false,
            PreferenceKey.outputDeviceLockEnabled.rawValue: false,
            PreferenceKey.outputAutoSwitchEnabled.rawValue: false,
            PreferenceKey.volumeControlStrategy.rawValue: VolumeControlStrategy.resetWhenMicStops.rawValue,
            PreferenceKey.targetVolume.rawValue: Float(0.75),
            PreferenceKey.launchAtLogin.rawValue: false,
            PreferenceKey.showInMenuBar.rawValue: true,
            PreferenceKey.showNotifications.rawValue: true,
            PreferenceKey.appPaused.rawValue: false,
            PreferenceKey.showStats.rawValue: false,
            PreferenceKey.micInUseIndicatorStyle.rawValue: MicInUseIndicatorStyle.redTint.rawValue,
            PreferenceKey.autoYieldOnRepeatedOverride.rawValue: true,
            // Auto-resume defaults on: after a deliberate yield, picking your #1
            // device again is an unambiguous "resume" signal — fewer stuck-paused
            // states for users who never find the Resume button.
            PreferenceKey.autoResumeOnTopPriorityPick.rawValue: true,
            // Virtual/loopback devices (Teams Audio, BlackHole) hidden by default —
            // they confuse first-run users and macOS refuses them as defaults anyway.
            PreferenceKey.hideVirtualDevices.rawValue: true
        ])
    }
    
    // MARK: - Device Preferences
    
    var preferredInputDeviceUID: String? {
        get { defaults.string(forKey: PreferenceKey.preferredInputDeviceUID.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.preferredInputDeviceUID.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.preferredInputDeviceUID.rawValue)
        }
    }
    
    var inputDeviceLockEnabled: Bool {
        get { defaults.bool(forKey: PreferenceKey.inputDeviceLockEnabled.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.inputDeviceLockEnabled.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.inputDeviceLockEnabled.rawValue)
        }
    }

    var inputAutoSwitchEnabled: Bool {
        get { defaults.bool(forKey: PreferenceKey.inputAutoSwitchEnabled.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.inputAutoSwitchEnabled.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.inputAutoSwitchEnabled.rawValue)
        }
    }
    
    var preferredInputDeviceOrder: [String] {
        get {
            defaults.array(forKey: PreferenceKey.preferredInputDeviceOrder.rawValue) as? [String] ?? []
        }
        set {
            // Deduplicate while preserving order
            var seen = Set<String>()
            let unique = newValue.filter { seen.insert($0).inserted }
            
            defaults.set(unique, forKey: PreferenceKey.preferredInputDeviceOrder.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.preferredInputDeviceOrder.rawValue)
        }
    }
    
    // MARK: - Output Device Preferences

    var preferredOutputDeviceUID: String? {
        get { defaults.string(forKey: PreferenceKey.preferredOutputDeviceUID.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.preferredOutputDeviceUID.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.preferredOutputDeviceUID.rawValue)
        }
    }

    var outputDeviceLockEnabled: Bool {
        get { defaults.bool(forKey: PreferenceKey.outputDeviceLockEnabled.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.outputDeviceLockEnabled.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.outputDeviceLockEnabled.rawValue)
        }
    }

    var preferredOutputDeviceOrder: [String] {
        get {
            defaults.array(forKey: PreferenceKey.preferredOutputDeviceOrder.rawValue) as? [String] ?? []
        }
        set {
            var seen = Set<String>()
            let unique = newValue.filter { seen.insert($0).inserted }
            defaults.set(unique, forKey: PreferenceKey.preferredOutputDeviceOrder.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.preferredOutputDeviceOrder.rawValue)
        }
    }

    var outputAutoSwitchEnabled: Bool {
        get { defaults.bool(forKey: PreferenceKey.outputAutoSwitchEnabled.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.outputAutoSwitchEnabled.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.outputAutoSwitchEnabled.rawValue)
        }
    }

    // MARK: - Volume Preferences
    
    var volumeControlStrategy: VolumeControlStrategy {
        get {
            guard let rawValue = defaults.string(forKey: PreferenceKey.volumeControlStrategy.rawValue),
                  let strategy = VolumeControlStrategy(rawValue: rawValue) else {
                return .none
            }
            return strategy
        }
        set {
            defaults.set(newValue.rawValue, forKey: PreferenceKey.volumeControlStrategy.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.volumeControlStrategy.rawValue)
        }
    }
    
    var targetVolume: Float {
        get { defaults.float(forKey: PreferenceKey.targetVolume.rawValue) }
        set {
            let clamped = max(0, min(1, newValue))
            defaults.set(clamped, forKey: PreferenceKey.targetVolume.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.targetVolume.rawValue)
        }
    }
    
    // MARK: - App Settings
    
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: PreferenceKey.launchAtLogin.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.launchAtLogin.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.launchAtLogin.rawValue)
            
            // Actually register/unregister with the system
            LaunchAtLoginManager.shared.setLaunchAtLogin(enabled: newValue)
        }
    }
    
    var showInMenuBar: Bool {
        get { defaults.bool(forKey: PreferenceKey.showInMenuBar.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.showInMenuBar.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.showInMenuBar.rawValue)
        }
    }
    
    var appPaused: Bool {
        get { defaults.bool(forKey: PreferenceKey.appPaused.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.appPaused.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.appPaused.rawValue)
        }
    }

    var showNotifications: Bool {
        get { defaults.bool(forKey: PreferenceKey.showNotifications.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.showNotifications.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.showNotifications.rawValue)
        }
    }
    
    var showStats: Bool {
        get { defaults.bool(forKey: PreferenceKey.showStats.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.showStats.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.showStats.rawValue)
        }
    }

    var micInUseIndicatorStyle: MicInUseIndicatorStyle {
        get {
            guard let raw = defaults.string(forKey: PreferenceKey.micInUseIndicatorStyle.rawValue),
                  let style = MicInUseIndicatorStyle(rawValue: raw) else {
                return .redTint
            }
            return style
        }
        set {
            defaults.set(newValue.rawValue, forKey: PreferenceKey.micInUseIndicatorStyle.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.micInUseIndicatorStyle.rawValue)
        }
    }

    var autoYieldOnRepeatedOverride: Bool {
        get { defaults.bool(forKey: PreferenceKey.autoYieldOnRepeatedOverride.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.autoYieldOnRepeatedOverride.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.autoYieldOnRepeatedOverride.rawValue)
        }
    }

    var autoResumeOnTopPriorityPick: Bool {
        get { defaults.bool(forKey: PreferenceKey.autoResumeOnTopPriorityPick.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.autoResumeOnTopPriorityPick.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.autoResumeOnTopPriorityPick.rawValue)
        }
    }

    var hideVirtualDevices: Bool {
        get { defaults.bool(forKey: PreferenceKey.hideVirtualDevices.rawValue) }
        set {
            defaults.set(newValue, forKey: PreferenceKey.hideVirtualDevices.rawValue)
            preferencesChangedPublisher.send(PreferenceKey.hideVirtualDevices.rawValue)
        }
    }
    
    // MARK: - Reset
    
    func resetToDefaults() {
        let domain = Bundle.main.bundleIdentifier ?? "com.micguard.app"
        defaults.removePersistentDomain(forName: domain)
        registerDefaults()
    }
    
    // MARK: - Migration
    
    private func migrateOldPreferences() {
        // Migrate single preferredInputDeviceUID to array if needed
        if preferredInputDeviceOrder.isEmpty,
           let oldUID = preferredInputDeviceUID {
            preferredInputDeviceOrder = [oldUID]
        }
        
        // Migrate old volume control preferences to new strategy
        let oldLockEnabledKey = "InputVolumeLockEnabled"
        let oldAutoResetKey = "AutoResetEnabled"
        let oldLockedVolumeKey = "LockedInputVolume"
        let oldResetVolumeKey = "DefaultResetVolume"
        
        // Gate on legacy-key presence (a fresh install has none and keeps the
        // registered default strategy) AND on the new strategy key having no
        // PERSISTED value — a user who already configured the new strategy while
        // this migration was dead code must not have it overwritten. A plain
        // string(forKey:) nil-check can't detect that: the registration domain is
        // process-wide, so any earlier PreferencesManager instance makes it
        // non-nil. Probe instead: removeObject strips only the persisted value,
        // leaving the registered default (if any) visible.
        let hasLegacyVolumeKeys = defaults.object(forKey: oldLockEnabledKey) != nil
            || defaults.object(forKey: oldAutoResetKey) != nil
            || defaults.object(forKey: oldLockedVolumeKey) != nil
            || defaults.object(forKey: oldResetVolumeKey) != nil

        if hasLegacyVolumeKeys {
            let strategyKey = PreferenceKey.volumeControlStrategy.rawValue
            let currentStrategy = defaults.string(forKey: strategyKey)
            defaults.removeObject(forKey: strategyKey)
            let registeredOnly = defaults.string(forKey: strategyKey)
            if let currentStrategy = currentStrategy {
                defaults.set(currentStrategy, forKey: strategyKey)
            }
            let hasPersistedStrategy = currentStrategy != nil && currentStrategy != registeredOnly

            if !hasPersistedStrategy {
                let oldLockEnabled = defaults.bool(forKey: oldLockEnabledKey)
                let oldAutoResetEnabled = defaults.bool(forKey: oldAutoResetKey)

                // Determine new strategy based on old settings
                if oldLockEnabled {
                    volumeControlStrategy = .lockVolume
                    // Migrate target volume from old locked volume
                    if let oldVolume = defaults.object(forKey: oldLockedVolumeKey) as? Float {
                        targetVolume = oldVolume
                    }
                } else if oldAutoResetEnabled {
                    volumeControlStrategy = .resetWhenMicStops
                    // Migrate target volume from old reset volume
                    if let oldVolume = defaults.object(forKey: oldResetVolumeKey) as? Float {
                        targetVolume = oldVolume
                    }
                } else {
                    volumeControlStrategy = .none
                }
            }

            // Clean up old keys either way — the migration is one-shot.
            defaults.removeObject(forKey: oldLockEnabledKey)
            defaults.removeObject(forKey: oldAutoResetKey)
            defaults.removeObject(forKey: oldLockedVolumeKey)
            defaults.removeObject(forKey: oldResetVolumeKey)
        }
    }
    
    // MARK: - Device Order Management
    
    func moveDevice(uid: String, direction: MoveDirection) {
        var order = preferredInputDeviceOrder
        guard let currentIndex = order.firstIndex(of: uid) else { return }
        
        switch direction {
        case .up:
            guard currentIndex > 0 else { return }
            order.swapAt(currentIndex, currentIndex - 1)
        case .down:
            guard currentIndex < order.count - 1 else { return }
            order.swapAt(currentIndex, currentIndex + 1)
        case .toTop:
            order.remove(at: currentIndex)
            order.insert(uid, at: 0)
        }
        
        preferredInputDeviceOrder = order
    }
    
    func addDeviceToOrder(_ uid: String) {
        var order = preferredInputDeviceOrder
        guard !order.contains(uid) else { return }
        order.append(uid)
        preferredInputDeviceOrder = order
    }
    
    func removeDeviceFromOrder(_ uid: String) {
        var order = preferredInputDeviceOrder
        order.removeAll { $0 == uid }
        preferredInputDeviceOrder = order
    }

    // MARK: - Output Device Order Management

    func moveOutputDevice(uid: String, direction: MoveDirection) {
        var order = preferredOutputDeviceOrder
        guard let currentIndex = order.firstIndex(of: uid) else { return }

        switch direction {
        case .up:
            guard currentIndex > 0 else { return }
            order.swapAt(currentIndex, currentIndex - 1)
        case .down:
            guard currentIndex < order.count - 1 else { return }
            order.swapAt(currentIndex, currentIndex + 1)
        case .toTop:
            order.remove(at: currentIndex)
            order.insert(uid, at: 0)
        }

        preferredOutputDeviceOrder = order
    }

    func addOutputDeviceToOrder(_ uid: String) {
        var order = preferredOutputDeviceOrder
        guard !order.contains(uid) else { return }
        order.append(uid)
        preferredOutputDeviceOrder = order
    }

    func removeOutputDeviceFromOrder(_ uid: String) {
        var order = preferredOutputDeviceOrder
        order.removeAll { $0 == uid }
        preferredOutputDeviceOrder = order
    }

    // MARK: - Device Name Cache

    func cacheDeviceName(uid: String, name: String) {
        var cache = defaults.dictionary(forKey: PreferenceKey.deviceNameCache.rawValue) as? [String: String] ?? [:]
        cache[uid] = name
        defaults.set(cache, forKey: PreferenceKey.deviceNameCache.rawValue)
    }

    func cachedDeviceName(for uid: String) -> String? {
        let cache = defaults.dictionary(forKey: PreferenceKey.deviceNameCache.rawValue) as? [String: String]
        return cache?[uid]
    }

    // MARK: - Per-Output-Device Volume

    func outputDeviceVolume(for uid: String) -> Float? {
        guard let dict = defaults.dictionary(forKey: PreferenceKey.outputDeviceVolumes.rawValue) as? [String: Double],
              let value = dict[uid] else {
            return nil
        }
        return Float(value)
    }

    func setOutputDeviceVolume(_ volume: Float?, for uid: String) {
        var dict = (defaults.dictionary(forKey: PreferenceKey.outputDeviceVolumes.rawValue) as? [String: Double]) ?? [:]
        if let volume = volume {
            dict[uid] = Double(max(0, min(1, volume)))
        } else {
            dict.removeValue(forKey: uid)
        }
        defaults.set(dict, forKey: PreferenceKey.outputDeviceVolumes.rawValue)
        preferencesChangedPublisher.send(PreferenceKey.outputDeviceVolumes.rawValue)
    }

    // MARK: - UID Migration

    func replaceDeviceUID(oldUID: String, newUID: String) {
        // Update priority order
        var order = preferredInputDeviceOrder
        if let index = order.firstIndex(of: oldUID) {
            order[index] = newUID
            preferredInputDeviceOrder = order
        }

        // Migrate cached name to new UID
        if let name = cachedDeviceName(for: oldUID) {
            cacheDeviceName(uid: newUID, name: name)
        }

        // Update preferredInputDeviceUID if it was the old one
        if preferredInputDeviceUID == oldUID {
            preferredInputDeviceUID = newUID
        }
    }

    func replaceOutputDeviceUID(oldUID: String, newUID: String) {
        var order = preferredOutputDeviceOrder
        if let index = order.firstIndex(of: oldUID) {
            order[index] = newUID
            preferredOutputDeviceOrder = order
        }

        if let name = cachedDeviceName(for: oldUID) {
            cacheDeviceName(uid: newUID, name: name)
        }

        if preferredOutputDeviceUID == oldUID {
            preferredOutputDeviceUID = newUID
        }
    }
}

// MARK: - Move Direction

enum MoveDirection {
    case up
    case down
    case toTop
}

// MARK: - Launch at Login Manager

import ServiceManagement

class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()
    
    func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Launch at login registration failed
            }
        } else {
            // Fallback for older macOS versions
        }
    }
    
    @available(macOS 13.0, *)
    var isEnabled: Bool {
        return SMAppService.mainApp.status == .enabled
    }
}
