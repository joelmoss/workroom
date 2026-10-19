import Foundation
import XCTest

@testable import Workroom

/// The docs site's keyboard shortcuts page (`docs-site/pages/reference/keyboard-shortcuts.md`) lists
/// exactly the shortcuts `KeyboardShortcutsView.groups` shows, under the same groups' headings, so the two
/// can't drift: a shortcut added, changed, renamed or removed in the app fails here until the page
/// says the same.
final class KeyboardShortcutsDocsTests: XCTestCase {
  private static let page = URL(fileURLWithPath: String(describing: #filePath))
    .deletingLastPathComponent()  // WorkroomAppTests
    .deletingLastPathComponent()  // macapp
    .deletingLastPathComponent()  // repository root
    .appendingPathComponent("docs-site/pages/reference/keyboard-shortcuts.md")

  func testThePageListsExactlyTheShortcutsTheAppShows() throws {
    let groups = KeyboardShortcutsView.groups
    XCTAssertFalse(groups.isEmpty, "the app shows no shortcuts, so nothing was compared")
    let page = try Self.pageRows()

    for group in groups {
      guard let rows = page[group.title] else {
        XCTFail("no “## \(group.title)” heading on the page")
        continue
      }
      let want = Set(group.items.map(Self.row))
      for row in want.subtracting(rows).sorted() {
        XCTFail("the page has no row “\(row)” in “\(group.title)”")
      }
      for row in rows.subtracting(want).sorted() {
        XCTFail("the page's row “\(row)” in “\(group.title)” is not a shortcut the app shows there")
      }
    }
    // Sections that aren't app groups are the page's own, such as "More" (the menus' shortcuts
    // that the sheet leaves out), so they aren't compared.
  }

  /// A shortcut's table row, as docs-site/README.md writes one: a `|` in a label is escaped.
  private static func row(_ item: ShortcutItem) -> String {
    "| \(item.label.replacingOccurrences(of: "|", with: #"\|"#)) | <kbd>\(item.keys)</kbd> |"
  }

  /// Each `##` section's shortcut rows: the table rows whose last cell is a `<kbd>`.
  private static func pageRows() throws -> [String: Set<String>] {
    var sections: [String: Set<String>] = [:]
    var current: String?
    for line in try String(contentsOf: page, encoding: .utf8).components(separatedBy: "\n") {
      let line = line.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("## ") {
        current = String(line.dropFirst(3))
        sections[current!, default: []] = []
      } else if let current, line.hasPrefix("|"), line.hasSuffix("</kbd> |") {
        sections[current, default: []].insert(line)
      }
    }
    return sections
  }
}
