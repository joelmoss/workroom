#!/usr/bin/env swift
//
// make-icon.swift — generates the Workroom app icons.
//
// Draws the shared Codaset / Workroom square-blocked mark in signal yellow on a black macOS tile.
// Development and nightly variants retain the yellow mark and overlay a compact, channel-colored
// label so side-by-side builds remain easy to distinguish. Exports every PNG the macOS AppIcon set
// needs. Pure CoreGraphics/AppKit, no source bitmap assets.
//
// Three variants are rendered:
//   • AppIcon         — the unlabelled release icon used by the shipped "Workroom" app.
//   • AppIcon-Dev     — overlays "dev" for the local Debug build.
//   • AppIcon-Nightly — overlays "nightly" for the rolling Nightly build.
//
// Usage:
//   swift Scripts/make-icon.swift [assets-dir]
// `assets-dir` defaults to WorkroomApp/Assets.xcassets relative to macapp/; each variant is
// written to its own <name>.appiconset under it.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Brand geometry and palette

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

struct Variant {
    let dirName: String
    let label: String?
}
let variants = [
    Variant(dirName: "AppIcon.appiconset", label: nil),
    Variant(dirName: "AppIcon-Dev.appiconset", label: "dev"),
    Variant(dirName: "AppIcon-Nightly.appiconset", label: "nightly"),
]

let brandYellow = rgb(0xFF, 0xEA, 0x00)
let brandBlack = rgb(0x00, 0x00, 0x00)
let devOrange = rgb(0xFF, 0x5A, 0x36)
let nightlyIndigo = rgb(0x5B, 0x55, 0xE7)

// The exact 36×36 geometry used by website/assets/brand/codaset-symbol.svg.
let markBlocks = [
    CGRect(x: 2, y: 2, width: 9, height: 9),
    CGRect(x: 14, y: 2, width: 8, height: 9),
    CGRect(x: 25, y: 2, width: 9, height: 9),
    CGRect(x: 2, y: 14, width: 9, height: 8),
    CGRect(x: 25, y: 14, width: 9, height: 8),
    CGRect(x: 2, y: 25, width: 9, height: 9),
    CGRect(x: 14, y: 25, width: 8, height: 9),
    CGRect(x: 25, y: 25, width: 9, height: 9),
]

// MARK: - Render

func render(_ pixels: Int, to url: URL, label: String?) {
    let S = CGFloat(pixels)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext") }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Draw the tile and symbol in top-left coordinates.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)

    let margin = S * 0.08
    let tile = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let radius = tile.width * 0.22
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -S * 0.016), blur: S * 0.034,
        color: rgb(0x00, 0x00, 0x00, 0.42))
    ctx.addPath(tilePath)
    ctx.setFillColor(brandBlack)
    ctx.fillPath()
    ctx.restoreGState()

    // Keep all artwork within the macOS tile silhouette.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // Inset the original 36×36 artboard so its outer blocks clear the tile's rounded corners.
    let markArtboardEdge = tile.width * 0.82
    let markOrigin = CGPoint(
        x: tile.midX - markArtboardEdge / 2,
        y: tile.midY - markArtboardEdge / 2)
    let markScale = markArtboardEdge / 36
    ctx.setFillColor(brandYellow)
    for block in markBlocks {
        ctx.fill(
            CGRect(
                x: markOrigin.x + block.minX * markScale,
                y: markOrigin.y + block.minY * markScale,
                width: block.width * markScale,
                height: block.height * markScale))
    }

    var labelRect: CGRect?
    if let label {
        let widthRatio: CGFloat = label == "nightly" ? 0.68 : 0.46
        let labelWidth = tile.width * widthRatio
        let labelHeight = tile.height * 0.17
        let rect = CGRect(
            x: tile.midX - labelWidth / 2,
            y: tile.minY + tile.height * 0.64,
            width: labelWidth,
            height: labelHeight)
        labelRect = rect
        ctx.setFillColor(label == "nightly" ? nightlyIndigo : devOrange)
        ctx.addPath(
            CGPath(
                roundedRect: rect,
                cornerWidth: labelHeight * 0.14,
                cornerHeight: labelHeight * 0.14,
                transform: nil))
        ctx.fillPath()
    }

    ctx.restoreGState()
    ctx.restoreGState()

    // CoreText uses the default bottom-left coordinate system; draw the channel name last so it
    // remains crisp instead of inheriting the flipped geometry transform above.
    if let label, let labelRect {
        let fontSize = S * (label == "nightly" ? 0.068 : 0.082)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .black)
        let textColor = label == "nightly"
            ? NSColor(srgbRed: 1, green: 234.0 / 255.0, blue: 0, alpha: 1)
            : NSColor.black
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .kern: S * 0.002,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: label, attributes: attributes))
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let baselineFromTop = labelRect.minY + (labelRect.height - fontSize) / 2 + fontSize * 0.79
        ctx.textPosition = CGPoint(x: labelRect.midX - textWidth / 2, y: S - baselineFromTop)
        CTLineDraw(line, ctx)
    }

    // --- Write PNG ------------------------------------------------------------------
    guard let image = ctx.makeImage() else { fatalError("makeImage") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try! png.write(to: url)
    print("  \(url.lastPathComponent)  (\(pixels)px)")
}

// MARK: - Menu bar glyph

// The status-bar item's icon (issue #33): the same square-blocked Codaset/Workroom mark as the
// app icon (`markBlocks`), filled solid on a transparent background — no tile, since the menu bar
// is the tile. Exported as a template image (see the imageset's Contents.json), so the system
// tints it to the menu bar's appearance and dims it when the app is inactive.
func renderMenuBarGlyph(_ pixels: Int, to url: URL) {
    let S = CGFloat(pixels)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext") }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // markBlocks is defined on a 36×36 artboard already inset ~2px on every edge, which reads as
    // the right amount of menu-bar padding at this size — so it's scaled straight onto the canvas.
    let scale = S / 36
    ctx.setFillColor(rgb(0, 0, 0))  // template-rendered, so the system recolours it
    for block in markBlocks {
        ctx.fill(CGRect(
            x: block.minX * scale, y: block.minY * scale,
            width: block.width * scale, height: block.height * scale))
    }

    guard let image = ctx.makeImage() else { fatalError("makeImage") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try! png.write(to: url)
    print("  \(url.lastPathComponent)  (\(pixels)px)")
}

// MARK: - Drive

let assetsDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "WorkroomApp/Assets.xcassets"

// filename -> pixel size, covering the full macOS AppIcon set.
let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),     ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),     ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),  ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),  ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),  ("icon_512x512@2x.png", 1024),
]

// Contents.json maps the PNGs above into the AppIcon set; identical for every variant.
let contentsJSON = """
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16", "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16", "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32", "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32", "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""

for variant in variants {
    let dir = URL(fileURLWithPath: assetsDir, isDirectory: true)
        .appendingPathComponent(variant.dirName, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    print("Rendering \(variant.dirName) → \(dir.path)")
    for (name, px) in outputs {
        render(px, to: dir.appendingPathComponent(name), label: variant.label)
    }
    try! contentsJSON.write(to: dir.appendingPathComponent("Contents.json"), atomically: false, encoding: .utf8)
}

// Menu bar template glyph (issue #33). One imageset, shared by both builds — a template image has
// no Dev/Release colour to differentiate. 18pt at @1x/@2x (macOS has no @3x).
do {
    let dir = URL(fileURLWithPath: assetsDir, isDirectory: true)
        .appendingPathComponent("MenuBarIcon.imageset", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    print("Rendering MenuBarIcon.imageset → \(dir.path)")
    let glyphOutputs: [(String, Int)] = [("menubar_18.png", 18), ("menubar_18@2x.png", 36)]
    for (name, px) in glyphOutputs {
        renderMenuBarGlyph(px, to: dir.appendingPathComponent(name))
    }
    let glyphContents = """
        {
          "images" : [
            { "idiom" : "universal", "scale" : "1x", "filename" : "menubar_18.png" },
            { "idiom" : "universal", "scale" : "2x", "filename" : "menubar_18@2x.png" }
          ],
          "info" : { "author" : "xcode", "version" : 1 },
          "properties" : { "template-rendering-intent" : "template" }
        }
        """
    try! glyphContents.write(
        to: dir.appendingPathComponent("Contents.json"), atomically: false, encoding: .utf8)
}

print("Done.")
