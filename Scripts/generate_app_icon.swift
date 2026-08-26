#!/usr/bin/env swift

import AppKit
import Foundation

private let canvas = CGSize(width: 1024, height: 1024)

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

private func drawIcon(in context: CGContext, pixelSize: Int) {
    let scale = CGFloat(pixelSize) / canvas.width
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let tile = CGPath(
        roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
        cornerWidth: 205,
        cornerHeight: 205,
        transform: nil
    )

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -26), blur: 34, color: color(0x001018, alpha: 0.42).cgColor)
    context.addPath(tile)
    context.setFillColor(color(0x0A1825).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0x16384B).cgColor, color(0x07131E).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        background,
        start: CGPoint(x: 180, y: 900),
        end: CGPoint(x: 840, y: 100),
        options: []
    )
    context.restoreGState()

    context.addPath(tile)
    context.setStrokeColor(color(0x82D9D0, alpha: 0.18).cgColor)
    context.setLineWidth(8)
    context.strokePath()

    // The broken arch reads as both a secure tunnel and an open connection.
    let arch = CGMutablePath()
    arch.move(to: CGPoint(x: 282, y: 316))
    arch.addLine(to: CGPoint(x: 282, y: 526))
    arch.addCurve(
        to: CGPoint(x: 742, y: 590),
        control1: CGPoint(x: 282, y: 836),
        control2: CGPoint(x: 742, y: 836)
    )
    context.addPath(arch)
    context.setStrokeColor(color(0x31D667).cgColor)
    context.setLineWidth(112)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    let lowerRight = CGMutablePath()
    lowerRight.move(to: CGPoint(x: 742, y: 374))
    lowerRight.addLine(to: CGPoint(x: 742, y: 316))
    context.addPath(lowerRight)
    context.setStrokeColor(color(0x31D667).cgColor)
    context.setLineWidth(112)
    context.setLineCap(.round)
    context.strokePath()

    // A bright route enters the tunnel; the dot stays legible at menu-bar sizes.
    let route = CGMutablePath()
    route.move(to: CGPoint(x: 512, y: 240))
    route.addLine(to: CGPoint(x: 512, y: 590))
    context.addPath(route)
    context.setStrokeColor(color(0xE9FEFF).cgColor)
    context.setLineWidth(64)
    context.setLineCap(.round)
    context.strokePath()

    context.setFillColor(color(0x46D8F1).cgColor)
    context.fillEllipse(in: CGRect(x: 467, y: 544, width: 90, height: 90))
    context.setFillColor(color(0xF5FFFF).cgColor)
    context.fillEllipse(in: CGRect(x: 490, y: 567, width: 44, height: 44))
}

private func pngData(pixelSize: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    graphicsContext.cgContext.clear(CGRect(origin: .zero, size: CGSize(width: pixelSize, height: pixelSize)))
    drawIcon(in: graphicsContext.cgContext, pixelSize: pixelSize)
    graphicsContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

private struct IconVariant {
    let filename: String
    let pixels: Int
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: generate_app_icon.swift output.icns preview.png\n".utf8))
    exit(2)
}

let fileManager = FileManager.default
let icnsURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let previewURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
let iconsetURL = fileManager.temporaryDirectory.appendingPathComponent("OpenConnectNative-\(UUID().uuidString).iconset")
private let variants = [
    IconVariant(filename: "icon_16x16.png", pixels: 16),
    IconVariant(filename: "icon_16x16@2x.png", pixels: 32),
    IconVariant(filename: "icon_32x32.png", pixels: 32),
    IconVariant(filename: "icon_32x32@2x.png", pixels: 64),
    IconVariant(filename: "icon_128x128.png", pixels: 128),
    IconVariant(filename: "icon_128x128@2x.png", pixels: 256),
    IconVariant(filename: "icon_256x256.png", pixels: 256),
    IconVariant(filename: "icon_256x256@2x.png", pixels: 512),
    IconVariant(filename: "icon_512x512.png", pixels: 512),
    IconVariant(filename: "icon_512x512@2x.png", pixels: 1024),
]

do {
    try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: iconsetURL) }

    for variant in variants {
        try pngData(pixelSize: variant.pixels).write(to: iconsetURL.appendingPathComponent(variant.filename))
    }
    try fileManager.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try pngData(pixelSize: 1024).write(to: previewURL)

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", "--output", icnsURL.path, iconsetURL.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error)\n".utf8))
    exit(1)
}
