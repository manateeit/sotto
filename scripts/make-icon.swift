#!/usr/bin/env swift
//
// Renders Assets/AppIcon.icns programmatically with CoreGraphics — no design
// tool, no external image assets. Dark rounded-square background, a white/teal
// microphone pill, four flanking waveform bars. No text.
//
// Usage: swift scripts/make-icon.swift
//   then: iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
// (scripts/make-app.sh consumes the committed .icns; it does not re-run this.)
//
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct IconSpec { let name: String; let size: Int }

let specs: [IconSpec] = [
    IconSpec(name: "icon_16x16", size: 16),
    IconSpec(name: "icon_16x16@2x", size: 32),
    IconSpec(name: "icon_32x32", size: 32),
    IconSpec(name: "icon_32x32@2x", size: 64),
    IconSpec(name: "icon_128x128", size: 128),
    IconSpec(name: "icon_128x128@2x", size: 256),
    IconSpec(name: "icon_256x256", size: 256),
    IconSpec(name: "icon_256x256@2x", size: 512),
    IconSpec(name: "icon_512x512", size: 512),
    IconSpec(name: "icon_512x512@2x", size: 1024),
]

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create CGContext at size \(size)") }

    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Background: rounded-square, dark charcoal-to-slate diagonal gradient.
    let cornerRadius = s * 0.225
    let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                         cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bgColors = [
        CGColor(red: 0.06, green: 0.08, blue: 0.11, alpha: 1),
        CGColor(red: 0.12, green: 0.17, blue: 0.21, alpha: 1),
    ] as CFArray
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }
    ctx.restoreGState()

    let centerX = s * 0.5
    let centerY = s * 0.5

    // Mic pill geometry decides how far out the waveform bars start.
    let pillWidth = s * 0.22
    let pillHeight = s * 0.46
    let pillHalf = pillWidth / 2

    // Waveform bars flanking the pill: two per side, taller near the pill.
    let barWidth = s * 0.055
    let barGap = s * 0.045
    let innerHeight = s * 0.26
    let outerHeight = s * 0.14
    let innerX = pillHalf + barGap + barWidth / 2
    let outerX = innerX + barWidth + barGap

    let bars: [(x: CGFloat, height: CGFloat)] = [
        (-outerX, outerHeight),
        (-innerX, innerHeight),
        (innerX, innerHeight),
        (outerX, outerHeight),
    ]
    let barColor = CGColor(red: 0.34, green: 0.86, blue: 0.79, alpha: 0.9)
    ctx.setFillColor(barColor)
    for bar in bars {
        let rect = CGRect(x: centerX + bar.x - barWidth / 2, y: centerY - bar.height / 2,
                           width: barWidth, height: bar.height)
        let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
    }

    // Mic pill: vertical capsule, white-to-teal gradient, centered.
    let pillRect = CGRect(x: centerX - pillHalf, y: centerY - pillHeight / 2, width: pillWidth, height: pillHeight)
    let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillHalf, cornerHeight: pillHalf, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03,
                   color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(pillPath)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(pillPath)
    ctx.clip()
    let pillColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        CGColor(red: 0.52, green: 0.91, blue: 0.85, alpha: 1),
    ] as CFArray
    if let pillGradient = CGGradient(colorsSpace: colorSpace, colors: pillColors, locations: [0, 1]) {
        ctx.drawLinearGradient(pillGradient,
                                start: CGPoint(x: centerX, y: centerY + pillHeight / 2),
                                end: CGPoint(x: centerX, y: centerY - pillHeight / 2), options: [])
    }
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fatalError("could not render image at size \(size)") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("could not write PNG at \(url.path)")
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconsetDir = root.appendingPathComponent("Assets/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try! FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for spec in specs {
    writePNG(drawIcon(size: spec.size), to: iconsetDir.appendingPathComponent("\(spec.name).png"))
}

print("Wrote iconset to \(iconsetDir.path)")
