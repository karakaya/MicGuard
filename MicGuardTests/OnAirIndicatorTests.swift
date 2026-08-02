//
//  OnAirIndicatorTests.swift
//  MicGuardTests
//

import XCTest
import Combine
@testable import MicGuard

/// Mock PreferencesManager — only the surface OnAirIndicator and other tests touch.
class MockPreferencesForOnAir: PreferencesManaging {
    var preferredInputDeviceUID: String?
    var preferredInputDeviceOrder: [String] = []
    var inputDeviceLockEnabled: Bool = false
    var inputAutoSwitchEnabled: Bool = false
    var volumeControlStrategy: VolumeControlStrategy = .none
    var targetVolume: Float = 0.75
    var launchAtLogin: Bool = false
    var showInMenuBar: Bool = true
    var showNotifications: Bool = true
    var appPaused: Bool = false
    var showStats: Bool = false
    var micInUseIndicatorStyle: MicInUseIndicatorStyle = .orangePill
    var autoYieldOnRepeatedOverride: Bool = true
    var autoResumeOnTopPriorityPick: Bool = false
    var hideVirtualDevices: Bool = false
    let preferencesChangedPublisher = PassthroughSubject<String, Never>()

    var preferredOutputDeviceUID: String?
    var preferredOutputDeviceOrder: [String] = []
    var outputDeviceLockEnabled: Bool = false
    var outputAutoSwitchEnabled: Bool = false

    func moveDevice(uid: String, direction: MoveDirection) {}
    func addDeviceToOrder(_ uid: String) {}
    func removeDeviceFromOrder(_ uid: String) {}
    func moveOutputDevice(uid: String, direction: MoveDirection) {}
    func addOutputDeviceToOrder(_ uid: String) {}
    func removeOutputDeviceFromOrder(_ uid: String) {}
    func cacheDeviceName(uid: String, name: String) {}
    func cachedDeviceName(for uid: String) -> String? { nil }
    func replaceDeviceUID(oldUID: String, newUID: String) {}
    func replaceOutputDeviceUID(oldUID: String, newUID: String) {}
    func outputDeviceVolume(for uid: String) -> Float? { nil }
    func setOutputDeviceVolume(_ volume: Float?, for uid: String) {}
}

final class OnAirIndicatorTests: XCTestCase {

    var indicator: OnAirIndicator!

    override func setUp() {
        super.setUp()
        // Pass nil for statusItem since we can't create one in tests.
        indicator = OnAirIndicator(statusItem: nil)
    }

    override func tearDown() {
        indicator = nil
        super.tearDown()
    }

    func testFlashDoesNotCrashWithNilStatusItem() {
        indicator.flash(label: "INPUT HELD")
        // No statusItem means the timer block early-returns; we just verify no crash.
    }

    func testPulseDoesNotCrashWithNilStatusItem() {
        indicator.pulse()
    }
}
