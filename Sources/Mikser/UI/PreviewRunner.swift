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
        let controller = NSHostingController(rootView: MenuBarContentView(engine: engine, usesMaterial: false))
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
        // with three rows, removes two, then restores one. The window must shrink
        // and grow again without collapsing the Applications section.
        if CommandLine.arguments.contains("--preview-resize-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                engine.hideApplication("preview.browser")
                engine.hideApplication("preview.messages")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                engine.showApplication("preview.browser")
            }
        }

        // Renders the panel to PNG files and quits: `--snapshot <directory>` writes
        // light.png and dark.png. Drawing the view directly needs no screen recording
        // permission, so it also works from a terminal session.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let directory = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1] : "."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    snapshot(window.contentView!, to: "\(directory)/\(name).png")
                }
                exit(0)
            }
        }

        if CommandLine.arguments.contains("--click-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { runClickTest(in: window) }
        }

        application.activate(ignoringOtherApps: true)
        application.run()
        exit(0)
    }

    /// Clicks every pop-up menu control near each of its edges and in its centre,
    /// and checks that a menu opens every time. Guards against the hit area
    /// shrinking below the visible control, which made the device menus look
    /// broken: only a thin strip through the middle of them responded.
    private static func runClickTest(in window: NSWindow) {
        func anchors(in view: NSView) -> [MenuAnchorView] {
            (view as? MenuAnchorView).map { [$0] } ?? view.subviews.flatMap(anchors(in:))
        }
        let targets = anchors(in: window.contentView!)
        var opened = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { notification in
            opened += 1
            // Cancelling from inside the notification is too early; the menu's
            // own tracking loop has to be running for it to take effect.
            let menu = notification.object as? NSMenu
            RunLoop.main.perform(inModes: [.eventTracking, .common]) {
                menu?.cancelTrackingWithoutAnimation()
            }
        }

        var failures: [String] = []
        for anchor in targets {
            let frame = anchor.convert(anchor.bounds, to: nil)
            let points: [(String, NSPoint)] = [
                ("center", NSPoint(x: frame.midX, y: frame.midY)),
                ("top", NSPoint(x: frame.midX, y: frame.maxY - 1.5)),
                ("bottom", NSPoint(x: frame.midX, y: frame.minY + 1.5)),
                ("left", NSPoint(x: frame.minX + 1.5, y: frame.midY)),
                ("right", NSPoint(x: frame.maxX - 1.5, y: frame.midY))
            ]
            for (name, point) in points {
                let before = opened
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1
                    )!
                    window.sendEvent(event)
                }
                if opened == before {
                    failures.append("\(anchor.accessibilityLabel() ?? "?") at \(name) \(Int(frame.width))x\(Int(frame.height))")
                }
            }
        }
        NotificationCenter.default.removeObserver(observer)

        print("Pop-up controls: \(targets.count), clicks: \(targets.count * 5), menus opened: \(opened)")
        for failure in failures { print("  NO MENU: \(failure)") }
        print(failures.isEmpty && !targets.isEmpty ? "PASS" : "FAIL")
        exit(failures.isEmpty && !targets.isEmpty ? 0 : 1)
    }

    private static func snapshot(_ view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}
