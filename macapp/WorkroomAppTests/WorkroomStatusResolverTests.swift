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
private let nul = "\u{0}"

final class WorkroomStatusResolverTests: XCTestCase {

  /// An existing directory so `resolveLocal`'s fileExists guard passes (the mock ignores it).
  private let existing = NSTemporaryDirectory()

  // MARK: - parseGitPorcelainV2Z

  func testParseClean() {
    let out =
      [
        "# branch.oid abc", "# branch.head main", "# branch.upstream origin/main",
        "# branch.ab +0 -0",
      ]
      .joined(separator: nul) + nul
    let p = WorkroomStatusResolver.parseGitPorcelainV2Z(out)
    XCTAssertFalse(p.dirty)
    XCTAssertFalse(p.conflicted)
    XCTAssertEqual(p.ahead, 0)
    XCTAssertEqual(p.behind, 0)
    XCTAssertEqual(p.branch, "main")
    XCTAssertTrue(p.files.isEmpty)
  }

  func testParseDirtyModifiedAndAheadBehind() {
    let out =
      [
        "# branch.head main", "# branch.ab +2 -1",
        "1 .M N... 100644 100644 100644 aaa bbb file.swift",
      ]
      .joined(separator: nul) + nul
    let p = WorkroomStatusResolver.parseGitPorcelainV2Z(out)
    XCTAssertTrue(p.dirty)
    XCTAssertEqual(p.ahead, 2)
    XCTAssertEqual(p.behind, 1)
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

  func testParseDetachedNoAheadBehind() {
    let out = ["# branch.oid abc", "# branch.head (detached)"].joined(separator: nul) + nul
    let p = WorkroomStatusResolver.parseGitPorcelainV2Z(out)
    XCTAssertNil(p.branch)  // detached → no branch for CI
    XCTAssertNil(p.ahead)
    XCTAssertNil(p.behind)
  }

  func testParseNoUpstream() {
    let out = ["# branch.head feature"].joined(separator: nul) + nul  // no branch.ab line
    let p = WorkroomStatusResolver.parseGitPorcelainV2Z(out)
    XCTAssertEqual(p.branch, "feature")
    XCTAssertNil(p.ahead)
    XCTAssertNil(p.behind)
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

  // MARK: - classifyCI

  func testCIPassing() {
    let json = #"[{"headSha":"H","status":"completed","conclusion":"success","workflowName":"CI"}]"#
    XCTAssertEqual(WorkroomStatusResolver.classifyCI(ok(json), head: "H"), .state(.passing))
  }

  func testCIFailingDominates() {
    let json = """
      [{"headSha":"H","status":"completed","conclusion":"success","workflowName":"lint"},
       {"headSha":"H","status":"completed","conclusion":"failure","workflowName":"test"}]
      """
    XCTAssertEqual(WorkroomStatusResolver.classifyCI(ok(json), head: "H"), .state(.failing))
  }

  func testCIRunning() {
    let json = #"[{"headSha":"H","status":"in_progress","conclusion":null,"workflowName":"CI"}]"#
    XCTAssertEqual(WorkroomStatusResolver.classifyCI(ok(json), head: "H"), .state(.running))
  }

  func testCIEmptyIsAbsent() {
    XCTAssertEqual(WorkroomStatusResolver.classifyCI(ok("[]"), head: "H"), .absent)
  }

  func testCIShaMismatchIsAbsent() {
    let json =
      #"[{"headSha":"OTHER","status":"completed","conclusion":"success","workflowName":"CI"}]"#
    XCTAssertEqual(WorkroomStatusResolver.classifyCI(ok(json), head: "H"), .absent)
  }

  func testCIGhAbsent() {
    let r = CommandResult(
      stdout: "", stderr: "env: gh: No such file", exitCode: 127, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyCI(r, head: "H"), .absent)
  }

  func testCIRateLimitKeepsPrior() {
    let r = CommandResult(
      stdout: "", stderr: "API rate limit exceeded", exitCode: 1, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyCI(r, head: "H"), .keepPrior)
  }

  func testCITimeoutKeepsPrior() {
    let r = CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: true)
    XCTAssertEqual(WorkroomStatusResolver.classifyCI(r, head: "H"), .keepPrior)
  }

  func testCINeutral() {
    // A sole completed run with a non-pass/non-fail conclusion collapses to .neutral.
    let json =
      #"[{"headSha":"H","status":"completed","conclusion":"cancelled","workflowName":"CI"}]"#
    XCTAssertEqual(WorkroomStatusResolver.classifyCI(ok(json), head: "H"), .state(.neutral))
  }

  func testCIFailingConclusions() {
    // All of these map to .failing, not just "failure".
    for conclusion in ["failure", "timed_out", "startup_failure", "action_required"] {
      let json =
        "[{\"headSha\":\"H\",\"status\":\"completed\",\"conclusion\":\"\(conclusion)\",\"workflowName\":\"CI\"}]"
      XCTAssertEqual(
        WorkroomStatusResolver.classifyCI(ok(json), head: "H"), .state(.failing),
        "conclusion \(conclusion) should be failing")
    }
  }

  func testCIRunningWinsOverPassing() {
    // Across workflows, a running check outranks a passing one.
    let json = """
      [{"headSha":"H","status":"completed","conclusion":"success","workflowName":"lint"},
       {"headSha":"H","status":"in_progress","conclusion":null,"workflowName":"test"}]
      """
    XCTAssertEqual(WorkroomStatusResolver.classifyCI(ok(json), head: "H"), .state(.running))
  }

  func testCIServerErrorKeepsPrior() {
    let r = CommandResult(
      stdout: "", stderr: "HTTP 503 Service Unavailable", exitCode: 1, timedOut: false)
    XCTAssertEqual(WorkroomStatusResolver.classifyCI(r, head: "H"), .keepPrior)
  }

  func testCIMalformedIsAbsent() {
    XCTAssertEqual(WorkroomStatusResolver.classifyCI(ok("not json"), head: "H"), .absent)
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
    XCTAssertNil(s.ahead)  // jj omits ahead/behind in Phase 1
    XCTAssertNil(s.behind)
    XCTAssertEqual(s.insertions, 9)
    XCTAssertEqual(s.deletions, 3)
    // jj branch resolved from the nearest bookmark, used for CI/PR lookup.
    XCTAssertEqual(s.branchForCI, "my-feature")
    XCTAssertEqual(s.jjRefs, ["feat"])
    XCTAssertEqual(s.jjDescription, "wip: x")
    XCTAssertEqual(s.jjChangeID, "ch")
    XCTAssertEqual(s.jjCommitID, "co34")
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

  func testResolveLocalUnknownVCS() async {
    let r = WorkroomStatusResolver(runner: MockStatusRunner { _, _ in ok("anything") })
    let s = await r.resolveLocal(path: existing, vcs: "hg")
    XCTAssertNil(s.dirty)
    XCTAssertEqual(s.failure, .notRepository)
  }

  // MARK: - resolveCI (end-to-end via the mock)

  func testResolveCIPassing() async {
    let json =
      #"[{"headSha":"HEADSHA","status":"completed","conclusion":"success","workflowName":"CI"}]"#
    let r = WorkroomStatusResolver(
      runner: MockStatusRunner { exe, args in
        if exe == "git", args.contains("rev-parse") { return ok("HEADSHA\n") }
        if exe == "gh" { return ok(json) }
        return ok("")
      })
    let res = await r.resolveCI(path: existing, vcs: "git", projectRoot: existing, branch: "main")
    XCTAssertEqual(res, .state(.passing))
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

  func testClassifyPRMalformedIsAbsent() {
    XCTAssertEqual(WorkroomStatusResolver.classifyPR(ok("not json")), .absent)
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
    // jj's `commit_id` for the bookmark == the git sha gh reports for the run on that branch.
    let json =
      #"[{"headSha":"JJSHA","status":"completed","conclusion":"success","workflowName":"CI"}]"#
    let runner = RecordingStatusRunner { exe, _ in
      if exe == "jj" { return ok("JJSHA\n") }  // `jj log -r <bookmark> -T commit_id`
      if exe == "gh" { return ok(json) }
      return ok("")
    }
    let r = WorkroomStatusResolver(runner: runner)
    let res = await r.resolveCI(
      path: "/proj/ws", vcs: "jj", projectRoot: "/proj", branch: "feature/login")
    XCTAssertEqual(res, .state(.passing))
    // gh must run from the colocated project root (the workspace has no `.git`), keyed by the bookmark.
    let gh = runner.calls.first { $0.exe == "gh" }
    XCTAssertEqual(gh?.dir, "/proj")
    XCTAssertTrue(gh?.args.contains("feature/login") ?? false)
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
}
