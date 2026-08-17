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

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sparkle keeps this controller alive for the whole process. It checks the
    /// signed GitHub appcast on launch and presents the standard macOS update UI.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Destroy taps explicitly so application audio returns straight to the hardware.
        MainActor.assumeIsolated { MixerEngine.shared.shutdown() }
    }
}
