import AppKit
import XCTest

@testable import Workroom

@MainActor
final class MenuBarIconTests: XCTestCase {
  /// A 10pt square centred in an 18pt template image, so the ring's position is known.
  private let glyph: NSImage = {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      NSColor.black.setFill()
      NSRect(x: 4, y: 4, width: 10, height: 10).fill()
      return true
    }
    image.isTemplate = true
    return image
  }()

  /// Draws the highlighted icon at 2x under `appearance` and returns pixel `x` of the middle row.
  private func pixel(_ appearance: NSAppearance.Name, x: Int) -> NSColor {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 18, height: 18)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
      MenuBarController.highlighted(glyph).draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.colorAt(x: x, y: 18)!.usingColorSpace(.sRGB)!
  }

  func testTheShapeIsWorkroomYellowOnEitherBar() {
    for bar in [NSAppearance.Name.vibrantLight, .vibrantDark] {
      let centre = pixel(bar, x: 18)
      XCTAssertEqual(centre.redComponent, 1, accuracy: 0.02, "\(bar.rawValue)")
      XCTAssertEqual(centre.greenComponent, 0xEB / 255, accuracy: 0.02, "\(bar.rawValue)")
      XCTAssertEqual(centre.blueComponent, 0, accuracy: 0.02, "\(bar.rawValue)")
    }
  }

  /// The half point just left of the square's edge (pixel 7 of 36, the square starts at 8): a dark
  /// ring on a light bar, nothing on a dark one.
  func testOnlyALightBarGetsTheRing() {
    let light = pixel(.vibrantLight, x: 7)
    XCTAssertGreaterThan(light.alphaComponent, 0.2, "ringed on a light bar")
    XCTAssertLessThan(light.redComponent + light.greenComponent, 0.2, "and the ring is dark")
    XCTAssertEqual(pixel(.vibrantDark, x: 7).alphaComponent, 0, accuracy: 0.01)
  }
}
