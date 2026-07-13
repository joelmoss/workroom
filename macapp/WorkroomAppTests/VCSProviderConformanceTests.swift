import XCTest

@testable import Workroom

/// Cross-backend conformance: on a **colocated** jj+git repo (where a jj commit-id == the git sha),
/// `RustJJProvider` (jj-lib) and `GitProvider` (SwiftGitX) must produce the SAME changeset file list
/// for the same commit. This guards against the two backends drifting on add/modify/delete
/// classification — the risk the hybrid architecture accepts (plan: "unify at the model layer +
/// a cross-backend conformance test").
///
/// Requires real `git` + `jj` (CI installs both). Throwaway repos under `NSTemporaryDirectory()`,
/// removed in `tearDown` — never touches a developer's own repositories.
final class VCSProviderConformanceTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  func testColocatedChangesetFileListMatchesAcrossBackends() async throws {
    try requireTool("git")
    try requireTool("jj")
    let root = try colocatedFixture()
    let url = URL(fileURLWithPath: root)

    // The changeset under test = the parent of the working copy (the last real commit).
    let cid = sh(
      "jj log -r @- --no-graph --ignore-working-copy --color never -T 'commit_id'", in: root
    ).out.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(cid.isEmpty, "could not resolve a commit id")

    let jj = try await RustJJProvider().changeset(root: url, commitID: cid)
    let git = try await GitProvider().changeset(root: url, commitID: cid)

    func key(_ f: VCSChangedFile) -> String { "\(f.kind):\(f.path)" }
    XCTAssertEqual(
      Set(jj.files.map(key)), Set(git.files.map(key)),
      "changeset file lists differ between jj and git backends")
    XCTAssertEqual(jj.commit.summary, git.commit.summary, "commit summary differs")
    XCTAssertEqual(
      Set(jj.files.map(key)), Set(["modified:a.txt", "added:b.txt"]),
      "unexpected changed files")
  }

  // MARK: - Fixture helpers (mirror WorkroomStatusIntegrationTests)

  private struct MissingTool: Error { let name: String }

  private func requireTool(_ name: String) throws {
    if sh("command -v \(name)", in: NSTemporaryDirectory()).exit != 0 {
      XCTFail("`\(name)` is required for conformance tests; CI installs it (brew install \(name))")
      throw MissingTool(name: name)
    }
  }

  private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "wr-conf-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    dirs.append(d)
    return d
  }

  /// A colocated jj+git repo with two real commits; the second changes a.txt (modified) and adds
  /// b.txt (added). Colocated init means jj exports commits to git, so the git repo sees the same
  /// commit under the same sha.
  private func colocatedFixture() throws -> String {
    let root = tempDir()
    let r = sh(
      """
      jj git init . >/dev/null 2>&1 || jj init --git . >/dev/null 2>&1
      jj config set --repo user.name t >/dev/null 2>&1 || true
      jj config set --repo user.email a@b.c >/dev/null 2>&1 || true
      printf 'one\\n' > a.txt
      jj commit -m 'add a.txt' >/dev/null 2>&1
      printf 'one\\ntwo\\n' > a.txt
      printf 'new\\n' > b.txt
      jj commit -m 'modify a, add b' >/dev/null 2>&1
      echo done
      """, in: root)
    XCTAssertTrue(r.out.contains("done"), "colocated fixture setup failed: \(r.out)")
    return root
  }

  @discardableResult
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
    do {
      try p.run()
    } catch {
      return ("", -1)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
  }
}
