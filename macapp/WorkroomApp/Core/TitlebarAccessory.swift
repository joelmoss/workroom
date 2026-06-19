import AppKit
import SwiftUI

/// Hosts arbitrary SwiftUI content as an `NSTitlebarAccessoryViewController` pinned to one edge of
/// the window's title bar — the AppKit escape hatch for the placement control SwiftUI's `.toolbar`
/// withholds.
///
/// Why this exists: in a `NavigationSplitView`, `.toolbar`'s `placement:` is *semantic and
/// column-scoped* — `.primaryAction` means "trailing edge of *this column*", not "trailing edge of
/// the window", and within a placement the only ordering lever is declaration order. A titlebar
/// accessory sidesteps that entirely: its `view` is a plain `NSView` we lay out ourselves, so an
/// embedded SwiftUI `HStack` gets exact spacing, alignment, and ordering across the full window
/// width, independent of the split's columns.
///
/// Mechanics mirror `WindowBackgroundThemer`/`SplitViewAutosave`: a zero-size probe locates the host
/// `NSWindow` once it's mounted, then installs (once, keyed by `identifier`) an accessory whose view
/// is an `NSHostingView`. The hosted SwiftUI tree observes `@EnvironmentObject`/`@Default` normally,
/// so pass any environment objects *inside* the `content` closure (they're captured at install and,
/// being reference types, keep updating the bar live).
struct TitlebarAccessory<Content: View>: NSViewRepresentable {
  /// `.trailing` or `.leading` — the title-bar edge the accessory docks to. (`.bottom` is also legal
  /// but stacks a full-width strip under the title bar, which isn't what we want here.)
  var edge: NSLayoutConstraint.Attribute
  /// Stable id so the accessory is installed exactly once even if SwiftUI re-creates the probe.
  var identifier: NSUserInterfaceItemIdentifier
  @ViewBuilder var content: () -> Content

  func makeNSView(context: Context) -> NSView {
    context.coordinator.content = content
    let probe = NSView(frame: .zero)
    DispatchQueue.main.async { [weak probe] in
      context.coordinator.install(in: probe?.window, edge: edge, identifier: identifier)
    }
    return probe
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    // Re-feed the latest closure so a parent re-render (new values captured in `content`) reaches the
    // hosted tree even when SwiftUI's own observation wouldn't.
    context.coordinator.content = content
    context.coordinator.refresh()
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    MainActor.assumeIsolated { coordinator.remove() }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor final class Coordinator {
    var content: (() -> Content)?
    private weak var window: NSWindow?
    private var accessory: NSTitlebarAccessoryViewController?
    private var hosting: NSHostingView<AnyView>?

    func install(
      in window: NSWindow?, edge: NSLayoutConstraint.Attribute,
      identifier: NSUserInterfaceItemIdentifier
    ) {
      guard let window, let content else { return }
      self.window = window

      // Idempotent: if a previous probe already installed our accessory, adopt it instead of
      // stacking duplicates (SwiftUI may make/dismantle the probe across body re-evaluations).
      if let existing = window.titlebarAccessoryViewControllers.first(where: {
        $0.identifier == identifier
      }) {
        accessory = existing
        hosting = existing.view as? NSHostingView<AnyView>
        refresh()
        return
      }

      let host = NSHostingView(rootView: AnyView(content()))
      host.translatesAutoresizingMaskIntoConstraints = false
      // Size to the SwiftUI content; AppKit centres it vertically in the title bar and pins it to
      // `edge`. Without a concrete frame the accessory can collapse to zero width on first layout.
      host.frame = NSRect(origin: .zero, size: host.fittingSize)

      let controller = NSTitlebarAccessoryViewController()
      controller.identifier = identifier
      controller.layoutAttribute = edge
      controller.view = host

      window.addTitlebarAccessoryViewController(controller)
      accessory = controller
      hosting = host
    }

    func refresh() {
      guard let content, let hosting else { return }
      hosting.rootView = AnyView(content())
      hosting.frame.size = hosting.fittingSize
    }

    func remove() {
      guard let window, let accessory,
        let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory)
      else { return }
      window.removeTitlebarAccessoryViewController(at: index)
      self.accessory = nil
      self.hosting = nil
    }
  }
}
