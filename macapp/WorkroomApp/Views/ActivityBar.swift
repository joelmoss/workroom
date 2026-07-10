import Defaults
import SwiftUI

/// The right **activity bar** (issue: activity bar) — a thin vertical icon rail pinned to the
/// window's trailing edge, VSCode-style. One large icon per `ActivitySection`; clicking one shows
/// that section's pane in the inspector, clicking the active one collapses the pane (the bar stays).
///
/// Always visible (unlike the inspector content pane it drives). Flat `panel` chrome with a leading
/// hairline so it reads as the same surface as the title bar and sidebars. Lives inside `RootView`'s
/// detail `HStack` — inside the detail-only `NavigationSplitView` — so its buttons get working
/// `.onHover` tracking (a raw content view near the title bar loses it, issue #114).
struct ActivityBar: View {
  @EnvironmentObject var store: AppStore
  @Default(.showInspector) private var showInspector
  // Bumped on `.themeDidChange` so the flat panel fill + hairline repaint live on a theme switch
  // (tokens are read from the `ThemeService` singleton, which SwiftUI doesn't observe on its own).
  @State private var themeTick = 0
  private let theme = ThemeService.shared
  private let width: CGFloat = 44

  var body: some View {
    VStack(spacing: 2) {
      ForEach(ActivitySection.allCases) { section in
        ActivityBarButton(
          section: section,
          // Active only while the pane is actually shown — a closed inspector highlights nothing
          // (VSCode behaviour), so the bar never implies content is visible when it isn't.
          active: showInspector && store.activeInspectorSection == section
        ) {
          store.apply(.iconClick(section))
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 6)
    .frame(width: width)
    .frame(maxHeight: .infinity)
    .background(theme.tokens.panel)
    .overlay(alignment: .leading) { theme.tokens.border.frame(width: 1) }
    .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in themeTick += 1 }
  }
}

/// One activity-bar icon. Active state is signalled by **position** (a 2pt accent strip on the inner
/// edge) and **brightness** (`fg` vs `fgMuted` glyph), not hue alone, so it reads for red/green
/// colour-blind users too (see the `run-status-glyph-colorblind` learning). Hover gets the standard
/// `hover` wash. Every control carries a tooltip, an accessibility label, and a stable identifier.
private struct ActivityBarButton: View {
  let section: ActivitySection
  let active: Bool
  let action: () -> Void
  @State private var hovering = false
  private let theme = ThemeService.shared

  var body: some View {
    Button(action: action) {
      Image(systemName: section.systemImage)
        .font(.system(size: 18, weight: .regular))
        .foregroundStyle(active ? theme.tokens.fg : theme.tokens.fgMuted)
        .frame(width: 44, height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background {
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 6)
          .fill(active ? theme.tokens.accentSoft : (hovering ? theme.tokens.hover : Color.clear))
          .padding(.horizontal, 4)
          .padding(.vertical, 2)
        if active {
          theme.tokens.accent
            .frame(width: 2)
            .clipShape(Capsule())
            .padding(.vertical, 8)
        }
      }
    }
    .onHover { hovering = $0 }
    .help("\(section.label) (\(section.shortcutHint))")
    .accessibilityLabel(section.label)
    .accessibilityIdentifier("activitySection.\(section.rawValue)")
    .accessibilityAddTraits(active ? [.isSelected] : [])
  }
}
