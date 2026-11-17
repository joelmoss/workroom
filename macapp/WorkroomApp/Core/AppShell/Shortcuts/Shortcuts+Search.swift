import Foundation

/// Settings ▸ Keyboard Shortcuts' search (#148).
extension Shortcuts {
  /// Whether a row matches a search: the query is in its label, its description or its keys as
  /// glyphs ("⌘T"); or every word of it is. A query naming a modifier ("cmd t", "shift") is about
  /// keys, so then every word must be one of the row's key names.
  static func matches(_ action: ShortcutAction, query: String, table: ShortcutTable) -> Bool {
    let query = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return true }
    let text = "\(action.label) \(action.summary)".lowercased()
    let glyphs = table.label(for: action)?.lowercased()
    func inGlyphs(_ text: String) -> Bool { glyphs?.contains(text) ?? false }
    if text.contains(query) || inGlyphs(query) { return true }
    let keyWords = Set(
      table.binding(for: action).map { ShortcutTable.searchNames(for: action, $0) } ?? [])
    let words = query.split(separator: " ").map(String.init)
    if words.contains(where: modifierWords.contains) {
      return words.allSatisfy(keyWords.contains)
    }
    return words.allSatisfy { word in
      text.contains(word) || keyWords.contains(word) || inGlyphs(word)
    }
  }

  private static let modifierWords: Set<String> = {
    let all: KeyModifiers = [.command, .option, .control, .shift]
    return Set(all.names)
  }()
}
