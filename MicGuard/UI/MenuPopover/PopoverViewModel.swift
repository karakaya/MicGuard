//
//  PopoverViewModel.swift
//  MicGuard
//
//  ObservableObject bridge that republishes manager state for SwiftUI.
//

import Foundation
import Combine
import AppKit

struct DeviceEntry: Identifiable, Equatable {
    let id: String        // device UID
    let displayName: String
    let isConnected: Bool
    let isActive: Bool
    let priority: Int     // 1-based
    let unsettable: Bool  // true if macOS rejected this device as default in this session
}

struct CustomOutputVolumeEntry: Identifiable, Equatable {
    var id: String { uid }
    let uid: String
    let displayName: String
    let volume: Float       // 0.0–1.0
    let isConnected: Bool
}

struct AddableOutputDevice: Identifiable, Hashable {
    var id: String { uid }
    let uid: String
    let displayName: String
}

/// A pending "stop fighting?" offer from a watchdog that keeps blocking
/// repeated switches to the same non-preferred device.
struct FightOffer: Equatable {
    let attemptedName: String   // the device something keeps switching to
    let preferredName: String   // the device MicGuard is holding
    let createdAt: Date

    /// Offers go stale — accepting one hours later would yield and switch to a
    /// contest "winner" that may be long gone.
    var isStale: Bool {
        Date().timeIntervalSince(createdAt) > 300
    }
}

@MainActor
final class PopoverViewModel: ObservableObject {

    // MARK: - Dependencies

    let audioDeviceManager: AudioDeviceManaging
    let preferencesManager: PreferencesManaging
    let statsManager: StatsManaging
    weak var activityMonitor: ActivityMonitor?


    // MARK: - Published state

    @Published var currentInputDeviceName: String = "No Microphone"
    @Published var preferredInputDisplayName: String? = nil

    @Published var inputDeviceLockEnabled: Bool = false
    @Published var inputAutoSwitchEnabled: Bool = false
    @Published var inputDevices: [DeviceEntry] = []

    @Published var volumeStrategy: VolumeControlStrategy = .none
    @Published var targetVolume: Float = 0.75

    @Published var outputDeviceLockEnabled: Bool = false
    @Published var outputAutoSwitchEnabled: Bool = false
    @Published var outputDevices: [DeviceEntry] = []
    @Published var currentOutputDisplayName: String? = nil
    @Published var preferredOutputDisplayName: String? = nil
    @Published var customOutputVolumes: [CustomOutputVolumeEntry] = []

    @Published var launchAtLogin: Bool = false
    @Published var micInUseIndicatorStyle: MicInUseIndicatorStyle = .orangePill
    @Published var autoResumeOnTopPriorityPick: Bool = false
    @Published var hideVirtualDevices: Bool = false
    @Published var appPaused: Bool = false

    @Published var stats: [StatType: Int] = [:]

    // Watchdog yield state, mirrored from AppDelegate via notifications so the
    // popover tells the truth about whether enforcement is actually running.
    @Published var isInputYielded: Bool = false
    @Published var isOutputYielded: Bool = false
    @Published var inputFightOffer: FightOffer? = nil
    @Published var outputFightOffer: FightOffer? = nil

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var suppressVolumePublish = false

    // UIDs the system silently refused to set as default this session.
    // Most often virtual / loopback devices (BlackHole, Teams Audio, aggregates).
    private var unsettableUIDs: Set<String> = []

    // MARK: - Init

    init(audioDeviceManager: AudioDeviceManaging,
         preferencesManager: PreferencesManaging,
         statsManager: StatsManaging,
         activityMonitor: ActivityMonitor?) {
        self.audioDeviceManager = audioDeviceManager
        self.preferencesManager = preferencesManager
        self.statsManager = statsManager
        self.activityMonitor = activityMonitor

        refreshAll()
        subscribe()
    }

    // MARK: - Subscriptions

    private func subscribe() {
        audioDeviceManager.devicesChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.refreshDeviceLists()
                self?.refreshStatusLine()
            }
            .store(in: &cancellables)

        audioDeviceManager.defaultInputChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshDeviceLists()
                self?.refreshStatusLine()
            }
            .store(in: &cancellables)

        audioDeviceManager.defaultOutputChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshDeviceLists()
                self?.refreshStatusLine()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .preferredInputDeviceChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshDeviceLists()
                self?.refreshStatusLine()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .preferredOutputDeviceChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshDeviceLists()
                self?.refreshStatusLine()
            }
            .store(in: &cancellables)

        statsManager.statsChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStats()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .watchdogYieldStateChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let direction = notification.userInfo?["direction"] as? String,
                      let yielded = notification.userInfo?["yielded"] as? Bool else { return }
                if direction == "input" {
                    self.isInputYielded = yielded
                    if yielded { self.inputFightOffer = nil }
                } else {
                    self.isOutputYielded = yielded
                    if yielded { self.outputFightOffer = nil }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .watchdogFightDetected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let direction = notification.userInfo?["direction"] as? String,
                      let attempted = notification.userInfo?["attempted"] as? String,
                      let preferred = notification.userInfo?["preferred"] as? String else { return }
                let offer = FightOffer(attemptedName: attempted, preferredName: preferred, createdAt: Date())
                if direction == "input" {
                    self.inputFightOffer = offer
                } else {
                    self.outputFightOffer = offer
                }
            }
            .store(in: &cancellables)

        preferencesManager.preferencesChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] key in
                self?.handlePreferenceChange(key: key)
            }
            .store(in: &cancellables)
    }

    private func handlePreferenceChange(key: String) {
        // Re-mirror simple toggles when something else changes them.
        inputDeviceLockEnabled = preferencesManager.inputDeviceLockEnabled
        inputAutoSwitchEnabled = preferencesManager.inputAutoSwitchEnabled
        outputDeviceLockEnabled = preferencesManager.outputDeviceLockEnabled
        outputAutoSwitchEnabled = preferencesManager.outputAutoSwitchEnabled
        volumeStrategy = preferencesManager.volumeControlStrategy
        launchAtLogin = preferencesManager.launchAtLogin
        micInUseIndicatorStyle = preferencesManager.micInUseIndicatorStyle
        autoResumeOnTopPriorityPick = preferencesManager.autoResumeOnTopPriorityPick
        hideVirtualDevices = preferencesManager.hideVirtualDevices
        appPaused = preferencesManager.appPaused

        if !suppressVolumePublish {
            targetVolume = preferencesManager.targetVolume
        }
        refreshStatusLine()
    }

    // MARK: - Refresh

    func refreshAll() {
        // Called on popover open — drop offers from fights that ended long ago.
        if inputFightOffer?.isStale == true { inputFightOffer = nil }
        if outputFightOffer?.isStale == true { outputFightOffer = nil }
        inputDeviceLockEnabled = preferencesManager.inputDeviceLockEnabled
        inputAutoSwitchEnabled = preferencesManager.inputAutoSwitchEnabled
        outputDeviceLockEnabled = preferencesManager.outputDeviceLockEnabled
        outputAutoSwitchEnabled = preferencesManager.outputAutoSwitchEnabled
        volumeStrategy = preferencesManager.volumeControlStrategy
        targetVolume = preferencesManager.targetVolume
        launchAtLogin = preferencesManager.launchAtLogin
        micInUseIndicatorStyle = preferencesManager.micInUseIndicatorStyle
        autoResumeOnTopPriorityPick = preferencesManager.autoResumeOnTopPriorityPick
        hideVirtualDevices = preferencesManager.hideVirtualDevices
        appPaused = preferencesManager.appPaused
        refreshDeviceLists()
        refreshStatusLine()
        refreshStats()
    }

    private func refreshStatusLine() {
        if let device = audioDeviceManager.defaultInputDevice {
            currentInputDeviceName = device.name
        } else {
            currentInputDeviceName = "No Microphone"
        }
        preferredInputDisplayName = computePreferredInputName()

        if let out = audioDeviceManager.defaultOutputDevice {
            currentOutputDisplayName = out.name
        } else {
            currentOutputDisplayName = nil
        }
        preferredOutputDisplayName = computePreferredOutputName()
    }

    private func computePreferredInputName() -> String? {
        for uid in preferencesManager.preferredInputDeviceOrder {
            if let device = audioDeviceManager.device(forUID: uid) {
                return device.name
            }
            if let name = preferencesManager.cachedDeviceName(for: uid) {
                return name
            }
        }
        return nil
    }

    private func computePreferredOutputName() -> String? {
        for uid in preferencesManager.preferredOutputDeviceOrder {
            if let device = audioDeviceManager.device(forUID: uid) {
                return device.name
            }
            if let name = preferencesManager.cachedDeviceName(for: uid) {
                return name
            }
        }
        return nil
    }

    private func refreshStats() {
        var newStats: [StatType: Int] = [:]
        for stat in StatType.allCases {
            newStats[stat] = statsManager.get(stat: stat)
        }
        stats = newStats
    }

    // MARK: - Device list resolution

    private func refreshDeviceLists() {
        inputDevices = resolveDeviceList(
            priorityOrder: preferencesManager.preferredInputDeviceOrder,
            allDevices: audioDeviceManager.inputDevices,
            activeUID: audioDeviceManager.defaultInputDevice?.uid,
            addToOrder: { [weak self] uid in self?.preferencesManager.addDeviceToOrder(uid) },
            replaceUID: { [weak self] old, new in self?.preferencesManager.replaceDeviceUID(oldUID: old, newUID: new) },
            currentOrder: { [weak self] in self?.preferencesManager.preferredInputDeviceOrder ?? [] }
        )

        outputDevices = resolveDeviceList(
            priorityOrder: preferencesManager.preferredOutputDeviceOrder,
            allDevices: audioDeviceManager.outputDevices,
            activeUID: audioDeviceManager.defaultOutputDevice?.uid,
            addToOrder: { [weak self] uid in self?.preferencesManager.addOutputDeviceToOrder(uid) },
            replaceUID: { [weak self] old, new in self?.preferencesManager.replaceOutputDeviceUID(oldUID: old, newUID: new) },
            currentOrder: { [weak self] in self?.preferencesManager.preferredOutputDeviceOrder ?? [] }
        )

        refreshCustomOutputVolumes()
    }

    private func resolveDeviceList(
        priorityOrder: [String],
        allDevices: [AudioDevice],
        activeUID: String?,
        addToOrder: (String) -> Void,
        replaceUID: (String, String) -> Void,
        currentOrder: () -> [String]
    ) -> [DeviceEntry] {

        struct Resolved {
            var device: AudioDevice?
            var uid: String
        }

        var ordered: [Resolved] = []
        // Live devices already resolved to some order entry. Rescue candidates are
        // limited to unclaimed devices so two stale entries with the same cached
        // name can't both collapse onto one live device (duplicate row IDs, and
        // the order setter's dedup would then silently delete an entry).
        var claimedUIDs = Set<String>()
        for uid in priorityOrder {
            var device = allDevices.first { $0.uid == uid }
            if device == nil, let cachedName = preferencesManager.cachedDeviceName(for: uid) {
                let nameMatches = allDevices.filter { $0.name == cachedName && !claimedUIDs.contains($0.uid) }
                if nameMatches.count == 1 {
                    device = nameMatches[0]
                    replaceUID(uid, nameMatches[0].uid)
                    // New UID = re-enumerated hardware; drop the session "unsettable"
                    // flag so the device gets a clean retry (re-flagged if refused again).
                    unsettableUIDs.remove(uid)
                }
            }
            if let claimed = device {
                claimedUIDs.insert(claimed.uid)
            }
            ordered.append(Resolved(device: device, uid: device?.uid ?? uid))
        }

        // Connected devices no order entry resolved to. "Accounted for" means an
        // entry actually claimed the device — a mere cached-name collision with a
        // stale entry must not suppress a physically connected device from the list.
        let snapshot = currentOrder()
        var newDevices = allDevices.filter { device in
            !snapshot.contains(device.uid) && !claimedUIDs.contains(device.uid)
        }

        // A stored UID with no cached name (seeded by the legacy single-UID
        // migration) can never be name-rescued. When exactly one such slot and
        // exactly one unaccounted device exist, adopt in place — otherwise the
        // user's #1 turns into a permanent ghost and their device re-appears at
        // the END of the list as a "new" entry.
        let unnamedStaleSlots = ordered.enumerated().filter { _, entry in
            entry.device == nil && preferencesManager.cachedDeviceName(for: entry.uid) == nil
        }
        if newDevices.count == 1, unnamedStaleSlots.count == 1,
           let slot = unnamedStaleSlots.first,
           !newDevices[0].isLikelyUnsettable {  // never let a virtual device steal the user's slot
            let device = newDevices[0]
            replaceUID(slot.element.uid, device.uid)
            unsettableUIDs.remove(slot.element.uid)
            ordered[slot.offset] = Resolved(device: device, uid: device.uid)
            claimedUIDs.insert(device.uid)
            newDevices = []
        }

        for device in newDevices {
            addToOrder(device.uid)
            ordered.append(Resolved(device: device, uid: device.uid))
        }

        for entry in ordered {
            if let device = entry.device {
                preferencesManager.cacheDeviceName(uid: device.uid, name: device.name)
            }
        }

        let allEntries: [DeviceEntry] = ordered.enumerated().map { index, entry in
            let isConnected = entry.device != nil
            let baseName: String
            if let device = entry.device {
                baseName = device.name
            } else {
                baseName = preferencesManager.cachedDeviceName(for: entry.uid) ?? entry.uid
            }
            let display = isConnected ? baseName : "\(baseName) (disconnected)"
            let likelyUnsettable = entry.device?.isLikelyUnsettable ?? false
            return DeviceEntry(
                id: entry.uid,
                displayName: display,
                isConnected: isConnected,
                isActive: entry.uid == activeUID,
                priority: index + 1,
                unsettable: unsettableUIDs.contains(entry.uid) || likelyUnsettable
            )
        }

        // When the "hide virtual devices" toggle is on, filter virtual/aggregate
        // entries from the display. The stored priority order is untouched —
        // priority numbers remain the stored positions (so "#3" still means
        // 3rd in the actual order even if a virtual #2 is hidden between).
        if hideVirtualDevices {
            return allEntries.filter { !$0.unsettable }
        }
        return allEntries
    }

    // MARK: - Actions: Yield / fight offers

    /// User accepted "stop fighting" — yield and switch to the contested device.
    func acceptInputFightOffer() {
        let attempted = inputFightOffer?.attemptedName
        inputFightOffer = nil
        NotificationCenter.default.post(
            name: .userRequestedYieldInputProtection, object: nil,
            userInfo: attempted.map { ["deviceName": $0] }
        )
    }

    func dismissInputFightOffer() {
        inputFightOffer = nil
    }

    func resumeInputProtection() {
        NotificationCenter.default.post(name: .userRequestedResumeInputProtection, object: nil)
    }

    func acceptOutputFightOffer() {
        let attempted = outputFightOffer?.attemptedName
        outputFightOffer = nil
        NotificationCenter.default.post(
            name: .userRequestedYieldOutputProtection, object: nil,
            userInfo: attempted.map { ["deviceName": $0] }
        )
    }

    func dismissOutputFightOffer() {
        outputFightOffer = nil
    }

    func resumeOutputProtection() {
        NotificationCenter.default.post(name: .userRequestedResumeOutputProtection, object: nil)
    }

    // MARK: - Actions: Input

    func setInputDeviceLockEnabled(_ enabled: Bool) {
        preferencesManager.inputDeviceLockEnabled = enabled
        inputDeviceLockEnabled = enabled
        // Toggling the lock stops/starts the watchdog with fresh (non-yielded)
        // state — reset the mirrors so the popover doesn't show a stale "Paused".
        isInputYielded = false
        inputFightOffer = nil
        NotificationCenter.default.post(name: .inputDeviceLockChanged, object: nil)
    }

    func setInputAutoSwitchEnabled(_ enabled: Bool) {
        preferencesManager.inputAutoSwitchEnabled = enabled
        inputAutoSwitchEnabled = enabled
    }

    /// `displayedIndex` is the row index in the filtered `inputDevices` array.
    /// Move logic is displayed-aware: swaps with the previous/next *visible* row
    /// so the UI behavior is intuitive even when virtual devices are hidden.
    func moveInputDevice(at displayedIndex: Int, direction: MoveDirection) {
        guard displayedIndex >= 0, displayedIndex < inputDevices.count else { return }
        let uid = inputDevices[displayedIndex].id
        var newOrder = preferencesManager.preferredInputDeviceOrder
        guard let currentIdx = newOrder.firstIndex(of: uid) else { return }

        switch direction {
        case .up:
            guard displayedIndex > 0 else { return }
            let prevUID = inputDevices[displayedIndex - 1].id
            guard let prevIdx = newOrder.firstIndex(of: prevUID) else { return }
            newOrder.swapAt(currentIdx, prevIdx)
        case .down:
            guard displayedIndex < inputDevices.count - 1 else { return }
            let nextUID = inputDevices[displayedIndex + 1].id
            guard let nextIdx = newOrder.firstIndex(of: nextUID) else { return }
            newOrder.swapAt(currentIdx, nextIdx)
        case .toTop:
            newOrder.remove(at: currentIdx)
            newOrder.insert(uid, at: 0)
        }

        preferencesManager.preferredInputDeviceOrder = newOrder
        NotificationCenter.default.post(name: .preferredInputDeviceChanged, object: uid)
    }

    func useInputDevice(at displayedIndex: Int) {
        guard displayedIndex >= 0, displayedIndex < inputDevices.count else { return }
        let uid = inputDevices[displayedIndex].id
        let before = audioDeviceManager.defaultInputDevice?.name ?? "nil"
        MGLog.debug("[MicGuard.PopoverVM] useInputDevice CALLED displayedIndex=\(displayedIndex) uid=\(uid) currentDefault=\(before)")

        // Connected devices: try to make them the system default first.
        // Disconnected devices: skip the CoreAudio call, just promote priority —
        // Lock / Auto-switch / Re-apply will activate them when they reconnect.
        if let device = audioDeviceManager.device(forUID: uid) {
            audioDeviceManager.setDefaultInputDevice(device)
            let actualUID = audioDeviceManager.defaultInputDevice?.uid
            if actualUID != device.uid {
                MGLog.debug("[MicGuard.PopoverVM] useInputDevice: macOS rejected \(device.name) (still on \(actualUID ?? "nil"))")
                unsettableUIDs.insert(uid)
                refreshDeviceLists()
                return
            }
            MGLog.debug("[MicGuard.PopoverVM] useInputDevice: \(before) → \(device.name) OK")
            unsettableUIDs.remove(uid)
        }

        preferencesManager.preferredInputDeviceUID = uid
        // Promote to top of stored order if not already #1 there.
        let order = preferencesManager.preferredInputDeviceOrder
        if order.first != uid {
            preferencesManager.moveDevice(uid: uid, direction: .toTop)
        }
        // The .preferredInputDeviceChanged subscription refreshes device lists
        // and the status line — no explicit refresh needed here. Posted before the
        // resume so the watchdog enforces against the NEW order, not the old one.
        NotificationCenter.default.post(name: .preferredInputDeviceChanged, object: uid)
        // A deliberate device pick re-arms a yielded lock — the user has chosen
        // their new #1 and expects it to be held. (No-op when not yielded.)
        NotificationCenter.default.post(name: .userRequestedResumeInputProtection, object: nil)
    }

    /// Snap the system default input to the top connected device in priority order.
    /// Does not reorder the priority list — honors what's already there. Safe to call
    /// regardless of which protection toggles are on; it's a one-shot manual command.
    /// Also clears any yielded-protection state so the lock resumes after the user
    /// previously fought it off via repeated manual overrides.
    func reapplyInputPriority() {
        NotificationCenter.default.post(name: .userRequestedResumeInputProtection, object: nil)
        guard let target = bestConnectedInput() else { return }
        guard audioDeviceManager.defaultInputDevice?.uid != target.uid else { return }
        audioDeviceManager.setDefaultInputDevice(target)
        NotificationCenter.default.post(name: .preferredInputDeviceChanged, object: target.uid)
    }

    private func bestConnectedInput() -> AudioDevice? {
        for uid in preferencesManager.preferredInputDeviceOrder {
            if let device = audioDeviceManager.device(forUID: uid), device.isInput {
                return device
            }
            if let name = preferencesManager.cachedDeviceName(for: uid) {
                let matches = audioDeviceManager.inputDevices(withName: name)
                if matches.count == 1 {
                    preferencesManager.replaceDeviceUID(oldUID: uid, newUID: matches[0].uid)
                    return matches[0]
                }
            }
        }
        return nil
    }

    func removeInputDevice(at displayedIndex: Int) {
        guard displayedIndex >= 0, displayedIndex < inputDevices.count else { return }
        let uid = inputDevices[displayedIndex].id
        preferencesManager.removeDeviceFromOrder(uid)
        if preferencesManager.preferredInputDeviceUID == uid {
            preferencesManager.preferredInputDeviceUID = nil
        }
        NotificationCenter.default.post(name: .preferredInputDeviceChanged, object: uid)
    }

    // MARK: - Actions: Output

    func setOutputDeviceLockEnabled(_ enabled: Bool) {
        preferencesManager.outputDeviceLockEnabled = enabled
        outputDeviceLockEnabled = enabled
        // Same stale-mirror reset as the input lock toggle.
        isOutputYielded = false
        outputFightOffer = nil
        NotificationCenter.default.post(name: .outputDeviceLockChanged, object: nil)
    }

    func setOutputAutoSwitchEnabled(_ enabled: Bool) {
        preferencesManager.outputAutoSwitchEnabled = enabled
        outputAutoSwitchEnabled = enabled
    }

    func moveOutputDevice(at displayedIndex: Int, direction: MoveDirection) {
        guard displayedIndex >= 0, displayedIndex < outputDevices.count else { return }
        let uid = outputDevices[displayedIndex].id
        var newOrder = preferencesManager.preferredOutputDeviceOrder
        guard let currentIdx = newOrder.firstIndex(of: uid) else { return }

        switch direction {
        case .up:
            guard displayedIndex > 0 else { return }
            let prevUID = outputDevices[displayedIndex - 1].id
            guard let prevIdx = newOrder.firstIndex(of: prevUID) else { return }
            newOrder.swapAt(currentIdx, prevIdx)
        case .down:
            guard displayedIndex < outputDevices.count - 1 else { return }
            let nextUID = outputDevices[displayedIndex + 1].id
            guard let nextIdx = newOrder.firstIndex(of: nextUID) else { return }
            newOrder.swapAt(currentIdx, nextIdx)
        case .toTop:
            newOrder.remove(at: currentIdx)
            newOrder.insert(uid, at: 0)
        }

        preferencesManager.preferredOutputDeviceOrder = newOrder
        NotificationCenter.default.post(name: .preferredOutputDeviceChanged, object: uid)
    }

    func useOutputDevice(at displayedIndex: Int) {
        guard displayedIndex >= 0, displayedIndex < outputDevices.count else { return }
        let uid = outputDevices[displayedIndex].id

        if let device = audioDeviceManager.device(forUID: uid) {
            audioDeviceManager.setDefaultOutputDevice(device)
            let actualUID = audioDeviceManager.defaultOutputDevice?.uid
            if actualUID != device.uid {
                MGLog.debug("[MicGuard.PopoverVM] useOutputDevice: macOS rejected \(device.name) (still on \(actualUID ?? "nil"))")
                unsettableUIDs.insert(uid)
                refreshDeviceLists()
                return
            }
            unsettableUIDs.remove(uid)
        }

        preferencesManager.preferredOutputDeviceUID = uid
        let order = preferencesManager.preferredOutputDeviceOrder
        if order.first != uid {
            preferencesManager.moveOutputDevice(uid: uid, direction: .toTop)
        }
        // Order update first so a resume enforces against the NEW order.
        NotificationCenter.default.post(name: .preferredOutputDeviceChanged, object: uid)
        // A deliberate device pick re-arms a yielded lock. (No-op when not yielded.)
        NotificationCenter.default.post(name: .userRequestedResumeOutputProtection, object: nil)
    }

    /// Snap the system default output to the top connected device in priority order.
    /// Same semantics as reapplyInputPriority — does not reorder the list.
    /// Also clears any yielded-protection state.
    func reapplyOutputPriority() {
        NotificationCenter.default.post(name: .userRequestedResumeOutputProtection, object: nil)
        guard let target = bestConnectedOutput() else { return }
        guard audioDeviceManager.defaultOutputDevice?.uid != target.uid else { return }
        audioDeviceManager.setDefaultOutputDevice(target)
        NotificationCenter.default.post(name: .preferredOutputDeviceChanged, object: target.uid)
    }

    private func bestConnectedOutput() -> AudioDevice? {
        for uid in preferencesManager.preferredOutputDeviceOrder {
            if let device = audioDeviceManager.device(forUID: uid), device.isOutput {
                return device
            }
            if let name = preferencesManager.cachedDeviceName(for: uid) {
                let matches = audioDeviceManager.outputDevices(withName: name)
                if matches.count == 1 {
                    preferencesManager.replaceOutputDeviceUID(oldUID: uid, newUID: matches[0].uid)
                    return matches[0]
                }
            }
        }
        return nil
    }

    /// Persist a per-device output volume default. If the device is currently the
    /// system output, apply it immediately so the user gets instant feedback
    /// (matches set-once-on-activation semantic for everyone else).
    func setCustomOutputVolume(_ volume: Float?, for uid: String) {
        preferencesManager.setOutputDeviceVolume(volume, for: uid)
        if let volume = volume,
           audioDeviceManager.defaultOutputDevice?.uid == uid,
           let device = audioDeviceManager.device(forUID: uid) {
            _ = audioDeviceManager.setOutputVolume(volume, for: device)
        }
        refreshCustomOutputVolumes()
    }

    /// Output devices that don't already have a custom volume set —
    /// candidates for the "+ Add custom level" picker.
    func addableOutputDevicesForCustomVolume() -> [AddableOutputDevice] {
        let configured = Set(customOutputVolumes.map { $0.uid })
        return audioDeviceManager.outputDevices
            .filter { !configured.contains($0.uid) }
            .map { AddableOutputDevice(uid: $0.uid, displayName: $0.name) }
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    private func refreshCustomOutputVolumes() {
        var entries: [CustomOutputVolumeEntry] = []
        // Walk the saved output priority order plus any other UID that has a saved
        // volume (covers devices removed from priority but still configured).
        var seen = Set<String>()
        let order = preferencesManager.preferredOutputDeviceOrder

        func appendIfHasVolume(_ uid: String) {
            guard !seen.contains(uid) else { return }
            guard let volume = preferencesManager.outputDeviceVolume(for: uid) else { return }
            seen.insert(uid)
            let device = audioDeviceManager.device(forUID: uid)
            let name = device?.name ?? preferencesManager.cachedDeviceName(for: uid) ?? uid
            entries.append(CustomOutputVolumeEntry(
                uid: uid,
                displayName: name,
                volume: volume,
                isConnected: device != nil
            ))
        }

        for uid in order { appendIfHasVolume(uid) }
        for device in audioDeviceManager.outputDevices { appendIfHasVolume(device.uid) }

        customOutputVolumes = entries
    }

    func removeOutputDevice(at displayedIndex: Int) {
        guard displayedIndex >= 0, displayedIndex < outputDevices.count else { return }
        let uid = outputDevices[displayedIndex].id
        preferencesManager.removeOutputDeviceFromOrder(uid)
        if preferencesManager.preferredOutputDeviceUID == uid {
            preferencesManager.preferredOutputDeviceUID = nil
        }
        NotificationCenter.default.post(name: .preferredOutputDeviceChanged, object: uid)
    }

    // MARK: - Actions: Volume

    func setVolumeStrategy(_ strategy: VolumeControlStrategy) {
        preferencesManager.volumeControlStrategy = strategy
        volumeStrategy = strategy
    }

    /// Update the in-memory slider value continuously without writing to UserDefaults.
    func updateVolumeSliderPreview(_ value: Float) {
        targetVolume = value
    }

    /// Commit the final slider value on mouse-up. Suppresses the publisher echo so we
    /// don't bounce the slider visually while the user is still holding it.
    func commitVolume(_ value: Float) {
        suppressVolumePublish = true
        preferencesManager.targetVolume = value
        targetVolume = value
        DispatchQueue.main.async { [weak self] in
            self?.suppressVolumePublish = false
        }
    }

    // MARK: - Actions: Settings

    func setLaunchAtLogin(_ enabled: Bool) {
        preferencesManager.launchAtLogin = enabled
        launchAtLogin = enabled
    }

    /// Master kill switch. Pausing clears yield mirrors and pending fight offers —
    /// the watchdogs are stopped outright, so that state is meaningless.
    func setAppPaused(_ paused: Bool) {
        preferencesManager.appPaused = paused
        appPaused = paused
        if paused {
            isInputYielded = false
            isOutputYielded = false
            inputFightOffer = nil
            outputFightOffer = nil
        }
    }

    func setMicInUseIndicatorStyle(_ style: MicInUseIndicatorStyle) {
        preferencesManager.micInUseIndicatorStyle = style
        micInUseIndicatorStyle = style
    }

    func setAutoResumeOnTopPriorityPick(_ enabled: Bool) {
        preferencesManager.autoResumeOnTopPriorityPick = enabled
        autoResumeOnTopPriorityPick = enabled
    }

    func setHideVirtualDevices(_ enabled: Bool) {
        preferencesManager.hideVirtualDevices = enabled
        hideVirtualDevices = enabled
        refreshDeviceLists()
    }

    func resetStats() {
        statsManager.reset()
    }

    // MARK: - Actions: App

    func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MicGuard"
        alert.informativeText = """
        Version 1.0

        Your Mic, Your Rules.

        Prevents macOS and apps from hijacking your microphone selection or volume levels.

        No microphone access, no recordings, no data collection.

        © 2025
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func quit() {
        NSApp.terminate(nil)
    }
}

