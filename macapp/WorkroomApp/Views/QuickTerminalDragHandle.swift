import AppKit
import Defaults
import SwiftUI

extension EnvironmentValues {
  /// True inside the Quick Terminal's window: the tab strip and pane footers it shares with
  /// workrooms put a `QuickTerminalDragHandle` in their empty space.
  @Entry var isQuickTerminal = false
}

/// Empty chrome you can drag the Quick Terminal by. The window isn't movable (AppKit would let it
/// float free); this moves it itself, docked to the nearest screen edge the whole way
/// (`QuickTerminalController.dragDock`), and keeps where it ends up for the next summon.
struct QuickTerminalDragHandle: NSViewRepresentable {
  func makeNSView(context: Context) -> HandleView { HandleView() }
  func updateNSView(_ nsView: HandleView, context: Context) {}

  final class HandleView: NSView {
    /// The pointer's distance from the window's centre when the drag began.
    private var grab: NSPoint?
    private var landed: (edge: QuickTerminalEdge, offset: Double)?
    /// The edge the window is on mid-drag.
    private var edge = QuickTerminalEdge.top
    /// Where the drag docks the window, and how far off that the window is drawn. A hop to
    /// another edge leaves the window where it was and `lag` fades to nothing, frame by frame,
    /// while every move still carries the window with the pointer, so it never trails it.
    private var target = NSRect.zero
    private var lag = CGVector.zero
    private var glide: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    /// The fade's time constant: about 0.15 s to land.
    private static let settle: CFTimeInterval = 0.05

    override var mouseDownCanMoveWindow: Bool { false }

    /// Torn down mid-glide (its strip re-rendered): land the window rather than leave it off its edge.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
      guard newWindow == nil, glide != nil else { return }
      stopGlide()
      window?.setFrame(target, display: true)
    }

    override func mouseDown(with event: NSEvent) {
      guard let window else { return }
      let pointer = NSEvent.mouseLocation
      grab = NSPoint(x: pointer.x - window.frame.midX, y: pointer.y - window.frame.midY)
      edge = Defaults[.quickTerminalEdge]
      NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
      guard let window, let grab else { return }
      guard
        let dock = QuickTerminalController.dragDock(
          size: window.frame.size, pointer: NSEvent.mouseLocation, grab: grab, current: edge,
          fallback: window.screen)
      else { return }
      if dock.edge != edge, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        lag = CGVector(
          dx: window.frame.minX - dock.frame.minX, dy: window.frame.minY - dock.frame.minY)
        startGlide()
      }
      edge = dock.edge
      landed = (dock.edge, dock.offset)
      target = dock.frame
      window.setFrame(target.offsetBy(dx: lag.dx, dy: lag.dy), display: true)
    }

    private func startGlide() {
      lastTick = CACurrentMediaTime()
      guard glide == nil else { return }
      glide = displayLink(target: self, selector: #selector(tick))
      glide?.add(to: .main, forMode: .common)
    }

    private func stopGlide() {
      glide?.invalidate()
      glide = nil
      lag = .zero
    }

    @objc private func tick(_ link: CADisplayLink) {
      let keep = exp(-(link.timestamp - lastTick) / Self.settle)
      lastTick = link.timestamp
      lag = CGVector(dx: lag.dx * keep, dy: lag.dy * keep)
      if hypot(lag.dx, lag.dy) < 0.5 { stopGlide() }
      window?.setFrame(target.offsetBy(dx: lag.dx, dy: lag.dy), display: true)
    }

    override func mouseUp(with event: NSEvent) {
      if grab != nil { NSCursor.pop() }
      grab = nil
      // Once, at the end: the Settings picker follows the edge it landed on.
      guard let landed else { return }
      self.landed = nil
      Defaults[.quickTerminalEdge] = landed.edge
      Defaults[.quickTerminalOffset] = landed.offset
    }
  }
}
