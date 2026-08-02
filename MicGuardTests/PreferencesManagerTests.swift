//
//  PreferencesManagerTests.swift
//  MicGuardTests
//
//  Tests for PreferencesManager functionality
//

import XCTest
import Combine
@testable import MicGuard

final class PreferencesManagerTests: XCTestCase {

    var preferencesManager: PreferencesManager!
    var testDefaults: UserDefaults!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.micguard.tests")!
        testDefaults.removePersistentDomain(forName: "com.micguard.tests")

        preferencesManager = PreferencesManager(defaults: testDefaults)
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "com.micguard.tests")
        testDefaults = nil
        preferencesManager = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Legacy Migration Tests

    func testLegacyVolumeLockMigrates() {
        // Old-version user: legacy keys present, new strategy key absent.
        // registerDefaults() used to run before migration, making the nil-guard
        // permanently false — these settings were silently dropped.
        let suite = "com.micguard.tests.migration"
        let legacyDefaults = UserDefaults(suiteName: suite)!
        legacyDefaults.removePersistentDomain(forName: suite)
        legacyDefaults.set(true, forKey: "InputVolumeLockEnabled")
        legacyDefaults.set(Float(0.5), forKey: "LockedInputVolume")

        let manager = PreferencesManager(defaults: legacyDefaults)

        XCTAssertEqual(manager.volumeControlStrategy, .lockVolume,
                       "Legacy volume lock must migrate to the lockVolume strategy")
        XCTAssertEqual(manager.targetVolume, 0.5, accuracy: 0.001,
                       "Legacy locked volume must migrate to targetVolume")
        XCTAssertNil(legacyDefaults.object(forKey: "InputVolumeLockEnabled"),
                     "Legacy keys must be cleaned up after migration")
        legacyDefaults.removePersistentDomain(forName: suite)
    }

    func testLegacyAutoResetMigrates() {
        let suite = "com.micguard.tests.migration2"
        let legacyDefaults = UserDefaults(suiteName: suite)!
        legacyDefaults.removePersistentDomain(forName: suite)
        legacyDefaults.set(true, forKey: "AutoResetEnabled")
        legacyDefaults.set(Float(0.6), forKey: "DefaultResetVolume")

        let manager = PreferencesManager(defaults: legacyDefaults)

        XCTAssertEqual(manager.volumeControlStrategy, .resetWhenMicStops)
        XCTAssertEqual(manager.targetVolume, 0.6, accuracy: 0.001)
        legacyDefaults.removePersistentDomain(forName: suite)
    }

    func testLegacyKeysDoNotOverrideAlreadyPersistedStrategy() {
        // User configured the new strategy while the migration was dead code —
        // lingering legacy keys must not clobber it, and must still be cleaned up.
        let suite = "com.micguard.tests.migration3"
        let legacyDefaults = UserDefaults(suiteName: suite)!
        legacyDefaults.removePersistentDomain(forName: suite)
        legacyDefaults.set(true, forKey: "InputVolumeLockEnabled")
        legacyDefaults.set(Float(0.5), forKey: "LockedInputVolume")
        legacyDefaults.set(VolumeControlStrategy.none.rawValue, forKey: "VolumeControlStrategy")

        let manager = PreferencesManager(defaults: legacyDefaults)

        XCTAssertEqual(manager.volumeControlStrategy, .none,
                       "A persisted strategy must survive the legacy migration")
        XCTAssertNil(legacyDefaults.object(forKey: "InputVolumeLockEnabled"),
                     "Legacy keys must still be cleaned up")
        legacyDefaults.removePersistentDomain(forName: suite)
    }

    func testAppPausedPersistence() {
        XCTAssertFalse(preferencesManager.appPaused, "App must not start paused by default")
        preferencesManager.appPaused = true
        XCTAssertTrue(preferencesManager.appPaused)
        XCTAssertTrue(testDefaults.bool(forKey: "AppPaused"))
    }

    func testFreshInstallKeepsRegisteredDefaultStrategy() {
        // No legacy keys: migration must not run, or a fresh install would be
        // forced to .none instead of the registered resetWhenMicStops default.
        XCTAssertEqual(preferencesManager.volumeControlStrategy, .resetWhenMicStops)
        XCTAssertEqual(preferencesManager.targetVolume, 0.75, accuracy: 0.001)
    }

    // MARK: - Default Values Tests

    func testDefaultValues() {
        XCTAssertNil(preferencesManager.preferredInputDeviceUID)
        XCTAssertFalse(preferencesManager.inputDeviceLockEnabled)
        XCTAssertEqual(preferencesManager.targetVolume, 0.75, accuracy: 0.001)
        XCTAssertFalse(preferencesManager.launchAtLogin)
        XCTAssertTrue(preferencesManager.showInMenuBar)
        XCTAssertTrue(preferencesManager.showNotifications)
        XCTAssertFalse(preferencesManager.showStats)
    }

    // MARK: - Device Preferences Tests

    func testPreferredInputDeviceUIDPersistence() {
        let testUID = "TestMicrophoneUID"

        preferencesManager.preferredInputDeviceUID = testUID

        XCTAssertEqual(preferencesManager.preferredInputDeviceUID, testUID)
        XCTAssertEqual(testDefaults.string(forKey: "PreferredInputDeviceUID"), testUID)
    }

    func testInputDeviceLockEnabledPersistence() {
        preferencesManager.inputDeviceLockEnabled = true

        XCTAssertTrue(preferencesManager.inputDeviceLockEnabled)
        XCTAssertTrue(testDefaults.bool(forKey: "InputDeviceLockEnabled"))
    }

    func testPreferredInputDeviceOrderPersistence() {
        let order = ["UID1", "UID2", "UID3"]

        preferencesManager.preferredInputDeviceOrder = order

        XCTAssertEqual(preferencesManager.preferredInputDeviceOrder, order)
    }

    func testPreferredInputDeviceOrderDeduplicates() {
        preferencesManager.preferredInputDeviceOrder = ["UID1", "UID2", "UID1", "UID3"]

        XCTAssertEqual(preferencesManager.preferredInputDeviceOrder, ["UID1", "UID2", "UID3"])
    }

    // MARK: - Volume Preferences Tests

    func testVolumeControlStrategyPersistence() {
        preferencesManager.volumeControlStrategy = .lockVolume

        XCTAssertEqual(preferencesManager.volumeControlStrategy, .lockVolume)
        XCTAssertEqual(testDefaults.string(forKey: "VolumeControlStrategy"), "lockVolume")
    }

    func testTargetVolumePersistence() {
        preferencesManager.targetVolume = 0.65

        XCTAssertEqual(preferencesManager.targetVolume, 0.65, accuracy: 0.01)
        XCTAssertEqual(testDefaults.float(forKey: "TargetVolume"), 0.65, accuracy: 0.01)
    }

    func testTargetVolumeClamping() {
        preferencesManager.targetVolume = 1.5
        XCTAssertEqual(preferencesManager.targetVolume, 1.0, accuracy: 0.001)

        preferencesManager.targetVolume = -0.5
        XCTAssertEqual(preferencesManager.targetVolume, 0.0, accuracy: 0.001)
    }

    // MARK: - App Settings Tests

    func testShowInMenuBarPersistence() {
        preferencesManager.showInMenuBar = false

        XCTAssertFalse(preferencesManager.showInMenuBar)
        XCTAssertFalse(testDefaults.bool(forKey: "ShowInMenuBar"))
    }

    func testShowNotificationsPersistence() {
        preferencesManager.showNotifications = false

        XCTAssertFalse(preferencesManager.showNotifications)
        XCTAssertFalse(testDefaults.bool(forKey: "ShowNotifications"))
    }

    // MARK: - Device Order Management Tests

    func testMoveDeviceUp() {
        preferencesManager.preferredInputDeviceOrder = ["A", "B", "C"]
        preferencesManager.moveDevice(uid: "B", direction: .up)

        XCTAssertEqual(preferencesManager.preferredInputDeviceOrder, ["B", "A", "C"])
    }

    func testMoveDeviceDown() {
        preferencesManager.preferredInputDeviceOrder = ["A", "B", "C"]
        preferencesManager.moveDevice(uid: "B", direction: .down)

        XCTAssertEqual(preferencesManager.preferredInputDeviceOrder, ["A", "C", "B"])
    }

    func testMoveDeviceToTop() {
        preferencesManager.preferredInputDeviceOrder = ["A", "B", "C"]
        preferencesManager.moveDevice(uid: "C", direction: .toTop)

        XCTAssertEqual(preferencesManager.preferredInputDeviceOrder, ["C", "A", "B"])
    }

    func testAddDeviceToOrder() {
        preferencesManager.preferredInputDeviceOrder = ["A"]
        preferencesManager.addDeviceToOrder("B")

        XCTAssertEqual(preferencesManager.preferredInputDeviceOrder, ["A", "B"])
    }

    func testAddDeviceToOrderSkipsDuplicates() {
        preferencesManager.preferredInputDeviceOrder = ["A", "B"]
        preferencesManager.addDeviceToOrder("A")

        XCTAssertEqual(preferencesManager.preferredInputDeviceOrder, ["A", "B"])
    }

    func testRemoveDeviceFromOrder() {
        preferencesManager.preferredInputDeviceOrder = ["A", "B", "C"]
        preferencesManager.removeDeviceFromOrder("B")

        XCTAssertEqual(preferencesManager.preferredInputDeviceOrder, ["A", "C"])
    }

    // MARK: - Device Name Cache Tests

    func testCacheDeviceName() {
        preferencesManager.cacheDeviceName(uid: "UID1", name: "Test Mic")

        XCTAssertEqual(preferencesManager.cachedDeviceName(for: "UID1"), "Test Mic")
    }

    func testCachedDeviceNameReturnsNilForUnknown() {
        XCTAssertNil(preferencesManager.cachedDeviceName(for: "unknown"))
    }

    // MARK: - UID Migration Tests

    func testReplaceDeviceUID() {
        preferencesManager.preferredInputDeviceOrder = ["oldUID", "other"]
        preferencesManager.cacheDeviceName(uid: "oldUID", name: "Test Mic")
        preferencesManager.preferredInputDeviceUID = "oldUID"

        preferencesManager.replaceDeviceUID(oldUID: "oldUID", newUID: "newUID")

        XCTAssertEqual(preferencesManager.preferredInputDeviceOrder, ["newUID", "other"])
        XCTAssertEqual(preferencesManager.cachedDeviceName(for: "newUID"), "Test Mic")
        XCTAssertEqual(preferencesManager.preferredInputDeviceUID, "newUID")
    }

    // MARK: - Publisher Tests

    func testPreferencesChangedPublisher() {
        let expectation = XCTestExpectation(description: "Preferences changed publisher")
        var changedKey: String?

        preferencesManager.preferencesChangedPublisher
            .sink { key in
                changedKey = key
                expectation.fulfill()
            }
            .store(in: &cancellables)

        preferencesManager.inputDeviceLockEnabled = true

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(changedKey, "InputDeviceLockEnabled")
    }

    func testMultiplePreferencesChangesPublisher() {
        var changedKeys: [String] = []
        let expectation = XCTestExpectation(description: "Multiple changes")
        expectation.expectedFulfillmentCount = 3

        preferencesManager.preferencesChangedPublisher
            .sink { key in
                changedKeys.append(key)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        preferencesManager.inputDeviceLockEnabled = true
        preferencesManager.targetVolume = 0.8
        preferencesManager.volumeControlStrategy = .lockVolume

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(changedKeys.count, 3)
        XCTAssertTrue(changedKeys.contains("InputDeviceLockEnabled"))
        XCTAssertTrue(changedKeys.contains("TargetVolume"))
        XCTAssertTrue(changedKeys.contains("VolumeControlStrategy"))
    }
}
