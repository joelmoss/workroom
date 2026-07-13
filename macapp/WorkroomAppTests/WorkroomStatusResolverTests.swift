import XCTest

@testable import Workroom

/// A `StatusCommandRunning` returning canned `CommandResult`s per (executable, args), so the
/// resolver is tested without spawning real git/jj/gh (mirrors `MockRunner` in BranchResolverTests).
private struct MockStatusRunner: StatusCommandRunning {
  let handler: @Sendable (_ executable: String, _ args: [String]) -> CommandResult
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    handler(executable, args)
  }
}

/// Like `MockStatusRunner` but records every (exe, args, dir) call, so a test can assert *where* a
/// probe ran — e.g. that a jj workspace's `gh` probe runs from the colocated project root, not the
/// (gitless) workspace.
private final class RecordingStatusRunner: StatusCommandRunning, @unchecked Sendable {
  private let handler: @Sendable (_ executable: String, _ args: [String]) -> CommandResult
  private let lock = NSLock()
  private var _calls: [(exe: String, args: [String], dir: String)] = []
  var calls: [(exe: String, args: [String], dir: String)] {
    lock.lock()
    defer { lock.unlock() }
    return _calls
  }

  init(_ handler: @escaping @Sendable (_ executable: String, _ args: [String]) -> CommandResult) {
    self.handler = handler
  }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    lock.lock()
    _calls.append((executable, args, directory))
    lock.unlock()
    return handler(executable, args)
  }
}

private func ok(_ stdout: String) -> CommandResult {
  CommandResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false)
}
private func fail() -> CommandResult {
  CommandResult(stdout: "", stderr: "boom", exitCode: 1, timedOut: false)
}
private let nul = "\u{0}"

final class WorkroomStatusResolverTests: XCTestCase {

  /// An existing directory so `resolveLocal`'s fileExists guard passes (the mock ignores it).
  private let existing = NSTemporaryDirectory()

  // MARK: - parseGitPorcelainV2Z

  func testParseClean() {
    // The `branch.ab` header is now ignored (ahead/behind removed); the parser must skip it cleanly.
    let out =
      [
        "# branch.oid abc", "# branch.head main", "# branch.upstream origin/main",
        "# branch.ab +0 -0",
      ]
      .joined(separator: nul) + nul
    let p = WorkroomStatusResolver.parseGitPorcelainV2Z(out)
    XCTAssertFalse(p.dirty)
    XCTAssertFalse(p.conflicted)
    XCTAssertEqual(p.branch, "main")
    XCTAssertTrue(p.files.isEmpty)
  }

  func testParseDirtyModified() {
    let out =
      [
        "# branch.head main",
        "1 .M N... 100644 100644 100644 aaa bbb file.swift",
      ]
      .joined(separator: nul) + nul
    let p = WorkroomStatusResolver.parseGitPorcelainV2Z(out)
    XCTAssertTrue(p.dirty)
    XCTAssertEqual(p.files.count, 1)
    XCTAssertEqual(p.files.first?.path, "file.swift")
    XCTAssertEqual(p.files.first?.change, .modified)
  }

  func testParseUntracked() {
    let out = ["# branch.head main", "? new file.txt"].joined(separator: nul) + nul
    let p = WorkroomStatusResolver.parseGitPorcelainV2Z(out)
    XCTAssertTrue(p.dirty)
    XCTAssertEqual(p.files.first?.change, .untracked)
    XCTAssertEqual(p.files.first?.path, "new file.txt")  // paths with spaces survive
  }

  func testParseAddedAndDeleted() {
    // type-1 XY: "A." → added, ".D" → deleted (path is after 8 space-fields).
    let out =
      [
        "# branch.head main",
        "1 A. N... 100644 100644 100644 0 a added.txt",
        "1 .D N... 100644 100644 000000 a 0 gone.txt",
      ].joined(separator: nul) + nul
    let p = WorkroomStatusResolver.parseGitPorcelainV2Z(out)
    let byChange = Dictionary(grouping: p.files, by: \.change).mapValues { $0.map(\.path) }
    XCTAssertEqual(byChange[.added], ["added.txt"])
    XCTAssertEqual(byChange[.deleted], ["gone.txt"])
  }

  func testParseConflicted() {
    // porcelain-v2 unmerged: u <xy> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path> (path is the
    // 11th token / after 10 space-fields).
    let out =
      ["# branch.head main", "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflicted.txt"]
      .joined(separator: nul) + nul
    let p = WorkroomStatusResolver.parseGitPorcelainV2Z(out)
    XCTAssertTrue(p.dirty)
    XCTAssertTrue(p.conflicted)
    XCTAssertEqual(p.files.first?.change, .conflicted)
    XCTAssertEqual(p.files.first?.path, "conflicted.txt")
  }

  func testParseDetached() {
    let out = ["# branch.oid abc", "# branch.head (detached)"].joined(separator: nul) + nul
    let p = WorkroomStatusResolver.parseGitPorcelainV2Z(out)
    XCTAssertNil(p.branch)  // detached → no branch for CI
  }

  func testParseBranchWithoutUpstreamLine() {
    let out = ["# branch.head feature"].joined(separator: nul) + nul  // no branch.ab line
    let p = WorkroomStatusResolver.parseGitPorcelainV2Z(out)
    XCTAssertEqual(p.branch, "feature")
  }

  func testParseRenameConsumesOriginalPath() {
    let out =
      [
        "# branch.head main",
        "2 R. N... 100644 100644 100644 aaa bbb R100 new.txt",
        // "old.txt" = the rename's original-path field; must be consumed, not parsed.
        "old.txt",
        "1 .M N... 100644 100644 100644 ccc ddd after.txt",
      ].joined(separator: nul) + nul
    let p = WorkroomStatusResolver.parseGitPorcelainV2Z(out)
    XCTAssertEqual(p.files.count, 2)
    XCTAssertEqual(p.files[0].path, "new.txt")
    XCTAssertEqual(p.files[0].change, .renamed)
    XCTAssertEqual(p.files[1].path, "after.txt")  // proves "old.txt" wasn't mis-parsed as an entry
  }

  // MARK: - parseJJSummary

  func testParseJJSummary() {
    let files = WorkroomStatusResolver.parseJJSummary("M a.txt\nA b.txt\nD c.txt\n")
    XCTAssertEqual(files.map(\.change), [.modified, .added, .deleted])
    XCTAssertEqual(files.map(\.path), ["a.txt", "b.txt", "c.txt"])
  }

  func testParseJJSummaryEmpty() {
    XCTAssertTrue(WorkroomStatusResolver.parseJJSummary("").isEmpty)
  }

  // MARK: - parseJJHead
  // template (6 fields): conflict \t change-shortest \t commit-shortest8
  //                      \t bookmarks \t tags \t description
  // The change-id is its shortest unique prefix (no padding); the commit-id is the shortest-8 id.

  func testParseJJHeadFresh() {
    // fresh @: has change/commit ids but no bookmark/tag/description
    let h = WorkroomStatusResolver.parseJJHead("false\tz\tda44c86c\t\t\t\n")
    XCTAssertFalse(h.conflicted)
    XCTAssertEqual(h.changeID, "z")  // unique prefix, no padding
    XCTAssertEqual(h.commitID, "da44c86c")
    XCTAssertEqual(h.refs, [])
    XCTAssertNil(h.description)  // empty → "(no description set)" at the view
  }

  func testParseJJHeadBookmarkAndDescription() {
    let h = WorkroomStatusResolver.parseJJHead(
      "false\tpw\t7d74470b\tmybook\t\thello world (#7)\n")
    XCTAssertFalse(h.conflicted)
    XCTAssertEqual(h.changeID, "pw")
    XCTAssertEqual(h.commitID, "7d74470b")
    XCTAssertEqual(h.refs, ["mybook"])
    XCTAssertEqual(h.description, "hello world (#7)")
  }

  func testParseJJHeadConflictRefsAndMultilineDescription() {
    let h = WorkroomStatusResolver.parseJJHead(
      "true\tab\t12345678\tmain feat\tv1.0\tfix: thing\nsecond line\n")
    XCTAssertTrue(h.conflicted)
    XCTAssertEqual(h.changeID, "ab")
    XCTAssertEqual(h.refs, ["main", "feat", "v1.0"])  // bookmarks + tags
    XCTAssertEqual(h.description, "fix: thing")  // first line only
  }

  func testParseJJHeadEmpty() {
    // A best-effort jj log failure returns empty stdout — must not crash, yields a blank head.
    let h = WorkroomStatusResolver.parseJJHead("")
    XCTAssertFalse(h.conflicted)
    XCTAssertNil(h.changeID)
    XCTAssertNil(h.commitID)
    XCTAssertEqual(h.refs, [])
    XCTAssertNil(h.description)
  }

  // MARK: - parseDiffStat (git --shortstat / jj --stat totals)

  func testParseDiffStatGitFull() {
    let s = WorkroomStatusResolver.parseDiffStat(" 2 files changed, 5 insertions(+), 1 deletion(-)")
    XCTAssertEqual(s.insertions, 5)
    XCTAssertEqual(s.deletions, 1)
  }

  func testParseDiffStatInsertionsOnly() {
    let s = WorkroomStatusResolver.parseDiffStat("1 file changed, 5 insertions(+)")
    XCTAssertEqual(s.insertions, 5)
    XCTAssertEqual(s.deletions, 0)
  }

  func testParseDiffStatDeletionsOnly() {
    let s = WorkroomStatusResolver.parseDiffStat("1 file changed, 1 deletion(-)")
    XCTAssertEqual(s.insertions, 0)
    XCTAssertEqual(s.deletions, 1)
  }

  func testParseDiffStatJJSummary() {
    let s = WorkroomStatusResolver.parseDiffStat(
      "PLAN.md | 428 ++++++\n1 file changed, 428 insertions(+), 0 deletions(-)")
    XCTAssertEqual(s.insertions, 428)
    XCTAssertEqual(s.deletions, 0)
  }

  func testParseDiffStatCleanIsZero() {
    let s = WorkroomStatusResolver.parseDiffStat("")
    XCTAssertEqual(s.insertions, 0)
    XCTAssertEqual(s.deletions, 0)
  }

  // MARK: - classifyGitFailure

  func testClassifyTimeout() {
    let r = CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: true)
    XCTAssertEqual(WorkroomStatusResolver.classifyGitFailure(r), .timeout)
  }

  func testClassifyNotRepository() {
    let r = CommandResult(
      stdout: "", stderr: "fatal: not a git repository", exitCode: 128, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyGitFailure(r), .notRepository)
  }

  // MARK: - classifyCheckRollup (#76: sidebar CI from GitHub's status-check rollup)

  /// `{"data":{"repository":{"object":{"statusCheckRollup":{"state":STATE}}}}}` for a given rollup state.
  private func rollup(_ state: String) -> CommandResult {
    ok(#"{"data":{"repository":{"object":{"statusCheckRollup":{"state":"\#(state)"}}}}}"#)
  }

  func testCheckRollupPassing() {
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(rollup("SUCCESS")), .state(.passing))
  }

  func testCheckRollupFailing() {
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(rollup("FAILURE")), .state(.failing))
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(rollup("ERROR")), .state(.failing))
  }

  func testCheckRollupRunning() {
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(rollup("PENDING")), .state(.running))
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(rollup("EXPECTED")), .state(.running))
  }

  /// No checks on the commit ⇒ a null rollup (or null object) ⇒ .absent (no glyph).
  func testCheckRollupNullIsAbsent() {
    XCTAssertEqual(
      WorkroomStatusResolver.classifyCheckRollup(
        ok(#"{"data":{"repository":{"object":{"statusCheckRollup":null}}}}"#)), .absent)
    XCTAssertEqual(
      WorkroomStatusResolver.classifyCheckRollup(
        ok(#"{"data":{"repository":{"object":null}}}"#)), .absent)
  }

  /// An unknown/future StatusState renders nothing rather than a misleading glyph.
  func testCheckRollupUnknownStateIsAbsent() {
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(rollup("WAT")), .absent)
  }

  /// `gh api graphql` returns HTTP 200 (exit 0) with an `errors` payload on a GraphQL-level error —
  /// keep the last good badge rather than blank it.
  func testCheckRollupGraphQLErrorsKeepsPrior() {
    let r = ok(
      #"{"data":{"repository":null},"errors":[{"message":"Could not resolve to a Repository"}]}"#)
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(r), .keepPrior)
  }

  func testCheckRollupMalformedKeepsPrior() {
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(ok("not json")), .keepPrior)
  }

  func testCheckRollupGhMissingIsAbsent() {
    let r = CommandResult(
      stdout: "", stderr: "env: gh: No such file", exitCode: 127, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(r), .absent)
  }

  func testCheckRollupRateLimitKeepsPrior() {
    let r = CommandResult(
      stdout: "", stderr: "API rate limit exceeded", exitCode: 1, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(r), .keepPrior)
  }

  func testCheckRollupServerErrorKeepsPrior() {
    let r = CommandResult(
      stdout: "", stderr: "HTTP 503 Service Unavailable", exitCode: 1, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(r), .keepPrior)
  }

  func testCheckRollupTimeoutKeepsPrior() {
    let r = CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: true)
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(r), .keepPrior)
  }

  func testCheckRollupQueryEmbedsOwnerNameOid() {
    let q = WorkroomStatusResolver.checkRollupQuery(owner: "octo", name: "repo", oid: "abc123")
    XCTAssertTrue(q.contains(#"repository(owner:"octo",name:"repo")"#))
    XCTAssertTrue(q.contains(#"object(oid:"abc123")"#))
    XCTAssertTrue(q.contains("statusCheckRollup{state}"))
  }

  // MARK: - resolveLocal (end-to-end via the mock)

  func testResolveLocalMissingPath() async {
    let r = WorkroomStatusResolver(runner: MockStatusRunner { _, _ in ok("") })
    let s = await r.resolveLocal(path: "/definitely/not/here-\(UUID().uuidString)", vcs: "git")
    XCTAssertNil(s.dirty)  // unknown, NOT clean
    XCTAssertEqual(s.failure, .missingPath)
  }

  func testResolveLocalGitDirty() async {
    let porcelain =
      ["# branch.head main", "# branch.ab +0 -0", "1 .M N... 1 2 3 a b x.swift"]
      .joined(separator: nul) + nul
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        if exe == "git", args.contains("status") { return ok(porcelain) }
        if exe == "git", args.contains("diff") {
          return ok(" 1 file changed, 7 insertions(+), 2 deletions(-)\n")
        }
        return ok("")
      })
    let s = await r.resolveLocal(path: existing, vcs: "git")
    XCTAssertEqual(s.dirty, true)
    XCTAssertEqual(s.branchForCI, "main")
    XCTAssertEqual(s.changedFiles?.count, 1)
    XCTAssertEqual(s.insertions, 7)
    XCTAssertEqual(s.deletions, 2)
    XCTAssertNil(s.failure)
  }

  func testResolveLocalGitFailureIsUnknownNotClean() async {
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { _, _ in
        CommandResult(stdout: "", stderr: "fatal", exitCode: 128, timedOut: false)
      })
    let s = await r.resolveLocal(path: existing, vcs: "git")
    // the regression-critical assertion: unknown ≠ clean
    XCTAssertNil(s.dirty)
    XCTAssertFalse(s.isClean)
    XCTAssertTrue(s.isUnknown)
    XCTAssertEqual(s.failure, .notRepository)
  }

  func testResolveLocalJJDirtyAndConflict() async {
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        if exe == "jj", args.contains("--summary") { return ok("M a.txt\nA b.txt\n") }
        if exe == "jj", args.contains("--stat") {
          return ok("2 files changed, 9 insertions(+), 3 deletions(-)\n")
        }
        // Branch query (nearest bookmark in @'s ancestry) — distinct from the head log below.
        if exe == "jj", args.contains("heads(::@ & bookmarks())") { return ok("my-feature\n") }
        // Head template (6 fields): conflict \t change-shortest \t commit-shortest8
        //                           \t bookmarks \t tags \t description.
        if exe == "jj", args.contains("log") { return ok("true\tch\tco34\tfeat\t\twip: x\n") }
        return ok("")
      })
    let s = await r.resolveLocal(path: existing, vcs: "jj")
    XCTAssertEqual(s.dirty, true)
    XCTAssertTrue(s.conflicted)
    XCTAssertEqual(s.changedFiles?.count, 2)
    XCTAssertEqual(s.insertions, 9)
    XCTAssertEqual(s.deletions, 3)
    // jj branch resolved from the nearest bookmark, used for CI/PR lookup.
    XCTAssertEqual(s.branchForCI, "my-feature")
    // The working-copy change set drives the Working Copy disclosure group; `changedFiles` mirrors it.
    XCTAssertEqual(s.jjWorkingCopy?.refs, ["feat"])
    XCTAssertEqual(s.jjWorkingCopy?.description, "wip: x")
    XCTAssertEqual(s.jjWorkingCopy?.changeID, "ch")
    XCTAssertEqual(s.jjWorkingCopy?.commitID, "co34")
    XCTAssertEqual(s.jjWorkingCopy?.files.count, 2)
    // With this mock the @- probes resolve to a single parent change set.
    guard case .changes(let parent)? = s.jjParent else {
      return XCTFail("expected .changes parent, got \(String(describing: s.jjParent))")
    }
    XCTAssertEqual(parent.files.count, 2)
  }

  // MARK: - resolveJJParent (working copy's parent @- state)

  func testResolveJJParentMerge() async {
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        guard exe == "jj" else { return ok("") }
        if args.contains(WorkroomStatusResolver.jjParentCountTemplate) { return ok("x\nx\n") }
        if args.contains("--summary"), args.contains("@"), !args.contains("@-") {
          return ok("M a.txt\n")
        }
        return ok("")
      })
    let s = await r.resolveLocal(path: existing, vcs: "jj")
    XCTAssertEqual(s.jjParent, .merge(2))  // @- resolved to two revisions
  }

  func testResolveJJParentRoot() async {
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        guard exe == "jj" else { return ok("") }
        // 0 revisions ⇒ @ has no parent (the root).
        if args.contains(WorkroomStatusResolver.jjParentCountTemplate) { return ok("") }
        if args.contains("--summary"), args.contains("@"), !args.contains("@-") {
          return ok("M a.txt\n")
        }
        return ok("")
      })
    let s = await r.resolveLocal(path: existing, vcs: "jj")
    XCTAssertEqual(s.jjParent, .root)
  }

  func testResolveJJParentUnavailableWhenProbesFail() async {
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        guard exe == "jj" else { return ok("") }
        if args.contains(WorkroomStatusResolver.jjParentCountTemplate) { return fail() }
        if args.contains("--summary"), args.contains("@-") { return fail() }  // parent files fail
        if args.contains("--summary") { return ok("M a.txt\n") }  // working copy ok (STEP-1 guard)
        return ok("")
      })
    let s = await r.resolveLocal(path: existing, vcs: "jj")
    XCTAssertEqual(s.jjParent, .unavailable)  // can't read the parent → not faked as empty
  }

  func testResolveJJParentDegradedHeaderWhenLogFails() async {
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        guard exe == "jj" else { return ok("") }
        // exactly one parent revision.
        if args.contains(WorkroomStatusResolver.jjParentCountTemplate) { return ok("x\n") }
        if args.contains(WorkroomStatusResolver.jjHeadTemplate), args.contains("@-") {
          return fail()  // parent head/log fails → no id chips, but files still shown
        }
        if args.contains("--summary"), args.contains("@-") { return ok("M p.txt\nA q.txt\n") }
        if args.contains("--summary") { return ok("M a.txt\n") }
        if args.contains(WorkroomStatusResolver.jjHeadTemplate) {
          return ok("false\tch\tco34\t\t\twip\n")
        }
        return ok("")
      })
    let s = await r.resolveLocal(path: existing, vcs: "jj")
    guard case .changes(let parent)? = s.jjParent else {
      return XCTFail("expected degraded .changes parent, got \(String(describing: s.jjParent))")
    }
    XCTAssertEqual(parent.files.count, 2)  // summary succeeded → files present
    XCTAssertNil(parent.changeID)  // log failed → header chips dropped, not the whole group
  }

  /// The parent (`@-`) is probed, the working-copy snapshot probe (STEP 1) does NOT ignore the
  /// working copy (it must snapshot + take the lock), and the concurrent STEP-2 reads DO ignore it
  /// (so they don't contend on the lock).
  func testResolveJJProbesParentAndIgnoresWorkingCopyOnStep2() async {
    let runner = RecordingStatusRunner { _, args in
      if args.contains(WorkroomStatusResolver.jjParentCountTemplate) { return ok("x\n") }
      if args.contains("--summary") { return ok("M a.txt\n") }
      if args.contains(WorkroomStatusResolver.jjHeadTemplate) {
        return ok("false\tch\tco34\t\t\twip\n")
      }
      return ok("")
    }
    _ = await WorkroomStatusResolver(runner: runner).resolveLocal(path: existing, vcs: "jj")
    let jj = runner.calls.filter { $0.exe == "jj" }
    XCTAssertTrue(jj.contains { $0.args.contains("@-") }, "parent @- must be probed")
    let wcSummary = jj.first {
      $0.args.contains("--summary") && $0.args.contains("@") && !$0.args.contains("@-")
    }
    XCTAssertNotNil(wcSummary)
    XCTAssertFalse(
      wcSummary?.args.contains("--ignore-working-copy") ?? true,
      "STEP-1 @ summary must snapshot (no --ignore-working-copy)")
    let parentSummary = jj.first { $0.args.contains("--summary") && $0.args.contains("@-") }
    XCTAssertEqual(
      parentSummary?.args.contains("--ignore-working-copy"), true,
      "STEP-2 @- summary must reuse the snapshot (--ignore-working-copy)")
  }

  // MARK: - parseJJBranch (nearest-bookmark resolution for jj CI/PR)

  func testParseJJBranchBasic() {
    XCTAssertEqual(WorkroomStatusResolver.parseJJBranch("my-feature\n"), "my-feature")
  }

  func testParseJJBranchEmptyIsNil() {
    XCTAssertNil(WorkroomStatusResolver.parseJJBranch(""))
    XCTAssertNil(WorkroomStatusResolver.parseJJBranch("\n\n"))
  }

  func testParseJJBranchMultipleTakesFirst() {
    XCTAssertEqual(WorkroomStatusResolver.parseJJBranch("alpha beta\n"), "alpha")
  }

  func testParseJJBranchStripsDecoration() {
    // jj decorates a bookmark ahead of its remote with a trailing `*`; we strip it.
    XCTAssertEqual(WorkroomStatusResolver.parseJJBranch("feature*\n"), "feature")
  }

  func testParseJJBranchStripsConflictDecoration() {
    // jj marks a conflicted bookmark with a trailing `??`; strip it too.
    XCTAssertEqual(WorkroomStatusResolver.parseJJBranch("feature??\n"), "feature")
  }

  func testResolveLocalUnknownVCS() async {
    let r = WorkroomStatusResolver(runner: MockStatusRunner { _, _ in ok("anything") })
    let s = await r.resolveLocal(path: existing, vcs: "hg")
    XCTAssertNil(s.dirty)
    XCTAssertEqual(s.failure, .notRepository)
  }

  // MARK: - resolveCI (end-to-end via the mock)

  func testResolveCIPassing() async {
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        if exe == "git", args.contains("rev-parse") { return ok("HEADSHA\n") }
        if exe == "gh", args.contains("repo") { return ok("octo/repo\n") }
        if exe == "gh", args.contains("graphql") {
          return ok(
            #"{"data":{"repository":{"object":{"statusCheckRollup":{"state":"SUCCESS"}}}}}"#)
        }
        return ok("")
      })
    let res = await r.resolveCI(path: existing, vcs: "git", projectRoot: existing, branch: "main")
    XCTAssertEqual(res, .state(.passing))
  }

  /// `nameWithOwner` passed in (the sweep's per-project cache) ⇒ no inline `gh repo view`; the rollup
  /// query is keyed by the resolved HEAD sha.
  func testResolveCIUsesCachedNameWithOwner() async {
    let runner = RecordingStatusRunner { exe, args in
      if exe == "git", args.contains("rev-parse") { return ok("HEADSHA\n") }
      if exe == "gh", args.contains("graphql") {
        return ok(#"{"data":{"repository":{"object":{"statusCheckRollup":{"state":"FAILURE"}}}}}"#)
      }
      return ok("")
    }
    let r = WorkroomStatusResolver(runner: runner)
    let res = await r.resolveCI(
      path: existing, vcs: "git", projectRoot: existing, branch: "main", nameWithOwner: "octo/repo")
    XCTAssertEqual(res, .state(.failing))
    XCTAssertFalse(runner.calls.contains { $0.exe == "gh" && $0.args.contains("repo") })
    let gh = runner.calls.first { $0.exe == "gh" && $0.args.contains("graphql") }
    XCTAssertTrue(gh?.args.contains { $0.contains("HEADSHA") } ?? false)  // keyed by the tip sha
  }

  func testResolveCINoGitBackingIsAbsent() async {
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { _, _ in
        CommandResult(stdout: "", stderr: "not a repo", exitCode: 128, timedOut: false)
      })
    let res = await r.resolveCI(path: existing, vcs: "git", projectRoot: existing, branch: "main")
    XCTAssertEqual(res, .absent)  // no git HEAD → no CI
  }

  // MARK: - classifyPR

  func testClassifyPROpenApproved() {
    let r = ok(
      #"[{"number":42,"title":"Add login","state":"OPEN","isDraft":false,"url":"https://x/42","reviewDecision":"APPROVED"}]"#
    )
    guard case .info(let pr) = WorkroomStatusResolver.classifyPR(r) else {
      return XCTFail("expected .info")
    }
    XCTAssertEqual(pr.number, 42)
    XCTAssertEqual(pr.title, "Add login")
    XCTAssertEqual(pr.state, .open)
    XCTAssertFalse(pr.isDraft)
    XCTAssertEqual(pr.url, "https://x/42")
    XCTAssertEqual(pr.reviewDecision, .approved)
    XCTAssertTrue(pr.reviewers.isEmpty)  // back-compat: JSON without review fields → no rows
  }

  func testClassifyPRDraftEmptyReviewIsNil() {
    let r = ok(
      #"[{"number":7,"title":"WIP","state":"OPEN","isDraft":true,"url":"u","reviewDecision":""}]"#)
    guard case .info(let pr) = WorkroomStatusResolver.classifyPR(r) else { return XCTFail() }
    XCTAssertTrue(pr.isDraft)
    XCTAssertEqual(pr.state, .open)  // a draft is still OPEN
    XCTAssertNil(pr.reviewDecision)  // "" → nil
  }

  func testClassifyPRMergedAndClosed() {
    let merged = ok(
      #"[{"number":1,"title":"m","state":"MERGED","isDraft":false,"url":"u","reviewDecision":"APPROVED"}]"#
    )
    let closed = ok(
      #"[{"number":2,"title":"c","state":"CLOSED","isDraft":false,"url":"u","reviewDecision":null}]"#
    )
    guard case .info(let mpr) = WorkroomStatusResolver.classifyPR(merged),
      case .info(let cpr) = WorkroomStatusResolver.classifyPR(closed)
    else { return XCTFail() }
    XCTAssertEqual(mpr.state, .merged)
    XCTAssertEqual(cpr.state, .closed)
    XCTAssertNil(cpr.reviewDecision)  // null → nil
  }

  func testClassifyPRReviewDecisions() {
    let cr = ok(
      #"[{"number":1,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":"CHANGES_REQUESTED"}]"#
    )
    let rr = ok(
      #"[{"number":2,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":"REVIEW_REQUIRED"}]"#
    )
    guard case .info(let crpr) = WorkroomStatusResolver.classifyPR(cr),
      case .info(let rrpr) = WorkroomStatusResolver.classifyPR(rr)
    else { return XCTFail() }
    XCTAssertEqual(crpr.reviewDecision, .changesRequested)
    XCTAssertEqual(rrpr.reviewDecision, .reviewRequired)
  }

  func testClassifyPREmptyArrayIsAbsent() {
    XCTAssertEqual(WorkroomStatusResolver.classifyPR(ok("[]")), .absent)  // no PR for the branch
  }

  func testClassifyPRGhMissingIsAbsent() {
    let r = CommandResult(
      stdout: "", stderr: "env: gh: No such file", exitCode: 127, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyPR(r), .absent)
  }

  func testClassifyPRNotOkIsAbsent() {
    let r = CommandResult(
      stdout: "", stderr: "no git remote found", exitCode: 1, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyPR(r), .absent)
  }

  func testClassifyPRRateLimitKeepsPrior() {
    let r = CommandResult(
      stdout: "", stderr: "API rate limit exceeded", exitCode: 1, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyPR(r), .keepPrior)
  }

  func testClassifyPRTimeoutKeepsPrior() {
    let r = CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: true)
    XCTAssertEqual(WorkroomStatusResolver.classifyPR(r), .keepPrior)
  }

  func testClassifyPRMalformedKeepsPrior() {
    // Malformed/truncated JSON must NOT erase the PR badge (a valid empty array still → .absent).
    XCTAssertEqual(WorkroomStatusResolver.classifyPR(ok("not json")), .keepPrior)
  }

  func testClassifyPRMergeability() {
    // MERGEABLE + CLEAN → the Merge button is offered (issue #88).
    let clean = ok(
      #"[{"number":1,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":null,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}]"#
    )
    guard case .info(let cpr) = WorkroomStatusResolver.classifyPR(clean) else { return XCTFail() }
    XCTAssertEqual(cpr.mergeable, true)
    XCTAssertEqual(cpr.mergeState, .clean)
    XCTAssertTrue(cpr.canMerge)

    // CONFLICTING + DIRTY → not mergeable.
    let dirty = ok(
      #"[{"number":2,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":null,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}]"#
    )
    guard case .info(let dpr) = WorkroomStatusResolver.classifyPR(dirty) else { return XCTFail() }
    XCTAssertEqual(dpr.mergeable, false)
    XCTAssertEqual(dpr.mergeState, .dirty)
    XCTAssertFalse(dpr.canMerge)

    // UNKNOWN (GitHub still computing) → nil / .unknown, button hidden.
    let unknown = ok(
      #"[{"number":3,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":null,"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}]"#
    )
    guard case .info(let upr) = WorkroomStatusResolver.classifyPR(unknown) else { return XCTFail() }
    XCTAssertNil(upr.mergeable)
    XCTAssertEqual(upr.mergeState, .unknown)
    XCTAssertFalse(upr.canMerge)
  }

  func testClassifyPRMergeFieldsAbsentAreNil() {
    // Back-compat: JSON without the merge fields decodes cleanly with nil mergeability (button off).
    let r = ok(
      #"[{"number":1,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":null}]"#)
    guard case .info(let pr) = WorkroomStatusResolver.classifyPR(r) else { return XCTFail() }
    XCTAssertNil(pr.mergeable)
    XCTAssertNil(pr.mergeState)
    XCTAssertFalse(pr.canMerge)
  }

  func testClassifyPRUnknownMergeStateMapsToUnknown() {
    // A future/unrecognised mergeStateStatus must map to .unknown (not-yet-mergeable), never be
    // silently treated as clean.
    let r = ok(
      #"[{"number":1,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":null,"mergeable":"MERGEABLE","mergeStateStatus":"QUEUED"}]"#
    )
    guard case .info(let pr) = WorkroomStatusResolver.classifyPR(r) else { return XCTFail() }
    XCTAssertEqual(pr.mergeState, .unknown)
    XCTAssertFalse(pr.canMerge)
  }

  func testClassifyPRUnknownStateKeepsPrior() {
    // A future/unknown GitHub PR state must not render (mapping to .open would expose destructive
    // actions on a PR we don't understand) — keep the last good value instead.
    let r = ok(
      #"[{"number":3,"title":"t","state":"LOCKED","isDraft":false,"url":"u","reviewDecision":null}]"#
    )
    XCTAssertEqual(WorkroomStatusResolver.classifyPR(r), .keepPrior)
  }

  // MARK: - classifyPR reviewers (issue #52)

  func testClassifyPRParsesReviewers() {
    let r = ok(
      #"[{"number":1,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":"CHANGES_REQUESTED","latestReviews":[{"author":{"login":"iainad"},"state":"APPROVED"},{"author":{"login":"octocat"},"state":"CHANGES_REQUESTED"},{"author":{"login":"carl"},"state":"COMMENTED"},{"author":{"login":"dot"},"state":"DISMISSED"}],"reviewRequests":[{"login":"copilot-pull-request-reviewer"}]}]"#
    )
    guard case .info(let pr) = WorkroomStatusResolver.classifyPR(r) else { return XCTFail() }
    XCTAssertEqual(pr.reviewDecision, .changesRequested)
    let byID = Dictionary(uniqueKeysWithValues: pr.reviewers.map { ($0.id, $0.state) })
    XCTAssertEqual(byID["user:iainad"], .approved)
    XCTAssertEqual(byID["user:octocat"], .changesRequested)
    XCTAssertEqual(byID["user:carl"], .commented)
    XCTAssertEqual(byID["user:dot"], .dismissed)
    XCTAssertEqual(byID["user:copilot-pull-request-reviewer"], .requested)
    XCTAssertEqual(pr.reviewers.count, 5)
  }

  /// A reviewer who submitted a review and was then RE-requested shows as pending again
  /// (reviewRequests overrides the stale submitted review).
  func testClassifyPRReviewRequestsWin() {
    let r = ok(
      #"[{"number":1,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":"REVIEW_REQUIRED","latestReviews":[{"author":{"login":"octocat"},"state":"CHANGES_REQUESTED"}],"reviewRequests":[{"login":"octocat"}]}]"#
    )
    guard case .info(let pr) = WorkroomStatusResolver.classifyPR(r) else { return XCTFail() }
    XCTAssertEqual(pr.reviewers.count, 1)
    XCTAssertEqual(pr.reviewers.first?.id, "user:octocat")
    XCTAssertEqual(pr.reviewers.first?.state, .requested)
  }

  func testClassifyPRTeamReviewRequest() {
    let r = ok(
      #"[{"number":1,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":null,"latestReviews":[],"reviewRequests":[{"__typename":"Team","name":"Platform","slug":"platform"}]}]"#
    )
    guard case .info(let pr) = WorkroomStatusResolver.classifyPR(r) else { return XCTFail() }
    XCTAssertEqual(pr.reviewers.count, 1)
    XCTAssertEqual(pr.reviewers.first?.identity, .team(slug: "platform"))
    XCTAssertEqual(pr.reviewers.first?.state, .requested)
  }

  /// A future/unknown review state (e.g. PENDING) is dropped, not rendered; known ones survive.
  func testClassifyPRSkipsUnknownReviewState() {
    let r = ok(
      #"[{"number":1,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":null,"latestReviews":[{"author":{"login":"a"},"state":"PENDING"},{"author":{"login":"b"},"state":"APPROVED"}],"reviewRequests":[]}]"#
    )
    guard case .info(let pr) = WorkroomStatusResolver.classifyPR(r) else { return XCTFail() }
    XCTAssertEqual(pr.reviewers.map(\.id), ["user:b"])
  }

  /// A review with no author login, and a request with neither login nor slug, are skipped.
  func testClassifyPRSkipsReviewerWithoutIdentity() {
    let r = ok(
      #"[{"number":1,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":null,"latestReviews":[{"author":null,"state":"APPROVED"}],"reviewRequests":[{"login":null,"slug":null}]}]"#
    )
    guard case .info(let pr) = WorkroomStatusResolver.classifyPR(r) else { return XCTFail() }
    XCTAssertTrue(pr.reviewers.isEmpty)
  }

  /// REGRESSION: JSON omitting the review fields must still resolve to a PR with no reviewer rows.
  func testClassifyPRBackCompatNoReviewFields() {
    let r = ok(
      #"[{"number":9,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":"APPROVED"}]"#
    )
    guard case .info(let pr) = WorkroomStatusResolver.classifyPR(r) else { return XCTFail() }
    XCTAssertEqual(pr.reviewDecision, .approved)
    XCTAssertTrue(pr.reviewers.isEmpty)
  }

  // MARK: - parseReviewURLs (review-permalink enrichment)

  func testParseReviewURLsMapsLoginToURL() {
    let r = ok(
      #"{"data":{"resource":{"latestReviews":{"nodes":[{"author":{"login":"iainad"},"url":"https://x/9#pullrequestreview-1"},{"author":{"login":"octocat"},"url":"https://x/9#pullrequestreview-2"}]}}}}"#
    )
    let map = WorkroomStatusResolver.parseReviewURLs(r)
    XCTAssertEqual(map["iainad"], "https://x/9#pullrequestreview-1")
    XCTAssertEqual(map["octocat"], "https://x/9#pullrequestreview-2")
  }

  /// A node missing an author, a url, or with an empty login is skipped — never a `"": url` key or
  /// a `login: ""` value that would link a row to nowhere.
  func testParseReviewURLsSkipsNodesMissingFields() {
    let r = ok(
      #"{"data":{"resource":{"latestReviews":{"nodes":[{"author":null,"url":"u"},{"author":{"login":"a"},"url":null},{"author":{"login":""},"url":"u"},{"author":{"login":"ok"},"url":"good"}]}}}}"#
    )
    XCTAssertEqual(WorkroomStatusResolver.parseReviewURLs(r), ["ok": "good"])
  }

  /// Best-effort: a non-JSON body, an unresolved PR (`resource:null`), or a GraphQL `errors` payload
  /// all yield an empty map so the enrichment probe can never blank the reviewer rows.
  func testParseReviewURLsMalformedIsEmpty() {
    XCTAssertTrue(WorkroomStatusResolver.parseReviewURLs(ok("not json")).isEmpty)
    XCTAssertTrue(
      WorkroomStatusResolver.parseReviewURLs(ok(#"{"data":{"resource":null}}"#)).isEmpty)
    XCTAssertTrue(
      WorkroomStatusResolver.parseReviewURLs(ok(#"{"errors":[{"message":"rate limited"}]}"#))
        .isEmpty)
  }

  func testReviewURLQueryEmbedsPRURL() {
    let q = WorkroomStatusResolver.reviewURLQuery(prURL: "https://github.com/o/r/pull/9")
    XCTAssertTrue(q.contains(#"resource(url:"https://github.com/o/r/pull/9")"#))
    XCTAssertTrue(q.contains("latestReviews"))
  }

  // MARK: - resolvePR review-URL enrichment (end-to-end via the mock)

  /// A submitted reviewer gets its review permalink from the follow-up GraphQL probe; a pending
  /// requester (no submitted review) stays url-less.
  func testResolvePREnrichesSubmittedReviewURLs() async {
    let prJSON =
      #"[{"number":9,"title":"t","state":"OPEN","isDraft":false,"url":"https://x/9","reviewDecision":"APPROVED","latestReviews":[{"author":{"login":"iainad"},"state":"APPROVED"}],"reviewRequests":[{"login":"carl"}]}]"#
    let gqlJSON =
      #"{"data":{"resource":{"latestReviews":{"nodes":[{"author":{"login":"iainad"},"url":"https://x/9#pullrequestreview-7"}]}}}}"#
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        guard exe == "gh" else { return ok("") }
        if args.contains("graphql") { return ok(gqlJSON) }
        if args.contains("pr") { return ok(prJSON) }
        return ok("")
      })
    let res = await r.resolvePR(path: existing, vcs: "git", projectRoot: existing, branch: "main")
    guard case .info(let pr) = res else { return XCTFail("expected .info") }
    func url(_ id: String) -> String? { pr.reviewers.first { $0.id == id }?.url }
    XCTAssertEqual(url("user:iainad"), "https://x/9#pullrequestreview-7")  // submitted → linked
    XCTAssertNil(url("user:carl"))  // pending requester → nothing to open
  }

  /// No submitted review ⇒ no permalink to fetch ⇒ the extra GraphQL round-trip is skipped.
  func testResolvePRSkipsReviewURLProbeWhenAllPending() async {
    let prJSON =
      #"[{"number":9,"title":"t","state":"OPEN","isDraft":false,"url":"https://x/9","reviewDecision":"REVIEW_REQUIRED","latestReviews":[],"reviewRequests":[{"login":"copilot-pull-request-reviewer"}]}]"#
    let runner = RecordingStatusRunner { exe, args in
      (exe == "gh" && args.contains("pr")) ? ok(prJSON) : ok("")
    }
    let r = WorkroomStatusResolver(runner: runner)
    let res = await r.resolvePR(path: existing, vcs: "git", projectRoot: existing, branch: "main")
    guard case .info(let pr) = res else { return XCTFail("expected .info") }
    XCTAssertNil(pr.reviewers.first?.url)
    XCTAssertFalse(runner.calls.contains { $0.args.contains("graphql") })
  }

  /// A failing enrichment probe leaves urls `nil` but never downgrades the already-resolved PR.
  func testResolvePRReviewURLProbeFailureKeepsPR() async {
    let prJSON =
      #"[{"number":9,"title":"t","state":"OPEN","isDraft":false,"url":"https://x/9","reviewDecision":"APPROVED","latestReviews":[{"author":{"login":"iainad"},"state":"APPROVED"}],"reviewRequests":[]}]"#
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        if exe == "gh", args.contains("graphql") {
          return CommandResult(stdout: "boom", stderr: "x", exitCode: 1, timedOut: false)
        }
        if exe == "gh", args.contains("pr") { return ok(prJSON) }
        return ok("")
      })
    let res = await r.resolvePR(path: existing, vcs: "git", projectRoot: existing, branch: "main")
    guard case .info(let pr) = res else { return XCTFail("expected .info") }
    XCTAssertEqual(pr.reviewers.first?.id, "user:iainad")
    XCTAssertNil(pr.reviewers.first?.url)
  }

  // MARK: - resolvePR (end-to-end via the mock)

  func testResolvePRWithBranch() async {
    let json =
      #"[{"number":9,"title":"Feature","state":"OPEN","isDraft":false,"url":"https://x/9","reviewDecision":"APPROVED"}]"#
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        (exe == "gh" && args.contains("pr")) ? ok(json) : ok("")
      })
    let res = await r.resolvePR(path: existing, vcs: "git", projectRoot: existing, branch: "main")
    guard case .info(let pr) = res else { return XCTFail("expected .info") }
    XCTAssertEqual(pr.number, 9)
    XCTAssertEqual(pr.reviewDecision, .approved)
  }

  func testResolvePRNoBranchIsAbsent() async {
    // branch nil + git symbolic-ref fails (detached) → no branch → absent, never calls gh.
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        if exe == "git", args.contains("symbolic-ref") {
          return CommandResult(stdout: "", stderr: "", exitCode: 1, timedOut: false)
        }
        return ok("[]")
      })
    let res = await r.resolvePR(path: existing, vcs: "git", projectRoot: existing, branch: nil)
    XCTAssertEqual(res, .absent)
  }

  // MARK: - resolveCI / resolvePR for jj (gh runs from the colocated project root)

  func testResolveCIJJProbesProjectRootWithBookmarkSha() async {
    // jj's `commit_id` for the bookmark is the git sha the rollup query is keyed on.
    let runner = RecordingStatusRunner { exe, _ in
      if exe == "jj" { return ok("JJSHA\n") }  // `jj log -r <bookmark> -T commit_id`
      if exe == "gh" {
        return ok(#"{"data":{"repository":{"object":{"statusCheckRollup":{"state":"SUCCESS"}}}}}"#)
      }
      return ok("")
    }
    let r = WorkroomStatusResolver(runner: runner)
    let res = await r.resolveCI(
      path: "/proj/ws", vcs: "jj", projectRoot: "/proj", branch: "feature/login",
      nameWithOwner: "octo/repo")
    XCTAssertEqual(res, .state(.passing))
    // gh must run from the colocated project root (the workspace has no `.git`), keyed by the
    // bookmark's commit sha.
    let gh = runner.calls.first { $0.exe == "gh" }
    XCTAssertEqual(gh?.dir, "/proj")
    XCTAssertTrue(gh?.args.contains { $0.contains("JJSHA") } ?? false)
    // the commit-id probe runs in the workspace itself (jj resolves the workspace from cwd)
    let jj = runner.calls.first { $0.exe == "jj" }
    XCTAssertEqual(jj?.dir, "/proj/ws")
    XCTAssertFalse(runner.calls.contains { $0.exe == "git" })  // never shells git in the workspace
  }

  func testResolveCIJJNoBookmarkIsAbsent() async {
    // No bookmark resolved upstream (branch nil) → no branch → absent, never calls jj or gh.
    let runner = RecordingStatusRunner { _, _ in ok("") }
    let r = WorkroomStatusResolver(runner: runner)
    let res = await r.resolveCI(path: "/proj/ws", vcs: "jj", projectRoot: "/proj", branch: nil)
    XCTAssertEqual(res, .absent)
    XCTAssertTrue(runner.calls.isEmpty)  // short-circuits before any probe
  }

  func testResolvePRJJProbesProjectRoot() async {
    let json =
      #"[{"number":9,"title":"F","state":"OPEN","isDraft":false,"url":"u","reviewDecision":null}]"#
    let runner = RecordingStatusRunner { exe, _ in (exe == "gh") ? ok(json) : ok("") }
    let r = WorkroomStatusResolver(runner: runner)
    let res = await r.resolvePR(
      path: "/proj/ws", vcs: "jj", projectRoot: "/proj", branch: "feature/login")
    guard case .info(let pr) = res else { return XCTFail("expected .info") }
    XCTAssertEqual(pr.number, 9)
    let gh = runner.calls.first { $0.exe == "gh" }
    XCTAssertEqual(gh?.dir, "/proj")  // colocated project root, not the workspace
    XCTAssertTrue(gh?.args.contains("feature/login") ?? false)
  }

  func testGhProbeDirectoryJJUsesProjectRootGitUsesPath() {
    XCTAssertEqual(
      WorkroomStatusResolver.ghProbeDirectory(path: "/p/ws", vcs: "jj", projectRoot: "/p"), "/p")
    XCTAssertEqual(
      WorkroomStatusResolver.ghProbeDirectory(path: "/p/wt", vcs: "git", projectRoot: "/p"), "/p/wt"
    )
  }

  func testResolveBranchNameFallsBackToSymbolicRef() async {
    // branch=nil + git symbolic-ref returns a name → resolvePR proceeds keyed by that branch.
    let json =
      #"[{"number":1,"title":"t","state":"OPEN","isDraft":false,"url":"u","reviewDecision":null}]"#
    let runner = RecordingStatusRunner { exe, args in
      if exe == "git", args.contains("symbolic-ref") { return ok("main\n") }
      if exe == "gh" { return ok(json) }
      return ok("")
    }
    let r = WorkroomStatusResolver(runner: runner)
    let res = await r.resolvePR(path: existing, vcs: "git", projectRoot: existing, branch: nil)
    guard case .info = res else { return XCTFail("expected .info via symbolic-ref fallback") }
    XCTAssertTrue((runner.calls.first { $0.exe == "gh" })?.args.contains("main") ?? false)
  }

  func testResolveLocalJJFailureIsNotRepository() async {
    // jj diff --summary fails (not a jj repo / exit 128) → unknown, not clean.
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { _, _ in
        CommandResult(stdout: "", stderr: "Error: no jj repo here", exitCode: 1, timedOut: false)
      })
    let s = await r.resolveLocal(path: existing, vcs: "jj")
    XCTAssertNil(s.dirty)  // unknown, NOT clean
    XCTAssertEqual(s.failure, .notRepository)
  }

  func testClassifyGitFailureNonStandardExitIsNotRepository() {
    // Any non-zero exit (not just 128) ⇒ unreadable repo → unknown, never clean.
    let r = CommandResult(
      stdout: "", stderr: "fatal: detected dubious ownership", exitCode: 1, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyGitFailure(r), .notRepository)
  }

  func testGHPreflightStderrTimeoutKeepsPrior() {
    // A `gh` exit-1 whose stderr contains "timeout" (a network blip, distinct from the timedOut
    // flag) → keepPrior, so a transient failure doesn't erase the badge.
    let r = CommandResult(stdout: "", stderr: "dial tcp: i/o timeout", exitCode: 1, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyCheckRollup(r), .keepPrior)
    XCTAssertEqual(WorkroomStatusResolver.classifyPR(r), .keepPrior)
  }

  // MARK: - classifyGitHubCLI

  func testClassifyGitHubCLINotInstalled() {
    let r = CommandResult(
      stdout: "", stderr: "env: gh: No such file", exitCode: 127, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyGitHubCLI(r), .notInstalled)
  }

  func testClassifyGitHubCLINotAuthenticated() {
    let r = CommandResult(
      stdout: "", stderr: "You are not logged into any GitHub hosts.", exitCode: 1, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyGitHubCLI(r), .notAuthenticated)
  }

  func testClassifyGitHubCLIAvailable() {
    let r = ok("github.com\n  \u{2713} Logged in to github.com account joelmoss")
    XCTAssertEqual(WorkroomStatusResolver.classifyGitHubCLI(r), .available)
  }

  func testClassifyGitHubCLITimeoutIsAvailable() {
    // A network/keyring blip must not raise a false "not signed in" warning.
    let r = CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: true)
    XCTAssertEqual(WorkroomStatusResolver.classifyGitHubCLI(r), .available)
  }

  // MARK: - resolveGitHubCLI (end-to-end via the mock)

  func testResolveGitHubCLIInstalledAndAuthed() async {
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        (exe == "gh" && args.contains("auth")) ? ok("Logged in") : ok("")
      })
    let status = await r.resolveGitHubCLI()
    XCTAssertEqual(status, .available)
  }

  func testResolveGitHubCLIMissing() async {
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { _, _ in
        CommandResult(stdout: "", stderr: "env: gh: No such file", exitCode: 127, timedOut: false)
      })
    let status = await r.resolveGitHubCLI()
    XCTAssertEqual(status, .notInstalled)
  }

  /// Regression lock for issues #50 + #86. The auth probe MUST pass `--active` (scope to the active
  /// account, else a broken secondary / GitHub-App account flips the whole app to "not signed in",
  /// #50) AND `--json hosts` (exits 0 with structured per-account state, so a transient network
  /// blip during token validation isn't misreported as a logout, #86). Asserting the args directly
  /// stops a future edit from silently dropping either — the other `resolveGitHubCLI` tests match
  /// only `"auth"` and would stay green without them.
  func testResolveGitHubCLIProbesActiveAccountAsJSON() async {
    let runner = RecordingStatusRunner { _, _ in
      ok(#"{"hosts":{"github.com":[{"state":"success"}]}}"#)
    }
    let r = WorkroomStatusResolver(runner: runner)
    let status = await r.resolveGitHubCLI()
    XCTAssertEqual(status, .available)
    let authCall = runner.calls.first { $0.exe == "gh" && $0.args.contains("auth") }
    XCTAssertNotNil(authCall, "resolveGitHubCLI should invoke `gh auth status`")
    XCTAssertEqual(authCall?.args, ["auth", "status", "--active", "--json", "hosts"])
  }

  // MARK: - classifyGitHubCLIJSON (issue #86)

  /// A validated active account → available.
  func testClassifyGitHubCLIJSONSuccess() {
    let json = #"{"hosts":{"github.com":[{"state":"success","active":true,"login":"joelmoss"}]}}"#
    XCTAssertEqual(WorkroomStatusResolver.classifyGitHubCLI(ok(json)), .available)
  }

  /// The #86 bug: a network blip while validating the token surfaces as a *transport* error (no HTTP
  /// status), the shape gh emitted in the real repro. It isn't a recognized 401, so it falls through
  /// to the transient default — `.available`, not a false "not signed in".
  func testClassifyGitHubCLIJSONTransportErrorIsAvailable() {
    let json = #"""
      {"hosts":{"github.com":[{"state":"error","active":true,"login":"joelmoss","error":"Get \"https://api.github.com/\": dial tcp: lookup api.github.com: no such host"}]}}
      """#
    XCTAssertEqual(WorkroomStatusResolver.classifyGitHubCLI(ok(json)), .available)
  }

  /// Policy lock (#86): the classifier recognizes a 401 as a real logout and treats *every other*
  /// `state == "error"` — transport failures, SSO/scope 403s, an empty/missing error — as a
  /// transient blip (`.available`). This pins the deliberate "don't cry wolf on an unrecognized
  /// error" direction so a future edit can't silently flip it back to warning-on-any-error (the #86
  /// regression). The transport test above is green via this same default; these make it explicit.
  func testClassifyGitHubCLIJSONUnrecognizedErrorIsAvailable() {
    let weird =
      #"{"hosts":{"github.com":[{"state":"error","active":true,"error":"something unexpected"}]}}"#
    XCTAssertEqual(WorkroomStatusResolver.classifyGitHubCLI(ok(weird)), .available)
    let sso =
      #"{"hosts":{"github.com":[{"state":"error","active":true,"error":"HTTP 403: Resource protected by organization SAML enforcement"}]}}"#
    XCTAssertEqual(WorkroomStatusResolver.classifyGitHubCLI(ok(sso)), .available)
    let noErrorKey = #"{"hosts":{"github.com":[{"state":"error","active":true}]}}"#
    XCTAssertEqual(WorkroomStatusResolver.classifyGitHubCLI(ok(noErrorKey)), .available)
  }

  /// A genuinely rejected token (HTTP 401 / bad credentials) → really logged out, keep the warning.
  func testClassifyGitHubCLIJSONAuthFailureIsNotAuthenticated() {
    let json = #"""
      {"hosts":{"github.com":[{"state":"error","active":true,"login":"joelmoss","error":"HTTP 401: Bad credentials (https://api.github.com/)"}]}}
      """#
    XCTAssertEqual(WorkroomStatusResolver.classifyGitHubCLI(ok(json)), .notAuthenticated)
  }

  /// No accounts configured → genuinely logged out.
  func testClassifyGitHubCLIJSONNoAccountsIsNotAuthenticated() {
    XCTAssertEqual(
      WorkroomStatusResolver.classifyGitHubCLI(ok(#"{"hosts":{}}"#)), .notAuthenticated)
  }

  /// A working active account wins even when a *secondary* host's account errors (#50): the default
  /// host's PR/CI probes work, so don't flip the whole app to "not signed in".
  func testClassifyGitHubCLIJSONSuccessWinsOverSecondaryError() {
    let json = #"""
      {"hosts":{"github.com":[{"state":"success","active":true}],"ghe.example.com":[{"state":"error","active":true,"error":"HTTP 401: Bad credentials"}]}}
      """#
    XCTAssertEqual(WorkroomStatusResolver.classifyGitHubCLI(ok(json)), .available)
  }

  /// Unparseable stdout (pre-2.57 gh without `--json`, or a fatal error) falls back to the exit-code
  /// heuristic: a clean exit is available, a non-zero exit is not-authenticated.
  func testClassifyGitHubCLINonJSONFallback() {
    XCTAssertEqual(
      WorkroomStatusResolver.classifyGitHubCLI(ok("Logged in to github.com")), .available)
    let failed = CommandResult(
      stdout: "", stderr: "You are not logged into any GitHub hosts.", exitCode: 1, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyGitHubCLI(failed), .notAuthenticated)
  }

  // MARK: - classifyChecks (issue #75)

  /// All-pass: exit 0 + JSON → the full list, name/state/workflow/link mapped from `bucket`.
  func testClassifyChecksAllPass() {
    let json = #"""
      [{"name":"build","bucket":"pass","state":"SUCCESS","link":"https://x/b","workflow":"CI"},
       {"name":"lint","bucket":"pass","state":"SUCCESS","link":"https://x/l","workflow":"CI"}]
      """#
    guard case .list(let checks) = WorkroomStatusResolver.classifyChecks(ok(json)) else {
      return XCTFail("expected .list")
    }
    XCTAssertEqual(checks.count, 2)
    XCTAssertEqual(checks.first { $0.name == "build" }?.state, .passing)
    XCTAssertEqual(checks.first { $0.name == "build" }?.link, "https://x/b")
    XCTAssertEqual(checks.first { $0.name == "build" }?.workflow, "CI")
  }

  /// REGRESSION (exit-code overload): a *failed* check makes `gh pr checks` exit 1, but the JSON is
  /// still on stdout — we must parse it, not treat exit 1 as a hard failure.
  func testClassifyChecksFailingExit1ParsesJSON() {
    let json =
      #"[{"name":"test","bucket":"fail","state":"FAILURE","link":"https://x/t","workflow":"CI"}]"#
    let r = CommandResult(stdout: json, stderr: "", exitCode: 1, timedOut: false)
    guard case .list(let checks) = WorkroomStatusResolver.classifyChecks(r) else {
      return XCTFail("expected .list despite exit 1")
    }
    XCTAssertEqual(checks.first?.state, .failing)
  }

  /// REGRESSION (exit-code overload): pending checks make `gh pr checks` exit 8, with JSON on stdout.
  func testClassifyChecksPendingExit8ParsesJSON() {
    let json =
      #"[{"name":"e2e","bucket":"pending","state":"IN_PROGRESS","link":"","workflow":"CI"}]"#
    let r = CommandResult(stdout: json, stderr: "", exitCode: 8, timedOut: false)
    guard case .list(let checks) = WorkroomStatusResolver.classifyChecks(r) else {
      return XCTFail("expected .list despite exit 8")
    }
    XCTAssertEqual(checks.first?.state, .pending)
    XCTAssertNil(checks.first?.link)  // empty link string → nil (row not tappable)
  }

  /// Every `bucket` value maps to the right state; an unknown bucket falls back to `.skipped`.
  func testClassifyChecksBucketMapping() {
    let json = #"""
      [{"name":"a","bucket":"pass"},{"name":"b","bucket":"fail"},{"name":"c","bucket":"pending"},
       {"name":"d","bucket":"skipping"},{"name":"e","bucket":"cancel"},{"name":"f","bucket":"???"}]
      """#
    guard case .list(let checks) = WorkroomStatusResolver.classifyChecks(ok(json)) else {
      return XCTFail("expected .list")
    }
    let byName = Dictionary(uniqueKeysWithValues: checks.map { ($0.name, $0.state) })
    XCTAssertEqual(byName["a"], .passing)
    XCTAssertEqual(byName["b"], .failing)
    XCTAssertEqual(byName["c"], .pending)
    XCTAssertEqual(byName["d"], .skipped)
    XCTAssertEqual(byName["e"], .cancelled)
    XCTAssertEqual(byName["f"], .skipped)  // unknown bucket → quiet skipped, never dropped
  }

  /// A valid empty array ⇒ "loaded, no checks" → .absent (the store maps it to `[]`).
  func testClassifyChecksEmptyArrayIsAbsent() {
    XCTAssertEqual(WorkroomStatusResolver.classifyChecks(ok("[]")), .absent)
  }

  /// "No checks reported" on a branch: gh exits non-zero with an empty stdout + a stderr message.
  func testClassifyChecksNoChecksReportedIsAbsent() {
    let r = CommandResult(
      stdout: "", stderr: "no checks reported on the 'main' branch", exitCode: 1, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyChecks(r), .absent)
  }

  func testClassifyChecksGhMissingIsAbsent() {
    let r = CommandResult(
      stdout: "", stderr: "env: gh: No such file", exitCode: 127, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyChecks(r), .absent)
  }

  func testClassifyChecksRateLimitKeepsPrior() {
    let r = CommandResult(
      stdout: "", stderr: "API rate limit exceeded", exitCode: 1, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyChecks(r), .keepPrior)
  }

  func testClassifyChecksTimeoutKeepsPrior() {
    let r = CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: true)
    XCTAssertEqual(WorkroomStatusResolver.classifyChecks(r), .keepPrior)
  }

  /// Non-empty but unparseable stdout (truncated output / schema change) keeps the last good rows,
  /// mirroring classifyCI/classifyPR — only an EMPTY stdout falls through to .absent.
  func testClassifyChecksMalformedKeepsPrior() {
    XCTAssertEqual(WorkroomStatusResolver.classifyChecks(ok("not json")), .keepPrior)
  }

  // MARK: - resolveChecks (end-to-end via the mock)

  /// git: `gh pr checks <number>` runs in the workroom path with the right args.
  func testResolveChecksGitRunsInPath() async {
    let json = #"[{"name":"build","bucket":"pass"}]"#
    let runner = RecordingStatusRunner { exe, _ in exe == "gh" ? ok(json) : ok("") }
    let r = WorkroomStatusResolver(runner: runner)
    let res = await r.resolveChecks(path: "/proj", vcs: "git", projectRoot: "/proj", number: 9)
    XCTAssertEqual(res, .list([CICheck(name: "build", state: .passing, workflow: nil, link: nil)]))
    let gh = runner.calls.first { $0.exe == "gh" }
    XCTAssertEqual(gh?.dir, "/proj")
    XCTAssertEqual(gh?.args.prefix(3).map { $0 }, ["pr", "checks", "9"])
  }

  /// jj: `gh` must run from the colocated project root (the workspace has no `.git`).
  func testResolveChecksJJRunsInProjectRoot() async {
    let runner = RecordingStatusRunner { exe, _ in exe == "gh" ? ok("[]") : ok("") }
    let r = WorkroomStatusResolver(runner: runner)
    let res = await r.resolveChecks(path: "/proj/ws", vcs: "jj", projectRoot: "/proj", number: 3)
    XCTAssertEqual(res, .absent)  // [] → loaded, no checks
    let gh = runner.calls.first { $0.exe == "gh" }
    XCTAssertEqual(gh?.dir, "/proj")
    XCTAssertTrue(gh?.args.contains("3") ?? false)
  }
}
