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
  /// What a window's code last set, which a cloaked window holds back.
  struct Requested {
    var alpha: CGFloat
    var ignoresMouseEvents: Bool
    var animationBehavior: NSWindow.AnimationBehavior
  }

  nonisolated(unsafe) private static var installed = false

  static func install() {
    guard !installed else { return }
    installed = true
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
  }

  /// What `window`'s code last set: what a cloaked window holds back, or what an uncloaked one
  /// holds.
  static func requested(_ window: NSWindow) -> Requested {
    stored(window)
      ?? Requested(
        alpha: window.alphaValue, ignoresMouseEvents: window.ignoresMouseEvents,
        animationBehavior: window.animationBehavior)
  }

  /// Lets `window` show as the user would see it: what its code set, taking clicks as it said.
  static func exempt(_ window: NSWindow) {
    objc_setAssociatedObject(window, &Keys.exempt, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    guard let held = stored(window) else { return }
    objc_setAssociatedObject(window, &Keys.requested, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    window.alphaValue = held.alpha
    window.ignoresMouseEvents = held.ignoresMouseEvents
    window.animationBehavior = held.animationBehavior
  }

  /// Hides `window` from the developer as it goes on screen, keeping what its code had set.
  fileprivate static func cloak(_ window: NSWindow) {
    guard stored(window) == nil, objc_getAssociatedObject(window, &Keys.exempt) as? Bool != true
    else { return }
    let held = Requested(
      alpha: window.alphaValue, ignoresMouseEvents: window.ignoresMouseEvents,
      animationBehavior: window.animationBehavior)
    // Through the original setters: the swapped ones would hold these back too.
    window.cloakedSetAlphaValue(0)
    window.cloakedSetIgnoresMouseEvents(true)
    window.cloakedSetAnimationBehavior(.none)
    store(held, on: window)
  }

  /// What a cloaked `window` holds back, or nil for a window not cloaked.
  fileprivate static func stored(_ window: NSWindow) -> Requested? {
    (objc_getAssociatedObject(window, &Keys.requested) as? Box)?.value
  }

  fileprivate static func store(_ value: Requested, on window: NSWindow) {
    objc_setAssociatedObject(
      window, &Keys.requested, Box(value), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }

  private final class Box {
    let value: Requested
    init(_ value: Requested) { self.value = value }
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
    guard var held = TestWindowCloak.stored(self) else { return cloakedSetAlphaValue(value) }
    held.alpha = value
    TestWindowCloak.store(held, on: self)
  }

  @objc dynamic fileprivate func cloakedSetIgnoresMouseEvents(_ value: Bool) {
    guard var held = TestWindowCloak.stored(self) else {
      return cloakedSetIgnoresMouseEvents(value)
    }
    held.ignoresMouseEvents = value
    TestWindowCloak.store(held, on: self)
  }

  @objc dynamic fileprivate func cloakedSetAnimationBehavior(_ value: NSWindow.AnimationBehavior) {
    guard var held = TestWindowCloak.stored(self) else {
      return cloakedSetAnimationBehavior(value)
    }
    held.animationBehavior = value
    TestWindowCloak.store(held, on: self)
  }
}
