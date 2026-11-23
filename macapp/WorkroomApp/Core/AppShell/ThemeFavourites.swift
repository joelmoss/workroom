import Defaults
import Observation
import SwiftUI

/// Something the user can star in the theme lists: a theme, by name and on whichever side it's on, or
/// a theme family, each kind stored apart (`Kind.key`).
struct ThemeFavourite: Hashable, Sendable {
  enum Kind: Hashable, Sendable, CaseIterable {
    case theme
    case family

    /// What a tab lists: families on the Family tab, themes on Light and Dark.
    init(_ tab: ThemePickerTab) { self = tab.side == nil ? .family : .theme }

    /// Where this kind's favourites are stored.
    var key: Defaults.Key<Set<String>> {
      switch self {
      case .theme: return .favouriteThemes
      case .family: return .favouriteFamilies
      }
    }
  }

  let kind: Kind
  let name: String

  static func theme(_ name: String) -> ThemeFavourite { ThemeFavourite(kind: .theme, name: name) }
  static func family(_ name: String) -> ThemeFavourite { ThemeFavourite(kind: .family, name: name) }
}

/// The user's favourite themes and families, shared by the ⌘⇧K picker (`ThemePicker`) and Settings ▸
/// Themes (`ThemesSettingsPane`). A favourite whose theme is gone is kept: a themes folder can be
/// missing for a while (a dotfiles sync), and the star comes back with the file.
@MainActor
enum ThemeFavourites {
  /// Stars `favourite`, or unstars it when it's starred already.
  static func toggle(_ favourite: ThemeFavourite) {
    var names = Defaults[favourite.kind.key]
    if names.remove(favourite.name) == nil { names.insert(favourite.name) }
    Defaults[favourite.kind.key] = names
  }
}

extension ThemeLists {
  /// What a theme list shows: the `items` whose name contains `query`, and, while the favourites
  /// filter is on (`favourites` non-nil), only those among `favourites`.
  static func shown<T>(
    _ items: [T], query: String, favourites: Set<String>?, name: (T) -> String
  ) -> [T] {
    let matching = filtered(items, by: query, name: name)
    guard let favourites else { return matching }
    return matching.filter { favourites.contains(name($0)) }
  }
}

/// One theme list's view of the favourites: which are starred, whether only favourites are listed,
/// and which rows a filtered list shows. Both lists hold one each, so the filter and the search behave
/// alike in both.
///
/// A row unstarred while the filter is on stays listed until the list is rebuilt (`rebuild`: a tab, a
/// search, the filter, or opening it again), so it doesn't vanish from under the pointer and a
/// misclick can be undone where it was made. A row starred meanwhile is listed at once.
/// `@Observable`, mirroring the stored favourites, so a star from anywhere repaints the list.
@MainActor
@Observable
final class ThemeListFavourites {
  /// The starred names of each kind, mirrored from `Kind.key`.
  private var starred: [ThemeFavourite.Kind: Set<String>] = [:]
  /// Only favourites listed: one setting for every theme list, kept between openings.
  private(set) var favouritesOnly = false
  /// The starred names of each kind the list was last rebuilt with.
  private var built: [ThemeFavourite.Kind: Set<String>] = [:]
  @ObservationIgnored private var observation: Defaults.Observation?

  init() {
    load()
    rebuild()
    observation = Defaults.observe(
      keys: .favouriteThemes, .favouriteFamilies, .themeFavouritesOnly, options: []
    ) { [weak self] in
      // Written on the main actor by everything in the app, so mirrored at once, before the write
      // returns (and so inside its transaction); a write from elsewhere hops.
      if Thread.isMainThread {
        MainActor.assumeIsolated { self?.load() }
      } else {
        Task { @MainActor in self?.load() }
      }
    }
  }

  private func load() {
    for kind in ThemeFavourite.Kind.allCases { starred[kind] = Defaults[kind.key] }
    favouritesOnly = Defaults[.themeFavouritesOnly]
  }

  func contains(_ favourite: ThemeFavourite) -> Bool {
    names(favourite.kind).contains(favourite.name)
  }

  /// Forgets rows unstarred since the last rebuild.
  func rebuild() { built = starred }

  /// Flips the favourites filter (the star by the search, ⌘F, Show All Themes), rebuilding the list.
  /// Without animation: the filter moves the tiles that stay to new places, and a tile's own implicit
  /// animations would otherwise carry parts of it there.
  func toggleFilter() {
    rebuild()
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { Defaults[.themeFavouritesOnly].toggle() }
  }

  /// The names of `kind` a filtered list shows, or nil while the filter is off: the favourites, and
  /// those unstarred since the last rebuild.
  func listed(_ kind: ThemeFavourite.Kind) -> Set<String>? {
    guard favouritesOnly else { return nil }
    return names(kind).union(built[kind] ?? [])
  }

  /// What a list of `kind` shows of `items`, for `query`.
  func shown<T>(
    _ items: [T], _ kind: ThemeFavourite.Kind, query: String, name: (T) -> String
  ) -> [T] {
    ThemeLists.shown(items, query: query, favourites: listed(kind), name: name)
  }

  /// What `tab`'s list says while it's empty, given every name the tab could list.
  func emptyState(on tab: ThemePickerTab, query: String, from names: [String])
    -> ThemeListEmptyState
  {
    let kind = ThemeFavourite.Kind(tab)
    return ThemeListEmptyState(
      tab: tab, query: query, favouritesOnly: favouritesOnly,
      hasFavouritesOnTab: !shown(names, kind, query: "", name: { $0 }).isEmpty)
  }

  /// `query` as a search field edits it: a new search rebuilds the list.
  func search(_ query: Binding<String>) -> Binding<String> {
    Binding(
      get: { query.wrappedValue },
      set: { [weak self] newValue in
        guard newValue != query.wrappedValue else { return }
        self?.rebuild()
        query.wrappedValue = newValue
      })
  }

  private func names(_ kind: ThemeFavourite.Kind) -> Set<String> { starred[kind] ?? [] }
}

/// What an empty theme list says.
enum ThemeListEmptyState: Equatable {
  /// The filter is on and the tab has no favourites at all.
  case noFavourites(ThemePickerTab)
  /// The filter is on and none of the tab's favourites match the search.
  case noFavouriteMatches(String)
  /// The filter is off and no theme matches the search.
  case noMatches(String)

  init(tab: ThemePickerTab, query: String, favouritesOnly: Bool, hasFavouritesOnTab: Bool) {
    let query = query.trimmingCharacters(in: .whitespaces)
    if !favouritesOnly {
      self = .noMatches(query)
    } else if hasFavouritesOnTab {
      self = .noFavouriteMatches(query)
    } else {
      self = .noFavourites(tab)
    }
  }

  var title: String {
    switch self {
    case .noFavourites(let tab):
      switch tab.side {
      case nil: return "No favourite families yet"
      case let side?: return "No favourite \(side.title.lowercased()) themes yet"
      }
    case .noFavouriteMatches(let query): return "No favourites match “\(query)”"
    case .noMatches(let query): return "No themes match “\(query)”"
    }
  }
}
