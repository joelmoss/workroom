import AppKit
import QuartzCore

/// How a pane's pop out and pull back are drawn (issue #172): the pure half, which says where a
/// transition is at every moment. `PaneWindowTransition` runs a plan frame by frame;
/// `PaneTransitionPanel` is what it draws with.
///
/// The live surface never animates. It moves exactly as it did before there was any animation, in
/// one step, and a snapshot of the pane flies in a borderless window over it: animating the real
/// window's frame would resize the terminal on every frame, and each resize is a `SIGWINCH` that a
/// busy program redraws for.
///
/// ```
///   pop out   slot ──spring, slight overshoot──▶ window frame   the window shows once it settles;
///             the slot's placeholder shows once the pane has lifted out of it
///   drag out  pointer ──the same spring──▶ window frame          the drag ghost was already there
///   pull back window frame ──critically damped spring──▶ slot   the slot's placeholder goes as it
///             starts; the pane docks when it lands, and the card fades off it
///   Reduce Motion, or no slot on screen: a crossfade in place, nothing moves
/// ```
enum PaneWindowMotion {
  /// Every timing and spring the transitions use, in one place to tune.
  enum Tuning {
    /// Pop out: a spring that overshoots its frame a little (2.5% of the way it travels) and
    /// settles in 0.38s.
    static let popOutSpring = Spring(dampingRatio: 0.76, settle: 0.38)
    /// Pull back: a critically damped spring, no overshoot, settled in 0.32s.
    static let pullBackSpring = Spring(dampingRatio: 1, settle: 0.32)
    /// How far into a pop out its slot's placeholder starts to show: once the card has lifted out
    /// of the slot.
    static let placeholderRevealFraction: Double = 0.4
    /// The placeholder fading in, once revealed.
    static let placeholderFadeIn: TimeInterval = 0.2
    /// The placeholder fading out: at the start of a pull back, or as a pane docks.
    static let placeholderFadeOut: TimeInterval = 0.08
    /// The card fading off the real thing once it has landed: the window it grew into, or the
    /// slot the pane docked in. It also covers the frame or two the surface takes to draw there.
    static let cardFadeOut: TimeInterval = 0.08
    /// Reduce Motion, or nowhere on screen to fly from or to: a crossfade in place.
    static let crossfadeDuration: TimeInterval = 0.15
    /// How far a dragged-out window scales up from: a little smaller than it lands, about the
    /// pointer.
    static let dragStartScale: CGFloat = 0.85
  }

  /// A damped spring from 0 to 1, given by how it feels: its damping ratio (1 is critically
  /// damped, below 1 overshoots) and how long it takes to settle, after which it is exactly 1.
  struct Spring: Equatable {
    let dampingRatio: Double
    let settle: TimeInterval
    /// The natural frequency that settles it in time, solved once: every frame reads it.
    let omega: Double
    /// Within this of its rest by `settle`, where it snaps to rest unseen.
    static let tolerance = 0.001

    init(dampingRatio: Double, settle: TimeInterval) {
      self.dampingRatio = dampingRatio
      self.settle = settle
      omega = Self.omega(dampingRatio: dampingRatio, settle: settle)
    }

    private static func omega(dampingRatio: Double, settle: TimeInterval) -> Double {
      if dampingRatio >= 1 {
        // (1 + u)e^-u = tolerance, solved for u = ωT.
        var lower = 0.0
        var upper = 50.0
        for _ in 0..<60 {
          let u = (lower + upper) / 2
          if (1 + u) * exp(-u) > tolerance { lower = u } else { upper = u }
        }
        return upper / settle
      }
      let damped = (1 - dampingRatio * dampingRatio).squareRoot()
      return log(1 / (tolerance * damped)) / (dampingRatio * settle)
    }

    /// How far along it is at `t` seconds: 0 at the start, past 1 while it overshoots, exactly 1
    /// from `settle` on.
    func value(at t: TimeInterval) -> Double {
      guard t > 0 else { return 0 }
      guard t < settle else { return 1 }
      let w = omega
      if dampingRatio >= 1 { return 1 - exp(-w * t) * (1 + w * t) }
      let damped = w * (1 - dampingRatio * dampingRatio).squareRoot()
      let decay = exp(-dampingRatio * w * t)
      return 1 - decay * (cos(damped * t) + dampingRatio * w / damped * sin(damped * t))
    }
  }

  /// How a plan moves through its time.
  enum Curve: Equatable {
    case spring(Spring)
    /// Ease in and out (smoothstep), for a crossfade.
    case smooth

    func value(at t: TimeInterval, duration: TimeInterval) -> Double {
      switch self {
      case .spring(let spring): return spring.value(at: t)
      case .smooth:
        guard duration > 0 else { return 1 }
        let x = min(max(t / duration, 0), 1)
        return x * x * (3 - 2 * x)
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
    var curve: Curve
    /// How far the snapshot has crossfaded from what it leaves (0) to what it lands as (1): from the
    /// slot to the window on a pop out, from the window to the slot on a pull back. Also how much
    /// of a window's shadow it casts.
    var startProgress: CGFloat = 0
    var endProgress: CGFloat = 1

    /// How long it runs: until its spring settles, or its crossfade ends.
    var duration: TimeInterval {
      switch curve {
      case .spring(let spring): spring.settle
      case .smooth: Tuning.crossfadeDuration
      }
    }

    /// Whether the transition moves. A crossfade fades in place: the real window itself on a pop
    /// out, a snapshot of it on a pull back.
    var moves: Bool { start != end }

    /// Where it is `t` seconds in. The frame follows the curve past its end while a spring
    /// overshoots; opacity and the crossfade stop at theirs.
    func pose(at t: TimeInterval) -> Pose {
      let p = CGFloat(curve.value(at: t, duration: duration))
      let clamped = min(max(p, 0), 1)
      func mix(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat { a + (b - a) * x }
      return Pose(
        frame: NSRect(
          x: mix(start.minX, end.minX, p), y: mix(start.minY, end.minY, p),
          width: mix(start.width, end.width, p), height: mix(start.height, end.height, p)),
        alpha: mix(startAlpha, endAlpha, clamped),
        progress: mix(startProgress, endProgress, clamped))
    }

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

  /// A popped-out pane's way into its window. `final` is the frame the window opens at, as it always
  /// has; `slot` is the pane's slot on screen, nil when it isn't on one; `pointer` is where the drop
  /// landed for a drag.
  static func popOut(
    slot: NSRect?, final: NSRect, pointer: CGPoint?, byDrag: Bool, reduceMotion: Bool,
    screens: [NSRect]
  ) -> Plan {
    let fade = Plan(start: final, end: final, startAlpha: 0, endAlpha: 1, curve: .smooth)
    if reduceMotion { return fade }
    // A drag showed the window to come, full size under the pointer (`DetachedPaneDragPreview`), so
    // growing out of the slot afterwards would send the pane back to where it was dragged from.
    if byDrag, let pointer {
      // The window as it lands throughout: the slot's shape would stretch to the window's.
      return Plan(
        start: scaled(final, by: Tuning.dragStartScale, about: pointer), end: final,
        startAlpha: 0, endAlpha: 1, curve: .spring(Tuning.popOutSpring), startProgress: 1)
    }
    guard let slot = onScreen(slot, screens: screens) else { return fade }
    return Plan(
      start: slot, end: final, startAlpha: 1, endAlpha: 1, curve: .spring(Tuning.popOutSpring))
  }

  /// A detached pane's way back into its slot, from its window's frame. Fully opaque until it
  /// lands: the card then fades off the docked pane (`Tuning.cardFadeOut`).
  static func pullBack(window: NSRect, slot: NSRect?, reduceMotion: Bool, screens: [NSRect])
    -> Plan
  {
    guard !reduceMotion, let slot = onScreen(slot, screens: screens) else {
      // The window's own picture fading where it was: there is no slot to turn into.
      return Plan(
        start: window, end: window, startAlpha: 1, endAlpha: 0, curve: .smooth, endProgress: 0)
    }
    return Plan(
      start: window, end: slot, startAlpha: 1, endAlpha: 1, curve: .spring(Tuning.pullBackSpring))
  }

  /// How long a popped-out slot's placeholder fades: in once a pop out has lifted the pane out, out
  /// fast as a pull back starts or a pane docks, and a crossfade's length with Reduce Motion.
  static func placeholderFade(appearing: Bool, reduceMotion: Bool) -> TimeInterval {
    if reduceMotion { return Tuning.crossfadeDuration }
    return appearing ? Tuning.placeholderFadeIn : Tuning.placeholderFadeOut
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

/// What runs a transition's clock: the display's refresh in the app, a hand-driven one in tests.
@MainActor
protocol PaneWindowAnimating {
  /// Call `step` with the seconds elapsed on each frame for `duration`, last with `duration`
  /// itself, then `completion`.
  func run(
    duration: TimeInterval, step: @escaping @MainActor (TimeInterval) -> Void,
    completion: @escaping @MainActor () -> Void)
}

/// Steps on the main screen's display link, so a spring is drawn at the display's own rate.
struct LivePaneWindowAnimator: PaneWindowAnimating {
  func run(
    duration: TimeInterval, step: @escaping @MainActor (TimeInterval) -> Void,
    completion: @escaping @MainActor () -> Void
  ) {
    DisplayLinkClock(duration: duration, step: step, completion: completion).start()
  }

  /// One run's display link. It keeps itself alive through the link, which retains its target,
  /// until the run ends.
  @MainActor
  private final class DisplayLinkClock: NSObject {
    private let duration: TimeInterval
    private let step: @MainActor (TimeInterval) -> Void
    private let completion: @MainActor () -> Void
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0

    init(
      duration: TimeInterval, step: @escaping @MainActor (TimeInterval) -> Void,
      completion: @escaping @MainActor () -> Void
    ) {
      self.duration = duration
      self.step = step
      self.completion = completion
    }

    func start() {
      guard let screen = NSScreen.main ?? NSScreen.screens.first else {
        finish()
        return
      }
      startTime = CACurrentMediaTime()
      let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
      link.add(to: .main, forMode: .common)
      self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
      let elapsed = CACurrentMediaTime() - startTime
      if elapsed >= duration {
        finish()
      } else {
        step(elapsed)
      }
    }

    private func finish() {
      link?.invalidate()
      link = nil
      step(duration)
      completion()
    }
  }
}

/// What a transition draws on: a snapshot's borderless window, or the real window fading in place.
@MainActor
protocol PaneWindowTransitionSurface: AnyObject {
  /// Put it at `pose` now: called once per frame.
  func set(_ pose: PaneWindowMotion.Pose)
  /// The transition is over: go, fading out over `fade` (0 for at once).
  func tearDown(fade: TimeInterval)
}

/// One running pop out or pull back. It ends exactly once, at its plan's end, whether its clock
/// runs out or something interrupts it (`finish`); `cancel` drops it without its ending, for a
/// pane that is going away. Its milestones each run once, at their fraction of the plan, or as it
/// ends or is dropped if it never got there.
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
  private var milestones: [(fraction: Double, action: () -> Void)]
  private(set) var isDone = false

  init(
    kind: Kind, plan: PaneWindowMotion.Plan, surface: PaneWindowTransitionSurface,
    animator: PaneWindowAnimating, milestones: [(fraction: Double, action: () -> Void)] = [],
    onEnd: @escaping (_ interrupted: Bool) -> Void
  ) {
    self.kind = kind
    self.plan = plan
    self.surface = surface
    self.animator = animator
    self.milestones = milestones
    self.onEnd = onEnd
  }

  func start() {
    surface.set(plan.startPose)
    animator.run(
      duration: plan.duration,
      step: { [weak self] t in self?.step(t) },
      completion: { [weak self] in self?.end(interrupted: false) })
  }

  /// Jump to the end now: a second pop out, pull back or move arrived while this one ran.
  func finish() { end(interrupted: true) }

  /// Drop the transition without its ending: its pane is closing, or leaving this window.
  func cancel() {
    guard !isDone else { return }
    isDone = true
    onEnd = nil
    runMilestones(through: .infinity)
    surface.tearDown(fade: 0)
  }

  private func step(_ t: TimeInterval) {
    guard !isDone else { return }
    surface.set(plan.pose(at: t))
    runMilestones(through: plan.duration > 0 ? t / plan.duration : 1)
  }

  private func runMilestones(through fraction: Double) {
    while let next = milestones.first, next.fraction <= fraction {
      milestones.removeFirst()
      next.action()
    }
  }

  private func end(interrupted: Bool) {
    guard !isDone else { return }
    isDone = true
    surface.set(plan.endPose)
    runMilestones(through: .infinity)
    let onEnd = onEnd
    self.onEnd = nil
    onEnd?(interrupted)
    surface.tearDown(fade: interrupted ? 0 : PaneWindowMotion.Tuning.cardFadeOut)
  }
}
