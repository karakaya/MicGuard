// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MicGuard",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MicGuard", targets: ["MicGuard"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MicGuard",
            dependencies: [],
            path: "MicGuard",
            sources: [
                "App/MicGuardApp.swift",
                "App/AppDelegate.swift",
                "Core/AudioDeviceManager.swift",
                "Core/ClamshellMonitor.swift",
                "Core/DeviceWatchdog.swift",
                "Core/VolumeGuard.swift",
                "Core/ActivityMonitor.swift",
                "Core/ProcessMonitor.swift",
                "UI/StatusBarController.swift",
                "UI/OnAirIndicator.swift",
                "UI/MenuPopover/PopoverViewModel.swift",
                "UI/MenuPopover/PopoverContentView.swift",
                "UI/MenuPopover/DevicePriorityListView.swift",
                "Utilities/MGLog.swift",
                "Utilities/PreferencesManager.swift",
                "Utilities/StatsManager.swift",
                "Utilities/NotificationManager.swift"
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "MicGuardTests",
            dependencies: ["MicGuard"],
            path: "MicGuardTests",
            sources: [
                "Mocks/MockAudioDeviceManager.swift",
                "AudioDeviceTests.swift",
                "DeviceWatchdogTests.swift",
                "VolumeGuardTests.swift",
                "ActivityMonitorTests.swift",
                "PreferencesManagerTests.swift",
                "StatsManagerTests.swift",
                "ProcessMonitorTests.swift",
                "OutputDeviceWatchdogTests.swift",
                "OnAirIndicatorTests.swift"
            ]
        )
    ]
)
