//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreAudio
import Foundation

/// A single process attached to the HAL.
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

/// One row on screen — it can cover several processes (an app and its helpers).
struct AudioApp: Identifiable, Equatable {
    let id: String              // resolved bundle identifier
    let name: String
    let icon: NSImage?
    var processObjectIDs: [AudioObjectID]
    var isPlaying: Bool
    var isFavorite: Bool

    /// Applications starred as favourites stay in the list even when they are not
    /// attached to the audio stack; their settings are kept and applied as soon as
    /// they start playing.
    var isConnected: Bool { !processObjectIDs.isEmpty }
}

enum AudioProcessMonitor {

    /// System services the user has no interest in. They stay out of the list even
    /// while playing audio.
    private static let ignoredBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.loginwindow",
        "com.apple.PowerChime",
        "com.apple.notificationcenterui",
        "com.apple.CoreSpeech",
        "com.apple.corespeechd_system",
        "com.apple.assistantd",
        "com.apple.SiriNCService",
        "com.apple.audiomxd",
        "com.apple.mediaremoted",
        "com.apple.cloudpaird",
        "com.apple.universalaccessd",
        "com.apple.accessibility.heard",
        "com.apple.TelephonyUtilities",
        "com.apple.avconferenced",
        "com.apple.cmio.ContinuityCaptureAgent",
        "com.apple.Sound-Settings.extension",
        "systemsoundserverd",
        // Audio routing infrastructure — tapping these collides with our own chain.
        "com.rogueamoeba.arkaudiod",
        "com.rogueamoeba.soundsource",
        Bundle.main.bundleIdentifier ?? "io.github.erdmncdr.mikser"
    ]

    /// Suffixes that show up in helper processes' bundle identifiers.
    private static let helperSuffixes = ["helper", "renderer", "gpu", "plugin", "networking", "extension"]

    static func currentProcesses() -> [AudioProcess] {
        let ids = (try? AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self
        )) ?? []

        return ids.map { objectID in
            AudioProcess(
                objectID: objectID,
                pid: objectID.readOptional(kAudioProcessPropertyPID, as: pid_t.self) ?? -1,
                bundleID: objectID.readStringOptional(kAudioProcessPropertyBundleID),
                isRunningOutput: (objectID.readOptional(
                    kAudioProcessPropertyIsRunningOutput, as: UInt32.self
                ) ?? 0) == 1
            )
        }
    }

    /// Groups processes by the real application behind them — Chrome's three helpers
    /// become one "Chrome" row. Favourites that are not attached to the audio stack
    /// are appended too.
    static func currentApps(favorites: Set<String>) -> [AudioApp] {
        var grouped: [String: (name: String, icon: NSImage?, ids: [AudioObjectID], playing: Bool)] = [:]

        for process in currentProcesses() {
            guard let identity = resolveIdentity(for: process) else { continue }
            guard !ignoredBundleIDs.contains(identity.bundleID) else { continue }

            if var existing = grouped[identity.bundleID] {
                existing.ids.append(process.objectID)
                existing.playing = existing.playing || process.isRunningOutput
                grouped[identity.bundleID] = existing
            } else {
                grouped[identity.bundleID] = (
                    identity.name, identity.icon, [process.objectID], process.isRunningOutput
                )
            }
        }

        var apps = grouped.map { entry in
            AudioApp(
                id: entry.key,
                name: entry.value.name,
                icon: entry.value.icon,
                // Keeping the IDs sorted means the "did the process list change?"
                // comparison is not affected by dictionary ordering.
                processObjectIDs: entry.value.ids.sorted(),
                isPlaying: entry.value.playing,
                isFavorite: favorites.contains(entry.key)
            )
        }

        // Favourites that are not playing yet still belong in the list.
        let present = Set(apps.map(\.id))
        for bundleID in favorites where !present.contains(bundleID) {
            if let placeholder = favoritePlaceholder(bundleID: bundleID) {
                apps.append(placeholder)
            }
        }

        return apps.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Applications the user can see, for the "add application" menu.
    static func selectableRunningApplications() -> [(bundleID: String, name: String, icon: NSImage?)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleID = application.bundleIdentifier,
                      !ignoredBundleIDs.contains(bundleID) else { return nil }
                return (bundleID, application.localizedName ?? bundleID, application.icon)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func appInfo(forBundleID bundleID: String) -> (name: String, icon: NSImage?)? {
        if let running = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == bundleID }
        ) {
            return (running.localizedName ?? bundleID, running.icon)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return (FileManager.default.displayName(atPath: url.path),
                    NSWorkspace.shared.icon(forFile: url.path))
        }
        return nil
    }

    private static func favoritePlaceholder(bundleID: String) -> AudioApp? {
        guard let info = appInfo(forBundleID: bundleID) else { return nil }
        return AudioApp(
            id: bundleID, name: info.name, icon: info.icon,
            processObjectIDs: [], isPlaying: false, isFavorite: true
        )
    }

    // MARK: - Identity resolution

    private struct Identity {
        let bundleID: String
        let name: String
        let icon: NSImage?
    }

    private static func resolveIdentity(for process: AudioProcess) -> Identity? {
        // 1) If the PID belongs directly to a visible application, that is the most
        //    reliable route.
        if process.pid > 0,
           let running = NSRunningApplication(processIdentifier: process.pid),
           let bundleID = running.bundleIdentifier,
           running.activationPolicy == .regular {
            return Identity(bundleID: bundleID,
                            name: running.localizedName ?? bundleID,
                            icon: running.icon)
        }

        // 2) A helper process: derive the parent application from the bundle ID.
        guard let bundleID = process.bundleID, !bundleID.isEmpty else { return nil }
        guard let parentID = parentBundleID(of: bundleID) else { return nil }
        guard let info = appInfo(forBundleID: parentID) else { return nil }
        return Identity(bundleID: parentID, name: info.name, icon: info.icon)
    }

    /// `com.google.Chrome.helper.renderer` → `com.google.Chrome`
    private static func parentBundleID(of bundleID: String) -> String? {
        var components = bundleID.split(separator: ".").map(String.init)

        while components.count > 2,
              let last = components.last,
              helperSuffixes.contains(where: { last.localizedCaseInsensitiveContains($0) }) {
            components.removeLast()
        }

        let candidate = components.joined(separator: ".")
        guard candidate.split(separator: ".").count >= 2 else { return nil }

        // Accept it only if it really maps to an installed application.
        let isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) != nil
            || NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == candidate }
        return isInstalled ? candidate : nil
    }
}
