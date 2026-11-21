import AppKit
import XCTest

@testable import DesignSystem

/// The user's own theme files in the Light and Dark lists (#737): each file in
/// `~/.config/ghostty/themes` is classified by its background, an unparseable one is hidden, one named
/// like a bundled theme replaces it, and a family is unavailable while a replacement puts one of its
/// themes on the wrong side. Every case points the user theme directory at a scratch directory,
/// never the developer's real `~/.config`.
final class UserThemeCatalogTests: XCTestCase {
  private let light = "background = #f4f1e8\nforeground = #202020\n"
  private let dark = "background = #101418\nforeground = #e0e0e0\n"

  private func names(on side: ThemeSide) -> [String] {
    ThemeCatalog.themes(on: side).map(\.name)
  }

  private func listed(_ name: String, on side: ThemeSide) -> [ListedTheme] {
    ThemeCatalog.themes(on: side).filter { $0.name == name }
  }

  // MARK: classification

  func testAUserThemeIsListedOnTheSideItsBackgroundGivesIt() throws {
    try withUserThemes(["My Paper": light, "My Night": dark]) {
      XCTAssertEqual(
        listed("My Paper", on: .light),
        [ListedTheme(name: "My Paper", side: .light, isUserTheme: true)])
      XCTAssertEqual(listed("My Paper", on: .dark), [])
      XCTAssertEqual(
        listed("My Night", on: .dark),
        [ListedTheme(name: "My Night", side: .dark, isUserTheme: true)])
      XCTAssertEqual(listed("My Night", on: .light), [])
    }
  }

  func testBundledThemesAreNotMarkedAsTheUsers() throws {
    try withUserThemes([:]) {
      XCTAssertEqual(
        listed("Catppuccin Latte", on: .light),
        [ListedTheme(name: "Catppuccin Latte", side: .light, isUserTheme: false)])
      XCTAssertTrue(ThemeCatalog.themes(on: .dark).allSatisfy { !$0.isUserTheme })
    }
  }

  func testAnUnparseableUserThemeIsHidden() throws {
    try withUserThemes(["Broken": "not a theme\n", "No Background": "foreground = #ffffff\n"]) {
      for side in ThemeSide.allCases {
        XCTAssertFalse(names(on: side).contains("Broken"))
        XCTAssertFalse(names(on: side).contains("No Background"))
      }
    }
  }

  /// Hidden files (`.DS_Store`) and directories in the themes folder are not themes.
  func testHiddenFilesAndDirectoriesAreNotListed() throws {
    try withUserThemes([".Hidden": dark]) { dir in
      try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("Subfolder"), withIntermediateDirectories: true)
      for side in ThemeSide.allCases {
        XCTAssertFalse(names(on: side).contains(".Hidden"))
        XCTAssertFalse(names(on: side).contains("Subfolder"))
      }
    }
  }

  func testNoUserThemeDirectoryListsOnlyTheBundledThemes() throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("workroom-no-themes-\(UUID().uuidString)").path
    ThemeCatalog.withUserThemeDirectory(missing) {
      XCTAssertEqual(
        Set(ThemeCatalog.themes(on: .light).map(\.name)),
        Set(ThemeCatalog.bundledThemes.filter { $0.side == .light }.map(\.name)))
    }
  }

  // MARK: order

  /// Workroom's theme for the side first, then everything else A→Z, the user's own themes among the
  /// bundled ones, case-insensitively.
  func testAListIsWorkroomFirstThenAlphabeticalWithTheUsersThemesAmongTheRest() throws {
    try withUserThemes(["aardvark": dark, "Nordic Mine": dark, "zzz Mine": dark]) {
      let dark = names(on: .dark)
      XCTAssertEqual(dark.first, "Workroom")
      let rest = Array(dark.dropFirst())
      // A known-good literal for the user's names among a few bundled ones, independent of how many
      // themes are bundled.
      let sample = [
        "aardvark", "Nord", "Nordic Mine", "TokyoNight Night", "Tomorrow Night", "zzz Mine",
      ]
      XCTAssertEqual(rest.filter { sample.contains($0) }, sample)
      XCTAssertEqual(rest.last, "zzz Mine")
      XCTAssertFalse(rest.contains("Workroom"))
    }
  }

  // MARK: replacement

  /// A user file named like a bundled theme replaces it: listed once, marked as the user's.
  func testAReplacementIsListedOnceAsTheUsers() throws {
    try withUserThemes(["Nord Light": light]) {
      XCTAssertEqual(
        listed("Nord Light", on: .light),
        [ListedTheme(name: "Nord Light", side: .light, isUserTheme: true)])
    }
  }

  /// A replacement with the other side's background moves to that side and leaves its own.
  func testAReplacementOnTheWrongSideMovesToTheOtherList() throws {
    try withUserThemes(["Ayu Light": dark]) {
      XCTAssertEqual(listed("Ayu Light", on: .light), [])
      XCTAssertEqual(
        listed("Ayu Light", on: .dark),
        [ListedTheme(name: "Ayu Light", side: .dark, isUserTheme: true)])
    }
  }

  /// An unparseable replacement hides the bundled theme it shares a name with, and that theme's
  /// family: ghostty still loads the user's file for the name, so offering the bundled theme would
  /// paint the chrome in colours the terminal never loads.
  func testAnUnparseableReplacementHidesTheBundledThemeAndItsFamily() throws {
    try withUserThemes(["Nord Light": "garbage\n"]) {
      for side in ThemeSide.allCases {
        XCTAssertFalse(names(on: side).contains("Nord Light"))
      }
      XCTAssertNil(ThemeCatalog.side(ofThemeNamed: "Nord Light"))
      XCTAssertFalse(ThemeCatalog.availableFamilies().contains { $0.name == "Nord" })
    }
  }

  /// A file whose name ghostty reads as a light/dark pair (a colon, comma or `=`) is hidden like an
  /// unparseable one and resolves to no side, so it can never be written as `theme =`.
  func testAUserThemeNamedLikeAPairIsHidden() throws {
    let pairs = ["light:Nord Light", "My, Night", "dark=Nord"]
    try withUserThemes(Dictionary(uniqueKeysWithValues: pairs.map { ($0, dark) })) {
      for name in pairs {
        for side in ThemeSide.allCases {
          XCTAssertFalse(names(on: side).contains(name), name)
        }
        XCTAssertNil(ThemeCatalog.side(ofThemeNamed: name), name)
        XCTAssertFalse(ThemeCatalog.isSingleThemeName(name), name)
      }
    }
  }

  /// One read of the folder answers every lookup: a file written after the read isn't seen until
  /// the next read.
  func testASnapshotIsTheFolderAsItWasWhenRead() throws {
    try withUserThemes([:]) { dir in
      let before = UserThemes.read()
      try dark.write(
        to: dir.appendingPathComponent("My Night"), atomically: true, encoding: .utf8)
      XCTAssertNil(ThemeCatalog.side(ofThemeNamed: "My Night", in: before))
      XCTAssertFalse(ThemeCatalog.themes(on: .dark, in: before).contains { $0.name == "My Night" })
      XCTAssertEqual(ThemeCatalog.side(ofThemeNamed: "My Night", in: .read()), .dark)
    }
  }

  /// A test's override of the user theme directory puts back whatever was in place before it, so a
  /// process-wide scratch directory survives a scoped one.
  func testAScopedOverridePutsTheOuterOneBack() throws {
    try withUserThemes([:]) { outer in
      try withUserThemes([:]) { inner in
        XCTAssertEqual(ThemeCatalog.userThemeDirectory(), inner.path)
      }
      XCTAssertEqual(ThemeCatalog.userThemeDirectory(), outer.path)
    }
  }

  /// Families match by name, so a pair that includes a replacement still shows the family's name.
  func testAPairWithAReplacementKeepsTheFamilysName() throws {
    try withUserThemes(["Catppuccin Mocha": dark]) {
      XCTAssertEqual(
        ThemeCatalog.familyLabel(light: "Catppuccin Latte", dark: "Catppuccin Mocha"), "Catppuccin")
      XCTAssertTrue(ThemeCatalog.availableFamilies().contains { $0.name == "Catppuccin" })
    }
  }

  // MARK: available families

  func testEveryFamilyIsAvailableWithNoUserThemes() throws {
    try withUserThemes([:]) {
      XCTAssertEqual(ThemeCatalog.availableFamilies(), ThemeCatalog.families)
    }
  }

  /// A family is hidden while either of its themes resolves to the wrong side, and only that family.
  func testAFamilyIsHiddenWhileAReplacementPutsOneOfItsThemesOnTheWrongSide() throws {
    try withUserThemes(["Ayu Light": dark, "Nord": light]) {
      let names = ThemeCatalog.availableFamilies().map(\.name)
      XCTAssertFalse(names.contains("Ayu"))
      XCTAssertFalse(names.contains("Nord"))
      XCTAssertEqual(names.count, ThemeCatalog.families.count - 2)
      XCTAssertEqual(names.first, ThemeCatalog.defaultFamilyName)
    }
  }

  /// Fixing the file brings the family back: the list is read when it loads, not remembered.
  func testFixingTheFileBringsTheFamilyBack() throws {
    try withUserThemes(["Ayu Light": dark]) { dir in
      XCTAssertFalse(ThemeCatalog.availableFamilies().contains { $0.name == "Ayu" })
      try light.write(
        to: dir.appendingPathComponent("Ayu Light"), atomically: true, encoding: .utf8)
      XCTAssertTrue(ThemeCatalog.availableFamilies().contains { $0.name == "Ayu" })
    }
  }

  /// Run `body` with the user theme directory pointed at a fresh temp dir holding `files`.
  private func withUserThemes(
    _ files: [String: String], _ body: (URL) throws -> Void
  ) throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("workroom-user-themes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for (name, contents) in files {
      try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try ThemeCatalog.withUserThemeDirectory(dir.path) { try body(dir) }
  }

  private func withUserThemes(_ files: [String: String], _ body: () throws -> Void) throws {
    try withUserThemes(files) { (_: URL) in try body() }
  }
}
