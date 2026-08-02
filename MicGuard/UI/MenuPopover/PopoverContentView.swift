//
//  PopoverContentView.swift
//  MicGuard
//
//  Root SwiftUI view rendered inside the menu-bar popover.
//

import SwiftUI

enum PopoverTab: Hashable {
    case input
    case output
    case settings

    var title: String {
        switch self {
        case .input: return "Input"
        case .output: return "Output"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .input: return "mic.fill"
        case .output: return "speaker.wave.2.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct PopoverContentView: View {

    @ObservedObject var viewModel: PopoverViewModel
    @State private var selectedTab: PopoverTab = .input

    var body: some View {
        VStack(spacing: 0) {
            MasterToggleRow(viewModel: viewModel)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()
                .padding(.bottom, 12)

            // Everything below the master toggle is inert and dimmed while paused —
            // the app is visibly "off", and nothing can be changed until resumed.
            Group {
                StatusSection(viewModel: viewModel, tab: selectedTab)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                TabBar(selectedTab: $selectedTab)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch selectedTab {
                        case .input:
                            InputSection(viewModel: viewModel)
                        case .output:
                            OutputSection(viewModel: viewModel)
                        case .settings:
                            SettingsSection(viewModel: viewModel)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 500, maxHeight: 620)
            }
            .disabled(viewModel.appPaused)
            .opacity(viewModel.appPaused ? 0.45 : 1)
            .animation(.easeOut(duration: 0.15), value: viewModel.appPaused)

            Divider()
            FooterBar(viewModel: viewModel)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: 360)
    }
}

// MARK: - Master toggle

/// The app's kill switch — fixed above every tab. Off = every protection
/// stops, the UI below dims, and the menu-bar mic shows a slash.
private struct MasterToggleRow: View {
    @ObservedObject var viewModel: PopoverViewModel

    var body: some View {
        Toggle(isOn: Binding(
            get: { !viewModel.appPaused },
            set: { viewModel.setAppPaused(!$0) }
        )) {
            HStack(spacing: 10) {
                Image(systemName: viewModel.appPaused ? "mic.slash.fill" : "shield.fill")
                    .font(.system(size: 16))
                    .foregroundColor(viewModel.appPaused ? .secondary : .green)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MicGuard")
                        .font(.system(size: 14, weight: .semibold))
                    Text(viewModel.appPaused ? "Off — nothing is enforced" : "On — protecting your devices")
                        .font(.system(size: 11))
                        .foregroundColor(viewModel.appPaused ? .orange : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .help(viewModel.appPaused
              ? "Turn MicGuard back on"
              : "Turn MicGuard off — all protections stop until you turn it back on")
    }
}

// MARK: - Tab bar

private struct TabBar: View {
    @Binding var selectedTab: PopoverTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach([PopoverTab.input, .output, .settings], id: \.self) { tab in
                TabButton(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    action: { withAnimation(.easeOut(duration: 0.12)) { selectedTab = tab } }
                )
            }
        }
    }
}

private struct TabButton: View {
    let tab: PopoverTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(0.5)
    }
}

// MARK: - Status section

private struct StatusSection: View {
    @ObservedObject var viewModel: PopoverViewModel
    let tab: PopoverTab

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .foregroundColor(.accentColor)
                Text(headerDeviceName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }

            HStack(spacing: 6) {
                Image(systemName: lockIcon)
                    .foregroundColor(lockIconColor)
                    .font(.system(size: 11))
                Text(lockText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if isLocked && isYielded {
                    Spacer()
                    Button("Resume") {
                        if showsOutput {
                            viewModel.resumeOutputProtection()
                        } else {
                            viewModel.resumeInputProtection()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Re-arm enforcement of your priority list")
                }
            }
        }
    }

    // The Settings tab leaves the status header pinned to input — mic protection is the
    // app's headline state, so it makes sense to keep it visible while configuring options.
    private var showsOutput: Bool { tab == .output }

    private var headerIcon: String {
        showsOutput ? "speaker.wave.2.fill" : "mic.fill"
    }

    private var headerDeviceName: String {
        if showsOutput {
            return viewModel.currentOutputDisplayName ?? "No Output Device"
        }
        return viewModel.currentInputDeviceName
    }

    private var isLocked: Bool {
        showsOutput ? viewModel.outputDeviceLockEnabled : viewModel.inputDeviceLockEnabled
    }

    private var isYielded: Bool {
        showsOutput ? viewModel.isOutputYielded : viewModel.isInputYielded
    }

    private var lockIcon: String {
        if isLocked && isYielded { return "pause.circle.fill" }
        return isLocked ? "lock.fill" : "lock.open"
    }

    private var lockIconColor: Color {
        if isLocked && isYielded { return .orange }
        return isLocked ? .green : .secondary
    }

    private var lockText: String {
        if isLocked {
            if isYielded {
                return "Paused — you chose a different device"
            }
            let name = showsOutput
                ? (viewModel.preferredOutputDisplayName ?? "preferred device")
                : (viewModel.preferredInputDisplayName ?? "preferred device")
            return "Enforcing priority · \(name)"
        }
        return "No lock — devices may auto-switch"
    }
}

// MARK: - Fight offer banner

/// Shown when a watchdog keeps blocking repeated switches to the same device.
/// Enforcement continues until the user explicitly picks "Stop fighting".
struct FightOfferBanner: View {
    let offer: FightOffer
    let onStopFighting: () -> Void
    let onKeepProtecting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 12))
                Text("Something keeps switching to \(offer.attemptedName)")
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("MicGuard is holding \(offer.preferredName). If this is you, MicGuard can stop fighting until you resume the lock.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Keep holding", action: onKeepProtecting)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Use \(offer.attemptedName)", action: onStopFighting)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
    }
}

// MARK: - Input section

private struct InputSection: View {
    @ObservedObject var viewModel: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let offer = viewModel.inputFightOffer {
                FightOfferBanner(
                    offer: offer,
                    onStopFighting: { viewModel.acceptInputFightOffer() },
                    onKeepProtecting: { viewModel.dismissInputFightOffer() }
                )
            }

            Toggle(isOn: Binding(
                get: { viewModel.inputDeviceLockEnabled },
                set: { viewModel.setInputDeviceLockEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lock input device")
                        .font(.system(size: 13))
                    Text("Periodically checks and prevents changes")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { viewModel.inputAutoSwitchEnabled },
                set: { viewModel.setInputAutoSwitchEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-switch on connect").font(.system(size: 13))
                    Text("Picks the top available device when your devices change")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            DevicePriorityListView(
                devices: viewModel.inputDevices,
                onUse: { viewModel.useInputDevice(at: $0) },
                onMoveUp: { viewModel.moveInputDevice(at: $0, direction: .up) },
                onMoveDown: { viewModel.moveInputDevice(at: $0, direction: .down) },
                onRemove: { viewModel.removeInputDevice(at: $0) },
                onReapply: { viewModel.reapplyInputPriority() }
            )

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Volume control")

                VStack(spacing: 2) {
                    VolumeStrategyRow(
                        title: "None",
                        subtitle: "Don't manage input volume",
                        badge: nil,
                        isSelected: viewModel.volumeStrategy == .none,
                        action: { viewModel.setVolumeStrategy(.none) }
                    )
                    VolumeStrategyRow(
                        title: "Lock volume",
                        subtitle: "Hold at target continuously",
                        badge: nil,
                        isSelected: viewModel.volumeStrategy == .lockVolume,
                        action: { viewModel.setVolumeStrategy(.lockVolume) }
                    )
                    VolumeStrategyRow(
                        title: "Reset when mic stops",
                        subtitle: "Restore target after each meeting",
                        badge: "Recommended",
                        isSelected: viewModel.volumeStrategy == .resetWhenMicStops,
                        action: { viewModel.setVolumeStrategy(.resetWhenMicStops) }
                    )
                }

                if viewModel.volumeStrategy != .none {
                    VolumeSliderRow(viewModel: viewModel)
                        .padding(.top, 4)
                }
            }
        }
    }
}

private struct VolumeSliderRow: View {
    @ObservedObject var viewModel: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Target volume")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(viewModel.targetVolume * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
                Slider(
                    value: Binding(
                        get: { viewModel.targetVolume },
                        set: { viewModel.updateVolumeSliderPreview($0) }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing {
                            viewModel.commitVolume(viewModel.targetVolume)
                        }
                    }
                )
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

private struct VolumeStrategyRow: View {
    let title: String
    let subtitle: String
    let badge: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.5))
                    .font(.system(size: 14))
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        if let badge = badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.accentColor.opacity(0.15))
                                )
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Output section

private struct OutputSection: View {
    @ObservedObject var viewModel: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let offer = viewModel.outputFightOffer {
                FightOfferBanner(
                    offer: offer,
                    onStopFighting: { viewModel.acceptOutputFightOffer() },
                    onKeepProtecting: { viewModel.dismissOutputFightOffer() }
                )
            }

            Toggle(isOn: Binding(
                get: { viewModel.outputDeviceLockEnabled },
                set: { viewModel.setOutputDeviceLockEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lock output device")
                        .font(.system(size: 13))
                    Text("Periodically checks and prevents changes")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { viewModel.outputAutoSwitchEnabled },
                set: { viewModel.setOutputAutoSwitchEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-switch on connect").font(.system(size: 13))
                    Text("Picks the top available device when your devices change")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            DevicePriorityListView(
                devices: viewModel.outputDevices,
                onUse: { viewModel.useOutputDevice(at: $0) },
                onMoveUp: { viewModel.moveOutputDevice(at: $0, direction: .up) },
                onMoveDown: { viewModel.moveOutputDevice(at: $0, direction: .down) },
                onRemove: { viewModel.removeOutputDevice(at: $0) },
                onReapply: { viewModel.reapplyOutputPriority() }
            )

            CustomOutputVolumesSection(viewModel: viewModel)
                .padding(.top, 6)
        }
    }
}

// MARK: - Custom Output Volumes

private struct CustomOutputVolumesSection: View {
    @ObservedObject var viewModel: PopoverViewModel
    @State private var isAdding: Bool = false
    @State private var draftDeviceUID: String? = nil
    @State private var draftVolume: Float = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Custom volumes")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.4)
                Spacer()
                if !isAdding {
                    Button(action: openAdd) {
                        Label("Add", systemImage: "plus.circle")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Set a one-time default volume that's applied when a specific device becomes active")
                }
            }

            if viewModel.customOutputVolumes.isEmpty && !isAdding {
                Text("No custom levels set. Click Add for devices like loud monitor speakers.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(viewModel.customOutputVolumes) { entry in
                    CustomOutputVolumeRow(
                        entry: entry,
                        onSave: { newVolume in viewModel.setCustomOutputVolume(newVolume, for: entry.uid) },
                        onRemove: { viewModel.setCustomOutputVolume(nil, for: entry.uid) }
                    )
                }
            }

            if isAdding {
                CustomOutputVolumeAddRow(
                    availableDevices: viewModel.addableOutputDevicesForCustomVolume(),
                    selectedUID: $draftDeviceUID,
                    volume: $draftVolume,
                    onAdd: {
                        guard let uid = draftDeviceUID else { return }
                        viewModel.setCustomOutputVolume(draftVolume, for: uid)
                        closeAdd()
                    },
                    onCancel: closeAdd
                )
                .padding(.top, 4)
            }
        }
    }

    private func openAdd() {
        draftVolume = 0.5
        draftDeviceUID = viewModel.addableOutputDevicesForCustomVolume().first?.uid
        withAnimation(.easeOut(duration: 0.15)) { isAdding = true }
    }

    private func closeAdd() {
        withAnimation(.easeOut(duration: 0.15)) { isAdding = false }
    }
}

private struct CustomOutputVolumeRow: View {
    let entry: CustomOutputVolumeEntry
    let onSave: (Float) -> Void
    let onRemove: () -> Void

    @State private var isEditing: Bool = false
    @State private var draftVolume: Float = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: toggleEdit) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .foregroundColor(entry.isConnected ? .accentColor : .secondary.opacity(0.5))
                            .frame(width: 16)
                        Text(entry.displayName)
                            .font(.system(size: 12))
                            .foregroundColor(entry.isConnected ? .primary : .secondary.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !entry.isConnected {
                            Text("(disconnected)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        Spacer()
                        Text("\(Int(entry.volume * 100))%")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isEditing ? "Click to collapse" : "Click to edit volume")

                Button(action: toggleEdit) {
                    Image(systemName: isEditing ? "chevron.up" : "pencil")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help(isEditing ? "Collapse" : "Edit volume")
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove this custom level")
            }

            if isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 9))
                        Slider(value: $draftVolume, in: 0...1)
                            .controlSize(.small)
                        Text("\(Int(draftVolume * 100))%")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Cancel") {
                            withAnimation(.easeOut(duration: 0.15)) { isEditing = false }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Save") {
                            onSave(draftVolume)
                            withAnimation(.easeOut(duration: 0.15)) { isEditing = false }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
    }

    private func toggleEdit() {
        if !isEditing { draftVolume = entry.volume }
        withAnimation(.easeOut(duration: 0.15)) { isEditing.toggle() }
    }
}

private struct CustomOutputVolumeAddRow: View {
    let availableDevices: [AddableOutputDevice]
    @Binding var selectedUID: String?
    @Binding var volume: Float
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if availableDevices.isEmpty {
                Text("Every output device already has a custom level set.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("Device")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 46, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { selectedUID ?? availableDevices.first?.uid ?? "" },
                        set: { selectedUID = $0 }
                    )) {
                        ForEach(availableDevices) { device in
                            Text(device.displayName).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Text("Volume")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 46, alignment: .leading)
                    Image(systemName: "speaker.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 9))
                    Slider(value: $volume, in: 0...1)
                        .controlSize(.small)
                    Text("\(Int(volume * 100))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Add", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(selectedUID == nil || availableDevices.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// MARK: - Settings section

private struct SettingsSection: View {
    @ObservedObject var viewModel: PopoverViewModel
    @State private var showSnoozeMenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { viewModel.launchAtLogin },
                set: { viewModel.setLaunchAtLogin($0) }
            )) {
                Text("Launch at login")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { viewModel.autoResumeOnTopPriorityPick },
                set: { viewModel.setAutoResumeOnTopPriorityPick($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-resume protection on top device")
                        .font(.system(size: 13))
                    Text("Reactivates a yielded lock when you switch back to your priority")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { viewModel.hideVirtualDevices },
                set: { viewModel.setHideVirtualDevices($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hide virtual devices")
                        .font(.system(size: 13))
                    Text("Excludes loopback / aggregate devices from the priority lists")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            MicIndicatorPicker(viewModel: viewModel)
                .padding(.top, 4)
        }
    }
}

private struct MicIndicatorPicker: View {
    @ObservedObject var viewModel: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mic-in-use indicator")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.4)
                .padding(.bottom, 2)

            MicIndicatorOption(
                title: "Orange pill",
                subtitle: "Matches macOS — most visible",
                isSelected: viewModel.micInUseIndicatorStyle == .orangePill,
                action: { viewModel.setMicInUseIndicatorStyle(.orangePill) }
            )
            MicIndicatorOption(
                title: "Red pill",
                subtitle: "More alarming — easier to notice",
                isSelected: viewModel.micInUseIndicatorStyle == .redTint,
                action: { viewModel.setMicInUseIndicatorStyle(.redTint) }
            )
            MicIndicatorOption(
                title: "None",
                subtitle: "Rely on macOS's own indicator",
                isSelected: viewModel.micInUseIndicatorStyle == .none,
                action: { viewModel.setMicInUseIndicatorStyle(.none) }
            )
        }
    }
}

private struct MicIndicatorOption: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.5))
                    .font(.system(size: 13))
                    .frame(width: 14)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stats section

private struct StatsSection: View {
    @ObservedObject var viewModel: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Stats")
                Spacer()
                Button("Reset") { viewModel.resetStats() }
                    .controlSize(.small)
            }
            ForEach(StatType.allCases, id: \.self) { stat in
                HStack {
                    Text(stat.displayName)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(viewModel.stats[stat] ?? 0)")
                        .font(.system(size: 12, design: .monospaced))
                }
            }
        }
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @ObservedObject var viewModel: PopoverViewModel
    @State private var showStatsPopover = false

    var body: some View {
        HStack {
            Button("About") { viewModel.showAbout() }
                .buttonStyle(.borderless)
                .controlSize(.small)

            // Stats render in a transient popover, not inline — they're
            // diagnostic info and shouldn't grow the app UI.
            Button(action: { showStatsPopover.toggle() }) {
                Text("Stats")
                    .font(.system(size: 11, weight: .light))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Show hijacks blocked, volume corrections, and more")
            .popover(isPresented: $showStatsPopover, arrowEdge: .top) {
                StatsSection(viewModel: viewModel)
                    .padding(14)
                    .frame(width: 260)
            }

            Spacer()
            Button(action: viewModel.quit) {
                Label("Quit MicGuard", systemImage: "power")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .keyboardShortcut("q", modifiers: [.command])
            .help("Quit MicGuard (⌘Q)")
        }
    }
}
