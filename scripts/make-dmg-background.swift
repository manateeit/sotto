#!/usr/bin/env swift
//
// Renders Assets/dmg-background.png programmatically with CoreGraphics/CoreText
// — same no-design-tool approach as make-icon.swift. Produces the classic
// "Drag Sotto to Applications" DMG background: dark canvas matching the app
// icon's palette, an arrow between where the app icon and the /Applications
// symlink land, instructional text above it.
//
// The icon slot centers here (180,170) and (480,170) are chosen to match the
// `position of item` coordinates scripts/make-dmg.sh sets via Finder
// AppleScript, in a 660x400 window — keep the two in sync if either changes.
//
// Usage: swift scripts/make-dmg-background.swift
// (scripts/make-dmg.sh consumes the committed PNG; it does not re-run this.)
//
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let width = 660
let height = 400

func drawArrow(in ctx: CGContext, from: CGPoint, to: CGPoint, color: CGColor, lineWidth: CGFloat) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.move(to: from)
    ctx.addLine(to: to)
    ctx.strokePath()

    let angle = atan2(to.y - from.y, to.x - from.x)
    let headLength: CGFloat = lineWidth * 5.5
    let headAngle: CGFloat = .pi / 7
    let p1 = CGPoint(x: to.x - headLength * cos(angle - headAngle), y: to.y - headLength * sin(angle - headAngle))
    let p2 = CGPoint(x: to.x - headLength * cos(angle + headAngle), y: to.y - headLength * sin(angle + headAngle))
    ctx.setFillColor(color)
    ctx.move(to: to)
    ctx.addLine(to: p1)
    ctx.addLine(to: p2)
    ctx.closePath()
    ctx.fillPath()
}

func drawCenteredText(_ text: String, in ctx: CGContext, centerX: CGFloat, centerY: CGFloat, fontSize: CGFloat, color: CGColor) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attrs = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color,
    ] as CFDictionary
    guard let attrString = CFAttributedStringCreate(nil, text as CFString, attrs) else { return }
    let line = CTLineCreateWithAttributedString(attrString)
    let bounds = CTLineGetBoundsWithOptions(line, [])
    ctx.textPosition = CGPoint(x: centerX - bounds.width / 2, y: centerY - bounds.height / 2 - bounds.origin.y)
    CTLineDraw(line, ctx)
}

func drawBackground() -> CGImage {
    let w = CGFloat(width), h = CGFloat(height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create CGContext") }

    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

    // Same charcoal-to-slate diagonal gradient as Assets/AppIcon.icns.
    let bgColors = [
        CGColor(red: 0.06, green: 0.08, blue: 0.11, alpha: 1),
        CGColor(red: 0.12, green: 0.17, blue: 0.21, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
    }

    // Icon row: mirrors make-dmg.sh's Finder icon positions (180,170)/(480,170)
    // in top-down window space; this context is bottom-up, so flip Y.
    let leftX = w * (180.0 / 660.0)
    let rightX = w * (480.0 / 660.0)
    let rowY = h - h * (170.0 / 400.0)

    let teal = CGColor(red: 0.34, green: 0.86, blue: 0.79, alpha: 0.95)
    drawArrow(in: ctx, from: CGPoint(x: leftX + 74, y: rowY), to: CGPoint(x: rightX - 74, y: rowY),
              color: teal, lineWidth: 4)

    drawCenteredText("Drag Sotto to Applications", in: ctx, centerX: w / 2, centerY: rowY + 120,
                      fontSize: 22, color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))

    guard let image = ctx.makeImage() else { fatalError("could not render background image") }
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
let outURL = root.appendingPathComponent("Assets/dmg-background.png")
writePNG(drawBackground(), to: outURL)
print("Wrote DMG background to \(outURL.path)")
