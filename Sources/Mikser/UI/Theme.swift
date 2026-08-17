//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

enum Theme {
    /// The green audio applications tend to use. Separate tone for light and dark.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.33, green: 0.84, blue: 0.50, alpha: 1)
            : NSColor(srgbRed: 0.11, green: 0.65, blue: 0.33, alpha: 1)
    })

    static let cardBackground = Color.primary.opacity(0.055)
    static let rowHighlight = Color.primary.opacity(0.05)
    static let controlBackground = Color.primary.opacity(0.08)
    static let detailBackground = Color.primary.opacity(0.04)
}

/// The single source of truth that keeps rows and column headers aligned.
/// The slider is flexible; every other column has a fixed width.
enum Layout {
    static let panelWidth: CGFloat = 720
    static let rowSpacing: CGFloat = 9
    static let rowVerticalPadding: CGFloat = 9

    static let starWidth: CGFloat = 18
    static let meterWidth: CGFloat = 3
    static let iconSize: CGFloat = 22
    static let nameWidth: CGFloat = 124
    static let muteWidth: CGFloat = 22
    static let percentWidth: CGFloat = 46
    /// The button stays narrow, but the column is wide enough to fit its header
    /// on one line.
    static let boostWidth: CGFloat = 26
    static let boostColumnWidth: CGFloat = 48
    static let deviceWidth: CGFloat = 176
    static let fxWidth: CGFloat = 26

    /// Card (10) plus the row's outer (4) and inner (10) padding. The header row
    /// uses this too.
    static let contentInset: CGFloat = 24
    static let cardInset: CGFloat = 10
    static let rowOuterPadding: CGFloat = 4
    static let rowInnerPadding: CGFloat = 10

    /// The section name in the header must be exactly as wide as the row's
    /// star / meter / icon / name block.
    static var leadingBlockWidth: CGFloat {
        starWidth + meterWidth + iconSize + nameWidth + rowSpacing * 3
    }
}

enum Typography {
    static let sectionTitle = Font.system(size: 13, weight: .bold)
    static let columnLabel = Font.system(size: 11)
    static let rowName = Font.system(size: 13)
    static let percent = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let detailLabel = Font.system(size: 11, weight: .medium)
}

// MARK: - Row components

/// The thin vertical level meter down the left edge of a row.
struct LevelBar: View {
    let level: Float
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.10))
                if isActive {
                    Capsule()
                        .fill(level > 0.92 ? Color.orange : Theme.accent)
                        .frame(height: proxy.size.height * CGFloat(min(1, max(0, level))))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
        }
        .frame(width: Layout.meterWidth, height: 24)
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
            .font(.system(size: 10, weight: .bold))
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
    var diameter: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
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
                .font(.system(size: 11))
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
                .font(.system(size: 12))
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
            columnLabel("Level").frame(maxWidth: .infinity)
            columnLabel("Boost").frame(width: Layout.boostColumnWidth)
            columnLabel(deviceColumnTitle).frame(width: Layout.deviceWidth)
            columnLabel("FX").frame(width: Layout.fxWidth)
        }
        .padding(.horizontal, Layout.contentInset)
        .padding(.bottom, 6)
    }

    private func columnLabel(_ text: String) -> some View {
        Text(text)
            .font(Typography.columnLabel)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// The rounded card wrapping a section.
struct SectionCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 1) { content }
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.cardBackground)
            )
            .padding(.horizontal, Layout.cardInset)
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

    var body: some View {
        // A native popup button: bordered with the double arrow indicator. Menu with
        // .borderlessButton was tried and swallows both the custom background and the
        // indicator.
        Picker("", selection: Binding(
            get: { selectedUID },
            set: { onSelect($0) }
        )) {
            if allowsSystemDefault {
                Text(systemDefaultLabel).tag(String?.none)
            }
            ForEach(devices) { device in
                Text(device.name).tag(String?.some(device.uid))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: Layout.deviceWidth)
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
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.detailBackground)
            )
            .padding(.horizontal, Layout.rowOuterPadding + Layout.rowInnerPadding)
            .padding(.bottom, 4)
    }
}
