import Foundation

/// Files these tests read from the repository rather than from the test bundle: the CLI's contract
/// goldens, the docs site, and the case tables a rule's copies in other runtimes also read.
enum SharedFixture {
  /// The repository root, found from this file's own source location.
  static let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Support
    .deletingLastPathComponent()  // WorkroomAppTests
    .deletingLastPathComponent()  // macapp
    .deletingLastPathComponent()  // repository root

  struct MalformedTable: Error, CustomStringConvertible {
    let description: String
  }

  /// The table at `relativePath` under the repository root: one row per line that is neither
  /// blank nor a `#` comment, split on tabs, each with exactly `columns` fields. A malformed line
  /// or a table with no rows throws, so an emptied table can't pass vacuously.
  static func rows(_ relativePath: String, columns: Int) throws -> [[String]] {
    let url = repositoryRoot.appendingPathComponent(relativePath)
    var rows: [[String]] = []
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    where !line.hasPrefix("#") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == columns else {
        throw MalformedTable(
          description: "malformed line in \(relativePath) (want \(columns) fields): \(line)")
      }
      rows.append(fields)
    }
    guard !rows.isEmpty else { throw MalformedTable(description: "no cases in \(relativePath)") }
    return rows
  }
}
