//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreAudio
import Foundation
import Observation

struct EqualizerSettings: Codable, Equatable {
    var isEnabled: Bool = false
    var gains: [Float] = Array(repeating: 0, count: EqualizerBands.count)

    var isFlat: Bool { gains.allSatisfy { abs($0) < 0.05 } }
    var preset: EqualizerPreset? { EqualizerPreset.matching(gains) }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false

        // Keep old records readable if the band count ever changes.
        let stored = try container.decodeIfPresent([Float].self, forKey: .gains) ?? []
        var normalized = [Float](repeating: 0, count: EqualizerBands.count)
        for index in 0..<min(stored.count, normalized.count) { normalized[index] = stored[index] }
        gains = normalized
    }
}

/// The settings the user has chosen for one application.
struct AppSettings: Codable, Equatable {
    var volume: Float = 1
    var isMuted: Bool = false
    /// While on, volume can go to 500%; otherwise it is capped at 100%.
    ///
    /// 500 rather than a lower ceiling because the soft limiter already bounds the
    /// output at full scale, so a lower cap protects nothing: on loud material the
    /// level is pinned long before 200% and further gain only adds distortion. The
    /// extra range only becomes usable on quiet sources, where it stays clean —
    /// a -20 dBFS recording measures 0% THD even at 500%.
    var isBoosted: Bool = false
    /// -1 is hard left, 0 centre, +1 hard right.
    var balance: Float = 0
    var equalizer = EqualizerSettings()
    /// nil means the system default output is used.
    var outputDeviceUID: String?

    var maximumVolume: Float { isBoosted ? 5 : 1 }

    init() {}

    /// Fields missing from older records fall back to their defaults, so the settings
    /// file does not become undecodable when a new field is added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isBoosted = try container.decodeIfPresent(Bool.self, forKey: .isBoosted) ?? false
        balance = try container.decodeIfPresent(Float.self, forKey: .balance) ?? 0
        equalizer = try container.decodeIfPresent(EqualizerSettings.self, forKey: .equalizer)
            ?? EqualizerSettings()
        outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
    }
}

struct HiddenApplication: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
@Observable
final class MixerEngine {

    // MARK: Published state

    private(set) var apps: [AudioApp] = []
    private(set) var outputDevices: [AudioDevice] = []
    private(set) var inputDevices: [AudioDevice] = []
    private(set) var levels: [String: Float] = [:]
    private(set) var lastError: String?

    private(set) var defaultOutputDevice: AudioDevice?
    private(set) var defaultInputDevice: AudioDevice?
    private(set) var effectsDevice: AudioDevice?

    /// nil when the device has no software volume; the UI disables the slider then.
    private(set) var systemVolume: Float?
    private(set) var systemMuted: Bool = false
    private(set) var inputVolume: Float?
    private(set) var inputMuted: Bool = false
    private(set) var effectsVolume: Float?

    /// Only applications the user has touched appear here. With no record, no tap is
    /// created for that application at all — zero latency, zero CPU.
    private(set) var settings: [String: AppSettings] = [:]
    private(set) var favorites: Set<String> = []
    private(set) var hiddenApps: Set<String> = []

    var visibleApps: [AudioApp] {
        apps.filter { !hiddenApps.contains($0.id) }
    }

    var hiddenApplications: [HiddenApplication] {
        hiddenApps.map { appID in
            let name = apps.first(where: { $0.id == appID })?.name
                ?? AudioProcessMonitor.appInfo(forBundleID: appID)?.name
                ?? appID
            return HiddenApplication(id: appID, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Internals

    private var taps: [String: AppTap] = [:]
    private var listeners: [ListenerToken] = []
    private var timer: Timer?
    private var tickCount = 0
    private var isMenuOpen = false
    private var isPreview = false

    private let settingsKey = "io.github.erdmncdr.mikser.settings"
    private let favoritesKey = "io.github.erdmncdr.mikser.favorites"
    private let hiddenAppsKey = "io.github.erdmncdr.mikser.hiddenApps"

    // MARK: Lifecycle

    static let shared = MixerEngine()

    init(preview: Bool = false) {
        if preview {
            isPreview = true
            loadPreviewData()
            return
        }
        loadPersisted()
        refreshDevices()
        refreshApps()
        installListeners()
        restartTimer()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        listeners.removeAll()
        for tap in taps.values { tap.stop() }
        taps.removeAll()
    }

    func setMenuOpen(_ open: Bool) {
        guard !isPreview else { return }
        guard isMenuOpen != open else { return }
        isMenuOpen = open
        if open {
            refreshDevices()
            refreshApps()
        }
        restartTimer()
    }

    /// Deterministic, anonymous data for screenshots and visual regression checks.
    /// It deliberately avoids touching Core Audio, UserDefaults, or process lists.
    private func loadPreviewData() {
        let speakers = AudioDevice(
            id: 100, uid: "preview.studio-speakers", name: "MacBook Pro Speakers",
            outputChannels: 2, inputChannels: 0, kind: .other
        )
        let headphones = AudioDevice(
            id: 101, uid: "preview.headphones", name: "Studio Headphones",
            outputChannels: 2, inputChannels: 0, kind: .headphones
        )
        let microphone = AudioDevice(
            id: 102, uid: "preview.microphone", name: "MacBook Pro Microphone",
            outputChannels: 0, inputChannels: 1, kind: .microphone
        )

        outputDevices = [speakers, headphones]
        inputDevices = [microphone]
        defaultOutputDevice = speakers
        defaultInputDevice = microphone
        effectsDevice = speakers
        systemVolume = 0.82
        inputVolume = 0.64
        effectsVolume = 1

        let examples: [(id: String, name: String, symbol: String, favorite: Bool)] = [
            ("preview.music", "Music", "music.note", true),
            ("preview.browser", "Browser", "globe", false),
            ("preview.messages", "Messages", "message.fill", false)
        ]
        apps = examples.enumerated().map { index, item in
            AudioApp(
                id: item.id,
                name: item.name,
                icon: NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.name),
                processObjectIDs: [AudioObjectID(200 + index)],
                isPlaying: true,
                isFavorite: item.favorite
            )
        }
        favorites = Set(examples.filter(\.favorite).map(\.id))
        levels = ["preview.music": 0.74, "preview.browser": 0.42, "preview.messages": 0.18]

        var music = AppSettings()
        music.volume = 0.78
        settings["preview.music"] = music
        settings["preview.browser"] = AppSettings()
        settings["preview.messages"] = AppSettings()
    }

    // MARK: Application settings

    func settings(for appID: String) -> AppSettings {
        settings[appID] ?? AppSettings()
    }

    func isControlled(_ appID: String) -> Bool {
        settings[appID] != nil
    }

    func setVolume(_ volume: Float, for appID: String) {
        var current = settings(for: appID)
        current.volume = max(0, min(current.maximumVolume, volume))
        apply(current, to: appID)
    }

    func setMuted(_ muted: Bool, for appID: String) {
        var current = settings(for: appID)
        current.isMuted = muted
        apply(current, to: appID)
    }

    func setBoosted(_ boosted: Bool, for appID: String) {
        var current = settings(for: appID)
        current.isBoosted = boosted
        // Turning boost off pulls a volume left above 100% back down to the cap.
        if !boosted { current.volume = min(current.volume, 1) }
        apply(current, to: appID)
    }

    func setBalance(_ balance: Float, for appID: String) {
        var current = settings(for: appID)
        current.balance = max(-1, min(1, balance))
        apply(current, to: appID)
    }

    func setOutputDevice(_ uid: String?, for appID: String) {
        var current = settings(for: appID)
        current.outputDeviceUID = uid
        apply(current, to: appID)
    }

    // MARK: Equalizer

    func setEqualizerEnabled(_ enabled: Bool, for appID: String) {
        var current = settings(for: appID)
        current.equalizer.isEnabled = enabled
        apply(current, to: appID)
    }

    func setEqualizerGain(_ gain: Float, band: Int, for appID: String) {
        guard band >= 0, band < EqualizerBands.count else { return }
        var current = settings(for: appID)
        current.equalizer.gains[band] = max(
            EqualizerBands.gainRange.lowerBound,
            min(EqualizerBands.gainRange.upperBound, gain)
        )
        // Moving a band by hand switches the equalizer on, so nothing stays silent
        // while the user is expecting a change.
        current.equalizer.isEnabled = true
        apply(current, to: appID)
    }

    func applyEqualizerPreset(_ preset: EqualizerPreset, for appID: String) {
        var current = settings(for: appID)
        current.equalizer.gains = preset.gains
        current.equalizer.isEnabled = preset != .flat
        apply(current, to: appID)
    }

    /// Releases the application: the tap closes and its audio goes straight to the
    /// hardware again.
    func reset(_ appID: String) {
        settings[appID] = nil
        levels[appID] = nil
        taps[appID]?.stop()
        taps[appID] = nil
        savePersisted()
        refreshApps()
    }

    /// Releases every controlled application, including settings for applications
    /// that are currently closed and therefore absent from the visible list.
    func resetAll() {
        for tap in taps.values { tap.stop() }
        taps.removeAll()
        settings.removeAll()
        hiddenApps.removeAll()
        levels.removeAll()
        lastError = nil
        savePersisted()
        refreshApps()
    }

    private func apply(_ newSettings: AppSettings, to appID: String) {
        settings[appID] = newSettings
        savePersisted()

        // If a tap is already running, update its parameters immediately.
        if let tap = taps[appID] {
            tap.parameters.gain = newSettings.volume
            tap.parameters.isMuted = newSettings.isMuted
            tap.parameters.balance = newSettings.balance
            tap.parameters.equalizer.update(gains: newSettings.equalizer.gains)
            tap.parameters.equalizer.isEnabled = newSettings.equalizer.isEnabled
        }
        syncTaps()
    }

    // MARK: Favourites

    func isFavorite(_ appID: String) -> Bool { favorites.contains(appID) }

    func toggleFavorite(_ appID: String) {
        if favorites.contains(appID) {
            favorites.remove(appID)
        } else {
            favorites.insert(appID)
            hiddenApps.remove(appID)
        }
        savePersisted()
        refreshApps()
    }

    func addFavorite(bundleID: String) {
        favorites.insert(bundleID)
        hiddenApps.remove(bundleID)
        savePersisted()
        refreshApps()
    }

    // MARK: Visibility

    /// Hiding only removes the row from the panel. Existing routing and audio
    /// settings keep working until the application is explicitly reset.
    func hideApplication(_ appID: String) {
        hiddenApps.insert(appID)
        if !isPreview { savePersisted() }
    }

    func showApplication(_ appID: String) {
        hiddenApps.remove(appID)
        if !isPreview {
            savePersisted()
            refreshApps()
        }
    }

    func showAllApplications() {
        hiddenApps.removeAll()
        if !isPreview {
            savePersisted()
            refreshApps()
        }
    }

    // MARK: System output, input and effects

    func setSystemVolume(_ volume: Float) {
        guard let device = defaultOutputDevice else { return }
        AudioDevices.setVolume(volume, for: device.id)
        systemVolume = volume
    }

    func setSystemMuted(_ muted: Bool) {
        guard let device = defaultOutputDevice else { return }
        AudioDevices.setMuted(muted, for: device.id)
        systemMuted = muted
    }

    func setInputVolume(_ volume: Float) {
        guard let device = defaultInputDevice else { return }
        AudioDevices.setVolume(volume, for: device.id, scope: kAudioObjectPropertyScopeInput)
        inputVolume = volume
    }

    func setInputMuted(_ muted: Bool) {
        guard let device = defaultInputDevice else { return }
        AudioDevices.setMuted(muted, for: device.id, scope: kAudioObjectPropertyScopeInput)
        inputMuted = muted
    }

    /// The UI tracks the value locally while dragging and calls this on release —
    /// alert volume is written through AppleScript and cannot be set every frame.
    func setEffectsVolume(_ volume: Float) {
        SystemAudio.setAlertVolume(volume)
        effectsVolume = volume
    }

    func setSystemOutputDevice(_ device: AudioDevice) {
        setDefault(kAudioHardwarePropertyDefaultOutputDevice, device)
        syncTaps()
    }

    func setSystemInputDevice(_ device: AudioDevice) {
        setDefault(kAudioHardwarePropertyDefaultInputDevice, device)
    }

    func setEffectsDevice(_ device: AudioDevice) {
        setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, device)
    }

    private func setDefault(_ selector: AudioObjectPropertySelector, _ device: AudioDevice) {
        do {
            try AudioDevices.setDefaultDevice(selector, to: device.id)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshDevices()
    }

    // MARK: Sample rate

    func sampleRate(of device: AudioDevice?) -> Double? {
        device.flatMap { AudioDevices.sampleRate(of: $0.id) }
    }

    func availableSampleRates(of device: AudioDevice?) -> [Double] {
        device.map { AudioDevices.availableSampleRates(of: $0.id) } ?? []
    }

    func setSampleRate(_ rate: Double, for device: AudioDevice) {
        AudioDevices.setSampleRate(rate, for: device.id)
    }

    // MARK: Refresh

    private func restartTimer() {
        timer?.invalidate()
        // Fast while the menu is open, for the level meters; frugal when closed.
        let interval: TimeInterval = isMenuOpen ? 0.1 : 2.0
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common is required: with the panel open the run loop switches to
        // .eventTracking, and a .default-mode timer stops, freezing the meters
        // exactly while they are being watched.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func tick() {
        tickCount += 1
        refreshLevels()

        // The application list changes far more slowly than the level meters.
        let appRefreshEvery = isMenuOpen ? 10 : 1
        if tickCount % appRefreshEvery == 0 {
            refreshApps()
            refreshVolumes()
        }
    }

    private func refreshLevels() {
        guard !taps.isEmpty else {
            if !levels.isEmpty { levels = [:] }
            return
        }
        var updated: [String: Float] = [:]
        for (appID, tap) in taps {
            let peak = tap.parameters.consumePeak()
            // Smooth the fall, follow the rise immediately.
            let previous = levels[appID] ?? 0
            updated[appID] = peak >= previous ? peak : previous * 0.7
        }
        levels = updated
    }

    private func refreshDevices() {
        outputDevices = AudioDevices.outputDevices()
        inputDevices = AudioDevices.inputDevices()
        defaultOutputDevice = AudioDevices.defaultOutputDevice()
        defaultInputDevice = AudioDevices.defaultInputDevice()
        effectsDevice = AudioDevices.defaultEffectsDevice()
        refreshVolumes()
    }

    /// The user can change volume from the keyboard too, so these are polled.
    private func refreshVolumes() {
        systemVolume = defaultOutputDevice.flatMap { AudioDevices.volume(of: $0.id) }
        systemMuted = defaultOutputDevice.map { AudioDevices.isMuted($0.id) } ?? false

        inputVolume = defaultInputDevice.flatMap {
            AudioDevices.volume(of: $0.id, scope: kAudioObjectPropertyScopeInput)
        }
        inputMuted = defaultInputDevice.map {
            AudioDevices.isMuted($0.id, scope: kAudioObjectPropertyScopeInput)
        } ?? false

        effectsVolume = SystemAudio.alertVolume()
    }

    private func refreshApps() {
        let updated = AudioProcessMonitor.currentApps(favorites: favorites)
        if updated != apps {
            apps = updated
            syncTaps()
        }
    }

    private func installListeners() {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyProcessObjectList,
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice
        ]
        listeners = selectors.compactMap { selector in
            AudioObjectID.system.addListener(selector) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if selector == kAudioHardwarePropertyProcessObjectList {
                        self.refreshApps()
                    } else {
                        self.refreshDevices()
                        self.syncTaps()
                    }
                }
            }
        }
    }

    // MARK: Tap management

    /// Brings running taps in line with the settings: starts the ones needed, stops
    /// the ones that are not, and rebuilds a tap when its process list or target
    /// device has changed.
    private func syncTaps() {
        let appsByID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (appID, tap) in taps {
            guard settings[appID] != nil,
                  let app = appsByID[appID], app.isConnected else {
                tap.stop()
                taps[appID] = nil
                continue
            }
            let desiredUID = settings(for: appID).outputDeviceUID ?? defaultOutputDevice?.uid
            if tap.processObjectIDs != app.processObjectIDs || tap.outputDeviceUID != desiredUID {
                tap.stop()
                taps[appID] = nil
            }
        }

        for appID in settings.keys where taps[appID] == nil {
            guard let app = appsByID[appID], app.isConnected else { continue }
            startTap(for: app)
        }
    }

    private func startTap(for app: AudioApp) {
        let appSettings = settings(for: app.id)
        guard let outputUID = appSettings.outputDeviceUID ?? defaultOutputDevice?.uid else { return }

        let tap = AppTap(appID: app.id, displayName: app.name)
        tap.parameters.gain = appSettings.volume
        tap.parameters.isMuted = appSettings.isMuted
        tap.parameters.balance = appSettings.balance
        tap.parameters.equalizer.update(gains: appSettings.equalizer.gains)
        tap.parameters.equalizer.isEnabled = appSettings.equalizer.isEnabled

        do {
            try tap.start(processObjectIDs: app.processObjectIDs, outputDeviceUID: outputUID)
            taps[app.id] = tap
            lastError = nil
        } catch {
            lastError = describe(error, app: app.name)
            // A missing device, a permission denial, or another router can make tap
            // creation fail temporarily. Keep the user's persisted settings so a later
            // device/process change or explicit edit can retry without data loss.
        }
    }

    private func describe(_ error: Error, app: String) -> String {
        if let caError = error as? CoreAudioError,
           caError.operation.contains("CreateProcessTap") {
            return """
            Could not capture \(app) (\(caError.status) '\(caError.status.fourCharCode)').
            Make sure Mikser is allowed in System Settings → Privacy & Security → \
            Screen & System Audio Recording.
            """
        }
        return error.localizedDescription
    }

    // MARK: Persistence

    private func loadPersisted() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode([String: AppSettings].self, from: data) {
            settings = decoded
        }
        if let stored = UserDefaults.standard.stringArray(forKey: favoritesKey) {
            favorites = Set(stored)
        }
        if let stored = UserDefaults.standard.stringArray(forKey: hiddenAppsKey) {
            hiddenApps = Set(stored)
        }
    }

    private func savePersisted() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKey)
        UserDefaults.standard.set(Array(hiddenApps), forKey: hiddenAppsKey)
    }
}
