import XCTest

@testable import Workroom

/// `GitCommitDiff` unit tests against REAL throwaway git repos, in the shape of `GitGraphTests` (the
/// other raw-libgit2 reader). What matters isn't the similarity math — libgit2 owns that — but the
/// contract our History depends on:
///
/// - a committed rename is ONE row carrying both paths, matching what `git show` prints, because git's
///   CLI has `diff.renames=true` by default;
/// - the pairing follows the REPO's `diff.renames`, not a flag we hard-code, so a repo that turns
///   detection off gets exactly the two rows its own `git show` prints;
/// - the per-file patch is git-format text with the `rename from`/`rename to` headers `UnifiedDiff`
///   parses;
/// - a root commit diffs against the empty tree (all files added), not against itself, and so does a
///   shallow clone's boundary commit — a missing parent is the end of our history, not a failure;
/// - a type change (file → symlink) is ONE row for the path, never two rows sharing an id;
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

  /// `diff.renames=false` has to be obeyed. libgit2 reads that config ONLY when
  /// `git_diff_find_similar` is given NULL options — spell `GIT_DIFF_FIND_RENAMES` out and
  /// `normalize_find_opts` skips the config read altogether, so the app would pair a rename that a
  /// `git show` in the very same repo splits in two.
  func testRenameDetectionObeysTheRepoConfig() throws {
    let root = try repoWithFile()
    sh(
      """
      git config diff.renames false
      git mv old.txt new.txt && git commit -qm 'rename old.txt'
      """, in: root)

    // git's own read of this commit under this config: two entries, not one.
    XCTAssertEqual(
      sh("git show --name-status --format= HEAD", in: root).out.trimmingCharacters(
        in: .whitespacesAndNewlines), "A\tnew.txt\nD\told.txt")

    let read = try XCTUnwrap(
      GitCommitDiff.read(root: URL(fileURLWithPath: root), commitID: head(root)))
    XCTAssertEqual(
      read.files.map { "\($0.kind):\($0.path)" }, ["added:new.txt", "deleted:old.txt"],
      "the repo turned detection off; we must not pair behind its back")
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

  /// A file that becomes a symlink is ONE row. Without `GIT_DIFF_INCLUDE_TYPECHANGE` libgit2 splits
  /// the change into DELETED + ADDED for the SAME path — two `VCSChangedFile`s sharing one `id`, since
  /// the id IS the path, which is exactly what the History list's `ForEach` over `Identifiable`
  /// cannot render. git calls the same change one entry (`T`), which is what this asserts against.
  func testTypeChangeIsOneRowNotASelfRename() throws {
    let root = try repoWithFile()
    sh(
      """
      printf '#!/bin/sh\\necho hi\\n' > tool
      git add tool && git commit -qm 'add tool'
      rm tool && ln -s old.txt tool
      git add tool && git commit -qm 'tool becomes a symlink'
      """, in: root)

    // git's own read of the same commit: one entry, status `T`.
    XCTAssertEqual(
      sh("git show --name-status --format= HEAD", in: root).out.trimmingCharacters(
        in: .whitespacesAndNewlines), "T\ttool")

    let read = try XCTUnwrap(
      GitCommitDiff.read(root: URL(fileURLWithPath: root), commitID: head(root)))
    XCTAssertEqual(read.files.count, 1, "one row for one path: \(read.files)")
    XCTAssertEqual(
      Set(read.files.map(\.id)).count, read.files.count, "rows must have distinct ids for ForEach")
    let row = try XCTUnwrap(read.files.first)
    XCTAssertEqual(row.path, "tool")
    XCTAssertNil(row.oldPath, "nothing moved, so there is no old path to show")
    XCTAssertEqual(
      row.kind, .modified,
      "`VCSChangeKind` has no type-change case; `.modified` is the mapping — update this if git's `T` "
        + "ever gets one of its own")
  }

  /// A shallow clone's oldest commit names a first parent this odb doesn't have. That's the end of the
  /// history we were given, not a failure: it diffs against the empty tree, exactly like a root commit.
  /// Before that degrade, `GitProvider.changeset` threw `VCSError.io` and History errored on the oldest
  /// row instead of listing its files.
  func testShallowBoundaryCommitListsItsFilesAsAdded() throws {
    let source = try repoWithFile()
    sh("echo nine >> old.txt && git commit -qam second", in: source)
    let parent = tempDir()
    // `--depth` needs the file:// transport; a plain path clone hardlinks the whole odb and ignores it.
    sh("git clone -q --depth 1 \"file://\(source)\" shallow", in: parent)
    let shallow = parent + "/shallow"
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: shallow + "/.git/shallow"), "clone must be shallow")
    let sha = head(shallow)

    // libgit2 reads `.git/shallow` as grafts when it opens the repo, so the boundary commit reports
    // zero parents here and takes the root-commit path.
    let grafted = try XCTUnwrap(
      GitCommitDiff.read(root: URL(fileURLWithPath: shallow), commitID: sha))
    XCTAssertEqual(grafted.files.map { "\($0.kind):\($0.path)" }, ["added:old.txt"])
    XCTAssertEqual(grafted.insertions, 9)

    // The same boundary WITHOUT the graft file — a partial clone, a stale `.git/shallow`, a pruned
    // odb. The commit still records its first parent, the lookup now misses with `GIT_ENOTFOUND`, and
    // the answer must be identical rather than `nil`.
    try FileManager.default.removeItem(atPath: shallow + "/.git/shallow")
    let ungrafted = try XCTUnwrap(
      GitCommitDiff.read(root: URL(fileURLWithPath: shallow), commitID: sha))
    XCTAssertEqual(ungrafted.files.map { "\($0.kind):\($0.path)" }, ["added:old.txt"])
    XCTAssertEqual(ungrafted.insertions, 9)
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

  /// The patch entry point has to fail the same way `read` does. `""` is reserved for "this commit
  /// didn't touch that path" (see below) — a commit that doesn't exist is a failed read, and the
  /// caller renders the two very differently.
  func testUnknownCommitPatchIsNil() throws {
    let root = try repoWithFile()
    XCTAssertNil(
      GitCommitDiff.patch(
        root: URL(fileURLWithPath: root),
        commitID: "0000000000000000000000000000000000000000", path: "old.txt"))
    XCTAssertNil(
      GitCommitDiff.patch(
        root: URL(fileURLWithPath: root), commitID: "not-a-sha", path: "old.txt"))
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
