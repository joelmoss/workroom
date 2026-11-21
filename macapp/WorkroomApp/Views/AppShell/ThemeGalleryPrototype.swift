#if DEBUG
  // PROTOTYPE (branch prototype/theme-gallery) — throwaway. Three structurally different ways to choose
  // themes in Settings → Appearance with every theme always visible (no popovers), switchable from the
  // floating PROTOTYPE bar. Clicking a theme applies it for real (ThemeService) so the repaint can be
  // judged. Never merge this file; the winner gets rewritten properly.
  import Defaults
  import DesignSystem
  import SwiftUI

  enum ThemeGalleryVariant: String, CaseIterable {
    case shelves = "A"
    case stage = "B"
    case strips = "C"

    var title: String {
      switch self {
      case .shelves: return "Shelves"
      case .stage: return "Stage + grid"
      case .strips: return "Theme strips"
      }
    }
  }

  // MARK: - Shared model (data + actions only; each variant owns its own layout)

  @MainActor
  final class ThemeGalleryData {
    private var cache: [ThemeSide: [ListedTheme]] = [:]
    private var familiesCache: [ThemeFamily]?
    func themes(_ side: ThemeSide) -> [ListedTheme] {
      if let c = cache[side] { return c }
      let t = ThemeCatalog.themes(on: side)
      cache[side] = t
      return t
    }
    func families() -> [ThemeFamily] {
      if let f = familiesCache { return f }
      let f = ThemeCatalog.availableFamilies()
      familiesCache = f
      return f
    }
  }

  private func matches(_ name: String, _ query: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    return q.isEmpty || name.localizedCaseInsensitiveContains(q)
  }

  private func sideWord(_ side: ThemeSide) -> String { side == .dark ? "Dark" : "Light" }

  /// The "applies when…" note for the side that isn't on screen, and the fallback note for a stored
  /// theme that can't be shown. Nil when neither applies.
  @MainActor
  private func sideNote(_ side: ThemeSide, stored: String) -> String? {
    if let fallback = ThemeFallbackNote(
      side: side, stored: stored, showing: ThemeService.activeThemeName(for: side),
      storedSide: ThemeCatalog.side(ofThemeNamed: stored))
    {
      return fallback.text
    }
    if side != ThemeService.showingSide() {
      return "Applies when the appearance is \(sideWord(side))"
    }
    return nil
  }

  extension ThemePreview {
    fileprivate func ansi(_ i: Int) -> Color {
      palette.indices.contains(i) ? Color(nsColor: palette[i]) : Color(nsColor: foreground)
    }
    fileprivate var bg: Color { Color(nsColor: background) }
    fileprivate var fg: Color { Color(nsColor: foreground) }
  }

  /// A few lines of coloured terminal output in the theme's own colours — what the theme will actually
  /// look like in a workroom, instead of a palette strip. The cursor uses the accent (palette 4), as
  /// the chrome does; theme files' own cursor colour isn't parsed yet.
  private struct TerminalSnippet: View {
    let preview: ThemePreview?
    var scale: CGFloat = 1
    var lines = 4

    var body: some View {
      let p = preview
      let size = 9.5 * scale
      VStack(alignment: .leading, spacing: 2.5 * scale) {
        HStack(spacing: 0) {
          Text("~/app ").foregroundStyle(p?.ansi(6) ?? .secondary)
          Text("main ").foregroundStyle(p?.ansi(5) ?? .secondary)
          Text("❯ ").foregroundStyle(p?.ansi(2) ?? .secondary)
          Rectangle().fill(p?.ansi(4) ?? .secondary).frame(width: 5 * scale, height: 11 * scale)
        }
        if lines > 1 {
          Text("+ let theme = \"new\"").foregroundStyle(p?.ansi(2) ?? .secondary)
        }
        if lines > 2 {
          Text("- let theme = \"old\"").foregroundStyle(p?.ansi(1) ?? .secondary)
        }
        if lines > 3 {
          HStack(spacing: 0) {
            Text("warning: ").foregroundStyle(p?.ansi(3) ?? .secondary)
            Text("2 files").foregroundStyle(p?.fg ?? .secondary)
          }
        }
      }
      .font(.system(size: size, weight: .medium, design: .monospaced))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 9 * scale)
      .padding(.vertical, 8 * scale)
      .frame(
        minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading
      )
      .clipped()
      .background(p?.bg ?? Color.gray.opacity(0.2))
    }
  }

  private struct YoursTag: View {
    var onDark = false
    var body: some View {
      Text("Yours")
        .font(.system(size: 9, weight: .semibold))
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(Capsule().fill(.thinMaterial))
        .help("Your own theme, from ~/.config/ghostty/themes")
    }
  }

  private struct SelectionRing: ViewModifier {
    @Environment(\.themeTokens) private var tokens
    let selected: Bool
    let radius: CGFloat
    func body(content: Content) -> some View {
      content
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .padding(3)
        .overlay(
          RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
            .strokeBorder(selected ? tokens.accent : .clear, lineWidth: 2.5)
        )
    }
  }

  extension View {
    fileprivate func selectionRing(_ selected: Bool, radius: CGFloat = 9) -> some View {
      modifier(SelectionRing(selected: selected, radius: radius))
    }
  }

  private struct SearchField: View {
    @Binding var query: String
    var body: some View {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search themes", text: $query).textFieldStyle(.plain)
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
        }
      }
      .padding(.horizontal, 8).padding(.vertical, 5)
      .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }
  }

  // MARK: - Host

  struct ThemeGalleryPrototypeHost: View {
    @AppStorage("prototypeThemeGalleryVariant") private var variantRaw = ThemeGalleryVariant.shelves
      .rawValue
    private var variant: ThemeGalleryVariant {
      ThemeGalleryVariant(rawValue: variantRaw) ?? .shelves
    }

    var body: some View {
      ZStack(alignment: .bottom) {
        Group {
          switch variant {
          case .shelves: ShelvesVariant()
          case .stage: StageVariant()
          case .strips: StripsVariant()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        switcher.padding(.bottom, 10)
      }
    }

    private func cycle(_ d: Int) {
      let all = ThemeGalleryVariant.allCases
      let i = all.firstIndex(of: variant) ?? 0
      variantRaw = all[(i + d + all.count) % all.count].rawValue
    }

    private var switcher: some View {
      HStack(spacing: 10) {
        Text("PROTOTYPE").font(.system(size: 9, weight: .heavy)).foregroundStyle(
          .black.opacity(0.7))
        Button {
          cycle(-1)
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.plain)
        Text("\(variant.rawValue) · \(variant.title)").font(.system(size: 12, weight: .semibold))
          .frame(minWidth: 120)
        Button {
          cycle(1)
        } label: {
          Image(systemName: "chevron.right")
        }
        .buttonStyle(.plain)
      }
      .foregroundStyle(.black)
      .padding(.horizontal, 14).padding(.vertical, 7)
      .background(Capsule().fill(Color.yellow))
      .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
  }

  private struct AppearanceModePicker: View {
    @Default(.appearance) private var appearance
    var body: some View {
      Picker("Appearance", selection: $appearance) {
        ForEach(AppearanceMode.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
    }
  }

  // MARK: - A · Shelves
  //
  // Inside the native grouped Form: the Appearance segmented control, then three always-visible
  // horizontal shelves — Families (paired dark|light cards), Light, Dark. The Form owns vertical
  // scroll; each shelf scrolls sideways. One search field filters every shelf.

  private struct ShelvesVariant: View {
    @Default(.lightTheme) private var lightTheme
    @Default(.darkTheme) private var darkTheme
    @Default(.appearance) private var appearance
    @State private var data = ThemeGalleryData()
    @State private var query = ""

    var body: some View {
      let family = ThemeCatalog.family(light: lightTheme, dark: darkTheme)
      Form {
        Section {
          LabeledContent("Appearance") { AppearanceModePicker().labelsHidden().frame(width: 220) }
          SearchField(query: $query)
        }
        Section {
          shelf(
            ids: data.families().filter { matches($0.name, query) }.map(\.name),
            current: family?.name
          ) { name in
            let f = data.families().first { $0.name == name }!
            familyCard(f, selected: f == family)
          }
        } header: {
          shelfHeader("Theme family", value: family?.name ?? "Custom", note: nil)
        }
        ForEach([ThemeSide.light, .dark], id: \.self) { side in
          let stored = side == .dark ? darkTheme : lightTheme
          Section {
            let themes = data.themes(side).filter { matches($0.name, query) }
            shelf(ids: themes.map(\.name), current: stored) { name in
              let t = themes.first { $0.name == name }!
              themeCard(t, selected: t.name == stored)
            }
          } header: {
            shelfHeader(
              "\(sideWord(side)) theme", value: stored, note: sideNote(side, stored: stored))
          }
        }
        Section {
          Text("Diff view, pane dimming, split sizing and avatars are hidden in this prototype.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Color.clear.frame(height: 30).listRowBackground(Color.clear)
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .onChange(of: appearance) { _, _ in }
    }

    private func shelfHeader(_ title: String, value: String, note: String?) -> some View {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(title).font(.headline).foregroundStyle(.primary)
        Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        Spacer()
        if let note {
          Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }

    private func shelf<Card: View>(
      ids: [String], current: String?, @ViewBuilder card: @escaping (String) -> Card
    ) -> some View {
      Group {
        if ids.isEmpty {
          Text("No themes match “\(query)”").font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
        } else {
          ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
              LazyHStack(alignment: .top, spacing: 10) {
                ForEach(ids, id: \.self) { card($0).id($0) }
              }
              .padding(.vertical, 6).padding(.horizontal, 2)
            }
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
          }
        }
      }
    }

    private func caption(_ name: String, selected: Bool) -> some View {
      Text(name)
        .font(.system(size: 11, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? .primary : .secondary)
        .lineLimit(1).truncationMode(.tail)
        .frame(width: 140)
        .help(name)
    }

    private func themeCard(_ t: ListedTheme, selected: Bool) -> some View {
      VStack(spacing: 5) {
        TerminalSnippet(preview: ThemeService.themePreview(named: t.name))
          .frame(width: 134, height: 70)
          .overlay(alignment: .topTrailing) { if t.isUserTheme { YoursTag().padding(5) } }
          .selectionRing(selected)
        caption(t.name, selected: selected)
      }
      .contentShape(Rectangle())
      .onTapGesture { ThemeService.shared.apply(theme: t.name, for: t.side) }
      .help(t.name)
    }

    private func familyCard(_ f: ThemeFamily, selected: Bool) -> some View {
      VStack(spacing: 5) {
        HStack(spacing: 0) {
          TerminalSnippet(preview: ThemeService.themePreview(named: f.dark), lines: 3)
          TerminalSnippet(preview: ThemeService.themePreview(named: f.light), lines: 3)
        }
        .frame(width: 200, height: 58)
        .selectionRing(selected)
        caption(f.name, selected: selected).frame(width: 200)
      }
      .contentShape(Rectangle())
      .onTapGesture { ThemeService.shared.applyFamily(f) }
      .help("\(f.name): \(f.dark) and \(f.light)")
    }
  }

  // MARK: - B · Stage + grid
  //
  // A stage of two miniature Workroom windows — the light theme and the dark theme as the whole app
  // would look — that double as the side switch: click one to browse for that side. Under it a
  // sticky browser (Families | Light | Dark, search) over a vertical grid. The pane owns one scroll;
  // the browser header pins while the grid scrolls under it.

  private enum Browse: String, CaseIterable {
    case family = "Families"
    case light = "Light"
    case dark = "Dark"
    var side: ThemeSide? { self == .light ? .light : self == .dark ? .dark : nil }
  }

  private struct StageVariant: View {
    @Environment(\.themeTokens) private var tokens
    @Default(.lightTheme) private var lightTheme
    @Default(.darkTheme) private var darkTheme
    @Default(.appearance) private var appearance
    @State private var data = ThemeGalleryData()
    @State private var browse: Browse = ThemeService.showingSide() == .dark ? .dark : .light
    @State private var query = ""

    var body: some View {
      ScrollView {
        LazyVStack(spacing: 14, pinnedViews: [.sectionHeaders]) {
          stage.padding(.horizontal, 20).padding(.top, 14)
          Section {
            grid.padding(.horizontal, 20).padding(.bottom, 60)
          } header: {
            browserBar
          }
        }
      }
    }

    private var stage: some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Appearance").font(.headline)
          Spacer()
          AppearanceModePicker().labelsHidden().frame(width: 220)
        }
        HStack(spacing: 14) {
          ForEach([ThemeSide.light, .dark], id: \.self) { side in
            let name = side == .dark ? darkTheme : lightTheme
            let browsing = browse.side == side
            Button {
              browse = side == .dark ? .dark : .light
            } label: {
              VStack(alignment: .leading, spacing: 6) {
                MiniWorkroomWindow(preview: ThemeService.themePreview(named: name))
                  .frame(height: 118)
                  .selectionRing(browsing, radius: 8)
                HStack(spacing: 6) {
                  Text(sideWord(side)).font(.system(size: 11, weight: .semibold))
                  Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                  Spacer(minLength: 0)
                  if side == ThemeService.showingSide() {
                    Text("On screen").font(.system(size: 9, weight: .semibold))
                      .padding(.horizontal, 5).padding(.vertical, 1.5)
                      .background(Capsule().fill(Color.primary.opacity(0.08)))
                  }
                }
                if let note = sideNote(side, stored: name), note.hasPrefix("Not") {
                  Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Browse \(sideWord(side).lowercased()) themes")
          }
        }
      }
    }

    private var browserBar: some View {
      VStack(spacing: 6) {
        HStack(spacing: 10) {
          Picker("", selection: $browse) {
            ForEach(Browse.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented).labelsHidden().frame(width: 230)
          SearchField(query: $query)
        }
        if let side = browse.side, side != ThemeService.showingSide() {
          Label(
            "Applies when the appearance is \(sideWord(side))", systemImage: "info.circle"
          )
          .font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, 20).padding(.vertical, 8)
      .background(tokens.panel)
    }

    private var grid: some View {
      let cols = [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 10)]
      return Group {
        switch browse.side {
        case nil:
          let fam = ThemeCatalog.family(light: lightTheme, dark: darkTheme)
          let rows = data.families().filter { matches($0.name, query) }
          if rows.isEmpty {
            empty
          } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 12) {
              ForEach(rows) { f in
                tile(f.name, selected: f == fam) {
                  HStack(spacing: 0) {
                    TerminalSnippet(preview: ThemeService.themePreview(named: f.dark), lines: 2)
                    TerminalSnippet(preview: ThemeService.themePreview(named: f.light), lines: 2)
                  }
                } action: {
                  ThemeService.shared.applyFamily(f)
                }
              }
            }
          }
        case let side?:
          let stored = side == .dark ? darkTheme : lightTheme
          let rows = data.themes(side).filter { matches($0.name, query) }
          if rows.isEmpty {
            empty
          } else {
            LazyVGrid(columns: cols, spacing: 12) {
              ForEach(rows, id: \.name) { t in
                tile(t.name, selected: t.name == stored, yours: t.isUserTheme) {
                  TerminalSnippet(preview: ThemeService.themePreview(named: t.name), lines: 2)
                } action: {
                  ThemeService.shared.apply(theme: t.name, for: side)
                }
              }
            }
          }
        }
      }
    }

    private var empty: some View {
      Text("No themes match “\(query)”").foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private func tile<Preview: View>(
      _ name: String, selected: Bool, yours: Bool = false, @ViewBuilder preview: () -> Preview,
      action: @escaping () -> Void
    ) -> some View {
      VStack(alignment: .leading, spacing: 4) {
        preview()
          .frame(height: 44)
          .overlay(alignment: .topTrailing) { if yours { YoursTag().padding(4) } }
          .selectionRing(selected, radius: 7)
        HStack(spacing: 4) {
          Text(name).font(.system(size: 11, weight: selected ? .semibold : .regular))
            .lineLimit(1).truncationMode(.tail)
          if selected {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
          }
        }
        .padding(.leading, 4)
      }
      .contentShape(Rectangle())
      .onTapGesture(perform: action)
      .help(name)
    }
  }

  /// The whole app in miniature, painted from the theme's derived chrome tokens: sidebar, a tab
  /// strip, and a terminal.
  private struct MiniWorkroomWindow: View {
    let preview: ThemePreview?
    var body: some View {
      let t = ThemeTokens(preview: preview)
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 3) {
            ForEach([Color.red, .yellow, .green], id: \.self) {
              Circle().fill($0.opacity(0.8)).frame(width: 5, height: 5)
            }
          }
          .padding(.bottom, 4)
          ForEach(0..<4) { i in
            RoundedRectangle(cornerRadius: 2)
              .fill(i == 1 ? t.accent.opacity(0.35) : t.fg.opacity(0.14))
              .frame(width: i == 1 ? 46 : CGFloat(30 + i * 5), height: 6)
          }
          Spacer()
        }
        .padding(7)
        .frame(width: 62)
        .frame(maxHeight: .infinity)
        .background(t.panel)
        Rectangle().fill(t.border).frame(width: 0.5)
        VStack(spacing: 0) {
          HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(t.fg.opacity(0.18)).frame(width: 34, height: 6)
            RoundedRectangle(cornerRadius: 2).fill(t.fg.opacity(0.08)).frame(width: 28, height: 6)
            Spacer()
          }
          .padding(.horizontal, 7).frame(height: 16).background(t.panel)
          TerminalSnippet(preview: preview, scale: 0.95)
        }
      }
    }
  }

  // MARK: - C · Theme strips
  //
  // No cards: a vertical list where every row IS the theme — painted in its background, its name in
  // its foreground, a line of real coloured terminal output trailing. Families are a name column
  // beside their dark strip over their light strip. One scroll, owned by the list.

  private struct StripsVariant: View {
    @Default(.lightTheme) private var lightTheme
    @Default(.darkTheme) private var darkTheme
    @Default(.appearance) private var appearance
    @State private var data = ThemeGalleryData()
    @State private var browse: Browse = .family
    @State private var query = ""

    var body: some View {
      VStack(spacing: 0) {
        VStack(spacing: 10) {
          HStack {
            Text("Appearance").font(.headline)
            Spacer()
            AppearanceModePicker().labelsHidden().frame(width: 220)
          }
          HStack(spacing: 10) {
            Picker("", selection: $browse) {
              ForEach(Browse.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            SearchField(query: $query)
          }
          currentSummary
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        Divider()
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 6) { rows }
              .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 60)
          }
          .onAppear { scrollToCurrent(proxy) }
          .onChange(of: browse) { _, _ in scrollToCurrent(proxy) }
        }
      }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
      let id: String? =
        switch browse {
        case .family: ThemeCatalog.family(light: lightTheme, dark: darkTheme)?.name
        case .light: lightTheme
        case .dark: darkTheme
        }
      if let id { proxy.scrollTo(id, anchor: .center) }
    }

    /// Which theme each side uses, always visible above the list, with that side's note.
    private var currentSummary: some View {
      HStack(alignment: .top, spacing: 16) {
        ForEach([ThemeSide.light, .dark], id: \.self) { side in
          let name = side == .dark ? darkTheme : lightTheme
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
              Image(systemName: side == .dark ? "moon.fill" : "sun.max.fill")
                .font(.system(size: 10)).foregroundStyle(.secondary)
              Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .truncationMode(.tail)
            }
            if let note = sideNote(side, stored: name) {
              Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }

    @ViewBuilder private var rows: some View {
      switch browse.side {
      case nil:
        let fam = ThemeCatalog.family(light: lightTheme, dark: darkTheme)
        let list = data.families().filter { matches($0.name, query) }
        if list.isEmpty { empty }
        ForEach(list) { f in
          HStack(spacing: 10) {
            HStack(spacing: 4) {
              Text(f.name).font(.system(size: 12, weight: f == fam ? .semibold : .regular))
                .lineLimit(1).truncationMode(.tail)
              if f == fam { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            }
            .frame(width: 120, alignment: .leading)
            VStack(spacing: 0) {
              strip(f.dark, height: 24)
              strip(f.light, height: 24)
            }
            .selectionRing(f == fam, radius: 6)
          }
          .id(f.name)
          .contentShape(Rectangle())
          .onTapGesture { ThemeService.shared.applyFamily(f) }
          .help("\(f.name): \(f.dark) and \(f.light)")
        }
      case let side?:
        let stored = side == .dark ? darkTheme : lightTheme
        let list = data.themes(side).filter { matches($0.name, query) }
        if list.isEmpty { empty }
        ForEach(list, id: \.name) { t in
          strip(t.name, height: 30, yours: t.isUserTheme, selected: t.name == stored)
            .selectionRing(t.name == stored, radius: 6)
            .id(t.name)
            .contentShape(Rectangle())
            .onTapGesture { ThemeService.shared.apply(theme: t.name, for: side) }
            .help(t.name)
        }
      }
    }

    private var empty: some View {
      Text("No themes match “\(query)”").foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private func strip(_ name: String, height: CGFloat, yours: Bool = false, selected: Bool = false)
      -> some View
    {
      let p = ThemeService.themePreview(named: name)
      return HStack(spacing: 8) {
        Text(name).font(.system(size: 12, weight: selected ? .bold : .medium))
          .foregroundStyle(p?.fg ?? .primary)
          .lineLimit(1).truncationMode(.tail)
          .layoutPriority(1)
        if yours { YoursTag() }
        Spacer(minLength: 8)
        HStack(spacing: 0) {
          Text("❯ ").foregroundStyle(p?.ansi(2) ?? .secondary)
          Text("git ").foregroundStyle(p?.ansi(4) ?? .secondary)
          Text("diff ").foregroundStyle(p?.ansi(5) ?? .secondary)
          Text("+12 ").foregroundStyle(p?.ansi(2) ?? .secondary)
          Text("−3 ").foregroundStyle(p?.ansi(1) ?? .secondary)
          Text("! ").foregroundStyle(p?.ansi(3) ?? .secondary)
          Text("~/app").foregroundStyle(p?.ansi(6) ?? .secondary)
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .fixedSize()
      }
      .padding(.horizontal, 10)
      .frame(height: height)
      .background(p?.bg ?? Color.gray.opacity(0.2))
    }
  }
#endif
