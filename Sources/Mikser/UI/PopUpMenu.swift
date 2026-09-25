//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// One entry in a pop-up menu.
enum MenuEntry {
    case item(MenuItem)
    case submenu(title: String, symbol: String?, entries: [MenuEntry])
    case header(String)
    case separator

    static func action(
        _ title: String, symbol: String? = nil, image: NSImage? = nil,
        isChecked: Bool = false, isEnabled: Bool = true,
        perform: @escaping () -> Void
    ) -> MenuEntry {
        .item(MenuItem(
            title: title, symbol: symbol, image: image,
            isChecked: isChecked, isEnabled: isEnabled, perform: perform
        ))
    }
}

struct MenuItem {
    let title: String
    var symbol: String?
    var image: NSImage?
    var isChecked = false
    var isEnabled = true
    let perform: () -> Void
}

/// Any SwiftUI view that opens an AppKit menu when clicked.
///
/// SwiftUI's `Menu` is not used for this. With `.borderlessButton` it renders
/// through an `NSPopUpButton` that draws only the label's text and image, and
/// sizes its hit area to them: a 34pt-tall device pill turned out to respond to
/// clicks only in a 14pt strip through its middle, so most clicks did nothing.
/// Here an AppKit view covers the whole label, so every visible point is
/// clickable, and the label can be any SwiftUI view.
///
/// Entries are built when the menu opens rather than on every render. That keeps
/// lists such as the running applications current, and keeps the work out of the
/// ten-times-a-second redraws that the level meters cause.
struct PopUpMenu<Label: View>: View {
    let accessibilityLabel: String
    var help: String?
    let entries: () -> [MenuEntry]
    @ViewBuilder let label: (_ isHighlighted: Bool) -> Label

    @State private var isHovering = false
    @State private var isOpen = false

    var body: some View {
        label(isHovering || isOpen)
            .overlay(
                MenuAnchor(
                    accessibilityLabel: accessibilityLabel,
                    help: help,
                    entries: entries,
                    onHover: { isHovering = $0 },
                    onOpenChange: { isOpen = $0 }
                )
            )
    }
}

private struct MenuAnchor: NSViewRepresentable {
    let accessibilityLabel: String
    let help: String?
    let entries: () -> [MenuEntry]
    let onHover: (Bool) -> Void
    let onOpenChange: (Bool) -> Void

    func makeNSView(context: Context) -> MenuAnchorView {
        MenuAnchorView()
    }

    func updateNSView(_ view: MenuAnchorView, context: Context) {
        view.entries = entries
        view.onHover = onHover
        view.onOpenChange = onOpenChange
        view.toolTip = help
        view.setAccessibilityLabel(accessibilityLabel)
    }
}

/// The transparent view that receives the click and shows the menu.
final class MenuAnchorView: NSView {
    var entries: () -> [MenuEntry] = { [] }
    var onHover: (Bool) -> Void = { _ in }
    var onOpenChange: (Bool) -> Void = { _ in }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The panel may not be key when the pointer arrives; the first click must
    /// still open the menu rather than only focusing the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        openMenu()
    }

    override func accessibilityPerformPress() -> Bool {
        openMenu()
        return true
    }

    private func openMenu() {
        let menu = MenuBuilder.menu(from: entries())
        guard !menu.items.isEmpty else { return }
        onOpenChange(true)
        onHover(false)
        // Opens just below the control, left edges aligned. `popUp` runs the menu's
        // own tracking loop and returns once it has closed.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        onOpenChange(false)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

@MainActor
enum MenuBuilder {
    static func menu(from entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            menu.addItem(makeItem(entry))
        }
        return menu
    }

    private static func makeItem(_ entry: MenuEntry) -> NSMenuItem {
        switch entry {
        case .item(let model):
            let item = ClosureMenuItem(title: model.title, handler: model.perform)
            item.state = model.isChecked ? .on : .off
            item.isEnabled = model.isEnabled
            item.image = model.image.map(menuSized) ?? model.symbol.flatMap(symbolImage)
            return item

        case .submenu(let title, let symbol, let entries):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = symbol.flatMap(symbolImage)
            item.submenu = menu(from: entries)
            return item

        case .header(let title):
            return NSMenuItem.sectionHeader(title: title)

        case .separator:
            return NSMenuItem.separator()
        }
    }

    private static func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Application icons arrive at full size; a menu row wants 16pt.
    private static func menuSized(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// A menu item that runs a closure instead of sending an action up the
/// responder chain.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
