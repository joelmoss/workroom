import Defaults
import DesignSystem
import SwiftUI

/// Settings ▸ Themes (#733): every theme always in view, no popovers.
///
/// A **stage** at the top shows the light theme and the dark theme as the whole app would look, each
/// a miniature Workroom window; clicking one browses that side. Under it a **browser** — Families,
/// Light or Dark, and a search — pins to the top while the **grid** of themes scrolls under it. Each
/// tile previews a theme as a few lines of coloured terminal output in its own colours.
///
/// Choosing a family sets both themes; choosing a light or dark theme sets only that side. On the side
/// that isn't showing (Light while the appearance is Dark), a choice is saved without repainting, and
/// a note says when it applies (`ThemeService.apply(theme:for:)`).
struct ThemesSettingsPane: View {
  @Environment(\.themeTokens) private var tokens
  @Default(.lightTheme) private var lightTheme
  @Default(.darkTheme) private var darkTheme
  /// Observed so the "on screen" side and the hidden side's note follow an appearance change.
  @Default(.appearance) private var appearance

  /// What the grid lists: families, light themes or dark themes. Opens on the side that's showing,
  /// as ⌘⇧K's picker does.
  @State private var browse = ThemePickerTab.current()
  @State private var query = ""
  /// Reloaded each time the pane appears, so a theme file added or fixed meanwhile is listed.
  @State private var lists = ThemeLists()
  @FocusState private var searchFocused: Bool
  /// Moves the grid to the current choice out of sight, on opening and on each switch, so it never
  /// visibly scrolls there.
  @State private var settle = ThemeListSettle()
  /// Keeps the theme the arrows moved to wholly on screen.
  @State private var keepVisible = ThemeListReveal()
  /// Focus on the grid, where ↑/↓/←/→ move through the themes.
  @FocusState private var gridFocused: Bool
  /// The grid's width, to know how many tiles a row holds (↑/↓ move a row).
  @State private var gridWidth: CGFloat = 0

  /// The smallest tile width per list, and the gap between tiles; the grid fits as many per row as
  /// these allow.
  private static let familyTileMinWidth: CGFloat = 196
  private static let themeTileMinWidth: CGFloat = 132
  private static let tileSpacing = Spacing.l

  /// The side that's on screen. Reads `appearance` so SwiftUI re-evaluates it when that changes; a
  /// System appearance flip re-renders through the theme tokens instead.
  private var showingSide: ThemeSide {
    _ = appearance
    return ThemeService.showingSide()
  }

  private var activeFamily: ThemeFamily? { ThemeCatalog.family(light: lightTheme, dark: darkTheme) }

  private func stored(_ side: ThemeSide) -> String { side == .dark ? darkTheme : lightTheme }

  var body: some View {
    // The stage and the browser stay put and only the grid scrolls, so jumping to the current choice
    // never scrolls the stage away.
    VStack(spacing: 0) {
      stage
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.l)
      browserBar
      ScrollViewReader { proxy in
        ScrollView {
          grid
            .onGeometryChange(for: CGFloat.self) {
              $0.size.width
            } action: {
              gridWidth = $0
            }
            .padding(.horizontal, Spacing.xxl)
        }
        // A margin the scroll respects, so a tile the arrows reveal stops clear of the edges rather
        // than flush with them.
        .safeAreaPadding(.vertical, Spacing.l)
        .scrollContentBackground(.hidden)
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.99) { ids in
          keepVisible.fullyVisible = Set(ids)
        }
        // ↑/↓/←/→ move through the grid and apply each theme live, as the ⌘⇧K picker does; the ring
        // on the current choice is the cursor. The grid takes focus when the pane opens, when a tile
        // is clicked, or on ↓ from the search field.
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
          switch press.key {
          case .leftArrow: move(by: -1, proxy)
          case .rightArrow: move(by: 1, proxy)
          case .upArrow: move(by: -columns, proxy)
          default: move(by: columns, proxy)
          }
          return .handled
        }
        .task { gridFocused = true }
        .opacity(settle.ready ? 1 : 0)
        .overlay { if !settle.ready { ThemeListLoading() } }
        .onAppear {
          lists = ThemeLists()
          settleOnCurrent(proxy)
        }
        .onChange(of: browse) { _, _ in settleOnCurrent(proxy) }
        // A search shrinks the grid under a scroll offset that may sit past its new end; go back to
        // the top of the results.
        .onChange(of: query) { _, _ in
          if let first = currentIDs.first { proxy.scrollTo(first, anchor: .top) }
        }
      }
    }
  }

  // MARK: Stage

  private var stage: some View {
    VStack(alignment: .leading, spacing: Spacing.l) {
      HStack(alignment: .center, spacing: Spacing.m) {
        familySummary
        Spacer(minLength: Spacing.l)
        Text("Appearance").foregroundStyle(.secondary)
        Picker("Appearance", selection: $appearance) {
          ForEach(AppearanceMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Match the system appearance, or force Light or Dark.")
        .accessibilityIdentifier("settings.themes.appearance")
      }
      HStack(alignment: .top, spacing: Spacing.xl) {
        stageCard(.light)
        stageCard(.dark)
      }
    }
  }

  /// The family the two themes match, or "Custom", as the Appearance pane's row says it.
  private var familySummary: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text("Theme family").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
      Text(ThemeCatalog.familyLabel(light: lightTheme, dark: darkTheme))
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityLabel("Theme family")
        .accessibilityValue(ThemeCatalog.familyLabel(light: lightTheme, dark: darkTheme))
        .accessibilityIdentifier("settings.themes.family")
    }
    .help(ThemeCatalog.familySummary(light: lightTheme, dark: darkTheme))
  }

  private func stageCard(_ side: ThemeSide) -> some View {
    let name = stored(side)
    let showing = ThemeService.activeThemeName(for: side)
    let note = ThemeFallbackNote(
      side: side, stored: name, showing: showing,
      storedSide: ThemeCatalog.side(ofThemeNamed: name))
    let onScreen = side == showingSide
    let sideName = side.title
    let help =
      note.map { "\(name). \($0.help)" }
      ?? "\(name): the theme Workroom uses while the appearance is \(sideName.lowercased()). "
      + "Click to browse \(sideName.lowercased()) themes."
    // Only the window is the button, so the name and the note under it stay their own elements for
    // VoiceOver; clicking the name browses too.
    return VStack(alignment: .leading, spacing: Spacing.s) {
      Button {
        browse = ThemePickerTab(side: side)
      } label: {
        // The window shows what's on screen for that side, so a fallback previews the fallback.
        MiniWorkroomWindow(preview: ThemeService.themePreview(named: showing))
          .frame(maxWidth: .infinity)
          .frame(height: 124)
          // On the window rather than beside the name, so a long name keeps the room.
          .overlay(alignment: .topTrailing) {
            if onScreen {
              Text("On screen")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
                .padding(Spacing.s)
                .help("The appearance is \(sideName), so this theme is the one on screen.")
            }
          }
          .themeTileChrome(selected: browse.side == side, radius: Radius.m)
          .contentShape(Rectangle())
      }
      .buttonStyle(ThemeTileButtonStyle())
      .help(help)
      .accessibilityLabel("Browse \(sideName.lowercased()) themes")
      .accessibilityValue(name)
      .accessibilityAddTraits(browse.side == side ? .isSelected : [])
      .accessibilityIdentifier("settings.themes.stage.\(side.rawValue)")
      HStack(spacing: Spacing.s) {
        Image(systemName: side == .dark ? "moon.fill" : "sun.max.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(name)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.tail)
          .help(help)
          .accessibilityLabel("\(sideName) theme")
          .accessibilityValue(name)
          .accessibilityIdentifier("settings.themes.stage.\(side.rawValue).name")
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
      .onTapGesture { browse = ThemePickerTab(side: side) }
      if let note {
        Label(note.text, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(note.help)
          .accessibilityIdentifier("settings.themes.fallback.\(side.rawValue)")
      }
    }
  }

  // MARK: Browser

  private var browserBar: some View {
    VStack(alignment: .leading, spacing: Spacing.s) {
      HStack(spacing: Spacing.l) {
        Picker("Browse", selection: $browse) {
          ForEach(ThemePickerTab.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Families set both themes; Light and Dark set one side.")
        .accessibilityIdentifier("settings.themes.browse")
        searchField
      }
      if let side = browse.side, side != showingSide {
        let sideName = side.title
        Label("Applies when the appearance is \(sideName)", systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help(
            "The appearance is \(side.other.title), so the "
              + "\(sideName.lowercased()) theme you choose here is saved and shows when the "
              + "appearance is \(sideName)."
          )
          .accessibilityIdentifier("settings.themes.note")
      }
    }
    .padding(.horizontal, Spacing.xxl)
    .padding(.vertical, Spacing.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tokens.panel)
    .overlay(alignment: .top) { Rectangle().fill(tokens.border).frame(height: 0.5) }
    .overlay(alignment: .bottom) { Rectangle().fill(tokens.border).frame(height: 0.5) }
  }

  private var searchField: some View {
    HStack(spacing: Spacing.s) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
      TextField("Search themes", text: $query)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        .help("Search the themes listed below by name; ↓ moves into them")
        .onKeyPress(.downArrow) {
          gridFocused = true
          return .handled
        }
        .accessibilityIdentifier("settings.themes.search")
      if !query.isEmpty {
        Button {
          query = ""
          searchFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Clear search")
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, Spacing.m)
    .frame(height: 24)
    .background(RoundedRectangle(cornerRadius: Radius.s).fill(Color.primary.opacity(0.06)))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.s)
        .strokeBorder(searchFocused ? tokens.accent.opacity(0.7) : .clear, lineWidth: 1.5)
    )
  }

  // MARK: Grid

  private func filtered<T>(_ items: [T], _ name: (T) -> String) -> [T] {
    ThemeLists.filtered(items, by: query, name: name)
  }

  private var currentIDs: [String] {
    switch browse.side {
    case nil: return filtered(lists.availableFamilies(), \.name).map { ThemeRowID.family($0.name) }
    case let side?:
      return filtered(lists.themes(on: side), \.name).map { ThemeRowID.theme($0.name, on: side) }
    }
  }

  /// Settles the grid on the current choice out of sight. With no current choice in the list (a
  /// custom pair on Families), it starts at the top.
  private func settleOnCurrent(_ proxy: ScrollViewProxy) {
    settle.settle(proxy) { currentChoiceID ?? currentIDs.first }
  }

  /// The row ID of the current choice in the list showing, or nil for a custom pair on Family.
  private var currentChoiceID: String? {
    switch browse.side {
    case nil: return activeFamily.map { ThemeRowID.family($0.name) }
    case let side?: return ThemeRowID.theme(stored(side), on: side)
    }
  }

  /// How many tiles a row holds at the grid's width, as an adaptive `GridItem` lays them out.
  private var columns: Int {
    let minimum = browse.side == nil ? Self.familyTileMinWidth : Self.themeTileMinWidth
    return max(1, Int((gridWidth + Self.tileSpacing) / (minimum + Self.tileSpacing)))
  }

  /// Moves the current choice `delta` tiles through the list showing (clamped to it) and applies it,
  /// keeping it on screen. With no current choice in the list, the first tile is chosen.
  private func move(by delta: Int, _ proxy: ScrollViewProxy) {
    guard settle.ready else { return }
    let ids = currentIDs
    guard !ids.isEmpty else { return }
    let current = currentChoiceID.flatMap { ids.firstIndex(of: $0) }
    let next = current.map { min(max($0 + delta, 0), ids.count - 1) } ?? 0
    guard next != current else { return }
    choose(at: next)
    let id = ids[next]
    keepVisible.reveal(proxy, id, movingForward: delta > 0) { currentChoiceID == id }
  }

  /// Applies the tile at `index` in the list showing.
  private func choose(at index: Int) {
    switch browse.side {
    case nil:
      let families = filtered(lists.availableFamilies(), \.name)
      if families.indices.contains(index) { ThemeService.shared.applyFamily(families[index]) }
    case let side?:
      let themes = filtered(lists.themes(on: side), \.name)
      if themes.indices.contains(index) {
        ThemeService.shared.apply(theme: themes[index].name, for: side)
      }
    }
  }

  @ViewBuilder private var grid: some View {
    switch browse.side {
    case nil:
      let families = filtered(lists.availableFamilies(), \.name)
      if families.isEmpty {
        emptyResults
      } else {
        LazyVGrid(
          columns: [
            GridItem(.adaptive(minimum: Self.familyTileMinWidth), spacing: Self.tileSpacing)
          ],
          spacing: Spacing.xxl
        ) {
          ForEach(families) { family in
            ThemeTile(
              name: family.name,
              previews: [family.dark, family.light].map { ThemeService.themePreview(named: $0) },
              selected: family == activeFamily,
              identifier: "settings.themes.family-\(family.name)",
              help: "\(family.name): \(family.dark) when dark, \(family.light) when light"
            ) {
              ThemeService.shared.applyFamily(family)
              gridFocused = true
            }
            .id(ThemeRowID.family(family.name))
          }
        }
        .scrollTargetLayout()
      }
    case let side?:
      let themes = filtered(lists.themes(on: side), \.name)
      if themes.isEmpty {
        emptyResults
      } else {
        LazyVGrid(
          columns: [
            GridItem(.adaptive(minimum: Self.themeTileMinWidth), spacing: Self.tileSpacing)
          ],
          spacing: Spacing.xxl
        ) {
          ForEach(themes, id: \.name) { theme in
            ThemeTile(
              name: theme.name,
              previews: [ThemeService.themePreview(named: theme.name)],
              selected: theme.name == stored(side),
              isUserTheme: theme.isUserTheme,
              identifier: "settings.themes.\(side.rawValue)-\(theme.name)",
              help: theme.name
            ) {
              ThemeService.shared.apply(theme: theme.name, for: side)
              gridFocused = true
            }
            .id(ThemeRowID.theme(theme.name, on: side))
          }
        }
        .scrollTargetLayout()
      }
    }
  }

  private var emptyResults: some View {
    VStack(spacing: Spacing.s) {
      Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.tertiary)
      Text("No themes match “\(query.trimmingCharacters(in: .whitespaces))”")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 120)
  }
}

// MARK: - Tiles

/// One theme, or one family (its dark theme beside its light one), in the grid: its preview, then its
/// name with a checkmark on the current choice and a "Yours" label on the user's own files.
private struct ThemeTile: View {
  let name: String
  let previews: [ThemePreview?]
  let selected: Bool
  var isUserTheme = false
  let identifier: String
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: Spacing.s) {
        HStack(spacing: 0) {
          ForEach(previews.indices, id: \.self) { TerminalSnippet(preview: previews[$0]) }
        }
        .frame(height: 58)
        .themeTileChrome(selected: selected, radius: Radius.s)
        HStack(spacing: Spacing.xs) {
          Text(name)
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
          if isUserTheme {
            Text("Yours")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
              .fixedSize()
              .help("Your own theme, from ~/.config/ghostty/themes")
              .accessibilityLabel("Your own theme")
              .accessibilityIdentifier("\(identifier)-yours")
          }
          Spacer(minLength: 0)
          if selected {
            Image(systemName: "checkmark")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.primary)
              .accessibilityHidden(true)
          }
        }
        .padding(.horizontal, 3)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(ThemeTileButtonStyle())
    .help(help)
    .accessibilityLabel(name)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }
}

/// A plain button that dims slightly while pressed, with a focus ring for keyboard navigation (a
/// plain style draws none); the tile's own chrome shows hover.
private struct ThemeTileButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    ThemeTileButtonBody(configuration: configuration)
  }
}

private struct ThemeTileButtonBody: View {
  @Environment(\.isFocused) private var focused
  @Environment(\.themeTokens) private var tokens
  let configuration: ButtonStyleConfiguration

  var body: some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.75 : 1)
      .overlay {
        RoundedRectangle(cornerRadius: Radius.m + 2, style: .continuous)
          .strokeBorder(focused ? tokens.accent.opacity(0.6) : .clear, lineWidth: 3)
          .padding(-3)
      }
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/// A preview's frame: a hairline, a ring in the accent on the current choice, and a fainter ring on
/// hover.
private struct ThemeTileChrome: ViewModifier {
  @Environment(\.themeTokens) private var tokens
  let selected: Bool
  let radius: CGFloat
  @State private var hovered = false

  func body(content: Content) -> some View {
    content
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
      )
      .padding(3)
      .overlay(
        RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
          .strokeBorder(
            selected ? tokens.accent : hovered ? Color.primary.opacity(0.22) : .clear,
            lineWidth: selected ? 2 : 1.5)
      )
      .onHover { hovered = $0 }
      .animation(.easeOut(duration: 0.15), value: hovered)
      .animation(.easeOut(duration: 0.15), value: selected)
  }
}

extension View {
  fileprivate func themeTileChrome(selected: Bool, radius: CGFloat) -> some View {
    modifier(ThemeTileChrome(selected: selected, radius: radius))
  }
}

/// The whole app in miniature, painted from the theme's derived chrome (`ThemeTokens`): a sidebar of
/// workrooms with one selected, a tab strip, and a terminal.
private struct MiniWorkroomWindow: View {
  let preview: ThemePreview?

  var body: some View {
    let t = ThemeTokens(preview: preview)
    GeometryReader { geo in
      let sidebar = max(56, geo.size.width * 0.24)
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 3) {
            ForEach([Color.red, .yellow, .green], id: \.self) {
              Circle().fill($0.opacity(0.85)).frame(width: 6, height: 6)
            }
          }
          .padding(.bottom, 6)
          // Workroom rows of varied length, the second one selected.
          ForEach(Array([0.5, 0.78, 0.62, 0.44, 0.56].enumerated()), id: \.offset) { index, width in
            RoundedRectangle(cornerRadius: 2)
              .fill(index == 1 ? t.accent.opacity(0.45) : t.fg.opacity(0.14))
              .frame(width: (sidebar - 16) * width, height: 6)
          }
          Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: sidebar, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(t.panel)
        Rectangle().fill(t.border).frame(width: 0.5)
        VStack(spacing: 0) {
          HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(t.fg.opacity(0.22)).frame(width: 40, height: 6)
            RoundedRectangle(cornerRadius: 2).fill(t.fg.opacity(0.09)).frame(width: 32, height: 6)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 8)
          .frame(height: 20)
          .background(t.panel)
          Rectangle().fill(t.border).frame(height: 0.5)
          TerminalSnippet(preview: preview, fontSize: 10)
        }
      }
    }
    .background(t.bg)
    .accessibilityHidden(true)
  }
}
