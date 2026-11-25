import AppKit
import ObjectiveC

/// Hides every window the test host shows from the developer, whoever shows it. The unit suite
/// runs on their Mac, and the app's own windows (the Quick Terminal sliding in, the switcher, the
/// copy toast, a popped-out pane) appear over their work whenever a test drives them.
///
/// Installed once, as the bundle loads (`HostedRunGuardObserver`), for the whole hosted run: from
/// then on a window is made transparent, click-through and unanimated as it is ordered on screen,
/// and stays so whatever its code sets later. The window server still counts it as on screen and
/// visible (only opaque coverage occludes), so it lays out, draws and renders exactly as before.
///
/// The window's getters tell the truth (alpha 0, click-through, no animation): AppKit reads them
/// itself, and when they reported what the code had set, its close animation ran at full opacity,
/// so every window flashed opaque as it shrank away. What the code asked for instead is kept, and a
/// test asserting a fade or a click-through flag reads it (`requested`). A test that needs an
/// ordinary window opts it out first (`showTestWindowVisibly`).
///
/// Launch windows open before the bundle loads, so a hosted run opens none
/// (`AppEnvironment.opensWindowsAtLaunch`).
enum TestWindowCloak {
  /// What a window's code last set, which a cloaked window holds back. One per cloaked window,
  /// made as it is cloaked and updated in place by its setters.
  final class Requested {
    var alpha: CGFloat
    var ignoresMouseEvents: Bool
    var animationBehavior: NSWindow.AnimationBehavior

    /// What `window` holds now.
    init(of window: NSWindow) {
      alpha = window.alphaValue
      ignoresMouseEvents = window.ignoresMouseEvents
      animationBehavior = window.animationBehavior
    }
  }

  /// Swaps the setters in, once however often it is called.
  static func install() { _ = swapped }

  private static let swapped: Void = {
    let swaps: [(Selector, Selector)] = [
      (#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.cloakedOrder(_:relativeTo:))),
      (
        #selector(NSWindow.orderFrontRegardless),
        #selector(NSWindow.cloakedOrderFrontRegardless)
      ),
      (#selector(setter: NSWindow.alphaValue), #selector(NSWindow.cloakedSetAlphaValue(_:))),
      (
        #selector(setter: NSWindow.ignoresMouseEvents),
        #selector(NSWindow.cloakedSetIgnoresMouseEvents(_:))
      ),
      (
        #selector(setter: NSWindow.animationBehavior),
        #selector(NSWindow.cloakedSetAnimationBehavior(_:))
      ),
    ]
    for (original, replacement) in swaps {
      guard let a = class_getInstanceMethod(NSWindow.self, original),
        let b = class_getInstanceMethod(NSWindow.self, replacement)
      else { preconditionFailure("NSWindow has no \(original)") }
      method_exchangeImplementations(a, b)
    }
  }()

  /// What `window`'s code last set: what a cloaked window holds back, or what an uncloaked one
  /// holds.
  static func requested(_ window: NSWindow) -> Requested {
    held(by: window) ?? Requested(of: window)
  }

  /// Lets `window` show as the user would see it: what its code set, taking clicks as it said.
  static func exempt(_ window: NSWindow) {
    objc_setAssociatedObject(window, &Keys.exempt, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    guard let held = held(by: window) else { return }
    objc_setAssociatedObject(window, &Keys.requested, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    window.alphaValue = held.alpha
    window.ignoresMouseEvents = held.ignoresMouseEvents
    window.animationBehavior = held.animationBehavior
  }

  /// Hides `window` from the developer as it goes on screen, keeping what its code had set.
  fileprivate static func cloak(_ window: NSWindow) {
    guard held(by: window) == nil, objc_getAssociatedObject(window, &Keys.exempt) as? Bool != true
    else { return }
    let held = Requested(of: window)
    // Through the original setters: the swapped ones would hold these back too.
    window.cloakedSetAlphaValue(0)
    window.cloakedSetIgnoresMouseEvents(true)
    window.cloakedSetAnimationBehavior(.none)
    objc_setAssociatedObject(window, &Keys.requested, held, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }

  /// What a cloaked `window` holds back, or nil for a window not cloaked.
  fileprivate static func held(by window: NSWindow) -> Requested? {
    objc_getAssociatedObject(window, &Keys.requested) as? Requested
  }

  private enum Keys {
    nonisolated(unsafe) static var requested = 0
    nonisolated(unsafe) static var exempt = 0
  }
}

// After `install`, each `cloaked` method's implementation is swapped with its original's: calling
// `cloakedX` from inside the replacement, or from `TestWindowCloak`, calls the ORIGINAL.
extension NSWindow {
  @objc dynamic fileprivate func cloakedOrder(_ place: NSWindow.OrderingMode, relativeTo other: Int)
  {
    if place != .out { TestWindowCloak.cloak(self) }
    cloakedOrder(place, relativeTo: other)
  }

  @objc dynamic fileprivate func cloakedOrderFrontRegardless() {
    TestWindowCloak.cloak(self)
    cloakedOrderFrontRegardless()
  }

  @objc dynamic fileprivate func cloakedSetAlphaValue(_ value: CGFloat) {
    hold(value, as: \.alpha) { cloakedSetAlphaValue(value) }
  }

  @objc dynamic fileprivate func cloakedSetIgnoresMouseEvents(_ value: Bool) {
    hold(value, as: \.ignoresMouseEvents) { cloakedSetIgnoresMouseEvents(value) }
  }

  @objc dynamic fileprivate func cloakedSetAnimationBehavior(_ value: NSWindow.AnimationBehavior) {
    hold(value, as: \.animationBehavior) { cloakedSetAnimationBehavior(value) }
  }

  /// A swapped setter's body: a cloaked window keeps `value` as what its code asked for, any other
  /// sets it through the original (`set`).
  private func hold<T>(
    _ value: T, as field: ReferenceWritableKeyPath<TestWindowCloak.Requested, T>,
    else set: () -> Void
  ) {
    guard let held = TestWindowCloak.held(by: self) else { return set() }
    held[keyPath: field] = value
  }
}
