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
///
/// Bringing Sparkle's windows to the front needs more than activating the app.
/// `LSUIElement` puts Mikser in the `.accessory` policy, and an accessory app
/// cannot take focus, so the update window opened behind whatever was in front.
/// Activating at the moment the menu item is clicked does not help either — the
/// window only appears after the appcast has been fetched over the network.
///
/// So the policy is raised to `.regular` from Sparkle's own delegate callbacks,
/// which fire immediately before any update UI is shown, and lowered again when
/// the session ends. The Dock icon appears for the duration of the check.
final class UpdateController: NSObject, SPUStandardUserDriverDelegate {
    static let shared = UpdateController()

    private var updaterController: SPUStandardUpdaterController!

    /// Non-nil only while update UI is on screen; also guards against raising the
    /// policy twice when several callbacks fire in one session.
    private var policyBeforeUpdateUI: NSApplication.ActivationPolicy?

    private override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    func checkForUpdates() {
        // Let the settings menu finish dismissing before Sparkle takes over.
        DispatchQueue.main.async { [self] in
            updaterController.checkForUpdates(nil)
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Fires before "You're up to date" and before error alerts.
    func standardUserDriverWillShowModalAlert() {
        moveToForeground()
        raiseUpdateWindowWhenItAppears()
    }

    /// The alert is run modally, so this returns only once it has been dismissed.
    ///
    /// Restoring here is what actually covers the common case: a manual check that
    /// finds no update never becomes an "update session", so
    /// `standardUserDriverWillFinishUpdateSession()` is not called for it and the
    /// Dock icon would otherwise stay for the rest of the run.
    func standardUserDriverDidShowModalAlert() {
        returnToBackground()
    }

    /// Fires before the update-available window.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        moveToForeground()
        raiseUpdateWindowWhenItAppears()
    }

    func standardUserDriverWillFinishUpdateSession() {
        returnToBackground()
    }

    private func moveToForeground() {
        if policyBeforeUpdateUI == nil {
            policyBeforeUpdateUI = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pulls Sparkle's window in front of the open menu bar panel.
    ///
    /// `MenuBarExtra`'s panel sits at `.popUpMenu` (level 101) and holds key status,
    /// which leaves Sparkle's window at level 0 and never focused — buried, no matter
    /// which application is active.
    ///
    /// Ordering the panel out directly does fix the layering, but it desyncs
    /// `MenuBarExtra`'s own presented/dismissed state: SwiftUI keeps believing the
    /// panel is open, so the next click on the status item does nothing and the panel
    /// can never be reopened. Taking key status instead makes the panel close through
    /// its normal resign-key path, which leaves that state intact.
    ///
    /// The window does not exist yet when the delegate fires, and modal alerts block
    /// the main queue, so this is scheduled on the run loop in `.modalPanel` mode too.
    private func raiseUpdateWindowWhenItAppears() {
        // The window does not exist yet when the delegate fires, and the appcast
        // fetch means it can be a moment away, so poll briefly instead of trying
        // once. The timer is added to `.modalPanel` as well because an NSAlert runs
        // its own modal loop and would otherwise starve the default mode.
        var attempts = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            attempts += 1
            if self?.raiseUpdateWindow() == true || attempts >= 40 {
                timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    /// Pulls Sparkle's window in front of the open menu bar panel.
    ///
    /// `MenuBarExtra`'s panel sits at `.popUpMenu` (level 101) and holds key status,
    /// which leaves Sparkle's window at level 0 and never focused — buried, no matter
    /// which application is active.
    ///
    /// Ordering the panel out directly does fix the layering, but it desyncs
    /// `MenuBarExtra`'s own presented/dismissed state: SwiftUI keeps believing the
    /// panel is open, so the next click on the status item does nothing and the panel
    /// can never be reopened. Taking key status instead makes the panel close through
    /// its normal resign-key path, which leaves that state intact.
    @discardableResult
    private func raiseUpdateWindow() -> Bool {
        let panelLevel = NSWindow.Level.popUpMenu.rawValue
        let updateWindow = NSApp.windows.first { window in
            window.isVisible
                && window.level.rawValue < panelLevel
                && !String(describing: type(of: window)).contains("StatusBar")
        }
        guard let updateWindow else { return false }

        updateWindow.level = NSWindow.Level(rawValue: panelLevel + 1)
        updateWindow.makeKeyAndOrderFront(nil)
        return true
    }

    private func returnToBackground() {
        guard let previous = policyBeforeUpdateUI else { return }
        NSApp.setActivationPolicy(previous)
        policyBeforeUpdateUI = nil
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
