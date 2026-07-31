//
//  DeviceWatchdogTests.swift
//  MicGuardTests
//
//  Tests for DeviceWatchdog functionality
//

import XCTest
import Combine
@testable import MicGuard

final class DeviceWatchdogTests: XCTestCase {
    
    var mockAudioManager: MockAudioDeviceManager!
    var watchdog: DeviceWatchdog!
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() {
        super.setUp()
        mockAudioManager = MockAudioDeviceManager()
        mockAudioManager.setupMockDevices()
        watchdog = DeviceWatchdog(audioDeviceManager: mockAudioManager, debounceInterval: 0.01)
        cancellables = Set<AnyCancellable>()
    }
    
    override func tearDown() {
        watchdog.stopWatching()
        watchdog = nil
        mockAudioManager = nil
        cancellables = nil
        super.tearDown()
    }
    
    // MARK: - Basic State Tests
    
    func testInitialState() {
        XCTAssertFalse(watchdog.isWatching, "Watchdog should not be watching initially")
        XCTAssertNil(watchdog.preferredDeviceUID, "No preferred device should be set initially")
    }
    
    func testStartWatchingSetsState() {
        // Given
        let preferredUID = "ShureMV7"
        
        // When
        watchdog.startWatching(devicePriorityOrder: [preferredUID])
        
        // Then
        XCTAssertTrue(watchdog.isWatching, "Watchdog should be watching after start")
        XCTAssertEqual(watchdog.preferredDeviceUID, preferredUID, "Preferred device UID should be set")
    }
    
    func testStopWatchingClearsState() {
        // Given
        watchdog.startWatching(devicePriorityOrder: ["ShureMV7"])
        
        // When
        watchdog.stopWatching()
        
        // Then
        XCTAssertFalse(watchdog.isWatching, "Watchdog should not be watching after stop")
    }
    
    func testUpdatePreferredDevice() {
        // Given
        watchdog.startWatching(devicePriorityOrder: ["ShureMV7"])
        
        // When
        watchdog.updatePreferredDevice(uid: "BuiltInMicrophone")
        
        // Then
        XCTAssertEqual(watchdog.preferredDeviceUID, "BuiltInMicrophone", "Preferred device should be updated")
    }
    
    // MARK: - Device Hijack Prevention Tests
    
    func testBlocksDeviceHijack() {
        // Given
        let expectation = XCTestExpectation(description: "Device hijack blocked")
        let preferredDevice = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!
        let hijackDevice = mockAudioManager.inputDevices.first { $0.uid == "AirPodsPro" }!
        
        // Set preferred device as current default
        mockAudioManager.setDefaultInputDevice(preferredDevice)
        
        watchdog.startWatching(devicePriorityOrder: [preferredDevice.uid])
        
        watchdog.onDeviceHijackBlocked = { attemptedDevice, enforcedDevice in
            XCTAssertEqual(attemptedDevice, "AirPods Pro")
            XCTAssertEqual(enforcedDevice, "Shure MV7")
            expectation.fulfill()
        }
        
        // When - Simulate AirPods hijacking input
        mockAudioManager.simulateDeviceSwitch(to: hijackDevice)
        
        // Then
        wait(for: [expectation], timeout: 1.0)
        
        // Verify device was switched back
        XCTAssertEqual(mockAudioManager.setDefaultInputDeviceCalls.last?.uid, preferredDevice.uid,
                       "Device should be switched back to preferred")
    }
    
    func testDoesNotBlockWhenNotWatching() {
        // Given
        let hijackDevice = mockAudioManager.inputDevices.first { $0.uid == "AirPodsPro" }!
        
        var hijackBlocked = false
        watchdog.onDeviceHijackBlocked = { _, _ in
            hijackBlocked = true
        }
        
        // When - Simulate device switch without watchdog active
        mockAudioManager.simulateDeviceSwitch(to: hijackDevice)
        
        // Allow debounce time
        let expectation = XCTestExpectation(description: "Wait for debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Then
        XCTAssertFalse(hijackBlocked, "Should not block hijack when not watching")
        XCTAssertTrue(mockAudioManager.setDefaultInputDeviceCalls.isEmpty,
                      "Should not attempt to change device")
    }
    
    func testAllowsSwitchToPreferredDevice() {
        // Given
        let preferredDevice = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!
        
        watchdog.startWatching(devicePriorityOrder: [preferredDevice.uid])
        mockAudioManager.setDefaultInputDeviceCalls.removeAll()
        
        // When - Simulate switch to preferred device (should be allowed)
        mockAudioManager.simulateDeviceSwitch(to: preferredDevice)
        
        // Allow debounce time
        let expectation = XCTestExpectation(description: "Wait for debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Then - Should not try to switch device again
        XCTAssertTrue(mockAudioManager.setDefaultInputDeviceCalls.isEmpty,
                      "Should not attempt device change when already on preferred device")
    }
    
    // MARK: - Edge Case Tests
    
    func testHandlesPreferredDeviceDisconnection() {
        // Given
        let preferredDevice = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!
        let fallbackDevice = mockAudioManager.inputDevices.first { $0.uid == "BuiltInMicrophone" }!
        
        watchdog.startWatching(devicePriorityOrder: [preferredDevice.uid])
        mockAudioManager.setDefaultInputDeviceCalls.removeAll()
        
        // When - Simulate preferred device disconnection
        mockAudioManager.simulateDeviceDisconnected(preferredDevice)
        mockAudioManager.simulateDeviceSwitch(to: fallbackDevice)
        
        // Allow debounce time
        let expectation = XCTestExpectation(description: "Wait for debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Then - Should not try to switch to disconnected device
        let switchAttempts = mockAudioManager.setDefaultInputDeviceCalls.filter { $0.uid == preferredDevice.uid }
        XCTAssertTrue(switchAttempts.isEmpty,
                      "Should not attempt to switch to disconnected device")
    }
    
    func testReenforcesWhenPreferredDeviceReconnects() {
        // Given
        let preferredDevice = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!
        let currentDevice = mockAudioManager.inputDevices.first { $0.uid == "BuiltInMicrophone" }!

        // Start watching and disconnect preferred device
        watchdog.startWatching(devicePriorityOrder: [preferredDevice.uid])
        mockAudioManager.simulateDeviceDisconnected(preferredDevice)
        mockAudioManager.simulateDeviceSwitch(to: currentDevice)
        mockAudioManager.setDefaultInputDeviceCalls.removeAll()

        // When - Preferred device reconnects
        mockAudioManager.simulateDeviceReconnected(preferredDevice)

        // Allow debounce time
        let expectation = XCTestExpectation(description: "Wait for reenforcement")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Then - Should switch back to preferred device
        XCTAssertTrue(mockAudioManager.setDefaultInputDeviceCalls.contains { $0.uid == preferredDevice.uid },
                      "Should switch back to preferred device when it reconnects")
    }

    // MARK: - Name-Based Reconnection Tests

    // MARK: - Priority Ordering Tests

    func testFallsBackToSecondPriorityWhenFirstDisconnected() {
        let device1 = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!
        let device2 = mockAudioManager.inputDevices.first { $0.uid == "AirPodsPro" }!
        let device3 = mockAudioManager.inputDevices.first { $0.uid == "BuiltInMicrophone" }!

        // Priority: ShureMV7 > AirPodsPro > BuiltInMicrophone
        watchdog.startWatching(devicePriorityOrder: [device1.uid, device2.uid, device3.uid])
        mockAudioManager.setDefaultInputDeviceCalls.removeAll()

        // Disconnect #1
        mockAudioManager.simulateDeviceDisconnected(device1)
        // System switches to built-in mic (not our #2)
        mockAudioManager.simulateDeviceSwitch(to: device3)

        let expectation = XCTestExpectation(description: "Wait for fallback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Should switch to #2 (AirPodsPro), not stay on #3
        XCTAssertTrue(
            mockAudioManager.setDefaultInputDeviceCalls.contains { $0.uid == device2.uid },
            "Should fall back to second priority device when first is disconnected"
        )
    }

    func testFallsBackToThirdWhenFirstAndSecondDisconnected() {
        let device1 = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!
        let device2 = mockAudioManager.inputDevices.first { $0.uid == "AirPodsPro" }!
        let device3 = mockAudioManager.inputDevices.first { $0.uid == "BuiltInMicrophone" }!

        watchdog.startWatching(devicePriorityOrder: [device1.uid, device2.uid, device3.uid])
        mockAudioManager.setDefaultInputDeviceCalls.removeAll()

        // Disconnect #1 and #2
        mockAudioManager.simulateDeviceDisconnected(device1)
        mockAudioManager.simulateDeviceDisconnected(device2)

        // System switches to something else, trigger device change
        mockAudioManager.simulateDeviceSwitch(to: device3)

        let expectation = XCTestExpectation(description: "Wait for fallback to #3")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Already on device3 (BuiltInMicrophone), should not try to switch
        // The watchdog should recognize device3 is the best available and not re-set
        // (device3 is already current default from the simulateDeviceSwitch)
    }

    func testShouldFailSetDevicePath() {
        let preferredDevice = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!
        let hijackDevice = mockAudioManager.inputDevices.first { $0.uid == "AirPodsPro" }!

        mockAudioManager.setDefaultInputDevice(preferredDevice)
        watchdog.startWatching(devicePriorityOrder: [preferredDevice.uid])

        var hijackBlocked = false
        watchdog.onDeviceHijackBlocked = { _, _ in
            hijackBlocked = true
        }

        // Fail the device set before the hijack event so enforcement can't succeed.
        mockAudioManager.shouldFailSetDevice = true
        mockAudioManager.simulateDeviceSwitch(to: hijackDevice)

        let expectation = XCTestExpectation(description: "Wait for enforcement")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // When setDefaultDevice fails, onDeviceHijackBlocked should NOT fire
        XCTAssertFalse(hijackBlocked,
                       "Should not report hijack blocked when device set fails")
    }

    func testNameBasedReconnectionUpdatesUID() {
        // Given - Start with device UID-A "Shure MV7"
        let originalDevice = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!
        let fallbackDevice = mockAudioManager.inputDevices.first { $0.uid == "BuiltInMicrophone" }!

        // Set up name resolver
        watchdog.nameForUID = { uid in
            if uid == "ShureMV7" { return "Shure MV7" }
            return nil
        }

        var uidUpdateCalled = false
        var capturedOldUID: String?
        var capturedNewUID: String?
        watchdog.onDeviceUIDUpdated = { oldUID, newUID in
            uidUpdateCalled = true
            capturedOldUID = oldUID
            capturedNewUID = newUID
        }

        // Start watching with original UID
        watchdog.startWatching(devicePriorityOrder: ["ShureMV7"])
        mockAudioManager.setDefaultInputDevice(originalDevice)
        mockAudioManager.setDefaultInputDeviceCalls.removeAll()

        // Disconnect the device
        mockAudioManager.simulateDeviceDisconnected(originalDevice)
        mockAudioManager.simulateDeviceSwitch(to: fallbackDevice)
        mockAudioManager.setDefaultInputDeviceCalls.removeAll()

        // Reconnect same physical device with a new UID (different USB port)
        let reconnectedDevice = AudioDevice(
            id: 99,
            uid: "ShureMV7-NewPort",
            name: "Shure MV7",
            isInput: true,
            isOutput: false
        )
        mockAudioManager.simulateDeviceReconnected(reconnectedDevice)

        // Allow debounce time
        let expectation = XCTestExpectation(description: "Wait for name-based match")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Then - Should find device by name and update UID
        XCTAssertTrue(uidUpdateCalled, "onDeviceUIDUpdated should be called")
        XCTAssertEqual(capturedOldUID, "ShureMV7", "Old UID should be the original")
        XCTAssertEqual(capturedNewUID, "ShureMV7-NewPort", "New UID should be the reconnected device")

        // Verify the watchdog switched to the reconnected device
        XCTAssertTrue(
            mockAudioManager.setDefaultInputDeviceCalls.contains { $0.uid == "ShureMV7-NewPort" },
            "Should switch to reconnected device matched by name"
        )
    }

    // MARK: - Ambiguous Name Matching Tests

    func testAmbiguousNameMatchFiresCallback() {
        let fallbackDevice = mockAudioManager.inputDevices.first { $0.uid == "BuiltInMicrophone" }!

        watchdog.nameForUID = { uid in
            if uid == "DisconnectedUID" { return "USB Mic" }
            return nil
        }

        var ambiguousCalled = false
        var capturedName: String?
        var capturedCount: Int?
        watchdog.onDeviceMatchAmbiguous = { name, count in
            ambiguousCalled = true
            capturedName = name
            capturedCount = count
        }

        // Add two devices with the same name
        let usbMic1 = AudioDevice(id: 10, uid: "USBMic1", name: "USB Mic", isInput: true, isOutput: false)
        let usbMic2 = AudioDevice(id: 11, uid: "USBMic2", name: "USB Mic", isInput: true, isOutput: false)
        mockAudioManager.inputDevices.append(usbMic1)
        mockAudioManager.inputDevices.append(usbMic2)

        // Start watching with a UID that will need name-based fallback
        watchdog.startWatching(devicePriorityOrder: ["DisconnectedUID", fallbackDevice.uid])

        let expectation = XCTestExpectation(description: "Wait for debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(ambiguousCalled, "onDeviceMatchAmbiguous should fire when multiple devices share a name")
        XCTAssertEqual(capturedName, "USB Mic")
        XCTAssertEqual(capturedCount, 2)
    }

    // MARK: - System-Initiated Routing Tests

    func testNoHijackCallbackDuringDeviceListFlux() {
        // OS-initiated routing right after a device-list change must revert
        // silently: no "INPUT HELD" flash, no hijack stat.
        let preferredDevice = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!
        let hijackDevice = mockAudioManager.inputDevices.first { $0.uid == "AirPodsPro" }!

        mockAudioManager.setDefaultInputDevice(preferredDevice)
        watchdog.startWatching(devicePriorityOrder: [preferredDevice.uid])
        mockAudioManager.setDefaultInputDeviceCalls.removeAll()

        var hijackAnnounced = false
        watchdog.onDeviceHijackBlocked = { _, _ in
            hijackAnnounced = true
        }

        // Device-list change opens the flux window, then macOS re-routes.
        mockAudioManager.devicesChangedPublisher.send()
        mockAudioManager.simulateDeviceSwitch(to: hijackDevice)

        let expectation = XCTestExpectation(description: "Wait for enforcement")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(hijackAnnounced,
                       "Should not announce hijack for system-initiated routing inside flux window")
        XCTAssertTrue(mockAudioManager.setDefaultInputDeviceCalls.contains { $0.uid == preferredDevice.uid },
                      "Should still silently revert to preferred device")
    }

    // MARK: - Direction Matching Tests

    func testInputWatchdogIgnoresOutputOnlyDeviceWithSameUID() {
        // A UID that only exists as an output device must not be selected by the
        // input watchdog — device(forUID:) searches both lists.
        let fallback = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!
        mockAudioManager.setDefaultInputDevice(fallback)
        mockAudioManager.setDefaultInputDeviceCalls.removeAll()

        // "BuiltInSpeakers" is output-only in the mock. Priority: speakers > shure.
        watchdog.startWatching(devicePriorityOrder: ["BuiltInSpeakers", fallback.uid])

        let expectation = XCTestExpectation(description: "Wait for enforcement")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(mockAudioManager.setDefaultInputDeviceCalls.contains { $0.uid == "BuiltInSpeakers" },
                       "Input watchdog must never set an output-only device as default input")
    }

    // MARK: - Usability Filter Tests (clamshell fallthrough)

    func testSkipsUnusableDeviceAndFallsThrough() {
        // Simulates clamshell mode: built-in mic enumerated but flagged unusable —
        // watchdog should enforce the next priority device instead.
        let builtIn = mockAudioManager.inputDevices.first { $0.uid == "BuiltInMicrophone" }!
        let fallback = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!

        watchdog.isDeviceUsable = { $0.uid != builtIn.uid }
        mockAudioManager.setDefaultInputDevice(builtIn)
        mockAudioManager.setDefaultInputDeviceCalls.removeAll()

        watchdog.startWatching(devicePriorityOrder: [builtIn.uid, fallback.uid])

        let expectation = XCTestExpectation(description: "Wait for fallthrough")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(mockAudioManager.setDefaultInputDeviceCalls.contains { $0.uid == fallback.uid },
                      "Should fall through to next priority device when top is unusable")
        XCTAssertFalse(mockAudioManager.setDefaultInputDeviceCalls.contains { $0.uid == builtIn.uid },
                       "Should not enforce the unusable device")
    }

    func testDoesNotFightWhenOnlyUnusableDeviceInPriority() {
        // Lid closed, priority holds only the built-in mic: selectBestDevice falls
        // back to the system default → watchdog must not fight the OS.
        let builtIn = mockAudioManager.inputDevices.first { $0.uid == "BuiltInMicrophone" }!
        let osChoice = mockAudioManager.inputDevices.first { $0.uid == "AirPodsPro" }!

        watchdog.isDeviceUsable = { $0.uid != builtIn.uid }
        watchdog.startWatching(devicePriorityOrder: [builtIn.uid])
        mockAudioManager.setDefaultInputDeviceCalls.removeAll()

        var hijackAnnounced = false
        watchdog.onDeviceHijackBlocked = { _, _ in
            hijackAnnounced = true
        }

        // OS routes away from the dead built-in mic.
        mockAudioManager.simulateDeviceSwitch(to: osChoice)

        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(hijackAnnounced, "Should not flash INPUT HELD when preferred device is unusable")
        XCTAssertFalse(mockAudioManager.setDefaultInputDeviceCalls.contains { $0.uid == builtIn.uid },
                       "Should not try to re-enforce the unusable device")
    }

    func testNoAmbiguousCallbackForSingleMatch() {
        watchdog.nameForUID = { uid in
            if uid == "ShureMV7" { return "Shure MV7" }
            return nil
        }

        var ambiguousCalled = false
        watchdog.onDeviceMatchAmbiguous = { _, _ in
            ambiguousCalled = true
        }

        // Disconnect ShureMV7 and reconnect with new UID (single match by name)
        let originalDevice = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!
        mockAudioManager.simulateDeviceDisconnected(originalDevice)

        let reconnected = AudioDevice(id: 99, uid: "ShureMV7-New", name: "Shure MV7", isInput: true, isOutput: false)
        mockAudioManager.simulateDeviceReconnected(reconnected)

        watchdog.startWatching(devicePriorityOrder: ["ShureMV7"])

        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(ambiguousCalled, "Should not fire ambiguous callback for single name match")
    }

}
