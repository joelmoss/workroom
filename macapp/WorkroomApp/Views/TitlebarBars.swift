import AppKit
import SwiftUI

/// Layout constants for the custom title bar. The bar is drawn as the top strip of the window's
/// (full-size) content rather than in an `NSTitlebarAccessoryViewController` — a leading accessory
/// is clamped to the native ~32pt title-bar height and can't be made taller (verified), so the
/// Chrome/Arc approach is used instead: `.fullSizeContentView` + draw the bar in content at any
/// height. Tune `height` to taste.
enum WorkroomTitlebar {
  /// Total bar height (panel background + drag area). Must stay tall enough to clear the
  /// NavigationSplitView's ~30pt top toolbar-reserve — shrinking it lets the split's sidebar column
  /// slide up and overlap the bar (clips the tabs, eats clicks). 38 is the tested-safe value.
  static let height: CGFloat = 38
  /// Leading inset so the bar's first control clears the traffic-light cluster.
  static let trafficLightInset: CGFloat = 80
}

/// A transparent backing view that lets a click-drag on the empty parts of the custom title bar
/// move the window — the content area isn't window-draggable by default (only the real title bar
/// is), so the bar needs this to stay draggable. Interactive controls drawn on top consume their
/// own clicks; clicks that fall through to this view start a window drag.
struct WindowDragBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
      // Double-click on the empty bar runs the system title-bar action (zoom/minimize); a single
      // click-drag moves the window.
      if event.clickCount == 2 {
        window?.performZoom(nil)
      } else {
        window?.performDrag(with: event)
      }
    }
  }
}

/// Toggles the window's `isMovable` to gate AppKit's automatic title-bar drag. The custom title bar
/// (issue #23) is drawn in the window's full-size content, where AppKit's title-bar drag ignores the
/// content views' `mouseDownCanMoveWindow` (verified) — so a drag anywhere in the bar, including on a
/// workroom tab chip, moves the whole *window* and steals the chip's reorder `DragGesture`. `isMovable`
/// is the one lever that actually disables that drag, but it's window-wide, so we flip it by hover:
/// the bar passes `movable = false` only while the cursor is over (or dragging) a chip, and `true`
/// otherwise — so the chips reorder while the empty bar still drags the window. Hover fires before the
/// press, so the flag is already set when the drag begins.
struct WindowMovableController: NSViewRepresentable {
  let movable: Bool

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async { [weak view] in view?.window?.isMovable = movable }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    nsView.window?.isMovable = movable
  }
}

/// The single unified title-bar toolbar, split into a leading and a trailing half hosted as
/// `NSTitlebarAccessoryViewController`s (see `TitlebarAccessory`). They sit in the window's *one*
/// title-bar row — the leading half right after the traffic lights, the trailing half at the
/// window's true trailing edge — so together they span the full width with the draggable title-bar
/// gap between them.
///
/// Why accessories rather than `.toolbar`: SwiftUI's `.toolbar` placement is column-scoped in a
/// `NavigationSplitView` (`.primaryAction` docks to a column, not the window edge), and `.toolbar`
/// items render with the framework's own chrome. Hosting plain SwiftUI `HStack`s in title-bar
/// accessories instead gives every control one shared `.borderless` style and exact placement,
/// independent of the split's columns.

/// A hairline group separator shared by the title-bar bars (matches `TitlebarControlsBar`'s).
struct TitlebarDivider: View {
  private let theme = ThemeService.shared

  var body: some View {
    Rectangle()
      .fill(theme.tokens.border)
      .frame(width: 1, height: 14)
      .padding(.horizontal, 4)
  }
}

/// Leading title-bar controls: sidebar toggle + history nav (issue #26). Our
/// own sidebar toggle (leftmost, right after the traffic lights) replaces NavigationSplitView's auto
/// one. `.toolbar(removing:)` is meant to drop it, but doesn't fully take, so the window toolbar is
/// hidden outright in `WindowBackgroundThemer` to kill its "more toolbar items" overflow chevron.
struct LeadingTitlebarBar: View {
  @EnvironmentObject var store: AppStore

  var body: some View {
    HStack(spacing: 6) {
      Button {
        store.sidebarVisible.toggle()
      } label: {
        Image(systemName: "sidebar.left")
      }
      .help(store.sidebarVisible ? "Hide sidebar (⌃⌘S)" : "Show sidebar (⌃⌘S)")
      .accessibilityLabel("Toggle sidebar")
      .accessibilityIdentifier("toolbar.toggleSidebar")
      // Hovering this button (while the sidebar is collapsed) peeks the sidebar via the edge-reveal
      // overlay (issue #74) — the trigger is the button alone, never the toolbar strip that used to
      // sit above the workroom tabs. Only report while collapsed so a hover with the sidebar pinned
      // doesn't churn reveal state.
      .onHover { hovering in
        if !store.sidebarVisible { store.hoveringLeftToggle = hovering }
      }

      TitlebarDivider()

      Button {
        store.navigateBack()
      } label: {
        Image(systemName: "chevron.left")
      }
      .help("Back (⌘[)")
      .accessibilityLabel("Back")
      .disabled(!store.canGoBack)

      Button {
        store.navigateForward()
      } label: {
        Image(systemName: "chevron.right")
      }
      .help("Forward (⌘])")
      .accessibilityLabel("Forward")
      .disabled(!store.canGoForward)
    }
    .buttonStyle(ToolbarIconButtonStyle())
    .padding(.horizontal, 10)
    // The titlebar accessory host is the full title-bar height (52pt — NOT 28), and NSHostingView
    // top-aligns a fixed-height root inside it, so the icons sat high. Fill the host and let the HStack
    // centre its buttons on the traffic-light line (the close button centres at y=26 of the 52pt host).
    .frame(maxHeight: .infinity)
  }
}

/// Trailing title-bar controls: the quick terminal (issue #39), the selected target's run/open-in
/// actions (issue #7), plus the notifications bell + inspector toggle. `RunControls`/`OpenInControl`
/// render nothing when not applicable, so the group collapses to just quick terminal + bell + toggle
/// in the empty state.
struct TrailingTitlebarBar: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @EnvironmentObject var updater: Updater

  var body: some View {
    HStack(spacing: 6) {
      // A newer version is waiting (Sparkle gentle reminder) — the accent pill leads the trailing
      // controls. Self-hides when no update is pending; the divider matches. It lives here, not in the
      // leading bar, because there it overran the sidebar and sat on the NavigationSplitView's
      // sidebar/detail divider, whose full-height resize grab zone stole the cursor (and a drag
      // resized the sidebar). At the window's trailing edge it's nowhere near that divider.
      if updater.availableVersionString != nil {
        UpdateAvailableButton()
        TitlebarDivider()
      }

      // Quick Terminal (⌥§) — a ~/ shell in its own window. First of the always-present controls (the
      // update pill precedes it only while an update is pending), just left of the run controls.
      Button {
        NotificationCenter.default.post(name: .showQuickTerminal, object: nil)
      } label: {
        // The `.badge.plus` extends this glyph's box upward, so a plain centre sits ~0.5pt high vs the
        // other icons; nudge it down to sit on the same line.
        Image(systemName: "macwindow.badge.plus")
          .offset(y: 0.5)
      }
      .help("Quick Terminal (⌥§)")
      .accessibilityLabel("Quick Terminal")
      .accessibilityIdentifier("toolbar.quickTerminal")

      if let target = store.selectedTarget, !target.isMissing {
        // Separate the quick terminal from the target's run/open-in actions — a different group.
        TitlebarDivider()
        if let projectPath = AppStore.projectPath(of: store.selectedTargetID) {
          RunControls(target: target, projectPath: projectPath)
        }
        OpenInControl(path: target.path)
      }
      // Bell + inspector toggle (carries its own padding/divider/style).
      TitlebarControlsBar()
    }
    .buttonStyle(ToolbarIconButtonStyle())
    // Fill the full-height (52pt) accessory host so the HStack centres its buttons — see LeadingTitlebarBar.
    .frame(maxHeight: .infinity)
  }
}
