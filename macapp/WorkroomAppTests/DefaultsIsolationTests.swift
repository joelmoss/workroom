import Defaults
import XCTest

@testable import Workroom

/// Tests must never read or write the developer's real state (user instruction, 2026-09-11).
///
/// The hazard is structural, not incidental: `WorkroomAppTests` is hosted by `Workroom Dev.app`, so
/// the whole app boots for every `make app-test` run, and `Defaults.Key` captures its suite at
/// DECLARATION with `UserDefaults.standard` as the default. One key declared without a suite is
/// enough to put a test's writes into the preferences the developer actually uses — theme, release
/// channel, inspector layout, run commands. `UserDefaults.app` redirects to a throwaway suite under
/// test; these two tests keep that redirect honest.
final class DefaultsIsolationTests: XCTestCase {

  func testTheAppSuiteIsIsolatedWhileTesting() {
    XCTAssertNotEqual(
      UserDefaults.app, UserDefaults.standard,
      "under XCTest the app's preference domain must be a throwaway suite, never the real one")
  }

  /// Scans the source rather than the runtime, because there is no way to enumerate `Defaults.Keys`
  /// — and a key added tomorrow without `suite: .app` is exactly the regression worth catching.
  func testEveryShippedKeyDeclaresTheAppSuite() throws {
    let keysFile = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // WorkroomAppTests
      .deletingLastPathComponent()  // macapp
      .appendingPathComponent("WorkroomApp/Core/DefaultsKeys.swift")
    let source = try String(contentsOf: keysFile, encoding: .utf8)

    // Declarations are `static let <name> = Key<…>(…)`, one per key, so splitting on the keyword
    // gives one chunk per declaration.
    let declarations = source.components(separatedBy: "static let ").dropFirst()
    let keyDeclarations = declarations.filter { $0.contains("= Key<") }
    XCTAssertGreaterThanOrEqual(
      keyDeclarations.count, 41, "parse looks wrong — the file declares at least this many keys")

    for declaration in keyDeclarations {
      let name = declaration.prefix { $0 != " " }
      XCTAssertTrue(
        declaration.contains("suite: .app"),
        "`\(name)` is declared without `suite: .app`, so it writes the developer's real preferences"
      )
    }
  }
}
