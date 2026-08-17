//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

enum Theme {
    /// A restrained studio palette: neutral surfaces keep the meters and active
    /// controls visually dominant without imitating another application's chrome.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.05, green: 0.78, blue: 0.52, alpha: 1)
            : NSColor(srgbRed: 0.02, green: 0.57, blue: 0.36, alpha: 1)
    })

    static let panelBackground = adaptive(
        dark: NSColor(srgbRed: 0.115, green: 0.12, blue: 0.13, alpha: 1),
        light: NSColor(srgbRed: 0.94, green: 0.945, blue: 0.955, alpha: 1)
    )
    static let sectionBackground = adaptive(
        dark: NSColor(srgbRed: 0.155, green: 0.16, blue: 0.17, alpha: 1),
        light: NSColor.white
    )
    static let sectionBorder = Color.primary.opacity(0.14)
    static let rowHighlight = Color.primary.opacity(0.065)
    static let controlBackground = Color.primary.opacity(0.085)
    static let controlBorder = Color.primary.opacity(0.08)
    static let detailBackground = Color.primary.opacity(0.045)

    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// The single source of truth that keeps rows and column headers aligned.
/// The slider is flexible; every other column has a fixed width.
enum Layout {
    static let panelWidth: CGFloat = 760
    static let rowSpacing: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 10

    static let starWidth: CGFloat = 20
    static let meterWidth: CGFloat = 4
    static let iconSize: CGFloat = 28
    static let nameWidth: CGFloat = 126
    static let muteWidth: CGFloat = 24
    static let percentWidth: CGFloat = 48
    /// The button stays narrow, but the column is wide enough to fit its header
    /// on one line.
    static let boostWidth: CGFloat = 30
    static let boostColumnWidth: CGFloat = 50
    static let deviceWidth: CGFloat = 184
    static let fxWidth: CGFloat = 30

    /// Card (10) plus the row's outer (4) and inner (10) padding. The header row
    /// uses this too.
    static let contentInset: CGFloat = 18
    static let cardInset: CGFloat = 10
    static let rowOuterPadding: CGFloat = 4
    static let rowInnerPadding: CGFloat = 12

    /// The section name in the header must be exactly as wide as the row's
    /// star / meter / icon / name block.
    static var leadingBlockWidth: CGFloat {
        starWidth + meterWidth + iconSize + nameWidth + rowSpacing * 3
    }
}

enum Typography {
    static let sectionTitle = Font.system(size: 15, weight: .bold)
    static let columnLabel = Font.system(size: 11, weight: .semibold)
    static let rowName = Font.system(size: 14, weight: .medium)
    static let percent = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let detailLabel = Font.system(size: 12, weight: .medium)
}

// MARK: - Row components

/// The thin vertical level meter down the left edge of a row.
struct LevelBar: View {
    let level: Float
    let isActive: Bool
    var warnsAtPeak = true

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.10))
                if isActive {
                    Capsule()
                        .fill(warnsAtPeak && level > 0.92 ? Color.orange : Theme.accent)
                        .frame(height: proxy.size.height * CGFloat(min(1, max(0, level))))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
        }
        .frame(width: Layout.meterWidth, height: 30)
    }
}

/// A compact horizontal fader with a high-contrast thumb. Native macOS sliders
/// inherit control chrome that varies by OS release and looks out of place inside
/// the dark studio surfaces.
struct StudioSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var isDisabled = false
    let onChange: (Double) -> Void
    var onEditingChanged: ((Bool) -> Void)?

    @State private var isDragging = false

    private let knobSize: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let usableWidth = max(1, proxy.size.width - knobSize)
            let span = max(0.0001, range.upperBound - range.lowerBound)
            let fraction = min(1, max(0, (value - range.lowerBound) / span))
            let knobX = knobSize / 2 + usableWidth * CGFloat(fraction)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.13))
                    .frame(height: 4)

                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(0, knobX - knobSize / 2), height: 4)

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .position(x: knobX, y: proxy.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard !isDisabled else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        let position = min(CGFloat(1), max(CGFloat(0),
                            (gesture.location.x - knobSize / 2) / usableWidth
                        ))
                        onChange(range.lowerBound + Double(position) * span)
                    }
                    .onEnded { _ in
                        guard !isDisabled else { return }
                        isDragging = false
                        onEditingChanged?(false)
                    }
            )
        }
        .frame(height: 20)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard !isDisabled else { return }
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: onChange(min(range.upperBound, value + step))
            case .decrement: onChange(max(range.lowerBound, value - step))
            @unknown default: break
            }
        }
    }
}

/// The boost button: round, with a double up arrow. SF Symbols has no dependable
/// "double chevron up", so two are stacked.
struct BoostButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: -2.5) {
                Image(systemName: "chevron.compact.up")
                Image(systemName: "chevron.compact.up")
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isOn ? Color.white : .secondary)
            .frame(width: Layout.boostWidth, height: Layout.boostWidth)
            .background(Circle().fill(isOn ? Theme.accent : Theme.controlBackground))
        }
        .buttonStyle(.plain)
        .help(isOn ? "Boost enabled — 200% ceiling" : "Enable boost (up to 200%)")
    }
}

/// The round chevron that opens and closes sections and row details.
struct DisclosureChevron: View {
    let isExpanded: Bool
    var diameter: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Theme.controlBackground))
        }
        .buttonStyle(.plain)
    }
}

struct FavoriteStar: View {
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 13))
                .foregroundStyle(isFavorite ? Theme.accent : Color.secondary.opacity(0.45))
                .frame(width: Layout.starWidth, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites — keep it listed while closed")
    }
}

struct MuteButton: View {
    let isMuted: Bool
    var symbol: String = "speaker.wave.2.fill"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : symbol)
                .font(.system(size: 14))
                .foregroundStyle(isMuted ? Color.red : .secondary)
                .frame(width: Layout.muteWidth, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute" : "Mute")
    }
}

/// The section name and the column headers above it, on one line.
struct ColumnHeader: View {
    let title: String
    let deviceColumnTitle: String
    let isExpanded: Bool
    var showsBoost = true
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: Layout.rowSpacing) {
            HStack(spacing: 8) {
                DisclosureChevron(isExpanded: isExpanded, action: toggle)
                Text(title)
                    .font(Typography.sectionTitle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .frame(width: Layout.leadingBlockWidth, alignment: .leading)

            // The flexible area is the exact counterpart of the row's
            // mute + slider + percentage block.
            columnLabel("Volume").frame(maxWidth: .infinity)
            if showsBoost {
                columnLabel("Boost").frame(width: Layout.boostColumnWidth)
            } else {
                Color.clear.frame(width: Layout.boostColumnWidth, height: 1)
            }
            columnLabel(deviceColumnTitle).frame(width: Layout.deviceWidth)
            columnLabel("FX").frame(width: Layout.fxWidth)
        }
        .padding(.horizontal, Layout.contentInset)
        .padding(.vertical, 10)
    }

    private func columnLabel(_ text: String) -> some View {
        Text(text)
            .font(Typography.columnLabel)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// The device picker inside a row.
struct DeviceMenu: View {
    let devices: [AudioDevice]
    let selectedUID: String?
    /// Application rows offer a "follow the system" entry; system rows do not.
    let allowsSystemDefault: Bool
    let systemDefaultLabel: String
    let onSelect: (String?) -> Void

    private var selectedDevice: AudioDevice? {
        devices.first { $0.uid == selectedUID }
    }

    private var label: String {
        selectedDevice?.name ?? systemDefaultLabel
    }

    private var symbol: String {
        selectedDevice?.symbolName ?? (allowsSystemDefault
            ? "arrow.triangle.2.circlepath"
            : "hifispeaker.fill")
    }

    var body: some View {
        Menu {
            if allowsSystemDefault {
                Button { onSelect(nil) } label: {
                    Label(systemDefaultLabel, systemImage: "arrow.triangle.2.circlepath")
                }
            }
            ForEach(devices) { device in
                Button { onSelect(device.uid) } label: {
                    Label(device.name, systemImage: device.symbolName)
                }
            }
        } label: {
            Color.clear
                .frame(width: Layout.deviceWidth, height: 34)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Layout.deviceWidth, height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.controlBorder, lineWidth: 1)
        )
        .overlay {
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)
                        .truncationMode(.middle)
                }

                HStack {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            }
            .allowsHitTesting(false)
        }
    }
}

/// The shared ground for rows: hover highlight and consistent padding.
struct RowBackground: ViewModifier {
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Layout.rowInnerPadding)
            .padding(.vertical, Layout.rowVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Theme.rowHighlight : .clear)
            )
            .padding(.horizontal, Layout.rowOuterPadding)
    }
}

extension View {
    func rowBackground(isHovering: Bool) -> some View {
        modifier(RowBackground(isHovering: isHovering))
    }

    func sectionSurface() -> some View {
        padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.sectionBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.sectionBorder, lineWidth: 1)
            )
            .padding(.horizontal, Layout.cardInset)
    }
}

/// The detail section the FX button opens.
struct DetailPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.detailBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Theme.controlBorder, lineWidth: 1)
            )
            .padding(.horizontal, Layout.rowOuterPadding + Layout.rowInnerPadding)
            .padding(.bottom, 4)
    }
}
