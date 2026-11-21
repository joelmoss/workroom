import Defaults
import DesignSystem
import SwiftUI

// What Settings ▸ Themes (`ThemesSettingsPane`) and the ⌘⇧K picker (`ThemePicker`) share: the
// Family | Light | Dark choice (`ThemePickerTab`), the theme lists, the search, the row IDs, the
// settle on the current choice, and the terminal-output preview.

extension ThemeSide {
  /// "Light" or "Dark", for labels; lowercased in running text.
  var title: String { self == .dark ? "Dark" : "Light" }

  /// The other side.
  var other: ThemeSide { self == .dark ? .light : .dark }
}

/// The scroll IDs of theme rows and tiles, in one place, so a `scrollTo` and the row it means can't
/// drift apart.
enum ThemeRowID {
  static func family(_ name: String) -> String { "family:\(name)" }
  static func theme(_ name: String, on side: ThemeSide) -> String { "\(side.rawValue):\(name)" }
}

/// The theme lists, read once per presentation (#737): the user's own theme files are read from disk
/// when a list first loads, not on every body pass, since each choice re-renders every row. A plain
/// class held in `@State`: a host re-render builds a throwaway instance whose init reads nothing, and
/// only the instance SwiftUI keeps ever loads.
@MainActor
final class ThemeLists {
  private var themes: [ThemeSide: [ListedTheme]] = [:]
  private var families: [ThemeFamily]?

  func themes(on side: ThemeSide) -> [ListedTheme] {
    Self.memoized(&themes[side]) { ThemeCatalog.themes(on: side) }
  }

  /// The families whose themes are both on their sides (`ThemeCatalog.availableFamilies`).
  func availableFamilies() -> [ThemeFamily] {
    Self.memoized(&families, ThemeCatalog.availableFamilies)
  }

  /// `items` whose name contains `query`, ignoring case and surrounding spaces; all of them for an
  /// empty query.
  static func filtered<T>(_ items: [T], by query: String, name: (T) -> String) -> [T] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return items }
    return items.filter { name($0).localizedCaseInsensitiveContains(q) }
  }

  /// `slot`'s value, loading it into `slot` the first time.
  private static func memoized<T>(_ slot: inout T?, _ load: () -> T) -> T {
    if let cached = slot { return cached }
    let loaded = load()
    slot = loaded
    return loaded
  }
}

/// Moves a theme list to its current choice out of sight. While `ready` is false the host hides the
/// list behind a loading state; `settle` scrolls twice, since a lazy list only learns its rows' real
/// heights once the first jump lays them out, then reveals it with a short fade. `target` is read at
/// each step, so a choice made mid-settle (an arrow press) is where the list ends up. A settle started
/// before the last one finished supersedes it, so it can't reveal the list early.
@MainActor
@Observable
final class ThemeListSettle {
  private(set) var ready = false
  @ObservationIgnored private var generation = 0

  func settle(_ proxy: ScrollViewProxy, on target: @escaping @MainActor () -> String?) {
    ready = false
    generation += 1
    let mine = generation
    guard let first = target() else {
      ready = true
      return
    }
    proxy.scrollTo(first, anchor: .center)
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(16))
      guard mine == generation else { return }
      if let id = target() { proxy.scrollTo(id, anchor: .center) }
      try? await Task.sleep(for: .milliseconds(16))
      guard mine == generation else { return }
      if let id = target() { proxy.scrollTo(id, anchor: .center) }
      withAnimation(.easeOut(duration: 0.15)) { ready = true }
    }
  }
}

/// Keeps the keyboard's current row wholly on screen as arrows move it. The host feeds `fullyVisible`
/// from `onScrollTargetVisibilityChange`; `reveal` scrolls only when the row isn't wholly visible,
/// flush with the edge it's moving towards, without animation (each press applies a theme and
/// repaints the list, and an animated scroll that a quick next press interrupted was left short).
/// Checked again on the next frame, after that repaint. A plain class held in `@State`.
@MainActor
final class ThemeListReveal {
  var fullyVisible: Set<String> = []

  func reveal(
    _ proxy: ScrollViewProxy, _ id: String, movingForward: Bool,
    stillCurrent: @escaping @MainActor () -> Bool
  ) {
    let anchor: UnitPoint = movingForward ? .bottom : .top
    if !fullyVisible.contains(id) { proxy.scrollTo(id, anchor: anchor) }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(16))
      guard stillCurrent(), !fullyVisible.contains(id) else { return }
      proxy.scrollTo(id, anchor: anchor)
    }
  }
}

/// The list's loading state while `ThemeListSettle` moves it.
struct ThemeListLoading: View {
  var body: some View {
    ProgressView().controlSize(.small).accessibilityLabel("Loading themes")
  }
}

extension ThemePreview {
  /// A palette colour, or the foreground when the theme leaves that slot out.
  fileprivate func ansi(_ index: Int) -> Color {
    Color(nsColor: palette.indices.contains(index) ? palette[index] : foreground)
  }
}

/// A few lines of coloured terminal output in a theme's own colours: a prompt with a cursor, an added
/// and a removed line. The cursor takes the accent (palette 4), as the chrome does. Shared by
/// Settings ▸ Themes and the ⌘⇧K picker (`ThemePicker`).
struct TerminalSnippet: View {
  let preview: ThemePreview?
  var fontSize: CGFloat = 9.5
  /// How many lines to show, from the top: the prompt, then the added line, then the removed one.
  var lines = 3

  var body: some View {
    let missing = Color.secondary
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 0) {
        Text("~/app ").foregroundStyle(preview?.ansi(6) ?? missing)
        Text("main ").foregroundStyle(preview?.ansi(5) ?? missing)
        Text("❯ ").foregroundStyle(preview?.ansi(2) ?? missing)
        Rectangle()
          .fill(preview?.ansi(4) ?? missing)
          .frame(width: fontSize * 0.55, height: fontSize * 1.2)
      }
      if lines > 1 {
        Text("+ let theme = \"new\"").foregroundStyle(preview?.ansi(2) ?? missing)
      }
      if lines > 2 {
        Text("- let theme = \"old\"").foregroundStyle(preview?.ansi(1) ?? missing)
      }
    }
    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .frame(
      minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading
    )
    .clipped()
    .background(preview.map { Color(nsColor: $0.background) } ?? Color.primary.opacity(0.06))
  }
}
