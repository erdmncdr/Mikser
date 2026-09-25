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
    /// False where nothing sits behind the window to blur (the preview window).
    var usesMaterial = true

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
        visibleAppIDs.reduce(CGFloat.zero) { total, appID in
            total + (appRowHeights[appID] ?? Layout.rowHeight)
        }
    }

    private let maximumListHeight: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let error = engine.lastError {
                errorBanner(error)
                    .padding(.bottom, 10)
            }

            sectionTitle("System", isExpanded: $systemExpanded)
            if systemExpanded {
                systemGroup
            }

            sectionTitle("Applications", isExpanded: $applicationsExpanded) {
                addApplicationMenu
            }
            .padding(.top, 14)
            if applicationsExpanded {
                applicationsGroup
            }

            if !engine.hiddenApplications.isEmpty {
                hiddenApplicationsMenu
                    .padding(.top, 8)
            }
        }
        .padding(Layout.panelPadding)
        .padding(.top, 2)
        .frame(width: Layout.panelWidth)
        .background {
            if usesMaterial {
                PanelBackground()
            } else {
                Theme.panelFallback
            }
        }
        .onAppear { engine.setMenuOpen(true) }
        .onDisappear { engine.setMenuOpen(false) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            MikserMark()
                .frame(width: 22, height: 22)
            Text("Mikser")
                .font(Typography.title)
            Spacer()
            settingsMenu
        }
        .padding(.leading, 4)
        .padding(.bottom, 12)
    }

    private var settingsMenu: some View {
        PopUpMenu(accessibilityLabel: "Settings", help: "Settings", entries: settingsEntries) { hover in
            icon("ellipsis.circle", hover: hover)
        }
    }

    private func settingsEntries() -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .action("Sound Settings…", symbol: "speaker.wave.2") {
                open("x-apple.systempreferences:com.apple.Sound-Settings.extension")
            },
            .action("Bluetooth Settings…", symbol: "wave.3.right") {
                open("x-apple.systempreferences:com.apple.BluetoothSettings")
            },
            .separator
        ]
        if !engine.hiddenApplications.isEmpty {
            entries.append(.submenu(
                title: "Hidden Applications", symbol: "eye.slash",
                entries: hiddenApplicationEntries()
            ))
            entries.append(.separator)
        }
        entries += [
            .action("Check for Updates…", symbol: "arrow.down.circle") {
                UpdateController.shared.checkForUpdates()
            },
            // A submenu stands in for a confirmation dialog: an alert from a menu
            // bar app opens behind other windows, and one stray click here would
            // otherwise erase every application's settings.
            .submenu(title: "Reset All Settings", symbol: "arrow.counterclockwise", entries: [
                .header("Every volume, route and equalizer returns to its default."),
                .action("Reset Everything") { engine.resetAll() }
            ]),
            .separator,
            .action("Quit Mikser") { NSApplication.shared.terminate(nil) }
        ]
        return entries
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    // MARK: Sections

    private func sectionTitle(
        _ title: String, isExpanded: Binding<Bool>
    ) -> some View {
        sectionTitle(title, isExpanded: isExpanded) { EmptyView() }
    }

    private func sectionTitle<Accessory: View>(
        _ title: String, isExpanded: Binding<Bool>,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Typography.sectionTitle)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded.wrappedValue ? "Collapse \(title)" : "Expand \(title)")

            Spacer()
            accessory()
        }
        .frame(height: 26)
        .padding(.leading, 4)
        .padding(.bottom, 6)
    }

    // MARK: System

    private var systemGroup: some View {
        VStack(spacing: 0) {
            outputRow
            inputRow
            effectsRow
        }
        .groupSurface()
    }

    private var outputRow: some View {
        let device = engine.defaultOutputDevice
        return SystemRow(
            symbol: device?.symbolName ?? "hifispeaker.fill",
            title: "Output",
            volume: engine.systemVolume.map(Double.init),
            onVolumeChange: { engine.setSystemVolume(Float($0)) },
            isMuted: engine.systemMuted,
            onMuteToggle: { engine.setSystemMuted(!engine.systemMuted) },
            route: RouteMenu(
                title: device?.name ?? "No output device",
                accessibilityLabel: "Output device",
                entries: { deviceEntries(engine.outputDevices, selected: device?.uid) {
                    engine.setSystemOutputDevice($0)
                } }
            ),
            isExpanded: outputDetailExpanded,
            onToggleExpand: {
                withAnimation(.easeOut(duration: 0.18)) { outputDetailExpanded.toggle() }
            }
        ) {
            sampleRateControl
        }
    }

    private var inputRow: some View {
        let device = engine.defaultInputDevice
        return SystemRow(
            symbol: "mic.fill",
            title: "Input",
            volume: engine.inputVolume.map(Double.init),
            onVolumeChange: { engine.setInputVolume(Float($0)) },
            isMuted: engine.inputMuted,
            onMuteToggle: { engine.setInputMuted(!engine.inputMuted) },
            muteSymbol: "mic.fill",
            mutedSymbol: "mic.slash.fill",
            route: RouteMenu(
                title: device?.name ?? "No input device",
                accessibilityLabel: "Input device",
                entries: { deviceEntries(engine.inputDevices, selected: device?.uid) {
                    engine.setSystemInputDevice($0)
                } }
            )
        )
    }

    /// Alert sounds. Their volume is written through AppleScript, so it is held
    /// locally while dragging and only sent to the system on release.
    private var effectsRow: some View {
        let device = engine.effectsDevice
        return SystemRow(
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
            route: RouteMenu(
                title: device?.name ?? "No output device",
                accessibilityLabel: "Sound effects device",
                entries: { deviceEntries(engine.outputDevices, selected: device?.uid) {
                    engine.setEffectsDevice($0)
                } }
            )
        )
    }

    private func deviceEntries(
        _ devices: [AudioDevice], selected: String?,
        choose: @escaping (AudioDevice) -> Void
    ) -> [MenuEntry] {
        guard !devices.isEmpty else {
            return [.action("No devices available", isEnabled: false) {}]
        }
        return devices.map { device in
            .action(device.name, symbol: device.symbolName, isChecked: device.uid == selected) {
                choose(device)
            }
        }
    }

    private var sampleRateControl: some View {
        DetailRow(label: "Sample rate") {
            let device = engine.defaultOutputDevice
            let rates = engine.availableSampleRates(of: device)
            if rates.isEmpty {
                Text("Not reported by this device")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                let current = engine.sampleRate(of: device)
                PillMenu(
                    title: current.map(Self.format(rate:)) ?? "—",
                    accessibilityLabel: "Sample rate",
                    entries: {
                        rates.map { rate in
                            .action(Self.format(rate: rate), isChecked: rate == current) {
                                if let device { engine.setSampleRate(rate, for: device) }
                            }
                        }
                    }
                )
            }
            Spacer()
        }
    }

    /// Written out by hand: the locale's grouping separator turns 44100 into
    /// "44.100", which reads as 44 in Turkish and German.
    private static func format(rate: Double) -> String {
        let kilohertz = rate / 1000
        return kilohertz == kilohertz.rounded()
            ? "\(Int(kilohertz)) kHz"
            : String(format: "%.1f kHz", kilohertz)
    }

    // MARK: Applications

    private var applicationsGroup: some View {
        Group {
            if engine.visibleApps.isEmpty {
                emptyApplications
            } else {
                appList
            }
        }
        .groupSurface()
    }

    private var emptyApplications: some View {
        VStack(spacing: 4) {
            Text(engine.apps.isEmpty ? "Nothing is playing" : "Every application is hidden")
                .font(Typography.rowName)
            Text(engine.apps.isEmpty
                 ? "Applications appear here when they make a sound. Add one to keep it listed."
                 : "Show them again from Hidden below.")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
    }

    private var appList: some View {
        ScrollView {
            VStack(spacing: 0) {
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
        .scrollIndicators(.automatic)
        .frame(height: min(max(visibleAppsHeight, 1), maximumListHeight))
        .onPreferenceChange(AppRowHeightsKey.self) { heights in
            for (appID, height) in heights where appRowHeights[appID] != height {
                appRowHeights[appID] = height
            }
        }
    }

    // MARK: Adding and hiding applications

    private var addApplicationMenu: some View {
        PopUpMenu(
            accessibilityLabel: "Add Application",
            help: "Keep an application listed even when it is silent",
            entries: addApplicationEntries
        ) { hover in
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                Text("Add")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(hover ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(hover ? Theme.controlFill : .clear))
        }
    }

    private func addApplicationEntries() -> [MenuEntry] {
        let listed = Set(engine.apps.map(\.id))
        let running = AudioProcessMonitor.selectableRunningApplications()
            .filter { !listed.contains($0.bundleID) }

        var entries: [MenuEntry] = [
            .action("Choose Application…", symbol: "folder") { selectApplication() }
        ]
        if !running.isEmpty {
            entries.append(.separator)
            entries.append(.header("Running"))
            entries += running.map { item in
                .action(item.name, image: item.icon) { engine.addFavorite(bundleID: item.bundleID) }
            }
        }
        return entries
    }

    private var hiddenApplicationsMenu: some View {
        PopUpMenu(accessibilityLabel: "Hidden applications", entries: hiddenApplicationEntries) { hover in
            HStack(spacing: 5) {
                Image(systemName: "eye.slash")
                Text("\(engine.hiddenApplications.count) hidden")
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(Typography.caption)
            .foregroundStyle(hover ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(hover ? Theme.controlFill : .clear))
        }
        .padding(.leading, -4)
    }

    private func hiddenApplicationEntries() -> [MenuEntry] {
        engine.hiddenApplications.map { item in
            .action("Show \(item.name)") { engine.showApplication(item.id) }
        } + [
            .separator,
            .action("Show All") { engine.showAllApplications() }
        ]
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.boost)
            Text(message)
                .font(Typography.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "xmark", help: "Dismiss") { engine.dismissError() }
                .padding(.top, -5)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.boost.opacity(0.12))
        )
    }
}

/// A row in the System group: output, input or alert sounds. It shares the
/// application rows' columns; the boost column stays empty.
struct SystemRow<Detail: View>: View {
    let symbol: String
    let title: String
    let volume: Double?
    let onVolumeChange: (Double) -> Void
    var onVolumeCommit: (() -> Void)?
    var isMuted: Bool?
    var onMuteToggle: (() -> Void)?
    var muteSymbol: String = "speaker.wave.2.fill"
    var mutedSymbol: String = "speaker.slash.fill"
    let route: RouteMenu
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
        HStack(spacing: Layout.columnSpacing) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Layout.iconSize, height: Layout.iconSize)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.controlFill)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Typography.rowName)
                    .lineLimit(1)
                route
            }
            .frame(width: Layout.nameWidth, alignment: .leading)

            if let isMuted, let onMuteToggle {
                MuteButton(isMuted: isMuted, symbol: muteSymbol, mutedSymbol: mutedSymbol, action: onMuteToggle)
            } else {
                Color.clear.frame(width: Layout.muteWidth, height: 22)
            }

            Fader(
                value: volume ?? 0,
                range: 0...1,
                isDisabled: volume == nil || (isMuted ?? false),
                accessibilityLabel: "\(title) volume",
                onChange: onVolumeChange,
                onEditingChanged: { editing in if !editing { onVolumeCommit?() } }
            )
            .help(volume == nil ? "This device has no adjustable volume" : "")

            Text(volume.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(Typography.percent)
                .foregroundStyle(.secondary)
                .frame(width: Layout.percentWidth, alignment: .trailing)

            Color.clear.frame(width: Layout.boostWidth, height: 1)

            if let onToggleExpand {
                DisclosureChevron(isExpanded: isExpanded, action: onToggleExpand)
            } else {
                Color.clear.frame(width: Layout.chevronWidth, height: 1)
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
        mutedSymbol: String = "speaker.slash.fill",
        route: RouteMenu
    ) {
        self.init(
            symbol: symbol, title: title, volume: volume,
            onVolumeChange: onVolumeChange, onVolumeCommit: onVolumeCommit,
            isMuted: isMuted, onMuteToggle: onMuteToggle,
            muteSymbol: muteSymbol, mutedSymbol: mutedSymbol, route: route,
            isExpanded: false, onToggleExpand: nil, detail: { EmptyView() }
        )
    }
}

/// The brand mark in the panel header: the application icon's three faders on
/// its mint ground.
struct MikserMark: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let body = Path(roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                            cornerRadius: side * 0.26, style: .continuous)
            context.fill(body, with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.40, green: 0.95, blue: 0.76),
                    Color(red: 0.13, green: 0.78, blue: 0.61),
                    Color(red: 0.04, green: 0.42, blue: 0.44)
                ]),
                startPoint: .zero, endPoint: CGPoint(x: side, y: side)
            ))

            let top = side * 0.24, bottom = side * 0.76
            let knob = side * 0.17
            for (x, fraction) in [(0.3, 0.74), (0.5, 0.36), (0.7, 0.57)] as [(CGFloat, CGFloat)] {
                let cx = side * x
                context.fill(
                    Path(roundedRect: CGRect(x: cx - side * 0.03, y: top, width: side * 0.06, height: bottom - top),
                         cornerRadius: side * 0.03),
                    with: .color(.white.opacity(0.45))
                )
                let cy = bottom - (bottom - top) * fraction
                context.fill(
                    Path(ellipseIn: CGRect(x: cx - knob / 2, y: cy - knob / 2, width: knob, height: knob)),
                    with: .color(.white)
                )
            }
        }
        .accessibilityHidden(true)
    }
}
