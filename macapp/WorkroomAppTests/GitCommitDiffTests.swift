import XCTest

@testable import Workroom

/// `GitCommitDiff` unit tests against REAL throwaway git repos, in the shape of `GitGraphTests` (the
/// other raw-libgit2 reader). What matters isn't the similarity math — libgit2 owns that — but the
/// contract our History depends on:
///
/// - a committed rename is ONE row carrying both paths, matching what `git show` prints, because git's
///   CLI has `diff.renames=true` by default;
/// - the per-file patch is git-format text with the `rename from`/`rename to` headers `UnifiedDiff`
///   parses;
/// - a root commit diffs against the empty tree (all files added), not against itself;
/// - a failed read is `nil` — never an empty diff, which the caller would render as "no changes".
///
/// Repos are created fresh under `NSTemporaryDirectory()` and removed in `tearDown`; these never touch
/// a developer's own repository.
final class GitCommitDiffTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  // MARK: - helpers

  private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "wr-gcd-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    dirs.append(d)
    return d
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
    do { try p.run() } catch { return ("", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
  }

  private func requireGit() throws {
    struct MissingTool: Error {}
    if sh("command -v git", in: NSTemporaryDirectory()).exit != 0 {
      XCTFail("`git` is required for GitCommitDiff tests")
      throw MissingTool()
    }
  }

  /// A repo whose first commit adds an 8-line `old.txt` (long enough for the 50% similarity default to
  /// have something to measure). Returns the work tree path.
  private func repoWithFile() throws -> String {
    try requireGit()
    let root = tempDir()
    sh(
      """
      git init -q -b main .
      git config user.email a@b.c && git config user.name t
      printf 'one\\ntwo\\nthree\\nfour\\nfive\\nsix\\nseven\\neight\\n' > old.txt
      git add . && git commit -qm 'add old.txt'
      """, in: root)
    return root
  }

  private func head(_ root: String) -> String {
    sh("git rev-parse HEAD", in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - rename detection

  func testPureRenameIsOneRow() throws {
    let root = try repoWithFile()
    sh("git mv old.txt new.txt && git commit -qm 'rename old.txt'", in: root)

    let read = try XCTUnwrap(
      GitCommitDiff.read(root: URL(fileURLWithPath: root), commitID: head(root)))
    XCTAssertEqual(read.files.count, 1, "a rename is one row, not delete + add: \(read.files)")
    let row = try XCTUnwrap(read.files.first)
    XCTAssertEqual(row.kind, .renamed)
    XCTAssertEqual(row.path, "new.txt")
    XCTAssertEqual(row.oldPath, "old.txt")
    // What `git show --stat` reports for a pure rename: no content changed.
    XCTAssertEqual(read.insertions, 0)
    XCTAssertEqual(read.deletions, 0)
  }

  /// A rename that also EDITS the file still has to pair — an exact-content match would be the easy
  /// case, and the one git wouldn't need `git_diff_find_similar` for.
  func testRenameWithEditsStillPairs() throws {
    let root = try repoWithFile()
    sh(
      """
      git mv old.txt new.txt
      printf 'one\\ntwo\\nthree\\nfour\\nFIVE\\nsix\\nseven\\neight\\n' > new.txt
      git add . && git commit -qm 'rename and edit'
      """, in: root)

    let read = try XCTUnwrap(
      GitCommitDiff.read(root: URL(fileURLWithPath: root), commitID: head(root)))
    XCTAssertEqual(read.files.map(\.kind), [.renamed], "got \(read.files)")
    XCTAssertEqual(read.files.first?.oldPath, "old.txt")
    XCTAssertEqual(read.insertions, 1)
    XCTAssertEqual(read.deletions, 1)
  }

  func testRenamePatchCarriesTheRenameHeaders() throws {
    let root = try repoWithFile()
    sh("git mv old.txt new.txt && git commit -qm 'rename old.txt'", in: root)

    let text = try XCTUnwrap(
      GitCommitDiff.patch(
        root: URL(fileURLWithPath: root), commitID: head(root), path: "new.txt"))
    XCTAssertTrue(
      text.contains("rename from old.txt"), "libgit2 should print git's rename headers: \(text)")
    XCTAssertEqual(
      UnifiedDiff.parse(text).renamedFrom, "old.txt", "the app's parser must read the old path")
  }

  /// The pre-move path has to resolve too: History can be asked for either side of a pair.
  func testRenamePatchIsFoundByTheOldPath() throws {
    let root = try repoWithFile()
    sh("git mv old.txt new.txt && git commit -qm 'rename old.txt'", in: root)

    let text = try XCTUnwrap(
      GitCommitDiff.patch(
        root: URL(fileURLWithPath: root), commitID: head(root), path: "old.txt"))
    XCTAssertTrue(text.contains("rename to new.txt"), "got \(text)")
  }

  // MARK: - the ordinary cases detection must not disturb

  func testPlainModifyIsUntouched() throws {
    let root = try repoWithFile()
    sh("echo nine >> old.txt && git commit -qam 'append'", in: root)

    let read = try XCTUnwrap(
      GitCommitDiff.read(root: URL(fileURLWithPath: root), commitID: head(root)))
    XCTAssertEqual(read.files.map(\.kind), [.modified])
    XCTAssertEqual(read.files.first?.path, "old.txt")
    XCTAssertNil(read.files.first?.oldPath, "only a pair carries the old path")
    XCTAssertEqual(read.insertions, 1)
    XCTAssertEqual(read.deletions, 0)
  }

  func testDeleteNamesTheDeletedFile() throws {
    let root = try repoWithFile()
    sh("git rm -q old.txt && git commit -qm 'drop old.txt'", in: root)

    let read = try XCTUnwrap(
      GitCommitDiff.read(root: URL(fileURLWithPath: root), commitID: head(root)))
    XCTAssertEqual(read.files.map(\.kind), [.deleted])
    XCTAssertEqual(read.files.first?.path, "old.txt")
    XCTAssertNil(read.files.first?.oldPath)
  }

  /// SwiftGitX's `diff(commit:)` diffs a root commit against ITSELF, so this used to come back empty —
  /// the first commit of every repo showed no files at all.
  func testRootCommitListsItsFilesAsAdded() throws {
    let root = try repoWithFile()

    let read = try XCTUnwrap(
      GitCommitDiff.read(root: URL(fileURLWithPath: root), commitID: head(root)))
    XCTAssertEqual(read.files.map { "\($0.kind):\($0.path)" }, ["added:old.txt"])
    XCTAssertEqual(read.insertions, 8)
  }

  /// A merge diffs against its FIRST parent, which is what `git show` does — so the side branch's own
  /// change isn't reported as part of the merge.
  func testMergeDiffsAgainstTheFirstParent() throws {
    let root = try repoWithFile()
    sh(
      """
      git checkout -q -b side && echo side > side.txt && git add . && git commit -qm side
      git checkout -q main && echo main > main.txt && git add . && git commit -qm main
      git merge -q --no-ff -m merge side
      """, in: root)

    let read = try XCTUnwrap(
      GitCommitDiff.read(root: URL(fileURLWithPath: root), commitID: head(root)))
    XCTAssertEqual(read.files.map { "\($0.kind):\($0.path)" }, ["added:side.txt"])
  }

  // MARK: - failure is nil, never an empty diff

  func testUnknownCommitIsNil() throws {
    let root = try repoWithFile()
    XCTAssertNil(
      GitCommitDiff.read(
        root: URL(fileURLWithPath: root),
        commitID: "0000000000000000000000000000000000000000"))
    XCTAssertNil(
      GitCommitDiff.read(root: URL(fileURLWithPath: root), commitID: "not-a-sha"))
  }

  func testNonRepoIsNil() throws {
    let dir = tempDir()
    XCTAssertNil(
      GitCommitDiff.read(
        root: URL(fileURLWithPath: dir), commitID: String(repeating: "0", count: 40)))
  }

  /// A path this commit didn't touch is `""` — a distinct answer from `nil` (couldn't read), because
  /// the caller renders one as "nothing to show" and must surface the other as an error.
  func testUnchangedPathIsEmptyNotNil() throws {
    let root = try repoWithFile()
    sh("echo nine >> old.txt && git commit -qam 'append'", in: root)

    XCTAssertEqual(
      GitCommitDiff.patch(
        root: URL(fileURLWithPath: root), commitID: head(root), path: "absent.txt"), "")
  }
}
