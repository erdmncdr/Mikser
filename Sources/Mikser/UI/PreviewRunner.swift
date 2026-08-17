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

        let controller = NSHostingController(
            rootView: MenuBarContentView(engine: MixerEngine(preview: true))
        )
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

        application.activate(ignoringOtherApps: true)
        application.run()
        exit(0)
    }
}
