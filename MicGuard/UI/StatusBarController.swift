//
//  StatusBarController.swift
//  MicGuard
//
//  Manages the menu bar icon and popover.
//

import Cocoa
import Combine
import SwiftUI

@MainActor
class StatusBarController {

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var eventMonitor: Any?

    private let audioDeviceManager: AudioDeviceManaging
    private let preferencesManager: PreferencesManaging
    private let statsManager: StatsManaging
    private var activityMonitor: ActivityMonitor?

    private var cancellables = Set<AnyCancellable>()

    private var onAirIndicator: OnAirIndicator?
    private var viewModel: PopoverViewModel?

    // MARK: - Initialization

    init(audioDeviceManager: AudioDeviceManaging,
         preferencesManager: PreferencesManaging,
         statsManager: StatsManaging,
         activityMonitor: ActivityMonitor?) {
        self.audioDeviceManager = audioDeviceManager
        self.preferencesManager = preferencesManager
        self.statsManager = statsManager
        self.activityMonitor = activityMonitor

        setupStatusItem()
        setupPopover()
        setupObservers()
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MicGuard")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            // Receive both clicks so we can route right-click to the context menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        onAirIndicator = OnAirIndicator(statusItem: statusItem)
        onAirIndicator?.setStyle(preferencesManager.micInUseIndicatorStyle)
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let inputItem = NSMenuItem(
            title: "Reactivate Input Lock",
            action: #selector(reactivateInputLock),
            keyEquivalent: ""
        )
        inputItem.target = self
        menu.addItem(inputItem)

        let outputItem = NSMenuItem(
            title: "Reactivate Output Lock",
            action: #selector(reactivateOutputLock),
            keyEquivalent: ""
        )
        outputItem.target = self
        menu.addItem(outputItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit MicGuard",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        // Show the menu attached to the status item so it appears in the right place.
        // Setting menu temporarily then popping it up — NSStatusItem doesn't have a
        // direct API for "show this menu now without making it the default click action."
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func reactivateInputLock() {
        NotificationCenter.default.post(name: .userRequestedResumeInputProtection, object: nil)
    }

    @objc private func reactivateOutputLock() {
        NotificationCenter.default.post(name: .userRequestedResumeOutputProtection, object: nil)
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func setupObservers() {
        activityMonitor?.micInUsePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inUse in
                self?.onAirIndicator?.update(isInUse: inUse)
            }
            .store(in: &cancellables)

        // Apply current state right away (publisher only fires on change).
        let initialInUse = activityMonitor?.isMicrophoneInUse ?? false
        onAirIndicator?.update(isInUse: initialInUse, force: true)

        // React to user changing the indicator style in Settings.
        preferencesManager.preferencesChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] key in
                guard key == "MicInUseIndicatorStyle", let self = self else { return }
                self.onAirIndicator?.setStyle(self.preferencesManager.micInUseIndicatorStyle)
            }
            .store(in: &cancellables)

        // Master pause: slashed/dimmed menu-bar icon while protections are off.
        preferencesManager.preferencesChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] key in
                guard key == "AppPaused", let self = self else { return }
                self.onAirIndicator?.setAppPaused(self.preferencesManager.appPaused)
            }
            .store(in: &cancellables)
        onAirIndicator?.setAppPaused(preferencesManager.appPaused)
    }

    private func setupPopover() {
        let vm = PopoverViewModel(
            audioDeviceManager: audioDeviceManager,
            preferencesManager: preferencesManager,
            statsManager: statsManager,
            activityMonitor: activityMonitor
        )
        self.viewModel = vm

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 500)
        popover.contentViewController = NSHostingController(rootView: PopoverContentView(viewModel: vm))
    }

    // MARK: - Popover control

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            viewModel?.refreshAll()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()

            // Rapid re-toggles can land here with a monitor still installed —
            // remove it first or the old one leaks.
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Public Methods (called from AppDelegate)

    nonisolated func flashLabel(_ label: String, background: NSColor = .systemRed) {
        Task { @MainActor [weak self] in
            self?.onAirIndicator?.flash(label: label, background: background)
        }
    }

    nonisolated func pulseIcon() {
        Task { @MainActor [weak self] in
            self?.onAirIndicator?.pulse()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let inputDeviceLockChanged = Notification.Name("inputDeviceLockChanged")
    static let inputVolumeLockChanged = Notification.Name("inputVolumeLockChanged")
    static let autoResetChanged = Notification.Name("autoResetChanged")
    static let preferredInputDeviceChanged = Notification.Name("preferredInputDeviceChanged")
    static let lockedVolumeChanged = Notification.Name("lockedVolumeChanged")
    static let outputDeviceLockChanged = Notification.Name("outputDeviceLockChanged")
    static let preferredOutputDeviceChanged = Notification.Name("preferredOutputDeviceChanged")
    static let userRequestedResumeInputProtection = Notification.Name("userRequestedResumeInputProtection")
    static let userRequestedResumeOutputProtection = Notification.Name("userRequestedResumeOutputProtection")
    static let userRequestedYieldInputProtection = Notification.Name("userRequestedYieldInputProtection")
    static let userRequestedYieldOutputProtection = Notification.Name("userRequestedYieldOutputProtection")
    /// userInfo: ["direction": "input"|"output", "yielded": Bool]
    static let watchdogYieldStateChanged = Notification.Name("watchdogYieldStateChanged")
    /// userInfo: ["direction": "input"|"output", "attempted": String, "preferred": String]
    static let watchdogFightDetected = Notification.Name("watchdogFightDetected")
}
