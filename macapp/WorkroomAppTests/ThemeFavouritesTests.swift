import AppKit
import Defaults
import DesignSystem
import SwiftUI
import XCTest

@testable import Workroom

/// Favourite themes and families, and the favourites filter the ⌘⇧K picker and Settings ▸ Themes
/// share: the store, the list a tab shows, the row that stays after it's unstarred, the empty states,
/// and which window ⌘D and ⌘F reach.
@MainActor
final class ThemeFavouritesTests: XCTestCase {
  private var savedThemes: Set<String>!
  private var savedFamilies: Set<String>!
  private var savedFilter: Bool!

  override func setUp() async throws {
    try await super.setUp()
    savedThemes = Defaults[.favouriteThemes]
    savedFamilies = Defaults[.favouriteFamilies]
    savedFilter = Defaults[.themeFavouritesOnly]
    Defaults[.favouriteThemes] = []
    Defaults[.favouriteFamilies] = []
    Defaults[.themeFavouritesOnly] = false
  }

  override func tearDown() async throws {
    Defaults[.favouriteThemes] = savedThemes
    Defaults[.favouriteFamilies] = savedFamilies
    Defaults[.themeFavouritesOnly] = savedFilter
    try await super.tearDown()
  }

  // MARK: Store

  func testStarringAThemeTwiceUnstarsIt() {
    XCTAssertFalse(ThemeFavourites.contains(.theme("Nord")))
    ThemeFavourites.toggle(.theme("Nord"))
    XCTAssertTrue(ThemeFavourites.contains(.theme("Nord")))
    ThemeFavourites.toggle(.theme("Nord"))
    XCTAssertFalse(ThemeFavourites.contains(.theme("Nord")))
  }

  func testAThemeAndAFamilyOfTheSameNameAreSeparateFavourites() {
    ThemeFavourites.toggle(.family("Nord"))
    XCTAssertTrue(ThemeFavourites.contains(.family("Nord")))
    XCTAssertFalse(ThemeFavourites.contains(.theme("Nord")))
    XCTAssertEqual(Defaults[.favouriteFamilies], ["Nord"])
    XCTAssertEqual(Defaults[.favouriteThemes], [])
  }

  // MARK: The list a tab shows

  private let themes = ["Ayu", "Gone Theme", "Nord", "Nord Light", "Solarized"]

  func testTheFilterOffListsEverythingTheSearchMatches() {
    XCTAssertEqual(
      ThemeLists.shown(themes, query: "nord", favourites: nil, name: { $0 }),
      ["Nord", "Nord Light"])
  }

  func testTheFilterListsOnlyFavouritesTheSearchMatches() {
    let favourites: Set<String> = ["Ayu", "Nord Light"]
    XCTAssertEqual(
      ThemeLists.shown(themes, query: "", favourites: favourites, name: { $0 }),
      ["Ayu", "Nord Light"])
    XCTAssertEqual(
      ThemeLists.shown(themes, query: "nord", favourites: favourites, name: { $0 }),
      ["Nord Light"])
  }

  /// A favourite whose file is gone is kept, unlisted, and listed again when the file comes back.
  func testAFavouriteWhoseThemeIsGoneIsKeptButNotListed() {
    ThemeFavourites.toggle(.theme("Gone Theme"))
    let withoutIt = ["Ayu", "Nord"]
    XCTAssertEqual(
      ThemeLists.shown(
        withoutIt, query: "", favourites: Defaults[.favouriteThemes], name: { $0 }),
      [])
    XCTAssertEqual(Defaults[.favouriteThemes], ["Gone Theme"])
    XCTAssertEqual(
      ThemeLists.shown(themes, query: "", favourites: Defaults[.favouriteThemes], name: { $0 }),
      ["Gone Theme"])
  }

  // MARK: A list's favourites

  func testAListFollowsStarsMadeAnywhere() {
    let favourites = ThemeListFavourites()
    ThemeFavourites.toggle(.theme("Nord"))
    XCTAssertTrue(favourites.contains(.theme("Nord")))
    XCTAssertFalse(favourites.contains(.family("Nord")))
  }

  func testWithTheFilterOffEveryThemeIsListed() {
    Defaults[.favouriteThemes] = ["Nord"]
    let favourites = ThemeListFavourites()
    XCTAssertNil(favourites.listed(.theme))
    XCTAssertEqual(favourites.shown(themes, .theme, query: "", name: { $0 }), themes)
  }

  func testTheFilterIsOneSettingForEveryList() {
    let picker = ThemeListFavourites()
    let settings = ThemeListFavourites()
    picker.toggleFilter()
    XCTAssertTrue(Defaults[.themeFavouritesOnly])
    XCTAssertTrue(settings.favouritesOnly, "the other list didn't follow the filter")
  }

  func testAnUnstarredRowStaysListedUntilTheListIsRebuilt() {
    Defaults[.favouriteThemes] = ["Ayu", "Nord"]
    Defaults[.themeFavouritesOnly] = true
    let favourites = ThemeListFavourites()
    ThemeFavourites.toggle(.theme("Nord"))
    XCTAssertFalse(favourites.contains(.theme("Nord")), "the star didn't go out")
    XCTAssertEqual(favourites.shown(themes, .theme, query: "", name: { $0 }), ["Ayu", "Nord"])
    favourites.rebuild()
    XCTAssertEqual(favourites.shown(themes, .theme, query: "", name: { $0 }), ["Ayu"])
  }

  func testANewSearchRebuildsTheList() {
    Defaults[.favouriteThemes] = ["Ayu", "Nord"]
    Defaults[.themeFavouritesOnly] = true
    let favourites = ThemeListFavourites()
    var query = ""
    let search = favourites.search(Binding(get: { query }, set: { query = $0 }))
    ThemeFavourites.toggle(.theme("Nord"))
    search.wrappedValue = "o"
    XCTAssertEqual(query, "o")
    XCTAssertEqual(favourites.shown(themes, .theme, query: query, name: { $0 }), [])
  }

  func testANewlyStarredRowIsListedAtOnce() {
    Defaults[.themeFavouritesOnly] = true
    let favourites = ThemeListFavourites()
    ThemeFavourites.toggle(.family("Nord"))
    XCTAssertEqual(favourites.listed(.family), ["Nord"])
    XCTAssertEqual(favourites.listed(.theme), [])
  }

  func testAListsEmptyStateKnowsWhetherTheTabHasFavourites() {
    Defaults[.favouriteThemes] = ["Nord"]
    Defaults[.themeFavouritesOnly] = true
    let favourites = ThemeListFavourites()
    XCTAssertEqual(
      favourites.emptyState(on: .dark, query: "zzz", from: themes), .noFavouriteMatches("zzz"))
    XCTAssertEqual(favourites.emptyState(on: .dark, query: "", from: ["Ayu"]), .noFavourites(.dark))
    XCTAssertEqual(
      favourites.emptyState(on: .family, query: "", from: themes), .noFavourites(.family),
      "a starred theme isn't a starred family")
  }

  // MARK: Empty states

  func testATabWithNoFavouritesSaysHowToStarOne() {
    let state = ThemeListEmptyState(
      tab: .dark, query: "", favouritesOnly: true, hasFavouritesOnTab: false)
    XCTAssertEqual(state, .noFavourites(.dark))
    XCTAssertEqual(state.title, "No favourite dark themes yet")
    XCTAssertEqual(
      ThemeListEmptyState(tab: .family, query: "x", favouritesOnly: true, hasFavouritesOnTab: false)
        .title,
      "No favourite families yet")
  }

  func testFavouritesTheSearchMissesSayWhatWasSearched() {
    let state = ThemeListEmptyState(
      tab: .light, query: " zzz ", favouritesOnly: true, hasFavouritesOnTab: true)
    XCTAssertEqual(state, .noFavouriteMatches("zzz"))
    XCTAssertEqual(state.title, "No favourites match “zzz”")
  }

  func testWithTheFilterOffASearchMissSaysNoThemesMatch() {
    let state = ThemeListEmptyState(
      tab: .light, query: "zzz", favouritesOnly: false, hasFavouritesOnTab: false)
    XCTAssertEqual(state.title, "No themes match “zzz”")
  }

  // MARK: ⌘D and ⌘F

  func testOnlyCommandDAndCommandFAreThemeListKeys() {
    XCTAssertEqual(ThemeListKeys.Command(.key("d", .command)), .toggleFavourite)
    XCTAssertEqual(ThemeListKeys.Command(.key("f", .command)), .toggleFilter)
    XCTAssertNil(ThemeListKeys.Command(.key("d", [.command, .shift])))
    XCTAssertNil(ThemeListKeys.Command(.key("f", [.command, .option])))
    XCTAssertNil(ThemeListKeys.Command(.key("k", .command)))
  }

  func testTheKeysReachOnlyTheThemeListInTheKeyWindow() {
    let keys = ThemeListKeys()
    let list = window()
    let other = window()
    var received: [ThemeListKeys.Command] = []
    let id = keys.register(window: list) { received.append($0) }

    XCTAssertFalse(
      keys.handle(.toggleFavourite, in: other), "another window keeps ⌘D (Split Right)")
    XCTAssertFalse(keys.handle(.toggleFavourite, in: nil))
    XCTAssertTrue(keys.handle(.toggleFavourite, in: list))
    XCTAssertTrue(keys.handle(.toggleFilter, in: list))
    XCTAssertEqual(received, [.toggleFavourite, .toggleFilter])

    keys.unregister(id)
    XCTAssertFalse(keys.handle(.toggleFavourite, in: list), "a closed list lets the keys go")
  }

  /// The ⌘⇧K picker is a popover, which leaves its host window key: a key press there is the
  /// picker's while it's up.
  func testTheKeysReachAPopoverFromTheWindowItHangsFrom() {
    let keys = ThemeListKeys()
    let host = window()
    let popover = window()
    host.addChildWindow(popover, ordered: .above)
    defer { host.removeChildWindow(popover) }
    var received = 0
    _ = keys.register(window: popover) { _ in received += 1 }
    XCTAssertTrue(keys.handle(.toggleFavourite, in: host))
    XCTAssertEqual(received, 1)
  }

  private func window() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    addTeardownBlock { window.close() }
    return window
  }
}
