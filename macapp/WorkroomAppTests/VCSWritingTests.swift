import XCTest

@testable import Workroom

/// `CLIVCSWriter`'s pure surface: argument builders, parsers, placement and failure classification.
///
/// These carry every semantic in the write layer, which is why they're `static` and tested without
/// spawning anything (the pattern `RustJJProvider.workingDiffArgs` established). Two of them pin bugs
/// this feature's review caught and verified against real tools:
/// - `parseCounts` + `gitCountsArgs` exist because `%(push:track)` is EMPTY for a branch with no
///   upstream under git's default `push.default=simple` — i.e. for every `git worktree add -b` workroom.
/// - `commonGitDir` exists because `FETCH_HEAD` is per-worktree, so fetching at the project root never
///   writes the workroom's copy.
final class VCSWritingTests: XCTestCase {

  // MARK: - Placement

  /// fetch runs at the project root for BOTH backends: jj because a secondary workspace has no `.git`,
  /// git because `FETCH_HEAD` is per-worktree and the root is the one answer every workroom shares.
  func testFetchAlwaysRunsAtTheProjectRoot() {
    for vcs in ["git", "jj"] {
      XCTAssertEqual(
        CLIVCSWriter.opDirectory(.fetch, path: "/w/room", vcs: vcs, projectRoot: "/p"), "/p",
        "\(vcs) fetch must run at the project root")
    }
  }

  /// jj bookmarks are repo-global, so its push runs at the root; a git push acts on this worktree.
  func testPushDirectoryDiffersByBackend() {
    XCTAssertEqual(
      CLIVCSWriter.opDirectory(.push, path: "/w/room", vcs: "git", projectRoot: "/p"), "/w/room")
    XCTAssertEqual(
      CLIVCSWriter.opDirectory(.push, path: "/w/room", vcs: "jj", projectRoot: "/p"), "/p")
  }

  func testPullAndAbortRunInTheWorkroom() {
    for vcs in ["git", "jj"] {
      XCTAssertEqual(
        CLIVCSWriter.opDirectory(.pull, path: "/w/room", vcs: vcs, projectRoot: "/p"), "/w/room")
      XCTAssertEqual(
        CLIVCSWriter.opDirectory(.abortRebase, path: "/w/room", vcs: vcs, projectRoot: "/p"),
        "/w/room")
    }
  }

  // MARK: - git argument builders

  func testGitArgsCarryTheHardeningFlags() {
    for args in [
      CLIVCSWriter.gitRemoteRefsArgs(),
      CLIVCSWriter.gitCountsArgs(remote: "origin", branch: "main"),
      CLIVCSWriter.gitFetchArgs(remote: "origin"),
      CLIVCSWriter.gitPushArgs(branch: "main", remote: "origin", setUpstream: false),
      CLIVCSWriter.gitPullArgs(remote: "origin", branch: "main"),
      CLIVCSWriter.gitAbortRebaseArgs(),
    ] {
      XCTAssertEqual(
        Array(args.prefix(2)), WorkroomStatusResolver.gitHardening,
        "every git invocation must be hardened: \(args)")
    }
  }

  /// The counts must come from an explicit rev-list range, never from `%(push:track)`.
  func testCountsUseRevListAgainstTheRemoteTrackingRef() {
    let args = CLIVCSWriter.gitCountsArgs(remote: "origin", branch: "feature/x")
    XCTAssertTrue(args.contains("rev-list"))
    XCTAssertTrue(args.contains("--left-right"))
    XCTAssertTrue(args.contains("--count"))
    XCTAssertTrue(args.contains("HEAD...refs/remotes/origin/feature/x"))
  }

  func testRemoteRefArgsAskOnlyForRemotesAndSkipNothing() {
    let args = CLIVCSWriter.gitRemoteRefsArgs()
    XCTAssertTrue(args.contains("refs/remotes"))
    XCTAssertFalse(
      args.contains(where: { $0.hasPrefix("--count") }),
      "no cap — with branch switching cut there is no picker to fill")
    XCTAssertTrue(args.contains(where: { $0.contains("%(symref)") }), "needed to drop origin/HEAD")
  }

  func testFetchDoesNotPruneOrSuppressFetchHead() {
    let args = CLIVCSWriter.gitFetchArgs(remote: "origin")
    XCTAssertFalse(args.contains("--prune"), "let the repo's own fetch.prune decide")
    XCTAssertFalse(
      args.contains("--no-write-fetch-head"), "FETCH_HEAD is exactly what the label reads")
  }

  func testPushSetsUpstreamOnlyWhenAskedAndNeverForces() {
    let plain = CLIVCSWriter.gitPushArgs(branch: "main", remote: "origin", setUpstream: false)
    XCTAssertFalse(plain.contains("--set-upstream"))
    let publish = CLIVCSWriter.gitPushArgs(branch: "main", remote: "origin", setUpstream: true)
    XCTAssertTrue(publish.contains("--set-upstream"))
    for args in [plain, publish] {
      XCTAssertFalse(args.contains("--force"))
      XCTAssertFalse(args.contains("--force-with-lease"))
      XCTAssertFalse(args.contains("-f"))
      XCTAssertTrue(
        args.contains("--porcelain"),
        "the rejection must be readable from the flag column, not from translated prose")
    }
  }

  /// The flag column is `!` for a rejected ref, and only for that.
  func testPushRejectionIsReadFromThePorcelainFlagColumn() {
    let rejected = """
      To ../origin.git
      !\trefs/heads/master:refs/heads/master\t[rejected] (fetch first)
      Done
      """
    XCTAssertTrue(CLIVCSWriter.gitPushRejected(stdout: rejected))

    for ok in [
      " \trefs/heads/master:refs/heads/master\t327c4e6..896d14c",  // updated
      "*\trefs/heads/feat:refs/heads/feat\t[new branch]",  // new ref
      "=\trefs/heads/feat:refs/heads/feat\t[up to date]",  // nothing to do
    ] {
      XCTAssertFalse(
        CLIVCSWriter.gitPushRejected(stdout: "To ../origin.git\n\(ok)\nDone"),
        "not a rejection: \(ok)")
    }
    XCTAssertFalse(CLIVCSWriter.gitPushRejected(stdout: ""))
    XCTAssertFalse(
      CLIVCSWriter.gitPushRejected(stdout: "! not a porcelain line"),
      "the flag is one character followed by a TAB — a bare ! is prose")
  }

  /// The point of the flag column: classification must survive a translated stderr. This is the exact
  /// pairing Homebrew git 2.55 produces under `fr_FR.UTF-8` — no English anywhere in the message.
  func testARejectedPushClassifiesWithNoEnglishInTheMessage() {
    let result = CommandResult(
      stdout: """
        To ../origin.git
        !\trefs/heads/master:refs/heads/master\t[rejected] (fetch first)
        Done
        """,
      stderr: """
        erreur : impossible de pousser des références vers '../origin.git'
        astuce : Les mises à jour ont été rejetées car le distant contient du travail que vous
        astuce : n'avez pas localement.
        """,
      exitCode: 1, timedOut: false)
    let failure = CLIVCSWriter.classify(result, action: .push, tool: "git")
    guard case .rejected = failure else {
      return XCTFail("expected .rejected, got \(String(describing: failure))")
    }
  }

  /// Workroom trees are essentially always dirty, so without `--autostash` every pull dies on
  /// "cannot pull with rebase: You have unstaged changes".
  func testPullRebasesWithAutostashAndAnExplicitRemoteBranch() {
    let args = CLIVCSWriter.gitPullArgs(remote: "origin", branch: "main")
    XCTAssertTrue(args.contains("--rebase"))
    XCTAssertTrue(args.contains("--autostash"))
    XCTAssertEqual(Array(args.suffix(2)), ["origin", "main"])
  }

  // MARK: - jj argument builders

  /// Reads must not snapshot the working copy; writes must, or uncommitted edits are lost.
  func testJJReadsIgnoreTheWorkingCopyAndWritesDoNot() {
    for args in [
      CLIVCSWriter.jjBookmarkListArgs(), CLIVCSWriter.jjOpLogArgs(),
      CLIVCSWriter.jjRevsetCountArgs("@"),
    ] {
      XCTAssertTrue(
        args.contains("--ignore-working-copy"), "read must not take the WC lock: \(args)")
    }
    for args in [
      CLIVCSWriter.jjFetchArgs(remote: "origin"),
      CLIVCSWriter.jjPushBookmarkArgs(bookmark: "main", remote: "origin"),
      CLIVCSWriter.jjPushChangeArgs(revision: "@", remote: "origin"),
      CLIVCSWriter.jjRebaseArgs(onto: "main@origin"),
    ] {
      XCTAssertFalse(
        args.contains("--ignore-working-copy"), "a write must snapshot first: \(args)")
    }
  }

  /// The template keyword is `self`; `ref.name()` errors on jj 0.43. And the tracking-count guards are
  /// load-bearing: calling `tracking_ahead_count()` on a local ref renders `<Error: …>` into the output.
  func testBookmarkTemplateUsesSelfAndGuardsTrackingCounts() {
    let template = CLIVCSWriter.jjBookmarkListArgs().last ?? ""
    XCTAssertTrue(template.contains("self.name()"))
    XCTAssertFalse(template.contains("ref.name()"))
    XCTAssertTrue(template.contains("self.tracking_present()"), "guards the count calls")
    XCTAssertTrue(
      CLIVCSWriter.jjBookmarkListArgs().contains("--all-remotes"),
      "the remote rows are where the tracking counts come from")
  }

  /// `-b @` moves the whole branch containing `@` (the pull-rebase shape). `-s @` would move only `@`
  /// and its descendants, orphaning its parents.
  func testJJRebaseMovesTheBranchNotJustTheWorkingCopy() {
    let args = CLIVCSWriter.jjRebaseArgs(onto: "main@origin")
    XCTAssertEqual(Array(args.prefix(5)), ["rebase", "-b", "@", "-d", "main@origin"])
    XCTAssertFalse(args.contains("-s"))
  }

  /// The ahead revset must be exactly what bare `jj git push` sends, so the count and the button agree.
  func testJJAheadRevsetMatchesWhatPushWouldSend() {
    XCTAssertEqual(
      CLIVCSWriter.jjAheadRevset(remote: "origin"), #"remote_bookmarks(remote="origin")..@"#)
    XCTAssertEqual(
      CLIVCSWriter.jjBehindRevset(remote: "origin"), #"@..remote_bookmarks(remote="origin")"#)
  }

  /// Interpolating a remote name bare is a parse bug. Verified against jj 0.43: `a b`, `a)b` and `a:b`
  /// fail with `Failed to parse revset`, and `a|b` silently parses as a UNION of two patterns — a wrong
  /// count with no error. Every one of them parses once quoted.
  func testRevsetRemoteNamesAreQuotedAndEscaped() {
    XCTAssertEqual(CLIVCSWriter.jjQuote("origin"), #""origin""#)
    XCTAssertEqual(CLIVCSWriter.jjQuote("a b"), #""a b""#)
    XCTAssertEqual(CLIVCSWriter.jjQuote("a|b"), #""a|b""#)
    // `\` before `"`, so the quote pass's own escapes don't get re-escaped.
    XCTAssertEqual(CLIVCSWriter.jjQuote(#"a"b"#), #""a\"b""#)
    XCTAssertEqual(CLIVCSWriter.jjQuote(#"a\b"#), #""a\\b""#)
    XCTAssertEqual(CLIVCSWriter.jjQuote(#"a\"b"#), #""a\\\"b""#)

    for name in ["a b", "a)b", "a:b", "a|b", #"a"b"#] {
      for revset in [
        CLIVCSWriter.jjAheadRevset(remote: name), CLIVCSWriter.jjBehindRevset(remote: name),
      ] {
        XCTAssertTrue(
          revset.contains("remote=\(CLIVCSWriter.jjQuote(name))"),
          "the name must reach the revset quoted: \(revset)")
      }
    }
  }

  /// jj refuses to push a commit with an empty description, and a fresh `@` after `jj new` has neither
  /// changes nor a description — the state a new workroom sits in.
  func testAnonymousPushRevisionAvoidsAnEmptyWorkingCopy() {
    XCTAssertEqual(CLIVCSWriter.jjPushRevision(hasChanges: false, hasDescription: false), "@-")
    XCTAssertEqual(CLIVCSWriter.jjPushRevision(hasChanges: true, hasDescription: false), "@")
    XCTAssertEqual(CLIVCSWriter.jjPushRevision(hasChanges: false, hasDescription: true), "@")
    XCTAssertEqual(CLIVCSWriter.jjPushRevision(hasChanges: true, hasDescription: true), "@")
  }

  func testJJPushUsesChangeForAnonymousAndBookmarkOtherwise() {
    XCTAssertTrue(
      CLIVCSWriter.jjPushChangeArgs(revision: "@-", remote: "origin").contains("--change"))
    XCTAssertTrue(
      CLIVCSWriter.jjPushBookmarkArgs(bookmark: "main", remote: "origin").contains("--bookmark"))
  }

  // MARK: - parseGitRemoteRefs

  private func nul(_ fields: String...) -> String { fields.joined(separator: "\0") }

  func testParsesRemoteNamesAndShortNames() {
    let out = [
      nul("refs/remotes/origin/main", "aaa", ""),
      nul("refs/remotes/origin/feature/x", "bbb", ""),
      nul("refs/remotes/upstream/main", "ccc", ""),
    ].joined(separator: "\n")
    let refs = CLIVCSWriter.parseGitRemoteRefs(out)
    XCTAssertEqual(refs.remotes, ["origin", "upstream"], "first-seen order")
    XCTAssertEqual(refs.shortNames, ["origin/main", "origin/feature/x", "upstream/main"])
  }

  /// `refs/remotes/origin/HEAD` is a symref whose short name is the bare remote — it would look like a
  /// branch called `origin`.
  func testDropsTheOriginHeadSymref() {
    let out = [
      nul("refs/remotes/origin/main", "aaa", ""),
      nul("refs/remotes/origin/HEAD", "aaa", "refs/remotes/origin/main"),
    ].joined(separator: "\n")
    let refs = CLIVCSWriter.parseGitRemoteRefs(out)
    XCTAssertEqual(refs.shortNames, ["origin/main"])
    XCTAssertEqual(refs.remotes, ["origin"])
  }

  func testSkipsMalformedRecordsWithoutCrashing() {
    let out = [
      nul("refs/remotes/origin/main", "aaa", ""),
      "garbage-with-no-nuls",
      nul("only", "two"),
      nul("refs/heads/local", "bbb", ""),  // not a remote ref
      nul("refs/remotes/noslash", "ccc", ""),  // no branch component
    ].joined(separator: "\n")
    let refs = CLIVCSWriter.parseGitRemoteRefs(out)
    XCTAssertEqual(refs.shortNames, ["origin/main"])
  }

  func testEmptyOutputYieldsNoRemotes() {
    XCTAssertEqual(CLIVCSWriter.parseGitRemoteRefs("").remotes, [])
  }

  // MARK: - parseCounts

  func testParsesAheadBehindCounts() {
    XCTAssertEqual(CLIVCSWriter.parseCounts("3\t1")?.ahead, 3)
    XCTAssertEqual(CLIVCSWriter.parseCounts("3\t1")?.behind, 1)
    XCTAssertEqual(CLIVCSWriter.parseCounts("0\t0\n")?.ahead, 0)
  }

  /// Garbage must be unanswerable, never a misleading zero — `nil` renders no badge, `0` claims sync.
  func testGarbageCountsAreNilNotZero() {
    XCTAssertNil(CLIVCSWriter.parseCounts(""))
    XCTAssertNil(CLIVCSWriter.parseCounts("wat"))
    XCTAssertNil(CLIVCSWriter.parseCounts("1"))
    XCTAssertNil(CLIVCSWriter.parseCounts("1\t2\t3"))
  }

  // MARK: - parseJJBookmarks (the inversion is the crown jewel)

  /// jj states its counts from the REMOTE ref's perspective: `tracking_ahead_count()` means the remote
  /// is ahead, which is git's BEHIND. If this ever stops failing on a swap, the toolbar lies about which
  /// way to sync.
  func testJJCountsAreSwappedToTheLocalPointOfView() {
    let out = [
      nul("main", "", "aaa", "1", "0", "0", "", ""),
      nul("main", "origin", "aaa", "1", "0", "1", "6010", "0"),
    ].joined(separator: "\n")
    let parsed = CLIVCSWriter.parseJJBookmarks(out)
    let tracking = parsed.bookmarks.first { $0.name == "main" }?.tracking
    XCTAssertEqual(
      tracking?.ahead, 0, "jj's tracking_BEHIND becomes our ahead")
    XCTAssertEqual(
      tracking?.behind, 6010, "jj's tracking_AHEAD (remote is ahead) becomes our behind")
  }

  /// A colocated repo exposes a pseudo-remote called `git`. It is not a remote.
  func testDropsTheGitPseudoRemote() {
    let out = [
      nul("main", "", "aaa", "1", "0", "0", "", ""),
      nul("main", "git", "aaa", "1", "0", "1", "0", "0"),
      nul("main", "origin", "aaa", "1", "0", "1", "0", "0"),
    ].joined(separator: "\n")
    let parsed = CLIVCSWriter.parseJJBookmarks(out)
    XCTAssertEqual(parsed.remotes, ["origin"], "the `git` pseudo-remote must not appear")
    XCTAssertEqual(parsed.bookmarks.first?.tracking?.comparedTo, "main@origin")
  }

  func testAbsentRemoteBookmarkIsGone() {
    let out = [
      nul("feature", "", "aaa", "1", "0", "0", "", ""),
      nul("feature", "origin", "", "0", "0", "1", "0", "6010"),
    ].joined(separator: "\n")
    let tracking = CLIVCSWriter.parseJJBookmarks(out).bookmarks.first?.tracking
    XCTAssertEqual(tracking?.gone, true)
    XCTAssertNil(tracking?.ahead, "a deleted counterpart can't answer counts")
    XCTAssertNil(tracking?.behind)
  }

  func testUntrackedRemoteBookmarkHasNoCounts() {
    let out = [
      nul("feature", "", "aaa", "1", "0", "0", "", ""),
      nul("feature", "origin", "bbb", "1", "0", "0", "", ""),
    ].joined(separator: "\n")
    let tracking = CLIVCSWriter.parseJJBookmarks(out).bookmarks.first?.tracking
    XCTAssertEqual(tracking?.comparedTo, "feature@origin")
    XCTAssertNil(tracking?.ahead, "jj cannot answer for an untracked remote bookmark")
  }

  /// Guarded in the template, but if a future jj change leaks `<Error: …>` into a count field it must
  /// degrade to "unanswerable", not crash or read as zero.
  func testErrorTextInACountFieldIsNil() {
    let out = [
      nul("main", "", "aaa", "1", "0", "0", "", ""),
      nul("main", "origin", "aaa", "1", "0", "1", "<Error: Not a tracked remote ref>", "0"),
    ].joined(separator: "\n")
    let tracking = CLIVCSWriter.parseJJBookmarks(out).bookmarks.first?.tracking
    XCTAssertNil(tracking?.behind)
  }

  func testLocalOnlyBookmarkHasNoTracking() {
    let out = nul("local-only", "", "aaa", "1", "0", "0", "", "")
    let parsed = CLIVCSWriter.parseJJBookmarks(out)
    XCTAssertEqual(parsed.bookmarks.map(\.name), ["local-only"])
    XCTAssertNil(parsed.bookmarks.first?.tracking)
    XCTAssertEqual(parsed.remotes, [])
  }

  // MARK: - parseJJFetchOp

  func testTakesTheNewestFetchOperation() {
    let out = [
      nul("1700000300", "snapshot working copy"),
      nul("1700000200", "fetch from git remote origin"),
      nul("1700000100", "fetch from git remote origin"),
    ].joined(separator: "\n")
    XCTAssertEqual(
      CLIVCSWriter.parseJJFetchOp(out), Date(timeIntervalSince1970: 1_700_000_200),
      "newest-first ordering means the FIRST match wins")
  }

  func testNoFetchOperationYieldsNil() {
    let out = [
      nul("1700000300", "snapshot working copy"), nul("1700000200", "new empty commit"),
    ].joined(separator: "\n")
    XCTAssertNil(CLIVCSWriter.parseJJFetchOp(out))
  }

  // MARK: - commonGitDir / worktreeGitDir / lastFetch

  private func tempDir() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("vcswriting-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testCommonGitDirForANormalRepoIsDotGit() {
    let repo = tempDir()
    defer { try? FileManager.default.removeItem(at: repo) }
    try? FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    XCTAssertEqual(
      CLIVCSWriter.commonGitDir(at: repo.path)?.lastPathComponent, ".git")
  }

  /// The bug this pins: a worktree's `.git` FILE points at `<common>/worktrees/<name>`, which has its
  /// own `FETCH_HEAD`. Fetching at the project root writes the COMMON one, so reading the per-worktree
  /// path would report "never fetched" forever.
  func testCommonGitDirStripsTheWorktreesSuffix() {
    let repo = tempDir()
    defer { try? FileManager.default.removeItem(at: repo) }
    let common = repo.appendingPathComponent(".git")
    let worktreeDir = common.appendingPathComponent("worktrees/room-a")
    try? FileManager.default.createDirectory(at: worktreeDir, withIntermediateDirectories: true)
    let workroom = repo.appendingPathComponent("room-a")
    try? FileManager.default.createDirectory(at: workroom, withIntermediateDirectories: true)
    try? "gitdir: \(worktreeDir.path)\n".write(
      to: workroom.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

    XCTAssertEqual(
      CLIVCSWriter.commonGitDir(at: workroom.path)?.standardized.path, common.standardized.path,
      "must resolve to the SHARED git dir, not the per-worktree one")
    XCTAssertEqual(
      CLIVCSWriter.worktreeGitDir(at: workroom.path)?.standardized.path,
      worktreeDir.standardized.path,
      "rebase state lives in the per-worktree dir, so that one must NOT be stripped")
  }

  func testCommonGitDirIsNilWhenThereIsNoGit() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    XCTAssertNil(CLIVCSWriter.commonGitDir(at: dir.path))
  }

  func testCommonGitDirIsNilForAMalformedPointer() {
    let repo = tempDir()
    defer { try? FileManager.default.removeItem(at: repo) }
    try? "not a gitdir line\n".write(
      to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    XCTAssertNil(CLIVCSWriter.commonGitDir(at: repo.path))
  }

  func testLastFetchIsNeverWhenFetchHeadIsAbsent() {
    let repo = tempDir()
    defer { try? FileManager.default.removeItem(at: repo) }
    let git = repo.appendingPathComponent(".git")
    try? FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    XCTAssertEqual(CLIVCSWriter.gitLastFetch(commonGitDir: git), .never)
  }

  func testLastFetchReadsFetchHeadMtime() {
    let repo = tempDir()
    defer { try? FileManager.default.removeItem(at: repo) }
    let git = repo.appendingPathComponent(".git")
    try? FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    try? "aaa\tbranch 'main' of origin\n".write(
      to: git.appendingPathComponent("FETCH_HEAD"), atomically: true, encoding: .utf8)
    guard case .at(let date) = CLIVCSWriter.gitLastFetch(commonGitDir: git) else {
      return XCTFail("expected .at(date)")
    }
    XCTAssertLessThan(abs(date.timeIntervalSinceNow), 30)
  }

  func testLastFetchIsUnknownWithoutAGitDir() {
    XCTAssertEqual(CLIVCSWriter.gitLastFetch(commonGitDir: nil), .unknown)
  }

  // MARK: - primaryRemote

  func testPrimaryRemotePrefersOrigin() {
    XCTAssertEqual(CLIVCSWriter.primaryRemote(["upstream", "origin"]), "origin")
    XCTAssertEqual(CLIVCSWriter.primaryRemote(["upstream", "fork"]), "upstream")
    XCTAssertNil(CLIVCSWriter.primaryRemote([]))
  }

  // MARK: - pullBranch

  func testPullBranchStripsTheRemotePrefix() {
    let tracking = VCSTracking(comparedTo: "origin/feature/x", ahead: 0, behind: 1, gone: false)
    XCTAssertEqual(
      CLIVCSWriter.pullBranch(
        current: VCSRef(name: "feature/x", kind: .branch), tracking: tracking), "feature/x")
  }

  func testPullBranchFallsBackToTheLocalName() {
    XCTAssertEqual(
      CLIVCSWriter.pullBranch(current: VCSRef(name: "main", kind: .branch), tracking: nil), "main")
  }

  // MARK: - classify

  private func failed(_ stderr: String, exit: Int32 = 1) -> CommandResult {
    CommandResult(stdout: "", stderr: stderr, exitCode: exit, timedOut: false)
  }

  func testSuccessClassifiesAsNil() {
    let ok = CommandResult(stdout: "done", stderr: "", exitCode: 0, timedOut: false)
    XCTAssertNil(CLIVCSWriter.classify(ok, action: .fetch, tool: "git"))
  }

  func testToolMissing() {
    let r = failed("", exit: CommandResult.commandNotFound)
    XCTAssertEqual(CLIVCSWriter.classify(r, action: .fetch, tool: "git"), .toolMissing("git"))
  }

  func testTimeout() {
    let r = CommandResult(stdout: "", stderr: "", exitCode: 1, timedOut: true)
    XCTAssertEqual(CLIVCSWriter.classify(r, action: .push, tool: "git"), .timedOut(.push))
  }

  func testAuthFailures() {
    for stderr in [
      "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
      "git@github.com: Permission denied (publickey).",
      "remote: Authentication failed for 'https://…'",
    ] {
      guard case .authRequired = CLIVCSWriter.classify(failed(stderr), action: .push, tool: "git")
      else { return XCTFail("expected .authRequired for: \(stderr)") }
    }
  }

  /// `BatchMode=yes` turns an interactive host-key confirmation into a hard failure, so it needs its
  /// own copy — "configure a credential helper" would be wrong advice here.
  func testHostKeyUnverifiedIsDistinctFromAuth() {
    let r = failed("Host key verification failed.\nfatal: Could not read from remote repository.")
    guard case .hostKeyUnverified = CLIVCSWriter.classify(r, action: .fetch, tool: "git") else {
      return XCTFail("expected .hostKeyUnverified")
    }
  }

  func testRejectedPush() {
    let r = failed("! [rejected]        main -> main (non-fast-forward)\nerror: failed to push")
    guard case .rejected = CLIVCSWriter.classify(r, action: .push, tool: "git") else {
      return XCTFail("expected .rejected")
    }
  }

  func testDirtyWorkingTree() {
    let r = failed(
      "error: Your local changes to the following files would be overwritten by merge:")
    guard case .dirtyWorkingTree = CLIVCSWriter.classify(r, action: .pull, tool: "git") else {
      return XCTFail("expected .dirtyWorkingTree")
    }
  }

  func testNoRemote() {
    XCTAssertEqual(
      CLIVCSWriter.classify(
        failed("fatal: 'nope' does not appear to be a git repository"),
        action: .fetch, tool: "git"), .noRemote)
    XCTAssertEqual(
      CLIVCSWriter.classify(
        failed("Error: No git remotes to fetch from"), action: .fetch, tool: "jj"),
      .noRemote)
  }

  // MARK: Lock files

  /// The path comes from git's OWN message. A repo has several lock files meaning different things
  /// (`index.lock`, `packed-refs.lock`, `HEAD.lock`, `config.lock`), so guessing which one is the problem
  /// would send someone to delete a file that isn't.
  func testParseLockPathReadsTheQuotedPath() {
    XCTAssertEqual(
      CLIVCSWriter.parseLockPath("fatal: Unable to create '/r/.git/index.lock': File exists."),
      "/r/.git/index.lock")
  }

  /// The ref-update phrasing nests TWO quoted strings and the lock path is the second — matching the
  /// first would yield `refs/heads/main`, which is not a file anyone can delete.
  func testParseLockPathTakesTheLockNotTheRefName() {
    let err = """
      error: cannot lock ref 'refs/heads/main': Unable to create \
      '/r/.git/refs/heads/main.lock': File exists
      """
    XCTAssertEqual(CLIVCSWriter.parseLockPath(err), "/r/.git/refs/heads/main.lock")
  }

  func testParseLockPathRejectsWhatItCannotUse() {
    XCTAssertNil(
      CLIVCSWriter.parseLockPath("Internal error: Failed to take lock for Git import/export"),
      "jj's lock message names no path")
    XCTAssertNil(
      CLIVCSWriter.parseLockPath("fatal: Unable to create '.git/index.lock': File exists."),
      "a relative path is meaningless in a tooltip")
    XCTAssertNil(
      CLIVCSWriter.parseLockPath("fatal: Unable to create '/r/.git/index': File exists."),
      "not a .lock — the phrasing wasn't what we assumed, so don't report a path")
    XCTAssertNil(CLIVCSWriter.parseLockPath(""))
    XCTAssertNil(
      CLIVCSWriter.parseLockPath("fatal: Unable to create '/r/.git/index.lock"),
      "an unterminated quote must not crash or return a truncated path")
  }

  /// **The distinction the whole feature turns on.** A lock file that is really there means every retry
  /// fails identically; one that has already cleared was transient contention. Only the on-disk check can
  /// tell them apart, so it is done against a real file.
  func testLockFileIsLocatedOnlyWhenItActuallyExists() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("wr-lock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let lock = dir.appendingPathComponent("index.lock")
    try Data().write(to: lock)

    let found = CLIVCSWriter.lockFile(in: "fatal: Unable to create '\(lock.path)': File exists.")
    XCTAssertEqual(found?.path, lock.path)
    XCTAssertEqual(found?.filename, "index.lock")
    XCTAssertNotNil(found?.modifiedAt, "the age is what lets a user judge whether it's abandoned")

    try FileManager.default.removeItem(at: lock)
    XCTAssertNil(
      CLIVCSWriter.lockFile(in: "fatal: Unable to create '\(lock.path)': File exists."),
      "a lock that cleared between the failure and the check WAS transient")
  }

  /// End to end: a real leftover lock must reach `classify` as a LOCATED lock, because that payload is
  /// what withholds the Retry button further up.
  func testClassifyCarriesARealLockFile() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("wr-lock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let lock = dir.appendingPathComponent("packed-refs.lock")
    try Data().write(to: lock)

    let failure = CLIVCSWriter.classify(
      failed("fatal: Unable to create '\(lock.path)': File exists."), action: .fetch, tool: "git")
    guard case .locked(let file) = failure else {
      return XCTFail("expected .locked, got \(String(describing: failure))")
    }
    XCTAssertEqual(file?.path, lock.path)
  }

  /// **The case message-parsing alone misses.** Which message git prints depends on which internal step
  /// hit the lock: a fast-forward pull names the file, but a pull that must really REBASE fails in
  /// autostash first and says only `error: could not write index` / `fatal: Cannot autostash` — no path
  /// and no "lock" anywhere. That's the diverged pull, i.e. what the Pull button is for, and it used to
  /// land in `.other` with raw stderr. Verified against real git 2.55 by `VCSRemoteIntegrationTests`.
  func testAPathlessLockFailureIsFoundOnDisk() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("wr-gitdir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appendingPathComponent("index.lock"))

    let stderr = "error: could not write index\nfatal: Cannot autostash"
    let failure = CLIVCSWriter.classify(
      failed(stderr), action: .pull, tool: "git", gitDir: dir)
    guard case .locked(let file) = failure else {
      return XCTFail("expected .locked, got \(String(describing: failure))")
    }
    XCTAssertEqual(file?.filename, "index.lock")
  }

  /// The disk probe must not invent a cause. Same symptoms, no lock file ⇒ the failure was something
  /// else and keeps its own (unhelpful, but honest) classification.
  func testAPathlessFailureWithNoLockOnDiskIsNotBlamedOnALock() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("wr-gitdir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let failure = CLIVCSWriter.classify(
      failed("error: could not write index"), action: .pull, tool: "git", gitDir: dir)
    guard case .other = failure else {
      return XCTFail("expected .other, got \(String(describing: failure))")
    }
  }

  /// Narrow on purpose: a lock file that happens to exist must not be blamed for an unrelated failure.
  func testLockSymptomOnlyMatchesLockShapedFailures() {
    XCTAssertTrue(CLIVCSWriter.lockSymptom("error: could not write index"))
    XCTAssertTrue(CLIVCSWriter.lockSymptom("fatal: Cannot autostash"))
    XCTAssertTrue(CLIVCSWriter.lockSymptom("error: cannot lock ref 'refs/heads/main'"))
    XCTAssertFalse(CLIVCSWriter.lockSymptom("fatal: couldn't find remote ref main"))
    XCTAssertFalse(CLIVCSWriter.lockSymptom("Permission denied (publickey)."))
    XCTAssertFalse(CLIVCSWriter.lockSymptom(""))
  }

  /// A workroom is a `git worktree`, so its `index.lock` and the repo's `packed-refs.lock` live in
  /// DIFFERENT directories — the worktree's own `<common>/worktrees/<name>` and the shared common dir.
  /// Checking only one would miss half the locks that can block a workroom.
  func testExistingLockFileChecksBothTheWorktreeAndCommonGitDirs() throws {
    let common = FileManager.default.temporaryDirectory
      .appendingPathComponent("wr-common-\(UUID().uuidString)", isDirectory: true)
    let worktree = common.appendingPathComponent("worktrees/room", isDirectory: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: common) }

    XCTAssertNil(CLIVCSWriter.existingLockFile(gitDir: worktree), "nothing planted yet")

    // Only in the COMMON dir — reachable only by walking up out of `worktrees/<name>`.
    try Data().write(to: common.appendingPathComponent("packed-refs.lock"))
    XCTAssertEqual(
      CLIVCSWriter.existingLockFile(gitDir: worktree)?.filename, "packed-refs.lock",
      "a workroom must see the shared repo's lock, not just its own")

    // The worktree's own lock wins when both exist: it's the one blocking THIS workroom's index.
    try Data().write(to: worktree.appendingPathComponent("index.lock"))
    XCTAssertEqual(CLIVCSWriter.existingLockFile(gitDir: worktree)?.filename, "index.lock")
  }

  func testLockedForBothBackends() {
    XCTAssertEqual(
      CLIVCSWriter.classify(
        failed("fatal: Unable to create '/r/.git/packed-refs.lock': File exists"),
        action: .fetch, tool: "git"), .locked(nil),
      "a path that isn't on disk means the lock already cleared — transient, so Retry is right")
    XCTAssertEqual(
      CLIVCSWriter.classify(
        failed("Internal error: Failed to take lock for Git import/export"),
        action: .fetch, tool: "jj"), .locked(nil),
      "jj's import/export lock message carries no path at all")
  }

  /// A failed pull that left a rebase behind must report `.rebaseInProgress`, because that state needs
  /// Abort — a Retry would fail identically.
  func testFailedPullWithARebaseParkedReportsRebaseInProgress() {
    let repo = tempDir()
    defer { try? FileManager.default.removeItem(at: repo) }
    let git = repo.appendingPathComponent(".git")
    try? FileManager.default.createDirectory(
      at: git.appendingPathComponent("rebase-merge"), withIntermediateDirectories: true)
    XCTAssertEqual(
      CLIVCSWriter.classify(
        failed("could not apply abc123"), action: .pull, tool: "git",
        gitDir: git), .rebaseInProgress)
  }

  /// A *timed-out* pull is the dangerous one — SIGKILL mid-rebase can leave the same state, and
  /// "timed out" would hide the fact that the worktree now needs an abort.
  func testTimedOutPullWithARebaseParkedAlsoReportsRebaseInProgress() {
    let repo = tempDir()
    defer { try? FileManager.default.removeItem(at: repo) }
    let git = repo.appendingPathComponent(".git")
    try? FileManager.default.createDirectory(
      at: git.appendingPathComponent("rebase-apply"), withIntermediateDirectories: true)
    let r = CommandResult(stdout: "", stderr: "", exitCode: 1, timedOut: true)
    XCTAssertEqual(
      CLIVCSWriter.classify(r, action: .pull, tool: "git", gitDir: git), .rebaseInProgress)
  }

  func testUnrecognisedFailureKeepsTheStderr() {
    guard
      case .other(let message) = CLIVCSWriter.classify(
        failed("something entirely new"), action: .fetch, tool: "git")
    else { return XCTFail("expected .other") }
    XCTAssertEqual(message, "something entirely new")
  }

  func testUnrecognisedFailureWithNoStderrNamesTheExitCode() {
    guard
      case .other(let message) = CLIVCSWriter.classify(
        failed("", exit: 3), action: .fetch, tool: "jj")
    else { return XCTFail("expected .other") }
    XCTAssertEqual(message, "jj exited 3")
  }

  // MARK: - Routing

  func testWriterRoutesByRepoKind() throws {
    let repo = tempDir()
    defer { try? FileManager.default.removeItem(at: repo) }
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let gitWriter = try VCS.writer(for: repo) as? CLIVCSWriter
    XCTAssertEqual(gitWriter?.vcs, "git")

    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".jj"), withIntermediateDirectories: true)
    let jjWriter = try VCS.writer(for: repo) as? CLIVCSWriter
    XCTAssertEqual(jjWriter?.vcs, "jj", "colocated prefers jj, matching provider(for:)")
  }

  func testWriterThrowsForAnUnsupportedPath() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    XCTAssertThrowsError(try VCS.writer(for: dir)) { error in
      guard case VCSError.unsupportedRepo = error else {
        return XCTFail("expected .unsupportedRepo, got \(error)")
      }
    }
  }
}
