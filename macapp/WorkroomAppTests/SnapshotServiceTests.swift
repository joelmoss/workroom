import AppKit
import XCTest

@testable import Workroom

/// `SnapshotService` + `SnapshotRegistry` (issue #132, T12): the plan/capture/crop pipeline, driven
/// with a stub capturer so nothing here touches ScreenCaptureKit, and offscreen plain `NSView`s so
/// nothing mounts a live `GhosttySurfaceView`.
@MainActor
final class SnapshotServiceTests: XCTestCase {

  /// A capturer that returns a canned image and records how often it ran. `beforeReturning` lets a test
  /// interleave a layout change between the plan and the delivery, which is the epoch guard's purpose.
  ///
  /// `contentRect` is derived from the window at capture time **in CG coordinates** — y-down, origin
  /// top-left — because that is what `SCContentFilter.contentRect` actually is. Handing this an AppKit
  /// frame instead puts every crop outside the image, which is exactly the confusion `SnapshotGeometry`
  /// exists to prevent.
  private final class FakeCapturer: SnapshotCapturing, @unchecked Sendable {
    let scale: CGFloat
    var calls = 0
    var beforeReturning: (@MainActor () -> Void)?

    init(scale: CGFloat) {
      self.scale = scale
    }

    @MainActor
    static func cgContentRect(of window: NSWindow) -> CGRect {
      let screenHeight = NSScreen.screens.first?.frame.height ?? window.frame.maxY
      return CGRect(
        x: window.frame.minX, y: screenHeight - window.frame.maxY,
        width: window.frame.width, height: window.frame.height)
    }

    func capture(window: NSWindow, maxLongEdge: CGFloat) async throws -> WindowCapture? {
      calls += 1
      let contentRect = await MainActor.run { Self.cgContentRect(of: window) }
      let w = Int(contentRect.width * scale)
      let h = Int(contentRect.height * scale)
      let context = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: w, height: h))
      let image = context.makeImage()!
      if let hook = beforeReturning { await MainActor.run { hook() } }
      return WindowCapture(image: image, contentRect: contentRect, scale: scale)
    }
  }

  private var windows: [NSWindow] = []

  override func tearDown() {
    for window in windows { window.orderOut(nil) }
    windows = []
    super.tearDown()
  }

  /// An on-screen window with `count` plain subviews registered as snapshot regions. Real views, real
  /// coordinate conversion — never a `GhosttySurfaceView`.
  private func window(regions count: Int, registry: SnapshotRegistry) -> (NSWindow, [SnapshotKey]) {
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    window.contentView = root
    window.orderFrontRegardless()
    windows.append(window)

    var keys: [SnapshotKey] = []
    let sliceWidth = 400 / CGFloat(max(1, count))
    for index in 0..<count {
      let view = NSView(
        frame: NSRect(x: sliceWidth * CGFloat(index), y: 0, width: sliceWidth, height: 300))
      root.addSubview(view)
      let key = SnapshotKey.pane(UUID())
      registry.register(view, for: key)
      keys.append(key)
    }
    return (window, keys)
  }

  private func makeService(_ capturer: SnapshotCapturing, registry: SnapshotRegistry)
    -> SnapshotService
  {
    SnapshotService(cache: SnapshotCache(), capturer: capturer, registry: registry)
  }

  // MARK: Registry

  func testRegistryReportsRectsInScreenCoordinates() {
    let registry = SnapshotRegistry()
    let (window, keys) = window(regions: 2, registry: registry)
    let reported = registry.regions(in: window)
    XCTAssertEqual(reported.count, 2)
    XCTAssertEqual(Set(reported.map(\.key)), Set(keys))
    for entry in reported {
      XCTAssertTrue(
        window.frame.intersects(entry.rect), "a reported rect must land inside its own window")
    }
  }

  func testRegistryIgnoresOtherWindowsAndPrunesDeadViews() {
    let registry = SnapshotRegistry()
    let (windowA, _) = window(regions: 2, registry: registry)
    let (windowB, _) = window(regions: 3, registry: registry)
    XCTAssertEqual(registry.regions(in: windowA).count, 2, "scoped to one window")
    XCTAssertEqual(registry.regions(in: windowB).count, 3)
    // Drop A's views: the weak reference is the real lifetime signal, not an explicit unregister.
    windowA.contentView = NSView()
    XCTAssertEqual(registry.regions(in: windowA).count, 0)
  }

  func testRegistrySkipsZeroSizedRegions() {
    let registry = SnapshotRegistry()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    window.contentView = root
    window.orderFrontRegardless()
    windows.append(window)
    let empty = NSView(frame: .zero)
    root.addSubview(empty)
    registry.register(empty, for: .pane(UUID()))
    XCTAssertTrue(registry.regions(in: window).isEmpty, "a collapsed pane has nothing to crop")
  }

  // MARK: Capture → crop → cache

  func testCapturePopulatesOneThumbnailPerRegion() async {
    let registry = SnapshotRegistry()
    let (window, keys) = window(regions: 2, registry: registry)
    let capturer = FakeCapturer(scale: 2)
    let service = makeService(capturer, registry: registry)

    service.capture(window: window, themeGeneration: 1)
    await settle()

    for key in keys {
      XCTAssertNotNil(service.snapshot(for: key, themeGeneration: 1), "\(key) got a thumbnail")
    }
  }

  func testThumbnailsAreDownscaledToTheWellNotStoredFullSize() async {
    let registry = SnapshotRegistry()
    let (window, keys) = window(regions: 1, registry: registry)
    let capturer = FakeCapturer(scale: 2)
    let service = makeService(capturer, registry: registry)
    service.capture(window: window, themeGeneration: 1)
    await settle()
    let image = service.snapshot(for: keys[0], themeGeneration: 1)
    XCTAssertNotNil(image)
    // Well is 72×56pt at 2× ⇒ nothing wider than 144px. Storing full-res crops would blow the byte cap
    // after a handful of panes for pictures drawn at 72×56.
    XCTAssertLessThanOrEqual(image!.width, 144)
  }

  func testAStaleThemeGenerationReadsAsAMiss() async {
    let registry = SnapshotRegistry()
    let (window, keys) = window(regions: 1, registry: registry)
    let service = makeService(FakeCapturer(scale: 2), registry: registry)
    service.capture(window: window, themeGeneration: 1)
    await settle()
    XCTAssertNotNil(service.snapshot(for: keys[0], themeGeneration: 1))
    XCTAssertNil(
      service.snapshot(for: keys[0], themeGeneration: 2),
      "after a theme change the cached picture is of the wrong colours")
  }

  // MARK: The guards

  func testAShotThatLandsAfterAnInvalidateIsDiscarded() async {
    // The epoch guard: a layout change between plan and delivery must throw the whole shot away rather
    // than crop old pixels against new rects — that is what would produce a MISLABELLED card.
    let registry = SnapshotRegistry()
    let (window, keys) = window(regions: 1, registry: registry)
    let capturer = FakeCapturer(scale: 2)
    let service = makeService(capturer, registry: registry)
    capturer.beforeReturning = { service.invalidate() }

    service.capture(window: window, themeGeneration: 1)
    await settle()
    XCTAssertNil(service.snapshot(for: keys[0], themeGeneration: 1), "stale shot discarded")
  }

  func testAShotThatLandsAfterTheWindowMovedIsDiscarded() async {
    let registry = SnapshotRegistry()
    let (window, keys) = window(regions: 1, registry: registry)
    let capturer = FakeCapturer(scale: 2)
    let service = makeService(capturer, registry: registry)
    capturer.beforeReturning = { window.setFrameOrigin(NSPoint(x: 600, y: 600)) }

    service.capture(window: window, themeGeneration: 1)
    await settle()
    XCTAssertNil(
      service.snapshot(for: keys[0], themeGeneration: 1),
      "the frame moved under the capture — every crop would be offset")
  }

  func testAMiniaturizedOrHiddenWindowIsNotCaptured() async {
    // A window on an inactive Space returns an all-black *successful* image, which "keep the old entry
    // on failure" would cache as the new truth. The gate is on visibility, before any capture.
    let registry = SnapshotRegistry()
    let (window, _) = window(regions: 1, registry: registry)
    let capturer = FakeCapturer(scale: 2)
    let service = makeService(capturer, registry: registry)
    window.orderOut(nil)
    service.capture(window: window, themeGeneration: 1)
    await settle()
    XCTAssertEqual(capturer.calls, 0, "not even attempted")
  }

  func testAWindowWithNoRegionsIsNotCaptured() async {
    let registry = SnapshotRegistry()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.orderFrontRegardless()
    windows.append(window)
    let capturer = FakeCapturer(scale: 2)
    let service = makeService(capturer, registry: registry)
    service.capture(window: window, themeGeneration: 1)
    await settle()
    XCTAssertEqual(capturer.calls, 0, "nothing to crop ⇒ no shot")
  }

  func testConcurrentRequestsForOneWindowCoalesce() async {
    let registry = SnapshotRegistry()
    let (window, _) = window(regions: 1, registry: registry)
    let capturer = FakeCapturer(scale: 2)
    let service = makeService(capturer, registry: registry)
    for _ in 0..<5 { service.capture(window: window, themeGeneration: 1) }
    await settle()
    XCTAssertEqual(capturer.calls, 1, "one in-flight shot per window, not five")
  }

  func testAFailingCapturerLeavesTheExistingThumbnailAlone() async {
    struct Failing: SnapshotCapturing {
      func capture(window: NSWindow, maxLongEdge: CGFloat) async throws -> WindowCapture? {
        struct Boom: Error {}
        throw Boom()
      }
    }
    let registry = SnapshotRegistry()
    let (window, keys) = window(regions: 1, registry: registry)
    let service = makeService(FakeCapturer(scale: 2), registry: registry)
    service.capture(window: window, themeGeneration: 1)
    await settle()
    XCTAssertNotNil(service.snapshot(for: keys[0], themeGeneration: 1))

    service.setCapturer(Failing())
    service.capture(window: window, themeGeneration: 1)
    await settle()
    XCTAssertNotNil(
      service.snapshot(for: keys[0], themeGeneration: 1),
      "a failed shot must not blank a card that already had a picture")
  }

  func testTheStubCapturerYieldsNoThumbnails() async {
    // The `railPreviews` opt-out path: cards fall back to their glyph wells.
    let registry = SnapshotRegistry()
    let (window, keys) = window(regions: 1, registry: registry)
    let service = makeService(StubSnapshotCapturer(), registry: registry)
    service.capture(window: window, themeGeneration: 1)
    await settle()
    XCTAssertNil(service.snapshot(for: keys[0], themeGeneration: 1))
  }

  func testForgetPanesDropsThumbnails() async {
    let registry = SnapshotRegistry()
    let (window, keys) = window(regions: 1, registry: registry)
    let service = makeService(FakeCapturer(scale: 2), registry: registry)
    service.capture(window: window, themeGeneration: 1)
    await settle()
    guard case .pane(let id) = keys[0] else { return XCTFail("key shape") }
    service.forgetPanes([id])
    XCTAssertNil(service.snapshot(for: keys[0], themeGeneration: 1))
  }

  func testInvalidateAllClearsEverything() async {
    let registry = SnapshotRegistry()
    let (window, keys) = window(regions: 2, registry: registry)
    let service = makeService(FakeCapturer(scale: 2), registry: registry)
    service.capture(window: window, themeGeneration: 1)
    await settle()
    service.invalidateAll()
    for key in keys { XCTAssertNil(service.snapshot(for: key, themeGeneration: 1)) }
  }

  /// Let the capture task run to completion. It hops to the main actor, so yielding is enough — no
  /// wall-clock sleep and no expectation timeout.
  private func settle() async {
    for _ in 0..<40 { await Task.yield() }
  }
}
