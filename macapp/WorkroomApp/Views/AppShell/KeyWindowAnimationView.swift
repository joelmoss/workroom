import AppKit

/// A layer-backed view whose endless Core Animation runs only while its window is key and on screen.
/// Animating in a window the user isn't looking at buys nothing, and even a compositor-side animation
/// keeps the render server awake, so a subclass's `syncAnimation()` is called whenever the window
/// becomes or resigns key or changes occlusion, and adds or removes its animation from there.
///
/// Core Animation rather than SwiftUI because a SwiftUI `repeatForever` forces a hosting-view layout
/// every display frame: the running underline cost 25–40% CPU all day that way (`SweepView`).
class KeyWindowAnimationView: NSView {
  // Main-thread only; `nonisolated(unsafe)` so `deinit` can remove them.
  nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

  deinit {
    for o in windowObservers { NotificationCenter.default.removeObserver(o) }
  }

  /// Whether the window is key and at least partly visible.
  var windowIsShowing: Bool {
    window?.isKeyWindow == true && window?.occlusionState.contains(.visible) == true
  }

  /// Adds or removes the subclass's animation to match `windowIsShowing` and its own state.
  func syncAnimation() {}

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    for o in windowObservers { NotificationCenter.default.removeObserver(o) }
    windowObservers = []
    guard let window else { return }
    let center = NotificationCenter.default
    for name in [
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
      NSWindow.didChangeOcclusionStateNotification,
    ] {
      windowObservers.append(
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.syncAnimation() }
        })
    }
    syncAnimation()
  }
}
