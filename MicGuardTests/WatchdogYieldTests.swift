//
//  WatchdogYieldTests.swift
//  MicGuardTests
//
//  Consent-based yield: fight detection, explicit yield/resume, strict
//  auto-resume, storm filtering, and unsettable-device fallthrough.
//

import XCTest
import Combine
@testable import MicGuard

final class WatchdogYieldTests: XCTestCase {

    var mockAudioManager: MockAudioDeviceManager!
    var watchdog: DeviceWatchdog!

    var shure: AudioDevice!
    var airpods: AudioDevice!
    var builtIn: AudioDevice!

    override func setUp() {
        super.setUp()
        mockAudioManager = MockAudioDeviceManager()
        mockAudioManager.setupMockDevices()
        watchdog = DeviceWatchdog(audioDeviceManager: mockAudioManager, debounceInterval: 0.01)

        shure = mockAudioManager.inputDevices.first { $0.uid == "ShureMV7" }!
        airpods = mockAudioManager.inputDevices.first { $0.uid == "AirPodsPro" }!
        builtIn = mockAudioManager.inputDevices.first { $0.uid == "BuiltInMicrophone" }!
    }

    override func tearDown() {
        watchdog.stopWatching()
        watchdog = nil
        mockAudioManager = nil
        super.tearDown()
    }

    private func wait(_ seconds: TimeInterval) {
        let expectation = XCTestExpectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { expectation.fulfill() }
        wait(for: [expectation], timeout: seconds + 2.0)
    }

    // MARK: - Fight detection (no silent yield)

    func testRepeatedOverridesFireFightDetectedButKeepEnforcing() {
        mockAudioManager.setDefaultInputDevice(shure)
        mockAudioManager.setDefaultInputDeviceCalls.removeAll()
        watchdog.startWatching(devicePriorityOrder: [shure.uid])
        watchdog.autoYieldEnabled = true

        var fightDetections = 0
        watchdog.onFightDetected = { attempted, preferred in
            XCTAssertEqual(attempted, "AirPods Pro")
            XCTAssertEqual(preferred, "Shure MV7")
            fightDetections += 1
        }
        var yields = 0
        watchdog.onYielded = { _, _ in yields += 1 }

        // Two overrides spaced past yieldMinSpread (1s) within yieldWindow (10s):
        // the old behavior silently yielded; the new behavior offers and enforces.
        mockAudioManager.simulateDeviceSwitch(to: airpods)
        wait(1.2)
        mockAudioManager.simulateDeviceSwitch(to: airpods)
        wait(0.2)

        XCTAssertEqual(fightDetections, 1, "Threshold of 2 overrides should surface exactly one offer")
        XCTAssertEqual(yields, 0, "Watchdog must never yield silently")
        XCTAssertFalse(watchdog.isYielded)
        XCTAssertEqual(mockAudioManager.defaultInputDevice?.uid, shure.uid,
                       "Enforcement must continue after fight detection")
    }

    func testEnforcementContinuesAfterFightDetected() {
        mockAudioManager.setDefaultInputDevice(shure)
        watchdog.startWatching(devicePriorityOrder: [shure.uid])
        watchdog.autoYieldEnabled = true

        mockAudioManager.simulateDeviceSwitch(to: airpods)
        wait(1.2)
        mockAudioManager.simulateDeviceSwitch(to: airpods)
        wait(1.2)

        // A third hijack after the offer is still reverted.
        mockAudioManager.simulateDeviceSwitch(to: airpods)
        wait(0.2)
        XCTAssertEqual(mockAudioManager.defaultInputDevice?.uid, shure.uid)
    }

    func testFlapStormLongerThanOneSecondDoesNotTriggerFight() {
        mockAudioManager.setDefaultInputDevice(shure)
        watchdog.startWatching(devicePriorityOrder: [shure.uid])
        watchdog.autoYieldEnabled = true

        var fightDetections = 0
        watchdog.onFightDetected = { _, _ in fightDetections += 1 }

        // Storm: events every ~0.55s for ~1.7s. Each is < yieldMinSpread after the
        // previous OBSERVED event, so the whole storm counts as one override.
        // (The old anchor-on-recorded logic recorded a second event at t≈1.1s.)
        mockAudioManager.simulateDeviceSwitch(to: airpods)
        wait(0.55)
        mockAudioManager.simulateDeviceSwitch(to: airpods)
        wait(0.55)
        mockAudioManager.simulateDeviceSwitch(to: airpods)
        wait(0.55)
        mockAudioManager.simulateDeviceSwitch(to: airpods)
        wait(0.2)

        XCTAssertEqual(fightDetections, 0, "A flap storm must not reach the fight threshold")
        XCTAssertFalse(watchdog.isYielded)
    }

    // MARK: - Explicit yield / resume

    func testYieldNowStopsEnforcementUntilResume() {
        mockAudioManager.setDefaultInputDevice(shure)
        watchdog.startWatching(devicePriorityOrder: [shure.uid])

        var yielded = false
        watchdog.onYielded = { _, _ in yielded = true }

        watchdog.yieldNow()
        XCTAssertTrue(watchdog.isYielded)
        XCTAssertTrue(yielded)

        mockAudioManager.setDefaultInputDeviceCalls.removeAll()
        mockAudioManager.simulateDeviceSwitch(to: airpods)
        wait(0.2)
        XCTAssertTrue(mockAudioManager.setDefaultInputDeviceCalls.isEmpty,
                      "Yielded watchdog must not enforce")
        XCTAssertEqual(mockAudioManager.defaultInputDevice?.uid, airpods.uid)

        var resumed = false
        watchdog.onProtectionResumed = { resumed = true }
        watchdog.resumeProtection()
        XCTAssertFalse(watchdog.isYielded)
        XCTAssertTrue(resumed)
        XCTAssertEqual(mockAudioManager.defaultInputDevice?.uid, shure.uid,
                       "Resume must re-enforce the preferred device")
    }

    func testUpdatePriorityOrderPreservesYieldState() {
        mockAudioManager.setDefaultInputDevice(shure)
        watchdog.startWatching(devicePriorityOrder: [shure.uid, airpods.uid])
        watchdog.yieldNow()
        mockAudioManager.simulateDeviceSwitch(to: builtIn)
        wait(0.2)

        mockAudioManager.setDefaultInputDeviceCalls.removeAll()
        watchdog.updateDevicePriorityOrder([airpods.uid, shure.uid])

        XCTAssertTrue(watchdog.isYielded, "A list edit must not silently cancel the yield")
        XCTAssertTrue(mockAudioManager.setDefaultInputDeviceCalls.isEmpty,
                      "A list edit while yielded must not re-enforce")
    }

    // MARK: - Auto-resume strictness

    func testAutoResumeFiresOnTopPriorityPick() {
        mockAudioManager.setDefaultInputDevice(builtIn)
        watchdog.startWatching(devicePriorityOrder: [shure.uid, airpods.uid])
        watchdog.autoResumeEnabled = true
        watchdog.yieldNow()

        mockAudioManager.simulateDeviceSwitch(to: shure)
        wait(0.2)
        XCTAssertFalse(watchdog.isYielded, "Picking the top-priority device should auto-resume")
    }

    func testAutoResumeDoesNotFireOnLowerPriorityDevice() {
        // Top priority (Shure) disconnected: the old logic auto-resumed on the
        // best AVAILABLE device (AirPods) — the new logic requires strictly #1.
        mockAudioManager.setDefaultInputDevice(builtIn)
        watchdog.startWatching(devicePriorityOrder: [shure.uid, airpods.uid])
        watchdog.autoResumeEnabled = true
        watchdog.yieldNow()

        mockAudioManager.inputDevices.removeAll { $0.uid == self.shure.uid }
        mockAudioManager.simulateDeviceSwitch(to: airpods)
        wait(0.2)
        XCTAssertTrue(watchdog.isYielded,
                      "A lower-priority pick must not auto-resume when #1 is just disconnected")
    }

    func testAutoResumeDoesNotFireWhenNoPriorityDeviceResolves() {
        // No priority UID resolves: the old logic fell back to the current default,
        // making the comparison self-vs-self — ANY change auto-resumed.
        mockAudioManager.setDefaultInputDevice(builtIn)
        watchdog.startWatching(devicePriorityOrder: ["GhostUID"])
        watchdog.autoResumeEnabled = true
        watchdog.yieldNow()

        mockAudioManager.simulateDeviceSwitch(to: airpods)
        wait(0.2)
        XCTAssertTrue(watchdog.isYielded,
                      "An unresolvable priority list must never auto-resume on random changes")
    }

    // MARK: - Unsettable-device fallthrough

    func testFallsThroughWhenTopDeviceSilentlyRefusesToStick() {
        // Shure reports success but the default never moves — macOS behavior for
        // virtual/aggregate devices. Refusals are counted by the 0.4s delayed
        // verification (an immediate read would race real re-overrides), so the
        // enforce → verify → count → re-enforce chain needs ~1s to cross
        // maxStickFailures and fall through to AirPods.
        mockAudioManager.silentlyRefusedUIDs = [shure.uid]
        mockAudioManager.setDefaultInputDevice(builtIn)
        watchdog.startWatching(devicePriorityOrder: [shure.uid, airpods.uid])

        wait(1.5)

        XCTAssertEqual(mockAudioManager.defaultInputDevice?.uid, airpods.uid,
                       "Enforcement must fall through past a device whose set never sticks")
    }

    func testReOverriddenSettableDeviceIsNotMarkedUnsettable() {
        // The set sticks (a change event carries Shure) but macOS re-overrides
        // 0.1s later — AirPods-style. The delayed verification must NOT count
        // this as a refusal; Shure stays eligible and keeps being enforced.
        mockAudioManager.setDefaultInputDevice(builtIn)
        watchdog.startWatching(devicePriorityOrder: [shure.uid, airpods.uid])
        wait(0.1)
        // Simulate the re-override landing between set and verification.
        mockAudioManager.simulateDeviceSwitch(to: airpods)

        wait(1.5)

        XCTAssertEqual(mockAudioManager.defaultInputDevice?.uid, shure.uid,
                       "A settable device that gets re-overridden must keep being enforced, not skipped")
    }
}
