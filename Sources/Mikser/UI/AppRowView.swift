//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// An application row: icon · name and route · mute · fader · percentage ·
/// boost · details
struct AppRowView: View {
    let app: AudioApp
    @Bindable var engine: MixerEngine
    @Binding var expandedRows: Set<String>

    @State private var isHovering = false

    private var settings: AppSettings { engine.settings(for: app.id) }
    private var isControlled: Bool { engine.isControlled(app.id) }
    private var isExpanded: Bool { expandedRows.contains(app.id) }

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if isExpanded { detailPanel }
        }
    }

    private var mainRow: some View {
        HStack(spacing: Layout.columnSpacing) {
            icon

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(Typography.rowName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    favoriteStar
                }
                routeMenu
            }
            .frame(width: Layout.nameWidth, alignment: .leading)

            MuteButton(isMuted: settings.isMuted) {
                engine.setMuted(!settings.isMuted, for: app.id)
            }

            Fader(
                value: Double(settings.volume),
                range: 0...Double(settings.maximumVolume),
                isDisabled: settings.isMuted,
                taper: settings.isBoosted ? .boost : .linear,
                // Only a processed application has a meter reading.
                level: isControlled ? engine.levels[app.id] ?? 0 : nil,
                accessibilityLabel: "\(app.name) volume",
                onChange: { engine.setVolume(Float($0), for: app.id) }
            )

            Text("\(Int((settings.volume * 100).rounded()))%")
                .font(Typography.percent)
                .foregroundStyle(settings.volume > 1.001
                                 ? AnyShapeStyle(Theme.boost) : AnyShapeStyle(.secondary))
                .frame(width: Layout.percentWidth, alignment: .trailing)

            BoostButton(isOn: settings.isBoosted) {
                engine.setBoosted(!settings.isBoosted, for: app.id)
            }

            DisclosureChevron(
                isExpanded: isExpanded,
                help: isExpanded ? "Hide balance and equalizer" : "Balance and equalizer"
            ) {
                withAnimation(.easeOut(duration: 0.18)) {
                    if isExpanded { expandedRows.remove(app.id) } else { expandedRows.insert(app.id) }
                }
            }
        }
        // Applications that are not running are listed because they are favourites;
        // their settings are kept and applied once they start playing.
        .opacity(app.isConnected ? 1 : 0.55)
        .rowBackground(isHovering: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Return to 100%") { engine.setVolume(1, for: app.id) }
            Button(app.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                engine.toggleFavorite(app.id)
            }
            Button("Hide from List") {
                expandedRows.remove(app.id)
                engine.hideApplication(app.id)
            }
            if isControlled {
                Divider()
                Button("Stop Controlling \(app.name)") { engine.reset(app.id) }
            }
        }
    }

    /// Shown when the application is a favourite; offered on hover otherwise, so
    /// the list is not lined with empty stars.
    @ViewBuilder
    private var favoriteStar: some View {
        if app.isFavorite || isHovering {
            Button {
                engine.toggleFavorite(app.id)
            } label: {
                Image(systemName: app.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(app.isFavorite ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(app.isFavorite
                  ? "Favorite: stays listed when silent. Click to remove."
                  : "Add to Favorites: keep it listed when silent")
            .accessibilityLabel(app.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    private var routeMenu: some View {
        let device = settings.outputDeviceUID.flatMap { uid in
            engine.outputDevices.first { $0.uid == uid }
        }
        let title: String
        if let device {
            title = device.name
        } else if settings.outputDeviceUID != nil {
            // Routed to a device that is not connected right now.
            title = "Device not connected"
        } else {
            title = "System output"
        }

        return RouteMenu(
            title: title,
            symbol: device == nil ? nil : "arrow.turn.down.right",
            isHighlighted: settings.outputDeviceUID != nil,
            accessibilityLabel: "\(app.name) output",
            entries: routeEntries
        )
    }

    private func routeEntries() -> [MenuEntry] {
        let selected = settings.outputDeviceUID
        var entries: [MenuEntry] = [
            .action("System Output", symbol: "arrow.triangle.2.circlepath", isChecked: selected == nil) {
                engine.setOutputDevice(nil, for: app.id)
            },
            .separator
        ]
        entries += engine.outputDevices.map { device in
            .action(device.name, symbol: device.symbolName, isChecked: device.uid == selected) {
                engine.setOutputDevice(device.uid, for: app.id)
            }
        }
        return entries
    }

    // MARK: Detail

    private var detailPanel: some View {
        DetailPanel {
            if !app.isConnected {
                Text("\(app.name) is not playing. These settings apply as soon as it makes a sound.")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DetailRow(label: "Balance") {
                Text("L").font(Typography.caption).foregroundStyle(.tertiary)
                Fader(
                    value: Double(settings.balance),
                    range: -1...1,
                    origin: 0,
                    accessibilityLabel: "Balance",
                    accessibilityValue: balanceLabel,
                    onChange: { value in
                        // A small detent at the center makes it easy to return to.
                        let snapped = abs(value) < 0.04 ? 0 : value
                        engine.setBalance(Float(snapped), for: app.id)
                    }
                )
                .frame(maxWidth: 240)
                Text("R").font(Typography.caption).foregroundStyle(.tertiary)

                Text(balanceLabel)
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                    .onTapGesture(count: 2) { engine.setBalance(0, for: app.id) }
                    .help("Double-click to center")
                Spacer(minLength: 0)
            }

            EqualizerView(appID: app.id, settings: settings.equalizer, engine: engine)
        }
    }

    private var balanceLabel: String {
        let percent = Int((abs(settings.balance) * 100).rounded())
        if percent == 0 { return "Center" }
        return settings.balance < 0 ? "Left \(percent)%" : "Right \(percent)%"
    }

    private var icon: some View {
        Group {
            if let image = app.icon {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .frame(width: Layout.iconSize, height: Layout.iconSize)
        .saturation(settings.isMuted ? 0 : 1)
        .opacity(settings.isMuted ? 0.5 : 1)
    }
}
