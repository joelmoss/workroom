#!/usr/bin/env swift
//
// make-icon.swift — generates the Workroom app icon.
//
// Draws three cascading rounded "room" cards (a workroom = an isolated copy) on a
// rounded-square tile, with a terminal prompt — a blue chevron and a pink block cursor —
// on the front card. Exports every PNG the macOS AppIcon set needs. Pure CoreGraphics/AppKit,
// no assets.
//
// Two variants are rendered (only the background gradient differs):
//   • AppIcon       — the release tile (teal→blue), used by the shipped "Workroom" app.
//   • AppIcon-Dev   — a warm amber→red tile so the Debug "Workroom Dev" build is obvious at a
//                     glance when both run side by side (see project.yml: Debug sets
//                     ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Dev).
//
// Usage:
//   swift Scripts/make-icon.swift [assets-dir]
// `assets-dir` defaults to WorkroomApp/Assets.xcassets relative to macapp/; each variant is
// written to its own <name>.appiconset under it.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

// Per-variant background gradient (the only thing that differs between release and dev).
struct Variant {
    let dirName: String   // <name>.appiconset under the assets dir
    let bgTop: CGColor    // top-left
    let bgBottom: CGColor // bottom-right
}
let variants = [
    Variant(dirName: "AppIcon.appiconset",
            bgTop: rgb(0x18, 0xE0, 0xC8), bgBottom: rgb(0x2E, 0x7D, 0xFF)),   // teal→blue (release)
    Variant(dirName: "AppIcon-Dev.appiconset",
            bgTop: rgb(0xFF, 0xB0, 0x2E), bgBottom: rgb(0xFF, 0x3D, 0x55)),   // amber→red (dev)
    Variant(dirName: "AppIcon-Nightly.appiconset",
            bgTop: rgb(0x9D, 0x5C, 0xFF), bgBottom: rgb(0x4B, 0x1F, 0xB8)),   // violet→indigo (nightly)
]

let cardBack = rgb(0xFF, 0xD2, 0x3F)  // yellow (deepest card)
let cardMid = rgb(0xFF, 0x6F, 0xB5)   // pink (middle card)
let cardFront = rgb(0xFF, 0xFF, 0xFF) // white (front card)
let chevron = rgb(0x2E, 0x7D, 0xFF)   // blue prompt chevron
let cursor = rgb(0xFF, 0x6F, 0xB5)    // pink block cursor

// MARK: - Geometry (fractions of the rounded tile)

let cardW: CGFloat = 0.66    // card edge as a fraction of the tile width
let offset: CGFloat = 0.055  // each card's diagonal step from the tile centre

// MARK: - Render

func render(_ pixels: Int, to url: URL, bgTop: CGColor, bgBottom: CGColor) {
    let S = CGFloat(pixels)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext") }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Flip to a top-left origin so the fractions above read naturally (y grows downward).
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)

    // --- Tile + soft contact shadow -------------------------------------------------
    let margin = S * 0.0975
    let tile = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let radius = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    // In the flipped CTM, a negative height pushes the shadow visually downward.
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
                  color: rgb(0x10, 0x06, 0x33, 0.40))
    ctx.addPath(tilePath)
    ctx.setFillColor(bgBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // --- Background gradient (clipped to the tile) ----------------------------------
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [bgTop, bgBottom] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: tile.minX, y: tile.minY),
                           end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])

    // Subtle top sheen for a glassy feel.
    let sheen = CGGradient(colorsSpace: cs,
                           colors: [rgb(0xFF, 0xFF, 0xFF, 0.16), rgb(0xFF, 0xFF, 0xFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: tile.minX, y: tile.minY),
                           end: CGPoint(x: tile.minX, y: tile.minY + tile.height * 0.55), options: [])

    // --- Cascading "room" cards -----------------------------------------------------
    func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + fx * tile.width, y: tile.minY + fy * tile.height)
    }
    let w = tile.width * cardW
    let cardRadius = w * 0.235
    let cardShadow = rgb(0x07, 0x2A, 0x55, 0.45)

    func card(center: CGPoint, fill: CGColor) {
        let r = CGRect(x: center.x - w / 2, y: center.y - w / 2, width: w, height: w)
        let path = CGPath(roundedRect: r, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.05), blur: w * 0.11, color: cardShadow)
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }
    card(center: pt(0.5 + offset, 0.5 - offset), fill: cardBack)
    card(center: pt(0.5, 0.5), fill: cardMid)
    let front = pt(0.5 - offset, 0.5 + offset)
    card(center: front, fill: cardFront)

    // --- Terminal prompt on the front card ------------------------------------------
    func fp(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        CGPoint(x: front.x + dx * w, y: front.y + dy * w)
    }
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // Blue chevron ">".
    ctx.setStrokeColor(chevron)
    ctx.setLineWidth(0.085 * w)
    ctx.move(to: fp(-0.26, -0.17))
    ctx.addLine(to: fp(-0.05, 0.0))
    ctx.addLine(to: fp(-0.26, 0.17))
    ctx.strokePath()
    // Pink block cursor.
    let cc = fp(0.16, 0.02)
    let cw = 0.17 * w
    let ch = 0.30 * w
    let cursorRect = CGRect(x: cc.x - cw / 2, y: cc.y - ch / 2, width: cw, height: ch)
    ctx.addPath(CGPath(roundedRect: cursorRect, cornerWidth: 0.035 * w, cornerHeight: 0.035 * w, transform: nil))
    ctx.setFillColor(cursor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.restoreGState()

    // --- Write PNG ------------------------------------------------------------------
    guard let image = ctx.makeImage() else { fatalError("makeImage") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try! png.write(to: url)
    print("  \(url.lastPathComponent)  (\(pixels)px)")
}

// MARK: - Menu bar glyph

// The status-bar item's icon (issue #33): a monochrome OUTLINE of the same three cascading "room"
// cards, on a transparent background — no tile, gradient, or terminal prompt (all illegible at
// 18px). Drawn back-to-front; each front card first knocks out (clears) the part of the card
// behind it, so the cascade reads as overlapping cards rather than a tangle of crossing strokes.
// Exported as a template image (see the imageset's Contents.json), so the system tints it to the
// menu bar's appearance and dims it when the app is inactive.
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

    let ink = rgb(0, 0, 0)  // template-rendered, so the system recolours it
    let margin = S * 0.13
    let content = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let edge = content.width * 0.54     // card edge
    let step = content.width * 0.17     // diagonal step between cards
    let radius = edge * 0.26            // matches the app icon's card corner ratio
    let stroke = max(1, S * 0.08)

    func cardRect(_ dx: CGFloat, _ dy: CGFloat) -> CGRect {
        CGRect(x: content.midX + dx - edge / 2, y: content.midY + dy - edge / 2, width: edge, height: edge)
    }
    // Back (up-right) → middle → front (down-left), echoing the app icon's cascade direction.
    let cards = [cardRect(step, step), cardRect(0, 0), cardRect(-step, -step)]

    ctx.setStrokeColor(ink)
    ctx.setLineWidth(stroke)
    ctx.setLineJoin(.round)

    for (i, r) in cards.enumerated() {
        if i > 0 {
            // Clear a filled rounded rect (grown by ~a stroke) so this card erases the outline of
            // the one behind where they overlap, leaving a clean "on top" edge.
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            let knock = r.insetBy(dx: -stroke * 0.9, dy: -stroke * 0.9)
            ctx.addPath(CGPath(
                roundedRect: knock, cornerWidth: radius + stroke, cornerHeight: radius + stroke,
                transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
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
        render(px, to: dir.appendingPathComponent(name), bgTop: variant.bgTop, bgBottom: variant.bgBottom)
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
