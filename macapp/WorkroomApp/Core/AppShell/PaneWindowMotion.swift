import AppKit
import QuartzCore

/// How a pane's pop out and pull back are drawn (issue #172): the pure half, which says where a
/// transition starts and ends, how long it takes and whether it moves at all. `PaneWindowTransition`
/// runs a plan; `PaneTransitionPanel` is what it draws with.
///
/// The live surface never animates. It moves exactly as it did before there was any animation, in
/// one step, and a snapshot of the pane flies in a borderless window over it: animating the real
/// window's frame would resize the terminal on every frame, and each resize is a `SIGWINCH` that a
/// busy program redraws for.
///
/// ```
///   pop out   slot ──grow 0.25s ease-out──▶ window frame     the window shows when it lands
///   drag out  pointer ──scale up 0.25s──▶ window frame        the drag ghost was already there
///   pull back window frame ──shrink 0.22s ease-in──▶ slot     the pane docks when it lands
///   Reduce Motion, or no slot on screen: a 0.15s crossfade in place, nothing moves
/// ```
enum PaneWindowMotion {
  static let popOutDuration: TimeInterval = 0.25
  static let pullBackDuration: TimeInterval = 0.22
  static let crossfadeDuration: TimeInterval = 0.15
  /// The snapshot's last fade once the real thing is under it: it covers the frame or two the
  /// surface takes to draw in its new place.
  static let tailFadeDuration: TimeInterval = 0.1
  /// How far a dragged-out window scales up from: a little smaller than it lands, about the pointer.
  static let dragStartScale: CGFloat = 0.85
  /// How faded the pulled-back snapshot is when it reaches the slot, before the pane docks under it.
  static let pullBackEndAlpha: CGFloat = 0.6

  /// The timing curve of a plan, kept apart from Core Animation's names so a plan is plain data.
  enum Timing: Equatable {
    case easeOut, easeIn, easeInOut

    var function: CAMediaTimingFunction {
      switch self {
      case .easeOut: CAMediaTimingFunction(name: .easeOut)
      case .easeIn: CAMediaTimingFunction(name: .easeIn)
      case .easeInOut: CAMediaTimingFunction(name: .easeInEaseOut)
      }
    }
  }

  /// One transition, in screen coordinates (AppKit's: y up, origin at the bottom-left of the
  /// primary screen).
  struct Plan: Equatable {
    var start: NSRect
    var end: NSRect
    var startAlpha: CGFloat
    var endAlpha: CGFloat
    var duration: TimeInterval
    var timing: Timing
    /// How far the snapshot has crossfaded from what it leaves (0) to what it lands as (1): from the
    /// slot to the window on a pop out, from the window to the slot on a pull back.
    var startProgress: CGFloat = 0
    var endProgress: CGFloat = 1
    /// Whether the transition moves. A crossfade fades in place: the real window itself on a pop
    /// out, a snapshot of it on a pull back.
    var moves: Bool { start != end }

    var startPose: Pose { Pose(frame: start, alpha: startAlpha, progress: startProgress) }
    var endPose: Pose { Pose(frame: end, alpha: endAlpha, progress: endProgress) }
  }

  /// Where a transition's snapshot is at one moment: its frame on screen, its opacity, and how far
  /// it has crossfaded into what it lands as.
  struct Pose: Equatable {
    var frame: NSRect
    var alpha: CGFloat
    var progress: CGFloat
  }

  /// Whether this process animates at all. A hosted unit run never does: its windows stay behind
  /// the developer's work, and its tests assert the end state the instant an action returns. The
  /// transition's own tests drive it through a manual animator instead.
  static let isEnabledByDefault = !AppEnvironment.isHostedUnitRun()

  /// A popped-out pane's way into its window. `final` is the frame the window opens at, as it always
  /// has; `slot` is the pane's slot on screen, nil when it isn't on one; `pointer` is where the drop
  /// landed for a drag.
  static func popOut(
    slot: NSRect?, final: NSRect, pointer: CGPoint?, byDrag: Bool, reduceMotion: Bool,
    screens: [NSRect]
  ) -> Plan {
    let fade = Plan(
      start: final, end: final, startAlpha: 0, endAlpha: 1, duration: crossfadeDuration,
      timing: .easeInOut)
    if reduceMotion { return fade }
    // A drag showed the window to come, full size under the pointer (`DetachedPaneDragPreview`), so
    // growing out of the slot afterwards would send the pane back to where it was dragged from.
    if byDrag, let pointer {
      // The window as it lands throughout: the slot's shape would stretch to the window's.
      return Plan(
        start: scaled(final, by: dragStartScale, about: pointer), end: final, startAlpha: 0,
        endAlpha: 1, duration: popOutDuration, timing: .easeOut, startProgress: 1)
    }
    guard let slot = onScreen(slot, screens: screens) else { return fade }
    return Plan(
      start: slot, end: final, startAlpha: 1, endAlpha: 1, duration: popOutDuration,
      timing: .easeOut)
  }

  /// A detached pane's way back into its slot, from its window's frame.
  static func pullBack(window: NSRect, slot: NSRect?, reduceMotion: Bool, screens: [NSRect])
    -> Plan
  {
    guard !reduceMotion, let slot = onScreen(slot, screens: screens) else {
      // The window's own picture fading where it was: there is no slot to turn into.
      return Plan(
        start: window, end: window, startAlpha: 1, endAlpha: 0, duration: crossfadeDuration,
        timing: .easeInOut, endProgress: 0)
    }
    return Plan(
      start: window, end: slot, startAlpha: 1, endAlpha: pullBackEndAlpha,
      duration: pullBackDuration, timing: .easeIn)
  }

  /// How long a popped-out slot's placeholder fades: in over the pop out's growth, out quickly
  /// once the pane is back under it, and a crossfade's length with Reduce Motion.
  static func placeholderFade(appearing: Bool, reduceMotion: Bool) -> TimeInterval {
    if reduceMotion { return crossfadeDuration }
    return appearing ? popOutDuration : crossfadeDuration
  }

  /// A rect in a window's base coordinates, on screen: what `NSWindow.convertToScreen` does, for a
  /// window at `windowFrame`.
  static func screenRect(of rectInWindow: NSRect, windowFrame: NSRect) -> NSRect {
    rectInWindow.offsetBy(dx: windowFrame.minX, dy: windowFrame.minY)
  }

  /// `rect` when some of it is on a screen, else nil. Not clamped: a slot partly off a screen still
  /// lines up with the pane it is a snapshot of, and the part off screen simply isn't seen.
  static func onScreen(_ rect: NSRect?, screens: [NSRect]) -> NSRect? {
    guard let rect, rect.width >= 1, rect.height >= 1 else { return nil }
    return screens.contains { $0.intersects(rect) } ? rect : nil
  }

  /// `rect` with each edge on the nearest device pixel at `scale`, so a snapshot drawn to it lands
  /// on the same pixels the view it pictures draws on.
  static func snapped(_ rect: NSRect, scale: CGFloat) -> NSRect {
    guard scale > 0 else { return rect }
    func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
    let minX = snap(rect.minX)
    let minY = snap(rect.minY)
    return NSRect(x: minX, y: minY, width: snap(rect.maxX) - minX, height: snap(rect.maxY) - minY)
  }

  /// `rect` scaled by `factor` about `point`, so the point keeps its place in it.
  static func scaled(_ rect: NSRect, by factor: CGFloat, about point: CGPoint) -> NSRect {
    NSRect(
      x: point.x + (rect.minX - point.x) * factor, y: point.y + (rect.minY - point.y) * factor,
      width: rect.width * factor, height: rect.height * factor)
  }
}

/// What runs a transition's timing: Core Animation's in the app, a hand-driven one in tests.
@MainActor
protocol PaneWindowAnimating {
  /// Run `changes` animated over `duration`, then `completion`.
  func animate(
    duration: TimeInterval, timing: PaneWindowMotion.Timing, changes: @escaping () -> Void,
    completion: @escaping @MainActor () -> Void)
}

/// `NSAnimationContext`, whose animator proxies move and fade a window.
struct LivePaneWindowAnimator: PaneWindowAnimating {
  func animate(
    duration: TimeInterval, timing: PaneWindowMotion.Timing, changes: @escaping () -> Void,
    completion: @escaping @MainActor () -> Void
  ) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = timing.function
      changes()
    } completionHandler: {
      MainActor.assumeIsolated { completion() }
    }
  }
}

/// What a transition draws on: a snapshot's borderless window, or the real window fading in place.
@MainActor
protocol PaneWindowTransitionSurface: AnyObject {
  /// Put it at `pose` at once, ending any animation.
  func set(_ pose: PaneWindowMotion.Pose)
  /// Move it to `pose` through the animator, inside an animation's `changes`. `duration` and
  /// `timing` are the animation's, for what the animator proxies don't reach (a layer's corners).
  func animate(
    to pose: PaneWindowMotion.Pose, duration: TimeInterval, timing: PaneWindowMotion.Timing)
  /// The transition is over: go, fading out over `fade` (0 for at once).
  func tearDown(fade: TimeInterval)
}

/// One running pop out or pull back. It ends exactly once, at its plan's end, whether its
/// animation completes or something interrupts it (`finish`); `cancel` drops it without its ending,
/// for a pane that is going away.
@MainActor
final class PaneWindowTransition {
  enum Kind { case popOut, pullBack }

  let kind: Kind
  let plan: PaneWindowMotion.Plan
  private let surface: PaneWindowTransitionSurface
  private let animator: PaneWindowAnimating
  /// What the transition leads to (show the real window, dock the pane), told whether it was cut
  /// short.
  private var onEnd: ((_ interrupted: Bool) -> Void)?
  private(set) var isDone = false

  init(
    kind: Kind, plan: PaneWindowMotion.Plan, surface: PaneWindowTransitionSurface,
    animator: PaneWindowAnimating, onEnd: @escaping (_ interrupted: Bool) -> Void
  ) {
    self.kind = kind
    self.plan = plan
    self.surface = surface
    self.animator = animator
    self.onEnd = onEnd
  }

  func start() {
    surface.set(plan.startPose)
    let plan = plan
    let surface = surface
    animator.animate(
      duration: plan.duration, timing: plan.timing,
      changes: {
        surface.animate(to: plan.endPose, duration: plan.duration, timing: plan.timing)
      },
      completion: { [weak self] in self?.end(interrupted: false) })
  }

  /// Jump to the end now: a second pop out, pull back or move arrived while this one ran.
  func finish() { end(interrupted: true) }

  /// Drop the transition without its ending: its pane is closing, or leaving this window.
  func cancel() {
    guard !isDone else { return }
    isDone = true
    onEnd = nil
    surface.tearDown(fade: 0)
  }

  private func end(interrupted: Bool) {
    guard !isDone else { return }
    isDone = true
    surface.set(plan.endPose)
    let onEnd = onEnd
    self.onEnd = nil
    onEnd?(interrupted)
    surface.tearDown(fade: interrupted ? 0 : PaneWindowMotion.tailFadeDuration)
  }
}
