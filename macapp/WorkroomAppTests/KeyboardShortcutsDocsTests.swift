import Foundation
import XCTest

@testable import Workroom

/// The docs site's keyboard shortcuts page (`docs-site/pages/reference/keyboard-shortcuts.md`) lists
/// exactly the default shortcuts Settings ▸ Keyboard Shortcuts has (#148), under the same groups'
/// headings, so the two can't drift: a default added, changed, renamed or removed in the app fails
/// here until the page says the same. Actions with no default shortcut have no row.
@MainActor
final class KeyboardShortcutsDocsTests: XCTestCase {
  private static let page = SharedFixture.repositoryRoot
    .appendingPathComponent("docs-site/pages/reference/keyboard-shortcuts.md")

  func testThePageListsExactlyTheDefaultShortcuts() throws {
    let page = try Self.pageRows()
    var compared = 0
    for group in ShortcutGroup.allCases {
      let want = Set(
        group.actions.compactMap { action in
          action.defaultBinding.map { Self.row(action.label, ShortcutTable.label(for: action, $0)) }
        })
      guard !want.isEmpty else { continue }
      compared += want.count
      guard let rows = page[group.title] else {
        XCTFail("no “## \(group.title)” heading on the page")
        continue
      }
      for row in want.subtracting(rows).sorted() {
        XCTFail("the page has no row “\(row)” in “\(group.title)”")
      }
      for row in rows.subtracting(want).sorted() {
        XCTFail("the page's row “\(row)” in “\(group.title)” is not a default the app has there")
      }
    }
    XCTAssertGreaterThan(compared, 40, "the app has fewer defaults than this, so nothing compared")
  }

  /// A shortcut's table row, as docs-site/README.md writes one: a `|` in a label is escaped.
  private static func row(_ label: String, _ keys: String) -> String {
    "| \(label.replacingOccurrences(of: "|", with: #"\|"#)) | <kbd>\(keys)</kbd> |"
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
