#!/usr/bin/env swift
//
// Draws the app icon and packs it into Resources/AppIcon.icns.
//
// The artwork is vector code rather than a checked-in design file so every size
// is rendered natively instead of resampled — a 16pt icon downscaled from 1024
// turns to mush. It mirrors the menu-bar language: a crescent moon (sleep) with
// a bolt cut through it (stays awake).
//
// Usage:
//   swift scripts/make-icon.swift [--preview out.png] [output.icns]
//
import AppKit
import SwiftUI

// MARK: - Geometry (design space is 1024 × 1024, y-up)

private let canvas: CGFloat = 1024

/// Rounded-square plate, inset like a standard macOS icon so the artwork keeps
/// its margin next to neighbouring icons.
private let plateRect = CGRect(x: 100, y: 96, width: 824, height: 824)
private let plateRadius: CGFloat = 185

private struct Circle {
    var center: CGPoint
    var radius: CGFloat
    var rect: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// Crescent = big disc minus a slightly larger disc offset to the upper right,
/// which keeps the waist thin without blunting the horns.
private let moonOuter = Circle(center: CGPoint(x: 412, y: 540), radius: 252)
private let moonInner = Circle(center: CGPoint(x: 545, y: 646), radius: 280)

private let boltBox = CGRect(x: 508, y: 190, width: 352, height: 660)

/// Hexagon of a classic bolt in a unit box (y-up): top tip leans right, the
/// waist jogs, the bottom tip leans left.
private let boltUnitPoints: [CGPoint] = [
    CGPoint(x: 0.62, y: 1.00),
    CGPoint(x: 0.04, y: 0.42),
    CGPoint(x: 0.40, y: 0.42),
    CGPoint(x: 0.24, y: 0.00),
    CGPoint(x: 0.96, y: 0.58),
    CGPoint(x: 0.60, y: 0.58)
]

/// Faint stars, only drawn where they can still be resolved. Kept clear of the
/// bolt's gap, which would otherwise bite pieces out of them.
private let stars: [(CGPoint, CGFloat)] = [
    (CGPoint(x: 248, y: 806), 13),
    (CGPoint(x: 336, y: 866), 8),
    (CGPoint(x: 828, y: 246), 10)
]

// MARK: - Colours

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

private let skyTop = rgb(62, 84, 158)
private let skyBottom = rgb(15, 20, 51)
private let moonTop = rgb(255, 250, 235)
private let moonBottom = rgb(222, 214, 190)
private let boltTop = rgb(255, 219, 92)
private let boltBottom = rgb(255, 163, 26)

// MARK: - Path helpers

private func platePath() -> CGPath {
    Path(roundedRect: plateRect, cornerRadius: plateRadius, style: .continuous).cgPath
}

private func boltPath() -> CGPath {
    let path = CGMutablePath()
    for (index, unit) in boltUnitPoints.enumerated() {
        let point = CGPoint(x: boltBox.minX + unit.x * boltBox.width,
                            y: boltBox.minY + unit.y * boltBox.height)
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// Grows a path outwards by `amount`, rounding its corners on the way — used
/// both for the bolt's silhouette and for the gap it punches into the moon.
/// Stroking alone would only yield the outline ring, so it is unioned back with
/// the original shape.
private func grown(_ path: CGPath, by amount: CGFloat) -> CGPath {
    let ring = path.copy(strokingWithWidth: amount * 2,
                         lineCap: .round,
                         lineJoin: .round,
                         miterLimit: 10)
    return path.union(ring)
}

private func fill(_ context: CGContext, path: CGPath, from: CGColor, to: CGColor) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(colorsSpace: colorSpace,
                                    colors: [from, to] as CFArray,
                                    locations: [0, 1]) else { return }
    let box = path.boundingBoxOfPath
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: box.midX, y: box.maxY),
                               end: CGPoint(x: box.midX, y: box.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

// MARK: - Drawing

/// - Parameter pointSize: the size the icon is *displayed* at, which drives the
///   simplification — a 32px @2x icon is still a 16pt icon and needs the same
///   fatter separating gap and no stars.
private func draw(into context: CGContext, pixelSize: CGFloat, pointSize: CGFloat) {
    context.saveGState()
    context.scaleBy(x: pixelSize / canvas, y: pixelSize / canvas)

    // Plate with the soft shadow every macOS icon carries.
    let plate = platePath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10),
                      blur: 26,
                      color: rgb(0, 0, 0, 0.35))
    context.addPath(plate)
    context.setFillColor(skyBottom)
    context.fillPath()
    context.restoreGState()
    fill(context, path: plate, from: skyTop, to: skyBottom)

    // Glow behind the moon, so the plate is not a flat wash.
    context.saveGState()
    context.addPath(plate)
    context.clip()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let glow = CGGradient(colorsSpace: colorSpace,
                             colors: [rgb(126, 158, 255, 0.38), rgb(126, 158, 255, 0)] as CFArray,
                             locations: [0, 1]) {
        context.drawRadialGradient(glow,
                                   startCenter: moonOuter.center, startRadius: 0,
                                   endCenter: moonOuter.center, endRadius: 470,
                                   options: [])
    }
    context.restoreGState()

    // The bolt's silhouette; small sizes get a slightly fatter one so it still
    // has body once it is only a handful of pixels wide.
    let boltSolid = grown(boltPath(), by: pointSize <= 32 ? 14 : 10)
    // Gap between bolt and moon, widened at small sizes for the same reason.
    let boltGap = grown(boltSolid, by: pointSize <= 32 ? 42 : 26)

    // Everything the bolt cuts through goes into one layer, so the gap is
    // punched out of the moon and the stars only — not out of the sky.
    context.beginTransparencyLayer(auxiliaryInfo: nil)

    fill(context, path: moonCrescent(pointSize: pointSize), from: moonTop, to: moonBottom)

    if pointSize >= 128 {
        for (center, radius) in stars {
            context.setFillColor(rgb(226, 234, 255, 0.85))
            context.fillEllipse(in: Circle(center: center, radius: radius).rect)
        }
    }

    context.saveGState()
    context.setBlendMode(.destinationOut)
    context.addPath(boltGap)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.endTransparencyLayer()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0, 0, 0, 0.3))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    fill(context, path: boltSolid, from: boltTop, to: boltBottom)
    context.endTransparencyLayer()
    context.restoreGState()

    // Hairline rim: catches the light at the top, grounds the plate at the bottom.
    context.saveGState()
    context.addPath(plate)
    context.setLineWidth(6)
    context.replacePathWithStrokedPath()
    context.clip()
    if let rim = CGGradient(colorsSpace: colorSpace,
                            colors: [rgb(255, 255, 255, 0.45), rgb(255, 255, 255, 0.04)] as CFArray,
                            locations: [0, 1]) {
        context.drawLinearGradient(rim,
                                   start: CGPoint(x: plateRect.midX, y: plateRect.maxY),
                                   end: CGPoint(x: plateRect.midX, y: plateRect.minY),
                                   options: [])
    }
    context.restoreGState()

    context.restoreGState()
}

/// The disc with the offset disc taken out of it. A real subtraction, not an
/// even-odd fill of both — even-odd would also keep the part of the (larger)
/// inner disc that sticks out past the outer one.
///
/// Pushing the inner disc further out thickens the waist and shortens the
/// horns, which is what keeps the crescent from dissolving at 16pt.
private func moonCrescent(pointSize: CGFloat) -> CGPath {
    let push: CGFloat = pointSize <= 32 ? 46 : 0
    let axis = CGPoint(x: moonInner.center.x - moonOuter.center.x,
                       y: moonInner.center.y - moonOuter.center.y)
    let length = (axis.x * axis.x + axis.y * axis.y).squareRoot()
    let inner = Circle(center: CGPoint(x: moonInner.center.x + axis.x / length * push,
                                       y: moonInner.center.y + axis.y / length * push),
                       radius: moonInner.radius)
    return CGPath(ellipseIn: moonOuter.rect, transform: nil)
        .subtracting(CGPath(ellipseIn: inner.rect, transform: nil))
}

// MARK: - Rendering

private func render(pixelSize: Int, pointSize: CGFloat) -> Data {
    let side = CGFloat(pixelSize)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixelSize,
                                     pixelsHigh: pixelSize,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("cannot create a \(pixelSize)px bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    draw(into: context, pixelSize: side, pointSize: pointSize)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode \(pixelSize)px PNG")
    }
    return data
}

// MARK: - Main

private let arguments = Array(CommandLine.arguments.dropFirst())
private var previewPath: String?
private var outputPath = FileManager.default.currentDirectoryPath + "/Resources/AppIcon.icns"

var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--preview":
        index += 1
        guard index < arguments.count else { fatalError("--preview needs a path") }
        previewPath = arguments[index]
    default:
        outputPath = arguments[index]
    }
    index += 1
}

if let previewPath {
    try render(pixelSize: 512, pointSize: 512).write(to: URL(fileURLWithPath: previewPath))
    print("✓ preview: \(previewPath)")
}

// (pixel size, point size) — @2x entries render at twice the pixels but keep the
// point size, so simplification follows what the eye actually sees.
private let variants: [(name: String, pixels: Int, points: CGFloat)] = [
    ("icon_16x16", 16, 16),
    ("icon_16x16@2x", 32, 16),
    ("icon_32x32", 32, 32),
    ("icon_32x32@2x", 64, 32),
    ("icon_128x128", 128, 128),
    ("icon_128x128@2x", 256, 128),
    ("icon_256x256", 256, 256),
    ("icon_256x256@2x", 512, 256),
    ("icon_512x512", 512, 512),
    ("icon_512x512@2x", 1024, 512)
]

private let fileManager = FileManager.default
private let output = URL(fileURLWithPath: outputPath)
try fileManager.createDirectory(at: output.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

// The iconset is staged next to the output rather than in the temp directory:
// it is guaranteed writable there, whatever TMPDIR the caller runs with.
private let iconset = output.deletingLastPathComponent()
    .appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    let data = render(pixelSize: variant.pixels, pointSize: variant.points)
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

private let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? fileManager.removeItem(at: iconset)

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(iconutil.terminationStatus)
}
print("✓ icon: \(output.path)")
