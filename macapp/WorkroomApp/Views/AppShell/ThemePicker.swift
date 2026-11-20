import Defaults
import DesignSystem
import SwiftUI

/// Which list the theme picker shows (#735): theme families, light themes or dark themes.
enum ThemePickerTab: String, CaseIterable, Identifiable {
  case family
  case light
  case dark

  var id: String { rawValue }

  init(side: ThemeSide) { self = side == .dark ? .dark : .light }

  /// The tab for the side that's showing, which is what ⌘⇧K and the titlebar button open on.
  @MainActor static func current() -> ThemePickerTab {
    ThemePickerTab(side: ThemeService.showingSide())
  }

  var label: String {
    switch self {
    case .family: return "Family"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }

  /// The side this tab chooses for, or nil for the Family tab, which chooses both.
  var side: ThemeSide? {
    switch self {
    case .family: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }

  var help: String {
    switch self {
    case .family: return "Theme families: choosing one sets both the light theme and the dark theme"
    case .light: return "Light themes: the theme Workroom uses while the appearance is light"
    case .dark: return "Dark themes: the theme Workroom uses while the appearance is dark"
    }
  }
}

/// One row of the picker: a theme family on the Family tab, a theme on the Light or Dark tab.
private enum ThemePickerEntry: Identifiable, Equatable {
  case family(ThemeFamily)
  case theme(ListedTheme)

  var id: String {
    switch self {
    case .family(let family): return "family:\(family.name)"
    case .theme(let theme): return "\(theme.side.rawValue):\(theme.name)"
    }
  }

  var name: String {
    switch self {
    case .family(let family): return family.name
    case .theme(let theme): return theme.name
    }
  }
}

/// The picker's lists, read once per presentation (#737): the user's own theme files are read from
/// disk when the list loads, not on every body pass, since each ↑/↓ applies a theme and re-renders
/// every row. A plain class held in `@State`: a host re-render builds a throwaway instance whose init
/// reads nothing, and only the instance SwiftUI keeps ever loads.
@MainActor
private final class ThemePickerLists {
  private var themes: [ThemeSide: [ListedTheme]] = [:]
  private var families: [ThemeFamily]?

  func themes(on side: ThemeSide) -> [ListedTheme] {
    Self.memoized(&themes[side]) { ThemeCatalog.themes(on: side) }
  }

  /// The families whose themes are both on their sides (`ThemeCatalog.availableFamilies`).
  func availableFamilies() -> [ThemeFamily] {
    Self.memoized(&families, ThemeCatalog.availableFamilies)
  }

  /// `slot`'s value, loading it into `slot` the first time.
  private static func memoized<T>(_ slot: inout T?, _ load: () -> T) -> T {
    if let cached = slot { return cached }
    let loaded = load()
    slot = loaded
    return loaded
  }
}

/// Theme chooser (issues #36, #733, #735). A **Family | Light | Dark** tab control over one search
/// field shared by every tab:
///
/// - **Family** rows show a dual (dark + light) swatch; choosing one sets both the light theme and the
///   dark theme.
/// - **Light** and **Dark** rows list only the themes on that side, each with one swatch; choosing one
///   changes only that side.
///
/// ↑/↓ apply live on every tab, and the current choice is scrolled into view when the picker opens or
/// the tab changes. On the tab for the side that isn't showing (Light while in Dark), a choice is saved
/// without changing the appearance or repainting (`ThemeService.apply(theme:for:)`), and a note says
/// when it applies. Both hosts are popovers: the titlebar's theme dropdown (`TrailingTitlebarBar`,
/// ⌘⇧K), which opens on the current appearance's tab, and the Settings rows, each opening its own.
struct ThemePicker: View {
  /// The size this picker frames itself to; both popovers size themselves from the rendered frame.
  static let contentSize = CGSize(width: 300, height: 420)

  @Environment(\.themeTokens) private var tokens
  @Environment(\.dismiss) private var dismiss
  @Default(.lightTheme) private var lightTheme
  @Default(.darkTheme) private var darkTheme
  /// Observed, not only read through `ThemeService.showingSide()`: ⌘⇧L flips the appearance with the
  /// picker left open, and the note about the other side has to follow it.
  @Default(.appearance) private var appearance

  @State private var tab: ThemePickerTab
  @State private var lists = ThemePickerLists()
  @State private var query = ""
  /// Index into `entries` of the keyboard-highlighted row (↑/↓ move it, ⏎ dismisses).
  @State private var highlighted = 0
  /// Focus on the search field, claimed explicitly on appear rather than left to the host. Without
  /// focus in this tree nothing works — not typing, and not ↑/↓, which reach `.onKeyPress` only
  /// through the focused SwiftUI view.
  @FocusState private var searchFocused: Bool

  init(tab: ThemePickerTab = .family) {
    _tab = State(initialValue: tab)
  }

  /// The family the light and dark themes match, or nil for a custom pair.
  private var activeFamily: ThemeFamily? {
    ThemeCatalog.family(light: lightTheme, dark: darkTheme)
  }

  /// The side that's on screen. Reads `appearance` so SwiftUI re-evaluates it when that changes; a
  /// System appearance flip re-renders through the theme tokens instead.
  private var showingSide: ThemeSide {
    _ = appearance
    return ThemeService.showingSide()
  }

  /// The current tab's rows, filtered by the shared search.
  private var entries: [ThemePickerEntry] {
    let all: [ThemePickerEntry]
    switch tab.side {
    case nil: all = lists.availableFamilies().map { .family($0) }
    case let side?: all = lists.themes(on: side).map { .theme($0) }
    }
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return all }
    return all.filter { $0.name.localizedCaseInsensitiveContains(q) }
  }

  private func isActive(_ entry: ThemePickerEntry) -> Bool {
    switch entry {
    case .family(let family): return family == activeFamily
    case .theme(let theme):
      return theme.name == (theme.side == .dark ? darkTheme : lightTheme)
    }
  }

  private func choose(_ entry: ThemePickerEntry) {
    switch entry {
    case .family(let family): ThemeService.shared.applyFamily(family)
    case .theme(let theme): ThemeService.shared.apply(theme: theme.name, for: theme.side)
    }
  }

  /// The highlight's starting row for the current tab: its current choice, else the first row.
  private var activeIndex: Int { entries.firstIndex { isActive($0) } ?? 0 }

  @ViewBuilder
  private func row(_ entry: ThemePickerEntry, highlighted: Bool) -> some View {
    let active = isActive(entry)
    Group {
      switch entry {
      case .family(let family):
        ThemePickerRow(
          name: family.name,
          // Dark left, light right.
          swatches: [family.dark, family.light].map { ($0, ThemeService.themePreview(named: $0)) },
          isActive: active,
          isHighlighted: highlighted,
          activeHelp: "\(family.name) is your theme family: your light theme and your dark theme "
            + "are both from it",
          activeLabel: "Your theme family",
          identifier: "theme-family-\(family.name)"
        )
      case .theme(let theme):
        let sideName = theme.side == .dark ? "dark" : "light"
        ThemePickerRow(
          name: theme.name,
          swatches: [(theme.name, ThemeService.themePreview(named: theme.name))],
          isActive: active,
          isHighlighted: highlighted,
          activeHelp: "\(theme.name) is your \(sideName) theme",
          activeLabel: "Your \(sideName) theme",
          // The side in the identifier is what lets `ThemePickerUITests` tell which tab opened.
          identifier: "theme-\(theme.side.rawValue)-\(theme.name)",
          isUserTheme: theme.isUserTheme
        )
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { choose(entry) }
  }

  /// Move the highlight by `delta` (clamped) and apply that row live — ↑/↓ change the theme
  /// immediately, no ⏎ needed.
  private func moveHighlight(_ delta: Int) {
    let rows = entries
    guard !rows.isEmpty else { return }
    highlighted = min(max(highlighted + delta, 0), rows.count - 1)
    choose(rows[highlighted])
  }

  var body: some View {
    VStack(spacing: 0) {
      searchField
      tabBar
      if let side = tab.side, side != showingSide {
        appliesLaterNote(side)
      }

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            let rows = entries
            if rows.isEmpty {
              Text("No themes match “\(query)”")
                .font(.footnote)
                .foregroundStyle(tokens.fgMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
              ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                row(entry, highlighted: index == highlighted)
                  .id(entry.id)
              }
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
        }
        .onChange(of: highlighted) { _, new in
          let rows = entries
          if rows.indices.contains(new) {
            withAnimation(.easeInOut(duration: 0.1)) { proxy.scrollTo(rows[new].id) }
          }
        }
        // Start the highlight on the current choice and scroll it into view — when the picker opens,
        // and again on each tab, since each tab has a choice of its own. Neither applies anything:
        // only an arrow key or a click does.
        .onAppear { highlightActive(proxy) }
        // A search shrinks the list under a scroll offset that may sit far past its new end, which
        // left the list blank, so a search goes back to the top, where its highlight now is.
        .onChange(of: query) { _, _ in
          if let first = entries.first { proxy.scrollTo(first.id, anchor: .top) }
        }
        .onChange(of: tab) { _, _ in highlightActive(proxy) }
      }
    }
    .frame(width: Self.contentSize.width, height: Self.contentSize.height)
    // ↑/↓ move through the list and apply the row live; ⏎ dismisses. The search field keeps text
    // focus; single-line fields don't consume the arrow keys, so they bubble here.
    .onKeyPress(.upArrow) {
      moveHighlight(-1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      moveHighlight(1)
      return .handled
    }
    .onKeyPress(.return) {
      dismiss()
      return .handled
    }
    // Esc closes too, explicitly rather than trusting the host: a popover's own cancel handling depends
    // on its behaviour mode, which SwiftUI doesn't expose, and the Settings popover has no other way out
    // besides clicking away.
    .onExitCommand { dismiss() }
    .onChange(of: query) { _, _ in highlighted = 0 }
    // `.task`, not `.onAppear`: it runs after the view is installed in its window, and focus set before
    // that is dropped — which leaves a picker you can't type into. There is no `await` here, so this is
    // not a suspension; it relies only on when SwiftUI schedules the task. Both hosts are popovers,
    // which rebuild their content on each presentation, so `searchFocused` starts false every time and
    // this can't no-op on a reused view.
    .task { searchFocused = true }
  }

  private func highlightActive(_ proxy: ScrollViewProxy) {
    let rows = entries
    let idx = activeIndex
    highlighted = idx
    if rows.indices.contains(idx) {
      proxy.scrollTo(rows[idx].id, anchor: .center)
    }
  }

  /// Family | Light | Dark. Plain buttons rather than a segmented `Picker`, so each tab carries its own
  /// tooltip and identifier, and choosing one hands focus straight back to the search field.
  private var tabBar: some View {
    HStack(spacing: 2) {
      ForEach(ThemePickerTab.allCases) { candidate in
        let selected = candidate == tab
        Button {
          tab = candidate
          searchFocused = true
        } label: {
          Text(candidate.label)
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? tokens.fg : tokens.fgMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
              RoundedRectangle(cornerRadius: Radius.s)
                .fill(selected ? tokens.surface : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(candidate.help)
        .accessibilityLabel(candidate.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("theme-picker.tab.\(candidate.rawValue)")
      }
    }
    .padding(2)
    .background(
      RoundedRectangle(cornerRadius: Radius.m)
        .strokeBorder(tokens.border, lineWidth: 0.5)
    )
    .padding(.horizontal, 10)
    .padding(.bottom, 6)
  }

  /// Shown on the tab for the side that isn't showing: a choice there is saved, but the screen keeps
  /// the theme it has until the appearance changes.
  private func appliesLaterNote(_ side: ThemeSide) -> some View {
    let appearance = side == .dark ? "Dark" : "Light"
    let showing = side == .dark ? "Light" : "Dark"
    return HStack(spacing: 4) {
      Image(systemName: "info.circle").accessibilityHidden(true)
      Text("Applies when the appearance is \(appearance)")
        .accessibilityIdentifier("theme-picker.note")
    }
    .font(.footnote)
    .foregroundStyle(tokens.fgMuted)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.bottom, 4)
    .help(
      "The appearance is \(showing), so the \(appearance.lowercased()) theme you choose here is "
        + "saved and shows when the appearance is \(appearance).")
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(tokens.fgDim)
      TextField("Search themes", text: $query)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain).foregroundStyle(tokens.fgDim)
        .help("Clear search")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: Radius.m)
        .fill(tokens.surface)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.m).strokeBorder(tokens.border, lineWidth: 0.5))
    )
    .padding(10)
  }
}

/// One row of the picker: a theme family on the Family tab (a dual swatch, dark left and light
/// right) or a theme on the Light or Dark tab (its single swatch, with a "Yours" label on the user's
/// own theme files, #737). The name, the checkmark on the current choice, and the row's chrome and
/// hover are the same on every tab.
///
/// Deliberately `internal`, not `private` (same reason as `HistoryRow`/`FileTreeRowView`):
/// `ThemePickerInvalidationTests` measures its rebuild cost directly.
struct ThemePickerRow: View {
  @Environment(\.themeTokens) private var tokens
  let name: String
  /// The themes the row previews, one swatch each, left to right: each theme-file name with its
  /// preview, or nil when the file doesn't resolve.
  let swatches: [(file: String, preview: ThemePreview?)]
  let isActive: Bool
  var isHighlighted = false
  /// The checkmark's tooltip and accessibility label.
  let activeHelp: String
  let activeLabel: String
  let identifier: String
  var isUserTheme = false
  @State private var hovered = false

  #if DEBUG
    /// How many times ANY row's body has been evaluated this process — the measurement behind
    /// `ThemePickerInvalidationTests` (WORKROOM-2B follow-up). Debug-only.
    static var bodyPasses = 0
  #endif

  var body: some View {
    #if DEBUG
      Self.bodyPasses += 1
    #endif
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(name)
          .font(.system(size: 12, weight: isActive ? .semibold : .medium))
          .foregroundStyle(isActive ? tokens.accent : tokens.fg)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(name)
        if isUserTheme { yoursLabel }
        Spacer(minLength: 0)
        if isActive {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(tokens.accent)
            .help(activeHelp)
            .accessibilityLabel(activeLabel)
        }
      }
      HStack(spacing: 4) {
        ForEach(swatches.indices, id: \.self) { index in
          Swatch(preview: swatches[index].preview, variantName: swatches[index].file)
        }
      }
      .frame(height: 16)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    // Accent ring on the current choice; a fainter ring on the keyboard-highlighted row so ↑/↓
    // focus is visible even when it isn't the current one.
    .pickerRowChrome(highlighted: isHighlighted, hovered: hovered, active: isActive)
    .onHover { hovered = $0 }
    // Queryable by `ThemePickerUITests`. Two things here are load-bearing and were both found by
    // running the test rather than by reasoning:
    //
    // `children: .contain` — WITHOUT it, an identifier on this container makes the row an a11y LEAF:
    // the identifier propagates to every descendant (four elements answered to the same one) and
    // `row.descendants(...)` came back empty, so the per-swatch assertions could never see anything.
    //
    // The identifier goes on the SwiftUI row, never on an `NSViewRepresentable` wrapper — an
    // identifier set on a wrapper isn't reachable from XCUITest at all.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }

  /// Marks a theme as one of the user's own files. Its identifier extends the row's, so
  /// `ThemePickerUITests` can ask whether a given row carries it.
  private var yoursLabel: some View {
    Text("Yours")
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(tokens.fgMuted)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(Capsule().strokeBorder(tokens.border, lineWidth: 0.5))
      .fixedSize()
      .help("Your own theme, from ~/.config/ghostty/themes")
      .accessibilityLabel("Your own theme")
      .accessibilityIdentifier("\(identifier)-yours")
  }
}

/// A single variant preview: the background with an "Ab" sample over a strip of the 16 palette
/// colours — the muxy swatch pattern.
private struct Swatch: View {
  @Environment(\.themeTokens) private var tokens
  let preview: ThemePreview?
  /// The variant's theme-file name. Carried purely so the swatch can report, through accessibility,
  /// *which* file it is drawing and whether that file resolved — the visible symptom of a registry
  /// typo is a grey fallback swatch, and that is the one failure a bundle-reading unit test can't see.
  let variantName: String

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(preview.map { Color(nsColor: $0.background) } ?? tokens.surface)
        .overlay(
          Text("Ab")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(preview.map { Color(nsColor: $0.foreground) } ?? tokens.fgMuted)
        )
        .frame(width: 26)
      ForEach(Array((preview?.palette ?? []).enumerated()), id: \.offset) { _, c in
        Rectangle().fill(Color(nsColor: c))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 3))
    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tokens.border, lineWidth: 0.5))
    .accessibilityElement()
    // Resolution state rides the IDENTIFIER, not `accessibilityValue`: a value set on a
    // non-control element like this one comes back empty through XCUIElement (measured), while
    // identifiers are reliably queryable.
    .accessibilityIdentifier(
      "theme-swatch-\(variantName)-\(preview == nil ? "unresolved" : "resolved")")
  }
}
