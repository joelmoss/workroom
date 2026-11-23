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
  func ansi(_ index: Int) -> Color {
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

// MARK: - Favourites

/// The star of the favourites controls: filled in the accent when `filled`, else an outline in
/// `outlineColor`, the host's muted text colour. The fill changes with a symbol replace.
struct FavouriteStarGlyph: View {
  @Environment(\.themeTokens) private var tokens
  let filled: Bool
  let size: CGFloat
  let outlineColor: Color

  var body: some View {
    Image(systemName: filled ? "star.fill" : "star")
      .font(.system(size: size, weight: .semibold))
      .foregroundStyle(filled ? tokens.accent : outlineColor)
      .contentTransition(.symbolEffect(.replace))
  }
}

/// "Add to Favourites" or "Remove from Favourites", in a theme's context menu.
struct FavouriteMenuItem: View {
  let favourite: ThemeFavourite
  let isFavourite: Bool

  var body: some View {
    Button(isFavourite ? "Remove from Favourites" : "Add to Favourites") {
      ThemeFavourites.toggle(favourite)
    }
  }
}

/// The star on a theme row or tile: filled on a favourite, always; an outline while `revealed` (the
/// row is hovered) on any other. Clicking it stars or unstars the theme without choosing it.
struct FavouriteStar: View {
  let favourite: ThemeFavourite
  let isFavourite: Bool
  let revealed: Bool
  let size: CGFloat
  let outlineColor: Color
  let identifier: String

  /// The width the star takes in its row, whether it shows or not, so a row's name doesn't shift as
  /// the star comes and goes.
  static func footprint(_ size: CGFloat) -> CGFloat { size + 5 }

  private var tooltip: String {
    let name = favourite.name
    let action =
      isFavourite ? "Remove \(name) from your favourites" : "Add \(name) to your favourites"
    // "The theme you're on": the picker's highlighted row, or the Settings tile the keyboard is on
    // (the current choice, else the first tile), which both lists ring.
    return "\(action). ⌘D does the same for the theme you're on."
  }

  var body: some View {
    let shows = isFavourite || revealed
    Button {
      ThemeFavourites.toggle(favourite)
    } label: {
      FavouriteStarGlyph(filled: isFavourite, size: size, outlineColor: outlineColor)
        .frame(width: Self.footprint(size), height: size + 3)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Only the fade is animated, so a star never slides with a tile that a filter moved.
    .animation(.easeOut(duration: 0.12)) { $0.opacity(shows ? 1 : 0) }
    // A hidden star leaves the click to the row, which chooses the theme.
    .allowsHitTesting(shows)
    .help(tooltip)
    .accessibilityLabel(isFavourite ? "Favourite" : "Add to favourites")
    .accessibilityAddTraits(isFavourite ? .isSelected : [])
    .accessibilityIdentifier("\(identifier)-star")
  }
}

/// The favourites filter, at the trailing end of a theme search field: an outline star while every
/// theme is listed, a filled one in the accent while only favourites are. One setting for every theme
/// list (`themeFavouritesOnly`), flipped through the host's list so the list rebuilds.
struct FavouritesFilterButton: View {
  @Environment(\.themeTokens) private var tokens
  let favourites: ThemeListFavourites
  let outlineColor: Color
  let identifier: String
  var onToggle: () -> Void = {}

  var body: some View {
    let on = favourites.favouritesOnly
    Button {
      favourites.toggleFilter()
      onToggle()
    } label: {
      FavouriteStarGlyph(filled: on, size: 11, outlineColor: outlineColor)
        .frame(width: 20, height: 18)
        .background(
          RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .fill(on ? tokens.accent.opacity(0.16) : .clear)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .animation(.easeOut(duration: 0.12), value: on)
    .help(on ? "Show all themes (⌘F)" : "Show only favourites (⌘F)")
    .accessibilityLabel("Favourites only")
    .accessibilityAddTraits(.isToggle)
    .accessibilityAddTraits(on ? .isSelected : [])
    .accessibilityValue(on ? "On" : "Off")
    .accessibilityIdentifier(identifier)
  }
}

/// An empty theme list (`ThemeListEmptyState`), laid out alike in the ⌘⇧K picker and in Settings ▸
/// Themes. A tab with no favourites says how to star one and offers every theme back, through the
/// host's list so the list rebuilds.
struct ThemeListEmptyView: View {
  @Environment(\.themeTokens) private var tokens
  let state: ThemeListEmptyState
  let favourites: ThemeListFavourites
  let identifier: String
  var onShowAll: () -> Void = {}

  var body: some View {
    VStack(spacing: Spacing.s) {
      Image(systemName: icon)
        .font(FontRole.messageGlyph)
        .foregroundStyle(tokens.fgDim)
        .accessibilityHidden(true)
      Text(state.title)
        .font(FontRole.body)
        .foregroundStyle(tokens.fgMuted)
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("\(identifier).title")
      if case .noFavourites = state {
        Text("Star one with \(Image(systemName: "star")) or ⌘D")
          .font(FontRole.detail)
          .foregroundStyle(tokens.fgDim)
        Button("Show All Themes") {
          favourites.toggleFilter()
          onShowAll()
        }
        .controlSize(.small)
        .padding(.top, Spacing.xxs)
        .help("Turn off the favourites filter (⌘F)")
        .accessibilityIdentifier("\(identifier).showAll")
      }
    }
    .frame(maxWidth: .infinity, minHeight: 120)
    .padding(.horizontal, Spacing.l)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }

  private var icon: String {
    if case .noFavourites = state { return "star" }
    return "magnifyingglass"
  }
}

extension View {
  /// Hands this theme list ⌘D and ⌘F (`ThemeListKeys`) while it's on screen in its window: ⌘D
  /// stars the theme `keyboardFavourite` names, the one the keyboard is on, and ⌘F flips the
  /// favourites filter. With no theme to star (an empty list), ⌘D beeps, as a key with nothing to
  /// act on does across macOS.
  func themeListKeys(
    _ favourites: ThemeListFavourites, keyboardFavourite: @escaping () -> ThemeFavourite?
  ) -> some View {
    modifier(
      ThemeListKeysModifier { command in
        switch command {
        case .toggleFavourite:
          if let favourite = keyboardFavourite() {
            ThemeFavourites.toggle(favourite)
          } else {
            NSSound.beep()
          }
        case .toggleFilter: favourites.toggleFilter()
        }
      })
  }
}

private struct ThemeListKeysModifier: ViewModifier {
  let perform: (ThemeListKeys.Command) -> Void
  @State private var registration: UUID?
  @State private var window: NSWindow?

  func body(content: Content) -> some View {
    content
      .background(
        WindowAccessor { resolved in
          guard window !== resolved else { return }
          window = resolved
          register()
        }
      )
      .onAppear { register() }
      .onDisappear {
        if let registration { ThemeListKeys.shared.unregister(registration) }
        registration = nil
      }
  }

  private func register() {
    guard let window else { return }
    if let registration { ThemeListKeys.shared.unregister(registration) }
    registration = ThemeListKeys.shared.register(window: window, perform: perform)
  }
}
