import SwiftUI

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

/// Leading title-bar controls: sidebar toggle + history nav + quick terminal (issue #26, #39). Our
/// own sidebar toggle (leftmost, right after the traffic lights) replaces NavigationSplitView's auto
/// one — removed via `.toolbar(removing:)`, with the now-itemless window toolbar hidden in
/// `WindowBackgroundThemer` so it doesn't leave an overflow chevron.
struct LeadingTitlebarBar: View {
  @EnvironmentObject var store: AppStore

  var body: some View {
    HStack(spacing: 6) {
      Button {
        store.sidebarVisible.toggle()
      } label: {
        Image(systemName: "sidebar.left")
      }
      .help(store.sidebarVisible ? "Hide sidebar" : "Show sidebar")
      .accessibilityLabel("Toggle sidebar")
      .accessibilityIdentifier("toolbar.toggleSidebar")

      TitlebarDivider()

      Button {
        store.navigateBack()
      } label: {
        Image(systemName: "chevron.left")
      }
      .help("Back")
      .accessibilityLabel("Back")
      .disabled(!store.canGoBack)

      Button {
        store.navigateForward()
      } label: {
        Image(systemName: "chevron.right")
      }
      .help("Forward")
      .accessibilityLabel("Forward")
      .disabled(!store.canGoForward)

      Button {
        NotificationCenter.default.post(name: .showQuickTerminal, object: nil)
      } label: {
        Image(systemName: "macwindow.badge.plus")
      }
      .help("Quick Terminal (⌥§)")
      .accessibilityLabel("Quick Terminal")
      .accessibilityIdentifier("toolbar.quickTerminal")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 10)
    .frame(height: 28)
  }
}

/// Trailing title-bar controls: the selected target's run/open-in actions (issue #7) plus the
/// notifications bell + inspector toggle. `RunControls`/`OpenInControl` render nothing when not
/// applicable, so the group collapses to just the bell + toggle in the empty state.
struct TrailingTitlebarBar: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore

  var body: some View {
    HStack(spacing: 6) {
      if let target = store.selectedTarget, !target.isMissing {
        if let projectPath = AppStore.projectPath(of: store.selectedTargetID) {
          RunControls(target: target, projectPath: projectPath)
        }
        OpenInControl(path: target.path)
        TitlebarDivider()
      }
      // Bell + inspector toggle (carries its own padding/divider/borderless style).
      TitlebarControlsBar()
    }
    .buttonStyle(.borderless)
    .frame(height: 28)
  }
}
