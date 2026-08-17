//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Shows the menu bar popover in an ordinary window.
///
///     Mikser.app/Contents/MacOS/Mikser --preview
///
/// For inspecting the layout, and taking screenshots, without clicking the menu bar.
@MainActor
enum PreviewRunner {
    static func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        let engine = MixerEngine(preview: true)
        let controller = NSHostingController(rootView: MenuBarContentView(engine: engine))
        // The menu bar popover sizes itself to its content, so the preview has to do
        // the same. With a fixed height, layout bugs that only appear in the popover
        // — such as a ScrollView collapsing to zero height — stay invisible here.
        controller.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: controller)
        window.title = "Mikser — preview"
        window.styleMask = [.titled, .closable]
        // Place it at the top left rather than centred; system dialogs cover the middle.
        if let screen = NSScreen.main {
            window.setFrameTopLeftPoint(
                NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 20)
            )
        }
        // Development window: keep it above other applications.
        window.level = .floating
        window.makeKeyAndOrderFront(nil)

        // Regression mode for the menu-bar panel's dynamic height. It starts
        // with three rows, then removes two so the window must shrink in place.
        if CommandLine.arguments.contains("--preview-resize-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                engine.hideApplication("preview.browser")
                engine.hideApplication("preview.messages")
            }
        }

        application.activate(ignoringOtherApps: true)
        application.run()
        exit(0)
    }
}
