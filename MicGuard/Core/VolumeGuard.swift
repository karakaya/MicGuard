//
//  VolumeGuard.swift
//  MicGuard
//
//  Monitors input volume changes and enforces user's preferred level
//

import Foundation
import CoreAudio
import Combine
import AppKit

// MARK: - Protocol for Testability

protocol VolumeGuardProtocol {
    var isGuarding: Bool { get }
    var targetVolume: Float { get }
    
    func startGuarding(targetVolume: Float)
    func stopGuarding()
    func updateTargetVolume(_ volume: Float)
    func setVolume(level: Float)
    
    var onVolumeCorrected: ((Float, Float) -> Void)? { get set }
}

// MARK: - VolumeGuard Implementation

class VolumeGuard: VolumeGuardProtocol {
    
    // MARK: - Properties
    
    private let audioDeviceManager: AudioDeviceManaging
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var currentDeviceID: AudioDeviceID?
    
    private(set) var isGuarding: Bool = false
    private(set) var targetVolume: Float = 0.75
    
    // Anti-fight mechanism
    private var correctionCount: Int = 0
    private var correctionWindowStart: Date = Date()
    private let maxCorrectionsPerWindow: Int = 10
    private let correctionWindowDuration: TimeInterval = 5.0
    
    // Debounce with a hard deadline: rescheduling on every event alone lets any
    // source that changes volume faster than the interval (conferencing auto-gain
    // adjusts ~every second) postpone the correction forever. The deadline pins
    // the correction to at most debounceInterval after the FIRST uncorrected drift.
    private var debounceWorkItem: DispatchWorkItem?
    private var pendingCorrectionDeadline: Date?
    private let debounceInterval: TimeInterval

    // Settle delay before snapping a newly-default device to the target volume.
    private let deviceSwitchSettleDelay: TimeInterval = 0.5
    
    // Volume tolerance (to prevent float comparison issues)
    private let volumeTolerance: Float = 0.01
    
    // Callback when volume is corrected
    var onVolumeCorrected: ((Float, Float) -> Void)?

    // Callback when manual volume change detected (System Settings frontmost)
    var onManualVolumeChangeDetected: (() -> Void)?

    // Callback when throttle state changes (true = throttled, false = resumed)
    var onThrottleStateChanged: ((Bool) -> Void)?

    // Track whether we're currently throttled (for edge detection)
    private var isThrottled: Bool = false

    // Track if we're currently setting volume (to avoid self-triggered events)
    private var isSettingVolume: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init(audioDeviceManager: AudioDeviceManaging, debounceInterval: TimeInterval = 2.5) {
        self.audioDeviceManager = audioDeviceManager
        self.debounceInterval = debounceInterval
        
        // Register cleanup on app termination (defense against force-quit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.removeVolumeListener()
        }
    }
    
    deinit {
        stopGuarding()
    }
    
    // MARK: - Public Methods
    
    func startGuarding(targetVolume: Float) {
        self.targetVolume = max(0, min(1, targetVolume))
        
        guard !isGuarding else {
            // Already guarding, just update target
            return
        }
        
        isGuarding = true
        
        // Watch for default device changes to re-attach the listener AND re-apply
        // the target: the newly-default device carries whatever volume it last had,
        // and no volume event fires until some other actor touches it.
        audioDeviceManager.defaultInputChangedPublisher
            .sink { [weak self] _ in
                self?.reattachVolumeListener()
                self?.enforceTargetAfterDeviceSwitch()
            }
            .store(in: &cancellables)
        
        // Attach volume listener to current device
        attachVolumeListener()
        
        // Set volume immediately to target
        setVolume(level: self.targetVolume)
        
    }
    
    func stopGuarding() {
        isGuarding = false
        removeVolumeListener()
        cancellables.removeAll()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pendingCorrectionDeadline = nil

    }
    
    func updateTargetVolume(_ volume: Float) {
        targetVolume = max(0, min(1, volume))
        
        if isGuarding {
            setVolume(level: targetVolume)
        }
    }
    
    func setVolume(level: Float) {
        guard let device = audioDeviceManager.defaultInputDevice else { return }

        isSettingVolume = true
        _ = audioDeviceManager.setInputVolume(level, for: device)
        isSettingVolume = false
    }
    
    // MARK: - Private Methods - Listener Management
    
    private func attachVolumeListener() {
        guard let device = audioDeviceManager.defaultInputDevice else { return }
        
        // Remove existing listener if any
        removeVolumeListener()
        
        currentDeviceID = device.id
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Check if master channel exists, otherwise use channel 1
        if !AudioObjectHasProperty(device.id, &propertyAddress) {
            propertyAddress.mElement = 1
        }
        
        volumeListenerBlock = { [weak self] (_, _) in
            DispatchQueue.main.async {
                guard let self = self, !self.isSettingVolume else { return }
                self.handleVolumeChange()
            }
        }
        
        _ = AudioObjectAddPropertyListenerBlock(
            device.id,
            &propertyAddress,
            nil,
            volumeListenerBlock!
        )
        
    }
    
    private func removeVolumeListener() {
        guard let deviceID = currentDeviceID,
              let block = volumeListenerBlock else { return }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Try master channel first
        var status = AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &propertyAddress,
            nil,
            block
        )
        
        // If that didn't work, try channel 1
        if status != noErr {
            propertyAddress.mElement = 1
            status = AudioObjectRemovePropertyListenerBlock(
                deviceID,
                &propertyAddress,
                nil,
                block
            )
        }
        
        currentDeviceID = nil
        volumeListenerBlock = nil
    }
    
    private func reattachVolumeListener() {
        guard isGuarding else { return }
        attachVolumeListener()
    }

    /// Snap a newly-default device to the target after a short settle delay.
    /// Without this, enforcement after a device switch is reactive-only: a device
    /// left at 20% by some app stays there until another actor trips the listener.
    private func enforceTargetAfterDeviceSwitch() {
        guard isGuarding else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + deviceSwitchSettleDelay) { [weak self] in
            guard let self = self, self.isGuarding,
                  let device = self.audioDeviceManager.defaultInputDevice,
                  let currentVolume = self.audioDeviceManager.getInputVolume(for: device),
                  abs(currentVolume - self.targetVolume) > self.volumeTolerance,
                  !self.shouldThrottle() else { return }

            self.isSettingVolume = true
            let success = self.audioDeviceManager.setInputVolume(self.targetVolume, for: device)
            self.isSettingVolume = false

            if success {
                self.recordCorrection()
                self.onVolumeCorrected?(currentVolume, self.targetVolume)
            }
        }
    }
    
    // MARK: - Private Methods - Volume Enforcement
    
    // internal (not private) so tests can drive volume-change events — the real
    // trigger is a CoreAudio listener the mock layer can't fire.
    func handleVolumeChange() {
        guard isGuarding,
              let device = audioDeviceManager.defaultInputDevice,
              let currentVolume = audioDeviceManager.getInputVolume(for: device) else { return }
        
        // Check if volume drifted from target
        let drift = abs(currentVolume - targetVolume)
        
        guard drift > volumeTolerance else { return }
        
        // Check anti-fight mechanism
        if shouldThrottle() { return }
        
        // Debounce the correction, capped by the deadline set at the first
        // uncorrected drift — continued churn cannot postpone it past that.
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingCorrectionDeadline = nil

            // Re-fetch at fire time: the default device may have changed (or gone)
            // during the debounce window, and the drift may already be resolved.
            guard self.isGuarding,
                  let device = self.audioDeviceManager.defaultInputDevice,
                  let currentVolume = self.audioDeviceManager.getInputVolume(for: device),
                  abs(currentVolume - self.targetVolume) > self.volumeTolerance else { return }

            self.isSettingVolume = true
            let success = self.audioDeviceManager.setInputVolume(self.targetVolume, for: device)
            self.isSettingVolume = false

            if success {
                self.recordCorrection()
                self.onVolumeCorrected?(currentVolume, self.targetVolume)

                if self.isSystemSettingsFrontmost() {
                    self.onManualVolumeChangeDetected?()
                }
            }
        }

        debounceWorkItem = workItem
        let now = Date()
        let deadline = pendingCorrectionDeadline ?? now.addingTimeInterval(debounceInterval)
        pendingCorrectionDeadline = deadline
        let delay = max(0, deadline.timeIntervalSince(now))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    
    // MARK: - Anti-Fight Mechanism

    private func shouldThrottle() -> Bool {
        let now = Date()

        // Reset window if expired
        if now.timeIntervalSince(correctionWindowStart) > correctionWindowDuration {
            correctionCount = 0
            correctionWindowStart = now

            // Notify that throttle has lifted
            if isThrottled {
                isThrottled = false
                onThrottleStateChanged?(false)
            }
        }

        let throttled = correctionCount >= maxCorrectionsPerWindow

        // Notify on first throttle in this window
        if throttled && !isThrottled {
            isThrottled = true
            onThrottleStateChanged?(true)
        }

        return throttled
    }

    private func recordCorrection() {
        let now = Date()

        // Reset window if expired
        if now.timeIntervalSince(correctionWindowStart) > correctionWindowDuration {
            correctionCount = 0
            correctionWindowStart = now
        }

        correctionCount += 1
    }
    
    // MARK: - Helper Methods

    private func isSystemSettingsFrontmost() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontmost.bundleIdentifier else { return false }
        
        return bundleId == "com.apple.systempreferences" ||  // macOS 12 and earlier
               bundleId == "com.apple.Settings"              // macOS 13+
    }
}
