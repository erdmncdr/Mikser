//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// An application row: star · meter · icon · name · mute · slider · percentage ·
/// boost · device · FX
struct AppRowView: View {
    let app: AudioApp
    @Bindable var engine: MixerEngine
    @Binding var expandedRows: Set<String>

    @State private var isHovering = false

    private var settings: AppSettings { engine.settings(for: app.id) }
    private var isControlled: Bool { engine.isControlled(app.id) }
    private var level: Float { engine.levels[app.id] ?? 0 }
    private var isExpanded: Bool { expandedRows.contains(app.id) }

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if isExpanded { detailPanel }
        }
    }

    private var mainRow: some View {
        HStack(spacing: Layout.rowSpacing) {
            FavoriteStar(isFavorite: app.isFavorite) {
                engine.toggleFavorite(app.id)
            }

            LevelBar(level: level, isActive: isControlled && !settings.isMuted)

            icon

            Text(app.name)
                .font(Typography.rowName)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Layout.nameWidth, alignment: .leading)
                .opacity(settings.isMuted ? 0.5 : 1)

            MuteButton(isMuted: settings.isMuted) {
                engine.setMuted(!settings.isMuted, for: app.id)
            }

            StudioSlider(
                value: Double(settings.volume),
                range: 0...Double(settings.maximumVolume),
                isDisabled: settings.isMuted,
                taper: settings.isBoosted ? .boost : .linear,
                onChange: { engine.setVolume(Float($0), for: app.id) }
            )

            Text("\(Int((settings.volume * 100).rounded()))%")
                .font(Typography.percent)
                .foregroundStyle(isControlled ? .primary : .secondary)
                .frame(width: Layout.percentWidth, alignment: .trailing)

            BoostButton(isOn: settings.isBoosted) {
                engine.setBoosted(!settings.isBoosted, for: app.id)
            }
            .frame(width: Layout.boostColumnWidth)

            DeviceMenu(
                devices: engine.outputDevices,
                selectedUID: settings.outputDeviceUID,
                allowsSystemDefault: true,
                systemDefaultLabel: "Follow System",
                onSelect: { engine.setOutputDevice($0, for: app.id) }
            )

            DisclosureChevron(isExpanded: isExpanded, diameter: Layout.fxWidth) {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isExpanded { expandedRows.remove(app.id) } else { expandedRows.insert(app.id) }
                }
            }
            .frame(width: Layout.fxWidth)
            .help(isExpanded ? "Hide details" : "Details for \(app.name)")
        }
        // Applications that are not running are in the list because they are
        // favourites; their settings are kept and applied once they start playing.
        // Dimming the row makes that state visible.
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
                Button("Remove from Mikser") { engine.reset(app.id) }
            }
        }
    }

    // MARK: Detail

    private var detailPanel: some View {
        DetailPanel {
            if !app.isConnected {
                Text("\(app.name) is not playing audio. Its settings are saved and will apply when playback starts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("Balance")
                    .font(Typography.detailLabel)
                    .frame(width: 76, alignment: .leading)

                Text("L").font(.system(size: 10)).foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { Double(settings.balance) },
                        set: { engine.setBalance(Float($0), for: app.id) }
                    ),
                    in: -1...1
                )
                .tint(Theme.accent)

                Text("R").font(.system(size: 10)).foregroundStyle(.secondary)

                Text(balanceLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)

                Button {
                    engine.setBalance(0, for: app.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.controlBackground))
                }
                .buttonStyle(.plain)
                .disabled(settings.balance == 0)
                .help("Center balance")
            }

            Divider().opacity(0.5)

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
                    .padding(3)
            }
        }
        .frame(width: Layout.iconSize, height: Layout.iconSize)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(settings.isMuted ? 0.45 : 1)
    }
}
