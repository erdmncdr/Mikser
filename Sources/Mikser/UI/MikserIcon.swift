//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

enum MikserIcon {

    private static let logoSide: CGFloat = 17
    private static let gap: CGFloat = 3.5
    private static let levelSegments = 4
    private static let levelWidth: CGFloat = 6
    private static let blockHeight: CGFloat = 2.5
    private static let blockGap: CGFloat = 1.0

    /// The menu bar item: brand mark plus a four-step level indicator, drawn into
    /// a **single** NSImage.
    ///
    /// Passing them as two separate `Image` views in the `MenuBarExtra` label made
    /// the second one disappear entirely — the label does not reliably carry more
    /// than one image. Drawing both here also gives exact control over the spacing.
    ///
    /// The mark is deliberately device independent: macOS already shows AirPods and
    /// headphone status with its own icon, so repeating it carries no information.
    static func menuBar(volume: Float?, muted: Bool) -> NSImage {
        cached[litSegments(volume: volume, muted: muted)]
    }

    private static func litSegments(volume: Float?, muted: Bool) -> Int {
        guard let volume, !muted, volume > 0 else { return 0 }
        return min(levelSegments, max(1, Int((volume * Float(levelSegments)).rounded(.up))))
    }

    /// Only five states exist, so they are drawn once instead of on every render.
    private static let cached: [NSImage] = (0...levelSegments).map(make(lit:))

    private static func make(lit: Int) -> NSImage {
        let stackHeight = CGFloat(levelSegments) * blockHeight
            + CGFloat(levelSegments - 1) * blockGap
        let size = NSSize(width: logoSide + gap + levelWidth, height: logoSide)

        let image = NSImage(size: size, flipped: false) { _ in
            drawLogo(in: NSRect(x: 0, y: 0, width: logoSide, height: logoSide))
            drawLevel(
                lit: lit,
                in: NSRect(
                    x: logoSide + gap,
                    y: (logoSide - stackHeight) / 2,
                    width: levelWidth,
                    height: stackHeight
                )
            )
            return true
        }
        // Template image: macOS tints it for the light or dark menu bar. Alpha acts
        // as the mask, so unlit blocks come out correctly faded.
        image.isTemplate = true
        return image
    }

    // MARK: Drawing

    /// A rounded square holding two faders. The app icon uses three; at 17pt three
    /// faders run into each other, so the small size drops one.
    private static func drawLogo(in rect: NSRect) {
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let frame = rect.insetBy(dx: 1.1, dy: 1.1)
        let border = NSBezierPath(roundedRect: frame, xRadius: 4.6, yRadius: 4.6)
        border.lineWidth = 1.5
        border.stroke()

        let trackTop = frame.maxY - 3.4
        let trackBottom = frame.minY + 3.4
        let faders: [(x: CGFloat, knob: CGFloat)] = [
            (frame.midX - 2.7, trackBottom + (trackTop - trackBottom) * 0.68),
            (frame.midX + 2.7, trackBottom + (trackTop - trackBottom) * 0.30)
        ]

        for fader in faders {
            NSBezierPath(rect: NSRect(
                x: fader.x - 0.5, y: trackBottom,
                width: 1.0, height: trackTop - trackBottom
            )).fill()

            let knobSize: CGFloat = 3.6
            NSBezierPath(ovalIn: NSRect(
                x: fader.x - knobSize / 2, y: fader.knob - knobSize / 2,
                width: knobSize, height: knobSize
            )).fill()
        }
    }

    /// Writes the five level states, scaled up over a light background, as PNGs.
    /// Invoked with `--dump-icons <directory>`; lets the design be reviewed without
    /// changing the system volume to walk through the steps.
    static func dumpVariants(to directory: String) {
        let scale: CGFloat = 8
        for (lit, source) in cached.enumerated() {
            let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            let canvas = NSImage(size: size)
            canvas.lockFocus()
            NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            NSGraphicsContext.current?.imageInterpolation = .none
            source.draw(in: NSRect(origin: .zero, size: size))
            canvas.unlockFocus()

            guard let tiff = canvas.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("menubar-\(lit)-of-\(levelSegments).png")
            try? png.write(to: url)
            print("  \(url.lastPathComponent)")
        }
    }

    private static func drawLevel(lit: Int, in rect: NSRect) {
        for index in 0..<levelSegments {
            // Index 0 is the bottom block.
            let y = rect.minY + CGFloat(index) * (blockHeight + blockGap)
            NSColor.black.withAlphaComponent(index < lit ? 1.0 : 0.25).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: rect.minX, y: y, width: rect.width, height: blockHeight),
                xRadius: 1, yRadius: 1
            ).fill()
        }
    }
}
