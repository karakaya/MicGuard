//
//  ClamshellMonitor.swift
//  MicGuard
//
//  Tracks MacBook lid (clamshell) state via IOKit.
//  In clamshell mode the built-in microphone stays enumerated and "alive" in
//  CoreAudio even though it is physically unusable, so the watchdog needs this
//  out-of-band signal to fall through to the next priority device (see TODO.md).
//

import Foundation
import IOKit

final class ClamshellMonitor {

    /// Fired on the main queue whenever the lid state flips.
    var onLidStateChanged: ((Bool) -> Void)?

    private(set) var isLidClosed: Bool = false

    private var notifyPort: IONotificationPortRef?
    private var interestNotification: io_object_t = 0
    private var rootDomain: io_service_t = 0

    init() {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else {
            MGLog.debug("[MicGuard.Clamshell] IOPMrootDomain not found — lid tracking disabled")
            return
        }

        isLidClosed = readClamshellState()
        MGLog.debug("[MicGuard.Clamshell] initial lid closed=\(isLidClosed)")

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notifyPort else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        // General-interest messages on the root domain include clamshell state
        // changes (kIOPMMessageClamshellStateChange). That constant is a C macro
        // Swift can't import, so instead of matching the message type we re-read
        // the registry property on any message and diff — cheap and robust.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon = refcon else { return }
            let monitor = Unmanaged<ClamshellMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.refreshState()
        }
        let status = IOServiceAddInterestNotification(
            port, rootDomain, "IOGeneralInterest", callback, refcon, &interestNotification
        )
        if status != KERN_SUCCESS {
            MGLog.debug("[MicGuard.Clamshell] interest notification failed status=\(status)")
        }
    }

    deinit {
        if interestNotification != 0 { IOObjectRelease(interestNotification) }
        if let port = notifyPort { IONotificationPortDestroy(port) }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
    }

    private func refreshState() {
        let closed = readClamshellState()
        guard closed != isLidClosed else { return }
        isLidClosed = closed
        MGLog.debug("[MicGuard.Clamshell] lid closed=\(closed)")
        onLidStateChanged?(closed)
    }

    private func readClamshellState() -> Bool {
        guard rootDomain != 0,
              let value = IORegistryEntryCreateCFProperty(
                rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() else {
            return false
        }
        return (value as? Bool) ?? false
    }
}
