//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Synchronization

/// Ten-band parametric equalizer.
///
/// Coefficients are computed on the interface thread and published lock-free; the
/// realtime thread only reads. Each band is the peaking EQ biquad from the RBJ
/// cookbook, run as Transposed Direct Form II.
enum EqualizerBands {
    /// The standard ten bands, one octave apart.
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static var count: Int { frequencies.count }

    /// Q suited to one-octave width. Higher values leave dips between the bands.
    static let q: Float = 1.414

    static let gainRange: ClosedRange<Float> = -12...12

    static func label(for frequency: Float) -> String {
        frequency >= 1000
            ? "\(Int(frequency / 1000))k"
            : "\(Int(frequency))"
    }
}

enum EqualizerPreset: String, CaseIterable, Codable {
    case flat, bass, treble, vocal, podcast, night, rock, electronic

    var displayName: String {
        switch self {
        case .flat:       "Düz"
        case .bass:       "Bas Yükselt"
        case .treble:     "Tiz Yükselt"
        case .vocal:      "Vokal"
        case .podcast:    "Konuşma"
        case .night:      "Gece Modu"
        case .rock:       "Rock"
        case .electronic: "Elektronik"
        }
    }

    //                       32  64 125 250 500  1k  2k  4k  8k 16k
    var gains: [Float] {
        switch self {
        case .flat:       [ 0,  0,  0,  0,  0,  0,  0,  0,  0,  0]
        case .bass:       [ 6,  5,  4,  2,  0,  0,  0,  0,  0,  0]
        case .treble:     [ 0,  0,  0,  0,  0,  0,  2,  4,  5,  6]
        case .vocal:      [-2, -2, -1,  1,  3,  4,  3,  2,  0, -1]
        case .podcast:    [-4, -3, -1,  2,  3,  3,  2,  1,  0, -2]
        // Compensates for the extremes the ear loses at low listening levels.
        case .night:      [ 5,  4,  2,  0, -1, -1,  0,  2,  4,  5]
        case .rock:       [ 5,  4,  2,  0, -1,  0,  2,  3,  4,  4]
        case .electronic: [ 6,  5,  2,  0, -2,  1,  1,  2,  4,  5]
        }
    }

    /// The preset that matches the given gains exactly, if there is one.
    static func matching(_ gains: [Float]) -> EqualizerPreset? {
        allCases.first { preset in
            zip(preset.gains, gains).allSatisfy { abs($0 - $1) < 0.05 }
        }
    }
}

private struct BiquadCoefficients {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var isIdentity: Bool = true

    static let identity = BiquadCoefficients()

    mutating func approach(_ target: BiquadCoefficients, amount: Float) {
        b0 += (target.b0 - b0) * amount
        b1 += (target.b1 - b1) * amount
        b2 += (target.b2 - b2) * amount
        a1 += (target.a1 - a1) * amount
        a2 += (target.a2 - a2) * amount

        // Only start skipping the band once it has fully settled on the target.
        isIdentity = abs(b0 - 1) < 1e-5 && abs(b1) < 1e-5 && abs(b2) < 1e-5
            && abs(a1) < 1e-5 && abs(a2) < 1e-5
    }
}

final class EqualizerCore: @unchecked Sendable {

    private static let channelCount = 2
    /// Number of coefficient slots. The interface only writes to a slot that is
    /// neither published nor being read by the realtime thread.
    private static let slotCount = 4

    /// Target coefficients written by the interface (slot × band).
    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    /// The coefficients the realtime thread uses, easing toward the target.
    private let currentCoefficients: UnsafeMutablePointer<BiquadCoefficients>
    /// Filter state belongs to the realtime thread alone: channel × band × 2.
    private let state: UnsafeMutablePointer<Float>

    /// Realtime-thread owned: jump straight to the target on the first block, ease after.
    private var hasSettled = false

    private let publishedSlot = Atomic<Int>(0)
    private let enabledFlag = Atomic<Bool>(false)
    // Atomic reader flags make the slot handoff race-free without ever blocking the
    // realtime thread. There is one IOProc consumer for each EqualizerCore instance.
    private let slot0IsBeingRead = Atomic<Bool>(false)
    private let slot1IsBeingRead = Atomic<Bool>(false)
    private let slot2IsBeingRead = Atomic<Bool>(false)
    private let slot3IsBeingRead = Atomic<Bool>(false)

    /// Touched only by the interface thread.
    private var nextSlot = 0
    private var gains = [Float](repeating: 0, count: EqualizerBands.count)
    private var sampleRate: Float = 48000

    init() {
        let bands = EqualizerBands.count
        coefficients = .allocate(capacity: Self.slotCount * bands)
        coefficients.initialize(repeating: .identity, count: Self.slotCount * bands)

        currentCoefficients = .allocate(capacity: bands)
        currentCoefficients.initialize(repeating: .identity, count: bands)

        state = .allocate(capacity: Self.channelCount * bands * 2)
        state.initialize(repeating: 0, count: Self.channelCount * bands * 2)
    }

    deinit {
        coefficients.deallocate()
        currentCoefficients.deallocate()
        state.deallocate()
    }

    // MARK: Interface side

    var isEnabled: Bool {
        get { enabledFlag.load(ordering: .relaxed) }
        set { enabledFlag.store(newValue, ordering: .relaxed) }
    }

    func update(gains newGains: [Float]) {
        gains = normalized(newGains)
        recompute()
    }

    func setSampleRate(_ rate: Double) {
        let value = Float(rate)
        guard value > 0, abs(value - sampleRate) > 1 else { return }
        sampleRate = value
        recompute()
    }

    private func normalized(_ input: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: EqualizerBands.count)
        for index in 0..<min(input.count, result.count) {
            result[index] = min(EqualizerBands.gainRange.upperBound,
                                max(EqualizerBands.gainRange.lowerBound, input[index]))
        }
        return result
    }

    private func recompute() {
        guard let writableSlot = nextWritableSlot() else { return }
        nextSlot = writableSlot
        let base = coefficients + writableSlot * EqualizerBands.count

        for band in 0..<EqualizerBands.count {
            base[band] = Self.peaking(
                frequency: EqualizerBands.frequencies[band],
                gainDB: gains[band],
                sampleRate: sampleRate
            )
        }
        publishedSlot.store(writableSlot, ordering: .releasing)
    }

    private func nextWritableSlot() -> Int? {
        let published = publishedSlot.load(ordering: .acquiring)
        for offset in 1...Self.slotCount {
            let candidate = (nextSlot + offset) % Self.slotCount
            if candidate != published && !slotIsBeingRead(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func slotIsBeingRead(_ slot: Int) -> Bool {
        switch slot {
        case 0: slot0IsBeingRead.load(ordering: .acquiring)
        case 1: slot1IsBeingRead.load(ordering: .acquiring)
        case 2: slot2IsBeingRead.load(ordering: .acquiring)
        default: slot3IsBeingRead.load(ordering: .acquiring)
        }
    }

    private func setSlotBeingRead(_ slot: Int, _ isBeingRead: Bool) {
        switch slot {
        case 0: slot0IsBeingRead.store(isBeingRead, ordering: .releasing)
        case 1: slot1IsBeingRead.store(isBeingRead, ordering: .releasing)
        case 2: slot2IsBeingRead.store(isBeingRead, ordering: .releasing)
        default: slot3IsBeingRead.store(isBeingRead, ordering: .releasing)
        }
    }

    /// RBJ Audio EQ Cookbook — peaking EQ.
    private static func peaking(frequency: Float, gainDB: Float, sampleRate: Float) -> BiquadCoefficients {
        // Flat band, or a frequency above Nyquist: skip the filter entirely.
        guard abs(gainDB) > 0.01, frequency > 0, frequency < sampleRate / 2 else {
            return .identity
        }

        let a = powf(10, gainDB / 40)
        let omega = 2 * Float.pi * frequency / sampleRate
        let cosOmega = cosf(omega)
        let alpha = sinf(omega) / (2 * EqualizerBands.q)

        let b0 = 1 + alpha * a
        let b1 = -2 * cosOmega
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosOmega
        let a2 = 1 - alpha / a

        return BiquadCoefficients(
            b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
            a1: a1 / a0, a2: a2 / a0,
            isIdentity: false
        )
    }

    // MARK: Realtime side

    /// Clears the filter history when the device stops or is rebuilt; otherwise old
    /// samples come back as a click.
    func resetState() {
        state.update(repeating: 0, count: Self.channelCount * EqualizerBands.count * 2)
        hasSettled = false
    }

    /// Called once at the start of every audio block.
    ///
    /// Eases the coefficients toward their target. Jumping straight to them upsets the
    /// filter state: while changing presets the measured peak briefly rose to ten times
    /// its steady value, which is an audible click. At 25% per block the transition
    /// covers most of the transition in about four blocks and then settles smoothly.
    func prepareBlock() {
        guard enabledFlag.load(ordering: .relaxed) else { return }

        let slot = publishedSlot.load(ordering: .acquiring)
        setSlotBeingRead(slot, true)
        // The publisher may have moved between the first load and the reader flag.
        // In that case the old slot can be under construction, so use the coefficients
        // from the previous block and try again on the next callback.
        guard publishedSlot.load(ordering: .acquiring) == slot else {
            setSlotBeingRead(slot, false)
            return
        }
        let target = coefficients + slot * EqualizerBands.count

        guard hasSettled else {
            currentCoefficients.update(from: target, count: EqualizerBands.count)
            hasSettled = true
            setSlotBeingRead(slot, false)
            return
        }
        for band in 0..<EqualizerBands.count {
            currentCoefficients[band].approach(target[band], amount: 0.25)
        }
        setSlotBeingRead(slot, false)
    }

    /// Processes a single channel in place. `sampleStride` is 2 for an interleaved
    /// layout and 1 when each channel has its own buffer.
    func process(
        _ samples: UnsafeMutablePointer<Float>, frames: Int, sampleStride: Int, channel: Int
    ) {
        guard enabledFlag.load(ordering: .relaxed), frames > 0 else { return }
        guard channel < Self.channelCount else { return }

        let channelState = state + channel * EqualizerBands.count * 2

        for band in 0..<EqualizerBands.count {
            let coefficient = currentCoefficients[band]
            if coefficient.isIdentity { continue }

            var z1 = channelState[band * 2]
            var z2 = channelState[band * 2 + 1]
            var index = 0

            for _ in 0..<frames {
                let input = samples[index]
                let output = coefficient.b0 * input + z1
                z1 = coefficient.b1 * input - coefficient.a1 * output + z2
                z2 = coefficient.b2 * input - coefficient.a2 * output
                samples[index] = output
                index += sampleStride
            }

            channelState[band * 2] = z1
            channelState[band * 2 + 1] = z2
        }
    }
}
