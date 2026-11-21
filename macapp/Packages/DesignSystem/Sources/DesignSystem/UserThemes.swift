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

  /// Each file's entry under its lookup key (`key(for:)`), with the name it has on disk.
  private let entries: [String: (name: String, entry: Entry)]
  /// Whether the folder's volume tells names apart by case. Most macOS volumes don't, so ghostty,
  /// asked for `Nord`, opens a file named `nord`, and a lookup has to match the same way.
  private let caseSensitive: Bool

  /// Nothing in the folder.
  public static let empty = UserThemes(entries: [:], caseSensitive: true)

  private init(entries: [String: (name: String, entry: Entry)], caseSensitive: Bool) {
    self.entries = entries
    self.caseSensitive = caseSensitive
  }

  /// `name` as the folder's volume compares names: as is on a case-sensitive volume, case-folded
  /// otherwise; both in one Unicode form, as the file system stores names.
  private static func key(for name: String, caseSensitive: Bool) -> String {
    let composed = name.precomposedStringWithCanonicalMapping
    return caseSensitive ? composed : composed.folding(options: .caseInsensitive, locale: nil)
  }

  func entry(named name: String) -> Entry {
    entries[Self.key(for: name, caseSensitive: caseSensitive)]?.entry ?? .absent
  }

  /// Whether a file in the folder takes `name`, usable or not.
  func shadows(_ name: String) -> Bool {
    if case .absent = entry(named: name) { return false }
    return true
  }

  /// The usable files, each classified by its background. User themes never form families.
  var listed: [ListedTheme] {
    entries.values.compactMap { file in
      guard case .theme(let preview) = file.entry else { return nil }
      return ListedTheme(
        name: file.name, side: ThemeSide(background: preview.background), isUserTheme: true)
    }
  }

  /// Every file in the folder now. Hidden files (`.DS_Store`) and directories are not themes.
  public static func read() -> UserThemes {
    let dir = ThemeCatalog.userThemeDirectory()
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
      return .empty
    }
    return snapshot(of: names, in: dir)
  }

  /// Only the files `names` name, for a lookup of a theme or two.
  public static func reading(named names: String...) -> UserThemes {
    snapshot(of: names, in: ThemeCatalog.userThemeDirectory())
  }

  private static func snapshot(of names: [String], in dir: String) -> UserThemes {
    let caseSensitive = isCaseSensitive(dir)
    var entries: [String: (name: String, entry: Entry)] = [:]
    for name in names {
      if let entry = readEntry(named: name, in: dir) {
        entries[key(for: name, caseSensitive: caseSensitive)] = (name, entry)
      }
    }
    return UserThemes(entries: entries, caseSensitive: caseSensitive)
  }

  /// Whether `dir`'s volume tells names apart by case; a volume that doesn't say is taken as macOS's
  /// default, which doesn't.
  private static func isCaseSensitive(_ dir: String) -> Bool {
    let values = try? URL(fileURLWithPath: dir).resourceValues(forKeys: [
      .volumeSupportsCaseSensitiveNamesKey
    ])
    return values?.volumeSupportsCaseSensitiveNames ?? false
  }

  private static func readEntry(named name: String, in dir: String) -> Entry? {
    guard !name.hasPrefix("."), !name.contains("/") else { return nil }
    let path = dir + "/" + name
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return nil }
    // A name the generated config would have to change (a quote or a backslash) can't be written
    // into it as is, so the file could never load: unusable, as the bundled import rejects it too.
    guard ThemeCatalog.isSingleThemeName(name), ThemeCatalog.sanitizedThemeName(name) == name,
      let preview = ThemeCatalog.parseThemeFile(atPath: path, name: name)
    else { return .unusable }
    return .theme(preview)
  }
}
