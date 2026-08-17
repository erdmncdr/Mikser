//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Sparkle
import SwiftUI

// The entry point lives in main.swift, so @main cannot be used here.
struct MikserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// Read inside the scene body so the menu bar item redraws when the volume changes.
    @State private var engine = MixerEngine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(engine: engine)
        } label: {
            // Brand mark and level indicator share a single image: the label does
            // not reliably carry more than one Image (the second never rendered).
            Image(nsImage: MikserIcon.menuBar(
                volume: engine.systemVolume, muted: engine.systemMuted
            ))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns Sparkle independently from NSApplication's delegate bridge. SwiftUI may
/// install a private delegate proxy, so views should not look the updater up by
/// casting NSApplication.shared.delegate.
final class UpdateController {
    static let shared = UpdateController()

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private init() {}

    func checkForUpdates() {
        // Let the settings menu finish dismissing before Sparkle presents its
        // status window, then bring the accessory app to the foreground.
        DispatchQueue.main.async { [updaterController] in
            NSApplication.shared.activate(ignoringOtherApps: true)
            updaterController.checkForUpdates(nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Starting the shared controller here also enables scheduled checks.
    private let updateController = UpdateController.shared

    func applicationWillTerminate(_ notification: Notification) {
        // Destroy taps explicitly so application audio returns straight to the hardware.
        MainActor.assumeIsolated { MixerEngine.shared.shutdown() }
    }
}
