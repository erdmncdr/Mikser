//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate
import CoreAudio
import Foundation
import Synchronization

/// The bridge between the realtime audio thread and the interface.
///
/// The IOProc block runs on a realtime-priority thread: it must not take locks,
/// allocate memory, or call into Objective-C. Everything is therefore exchanged
/// through lock-free atomics.
final class TapParameters: @unchecked Sendable {
    private let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let balanceBits = Atomic<UInt32>(Float(0).bitPattern)
    private let mutedFlag = Atomic<Bool>(false)
    private let peakBits = Atomic<UInt32>(Float(0).bitPattern)

    /// Ten-band equalizer whose coefficients are computed on the interface thread
    /// and published lock-free.
    let equalizer = EqualizerCore()

    var gain: Float {
        get { Float(bitPattern: gainBits.load(ordering: .relaxed)) }
        set { gainBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// -1 is hard left, 0 centre, +1 hard right.
    var balance: Float {
        get { Float(bitPattern: balanceBits.load(ordering: .relaxed)) }
        set { balanceBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    var isMuted: Bool {
        get { mutedFlag.load(ordering: .relaxed) }
        set { mutedFlag.store(newValue, ordering: .relaxed) }
    }

    /// Highest peak seen since the last read. Reading resets it.
    func consumePeak() -> Float {
        Float(bitPattern: peakBits.exchange(Float(0).bitPattern, ordering: .relaxed))
    }

    @inline(__always)
    func reportPeak(_ value: Float) {
        var current = peakBits.load(ordering: .relaxed)
        while Float(bitPattern: current) < value {
            let (exchanged, original) = peakBits.compareExchange(
                expected: current, desired: value.bitPattern, ordering: .relaxed
            )
            if exchanged { return }
            current = original
        }
    }
}

/// Captures one application's audio and plays it back under our own gain.
///
/// The chain: the application's output → a process tap (its path to the hardware is
/// muted) → a private aggregate device (tap input plus the target output device) →
/// an IOProc → the speakers.
final class AppTap {
    static let aggregateUIDPrefix = "io.github.erdmncdr.mikser.agg."

    let appID: String
    let displayName: String
    let parameters = TapParameters()

    private(set) var isRunning = false
    private(set) var processObjectIDs: [AudioObjectID] = []
    private(set) var outputDeviceUID: String?

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    init(appID: String, displayName: String) {
        self.appID = appID
        self.displayName = displayName
    }

    deinit { stop() }

    /// The audio format the tap advertises — for diagnostics.
    var tapFormat: AudioStreamBasicDescription? {
        guard tapID.isValid else { return nil }
        return tapID.readOptional(kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self)
    }

    /// The rate the IOProc actually runs at. It can differ from the tap format's.
    var deviceSampleRate: Double? {
        guard aggregateID.isValid else { return nil }
        return AudioDevices.sampleRate(of: aggregateID)
    }

    func start(processObjectIDs: [AudioObjectID], outputDeviceUID: String) throws {
        stop()
        guard !processObjectIDs.isEmpty else { return }

        // 1) Create a tap that mixes all of the application's processes down to stereo.
        //    .mutedWhenTapped: while we are reading the tap the application's audio
        //    does not reach the hardware, so it is not heard twice.
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        let tapUUID = UUID()
        description.name = "Mikser · \(displayName)"
        description.uuid = tapUUID
        description.isPrivate = true
        description.isExclusive = false
        description.muteBehavior = .mutedWhenTapped

        var createdTapID = AudioObjectID.unknown
        try caTry("AudioHardwareCreateProcessTap") {
            AudioHardwareCreateProcessTap(description, &createdTapID)
        }
        tapID = createdTapID

        // 2) Combine the tap input and the target output device into one private
        //    aggregate device.
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mikser · \(displayName)",
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + tapUUID.uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var createdAggregateID = AudioObjectID.unknown
        try caTry("AudioHardwareCreateAggregateDevice") {
            AudioHardwareCreateAggregateDevice(settings as CFDictionary, &createdAggregateID)
        }
        aggregateID = createdAggregateID

        // Equalizer coefficients must be computed for the **aggregate device's** rate.
        // The IOProc runs at that rate, and it can differ from the format the tap
        // advertises (AirPods drop to 24 kHz while the tap still reports 48 kHz).
        // The wrong rate shifts the filters: missing the band centre turned a
        // requested +12 dB into roughly +4 dB.
        if let rate = AudioDevices.sampleRate(of: aggregateID) {
            parameters.equalizer.setSampleRate(rate)
        }
        parameters.equalizer.resetState()

        // 3) The IOProc reads the tap, applies gain, and writes to the output.
        //    A nil queue means the block runs directly on the realtime thread.
        let parameters = self.parameters
        var createdIOProcID: AudioDeviceIOProcID?
        try caTry("AudioDeviceCreateIOProcIDWithBlock") {
            AudioDeviceCreateIOProcIDWithBlock(&createdIOProcID, aggregateID, nil) {
                _, inputData, _, outputData, _ in
                AppTap.render(input: inputData, output: outputData, parameters: parameters)
            }
        }
        guard let createdIOProcID else {
            throw CoreAudioError(operation: "AudioDeviceCreateIOProcIDWithBlock",
                                 status: kAudioHardwareUnspecifiedError)
        }
        ioProcID = createdIOProcID

        try caTry("AudioDeviceStart") { AudioDeviceStart(aggregateID, createdIOProcID) }

        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        isRunning = true
    }

    func stop() {
        if let ioProcID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }

        isRunning = false
        processObjectIDs = []
        outputDeviceUID = nil
    }

    // MARK: - Realtime processing

    private struct InputChannel {
        let samples: UnsafePointer<Float>
        let frameCount: Int
        let stride: Int
    }

    private struct OutputChannel {
        let samples: UnsafeMutablePointer<Float>
        let frameCount: Int
        let stride: Int
    }

    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        parameters: TapParameters
    ) {
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)

        // An IOProc owns every byte in the output list. Clear it up front so devices
        // with more than two channels never receive stale data in channels we do not use.
        for buffer in outputList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        let gain = parameters.isMuted ? 0 : parameters.gain
        guard gain != 0,
              let inputLeft = inputChannel(0, in: inputList),
              let outputLeft = outputChannel(0, in: outputList) else {
            parameters.reportPeak(0)
            return
        }

        let balance = parameters.balance
        let equalizer = parameters.equalizer
        let equalizerActive = equalizer.isEnabled
        // Move coefficients toward their target — once per block, before the channels.
        if equalizerActive { equalizer.prepareBlock() }

        // Balance only attenuates the opposite channel; centred, both pass untouched.
        let leftGain = gain * (balance > 0 ? 1 - balance : 1)
        let rightGain = gain * (balance < 0 ? 1 + balance : 1)

        let inputRight = inputChannel(1, in: inputList) ?? inputLeft
        let shouldLimit = gain > 1 || equalizerActive
        var peak: Float

        if let outputRight = outputChannel(1, in: outputList) {
            peak = process(
                input: inputLeft, output: outputLeft, gain: leftGain,
                equalizer: equalizer, equalizerActive: equalizerActive,
                shouldLimit: shouldLimit, channel: 0
            )
            peak = max(peak, process(
                input: inputRight, output: outputRight, gain: rightGain,
                equalizer: equalizer, equalizerActive: equalizerActive,
                shouldLimit: shouldLimit, channel: 1
            ))
        } else {
            // A mono destination receives an arithmetic average of left and right.
            peak = mixToMono(
                left: inputLeft, right: inputRight, output: outputLeft,
                leftGain: leftGain * 0.5, rightGain: rightGain * 0.5,
                equalizer: equalizer, equalizerActive: equalizerActive,
                shouldLimit: shouldLimit
            )
        }

        parameters.reportPeak(peak)
    }

    /// Finds a logical channel regardless of whether the AudioBufferList is interleaved,
    /// deinterleaved, or split across several multichannel buffers.
    private static func inputChannel(
        _ channel: Int, in buffers: UnsafeMutableAudioBufferListPointer
    ) -> InputChannel? {
        var firstChannel = 0
        for buffer in buffers {
            let channelCount = Int(buffer.mNumberChannels)
            guard channelCount > 0 else { continue }
            defer { firstChannel += channelCount }

            guard channel >= firstChannel, channel < firstChannel + channelCount,
                  let data = buffer.mData else { continue }
            let localChannel = channel - firstChannel
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            return InputChannel(
                samples: UnsafePointer(data.assumingMemoryBound(to: Float.self) + localChannel),
                frameCount: sampleCount / channelCount,
                stride: channelCount
            )
        }
        return nil
    }

    private static func outputChannel(
        _ channel: Int, in buffers: UnsafeMutableAudioBufferListPointer
    ) -> OutputChannel? {
        var firstChannel = 0
        for buffer in buffers {
            let channelCount = Int(buffer.mNumberChannels)
            guard channelCount > 0 else { continue }
            defer { firstChannel += channelCount }

            guard channel >= firstChannel, channel < firstChannel + channelCount,
                  let data = buffer.mData else { continue }
            let localChannel = channel - firstChannel
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            return OutputChannel(
                samples: data.assumingMemoryBound(to: Float.self) + localChannel,
                frameCount: sampleCount / channelCount,
                stride: channelCount
            )
        }
        return nil
    }

    private static func process(
        input: InputChannel, output: OutputChannel, gain: Float,
        equalizer: EqualizerCore, equalizerActive: Bool,
        shouldLimit: Bool, channel: Int
    ) -> Float {
        let frames = min(input.frameCount, output.frameCount)
        guard frames > 0 else { return 0 }

        var scale = gain
        vDSP_vsmul(
            input.samples, vDSP_Stride(input.stride), &scale,
            output.samples, vDSP_Stride(output.stride), vDSP_Length(frames)
        )
        if equalizerActive {
            equalizer.process(
                output.samples, frames: frames,
                sampleStride: output.stride, channel: channel
            )
        }
        if shouldLimit {
            softClip(output.samples, frames: frames, stride: output.stride)
        }

        var peak: Float = 0
        vDSP_maxmgv(
            output.samples, vDSP_Stride(output.stride), &peak, vDSP_Length(frames)
        )
        return peak
    }

    private static func mixToMono(
        left: InputChannel, right: InputChannel, output: OutputChannel,
        leftGain: Float, rightGain: Float,
        equalizer: EqualizerCore, equalizerActive: Bool, shouldLimit: Bool
    ) -> Float {
        let frames = min(min(left.frameCount, right.frameCount), output.frameCount)
        guard frames > 0 else { return 0 }

        var leftScale = leftGain
        var rightScale = rightGain
        vDSP_vsmul(
            left.samples, vDSP_Stride(left.stride), &leftScale,
            output.samples, vDSP_Stride(output.stride), vDSP_Length(frames)
        )
        vDSP_vsma(
            right.samples, vDSP_Stride(right.stride), &rightScale,
            output.samples, vDSP_Stride(output.stride),
            output.samples, vDSP_Stride(output.stride), vDSP_Length(frames)
        )
        if equalizerActive {
            equalizer.process(
                output.samples, frames: frames,
                sampleStride: output.stride, channel: 0
            )
        }
        if shouldLimit {
            softClip(output.samples, frames: frames, stride: output.stride)
        }

        var peak: Float = 0
        vDSP_maxmgv(
            output.samples, vDSP_Stride(output.stride), &peak, vDSP_Length(frames)
        )
        return peak
    }

    /// A limiter that is continuous, and continuous in its first derivative, above the
    /// threshold. Everything at |x| <= t passes through untouched; above it the curve
    /// approaches 1 asymptotically.
    @inline(__always)
    private static func softClip(
        _ buffer: UnsafeMutablePointer<Float>, frames: Int, stride: Int
    ) {
        let threshold: Float = 0.7
        let range: Float = 1 - threshold
        var index = 0

        for _ in 0..<frames {
            let sample = buffer[index]
            let magnitude = abs(sample)
            if magnitude > threshold {
                let limited = threshold + range * tanhf((magnitude - threshold) / range)
                buffer[index] = sample < 0 ? -limited : limited
            }
            index += stride
        }
    }
}
