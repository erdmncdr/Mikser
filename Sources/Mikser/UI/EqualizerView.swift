//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A vertical fader. SwiftUI's Slider does not work vertically and rotating it
/// breaks the layout, so this is a custom control whose fill starts at 0 dB.
struct VerticalFader: View {
    let value: Float
    let range: ClosedRange<Float>
    let onChange: (Float) -> Void

    private let trackWidth: CGFloat = 4
    private let knobSize: CGFloat = 13

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let usable = max(1, height - knobSize)
            let span = range.upperBound - range.lowerBound
            let centerX = proxy.size.width / 2

            let knobY = height - knobSize / 2 - usable * CGFloat((value - range.lowerBound) / span)
            let zeroY = height - knobSize / 2 - usable * CGFloat((0 - range.lowerBound) / span)

            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: trackWidth, height: height)
                    .position(x: centerX, y: height / 2)

                Capsule()
                    .fill(Theme.accent)
                    .frame(width: trackWidth, height: abs(knobY - zeroY))
                    .position(x: centerX, y: (knobY + zeroY) / 2)

                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .frame(width: knobSize, height: knobSize)
                    .position(x: centerX, y: knobY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let clamped = min(max(knobSize / 2, gesture.location.y), height - knobSize / 2)
                        let fraction = 1 - (clamped - knobSize / 2) / usable
                        onChange(range.lowerBound + Float(fraction) * span)
                    }
            )
        }
    }
}

/// The ten-band equalizer inside the FX panel.
struct EqualizerView: View {
    let appID: String
    let settings: EqualizerSettings
    @Bindable var engine: MixerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlRow
            faderRow
        }
    }

    private var controlRow: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { settings.isEnabled },
                set: { engine.setEqualizerEnabled($0, for: appID) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            Text("10-Band Equalizer")
                .font(Typography.detailLabel)
                .foregroundStyle(settings.isEnabled ? .primary : .secondary)

            Spacer()

            Text("Preset")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("", selection: Binding<EqualizerPreset?>(
                get: { settings.preset },
                set: { if let preset = $0 { engine.applyEqualizerPreset(preset, for: appID) } }
            )) {
                // Nothing matches a preset once the user has moved bands by hand.
                if settings.preset == nil {
                    Text("Custom").tag(EqualizerPreset?.none)
                }
                ForEach(EqualizerPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(EqualizerPreset?.some(preset))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 140)

            Button {
                engine.applyEqualizerPreset(.flat, for: appID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.controlBackground))
            }
            .buttonStyle(.plain)
            .disabled(settings.isFlat)
            .help("Reset all bands")
        }
    }

    private var faderRow: some View {
        HStack(alignment: .top, spacing: 0) {
            scale

            ForEach(Array(EqualizerBands.frequencies.enumerated()), id: \.offset) { index, frequency in
                VStack(spacing: 5) {
                    Text(gainLabel(settings.gains[index]))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(
                            abs(settings.gains[index]) < 0.05 ? .tertiary : .secondary
                        )

                    VerticalFader(
                        value: settings.gains[index],
                        range: EqualizerBands.gainRange
                    ) { newValue in
                        engine.setEqualizerGain(newValue, band: index, for: appID)
                    }
                    .frame(height: 96)

                    Text(EqualizerBands.label(for: frequency))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .opacity(settings.isEnabled ? 1 : 0.45)
    }

    /// The dB ruler down the left edge. It starts with the same gap as the gain
    /// label above each fader so the two line up.
    private var scale: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Color.clear.frame(height: 16)
            VStack(alignment: .trailing) {
                Text("+12").frame(maxHeight: .infinity, alignment: .top)
                Text("0").frame(maxHeight: .infinity, alignment: .center)
                Text("−12").frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 96)
        }
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(.tertiary)
        .padding(.trailing, 8)
    }

    private func gainLabel(_ gain: Float) -> String {
        let rounded = (gain * 10).rounded() / 10
        if abs(rounded) < 0.05 { return "0" }
        return String(format: "%+.0f", rounded)
    }
}
