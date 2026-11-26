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
    XCTAssertEqual(plan.duration, 0.25)
    XCTAssertEqual(plan.timing, .easeOut)
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

  func testAPullBackShrinksIntoTheSlotAndFades() {
    let slot = NSRect(x: 40, y: 60, width: 400, height: 300)
    let plan = PaneWindowMotion.pullBack(
      window: final, slot: slot, reduceMotion: false, screens: [primary])

    XCTAssertEqual(plan.start, final)
    XCTAssertEqual(plan.end, slot)
    XCTAssertLessThan(plan.endAlpha, plan.startAlpha)
    XCTAssertGreaterThan(plan.endAlpha, 0, "still there to hand over to the slot")
    XCTAssertEqual(plan.duration, 0.22)
    XCTAssertEqual(plan.timing, .easeIn)
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
    XCTAssertEqual(PaneWindowMotion.placeholderFade(appearing: true, reduceMotion: false), 0.25)
    XCTAssertEqual(PaneWindowMotion.placeholderFade(appearing: false, reduceMotion: false), 0.15)
    XCTAssertEqual(PaneWindowMotion.placeholderFade(appearing: true, reduceMotion: true), 0.15)
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
    XCTAssertEqual(surface.animatedTo, plan.end)
    XCTAssertEqual(ends, [], "nothing ends until the animation does")

    animator.complete()

    XCTAssertEqual(ends, [false])
    XCTAssertEqual(surface.frame, plan.end)
    XCTAssertEqual(surface.tearDowns, [PaneWindowMotion.tailFadeDuration])
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
    let slot = NSRect(x: 40, y: 60, width: 400, height: 300)
    var docks = 0

    windows.dock(tabID, intoSlot: slot) { docks += 1 }
    XCTAssertEqual(docks, 0, "the pane docks when it lands, not as it leaves")
    XCTAssertFalse(try XCTUnwrap(windows.window(for: tabID)).isVisible, "its window is gone")

    windows.dock(tabID, intoSlot: slot) { docks += 1 }
    XCTAssertEqual(docks, 1, "a second pull back lands the first at once, and docks once")
    animator.completeAll()
    XCTAssertEqual(docks, 1, "the first's late completion docks nothing more")
  }

  func testClosingAPaneMidPullBackDocksNothing() {
    let (windows, animator, tabID) = openAnimatedWindow()
    var docks = 0
    windows.dock(tabID, intoSlot: NSRect(x: 40, y: 60, width: 400, height: 300)) { docks += 1 }

    windows.close(tabID: tabID)
    animator.completeAll()

    XCTAssertEqual(docks, 0)
    XCTAssertNil(windows.window(for: tabID))
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
    let source = DetachedPaneWindows.PopOutSource(
      slot: NSRect(x: 40, y: 60, width: 400, height: 300), snapshot: nil, scale: 2,
      background: .black, level: .normal, byDrag: false, pointer: nil)
    windows.open(
      tabID: tabID, title: "pane", project: "p", workroom: nil, origin: nil, popOut: source,
      onCloseTab: {}, onDock: {}, content: { Color.clear.frame(width: 200, height: 120) })
    defer { windows.close(tabID: tabID) }
    let window = try XCTUnwrap(windows.window(for: tabID))
    XCTAssertEqual(TestWindowCloak.requested(window).alpha, 0, "hidden while it grows")
    let opened = window.frame
    var docks = 0

    windows.dock(tabID, intoSlot: source.slot) { docks += 1 }

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

  // MARK: Helpers

  private func movingPlan() -> PaneWindowMotion.Plan {
    PaneWindowMotion.Plan(
      start: NSRect(x: 0, y: 0, width: 100, height: 100), end: final, startAlpha: 1,
      endAlpha: 0.6, duration: 0.22, timing: .easeIn)
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
  var frame: NSRect?
  var alpha: CGFloat?
  var animatedTo: NSRect?
  var tearDowns: [TimeInterval] = []

  func set(frame: NSRect, alpha: CGFloat) {
    self.frame = frame
    self.alpha = alpha
  }

  func animate(to frame: NSRect, alpha: CGFloat) { animatedTo = frame }

  func tearDown(fade: TimeInterval) { tearDowns.append(fade) }
}

/// Runs each animation's changes at once and holds its completion until told.
@MainActor
private final class ManualAnimator: PaneWindowAnimating {
  private var completions: [() -> Void] = []

  func animate(
    duration: TimeInterval, timing: PaneWindowMotion.Timing, changes: @escaping () -> Void,
    completion: @escaping @MainActor () -> Void
  ) {
    changes()
    completions.append(completion)
  }

  func complete() { completeAll() }

  func completeAll() {
    let pending = completions
    completions = []
    for completion in pending { completion() }
  }
}
