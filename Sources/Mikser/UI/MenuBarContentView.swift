//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Measures each application row independently. Keeping the identifier with the
/// height lets the panel total only the rows that are still visible.
private struct AppRowHeightsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct MenuBarContentView: View {
    @Bindable var engine: MixerEngine

    @AppStorage("mikser.systemExpanded") private var systemExpanded = true
    @AppStorage("mikser.applicationsExpanded") private var applicationsExpanded = true

    /// A ScrollView has no natural height of its own. Row heights are retained by
    /// application ID so hiding or restoring a row updates the total immediately.
    @State private var appRowHeights: [String: CGFloat] = [:]
    @State private var effectsDraft: Double?

    // Details left open are remembered across sessions. @AppStorage cannot hold a
    // set, so the row identifiers live in one newline-separated string.
    @AppStorage("mikser.outputDetailExpanded") private var outputDetailExpanded = false
    @AppStorage("mikser.expandedRows") private var expandedRowsRaw = ""

    private var expandedRows: Binding<Set<String>> {
        Binding(
            get: { Set(expandedRowsRaw.split(separator: "\n").map(String.init)) },
            set: { expandedRowsRaw = $0.sorted().joined(separator: "\n") }
        )
    }

    private var visibleAppIDs: [String] {
        engine.visibleApps.map(\.id)
    }

    private var visibleAppsHeight: CGFloat {
        let rows = visibleAppIDs.reduce(CGFloat.zero) { total, appID in
            total + (appRowHeights[appID] ?? Layout.standardRowHeight)
        }
        let gaps = CGFloat(max(visibleAppIDs.count - 1, 0))
        return rows + gaps
    }

    private let maximumListHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            systemSection.padding(.top, 8)
            applicationsSection.padding(.top, 8)
            addApplicationBar.padding(.vertical, 8)

            if let error = engine.lastError {
                errorBanner(error)
            }
        }
        .padding(.vertical, 8)
        .frame(width: Layout.panelWidth)
        .background(Theme.panelBackground)
        .onAppear { engine.setMenuOpen(true) }
        .onDisappear { engine.setMenuOpen(false) }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text("Mikser")
                .font(.system(size: 18, weight: .bold))
                .frame(maxWidth: .infinity)

            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.controlBackground))
                Spacer()
                settingsMenu
            }
        }
        .padding(.horizontal, Layout.contentInset)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button("Sound Settings…") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
                )
            }
            Button("Bluetooth Settings…") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
                )
            }
            Divider()
            if !engine.hiddenApplications.isEmpty {
                Menu("Hidden Applications") {
                    ForEach(engine.hiddenApplications) { item in
                        Button(item.name) { engine.showApplication(item.id) }
                    }
                    Divider()
                    Button("Show All") { engine.showAllApplications() }
                }
                Divider()
            }
            Button("Check for Updates…") {
                UpdateController.shared.checkForUpdates()
            }
            Divider()
            Button("Reset All Settings") { engine.resetAll() }
            Divider()
            Button("Quit Mikser") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Theme.accent)
        .frame(width: 30, height: 30)
        .help("Settings")
    }

    // MARK: System

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(
                title: "System", deviceColumnTitle: "Device",
                isExpanded: systemExpanded, showsBoost: false
            ) {
                withAnimation(.easeOut(duration: 0.15)) { systemExpanded.toggle() }
            }

            if systemExpanded {
                VStack(spacing: 1) {
                    outputRow
                    inputRow
                    effectsRow
                }
                .padding(.bottom, 4)
            }
        }
        .sectionSurface()
    }

    private var outputRow: some View {
        SystemRow(
            symbol: engine.defaultOutputDevice?.symbolName ?? "hifispeaker.fill",
            title: "Output",
            volume: engine.systemVolume.map(Double.init),
            onVolumeChange: { engine.setSystemVolume(Float($0)) },
            isMuted: engine.systemMuted,
            onMuteToggle: { engine.setSystemMuted(!engine.systemMuted) },
            devices: engine.outputDevices,
            selectedUID: engine.defaultOutputDevice?.uid,
            onSelectDevice: { uid in
                if let device = engine.outputDevices.first(where: { $0.uid == uid }) {
                    engine.setSystemOutputDevice(device)
                }
            },
            isExpanded: outputDetailExpanded,
            onToggleExpand: {
                withAnimation(.easeOut(duration: 0.15)) { outputDetailExpanded.toggle() }
            }
        ) {
            sampleRateControl
        }
    }

    private var inputRow: some View {
        SystemRow(
            symbol: "mic.fill",
            title: "Input",
            volume: engine.inputVolume.map(Double.init),
            onVolumeChange: { engine.setInputVolume(Float($0)) },
            isMuted: engine.inputMuted,
            onMuteToggle: { engine.setInputMuted(!engine.inputMuted) },
            muteSymbol: "mic.fill",
            devices: engine.inputDevices,
            selectedUID: engine.defaultInputDevice?.uid,
            onSelectDevice: { uid in
                if let device = engine.inputDevices.first(where: { $0.uid == uid }) {
                    engine.setSystemInputDevice(device)
                }
            }
        )
    }

    /// Alert sounds. Their volume is written through AppleScript, so it is held
    /// locally while dragging and only sent to the system on release.
    private var effectsRow: some View {
        SystemRow(
            symbol: "bell.fill",
            title: "Sound Effects",
            volume: effectsDraft ?? engine.effectsVolume.map(Double.init),
            onVolumeChange: { effectsDraft = $0 },
            onVolumeCommit: {
                if let draft = effectsDraft {
                    engine.setEffectsVolume(Float(draft))
                    effectsDraft = nil
                }
            },
            devices: engine.outputDevices,
            selectedUID: engine.effectsDevice?.uid,
            onSelectDevice: { uid in
                if let device = engine.outputDevices.first(where: { $0.uid == uid }) {
                    engine.setEffectsDevice(device)
                }
            }
        )
    }

    private var sampleRateControl: some View {
        HStack(spacing: 10) {
            Text("Sample Rate")
                .font(Typography.detailLabel)
                .frame(width: 110, alignment: .leading)

            let rates = engine.availableSampleRates(of: engine.defaultOutputDevice)
            if rates.isEmpty {
                Text("Not reported by this device")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { engine.sampleRate(of: engine.defaultOutputDevice) ?? rates[0] },
                    set: { rate in
                        if let device = engine.defaultOutputDevice {
                            engine.setSampleRate(rate, for: device)
                        }
                    }
                )) {
                    ForEach(rates, id: \.self) { rate in
                        // verbatim: Text applies the locale's grouping separator to
                        // interpolated numbers, and "24.000 Hz" reads as 24 by mistake.
                        Text(verbatim: "\(Int(rate)) Hz").tag(rate)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
            }
            Spacer()
        }
    }

    // MARK: Applications

    private var applicationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(
                title: "Applications", deviceColumnTitle: "Route To",
                isExpanded: applicationsExpanded
            ) {
                withAnimation(.easeOut(duration: 0.15)) { applicationsExpanded.toggle() }
            }

            if applicationsExpanded {
                if engine.visibleApps.isEmpty {
                    Text(engine.apps.isEmpty
                         ? "No applications are playing audio"
                         : "All applications are hidden")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                } else {
                    appList.padding(.bottom, 4)
                }
            }
        }
        .sectionSurface()
    }

    private var appList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(engine.visibleApps) { app in
                    AppRowView(app: app, engine: engine, expandedRows: expandedRows)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: AppRowHeightsKey.self,
                                    value: [app.id: proxy.size.height]
                                )
                            }
                        )
                }
            }
        }
        .id(visibleAppIDs)
        .frame(height: min(max(visibleAppsHeight, 1), maximumListHeight))
        .onPreferenceChange(AppRowHeightsKey.self) { heights in
            for (appID, height) in heights where appRowHeights[appID] != height {
                appRowHeights[appID] = height
            }
        }
    }

    // MARK: Adding applications

    private var addApplicationBar: some View {
        HStack {
            Menu {
                Button("Choose Application…") { selectApplication() }
                Divider()
                Section("Running Applications") {
                    ForEach(AudioProcessMonitor.selectableRunningApplications(), id: \.bundleID) { item in
                        Button(item.name) { engine.addFavorite(bundleID: item.bundleID) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text("Add Application")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.leading, 13)
                .padding(.trailing, 10)
                .frame(height: 34)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.sectionBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.sectionBorder, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
            .help("A favorite remains listed even when it is not playing audio")

            Spacer()

            if !engine.hiddenApplications.isEmpty {
                Menu {
                    ForEach(engine.hiddenApplications) { item in
                        Button(item.name) { engine.showApplication(item.id) }
                    }
                    Divider()
                    Button("Show All") { engine.showAllApplications() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash.fill")
                        Text("Hidden \(engine.hiddenApplications.count)")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.sectionBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.sectionBorder, lineWidth: 1)
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, Layout.cardInset + 4)
    }

    private func selectApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add"

        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        engine.addFavorite(bundleID: bundleID)
    }

    // MARK: Error

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Layout.contentInset)
            .padding(.top, 12)
    }
}

/// The rows in the System section (output, input, sound effects).
/// They use the same column metrics as application rows; only the star is replaced
/// by empty space.
struct SystemRow<Detail: View>: View {
    let symbol: String
    let title: String
    let volume: Double?
    let onVolumeChange: (Double) -> Void
    var onVolumeCommit: (() -> Void)?
    var isMuted: Bool?
    var onMuteToggle: (() -> Void)?
    var muteSymbol: String = "speaker.wave.2.fill"
    let devices: [AudioDevice]
    let selectedUID: String?
    let onSelectDevice: (String) -> Void
    var isExpanded: Bool = false
    var onToggleExpand: (() -> Void)?
    @ViewBuilder var detail: Detail

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if isExpanded, !(Detail.self == EmptyView.self) {
                DetailPanel { detail }
            }
        }
    }

    private var mainRow: some View {
        HStack(spacing: Layout.rowSpacing) {
            // System rows have no favourite control, but retain the same visual
            // rhythm as application rows. Their meter reflects the current level.
            Color.clear.frame(width: Layout.starWidth, height: 20)
            LevelBar(
                level: Float(volume ?? 0),
                isActive: volume != nil && !(isMuted ?? false),
                warnsAtPeak: false
            )

            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: Layout.iconSize, height: Layout.iconSize)

            Text(title)
                .font(Typography.rowName)
                .lineLimit(1)
                .frame(width: Layout.nameWidth, alignment: .leading)

            if let isMuted, let onMuteToggle {
                MuteButton(isMuted: isMuted, symbol: muteSymbol, action: onMuteToggle)
            } else {
                Image(systemName: muteSymbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: Layout.muteWidth, height: 20)
            }

            StudioSlider(
                value: volume ?? 0,
                range: 0...1,
                isDisabled: volume == nil || (isMuted ?? false),
                onChange: onVolumeChange,
                onEditingChanged: { editing in if !editing { onVolumeCommit?() } }
            )

            Text(volume.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(Typography.percent)
                .foregroundStyle(volume == nil ? .secondary : .primary)
                .frame(width: Layout.percentWidth, alignment: .trailing)

            // System rows have no boost; the space keeps the columns aligned.
            Color.clear.frame(width: Layout.boostColumnWidth, height: 20)

            DeviceMenu(
                devices: devices,
                selectedUID: selectedUID,
                allowsSystemDefault: false,
                systemDefaultLabel: "No Device",
                onSelect: { uid in if let uid { onSelectDevice(uid) } }
            )

            if let onToggleExpand {
                DisclosureChevron(isExpanded: isExpanded, diameter: Layout.fxWidth, action: onToggleExpand)
                    .frame(width: Layout.fxWidth)
            } else {
                Color.clear.frame(width: Layout.fxWidth, height: 20)
            }
        }
        .rowBackground(isHovering: isHovering)
        .onHover { isHovering = $0 }
    }
}

extension SystemRow where Detail == EmptyView {
    init(
        symbol: String, title: String, volume: Double?,
        onVolumeChange: @escaping (Double) -> Void,
        onVolumeCommit: (() -> Void)? = nil,
        isMuted: Bool? = nil, onMuteToggle: (() -> Void)? = nil,
        muteSymbol: String = "speaker.wave.2.fill",
        devices: [AudioDevice], selectedUID: String?,
        onSelectDevice: @escaping (String) -> Void
    ) {
        self.init(
            symbol: symbol, title: title, volume: volume,
            onVolumeChange: onVolumeChange, onVolumeCommit: onVolumeCommit,
            isMuted: isMuted, onMuteToggle: onMuteToggle, muteSymbol: muteSymbol,
            devices: devices, selectedUID: selectedUID, onSelectDevice: onSelectDevice,
            isExpanded: false, onToggleExpand: nil, detail: { EmptyView() }
        )
    }
}
