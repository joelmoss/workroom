import Foundation
import XCTest

@testable import Workroom

/// Views must reach VCS through a seam, never by spawning a command or reading a repo's private
/// directories themselves.
///
/// **Why this is a source scan and not a unit test.** The rule is about which code a View is allowed
/// to call, and nothing at runtime can observe that: a View that spawns `git` behaves identically to
/// one that asks the store, right up until the repo is not on this Mac. `CommitSheet.prefill` did
/// exactly that — `StatusCommandRunner().run("jj", …)` plus a `.git` directory listing — and the
/// only symptom would have been a remote workroom's commit dialog opening blank (issue #154,
/// Phase 2). Same technique, and the same reasoning, as
/// `DefaultsIsolationTests.testEveryShippedKeyDeclaresTheAppSuite`.
final class ViewVCSSeamTests: XCTestCase {
  private static let viewsDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // WorkroomAppTests
    .deletingLastPathComponent()  // macapp
    .appendingPathComponent("WorkroomApp/Views")

  /// Spawning a VCS process, or calling one of `CLIVCSWriter`'s statics to build its arguments or
  /// stat its repo, is the bypass this catches. `VCSWriting`'s own protocol types are fine — a View
  /// naming `VCSCommitPreflight` or `VCSCommitMode` is using the seam, which is the point.
  private static let forbidden = [
    "StatusCommandRunner(": "spawns a VCS command from a View — ask the store instead",
    "CLIVCSWriter.": "reaches into the CLI writer's internals — go through `VCSWriting`",
  ]

  /// Enumerated RECURSIVELY, not with `contentsOfDirectory`.
  ///
  /// `Views/` happens to be flat today, but the target's source glob compiles nested files and the
  /// tree already nests elsewhere (`Core/Session`, `Core/SyntaxHighlighting`). A `Views/Inspector/`
  /// added tomorrow would sit outside a shallow scan while the count assertion below — which only
  /// ever saw the direct children — stayed green, which is precisely the silently-passing guard
  /// this file exists to avoid being.
  private static func viewSources() throws -> [URL] {
    guard
      let walker = FileManager.default.enumerator(
        at: viewsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
  }

  func testNoViewSpawnsVCSCommandsOrReadsARepoDirectly() throws {
    let files = try Self.viewSources()

    XCTAssertGreaterThan(files.count, 10, "the Views directory did not resolve — the scan is void")

    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      for (needle, why) in Self.forbidden {
        XCTAssertFalse(
          source.contains(needle),
          "\(file.lastPathComponent) contains `\(needle)` — \(why)")
      }
    }
  }

  /// The scan is only worth anything if those strings are what the bypass actually looks like, so
  /// this pins the needles against the real call shapes rather than trusting them.
  ///
  /// Without it a typo'd needle (`StatusCommandRunner(` → `StatusCommandRunnner(`) would leave the
  /// test permanently, silently green.
  func testTheForbiddenPatternsMatchTheCallsTheyDescribe() {
    let realBypasses = [
      #"await StatusCommandRunner().run("jj", CLIVCSWriter.jjDescriptionArgs(), in: path)"#,
      #"CLIVCSWriter.sequencerState(gitDir: CLIVCSWriter.worktreeGitDir(at: item.path))"#,
    ]
    for bypass in realBypasses {
      XCTAssertTrue(
        Self.forbidden.keys.contains(where: bypass.contains),
        "no pattern matches `\(bypass)`, so the scan would not have caught it")
    }
  }
}
