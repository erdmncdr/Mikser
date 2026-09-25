//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

enum Theme {
    /// The mint of the application icon, tuned for contrast on each appearance.
    static let accent = adaptive(
        dark: NSColor(srgbRed: 0.16, green: 0.84, blue: 0.64, alpha: 1),
        light: NSColor(srgbRed: 0.02, green: 0.58, blue: 0.43, alpha: 1)
    )
    /// Gain above 100%. Amber rather than the accent, because audio past unity is
    /// the one state that deserves a second look.
    static let boost = adaptive(
        dark: NSColor(srgbRed: 1.0, green: 0.71, blue: 0.20, alpha: 1),
        light: NSColor(srgbRed: 0.85, green: 0.50, blue: 0.0, alpha: 1)
    )
    static let muted = Color(nsColor: .systemRed)

    /// Only used where the window has no material behind it (the preview window
    /// and snapshots). In the menu bar the panel sits on the system's own
    /// translucent popover material.
    static let panelFallback = adaptive(
        dark: NSColor(srgbRed: 0.16, green: 0.165, blue: 0.175, alpha: 1),
        light: NSColor(srgbRed: 0.925, green: 0.93, blue: 0.94, alpha: 1)
    )
    static let groupFill = Color.primary.opacity(0.05)
    static let groupStroke = Color.primary.opacity(0.07)
    static let rowHighlight = Color.primary.opacity(0.06)
    static let controlFill = Color.primary.opacity(0.08)
    static let controlFillHover = Color.primary.opacity(0.13)
    static let track = Color.primary.opacity(0.12)
    static let hairline = Color.primary.opacity(0.08)

    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// Every row shares these column widths; the fader takes whatever is left.
enum Layout {
    static let panelWidth: CGFloat = 640
    static let panelPadding: CGFloat = 12
    static let columnSpacing: CGFloat = 10

    static let iconSize: CGFloat = 28
    static let nameWidth: CGFloat = 170
    static let muteWidth: CGFloat = 22
    static let percentWidth: CGFloat = 44
    static let boostWidth: CGFloat = 26
    static let chevronWidth: CGFloat = 24

    static let rowHorizontalPadding: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 7
    /// A row's natural height: the two-line name block plus padding.
    static let rowHeight: CGFloat = 32 + rowVerticalPadding * 2
    static let groupRadius: CGFloat = 12
}

enum Typography {
    static let title = Font.system(size: 15, weight: .semibold)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let rowName = Font.system(size: 13, weight: .medium)
    static let rowDetail = Font.system(size: 11)
    static let percent = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let detailLabel = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11)
}

// MARK: - Fader

/// How a fader position maps to its value.
///
/// A boosted volume fader spans 0-500%, and with a straight linear mapping the
/// everyday 0-100% region would be squeezed into the first fifth of the track.
///
/// `.boost` keeps unity at the midpoint and gives the half above it a constant
/// number of decibels per pixel, which is how a gain control should behave: the
/// step from 100% to 120% takes as much travel as the step from 400% to 480%.
enum SliderTaper {
    case linear
    case boost

    func value(atPosition position: Double, in range: ClosedRange<Double>) -> Double {
        switch self {
        case .linear:
            return range.lowerBound + position * (range.upperBound - range.lowerBound)
        case .boost:
            let maximum = range.upperBound
            guard maximum > 1 else {
                return range.lowerBound + position * (maximum - range.lowerBound)
            }
            if position <= 0.5 { return position * 2 }
            return pow(maximum, (position - 0.5) * 2)
        }
    }

    func position(forValue value: Double, in range: ClosedRange<Double>) -> Double {
        switch self {
        case .linear:
            let span = max(0.0001, range.upperBound - range.lowerBound)
            return (value - range.lowerBound) / span
        case .boost:
            let maximum = range.upperBound
            guard maximum > 1 else {
                let span = max(0.0001, maximum - range.lowerBound)
                return (value - range.lowerBound) / span
            }
            if value <= 1 { return value / 2 }
            return 0.5 + log(value) / log(maximum) / 2
        }
    }
}

/// The horizontal fader, and the panel's one expressive element: the track
/// doubles as the level meter.
///
/// When a `level` is supplied (only applications Mikser is processing have one),
/// the fill up to the knob is drawn dim and lights up as far as the signal
/// reaches, so a playing application visibly pulses. Past 100% the fill turns
/// amber to mark boosted gain.
struct Fader: View {
    let value: Double
    let range: ClosedRange<Double>
    var isDisabled = false
    var taper: SliderTaper = .linear
    /// Post-gain peak level, 0-1. nil when there is nothing to meter.
    var level: Float?
    /// Where the fill starts. A balance control fills out from its centre.
    var origin: Double?
    var accessibilityLabel = "Volume"
    var accessibilityValue: String?
    let onChange: (Double) -> Void
    var onEditingChanged: ((Bool) -> Void)?

    @State private var isDragging = false

    private let knobSize: CGFloat = 15
    private let trackHeight: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let usableWidth = max(1, proxy.size.width - knobSize)
            let x = { (position: Double) -> CGFloat in
                knobSize / 2 + usableWidth * CGFloat(min(1, max(0, position)))
            }
            let knobX = x(taper.position(forValue: value, in: range))
            // A fill from the bottom of the range starts flush with the track's end.
            let originX = origin.map { x(taper.position(forValue: $0, in: range)) } ?? 0
            let unityX = range.upperBound > 1 && origin == nil
                ? x(taper.position(forValue: 1, in: range)) : .infinity
            let midY = proxy.size.height / 2

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Theme.track)
                    .frame(height: trackHeight)
                    .position(x: proxy.size.width / 2, y: midY)
                    .frame(width: proxy.size.width)

                fill(from: originX, to: knobX, unityX: unityX, midY: midY)
                    .opacity(level == nil ? 1 : 0.38)

                if let level, level > 0.001 {
                    let levelX = min(knobX, x(taper.position(forValue: Double(level), in: range)))
                    fill(from: originX, to: levelX, unityX: unityX, midY: midY)
                        .animation(.linear(duration: 0.08), value: levelX)
                }

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: .black.opacity(isDragging ? 0.35 : 0.25), radius: isDragging ? 3 : 1.5, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .scaleEffect(isDragging ? 1.1 : 1)
                    .animation(.easeOut(duration: 0.12), value: isDragging)
                    .position(x: knobX, y: midY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard !isDisabled else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        let position = (gesture.location.x - knobSize / 2) / usableWidth
                        let clamped = Double(min(1, max(0, position)))
                        onChange(taper.value(atPosition: clamped, in: range))
                    }
                    .onEnded { _ in
                        guard !isDisabled else { return }
                        isDragging = false
                        onEditingChanged?(false)
                    }
            )
        }
        .frame(height: 22)
        .opacity(isDisabled ? 0.4 : 1)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard !isDisabled else { return }
            // Stepping in position space keeps the increments even under a taper.
            let current = taper.position(forValue: value, in: range)
            let step = 0.05
            switch direction {
            case .increment: onChange(taper.value(atPosition: min(1, current + step), in: range))
            case .decrement: onChange(taper.value(atPosition: max(0, current - step), in: range))
            @unknown default: break
            }
        }
    }

    /// The filled span of the track, accent up to unity and amber beyond it.
    @ViewBuilder
    private func fill(from start: CGFloat, to end: CGFloat, unityX: CGFloat, midY: CGFloat) -> some View {
        let low = min(start, end), high = max(start, end)
        let accentEnd = min(high, unityX)
        ZStack(alignment: .topLeading) {
            if accentEnd > low {
                segment(from: low, to: accentEnd, midY: midY, color: Theme.accent)
            }
            if high > unityX {
                segment(from: unityX, to: high, midY: midY, color: Theme.boost)
            }
        }
    }

    private func segment(from start: CGFloat, to end: CGFloat, midY: CGFloat, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: max(trackHeight, end - start), height: trackHeight)
            .position(x: (start + end) / 2, y: midY)
    }
}

// MARK: - Row controls

/// Lets gain go past 100%. Amber when on, matching the boosted part of the fader.
struct BoostButton: View {
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.up.2")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isOn ? Color.black.opacity(0.75) : Color.secondary)
                .frame(width: Layout.boostWidth, height: Layout.boostWidth)
                .background(
                    Circle().fill(isOn ? Theme.boost : (isHovering ? Theme.controlFill : .clear))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isOn ? "Boost is on: volume goes up to 500%" : "Boost: let the volume go up to 500%")
        .accessibilityLabel("Boost")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Opens and closes a row's detail panel or a section.
struct DisclosureChevron: View {
    let isExpanded: Bool
    var size: CGFloat = Layout.chevronWidth
    var help: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isExpanded ? .primary : .secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(isExpanded || isHovering ? Theme.controlFill : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help ?? (isExpanded ? "Hide details" : "Show details"))
        .accessibilityLabel(isExpanded ? "Hide details" : "Show details")
    }
}

struct MuteButton: View {
    let isMuted: Bool
    var symbol: String = "speaker.wave.2.fill"
    var mutedSymbol: String = "speaker.slash.fill"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? mutedSymbol : symbol)
                .font(.system(size: 13))
                .foregroundStyle(isMuted ? Theme.muted : .secondary)
                .frame(width: Layout.muteWidth, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute" : "Mute")
        .accessibilityLabel(isMuted ? "Unmute" : "Mute")
    }
}

/// The small line under a row's name that shows, and changes, where its sound
/// goes.
struct RouteMenu: View {
    let title: String
    var symbol: String?
    /// Accent colour when the row is sent somewhere other than the default.
    var isHighlighted = false
    let accessibilityLabel: String
    let entries: () -> [MenuEntry]

    var body: some View {
        PopUpMenu(accessibilityLabel: accessibilityLabel, help: "Choose where the sound plays", entries: entries) { hover in
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(hover ? 1 : 0.6)
            }
            .font(Typography.rowDetail)
            .foregroundStyle(isHighlighted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hover ? Theme.controlFill : .clear)
            )
            .padding(.horizontal, -5)
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// A compact pill used for choices inside detail panels.
struct PillMenu: View {
    let title: String
    let accessibilityLabel: String
    let entries: () -> [MenuEntry]

    var body: some View {
        PopUpMenu(accessibilityLabel: accessibilityLabel, entries: entries) { hover in
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover ? Theme.controlFillHover : Theme.controlFill)
            )
            .fixedSize()
        }
    }
}

/// A round icon button with a quiet hover state.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            icon(symbol, hover: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The look of `IconButton`, shared with icon-sized pop-up menus.
func icon(_ symbol: String, hover: Bool) -> some View {
    Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 26, height: 26)
        .background(Circle().fill(hover ? Theme.controlFill : .clear))
        .contentShape(Circle())
}

// MARK: - Surfaces

/// Hover highlight and padding shared by every row.
struct RowBackground: ViewModifier {
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Layout.rowHorizontalPadding)
            .padding(.vertical, Layout.rowVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Theme.rowHighlight : .clear)
            )
            .padding(.horizontal, 4)
    }
}

extension View {
    func rowBackground(isHovering: Bool) -> some View {
        modifier(RowBackground(isHovering: isHovering))
    }

    /// The rounded group that holds a section's rows.
    func groupSurface() -> some View {
        padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Layout.groupRadius, style: .continuous)
                    .fill(Theme.groupFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.groupRadius, style: .continuous)
                    .strokeBorder(Theme.groupStroke, lineWidth: 0.5)
            )
    }
}

/// The panel a row's chevron opens, set in under the row.
struct DetailPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
            .padding(.leading, 4 + Layout.rowHorizontalPadding + Layout.iconSize + Layout.columnSpacing)
            .padding(.trailing, 4 + Layout.rowHorizontalPadding)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// A labelled line inside a detail panel.
struct DetailRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Typography.detailLabel)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            content
        }
    }
}

/// The panel background: the system popover material in the menu bar, a solid
/// stand-in where there is nothing behind the window to blur.
struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
