import AppKit
import XCTest

@testable import Workroom

// MARK: - Fakes (the injected Scheduling/FrameSource seam, Tension 2)

private final class FakeCancellable: PreviewCancellable {
  private(set) var cancelled = false
  func cancel() { cancelled = true }
}

/// Captures every scheduled block instead of running it — tests fire them explicitly, so the dwell
/// and settle delays never actually need to elapse.
private final class FakeScheduling: PreviewScheduling {
  private(set) var entries: [(cancellable: FakeCancellable, block: () -> Void)] = []

  func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> PreviewCancellable {
    let cancellable = FakeCancellable()
    entries.append((cancellable, block))
    return cancellable
  }

  /// Fires the most recently scheduled block, if it hasn't been cancelled.
  func fireLast() {
    guard let entry = entries.last, !entry.cancellable.cancelled else { return }
    entry.block()
  }
}

private final class FakeFrameSource: PreviewFrameSource {
  var mountResult = true
  private(set) var mountCalled = false
  private(set) var unmountCalled = false
  private(set) var stopPresentingCalled = false
  private var onFirstFrame: (() -> Void)?

  func mount(surface: GhosttySurfaceView, host: NSView) -> Bool {
    mountCalled = true
    return mountResult
  }

  func startPresenting(onFirstFrame: @escaping () -> Void) {
    self.onFirstFrame = onFirstFrame
  }

  /// Fires the `onFirstFrame` callback passed to `startPresenting`, if any.
  func fireFirstFrame() {
    onFirstFrame?()
  }

  func stopPresenting() {
    stopPresentingCalled = true
  }

  func unmount() {
    unmountCalled = true
  }
}

@MainActor
final class TerminalHoverPreviewControllerTests: XCTestCase {
  private let target = TerminalTarget(
    id: "wr|/p|hover", title: "hover", path: "/tmp", isMissing: false)
  private var window: NSWindow!
  /// Every real surface created via `makeSessions()`'s factory, torn down in `tearDown()` — each one
  /// spawns a real shell (`spawnsSurface: true`, needed for `hasSurface`/`isPreviewEligible` to ever be
  /// true), so cleanup here matters the same way it does in production (no orphaned shells).
  private var createdSurfaces: [GhosttySurfaceView] = []

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(GhosttyApp.shared.app != nil, "requires the libghostty runtime")
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
      styleMask: [.titled], backing: .buffered, defer: true)
  }

  override func tearDown() {
    for surface in createdSurfaces { surface.tearDown() }
    createdSurfaces = []
    super.tearDown()
  }

  /// A `TerminalSessions` whose surfaces are pre-attached to a real (offscreen) window with a REAL
  /// spawned surface (`spawnsSurface: true`) — the controller's `armHover` gates on
  /// `isPreviewEligible`/`hasSurface`, which reflects a genuine `ghostty_surface_t`, not just a mounted
  /// `NSView`. Requires the libghostty runtime to be ready in the test host — skip-gated by the one
  /// caller that constructs sessions this way, matching `TerminalFocusAdoptionLiveSurfaceTests`'
  /// precedent (a skipped test beats a flaky one).
  ///
  /// Also mimics `TerminalContainerView`'s real mount/detach behavior via `onFocusChange`: production
  /// keeps only the currently-focused/visible tab's surface attached to a window — every OTHER tab's
  /// surface is detached (`superview == nil`). Earlier versions of this fixture attached every surface
  /// permanently, which is exactly the unrealistic setup that let a real bug through undetected: `mount()`
  /// used to `guard let superview = surface.superview else { return }`, silently no-oping for every
  /// genuinely-backgrounded tab (found via a real-mouse hover test showing nothing at all — no crash, no
  /// log — after this test suite had already gone green against the too-generous old fixture).
  private func makeSessions() -> TerminalSessions {
    let sessions = TerminalSessions()
    sessions.makeView = { [window, weak self] _, cwd, _ in
      let view = GhosttySurfaceView(workingDirectory: cwd, command: nil, spawnsSurface: true)
      view.frame = window!.contentView!.bounds
      window!.contentView!.addSubview(view)
      self?.createdSurfaces.append(view)
      return view
    }
    var previouslyFocused: TerminalTab.ID?
    sessions.onFocusChange = { [weak sessions, target] _, newFocusedID in
      if let previouslyFocused, previouslyFocused != newFocusedID {
        sessions?.tab(previouslyFocused, for: target)?.surface?.removeFromSuperview()
      }
      previouslyFocused = newFocusedID
    }
    return sessions
  }

  private func makeController(
    sessions: TerminalSessions, scheduling: FakeScheduling, frameSource: FakeFrameSource
  )
    -> TerminalHoverPreviewController
  {
    TerminalHoverPreviewController(
      sessions: sessions, scheduling: scheduling, dwell: 0.4, makeFrameSource: { frameSource })
  }

  // MARK: Gates

  func testArmHoverDoesNothingForAlreadyVisibleTab() {
    let sessions = makeSessions()
    let focused = sessions.addTab(for: target)  // focused == visible
    let scheduling = FakeScheduling()
    let controller = makeController(
      sessions: sessions, scheduling: scheduling, frameSource: FakeFrameSource())

    controller.armHover(tab: focused, target: target)

    XCTAssertEqual(controller.phase, .idle, "an already-visible tab must never arm")
    XCTAssertTrue(scheduling.entries.isEmpty, "no dwell timer should be scheduled")
  }

  func testArmHoverDoesNothingWithoutASurface() {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, _ in
      // Never attached to a window, so its surface stays nil.
      GhosttySurfaceView(workingDirectory: cwd, command: nil, spawnsSurface: false)
    }
    let focusedDummy = sessions.addTab(for: target)
    let background = sessions.addTab(for: target)
    sessions.focus(focusedDummy.id, for: target)
    let scheduling = FakeScheduling()
    let controller = makeController(
      sessions: sessions, scheduling: scheduling, frameSource: FakeFrameSource())

    controller.armHover(tab: background, target: target)

    XCTAssertEqual(controller.phase, .idle, "a tab with no live surface must never arm")
    XCTAssertTrue(scheduling.entries.isEmpty)
  }

  // MARK: Happy path

  func testFullHoverCycleMountsPresentsAndTearsDown() {
    let sessions = makeSessions()
    let focused = sessions.addTab(for: target)
    let background = sessions.addTab(for: target)
    sessions.focus(focused.id, for: target)
    let scheduling = FakeScheduling()
    let frameSource = FakeFrameSource()
    let controller = makeController(
      sessions: sessions, scheduling: scheduling, frameSource: frameSource)

    controller.armHover(tab: background, target: target)
    XCTAssertEqual(controller.phase, .armed(tabID: background.id))
    XCTAssertFalse(frameSource.mountCalled, "must not mount before the dwell elapses")

    scheduling.fireLast()  // dwell elapses → resolve → mount
    XCTAssertTrue(frameSource.mountCalled)
    XCTAssertEqual(
      background.surface?.isPaneVisibleForTesting, true,
      "beginPreview must have un-occluded the background tab")
    XCTAssertNotNil(controller.previewHost)

    // The settle callback from startPresenting (not scheduling-routed).
    frameSource.fireFirstFrame()
    XCTAssertEqual(controller.phase, .visible(tabID: background.id))

    controller.cancelHover()  // hover ends
    XCTAssertEqual(controller.phase, .idle)
    XCTAssertTrue(frameSource.stopPresentingCalled)
    XCTAssertTrue(frameSource.unmountCalled)
    XCTAssertNil(controller.previewHost)
    XCTAssertEqual(
      background.surface?.isPaneVisibleForTesting, false,
      "endPreview must have re-occluded the background tab on teardown")
  }

  // MARK: Cancellation / supersession

  func testCancelHoverDuringDwellNeverMounts() {
    let sessions = makeSessions()
    let focused = sessions.addTab(for: target)
    let background = sessions.addTab(for: target)
    sessions.focus(focused.id, for: target)
    let scheduling = FakeScheduling()
    let frameSource = FakeFrameSource()
    let controller = makeController(
      sessions: sessions, scheduling: scheduling, frameSource: frameSource)

    controller.armHover(tab: background, target: target)
    controller.cancelHover()  // mouse left before the dwell fired

    scheduling.fireLast()  // the (cancelled) dwell work, if it somehow ran anyway
    XCTAssertFalse(frameSource.mountCalled, "a cancelled dwell must never mount")
    XCTAssertEqual(controller.phase, .idle)
  }

  func testArmingANewHoverSupersedesTheStaleOne() {
    let sessions = makeSessions()
    let focused = sessions.addTab(for: target)
    let backgroundA = sessions.addTab(for: target)
    let backgroundB = sessions.addTab(for: target)
    sessions.focus(focused.id, for: target)
    let scheduling = FakeScheduling()
    let frameSource = FakeFrameSource()
    let controller = makeController(
      sessions: sessions, scheduling: scheduling, frameSource: frameSource)

    controller.armHover(tab: backgroundA, target: target)
    let staleGeneration = scheduling.entries.last!
    // B supersedes A before A's dwell fired.
    controller.armHover(tab: backgroundB, target: target)

    // A's stale dwell work fires anyway (simulates a race, not just a cancel).
    staleGeneration.block()
    XCTAssertFalse(
      frameSource.mountCalled, "A's superseded dwell must be a no-op even if it manages to fire")

    scheduling.fireLast()  // B's own dwell
    XCTAssertTrue(frameSource.mountCalled)
    XCTAssertEqual(
      controller.phase, .armed(tabID: backgroundB.id), "mount doesn't change phase yet")
    // The observable proxy for "B, not A, was mounted": beginPreview un-occludes exactly one tab.
    XCTAssertEqual(backgroundB.surface?.isPaneVisibleForTesting, true)
    XCTAssertEqual(backgroundA.surface?.isPaneVisibleForTesting, false)
  }

  // MARK: Failure routing (eng review Codex #3 — a stale/failed step must clean up, not just no-op)

  func testMountFailureRoutesToIdleWithoutLeavingStatePartiallySet() {
    let sessions = makeSessions()
    let focused = sessions.addTab(for: target)
    let background = sessions.addTab(for: target)
    sessions.focus(focused.id, for: target)
    let scheduling = FakeScheduling()
    let frameSource = FakeFrameSource()
    frameSource.mountResult = false
    let controller = makeController(
      sessions: sessions, scheduling: scheduling, frameSource: frameSource)

    controller.armHover(tab: background, target: target)
    scheduling.fireLast()

    XCTAssertEqual(controller.phase, .idle)
    XCTAssertNil(controller.previewHost)
    XCTAssertEqual(
      background.surface?.isPaneVisibleForTesting, false,
      "a failed mount must never have un-occluded the tab")
  }

  // MARK: Tab closed mid-hover

  func testTabClosedMidDwellNeverMounts() {
    let sessions = makeSessions()
    let focused = sessions.addTab(for: target)
    let background = sessions.addTab(for: target)
    sessions.focus(focused.id, for: target)
    let scheduling = FakeScheduling()
    let frameSource = FakeFrameSource()
    let controller = makeController(
      sessions: sessions, scheduling: scheduling, frameSource: frameSource)

    controller.armHover(tab: background, target: target)
    sessions.closeTab(background.id, for: target)

    scheduling.fireLast()
    XCTAssertFalse(frameSource.mountCalled, "a tab closed mid-dwell must never be mounted")
    XCTAssertEqual(controller.phase, .idle)
  }
}
