//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio
import Foundation

/// What the device is — this drives the symbol shown in the list.
enum DeviceKind {
    case builtIn, airPods, airPodsPro, airPodsMax, headphones
    case bluetooth, usb, display, airPlay, virtual, microphone, other

    var symbolName: String {
        switch self {
        case .builtIn:    "laptopcomputer"
        case .airPods:    "airpods"
        case .airPodsPro: "airpodspro"
        case .airPodsMax: "airpodsmax"
        case .headphones: "headphones"
        case .bluetooth:  "hifispeaker.fill"
        case .usb:        "hifispeaker.fill"
        case .display:    "display"
        case .airPlay:    "airplayaudio"
        case .virtual:    "waveform"
        case .microphone: "mic.fill"
        case .other:      "hifispeaker.fill"
        }
    }
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let outputChannels: Int
    let inputChannels: Int
    let kind: DeviceKind

    var symbolName: String { kind.symbolName }
}

enum AudioDevices {

    // MARK: Enumeration

    static func outputDevices() -> [AudioDevice] {
        allDevices().filter { $0.outputChannels > 0 }
    }

    static func inputDevices() -> [AudioDevice] {
        allDevices().filter { $0.inputChannels > 0 }
    }

    static func allDevices() -> [AudioDevice] {
        let ids = (try? AudioObjectID.system.readArray(
            kAudioHardwarePropertyDevices, of: AudioObjectID.self
        )) ?? []

        return ids.compactMap(device(for:))
            // The aggregate devices we create ourselves must not show up in the list.
            .filter { !$0.uid.hasPrefix(AppTap.aggregateUIDPrefix) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func device(for id: AudioObjectID) -> AudioDevice? {
        guard let uid = id.readStringOptional(kAudioDevicePropertyDeviceUID) else { return nil }
        let outputs = channelCount(of: id, scope: kAudioObjectPropertyScopeOutput)
        let inputs = channelCount(of: id, scope: kAudioObjectPropertyScopeInput)
        guard outputs > 0 || inputs > 0 else { return nil }

        let name = id.readStringOptional(kAudioObjectPropertyName) ?? uid
        return AudioDevice(
            id: id, uid: uid, name: name,
            outputChannels: outputs, inputChannels: inputs,
            kind: kind(of: id, name: name, hasOutput: outputs > 0)
        )
    }

    // MARK: Default devices

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDevice? {
        guard let id = try? AudioObjectID.system.read(selector, as: AudioObjectID.self),
              id.isValid else { return nil }
        return device(for: id)
    }

    static func setDefaultDevice(
        _ selector: AudioObjectPropertySelector, to deviceID: AudioObjectID
    ) throws {
        try AudioObjectID.system.write(selector, value: deviceID)
    }

    static func defaultOutputDevice() -> AudioDevice? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultInputDevice() -> AudioDevice? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    /// Where alerts and interface sounds play — selectable separately from normal output.
    static func defaultEffectsDevice() -> AudioDevice? {
        defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    // MARK: Device kind

    private static func kind(of deviceID: AudioObjectID, name: String, hasOutput: Bool) -> DeviceKind {
        let transport = deviceID.readOptional(
            kAudioDevicePropertyTransportType, as: UInt32.self
        ) ?? 0

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return hasOutput ? .builtIn : .microphone
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            // AirPods models have their own symbols; matching on the name is the only way.
            if name.localizedCaseInsensitiveContains("AirPods Max") { return .airPodsMax }
            if name.localizedCaseInsensitiveContains("AirPods Pro") { return .airPodsPro }
            if name.localizedCaseInsensitiveContains("AirPods") { return .airPods }
            if name.localizedCaseInsensitiveContains("Beats")
                || name.localizedCaseInsensitiveContains("Headphone") { return .headphones }
            return .bluetooth
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return .display
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return .virtual
        default:
            return hasOutput ? .other : .microphone
        }
    }

    // MARK: Volume

    /// Elements that support hardware volume. Some devices expose a single main
    /// element, others only offer per-channel volume.
    private static func volumeElements(
        of deviceID: AudioObjectID, scope: AudioObjectPropertyScope
    ) -> [AudioObjectPropertyElement] {
        if deviceID.hasProperty(kAudioDevicePropertyVolumeScalar,
                                scope: scope, element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        return [1, 2].filter {
            deviceID.hasProperty(kAudioDevicePropertyVolumeScalar, scope: scope, element: $0)
        }
    }

    /// nil when the device has no software volume — the UI disables the slider then.
    static func volume(
        of deviceID: AudioObjectID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Float? {
        let elements = volumeElements(of: deviceID, scope: scope)
        guard !elements.isEmpty else { return nil }

        let values = elements.compactMap {
            deviceID.readOptional(kAudioDevicePropertyVolumeScalar,
                                  scope: scope, element: $0, as: Float.self)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    static func setVolume(
        _ volume: Float, for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) {
        let clamped = max(0, min(1, volume))
        for element in volumeElements(of: deviceID, scope: scope) {
            guard deviceID.isSettable(kAudioDevicePropertyVolumeScalar,
                                      scope: scope, element: element) else { continue }
            try? deviceID.write(kAudioDevicePropertyVolumeScalar,
                                scope: scope, element: element, value: clamped)
        }
    }

    static func isMuted(
        _ deviceID: AudioObjectID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Bool {
        (deviceID.readOptional(kAudioDevicePropertyMute, scope: scope, as: UInt32.self) ?? 0) == 1
    }

    static func setMuted(
        _ muted: Bool, for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) {
        guard deviceID.isSettable(kAudioDevicePropertyMute, scope: scope) else { return }
        try? deviceID.write(kAudioDevicePropertyMute, scope: scope, value: UInt32(muted ? 1 : 0))
    }

    // MARK: Sample rate

    static func sampleRate(of deviceID: AudioObjectID) -> Double? {
        deviceID.readOptional(kAudioDevicePropertyNominalSampleRate, as: Double.self)
    }

    /// Rates the device supports. For devices reporting a continuous range only the
    /// endpoints are taken — listing every value in between is not meaningful.
    static func availableSampleRates(of deviceID: AudioObjectID) -> [Double] {
        let ranges = (try? deviceID.readArray(
            kAudioDevicePropertyAvailableNominalSampleRates, of: AudioValueRange.self
        )) ?? []

        var rates: Set<Double> = []
        for range in ranges {
            rates.insert(range.mMinimum)
            rates.insert(range.mMaximum)
        }
        return rates.sorted()
    }

    static func setSampleRate(_ rate: Double, for deviceID: AudioObjectID) {
        guard deviceID.isSettable(kAudioDevicePropertyNominalSampleRate) else { return }
        try? deviceID.write(kAudioDevicePropertyNominalSampleRate, value: rate)
    }

    // MARK: Channel count

    static func channelCount(
        of deviceID: AudioObjectID, scope: AudioObjectPropertyScope
    ) -> Int {
        var addr = AudioObjectID.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
