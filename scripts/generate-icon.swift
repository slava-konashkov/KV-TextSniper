#!/usr/bin/env swift
//
// generate-icon.swift
//
// Generates the 10 PNG sizes that macOS expects inside
// KV-TextSniper/Assets.xcassets/AppIcon.appiconset, and rewrites
// Contents.json to reference them. Run once (or after changing the
// icon design):
//
//     swift scripts/generate-icon.swift
//
// Uses the same `text.viewfinder` SF Symbol that the menu-bar uses,
// on a blue gradient "card" with macOS-standard corner radius.
//

import AppKit
import Foundation

// MARK: - Sizes matrix

struct IconSize {
    let pointSize: Int
    let scale: Int        // 1 or 2
    let filename: String

    var pixelSize: Int { pointSize * scale }
}

let sizes: [IconSize] = [
    .init(pointSize: 16,  scale: 1, filename: "icon_16x16.png"),
    .init(pointSize: 16,  scale: 2, filename: "icon_16x16@2x.png"),
    .init(pointSize: 32,  scale: 1, filename: "icon_32x32.png"),
    .init(pointSize: 32,  scale: 2, filename: "icon_32x32@2x.png"),
    .init(pointSize: 128, scale: 1, filename: "icon_128x128.png"),
    .init(pointSize: 128, scale: 2, filename: "icon_128x128@2x.png"),
    .init(pointSize: 256, scale: 1, filename: "icon_256x256.png"),
    .init(pointSize: 256, scale: 2, filename: "icon_256x256@2x.png"),
    .init(pointSize: 512, scale: 1, filename: "icon_512x512.png"),
    .init(pointSize: 512, scale: 2, filename: "icon_512x512@2x.png"),
]

// MARK: - Drawing

/// Returns a PNG representation of the icon at `px` × `px` pixels.
/// Draws directly into a CGContext so the script works in a plain CLI
/// process (no window server, no NSApplication instance).
func renderIcon(pixelSize px: Int) -> Data? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Wrap in NSGraphicsContext so AppKit drawing APIs (NSBezierPath,
    // NSGradient, NSImage.draw) target this CGContext.
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Background "card": slightly inset from the canvas, with the
    // rounded-corner radius macOS has used since Big Sur (~22.37% of
    // the card side).
    let inset = CGFloat(px) * 0.08
    let cardRect = NSRect(
        x: inset, y: inset,
        width: CGFloat(px) - 2 * inset,
        height: CGFloat(px) - 2 * inset
    )
    let cornerRadius = cardRect.width * 0.2237
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)

    guard let gradient = NSGradient(colors: [
        NSColor(red: 0.20, green: 0.45, blue: 0.90, alpha: 1.0),
        NSColor(red: 0.10, green: 0.30, blue: 0.70, alpha: 1.0),
    ]) else { return nil }
    gradient.draw(in: cardPath, angle: -90)

    // SF Symbol centred on the card, ~60% of card side, white.
    let symbolPointSize = cardRect.width * 0.58
    let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
    if let base = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil),
       let configured = base.withSymbolConfiguration(config) {
        // Get the CGImage so we can tint-blit it via Core Graphics, which
        // works reliably without a window server.
        var proposed = NSRect(origin: .zero, size: configured.size)
        if let cg = configured.cgImage(forProposedRect: &proposed, context: nsCtx, hints: nil) {
            let sRect = NSRect(
                x: cardRect.midX - configured.size.width / 2,
                y: cardRect.midY - configured.size.height / 2,
                width: configured.size.width,
                height: configured.size.height
            )
            // Clip to the symbol shape, then fill with white — this turns
            // the template image into a white-tinted icon.
            ctx.saveGState()
            ctx.clip(to: sRect, mask: cg)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(sRect)
            ctx.restoreGState()
        }
    }

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Output paths

let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconsetURL = cwd
    .appendingPathComponent("KV-TextSniper")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

guard fm.fileExists(atPath: iconsetURL.path) else {
    FileHandle.standardError.write(Data("AppIcon.appiconset not found at \(iconsetURL.path)\n".utf8))
    FileHandle.standardError.write(Data("Run this script from the project root.\n".utf8))
    exit(1)
}

// MARK: - Render & write

for spec in sizes {
    guard let png = renderIcon(pixelSize: spec.pixelSize) else {
        FileHandle.standardError.write(Data("Failed to render \(spec.filename)\n".utf8))
        exit(1)
    }
    let outURL = iconsetURL.appendingPathComponent(spec.filename)
    try png.write(to: outURL)
    print("Wrote \(spec.filename) (\(spec.pixelSize)×\(spec.pixelSize))")
}

// MARK: - Rewrite Contents.json

struct ImageEntry: Encodable {
    let filename: String
    let idiom: String
    let scale: String
    let size: String
}

struct Info: Encodable {
    let author: String
    let version: Int
}

struct Manifest: Encodable {
    let images: [ImageEntry]
    let info: Info
}

let images = sizes.map { spec -> ImageEntry in
    ImageEntry(
        filename: spec.filename,
        idiom: "mac",
        scale: "\(spec.scale)x",
        size: "\(spec.pointSize)x\(spec.pointSize)"
    )
}

let manifest = Manifest(images: images, info: Info(author: "xcode", version: 1))
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(manifest)
try data.write(to: iconsetURL.appendingPathComponent("Contents.json"))
print("Rewrote Contents.json")
