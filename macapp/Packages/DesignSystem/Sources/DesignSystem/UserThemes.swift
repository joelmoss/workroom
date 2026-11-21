import Foundation

/// The user's own theme files (`ThemeCatalog.userThemeDirectory()`), read once (#737). The Light and
/// Dark lists, the families on offer and one apply each resolve against one read, so a list or an
/// apply touches the folder once rather than once per theme name; a later read sees the folder as it
/// is then, so a fixed file comes back the next time a list loads.
public struct UserThemes: Sendable {
  /// What the folder holds under one name.
  enum Entry: Sendable {
    /// No file: the bundled theme of that name, if any, is the one ghostty loads.
    case absent
    /// A file that doesn't parse, or whose name ghostty reads as a pair. Ghostty would still find it
    /// first, so the name resolves to nothing rather than to a bundled theme.
    case unusable
    case theme(ThemePreview)
  }

  private let entries: [String: Entry]

  /// Nothing in the folder.
  public static let empty = UserThemes(entries: [:])

  private init(entries: [String: Entry]) { self.entries = entries }

  func entry(named name: String) -> Entry { entries[name] ?? .absent }

  /// Whether a file in the folder takes `name`, usable or not.
  func shadows(_ name: String) -> Bool {
    if case .absent = entry(named: name) { return false }
    return true
  }

  /// The usable files, each classified by its background. User themes never form families.
  var listed: [ListedTheme] {
    entries.compactMap { name, entry in
      guard case .theme(let preview) = entry else { return nil }
      return ListedTheme(
        name: name, side: ThemeSide(background: preview.background), isUserTheme: true)
    }
  }

  /// Every file in the folder now. Hidden files (`.DS_Store`) and directories are not themes.
  public static func read() -> UserThemes {
    let dir = ThemeCatalog.userThemeDirectory()
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
      return .empty
    }
    var entries: [String: Entry] = [:]
    for name in names {
      if let entry = readEntry(named: name, in: dir) { entries[name] = entry }
    }
    return UserThemes(entries: entries)
  }

  /// Only the files `names` name, for a lookup of a theme or two.
  public static func reading(named names: String...) -> UserThemes {
    let dir = ThemeCatalog.userThemeDirectory()
    var entries: [String: Entry] = [:]
    for name in names {
      if let entry = readEntry(named: name, in: dir) { entries[name] = entry }
    }
    return UserThemes(entries: entries)
  }

  private static func readEntry(named name: String, in dir: String) -> Entry? {
    guard !name.hasPrefix("."), !name.contains("/") else { return nil }
    let path = dir + "/" + name
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return nil }
    guard ThemeCatalog.isSingleThemeName(name),
      let preview = ThemeCatalog.parseThemeFile(atPath: path, name: name)
    else { return .unusable }
    return .theme(preview)
  }
}
