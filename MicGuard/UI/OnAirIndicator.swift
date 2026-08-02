//
//  OnAirIndicator.swift
//  MicGuard
//
//  Owns the menu bar status item's visual state.
//  Default: plain template mic glyph.
//  When mic is in use: tinted/styled per `MicInUseIndicatorStyle`.
//  On prevention events: briefly flashes a red label (`INPUT HELD`, etc.).
//  On volume corrections: briefly red-pulses the icon (no width change).
//

import Cocoa

class OnAirIndicator {

    // MARK: - Properties

    private weak var statusItem: NSStatusItem?

    private var isInUse: Bool = false
    private var style: MicInUseIndicatorStyle = .orangePill
    private var isAppPaused: Bool = false

    private var isFlashing: Bool = false
    private var flashTimer: Timer?
    private var flashCount: Int = 0
    private let labelFlashCycles: Int = 3
    private let flashDuration: TimeInterval = 0.5

    // MARK: - Initialization

    init(statusItem: NSStatusItem?) {
        self.statusItem = statusItem
        applyBaseState()
    }

    // MARK: - Public

    func setStyle(_ style: MicInUseIndicatorStyle) {
        guard style != self.style else { return }
        self.style = style
        if !isFlashing { applyBaseState() }
    }

    func update(isInUse: Bool, force: Bool = false) {
        if !force && isInUse == self.isInUse { return }
        self.isInUse = isInUse
        if !isFlashing { applyBaseState() }
    }

    /// Master pause: slashed, dimmed mic so the disabled state is visible at a
    /// glance. Overrides the in-use pill — a paused MicGuard shows paused.
    func setAppPaused(_ paused: Bool) {
        guard paused != isAppPaused else { return }
        isAppPaused = paused
        if !isFlashing { applyBaseState() }
    }

    /// Flash a colored label (e.g. "INPUT HELD" red, "OUTPUT CHANGED" green) in place
    /// of the mic icon, 3 cycles. A new flash preempts any in-flight one — newer
    /// information (e.g. "yield" right after "held") matters more than visual continuity.
    func flash(label: String, background: NSColor = .systemRed) {
        MGLog.debug("[MicGuard.Indicator] flash label=\(label) (preempting=\(isFlashing))")
        flashTimer?.invalidate()
        isFlashing = true
        flashCount = 0
        // Show the label immediately — the timer then alternates hide/show.
        // (Starting hidden would leave a blank menu-bar slot for the first cycle.)
        renderFlashFrame(label, background: background, visible: true)
        let timer = Timer(timeInterval: flashDuration, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            guard self.statusItem?.button != nil else {
                timer.invalidate()
                self.isFlashing = false
                return
            }

            self.flashCount += 1
            if self.flashCount >= self.labelFlashCycles * 2 {
                timer.invalidate()
                self.isFlashing = false
                self.flashCount = 0
                self.applyBaseState()
                return
            }

            let visible = (self.flashCount % 2 == 0)
            self.renderFlashFrame(label, background: background, visible: visible)
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    private func renderFlashFrame(_ label: String, background: NSColor, visible: Bool) {
        statusItem?.button?.attributedTitle = Self.labelAttributedString(
            label, background: background, alpha: visible ? 1.0 : 0.0
        )
        statusItem?.button?.image = nil
        statusItem?.button?.contentTintColor = nil
    }

    /// Subtle 1–2 red-tint pulses on the mic icon. Used for volume corrections.
    /// Doesn't change the icon width, so no menu bar reflow.
    func pulse(cycles: Int = 2) {
        flashTimer?.invalidate()
        isFlashing = true
        flashCount = 0
        let totalSteps = max(1, cycles) * 2
        let pulseStep: TimeInterval = 0.18
        let timer = Timer(timeInterval: pulseStep, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            guard let button = self.statusItem?.button else {
                timer.invalidate()
                self.isFlashing = false
                return
            }

            let tinted = (self.flashCount % 2 == 0)
            if tinted {
                button.contentTintColor = .systemRed
            } else {
                button.contentTintColor = nil
            }
            self.flashCount += 1
            if self.flashCount >= totalSteps {
                timer.invalidate()
                self.isFlashing = false
                self.flashCount = 0
                self.applyBaseState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    // MARK: - Private

    private func applyBaseState() {
        guard let button = statusItem?.button else { return }
        button.attributedTitle = NSAttributedString()

        if isAppPaused {
            let mic = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "MicGuard (paused)")
            mic?.isTemplate = true
            button.image = mic
            button.contentTintColor = nil
            button.appearsDisabled = true
            return
        }
        button.appearsDisabled = false

        if isInUse {
            switch style {
            case .orangePill:
                button.image = Self.pillImage(background: .systemOrange)
                button.image?.isTemplate = false
                button.contentTintColor = nil
            case .redTint:
                button.image = Self.pillImage(background: .systemRed)
                button.image?.isTemplate = false
                button.contentTintColor = nil
            case .none:
                applyNeutralMic(button: button)
            }
        } else {
            applyNeutralMic(button: button)
        }
    }

    private func applyNeutralMic(button: NSStatusBarButton) {
        let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MicGuard")
        mic?.isTemplate = true
        button.image = mic
        button.contentTintColor = nil
    }

    private static func labelAttributedString(_ text: String, background: NSColor = .systemRed, alpha: CGFloat = 1.0) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.minimumLineHeight = 20
        paragraphStyle.maximumLineHeight = 20

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .backgroundColor: background.withAlphaComponent(alpha),
            .paragraphStyle: paragraphStyle,
            .baselineOffset: -1
        ]
        return NSAttributedString(string: " \(text) ", attributes: attributes)
    }

    /// Composes a colored rounded-rect pill with a white mic glyph centered.
    /// Used for both the orange (macOS-native look) and red (more alarming) styles.
    private static func pillImage(background: NSColor) -> NSImage {
        let size = NSSize(width: 30, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        background.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 6, yRadius: 6).fill()

        let baseConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [.white])
        let config = baseConfig.applying(paletteConfig)

        if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let micSize = mic.size
            let origin = NSPoint(
                x: (size.width - micSize.width) / 2,
                y: (size.height - micSize.height) / 2
            )
            mic.draw(in: NSRect(origin: origin, size: micSize))
        }

        return image
    }
}
