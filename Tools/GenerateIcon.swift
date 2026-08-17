//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Generates the Mikser application icon.
//
//      swift Tools/GenerateIcon.swift Resources/Mikser.iconset
//      iconutil -c icns Resources/Mikser.iconset -o Resources/Mikser.icns
//
//  The motif matches the menu bar mark: faders. Two there (three run into each other
//  at 17pt), three here. Every size is drawn from this one source rather than scaled
//  down, so small sizes stay sharp.

import AppKit
import CoreGraphics
import Foundation

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Mikser.iconset"
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Apple's icon corner is a superellipse rather than a circular arc, so it is drawn
/// by sampling the curve parametrically.
func squirclePath(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 1440

    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = cx + a * pow(abs(cosT), 2 / exponent) * (cosT < 0 ? -1 : 1)
        let y = cy + b * pow(abs(sinT), 2 / exponent) * (sinT < 0 ? -1 : 1)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func capsulePath(x: CGFloat, bottom: CGFloat, top: CGFloat, width: CGFloat) -> CGPath {
    let rect = CGRect(x: x - width / 2, y: bottom, width: width, height: top - bottom)
    return CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
}

func drawIcon(pixelSize: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: pixelSize, height: pixelSize,
        bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let scale = CGFloat(pixelSize) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS icon template: an 824pt body on a 1024pt canvas, leaving room for the shadow.
    let body = CGRect(x: 100, y: 108, width: 824, height: 824)
    let shape = squirclePath(in: body)

    // Body shadow
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -20), blur: 46,
        color: CGColor(red: 0, green: 0.10, blue: 0.10, alpha: 0.38)
    )
    context.addPath(shape)
    context.setFillColor(CGColor(red: 0.06, green: 0.45, blue: 0.44, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // Main gradient: bright mint through to deep teal
    let bodyGradient = CGGradient(colorsSpace: sRGB, colors: [
        CGColor(red: 0.40, green: 0.95, blue: 0.76, alpha: 1),
        CGColor(red: 0.13, green: 0.78, blue: 0.61, alpha: 1),
        CGColor(red: 0.04, green: 0.38, blue: 0.42, alpha: 1)
    ] as CFArray, locations: [0, 0.48, 1])!
    context.drawLinearGradient(
        bodyGradient,
        start: CGPoint(x: 170, y: 900), end: CGPoint(x: 880, y: 140), options: []
    )

    // A soft light from above — gives the flat gradient some volume
    let sheen = CGGradient(colorsSpace: sRGB, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.34),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0)
    ] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(
        sheen,
        startCenter: CGPoint(x: 380, y: 900), startRadius: 0,
        endCenter: CGPoint(x: 380, y: 900), endRadius: 620,
        options: []
    )

    // MARK: Faders

    let trackBottom: CGFloat = 300
    let trackTop: CGFloat = 730
    let trackWidth: CGFloat = 58
    let knobRadius: CGFloat = 55

    // The heights are deliberately uneven; level knobs make the graphic look dead.
    let faders: [(x: CGFloat, fraction: CGFloat)] = [
        (340, 0.74),
        (512, 0.36),
        (684, 0.57)
    ]

    for fader in faders {
        let knobY = trackBottom + (trackTop - trackBottom) * fader.fraction

        // Track
        context.addPath(capsulePath(x: fader.x, bottom: trackBottom, top: trackTop, width: trackWidth))
        context.setFillColor(CGColor(red: 0.02, green: 0.24, blue: 0.26, alpha: 0.30))
        context.fillPath()

        // The filled part below the knob
        context.addPath(capsulePath(x: fader.x, bottom: trackBottom, top: knobY, width: trackWidth))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.50))
        context.fillPath()

        // Knob
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -7), blur: 16,
            color: CGColor(red: 0, green: 0.14, blue: 0.14, alpha: 0.45)
        )
        context.addEllipse(in: CGRect(
            x: fader.x - knobRadius, y: knobY - knobRadius,
            width: knobRadius * 2, height: knobRadius * 2
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()
    }

    context.restoreGState()

    // Edge bevel: a thin light line, the classic Apple icon lift
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.addPath(shape)
    context.setLineWidth(4)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))
    context.strokePath()
    context.restoreGState()

    return context.makeImage()
}

func writePNG(_ image: CGImage, to path: String) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: image.width, height: image.height)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateIcon", code: 1)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

// MARK: Generation

try? FileManager.default.createDirectory(
    atPath: outputPath, withIntermediateDirectories: true
)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    guard let image = drawIcon(pixelSize: variant.pixels) else {
        FileHandle.standardError.write(Data("could not draw \(variant.name)\n".utf8))
        exit(1)
    }
    try writePNG(image, to: "\(outputPath)/\(variant.name).png")
    print("  \(variant.name).png  (\(variant.pixels)px)")
}

print("Done: \(outputPath)")
