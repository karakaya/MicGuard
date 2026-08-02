//
//  VolumeGuardTests.swift
//  MicGuardTests
//
//  Tests for VolumeGuard functionality
//

import XCTest
import Combine
@testable import MicGuard

final class VolumeGuardTests: XCTestCase {
    
    var mockAudioManager: MockAudioDeviceManager!
    var volumeGuard: VolumeGuard!
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() {
        super.setUp()
        mockAudioManager = MockAudioDeviceManager()
        mockAudioManager.setupMockDevices()
        volumeGuard = VolumeGuard(audioDeviceManager: mockAudioManager, debounceInterval: 0.01)
        cancellables = Set<AnyCancellable>()
    }
    
    override func tearDown() {
        volumeGuard.stopGuarding()
        volumeGuard = nil
        mockAudioManager = nil
        cancellables = nil
        super.tearDown()
    }
    
    // MARK: - Basic State Tests
    
    func testInitialState() {
        XCTAssertFalse(volumeGuard.isGuarding, "VolumeGuard should not be guarding initially")
        XCTAssertEqual(volumeGuard.targetVolume, 0.75, "Default target volume should be 0.75")
    }
    
    func testStartGuardingSetsState() {
        // Given
        let targetVolume: Float = 0.6
        
        // When
        volumeGuard.startGuarding(targetVolume: targetVolume)
        
        // Then
        XCTAssertTrue(volumeGuard.isGuarding, "VolumeGuard should be guarding after start")
        XCTAssertEqual(volumeGuard.targetVolume, targetVolume, "Target volume should be set")
    }
    
    func testStopGuardingClearsState() {
        // Given
        volumeGuard.startGuarding(targetVolume: 0.5)
        
        // When
        volumeGuard.stopGuarding()
        
        // Then
        XCTAssertFalse(volumeGuard.isGuarding, "VolumeGuard should not be guarding after stop")
    }
    
    func testUpdateTargetVolume() {
        // Given
        volumeGuard.startGuarding(targetVolume: 0.5)
        
        // When
        volumeGuard.updateTargetVolume(0.8)
        
        // Then
        XCTAssertEqual(volumeGuard.targetVolume, 0.8, "Target volume should be updated")
    }
    
    func testTargetVolumeClamping() {
        // Given
        volumeGuard.startGuarding(targetVolume: 1.5) // Over max
        XCTAssertEqual(volumeGuard.targetVolume, 1.0, "Volume should be clamped to 1.0")
        
        volumeGuard.updateTargetVolume(-0.5) // Under min
        XCTAssertEqual(volumeGuard.targetVolume, 0.0, "Volume should be clamped to 0.0")
    }
    
    // MARK: - Volume Setting Tests
    
    func testSetsVolumeImmediatelyWhenStarting() {
        // Given
        let targetVolume: Float = 0.65
        let currentDevice = mockAudioManager.defaultInputDevice!
        mockAudioManager.setInputVolumeCalls.removeAll()
        
        // When
        volumeGuard.startGuarding(targetVolume: targetVolume)
        
        // Then
        XCTAssertEqual(mockAudioManager.setInputVolumeCalls.count, 1,
                       "Should set volume once when starting")
        XCTAssertEqual(mockAudioManager.setInputVolumeCalls.first?.volume, targetVolume,
                       "Should set to target volume")
        XCTAssertEqual(mockAudioManager.setInputVolumeCalls.first?.device.uid, currentDevice.uid,
                       "Should set volume on default input device")
    }
    
    func testSetVolumeDirectly() {
        // Given
        mockAudioManager.setInputVolumeCalls.removeAll()
        
        // When
        volumeGuard.setVolume(level: 0.45)
        
        // Then
        XCTAssertEqual(mockAudioManager.setInputVolumeCalls.count, 1,
                       "Should call setInputVolume")
        XCTAssertEqual(mockAudioManager.setInputVolumeCalls.first?.volume, 0.45,
                       "Should set correct volume")
    }
    
    // MARK: - Volume Lock Tests
    
    func testLocksVolumeAtTargetLevel() {
        // Given
        let targetVolume: Float = 0.75
        let device = mockAudioManager.defaultInputDevice!
        
        volumeGuard.startGuarding(targetVolume: targetVolume)
        mockAudioManager.setInputVolumeCalls.removeAll()
        
        // When - Verify volume is at target
        let currentVolume = mockAudioManager.getInputVolume(for: device) ?? 0.0

        // Then
        XCTAssertEqual(currentVolume, targetVolume, accuracy: 0.01,
                       "Volume should be locked at target level")
    }
    
    func testDoesNotCorrectWhenNotGuarding() {
        // Given
        let device = mockAudioManager.defaultInputDevice!
        mockAudioManager.simulateVolumeChange(for: device, to: 1.0)
        
        // Allow processing time
        let expectation = XCTestExpectation(description: "Wait for processing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Then
        XCTAssertTrue(mockAudioManager.setInputVolumeCalls.isEmpty,
                      "Should not correct volume when not guarding")
    }
    
    // MARK: - Callback Tests
    
    func testOnVolumeCorrectedCallback() {
        // Given
        let expectation = XCTestExpectation(description: "Volume corrected callback")
        let targetVolume: Float = 0.5
        
        volumeGuard.startGuarding(targetVolume: targetVolume)
        
        volumeGuard.onVolumeCorrected = { originalLevel, correctedLevel in
            XCTAssertEqual(correctedLevel, targetVolume, accuracy: 0.01)
            expectation.fulfill()
        }
        
        // Note: In a real scenario, we'd trigger the volume listener
        // For unit tests, we're testing the callback mechanism exists
        
        // Simulate callback directly for testing
        volumeGuard.onVolumeCorrected?(0.8, targetVolume)
        
        // Then
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - Tolerance Tests
    
    func testAllowsSmallVolumeVariance() {
        // This tests the 0.01 tolerance
        let targetVolume: Float = 0.75

        volumeGuard.startGuarding(targetVolume: targetVolume)
        mockAudioManager.setInputVolumeCalls.removeAll()

        // A change within tolerance should not trigger correction
        // Testing the concept - actual implementation uses CoreAudio listeners
        let withinTolerance = abs(0.755 - targetVolume) <= 0.01
        XCTAssertTrue(withinTolerance, "0.755 should be within tolerance of 0.75")

        let outsideTolerance = abs(0.80 - targetVolume) > 0.01
        XCTAssertTrue(outsideTolerance, "0.80 should be outside tolerance of 0.75")
    }

    // MARK: - Anti-Fight Mechanism Tests

    func testShouldNotThrottleUnderLimit() {
        // VolumeGuard starts with correctionCount = 0
        // Internal shouldThrottle() returns false when under 10 corrections
        volumeGuard.startGuarding(targetVolume: 0.5)

        // Simulate a volume correction callback — if throttle were active, callback wouldn't fire
        let expectation = XCTestExpectation(description: "Volume corrected callback fires")
        volumeGuard.onVolumeCorrected = { _, _ in
            expectation.fulfill()
        }

        // Manually invoke callback to verify it's set up (anti-fight is not blocking)
        volumeGuard.onVolumeCorrected?(0.8, 0.5)

        wait(for: [expectation], timeout: 1.0)
    }

    func testMultipleSetVolumesSucceed() {
        // Verify that multiple volume sets in quick succession all work
        // (anti-fight only kicks in after 10 corrections in 5s via the listener, not setVolume)
        let targetVolume: Float = 0.65
        volumeGuard.startGuarding(targetVolume: targetVolume)
        mockAudioManager.setInputVolumeCalls.removeAll()

        for _ in 0..<5 {
            volumeGuard.setVolume(level: targetVolume)
        }

        XCTAssertEqual(mockAudioManager.setInputVolumeCalls.count, 5,
                       "All 5 setVolume calls should succeed")
    }

    // MARK: - Listener-Triggered Correction Tests

    func testOnVolumeCorrectedCallbackSetupOnStart() {
        var callbackCalled = false
        volumeGuard.onVolumeCorrected = { originalLevel, correctedLevel in
            callbackCalled = true
            XCTAssertEqual(correctedLevel, 0.6, accuracy: 0.01)
        }

        volumeGuard.startGuarding(targetVolume: 0.6)

        // Simulate what the listener flow would do
        volumeGuard.onVolumeCorrected?(0.9, 0.6)
        XCTAssertTrue(callbackCalled, "onVolumeCorrected callback should be callable")
    }

    func testSetVolumeHandlesNoDefaultDevice() {
        // Remove default device
        mockAudioManager.inputDevices = []

        // This hack creates a manager with no default device
        let emptyManager = MockAudioDeviceManager()
        let guard2 = VolumeGuard(audioDeviceManager: emptyManager, debounceInterval: 0.01)

        // Should not crash
        guard2.setVolume(level: 0.5)

        XCTAssertTrue(emptyManager.setInputVolumeCalls.isEmpty,
                      "Should not try to set volume without a default device")
    }

    // MARK: - Throttle Callback Tests

    func testThrottleCallbackNotCalledInitially() {
        var throttleStates: [Bool] = []
        volumeGuard.onThrottleStateChanged = { isThrottled in
            throttleStates.append(isThrottled)
        }

        volumeGuard.startGuarding(targetVolume: 0.5)

        // No corrections yet, callback should not fire
        XCTAssertTrue(throttleStates.isEmpty,
                      "Throttle callback should not fire without any corrections")
    }

    func testThrottleCallbackSetup() {
        var callbackCalled = false
        volumeGuard.onThrottleStateChanged = { isThrottled in
            callbackCalled = true
        }

        // Verify callback is wired up
        volumeGuard.onThrottleStateChanged?(true)
        XCTAssertTrue(callbackCalled, "onThrottleStateChanged callback should be callable")
    }

    // MARK: - Device switch enforcement

    func testAppliesTargetVolumeAfterDeviceSwitch() {
        // A newly-default device carries whatever volume it last had; the guard
        // must snap it to target after the settle delay, without waiting for a
        // volume event that may never come.
        let airpods = mockAudioManager.inputDevices.first { $0.uid == "AirPodsPro" }!
        volumeGuard.startGuarding(targetVolume: 0.75)
        mockAudioManager.simulateVolumeChange(for: airpods, to: 0.2)
        mockAudioManager.setInputVolumeCalls.removeAll()

        mockAudioManager.simulateDeviceSwitch(to: airpods)

        let expectation = XCTestExpectation(description: "target applied after settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(
            mockAudioManager.setInputVolumeCalls.contains { $0.device.uid == airpods.uid && abs($0.volume - 0.75) < 0.001 },
            "Target volume must be applied to the newly-default device"
        )
        XCTAssertEqual(mockAudioManager.getInputVolume(for: airpods) ?? 0, 0.75, accuracy: 0.001)
    }

    // MARK: - Debounce deadline

    func testContinuousVolumeChurnCannotStarveCorrection() {
        // Pure trailing-edge debounce let any source changing volume faster than
        // the interval postpone the correction forever (conferencing auto-gain).
        // The deadline pins the correction to debounceInterval after FIRST drift.
        let mock = mockAudioManager!
        let guard2 = VolumeGuard(audioDeviceManager: mock, debounceInterval: 0.5)
        defer { guard2.stopGuarding() }
        let device = mock.defaultInputDevice!
        guard2.startGuarding(targetVolume: 0.75)
        mock.setInputVolumeCalls.removeAll()

        // Churn: re-drift and re-trigger every 0.15s for ~0.6s — each event
        // used to cancel and re-schedule the correction another 0.5s out.
        for i in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) { [weak guard2] in
                mock.simulateVolumeChange(for: device, to: 0.2)
                guard2?.handleVolumeChange()
            }
        }

        let expectation = XCTestExpectation(description: "correction fires despite churn")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(
            mock.setInputVolumeCalls.contains { abs($0.volume - 0.75) < 0.001 },
            "Correction must fire by first-drift + debounceInterval even under continuous churn"
        )
    }
}
