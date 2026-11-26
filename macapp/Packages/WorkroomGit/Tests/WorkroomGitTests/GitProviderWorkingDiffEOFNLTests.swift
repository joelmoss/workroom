import Foundation
import WorkroomSystem
import XCTest

@testable import WorkroomGit

/// `GitProvider.workingFileDiff` against `git diff` for a file with no newline at its end, on either
/// side. libgit2 reports git's `\ No newline at end of file` marker as a line of its own whose text
/// starts with the newline that ends the line before it, so it takes no `+`/`-`/space prefix: one
/// there lands at the end of the real last line.
///
/// Repos are created fresh under `NSTemporaryDirectory()` and removed in `tearDown`; these never touch
/// a developer's own repository.
final class GitProviderWorkingDiffEOFNLTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  func testRemovingTheFinalNewlineMatchesGit() async throws {
    try await assertWorkingDiffMatchesGit(committed: "one\ntwo\n", onDisk: "one\ntwo")
  }

  func testAddingAFinalNewlineMatchesGit() async throws {
    try await assertWorkingDiffMatchesGit(committed: "one\ntwo", onDisk: "one\ntwo\n")
  }

  func testEditingAnEarlierLineOfAFileWithoutAFinalNewlineMatchesGit() async throws {
    try await assertWorkingDiffMatchesGit(committed: "one\ntwo", onDisk: "uno\ntwo")
  }

  // MARK: - helpers

  /// Commit `committed` as `f.txt`, write `onDisk` over it, and compare the hunks of
  /// `workingFileDiff` with `git diff`'s. Hunk headers are compared up to their closing `@@`: git
  /// appends a function-context hint after it that libgit2's blob patches don't.
  private func assertWorkingDiffMatchesGit(
    committed: String, onDisk: String, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let repo = NSTemporaryDirectory() + "wr-eofnl-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    dirs.append(repo)
    let path = URL(fileURLWithPath: repo).appendingPathComponent("f.txt")
    XCTAssertEqual(sh("git init -q", in: repo).exit, 0)
    try committed.write(to: path, atomically: true, encoding: .utf8)
    XCTAssertEqual(
      sh("git add f.txt && git -c user.name=t -c user.email=t@example.com commit -qm c", in: repo)
        .exit, 0)
    try onDisk.write(to: path, atomically: true, encoding: .utf8)

    let expected = Self.hunks(sh("git diff --no-color -- f.txt", in: repo).out)
    let actual = Self.hunks(
      try await GitProvider().workingFileDiff(root: URL(fileURLWithPath: repo), path: "f.txt"))
    XCTAssertFalse(expected.isEmpty, "git diff reported no change", file: file, line: line)
    XCTAssertEqual(actual, expected, file: file, line: line)
  }

  /// A git-format patch's text from its first hunk on, each hunk header cut after its closing `@@`.
  private static func hunks(_ patch: String) -> String {
    let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
    guard let first = lines.firstIndex(where: { $0.hasPrefix("@@") }) else { return "" }
    return lines[first...].map { line in
      guard line.hasPrefix("@@"),
        let close = line.range(
          of: " @@", options: [],
          range:
            line.index(line.startIndex, offsetBy: 2)..<line.endIndex)
      else { return String(line) }
      return String(line[..<close.upperBound])
    }.joined(separator: "\n")
  }

  private func sh(_ cmd: String, in dir: String) -> (out: String, exit: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    var env = ProcessInfo.processInfo.environment
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_SYSTEM"] = "/dev/null"
    env["PATH"] = ShellEnvironment.path()
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
  }
}
