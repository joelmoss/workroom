import AppKit
import QuartzCore
import XCTest

@testable import Workroom

/// Coverage for the actual production `PreviewFrameSource` (Candidate A) — none of
/// `TerminalHoverPreviewControllerTests` exercise this, since they all inject a `FakeFrameSource` to
/// keep the state-machine tests fast/isolated. This file exists specifically because that split let a
/// real bug through: found via a real-mouse QA pass ("hover selected the tab, detail pane went empty"),
/// not caught by any automated test until this one.
@MainActor
final class TransformScaleFrameSourceTests: XCTestCase {
  private var window: NSWindow!

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(GhosttyApp.shared.app != nil, "requires the libghostty runtime")
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
      styleMask: [.titled], backing: .buffered, defer: true)
  }

  /// The regression: `TerminalContainerView.mount(in:)` only ever writes `wantsFocus` on whichever
  /// surface is CURRENTLY its `view:` — a backgrounded tab's surface keeps whatever stale value it had
  /// from when it was last actually active (typically `true`, from being the newly-focused tab at
  /// creation; nothing resets it when a solo tab is swapped away entirely). Mounting that surface into
  /// the preview host must not let a stale `true` steal first responder from whatever the real active
  /// view is via `viewDidMoveToWindow`'s `if wantsFocus, window.firstResponder !== self {
  /// window.makeFirstResponder(self) }`.
  func testMountNeverStealsFirstResponderFromCurrentlyFocusedView() {
    // The "hovered" surface — mounted once (as if it had been the active tab), leaving a stale
    // `wantsFocus == true`, matching what `TerminalContainerView.mount(in:)` would have set.
    let surface = GhosttySurfaceView(
      workingDirectory: NSTemporaryDirectory(), command: nil, spawnsSurface: true)
    surface.frame = window.contentView!.bounds
    window.contentView!.addSubview(surface)
    surface.wantsFocus = true
    defer { surface.tearDown() }

    // A different view stands in for the real, currently-active tab's surface.
    let activeView = NSView()
    window.contentView!.addSubview(activeView)
    XCTAssertTrue(window.makeFirstResponder(activeView))

    // Background the hovered surface (as `TerminalContainerView`'s detach-on-switch-away does), then
    // mount it into a preview host that's part of the same real window.
    surface.removeFromSuperview()
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 160))
    host.wantsLayer = true
    window.contentView!.addSubview(host)

    let source = TransformScaleFrameSource(scheduling: DispatchQueueScheduling())
    XCTAssertTrue(source.mount(surface: surface, host: host))

    XCTAssertFalse(
      surface.wantsFocus, "mount must clear a stale wantsFocus so it can never auto-claim focus")
    XCTAssertTrue(
      window.firstResponder === activeView,
      "mounting a hover preview must never steal first responder from the real active view")
  }

  func testMountScalesToFitAndNeverResizesTheSurface() {
    let surface = GhosttySurfaceView(
      workingDirectory: NSTemporaryDirectory(), command: nil, spawnsSurface: true)
    surface.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
    window.contentView!.addSubview(surface)
    defer { surface.tearDown() }
    let originalSize = surface.frame.size

    surface.removeFromSuperview()
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 160))
    host.wantsLayer = true
    window.contentView!.addSubview(host)

    let source = TransformScaleFrameSource(scheduling: DispatchQueueScheduling())
    XCTAssertTrue(source.mount(surface: surface, host: host))

    XCTAssertEqual(
      surface.frame.size, originalSize,
      "the critical finding's rule: mount must never write .frame.size — only .frame.origin")
    let transform = host.layer?.sublayerTransform ?? CATransform3DIdentity
    XCTAssertFalse(
      CATransform3DIsIdentity(transform),
      "the visual shrink must come from a compositing transform, not a geometry change")
  }

  /// The fill-scale regression: a 260×160 landscape envelope letterboxing a near-square pane left the
  /// content occupying well under half the box (found via real-mouse QA against a real 933×925.5 pane).
  /// `mount()` must shrink `host` itself to hug the scaled content's own aspect ratio, not force it
  /// into the full envelope with empty bars.
  func testMountShrinksHostToHugContentAspectWithNoLetterboxing() {
    let surface = GhosttySurfaceView(
      workingDirectory: NSTemporaryDirectory(), command: nil, spawnsSurface: true)
    surface.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    window.contentView!.addSubview(surface)
    defer { surface.tearDown() }

    surface.removeFromSuperview()
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 160))
    host.wantsLayer = true
    window.contentView!.addSubview(host)

    let source = TransformScaleFrameSource(scheduling: DispatchQueueScheduling())
    XCTAssertTrue(source.mount(surface: surface, host: host))

    // A 400×400 square fit inside a 260×160 envelope is height-constrained: scale = 160/400 = 0.4,
    // so the tight-fit box is 160×160 — no leftover width or height bars.
    XCTAssertEqual(host.frame.width, 160, accuracy: 0.001)
    XCTAssertEqual(host.frame.height, 160, accuracy: 0.001)
    XCTAssertEqual(
      surface.frame, NSRect(origin: .zero, size: NSSize(width: 400, height: 400)),
      "the surface itself is still never resized — only host shrinks to match")
  }

  /// The blank-panel regression: clicking the previewed tab's chip while its preview is still open
  /// re-homes the surface into the REAL container (`TerminalContainerView.mount(in:)`) before the
  /// hover ends. When teardown finally runs, `unmount()` must not rip the surface back out of that
  /// new, legitimate home (found via real-mouse QA: "clicking a tab while the preview is open just
  /// shows a blank detail panel").
  func testUnmountDoesNotDetachASurfaceAlreadyReHomedElsewhere() {
    let surface = GhosttySurfaceView(
      workingDirectory: NSTemporaryDirectory(), command: nil, spawnsSurface: true)
    surface.frame = window.contentView!.bounds
    window.contentView!.addSubview(surface)
    defer { surface.tearDown() }
    surface.removeFromSuperview()

    let host = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 160))
    host.wantsLayer = true
    window.contentView!.addSubview(host)
    let source = TransformScaleFrameSource(scheduling: DispatchQueueScheduling())
    XCTAssertTrue(source.mount(surface: surface, host: host))

    // Someone else (a real focus/tab switch) claims the surface before this preview session tears
    // down.
    let realContainer = NSView()
    window.contentView!.addSubview(realContainer)
    surface.removeFromSuperview()
    realContainer.addSubview(surface)

    source.unmount()

    XCTAssertTrue(
      surface.superview === realContainer,
      "unmount must not detach a surface that's already been legitimately re-homed elsewhere")
  }
}
