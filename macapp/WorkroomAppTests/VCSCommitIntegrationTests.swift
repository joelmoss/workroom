import XCTest

@testable import Workroom

/// `CLIVCSWriter.commit` against REAL git and jj repos through the REAL `StatusCommandRunner`.
///
/// **This tier exists because the unit tests cannot see any of it.** Argument builders can only prove
/// what we *send*; every bug below was about what git and jj then *did*, and each one shipped in the
/// plan before being measured:
///
/// - a renamed row recorded an add plus an orphaned deletion (`testRenameCommitsBothSides`)
/// - a bracketed filename committed its innocent neighbour (`testGlobMagicCannotReachAnUnselectedFile`)
/// - `--only` alone could not commit a new file at all (`testUntrackedFileCommits`)
/// - committing a path DISCARDED content staged for it (`testCommitDoesNotAbsorbAnotherPathsStagedContent`)
///
/// Every repo is a throwaway under `NSTemporaryDirectory()`, removed in `tearDown`, and git is isolated
/// from the developer's own config — these never touch a real repository. The UI tier can't stand in:
/// it short-circuits the write under `UITestFixture.isActive` by design.
final class VCSCommitIntegrationTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  // MARK: helpers

  private struct MissingTool: Error { let name: String }

  private func requireTool(_ name: String) throws {
    if sh("command -v \(name)", in: NSTemporaryDirectory()).exit != 0 {
      XCTFail("`\(name)` is required for integration tests (brew install \(name))")
      throw MissingTool(name: name)
    }
  }

  private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "wr-commit-\(UUID().uuidString)"
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
    // Isolate from the developer's own git config, including any commit.gpgsign or hooksPath that
    // would otherwise make these tests depend on the machine they run on.
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_SYSTEM"] = "/dev/null"
    env["GIT_AUTHOR_NAME"] = "T"
    env["GIT_AUTHOR_EMAIL"] = "t@e.com"
    env["GIT_COMMITTER_NAME"] = "T"
    env["GIT_COMMITTER_EMAIL"] = "t@e.com"
    env["PATH"] = ShellEnvironment.path()
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
  }

  private func writer(_ vcs: String) -> CLIVCSWriter {
    CLIVCSWriter(
      vcs: vcs, runner: StatusCommandRunner(), makeProvider: { try VCS.provider(for: $0) },
      gate: JJSnapshotGate(maxChainWait: 5))
  }

  /// A git repo with one commit and the named files tracked.
  private func gitRepo(files: [String: String] = ["base.txt": "base\n"]) -> String {
    let dir = tempDir()
    sh("git init -q . && git config user.email t@e.com && git config user.name T", in: dir)
    for (name, contents) in files { write(contents, to: name, in: dir) }
    sh("git add -A && git commit -qm base", in: dir)
    return dir
  }

  private func write(_ contents: String, to name: String, in dir: String) {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? contents.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Porcelain status, trimming ONLY newlines.
  ///
  /// Trimming whitespace here would be a silent bug in the tests themselves: porcelain's two-column
  /// `XY` prefix puts the index status in column 1 and the worktree status in column 2, so `M ` means
  /// staged and ` M` means worktree-only — and several of these tests exist precisely to tell those
  /// apart. `.whitespacesAndNewlines` collapses them into the same string.
  private func status(_ dir: String) -> String {
    sh("git status --porcelain", in: dir).out.trimmingCharacters(in: .newlines)
  }

  /// The files touched by HEAD, one per line, so an assertion can name exactly what landed.
  ///
  /// `--name-only` collapses a detected rename to the NEW path alone; use `nameStatus` when the
  /// rename itself is the thing under test.
  private func committedFiles(_ dir: String) -> [String] {
    sh("git show --name-only --format= HEAD", in: dir).out
      .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }.sorted()
  }

  /// `R100\told.txt\tnew.txt`-style records, for asserting on the change KIND rather than the names.
  private func nameStatus(_ dir: String) -> String {
    sh("git show --name-status --format= HEAD", in: dir).out
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func modified(_ path: String) -> ChangedFile {
    ChangedFile(path: path, change: .modified, oldPath: nil)
  }

  // MARK: - The measured bugs

  /// A rename is one row and two paths. Sending only the new one records an **add** and leaves the
  /// deletion behind in the worktree — the user ticked `old → new` and got half a rename.
  func testRenameCommitsBothSides() async throws {
    try requireTool("git")
    let dir = gitRepo(files: ["base.txt": "base\n", "old.txt": "content\n"])
    sh("git mv old.txt new.txt", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(
        message: "move it",
        files: [ChangedFile(path: "new.txt", change: .renamed, oldPath: "old.txt")],
        mode: .commit))

    guard case .ok = result else { return XCTFail("commit failed: \(result)") }
    // Asserted as a RENAME record, not as two filenames: git's rename detection collapses
    // `--name-only` to the new path alone, so a passing "both names appear" check is impossible here
    // and its absence proves nothing. `R` is the fact that matters.
    let record = nameStatus(dir)
    XCTAssertTrue(record.hasPrefix("R"), "recorded as a rename, not an add: \(record)")
    XCTAssertTrue(record.contains("old.txt") && record.contains("new.txt"), record)
    XCTAssertEqual(status(dir), "", "no dangling deletion left behind in the worktree")
  }

  /// **The rename that actually happens.** `git mv` (above) stages the rename, so git already knows
  /// the new path — which is why that test passed while every real rename failed. A plain `mv` is what
  /// editors, IDEs and coding agents all do: libgit2 status pairs it into ONE `.renamed` row whose new
  /// side git has never seen, and `--only` then refused the entire selection with `pathspec … did not
  /// match any file(s) known to git`, committing nothing at all.
  ///
  /// The unrelated `other.txt` is the point of the assertion: the failure was never scoped to the
  /// rename row, it took down every file ticked alongside it.
  func testAPlainMoveRenameCommitsInsteadOfFailingTheWholeSelection() async throws {
    try requireTool("git")
    let dir = gitRepo(files: [
      "base.txt": "base\n", "old.txt": "content\n", "other.txt": "other\n",
    ])
    sh("mv old.txt new.txt", in: dir)
    write("other changed\n", to: "other.txt", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(
        message: "move it",
        files: [
          ChangedFile(path: "new.txt", change: .renamed, oldPath: "old.txt"),
          modified("other.txt"),
        ],
        mode: .commit))

    guard case .ok = result else { return XCTFail("commit failed: \(result)") }
    let record = nameStatus(dir)
    XCTAssertTrue(record.contains("new.txt"), "the renamed file must be in the commit: \(record)")
    XCTAssertTrue(
      record.contains("other.txt"),
      "and so must the file ticked beside it — the old failure was not scoped to the rename")
    XCTAssertEqual(status(dir), "", "nothing left behind: no dangling deletion, no stray untracked")
  }

  /// A failed commit must not leave the index holding intent-to-add entries the user never made.
  /// Measured: they break the user's own `git stash` with `Entry 'x' not uptodate. Cannot merge.`
  /// until they find and reverse a change that was never theirs.
  func testAFailedCommitLeavesNoIntentToAddResidue() async throws {
    try requireTool("git")
    let dir = gitRepo(files: ["base.txt": "base\n"])
    write("fresh\n", to: "untracked.txt", in: dir)
    // A `commit-msg` hook that always rejects: the commonest way a commit fails after the
    // intent-to-add step has already run.
    let hook = "\(dir)/.git/hooks/commit-msg"
    write("#!/bin/sh\nexit 1\n", to: ".git/hooks/commit-msg", in: dir)
    sh("chmod +x \(hook)", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(
        message: "will be rejected",
        files: [ChangedFile(path: "untracked.txt", change: .untracked)], mode: .commit))

    guard case .failed = result else { return XCTFail("the hook should have rejected: \(result)") }
    XCTAssertEqual(
      status(dir), "?? untracked.txt",
      "the file must be untracked again, exactly as the user left it — not staged as ' A'")
    let stash = sh("git stash 2>&1", in: dir)
    XCTAssertFalse(
      stash.out.contains("not uptodate"),
      "a failed commit must not break the user's own stash: \(stash.out)")
  }

  /// `--` ends option parsing, not magic parsing. Bare, `a[b].txt` is a glob that also matches
  /// `ab.txt`; `:(literal)` is what stops it. This is the selection model's whole promise.
  func testGlobMagicCannotReachAnUnselectedFile() async throws {
    try requireTool("git")
    let dir = gitRepo(files: ["ab.txt": "neighbour\n", "a[b].txt": "selected\n"])
    write("neighbour changed\n", to: "ab.txt", in: dir)
    write("selected changed\n", to: "a[b].txt", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(message: "bracket", files: [modified("a[b].txt")], mode: .commit))

    guard case .ok = result else { return XCTFail("commit failed: \(result)") }
    XCTAssertEqual(committedFiles(dir), ["a[b].txt"], "the neighbour must NOT be swept in")
    XCTAssertEqual(status(dir), " M ab.txt", "ab.txt is still uncommitted, as the user chose")
  }

  /// `git commit --only` refuses a path git has never seen, so the intent-to-add step is mandatory
  /// rather than an alternative. This is the single most common commit there is.
  func testUntrackedFileCommits() async throws {
    try requireTool("git")
    let dir = gitRepo()
    write("brand new\n", to: "fresh.txt", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(
        message: "add fresh",
        files: [ChangedFile(path: "fresh.txt", change: .untracked, oldPath: nil)], mode: .commit))

    guard case .ok = result else { return XCTFail("commit failed: \(result)") }
    XCTAssertEqual(committedFiles(dir), ["fresh.txt"])
    XCTAssertEqual(status(dir), "")
  }

  /// The reason `--only` was chosen over `git add` + `git commit`: a file the user staged in the
  /// terminal must survive a commit of a DIFFERENT file, still staged, untouched.
  func testCommitDoesNotAbsorbAnotherPathsStagedContent() async throws {
    try requireTool("git")
    let dir = gitRepo(files: ["base.txt": "base\n", "other.txt": "other\n"])
    write("other staged\n", to: "other.txt", in: dir)
    sh("git add other.txt", in: dir)
    write("base changed\n", to: "base.txt", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(message: "only base", files: [modified("base.txt")], mode: .commit))

    guard case .ok = result else { return XCTFail("commit failed: \(result)") }
    XCTAssertEqual(committedFiles(dir), ["base.txt"], "the staged file must not ride along")
    XCTAssertEqual(
      status(dir), "M  other.txt", "and it is STILL STAGED, exactly as the user left it")
  }

  /// A deleted file stages and commits through the same path entry — no `-A` hedge needed.
  func testDeletionCommits() async throws {
    try requireTool("git")
    let dir = gitRepo(files: ["base.txt": "base\n", "gone.txt": "bye\n"])
    try? FileManager.default.removeItem(atPath: dir + "/gone.txt")

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(
        message: "remove it",
        files: [ChangedFile(path: "gone.txt", change: .deleted, oldPath: nil)], mode: .commit))

    guard case .ok = result else { return XCTFail("commit failed: \(result)") }
    XCTAssertEqual(committedFiles(dir), ["gone.txt"])
    XCTAssertEqual(status(dir), "")
  }

  /// A filename with a space is ordinary, not an edge case, and NUL separation is what makes it work
  /// without any escaping.
  func testPathWithSpacesAndUnicodeCommits() async throws {
    try requireTool("git")
    let dir = gitRepo()
    write("x\n", to: "My Notes café.md", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(
        message: "notes",
        files: [ChangedFile(path: "My Notes café.md", change: .untracked, oldPath: nil)],
        mode: .commit))

    guard case .ok = result else { return XCTFail("commit failed: \(result)") }
    XCTAssertEqual(status(dir), "", "the file committed and nothing is left dirty")
  }

  // MARK: - The staged-content guard

  /// End-to-end proof of the loss the guard exists to warn about, and that the guard sees it.
  ///
  /// `git add -p` leaves a file whose index copy is a real intermediate state. `--only` builds the
  /// commit from the WORKTREE, so that intermediate is bypassed and then unrecoverable — `git status`
  /// is clean afterwards and nothing records that it existed.
  func testGuardDetectsAPartlyStagedFile() async throws {
    try requireTool("git")
    let dir = gitRepo(files: ["f.txt": "l1\nl2\nl3\n", "g.txt": "other\n"])
    // The `git add -p` shape: stage an intermediate, then keep editing.
    write("l1\nSTAGED\nl3\n", to: "f.txt", in: dir)
    sh("git add f.txt", in: dir)
    write("l1\nSTAGED\nl3\nWORKTREE\n", to: "f.txt", in: dir)
    // A worktree-only change, which is NOT at risk — nothing was staged for it.
    write("other changed\n", to: "g.txt", in: dir)

    let atRisk = await writer("git").stagedContentAtRisk(
      path: dir, files: [modified("f.txt"), modified("g.txt")])
    XCTAssertEqual(atRisk, ["f.txt"], "only the partly-staged file is at risk")
  }

  /// And the loss itself, so the warning's claim is not merely asserted in a comment.
  func testCommittingAPartlyStagedFileTakesTheWorktreeCopy() async throws {
    try requireTool("git")
    let dir = gitRepo(files: ["f.txt": "l1\nl2\nl3\n"])
    write("l1\nSTAGED\nl3\n", to: "f.txt", in: dir)
    sh("git add f.txt", in: dir)
    write("l1\nSTAGED\nl3\nWORKTREE\n", to: "f.txt", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(message: "partial", files: [modified("f.txt")], mode: .commit))

    guard case .ok = result else { return XCTFail("commit failed: \(result)") }
    let recorded = sh("git show HEAD:f.txt", in: dir).out
    XCTAssertTrue(
      recorded.contains("WORKTREE"),
      "the worktree copy is what lands — which is exactly why the guard warns first")
    XCTAssertEqual(status(dir), "", "and the staged intermediate is gone without a trace")
  }

  /// A fully-staged file whose worktree copy matches has nothing to lose, so it must not warn — a
  /// guard that cries wolf on the ordinary `git add .` workflow would be trained away immediately.
  func testGuardIgnoresAFullyStagedFile() async throws {
    try requireTool("git")
    let dir = gitRepo(files: ["f.txt": "one\n"])
    write("two\n", to: "f.txt", in: dir)
    sh("git add f.txt", in: dir)

    let atRisk = await writer("git").stagedContentAtRisk(path: dir, files: [modified("f.txt")])
    XCTAssertTrue(atRisk.isEmpty, "staged and identical to disk — nothing is discarded")
  }

  // MARK: - Message, amend, and the empty case

  /// The summary and body arrive as one `-m` argument with an embedded blank line.
  func testMultiLineMessageRoundTrips() async throws {
    try requireTool("git")
    let dir = gitRepo()
    write("changed\n", to: "base.txt", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(
        message: "Summary line\n\nBody paragraph explaining why.", files: [modified("base.txt")],
        mode: .commit))

    guard case .ok = result else { return XCTFail("commit failed: \(result)") }
    let recorded = sh("git log -1 --format=%B", in: dir).out
    XCTAssertTrue(recorded.hasPrefix("Summary line\n\nBody paragraph explaining why."))
  }

  /// Amend rewords and takes nothing else — the staged file stays staged.
  ///
  /// The second commit is not incidental: amending the ROOT commit would legitimately report every
  /// file in the repo as "touched", which looks exactly like absorption and isn't. Measured both
  /// ways before settling on this shape.
  func testAmendMessageLeavesTheIndexAlone() async throws {
    try requireTool("git")
    let dir = gitRepo(files: ["base.txt": "base\n", "other.txt": "other\n"])
    write("second\n", to: "second.txt", in: dir)
    sh("git add second.txt && git commit -qm 'second commit'", in: dir)
    write("staged\n", to: "other.txt", in: dir)
    sh("git add other.txt", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(message: "reworded", files: [], mode: .amendMessage))

    guard case .ok = result else { return XCTFail("amend failed: \(result)") }
    XCTAssertEqual(
      sh("git log -1 --format=%s", in: dir).out.trimmingCharacters(in: .whitespacesAndNewlines),
      "reworded")
    XCTAssertEqual(committedFiles(dir), ["second.txt"], "other.txt was NOT absorbed")
    XCTAssertEqual(status(dir), "M  other.txt", "and it is still staged")
  }

  func testNothingToCommitIsTyped() async throws {
    try requireTool("git")
    let dir = gitRepo()
    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(message: "nothing", files: [modified("base.txt")], mode: .commit))
    XCTAssertEqual(result, .failed(.nothingToCommit))
  }

  /// A repo with no commits at all is a legitimate state to commit from.
  func testUnbornHeadCommits() async throws {
    try requireTool("git")
    let dir = tempDir()
    sh("git init -q . && git config user.email t@e.com && git config user.name T", in: dir)
    write("first\n", to: "first.txt", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(
        message: "first commit",
        files: [ChangedFile(path: "first.txt", change: .untracked, oldPath: nil)], mode: .commit))

    guard case .ok = result else { return XCTFail("commit failed: \(result)") }
    XCTAssertEqual(committedFiles(dir), ["first.txt"])
  }

  // MARK: - Hooks and parked operations

  /// The hook's own output is the most valuable text in the whole taxonomy, so it must survive
  /// classification rather than being flattened to "failed".
  func testRejectingHookIsClassifiedAndKeepsItsOutput() async throws {
    try requireTool("git")
    let dir = gitRepo()
    let hook = dir + "/.git/hooks/pre-commit"
    write(
      "#!/bin/sh\necho 'lint: 2 problems found' >&2\nexit 1\n", to: ".git/hooks/pre-commit", in: dir
    )
    sh("chmod +x '\(hook)'", in: dir)
    write("changed\n", to: "base.txt", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(message: "blocked", files: [modified("base.txt")], mode: .commit))

    guard case .failed(let failure) = result else { return XCTFail("expected failure: \(result)") }
    // git's own wording varies by version, so accept either the matched hook case or `.other` —
    // what must NOT happen is losing the hook's output, which is the thing the user needs.
    let detail = CLIVCSWriter.commitFailureDetail(failure)
    XCTAssertTrue(detail.contains("lint: 2 problems found"), "hook output survived: \(detail)")
    XCTAssertEqual(status(dir), " M base.txt", "nothing was committed and the index is untouched")
  }

  /// Resolving the conflicts clears the markers but leaves `MERGE_HEAD`, and a path-limited commit is
  /// still invalid — the guard has to read the sequencer file, not the conflict.
  func testCommitIsRefusedWhileAMergeIsParked() async throws {
    try requireTool("git")
    let dir = gitRepo()
    FileManager.default.createFile(atPath: dir + "/.git/MERGE_HEAD", contents: Data("abc\n".utf8))
    write("changed\n", to: "base.txt", in: dir)

    let result = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(message: "mid-merge", files: [modified("base.txt")], mode: .commit))

    XCTAssertEqual(result, .failed(.sequencerInProgress("merge")))
    XCTAssertEqual(status(dir), " M base.txt", "nothing was spawned, nothing changed")
  }

  // MARK: - jj

  private func jjRepo() -> String {
    let dir = tempDir()
    sh("jj git init . >/dev/null 2>&1", in: dir)
    sh("jj config set --repo user.name T >/dev/null 2>&1", in: dir)
    sh("jj config set --repo user.email t@e.com >/dev/null 2>&1", in: dir)
    return dir
  }

  /// `jj commit` describes `@` and starts a new empty change on top, so afterwards the working copy
  /// is clean and the message is on the parent.
  func testJJCommitDescribesAndStartsANewChange() async throws {
    try requireTool("jj")
    let dir = jjRepo()
    write("hello\n", to: "a.txt", in: dir)

    let result = await writer("jj").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(message: "jj summary", files: [], mode: .commit))

    guard case .ok = result else { return XCTFail("jj commit failed: \(result)") }
    let parent = sh(
      "jj log --ignore-working-copy --no-graph -r @- -T 'description.first_line()'", in: dir
    ).out
    XCTAssertTrue(parent.contains("jj summary"), "the message landed on the parent, got: \(parent)")
  }

  /// Describe sets the message and STAYS on the change — the distinction the menu item's help text
  /// has to teach, so it had better be true.
  func testJJDescribeStaysOnTheSameChange() async throws {
    try requireTool("jj")
    let dir = jjRepo()
    write("hello\n", to: "a.txt", in: dir)
    let before = sh("jj log --ignore-working-copy --no-graph -r @ -T 'change_id'", in: dir).out

    let result = await writer("jj").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(message: "described", files: [], mode: .describe))

    guard case .ok = result else { return XCTFail("jj describe failed: \(result)") }
    let after = sh("jj log --ignore-working-copy --no-graph -r @ -T 'change_id'", in: dir).out
    XCTAssertEqual(before, after, "@ is the same change")
    let message = sh(
      "jj log --ignore-working-copy --no-graph -r @ -T 'description.first_line()'", in: dir
    ).out
    XCTAssertTrue(message.contains("described"))
  }

  /// A multi-line jj description round-trips whole, which is what the prefill read depends on —
  /// `JJCommitChanges.description` is only the first line, so prefilling from that and describing
  /// again would silently discard the body.
  func testJJDescriptionReadReturnsTheWholeBody() async throws {
    try requireTool("jj")
    let dir = jjRepo()
    write("hello\n", to: "a.txt", in: dir)
    _ = await writer("jj").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(message: "Summary\n\nBody line one.", files: [], mode: .describe))

    let full = sh(
      "jj log --ignore-working-copy --no-graph -r @ -T description", in: dir
    ).out
    XCTAssertTrue(full.contains("Summary"))
    XCTAssertTrue(full.contains("Body line one."), "the body survived, got: \(full)")
  }

  /// The verbs are backend-scoped and a mismatch is reported, never silently run as the nearest
  /// available command.
  func testUnsupportedModeIsRejectedPerBackend() async throws {
    try requireTool("git")
    let dir = gitRepo()
    let describeOnGit = await writer("git").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(message: "m", files: [], mode: .describe))
    XCTAssertEqual(describeOnGit, .failed(.unsupportedMode))

    let amendOnJJ = await writer("jj").commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(message: "m", files: [], mode: .amendMessage))
    XCTAssertEqual(amendOnJJ, .failed(.unsupportedMode))
  }
}
