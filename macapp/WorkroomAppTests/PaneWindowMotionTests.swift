import AppKit
import CoreImage
import IOSurface
import SwiftUI
import XCTest

@testable import Workroom

/// The pop out and pull back of a pane (issue #172): where each starts and ends, the Reduce Motion
/// choice, and that one cut short ends exactly once, at its end. The timing runs through a hand-
/// driven animator, so nothing here waits on a real animation.
@MainActor
final class PaneWindowMotionTests: XCTestCase {
  private let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
  /// A second screen to the left of and above the primary's origin.
  private let secondary = NSRect(x: -1920, y: 200, width: 1920, height: 1080)
  private let final = NSRect(x: 300, y: 200, width: 800, height: 528)

  /// A hosted unit run's pane windows move without animating; an app's animate.
  func testOnlyAHostedUnitRunTurnsTheMotionOff() {
    XCTAssertTrue(AppEnvironment.animatesPaneWindows(environment: [:]))
    XCTAssertFalse(
      AppEnvironment.animatesPaneWindows(environment: ["XCTestConfigurationFilePath": "x"]))
    XCTAssertFalse(DetachedPaneWindows().animates, "this run is a hosted one")
  }

  // MARK: Frames

  func testAPopOutGrowsFromTheSlotToTheFrameItOpensAt() {
    let slot = NSRect(x: 40, y: 60, width: 400, height: 300)
    let plan = PaneWindowMotion.popOut(
      slot: slot, final: final, pointer: CGPoint(x: 300, y: 728), byDrag: false,
      reduceMotion: false, screens: [primary])

    XCTAssertEqual(plan.start, slot)
    XCTAssertEqual(plan.end, final)
    XCTAssertEqual(plan.startAlpha, 1, "the snapshot covers the slot exactly as it leaves")
    XCTAssertEqual(plan.endAlpha, 1)
    XCTAssertEqual(plan.curve, .spring(PaneWindowMotion.Tuning.popOutSpring))
    XCTAssertEqual(plan.duration, 0.38)
  }

  func testASlotOnASecondaryScreenIsWhereItIs() {
    let slot = NSRect(x: -1500, y: 400, width: 600, height: 400)
    let plan = PaneWindowMotion.popOut(
      slot: slot, final: final, pointer: nil, byDrag: false, reduceMotion: false,
      screens: [primary, secondary])

    XCTAssertEqual(plan.start, slot, "negative coordinates are a screen, not off-screen")
  }

  func testASlotPartlyOffScreenIsNotClamped() {
    let slot = NSRect(x: 1200, y: 100, width: 600, height: 400)
    let plan = PaneWindowMotion.pullBack(
      window: final, slot: slot, reduceMotion: false, screens: [primary])

    XCTAssertEqual(plan.end, slot, "it lands on the pane, off-screen part and all")
  }

  func testASlotOffEveryScreenFadesInPlace() {
    let slot = NSRect(x: 5000, y: 5000, width: 600, height: 400)
    let popOut = PaneWindowMotion.popOut(
      slot: slot, final: final, pointer: nil, byDrag: false, reduceMotion: false,
      screens: [primary, secondary])
    let pullBack = PaneWindowMotion.pullBack(
      window: final, slot: slot, reduceMotion: false, screens: [primary, secondary])

    XCTAssertFalse(popOut.moves)
    XCTAssertFalse(pullBack.moves)
    XCTAssertEqual(pullBack.endAlpha, 0)
  }

  func testAWindowRectConvertsToTheScreenItIsOn() {
    let windowFrame = NSRect(x: -1800, y: 300, width: 1200, height: 800)
    let inWindow = NSRect(x: 10, y: 20, width: 300, height: 200)

    XCTAssertEqual(
      PaneWindowMotion.screenRect(of: inWindow, windowFrame: windowFrame),
      NSRect(x: -1790, y: 320, width: 300, height: 200))
  }

  func testADragOutScalesUpAboutThePointer() {
    let pointer = CGPoint(x: final.minX, y: final.maxY)
    let plan = PaneWindowMotion.popOut(
      slot: NSRect(x: 40, y: 60, width: 400, height: 300), final: final, pointer: pointer,
      byDrag: true, reduceMotion: false, screens: [primary])

    XCTAssertEqual(plan.end, final)
    XCTAssertEqual(plan.start.width, final.width * 0.85, accuracy: 0.001)
    XCTAssertEqual(plan.start.height, final.height * 0.85, accuracy: 0.001)
    XCTAssertEqual(plan.start.minX, pointer.x, accuracy: 0.001, "the pointer keeps its place")
    XCTAssertEqual(plan.start.maxY, pointer.y, accuracy: 0.001)
    XCTAssertEqual(plan.startAlpha, 0, "it fades in where the drag's ghost was")
  }

  func testAPullBackShrinksIntoTheSlotFullyOpaque() {
    let slot = NSRect(x: 40, y: 60, width: 400, height: 300)
    let plan = PaneWindowMotion.pullBack(
      window: final, slot: slot, reduceMotion: false, screens: [primary])

    XCTAssertEqual(plan.start, final)
    XCTAssertEqual(plan.end, slot)
    XCTAssertEqual(plan.curve, .spring(PaneWindowMotion.Tuning.pullBackSpring))
    XCTAssertEqual(plan.duration, 0.32)
    for t in stride(from: 0.0, through: plan.duration, by: 0.01) {
      XCTAssertEqual(plan.pose(at: t).alpha, 1, "no dip in opacity at \(t)s: it fades once landed")
    }
  }

  // MARK: Springs

  /// The pull back's spring is critically damped: it closes in on the slot without ever passing
  /// it, and is exactly there once it settles.
  func testThePullBackSpringNeverOvershootsAndSettles() {
    let spring = PaneWindowMotion.Tuning.pullBackSpring
    var last = 0.0
    for t in stride(from: 0.0, through: spring.settle, by: 0.002) {
      let value = spring.value(at: t)
      XCTAssertLessThanOrEqual(value, 1, "never past the slot, at \(t)s")
      XCTAssertGreaterThanOrEqual(value, last - 1e-12, "always closing in, at \(t)s")
      last = value
    }
    XCTAssertGreaterThan(spring.value(at: spring.settle - 0.001), 0.998, "settled by 0.32s")
    XCTAssertEqual(spring.value(at: spring.settle), 1)
  }

  /// The pop out's spring overshoots its frame by 2 to 3% of the way it travels, once, then
  /// settles exactly on it.
  func testThePopOutSpringOvershootsSlightlyThenSettles() {
    let spring = PaneWindowMotion.Tuning.popOutSpring
    var peak = 0.0
    for t in stride(from: 0.0, through: spring.settle, by: 0.001) {
      peak = max(peak, spring.value(at: t))
    }
    XCTAssertGreaterThanOrEqual(peak, 1.02)
    XCTAssertLessThanOrEqual(peak, 1.03)
    XCTAssertEqual(spring.value(at: spring.settle - 0.001), 1, accuracy: 0.003, "settled by 0.38s")
    XCTAssertEqual(spring.value(at: spring.settle), 1)

    // On a plan the frame follows it past the window, but opacity and crossfade stop at theirs.
    let plan = PaneWindowMotion.popOut(
      slot: NSRect(x: 40, y: 60, width: 400, height: 300), final: final, pointer: nil,
      byDrag: false, reduceMotion: false, screens: [primary])
    var widest: CGFloat = 0
    for t in stride(from: 0.0, through: plan.duration, by: 0.001) {
      let pose = plan.pose(at: t)
      widest = max(widest, pose.frame.width)
      XCTAssertLessThanOrEqual(pose.progress, 1)
    }
    XCTAssertGreaterThan(widest, final.width, "it grows a little past the window")
    XCTAssertLessThan(widest, final.width + (final.width - 400) * 0.031)
    XCTAssertEqual(plan.pose(at: plan.duration), plan.endPose, "and lands exactly on it")
  }

  // MARK: Reduce Motion

  func testReduceMotionCrossfadesWithoutMoving() {
    let slot = NSRect(x: 40, y: 60, width: 400, height: 300)
    for byDrag in [false, true] {
      let popOut = PaneWindowMotion.popOut(
        slot: slot, final: final, pointer: CGPoint(x: 300, y: 728), byDrag: byDrag,
        reduceMotion: true, screens: [primary])
      XCTAssertEqual(popOut.start, final)
      XCTAssertEqual(popOut.end, final)
      XCTAssertEqual(popOut.startAlpha, 0)
      XCTAssertEqual(popOut.endAlpha, 1)
      XCTAssertEqual(popOut.duration, 0.15)
    }
    let pullBack = PaneWindowMotion.pullBack(
      window: final, slot: slot, reduceMotion: true, screens: [primary])
    XCTAssertFalse(pullBack.moves)
    XCTAssertEqual(pullBack.endAlpha, 0)
    XCTAssertEqual(pullBack.duration, 0.15)
  }

  func testThePlaceholderFadesWithTheTransition() {
    XCTAssertEqual(PaneWindowMotion.placeholderFade(appearing: true, reduceMotion: false), 0.2)
    XCTAssertEqual(PaneWindowMotion.placeholderFade(appearing: false, reduceMotion: false), 0.08)
    XCTAssertEqual(PaneWindowMotion.placeholderFade(appearing: true, reduceMotion: true), 0.15)
    XCTAssertEqual(PaneWindowMotion.placeholderFade(appearing: false, reduceMotion: true), 0.15)
  }

  // MARK: Transitions

  func testATransitionEndsAtItsEndWhenItsAnimationCompletes() {
    let surface = FakeSurface()
    let animator = ManualAnimator()
    var ends: [Bool] = []
    let plan = movingPlan()
    let transition = PaneWindowTransition(
      kind: .popOut, plan: plan, surface: surface, animator: animator
    ) { ends.append($0) }

    transition.start()
    XCTAssertEqual(surface.frame, plan.start)
    XCTAssertEqual(surface.pose?.progress, 0, "it starts as what it leaves")
    animator.advance(to: 0.1)
    XCTAssertEqual(surface.pose, plan.pose(at: 0.1), "each frame draws the plan's pose")
    XCTAssertEqual(ends, [], "nothing ends until the clock runs out")

    animator.complete()

    XCTAssertEqual(ends, [false])
    XCTAssertEqual(surface.frame, plan.end)
    XCTAssertEqual(surface.tearDowns, [PaneWindowMotion.Tuning.cardFadeOut])
  }

  /// A milestone runs once, when the clock passes its fraction, and one never reached runs as the
  /// transition is cut short.
  func testMilestonesRunOnceAtTheirFraction() {
    let animator = ManualAnimator()
    let plan = movingPlan()
    var reached: [String] = []
    let transition = PaneWindowTransition(
      kind: .popOut, plan: plan, surface: FakeSurface(), animator: animator,
      milestones: [(0.4, { reached.append("lifted") }), (0.9, { reached.append("late") })]
    ) { _ in reached.append("end") }
    transition.start()

    animator.advance(to: plan.duration * 0.39)
    XCTAssertEqual(reached, [])
    animator.advance(to: plan.duration * 0.41)
    XCTAssertEqual(reached, ["lifted"])
    animator.advance(to: plan.duration * 0.5)
    transition.finish()
    animator.complete()

    XCTAssertEqual(reached, ["lifted", "late", "end"])
  }

  func testAnInterruptedTransitionEndsAtItsEndOnce() {
    let surface = FakeSurface()
    let animator = ManualAnimator()
    var ends: [Bool] = []
    let plan = movingPlan()
    let transition = PaneWindowTransition(
      kind: .pullBack, plan: plan, surface: surface, animator: animator
    ) { ends.append($0) }
    transition.start()

    transition.finish()
    animator.complete()  // the cut-short animation's own completion, arriving late
    transition.finish()

    XCTAssertEqual(ends, [true], "it ends once, as interrupted")
    XCTAssertEqual(surface.frame, plan.end, "at its end, not wherever the animation had got to")
    XCTAssertEqual(surface.alpha, plan.endAlpha)
    XCTAssertEqual(surface.pose?.progress, 1, "landed as what it turns into")
    XCTAssertEqual(surface.tearDowns, [0], "and goes at once")
  }

  func testACancelledTransitionNeverEnds() {
    let surface = FakeSurface()
    let animator = ManualAnimator()
    var ends: [Bool] = []
    let transition = PaneWindowTransition(
      kind: .pullBack, plan: movingPlan(), surface: surface, animator: animator
    ) { ends.append($0) }
    transition.start()

    transition.cancel()
    animator.complete()

    XCTAssertEqual(ends, [])
    XCTAssertEqual(surface.tearDowns, [0])
  }

  // MARK: The windows' transitions

  /// A pull back docks when it lands; a second pull back while it runs lands it at once, and a
  /// close while it runs drops it, docking nothing.
  func testAPullBackDocksWhenItLandsAndSettlesWhenInterrupted() throws {
    let (windows, animator, tabID) = openAnimatedWindow()
    defer { windows.close(tabID: tabID) }
    let slot = testSlot()
    var docks = 0
    var inFlight: [Bool] = []

    windows.dock(
      tabID, into: slot, setInFlight: { inFlight.append($0) }, then: { docks += 1 })
    XCTAssertEqual(inFlight, [true], "the slot's placeholder goes as the pull back starts")
    animator.advance(to: 0.2)
    XCTAssertEqual(docks, 0, "the pane docks when it lands, not as it leaves")
    XCTAssertEqual(inFlight, [true], "and stays gone the whole flight; docking clears it")
    XCTAssertFalse(try XCTUnwrap(windows.window(for: tabID)).isVisible, "its window is gone")

    windows.dock(tabID, into: slot) { docks += 1 }
    XCTAssertEqual(docks, 1, "a second pull back lands the first at once, and docks once")
    animator.completeAll()
    XCTAssertEqual(docks, 1, "the first's late completion docks nothing more")
  }

  func testClosingAPaneMidPullBackDocksNothing() {
    let (windows, animator, tabID) = openAnimatedWindow()
    var docks = 0
    windows.dock(tabID, into: testSlot()) { docks += 1 }

    windows.close(tabID: tabID)
    animator.completeAll()

    XCTAssertEqual(docks, 0)
    XCTAssertNil(windows.window(for: tabID))
  }

  /// A pop out keeps its slot's placeholder hidden until the pane has lifted out, 40% into the
  /// flight, and shows its window once the spring settles.
  func testAPopOutRevealsThePlaceholderOnceLiftedAndTheWindowOnceSettled() throws {
    let windows = DetachedPaneWindows()
    let animator = ManualAnimator()
    windows.animates = true
    windows.animator = animator
    windows.reduceMotion = { false }
    let tabID = UUID()
    var inFlight: [Bool] = []
    let source = DetachedPaneWindows.PopOutSource(
      slot: testSlot(), byDrag: false, pointer: nil, setInFlight: { inFlight.append($0) })
    windows.open(
      tabID: tabID, title: "pane", project: "p", workroom: nil, origin: nil, popOut: source,
      onCloseTab: {}, onDock: {}, content: { Color.clear })
    defer { windows.close(tabID: tabID) }
    let window = try XCTUnwrap(windows.window(for: tabID))
    let duration = PaneWindowMotion.Tuning.popOutSpring.settle
    XCTAssertEqual(inFlight, [true], "no placeholder as it leaves")

    animator.advance(to: duration * 0.39)
    XCTAssertEqual(inFlight, [true])
    animator.advance(to: duration * 0.41)
    XCTAssertEqual(inFlight, [true, false], "the placeholder shows once the pane has lifted out")
    XCTAssertEqual(TestWindowCloak.requested(window).alpha, 0, "the window waits for the spring")

    animator.complete()
    XCTAssertEqual(TestWindowCloak.requested(window).alpha, 1, "and swaps in once it settles")
  }

  /// With Reduce Motion a pop out fades the window in and never hides the placeholder.
  func testAReduceMotionPopOutLeavesThePlaceholderAlone() throws {
    let windows = DetachedPaneWindows()
    windows.animates = true
    windows.animator = ManualAnimator()
    windows.reduceMotion = { true }
    let tabID = UUID()
    var inFlight: [Bool] = []
    let source = DetachedPaneWindows.PopOutSource(
      slot: testSlot(), byDrag: false, pointer: nil, setInFlight: { inFlight.append($0) })
    windows.open(
      tabID: tabID, title: "pane", project: "p", workroom: nil, origin: nil, popOut: source,
      onCloseTab: {}, onDock: {}, content: { Color.clear })
    defer { windows.close(tabID: tabID) }

    XCTAssertEqual(inFlight, [])
  }

  /// A pop out shows its window when it lands; a pull back started before then lands it first, so
  /// the window is never left hidden.
  func testAPopOutInterruptedByAPullBackShowsItsWindowFirst() throws {
    let windows = DetachedPaneWindows()
    let animator = ManualAnimator()
    windows.animates = true
    windows.animator = animator
    windows.reduceMotion = { false }
    let tabID = UUID()
    let source = DetachedPaneWindows.PopOutSource(slot: testSlot(), byDrag: false, pointer: nil)
    windows.open(
      tabID: tabID, title: "pane", project: "p", workroom: nil, origin: nil, popOut: source,
      onCloseTab: {}, onDock: {}, content: { Color.clear })
    defer { windows.close(tabID: tabID) }
    let window = try XCTUnwrap(windows.window(for: tabID))
    // Its content laying out and its glass applying must not count as the user moving it, which
    // would cut every pop out short.
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertEqual(TestWindowCloak.requested(window).alpha, 0, "hidden while it grows")
    let opened = window.frame
    var docks = 0

    windows.dock(tabID, into: source.slot) { docks += 1 }

    XCTAssertEqual(TestWindowCloak.requested(window).alpha, 1, "shown as the pop out settles")
    XCTAssertEqual(window.frame, opened, "at the frame it opened at, which never moved")
    XCTAssertEqual(docks, 0, "and then it pulls back, docking when it lands")
    animator.completeAll()
    XCTAssertEqual(docks, 1)
  }

  // MARK: Snapshots

  /// The terminal's last frame, an `IOSurface`, is drawn the right way up.
  func testASurfaceSnapshotIsUpright() throws {
    let surface = try XCTUnwrap(
      IOSurfaceCreate(
        [
          kIOSurfaceWidth: 4, kIOSurfaceHeight: 4, kIOSurfaceBytesPerElement: 4,
          kIOSurfacePixelFormat: 0x4247_5241,  // 'BGRA'
        ] as CFDictionary))
    IOSurfaceLock(surface, [], nil)
    let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
    let stride = IOSurfaceGetBytesPerRow(surface)
    for row in 0..<4 {
      for col in 0..<4 {
        let pixel = base + row * stride + col * 4
        // The first rows (the top) red, the rest blue, BGRA.
        let red = row < 2
        pixel[0] = red ? 0 : 255
        pixel[1] = 0
        pixel[2] = red ? 255 : 0
        pixel[3] = 255
      }
    }
    IOSurfaceUnlock(surface, [], nil)
    let layer = CALayer()
    layer.contents = surface

    let image = try XCTUnwrap(PaneSnapshot.presentedImage(of: layer))
    let rep = NSBitmapImageRep(cgImage: image)

    let top = try XCTUnwrap(rep.colorAt(x: 1, y: 0)?.usingColorSpace(.sRGB))
    let bottom = try XCTUnwrap(rep.colorAt(x: 1, y: 3)?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(top.redComponent, 0.9, "the surface's top row is the image's top")
    XCTAssertGreaterThan(bottom.blueComponent, 0.9)
  }

  /// A window's picture shows its title bar: the traffic lights and the title the toolbar draws,
  /// on the window's background, at its backing scale.
  func testAWindowSnapshotShowsItsTitleBar() throws {
    let windows = DetachedPaneWindows()
    let tabID = UUID()
    windows.open(
      tabID: tabID, title: "Snapshot Title", project: "proj", workroom: nil, origin: nil,
      onCloseTab: {}, onDock: {}, content: { Color.clear })
    defer { windows.close(tabID: tabID) }
    let window = try XCTUnwrap(windows.window(for: tabID))
    window.contentView?.superview?.layoutSubtreeIfNeeded()

    let image = try XCTUnwrap(PaneSnapshot.window(window))
    let scale = window.backingScaleFactor
    XCTAssertEqual(image.width, Int(window.frame.width * scale))
    XCTAssertEqual(image.height, Int(window.frame.height * scale))
    let titlebar = PaneSnapshot.titlebarHeight(of: window)
    XCTAssertGreaterThan(titlebar, 20, "the title bar is above the content")
    let band = try XCTUnwrap(
      PaneSnapshot.split(image, height: window.frame.height, top: titlebar).top)
    XCTAssertGreaterThan(
      distinctColors(band), 10, "the band draws the traffic lights and the title, not a flat fill")
    XCTAssertEqual(alpha(of: band), 1, "opaque, on the window's background")
  }

  /// The title bar alone is the same pixels as the top of the whole window's picture.
  func testATitlebarSnapshotIsTheTopOfTheWindowSnapshot() throws {
    let windows = DetachedPaneWindows()
    let tabID = UUID()
    windows.open(
      tabID: tabID, title: "Snapshot Title", project: "proj", workroom: nil, origin: nil,
      onCloseTab: {}, onDock: {}, content: { Color.clear })
    defer { windows.close(tabID: tabID) }
    let window = try XCTUnwrap(windows.window(for: tabID))
    window.contentView?.superview?.layoutSubtreeIfNeeded()

    let whole = try XCTUnwrap(PaneSnapshot.window(window))
    let expected = try XCTUnwrap(
      PaneSnapshot.split(
        whole, height: window.frame.height, top: PaneSnapshot.titlebarHeight(of: window)
      ).top)
    let band = try XCTUnwrap(PaneSnapshot.titlebar(of: window))
    XCTAssertEqual([band.width, band.height], [expected.width, expected.height])
    XCTAssertTrue(try pixels(band) == pixels(expected), "pixel for pixel")
  }

  /// A split cuts on a whole pixel row from the top, and the halves go back together the right
  /// way up.
  func testASplitAndComposeKeepTheTopAtTheTop() throws {
    // 10x20 points at 2x: the top 6 points red, the rest blue.
    let source = try XCTUnwrap(
      PaneSnapshot.compose(
        size: NSSize(width: 10, height: 20), scale: 2, background: .blue,
        top: solid(.red), topHeight: 6, body: nil))
    XCTAssertEqual(source.width, 20)
    XCTAssertEqual(source.height, 40)

    let halves = PaneSnapshot.split(source, height: 20, top: 6)
    let top = try XCTUnwrap(halves.top)
    let body = try XCTUnwrap(halves.body)
    XCTAssertEqual(top.height, 12)
    XCTAssertEqual(body.height, 28)
    XCTAssertGreaterThan(try color(top, x: 5, y: 5).redComponent, 0.9)
    XCTAssertGreaterThan(try color(body, x: 5, y: 5).blueComponent, 0.9)

    // Swapped: the body as a 4pt top row over the old top as the body.
    let swapped = try XCTUnwrap(
      PaneSnapshot.compose(
        size: NSSize(width: 10, height: 20), scale: 2, background: .green, top: body,
        topHeight: 4, body: top))
    XCTAssertGreaterThan(try color(swapped, x: 5, y: 2).blueComponent, 0.9, "top row at the top")
    XCTAssertGreaterThan(try color(swapped, x: 5, y: 30).redComponent, 0.9)
  }

  func testRectsSnapToDevicePixels() {
    let rect = NSRect(x: 10.3, y: 20.76, width: 100.2, height: 50.49)
    XCTAssertEqual(
      PaneWindowMotion.snapped(rect, scale: 2), NSRect(x: 10.5, y: 21, width: 100, height: 50.5))
    // Edges snap, not sizes: 10.3…110.5 becomes 10…111.
    XCTAssertEqual(
      PaneWindowMotion.snapped(rect, scale: 1), NSRect(x: 10, y: 21, width: 101, height: 50))
    // A secondary screen's negative coordinates snap the same way.
    let negative = NSRect(x: -1500.26, y: 400.24, width: 600, height: 400)
    XCTAssertEqual(
      PaneWindowMotion.snapped(negative, scale: 2),
      NSRect(x: -1500.5, y: 400, width: 600, height: 400))
  }

  /// A pop out crossfades from the slot into the window it lands as; a dragged one is the window
  /// throughout, and a pull back with nowhere to land stays the window as it fades.
  func testCrossfadeProgressByKind() {
    let slot = NSRect(x: 40, y: 60, width: 400, height: 300)
    let grow = PaneWindowMotion.popOut(
      slot: slot, final: final, pointer: nil, byDrag: false, reduceMotion: false,
      screens: [primary])
    XCTAssertEqual([grow.startProgress, grow.endProgress], [0, 1])
    let drag = PaneWindowMotion.popOut(
      slot: slot, final: final, pointer: CGPoint(x: 300, y: 728), byDrag: true,
      reduceMotion: false, screens: [primary])
    XCTAssertEqual([drag.startProgress, drag.endProgress], [1, 1])
    let land = PaneWindowMotion.pullBack(
      window: final, slot: slot, reduceMotion: false, screens: [primary])
    XCTAssertEqual([land.startProgress, land.endProgress], [0, 1])
    let fade = PaneWindowMotion.pullBack(
      window: final, slot: nil, reduceMotion: false, screens: [primary])
    XCTAssertEqual([fade.startProgress, fade.endProgress], [0, 0])
  }

  // MARK: Helpers

  private func testSlot() -> PaneSlot {
    PaneSlot(
      rect: NSRect(x: 40, y: 60, width: 400, height: 300), snapshot: nil, scale: 2,
      background: .black, level: .normal)
  }

  private func solid(_ color: NSColor) -> CGImage? {
    PaneSnapshot.compose(
      size: NSSize(width: 4, height: 4), scale: 1, background: color, top: nil, topHeight: 0,
      body: nil)
  }

  /// The colour at pixel (`x`, `y`) from the top-left.
  private func color(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
    try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
  }

  private func distinctColors(_ image: CGImage) -> Int {
    let rep = NSBitmapImageRep(cgImage: image)
    var seen = Set<String>()
    for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
      for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        guard let c = rep.colorAt(x: x, y: y) else { continue }
        seen.insert(
          String(format: "%.2f%.2f%.2f", c.redComponent, c.greenComponent, c.blueComponent))
      }
    }
    return seen.count
  }

  /// Every byte of `image`, drawn into a plain sRGB bitmap of its own size.
  private func pixels(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    XCTAssertTrue(drawn)
    return bytes
  }

  private func alpha(of image: CGImage) -> CGFloat {
    let rep = NSBitmapImageRep(cgImage: image)
    var lowest: CGFloat = 1
    for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
      for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
        lowest = min(lowest, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
      }
    }
    return lowest
  }

  private func movingPlan() -> PaneWindowMotion.Plan {
    PaneWindowMotion.Plan(
      start: NSRect(x: 0, y: 0, width: 100, height: 100), end: final, startAlpha: 1,
      endAlpha: 1, curve: .spring(PaneWindowMotion.Tuning.pullBackSpring))
  }

  private func openAnimatedWindow() -> (DetachedPaneWindows, ManualAnimator, TerminalTab.ID) {
    let windows = DetachedPaneWindows()
    let animator = ManualAnimator()
    let tabID = UUID()
    windows.open(
      tabID: tabID, title: "pane", project: "p", workroom: nil, origin: nil,
      onCloseTab: {}, onDock: {}, content: { Color.clear.frame(width: 200, height: 120) })
    windows.animates = true
    windows.animator = animator
    windows.reduceMotion = { false }
    return (windows, animator, tabID)
  }
}

/// Records what a transition does to what it draws on.
@MainActor
private final class FakeSurface: PaneWindowTransitionSurface {
  var pose: PaneWindowMotion.Pose?
  var tearDowns: [TimeInterval] = []
  var frame: NSRect? { pose?.frame }
  var alpha: CGFloat? { pose?.alpha }

  func set(_ pose: PaneWindowMotion.Pose) { self.pose = pose }

  func tearDown(fade: TimeInterval) { tearDowns.append(fade) }
}

/// A clock moved by hand: `advance` steps every run to a time, `complete` runs them out.
@MainActor
private final class ManualAnimator: PaneWindowAnimating {
  private struct Run {
    let duration: TimeInterval
    let step: @MainActor (TimeInterval) -> Void
    let completion: @MainActor () -> Void
  }

  private var runs: [Run] = []

  func run(
    duration: TimeInterval, step: @escaping @MainActor (TimeInterval) -> Void,
    completion: @escaping @MainActor () -> Void
  ) {
    runs.append(Run(duration: duration, step: step, completion: completion))
  }

  func advance(to t: TimeInterval) {
    for run in runs { run.step(min(t, run.duration)) }
  }

  func complete() { completeAll() }

  func completeAll() {
    let pending = runs
    runs = []
    for run in pending {
      run.step(run.duration)
      run.completion()
    }
  }
}
