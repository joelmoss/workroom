import AppKit
import SwiftUI

/// Hosts a SwiftUI view as a full-width `.left` titlebar accessory — the custom title-bar bar to the
/// RIGHT of the traffic lights, in the same row (Chrome-style). Unlike SwiftUI's `.toolbar` items,
/// a titlebar accessory is a raw view we fully control: it never collapses into an overflow `»`, so
/// the workroom tab strip (a horizontal `ScrollView`) simply scrolls when space is tight and the
/// controls stay put. A `.left` accessory takes the height of the title-bar row it sits in — which is
/// the taller `.unified`-toolbar row (see `WorkroomApp`/`rootWindowChrome`) — so AppKit centers the
/// traffic lights in that taller bar and the accessory content centers alongside them (no manual
/// button positioning).
///
/// Pattern per `github/CopilotForXcode` (`NSHostingView` as the accessory view). We keep a single
/// `NSHostingController` and refresh its `rootView` each SwiftUI update so environment/bindings stay
/// live; the accessory is installed once per window.
struct TitlebarAccessoryHost<Content: View>: NSViewRepresentable {
  private let content: Content

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  func makeNSView(context: Context) -> NSView {
    let probe = NSView(frame: .zero)
    context.coordinator.hosting.rootView = AnyView(content)
    DispatchQueue.main.async { [weak probe] in context.coordinator.install(on: probe?.window) }
    return probe
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.hosting.rootView = AnyView(content)
    context.coordinator.install(on: nsView.window)
    // Re-assert transparency: NSHostingController resets its view's backing to opaque when the content
    // re-renders (e.g. adding a workroom tab), which brought back the solid block. Reapply each update.
    context.coordinator.applyTransparency()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor final class Coordinator {
    let hosting = NSHostingController(rootView: AnyView(EmptyView()))
    private var installed = false
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    deinit {
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func install(on window: NSWindow?) {
      guard let window, !installed else { return }
      installed = true
      self.window = window
      applyTransparency()
      let vc = NSTitlebarAccessoryViewController()
      vc.layoutAttribute = .left
      vc.view = hosting.view
      window.addTitlebarAccessoryViewController(vc)
      // A `.left` accessory does NOT auto-fill — its frame must be set explicitly and kept in sync:
      // - width, so the tab strip can shrink/scroll as the window resizes (`didResize`);
      // - height, to match the title-bar row — which grows AFTER install once SwiftUI applies the
      //   `.unified` toolbar, so a one-shot measure would lag. `didUpdate` fires after every window
      //   update cycle (incl. the toolbar taking effect), so re-measuring there self-corrects the
      //   height to the taller bar. `updateFrame` is idempotent (only writes on a real change), so the
      //   frequent `didUpdate` is cheap.
      for name in [NSWindow.didResizeNotification, NSWindow.didUpdateNotification] {
        observers.append(
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.updateFrame() }
          })
      }
      updateFrame()
    }

    /// Make the hosting view transparent so the window's panel bg shows through (matches the strip
    /// behind the traffic lights); an opaque hosting view otherwise paints a solid block that
    /// mismatches the titlebar. NSHostingController re-asserts an opaque backing whenever its content
    /// re-renders (e.g. adding a workroom tab), so this must run on every SwiftUI update, not once.
    func applyTransparency() {
      hosting.view.wantsLayer = true
      hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Fill the title-bar width to the right of the traffic-light cluster, and match the height to the
    /// title-bar row (the traffic lights' own container) so the bar content vertically centers in line
    /// with the lights. Idempotent: only rewrites the frame on a real change, so the frequent
    /// `didUpdate` re-measure (which catches the unified toolbar growing the bar after install) is
    /// cheap and doesn't churn layout.
    private func updateFrame() {
      guard let window else { return }
      let width = max(window.frame.width - WorkroomTitlebar.trafficLightInset, 120)
      let titlebar = window.standardWindowButton(.closeButton)?.superview?.frame.height
      let frame = NSRect(x: 0, y: 0, width: width, height: titlebar ?? WorkroomTitlebar.height)
      if hosting.view.frame != frame { hosting.view.frame = frame }
    }
  }
}
