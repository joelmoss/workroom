import CoreGraphics
import XCTest

@testable import Workroom

/// `SnapshotGeometry` (issue #132, T12): the pixel arithmetic that turns one window capture into N pane
/// thumbnails.
///
/// These tests exist because the plan's original crop recipe was **wrong in two independent ways** and
/// the T1 spike measured it. The measured configuration is pinned below verbatim: a fixture where
/// `contentRect.size == frame.size` passes a wrong implementation, so it must not be the only case.
final class SnapshotGeometryTests: XCTestCase {

  // The T1 spike's measured numbers (macOS 26.5.2, 2× display).
  //   NSWindow.frame      (200, 200, 820, 552)  AppKit, y-up
  //   filter.contentRect  (205, 872, 810, 544)  CG, y-down, inset ~5pt x / ~4pt y
  //   captured image       1620 × 1088  ==  contentRect × pointPixelScale(2.0), exactly
  private let windowFrame = CGRect(x: 200, y: 200, width: 820, height: 552)
  private let contentRect = CGRect(x: 205, y: 872, width: 810, height: 544)
  private let scale: CGFloat = 2.0
  /// The y-flip constant that makes the measured pair consistent: `contentRect.minY` = H − frame.maxY − inset.
  private let mainScreenHeight: CGFloat = 1624

  // MARK: The measured case

  func testTheCaptureIsExactlyContentRectTimesScaleNotTheFrame() {
    let fromContent = SnapshotGeometry.capturePixelSize(
      contentRect: contentRect, scale: scale, maxLongEdge: 4000)
    XCTAssertEqual(
      fromContent, CGSize(width: 1620, height: 1088), "the spike measured exactly this")
    // The trap: sizing from the window frame instead gives a different image, and every crop taken
    // from it is then off by a scale factor of 1.9756/1.9710 rather than 2.0.
    let fromFrame = SnapshotGeometry.capturePixelSize(
      contentRect: windowFrame, scale: scale, maxLongEdge: 4000)
    XCTAssertNotEqual(
      fromFrame, fromContent, "contentRect is NOT the window frame — in size either")
  }

  func testARegionSpanningTheWholeContentRectMapsToTheWholeImage() {
    // Express the content rect back in AppKit screen coordinates and crop it: the result must be the
    // entire image, which is only true if the reference rect and the single y-flip are both right.
    let regionOnScreen = CGRect(
      x: contentRect.minX, y: mainScreenHeight - contentRect.maxY,
      width: contentRect.width, height: contentRect.height)
    let crop = SnapshotGeometry.cropRect(
      regionOnScreen: regionOnScreen, windowContentRect: contentRect,
      mainScreenHeight: mainScreenHeight, scale: scale)
    XCTAssertEqual(crop, CGRect(x: 0, y: 0, width: 1620, height: 1088))
  }

  func testTheYFlipsDoNotCancel() {
    // A region in the TOP half of the window must crop from the TOP of the image (small y in CG).
    // Getting the flip wrong is silent: the crop is a valid rect, just of the wrong pane.
    let topHalf = CGRect(
      x: contentRect.minX, y: mainScreenHeight - contentRect.maxY + contentRect.height / 2,
      width: contentRect.width, height: contentRect.height / 2)
    let crop = SnapshotGeometry.cropRect(
      regionOnScreen: topHalf, windowContentRect: contentRect,
      mainScreenHeight: mainScreenHeight, scale: scale)
    XCTAssertEqual(crop?.minY, 0, "the top of the window is y=0 in the capture")
    XCTAssertEqual(crop?.height, 544, "half the window, in pixels")
  }

  func testABottomRegionCropsFromTheBottomOfTheImage() {
    let bottomHalf = CGRect(
      x: contentRect.minX, y: mainScreenHeight - contentRect.maxY,
      width: contentRect.width, height: contentRect.height / 2)
    let crop = SnapshotGeometry.cropRect(
      regionOnScreen: bottomHalf, windowContentRect: contentRect,
      mainScreenHeight: mainScreenHeight, scale: scale)
    XCTAssertEqual(crop?.minY, 544)
    XCTAssertEqual(crop?.maxY, 1088)
  }

  func testASplitPanesTwoHalvesTileTheImageExactly() {
    // The real use: two side-by-side panes must partition the capture with no gap and no overlap.
    let leftOnScreen = CGRect(
      x: contentRect.minX, y: mainScreenHeight - contentRect.maxY,
      width: contentRect.width / 2, height: contentRect.height)
    let rightOnScreen = leftOnScreen.offsetBy(dx: contentRect.width / 2, dy: 0)
    let left = SnapshotGeometry.cropRect(
      regionOnScreen: leftOnScreen, windowContentRect: contentRect,
      mainScreenHeight: mainScreenHeight, scale: scale)
    let right = SnapshotGeometry.cropRect(
      regionOnScreen: rightOnScreen, windowContentRect: contentRect,
      mainScreenHeight: mainScreenHeight, scale: scale)
    XCTAssertEqual(left?.maxX, right?.minX, "no seam and no overlap between split members")
    XCTAssertEqual(left?.width, 810)
    XCTAssertEqual(right?.maxX, 1620)
  }

  // MARK: Degenerate inputs

  func testARegionOutsideTheCaptureIsNil() {
    let offscreen = CGRect(x: 5000, y: 5000, width: 100, height: 100)
    XCTAssertNil(
      SnapshotGeometry.cropRect(
        regionOnScreen: offscreen, windowContentRect: contentRect,
        mainScreenHeight: mainScreenHeight, scale: scale),
      "a pane scrolled out of the window yields no crop, not a bogus rect")
  }

  func testAPartiallyOffscreenRegionIsClampedToTheImage() {
    // Straddling the leading edge: keep the visible part rather than reading out of bounds.
    let straddling = CGRect(
      x: contentRect.minX - 100, y: mainScreenHeight - contentRect.maxY,
      width: 300, height: contentRect.height)
    let crop = SnapshotGeometry.cropRect(
      regionOnScreen: straddling, windowContentRect: contentRect,
      mainScreenHeight: mainScreenHeight, scale: scale)
    XCTAssertEqual(crop?.minX, 0, "clamped, never negative")
    XCTAssertEqual(crop?.width, 400, "only the 200pt that overlaps, at 2×")
  }

  func testZeroScaleAndEmptyRectsAreRejected() {
    let region = CGRect(x: 205, y: 200, width: 100, height: 100)
    XCTAssertNil(
      SnapshotGeometry.cropRect(
        regionOnScreen: region, windowContentRect: contentRect, mainScreenHeight: mainScreenHeight,
        scale: 0))
    XCTAssertNil(
      SnapshotGeometry.cropRect(
        regionOnScreen: .zero, windowContentRect: contentRect,
        mainScreenHeight: mainScreenHeight, scale: scale))
    XCTAssertNil(
      SnapshotGeometry.cropRect(
        regionOnScreen: region, windowContentRect: .zero, mainScreenHeight: mainScreenHeight,
        scale: scale))
  }

  // MARK: Capture sizing

  func testCaptureSizeIsCappedButStaysStrictlyProportional() {
    let big = CGRect(x: 0, y: 0, width: 3000, height: 1000)
    let size = SnapshotGeometry.capturePixelSize(contentRect: big, scale: 2, maxLongEdge: 1440)
    XCTAssertEqual(max(size.width, size.height), 1440, "long edge capped")
    // A mismatched aspect letterboxes and silently misaligns every crop, so the ratio must survive.
    XCTAssertEqual(size.width / size.height, 3, accuracy: 0.01)
  }

  func testASmallWindowIsNotUpscaled() {
    let small = CGRect(x: 0, y: 0, width: 400, height: 300)
    let size = SnapshotGeometry.capturePixelSize(contentRect: small, scale: 2, maxLongEdge: 1440)
    XCTAssertEqual(size, CGSize(width: 800, height: 600))
  }

  // MARK: Thumbnail sizing

  func testThumbnailAspectFitsWithoutCropping() {
    // A wide window into a 72×56 well: width binds, height comes out short — letterboxed, not cropped.
    let size = SnapshotGeometry.thumbnailPixelSize(
      source: CGSize(width: 1620, height: 1088), maxPointSize: CGSize(width: 72, height: 56),
      scale: 2)
    XCTAssertEqual(size.width, 144, "the binding edge fills the well")
    XCTAssertLessThanOrEqual(size.height, 112)
    XCTAssertEqual(size.width / size.height, 1620 / 1088, accuracy: 0.02, "aspect preserved")
  }

  func testATinySourceIsNotUpscaled() {
    let size = SnapshotGeometry.thumbnailPixelSize(
      source: CGSize(width: 40, height: 30), maxPointSize: CGSize(width: 72, height: 56), scale: 2)
    XCTAssertEqual(size, CGSize(width: 40, height: 30), "never blown up past 1:1")
  }

  func testThumbnailOfAnEmptySourceIsZero() {
    XCTAssertEqual(
      SnapshotGeometry.thumbnailPixelSize(
        source: .zero, maxPointSize: CGSize(width: 72, height: 56), scale: 2), .zero)
  }
}
