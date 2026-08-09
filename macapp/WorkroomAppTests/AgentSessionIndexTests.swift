import XCTest

@testable import Workroom

/// Finding a resumable agent conversation for a restored pane (issue #145).
///
/// Every test seeds a throwaway `$HOME`. Nothing here reads the developer's real `~/.claude` or
/// `~/.codex` — which is also what `AgentSessionIndex.forCurrentEnvironment` enforces at runtime, so
/// a unit test cannot pass or fail based on which directories someone talked to an agent in today.
final class AgentSessionIndexTests: XCTestCase {
  private var home: URL!
  private let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

  override func setUpWithError() throws {
    try super.setUpWithError()
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("agent-index-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
    try super.tearDownWithError()
  }

  private func makeIndex(
    limits: AgentSessionIndex.Limits = .standard, now: @escaping () -> Date = { Date() }
  )
    -> AgentSessionIndex
  {
    AgentSessionIndex(roots: AgentSessionIndex.Roots(home: home), limits: limits, now: now)
  }

  private func write(_ lines: [String], to url: URL, modified: Date) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
  }

  /// A Claude transcript: line 1 is the `{leafUuid, sessionId, type}` summary that carries NO cwd,
  /// exactly as the real store writes it.
  @discardableResult
  private func seedClaude(
    directory: String, cwd: String, modified: Date? = nil, file: String = "session.jsonl"
  ) throws -> URL {
    let url = home.appendingPathComponent(".claude/projects/\(directory)/\(file)")
    try write(
      [
        #"{"leafUuid":"abc","sessionId":"s1","type":"summary"}"#,
        #"{"type":"user","cwd":"\#(cwd)","message":{"role":"user"}}"#,
      ], to: url, modified: modified ?? savedAt)
    return url
  }

  @discardableResult
  private func seedCodex(
    day: String, cwd: String, modified: Date? = nil, file: String = "rollout-a.jsonl"
  )
    throws -> URL
  {
    let url = home.appendingPathComponent(".codex/sessions/\(day)/\(file)")
    try write(
      [#"{"type":"session_meta","timestamp":"t","payload":{"cwd":"\#(cwd)","id":"x"}}"#],
      to: url, modified: modified ?? savedAt)
    return url
  }

  /// `savedAt`'s own day, in the local calendar — the tree Codex writes into.
  private var savedAtDay: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd"
    return formatter.string(from: savedAt)
  }

  // MARK: Claude

  func testFindsAClaudeConversationForTheExactDirectory() throws {
    let cwd = "/tmp/project"
    try seedClaude(directory: AgentSessionIndex.claudeSlugHint(for: cwd), cwd: cwd)

    let found = makeIndex().backends(forCwds: [cwd], savedAt: savedAt)
    XCTAssertEqual(found[cwd], [.claude])
  }

  /// **REGRESSION.** The slug is a hint, and the hint is allowed to be wrong.
  ///
  /// Claude's scheme is Claude's: it replaces `.` as well as `/`, and other character classes are
  /// undocumented. Keying identity on a reconstructed slug meant any directory we transformed
  /// differently silently showed no button, indistinguishable from "no history here". This seeds a
  /// directory the hint does NOT produce and asserts the conversation is found anyway — by the `cwd`
  /// the file itself records.
  func testFindsAConversationEvenWhenTheSlugHintIsWrong() throws {
    let cwd = "/tmp/a_b/project"
    let stored = "-tmp-a-b-project"  // what a slug rule we don't implement would have produced
    XCTAssertNotEqual(
      AgentSessionIndex.claudeSlugHint(for: cwd), stored, "the hint must genuinely miss here")
    try seedClaude(directory: stored, cwd: cwd)

    XCTAssertEqual(makeIndex().backends(forCwds: [cwd], savedAt: savedAt)[cwd], [.claude])
  }

  /// The documented `/a-b/c` vs `/a/b/c` collision is RESOLVED by exact matching, not accepted:
  /// both slug to the same directory name, and only the one whose recorded cwd matches counts.
  func testSlugCollidingDirectoriesAreToldApartByTheRecordedCwd() throws {
    let mine = "/a-b/c"
    let theirs = "/a/b/c"
    XCTAssertEqual(
      AgentSessionIndex.claudeSlugHint(for: mine), AgentSessionIndex.claudeSlugHint(for: theirs),
      "the collision must be real, or this test proves nothing")
    try seedClaude(directory: AgentSessionIndex.claudeSlugHint(for: mine), cwd: theirs)

    let found = makeIndex().backends(forCwds: [mine], savedAt: savedAt)
    XCTAssertNil(found[mine], "a sibling directory's conversation is not this pane's")
  }

  /// The `cwd` is not on line 1 — that is a summary record — so extraction has to scan forward.
  func testClaudeCwdIsReadPastTheSummaryFirstLine() {
    let lines = [
      #"{"leafUuid":"abc","sessionId":"s1","type":"summary"}"#,
      #"{"type":"user","cwd":"/tmp/project"}"#,
    ]
    XCTAssertEqual(AgentSessionIndex.claudeCwd(inLines: lines), "/tmp/project")
    XCTAssertNil(AgentSessionIndex.claudeCwd(inLines: [lines[0]]), "the summary alone has no cwd")
  }

  func testMalformedClaudeLinesAreIgnored() {
    XCTAssertNil(AgentSessionIndex.claudeCwd(inLines: []))
    XCTAssertNil(AgentSessionIndex.claudeCwd(inLines: ["not json at all"]))
    XCTAssertNil(AgentSessionIndex.claudeCwd(inLines: [#"{"type":"user"}"#]))
    XCTAssertNil(
      AgentSessionIndex.claudeCwd(inLines: [#"{"cwd":""}"#]), "an empty cwd is not a cwd")
  }

  func testSlugHintReplacesDotsAsWellAsSlashes() {
    // Measured against the real store: `/Users/x/.buzz` is kept as `-Users-x--buzz`.
    XCTAssertEqual(AgentSessionIndex.claudeSlugHint(for: "/Users/x/.buzz"), "-Users-x--buzz")
    XCTAssertEqual(AgentSessionIndex.claudeSlugHint(for: "/tmp/project"), "-tmp-project")
  }

  // MARK: Codex

  func testFindsACodexConversationByRecordedCwd() throws {
    let cwd = "/tmp/project"
    try seedCodex(day: savedAtDay, cwd: cwd)

    XCTAssertEqual(makeIndex().backends(forCwds: [cwd], savedAt: savedAt)[cwd], [.codex])
  }

  func testCodexCwdRequiresASessionMetaFirstLine() {
    XCTAssertEqual(
      AgentSessionIndex.codexCwd(
        inFirstLine: #"{"type":"session_meta","payload":{"cwd":"/tmp/p"}}"#), "/tmp/p")
    // A record kind we don't understand is a format we shouldn't guess at.
    XCTAssertNil(
      AgentSessionIndex.codexCwd(
        inFirstLine: #"{"type":"response_item","payload":{"cwd":"/tmp/p"}}"#))
    XCTAssertNil(AgentSessionIndex.codexCwd(inFirstLine: ""))
    XCTAssertNil(AgentSessionIndex.codexCwd(inFirstLine: "plain text"))
    XCTAssertNil(AgentSessionIndex.codexCwd(inFirstLine: #"{"type":"session_meta"}"#))
  }

  func testBothAgentsQualifyingYieldsBothRatherThanAGuess() throws {
    let cwd = "/tmp/project"
    try seedClaude(directory: AgentSessionIndex.claudeSlugHint(for: cwd), cwd: cwd)
    try seedCodex(day: savedAtDay, cwd: cwd)

    XCTAssertEqual(makeIndex().backends(forCwds: [cwd], savedAt: savedAt)[cwd], [.claude, .codex])
  }

  // MARK: Recency

  func testRecencyWindowBoundaries() {
    let window = AgentSessionIndex.recencyWindow
    XCTAssertTrue(AgentSessionIndex.isRecent(savedAt, savedAt: savedAt))
    XCTAssertTrue(
      AgentSessionIndex.isRecent(savedAt.addingTimeInterval(-window), savedAt: savedAt),
      "the boundary itself qualifies")
    XCTAssertTrue(AgentSessionIndex.isRecent(savedAt.addingTimeInterval(window), savedAt: savedAt))
    XCTAssertFalse(
      AgentSessionIndex.isRecent(savedAt.addingTimeInterval(-window - 1), savedAt: savedAt))
  }

  /// A future mtime is clock skew or a restored backup, not evidence the session is irrelevant.
  func testAFutureDatedSessionStillQualifies() {
    XCTAssertTrue(
      AgentSessionIndex.isRecent(savedAt.addingTimeInterval(60 * 60), savedAt: savedAt))
  }

  /// **REGRESSION.** Twelve hours, not the five minutes first proposed: a transcript's mtime is its
  /// last message, so an agent left idle at its prompt before you quit is the COMMON case, and a
  /// five-minute window would have missed exactly the conversation the feature exists to reopen.
  func testAnAgentIdleForFortyMinutesBeforeTheQuitStillQualifies() throws {
    let cwd = "/tmp/project"
    try seedClaude(
      directory: AgentSessionIndex.claudeSlugHint(for: cwd), cwd: cwd,
      modified: savedAt.addingTimeInterval(-40 * 60))

    XCTAssertEqual(makeIndex().backends(forCwds: [cwd], savedAt: savedAt)[cwd], [.claude])
  }

  func testAStaleConversationIsNotOffered() throws {
    let cwd = "/tmp/project"
    try seedClaude(
      directory: AgentSessionIndex.claudeSlugHint(for: cwd), cwd: cwd,
      modified: savedAt.addingTimeInterval(-5 * 24 * 60 * 60))

    XCTAssertNil(makeIndex().backends(forCwds: [cwd], savedAt: savedAt)[cwd])
  }

  // MARK: Path comparison

  func testTrailingSlashesAndSymlinksMatchButCaseIsNotFolded() throws {
    XCTAssertTrue(AgentSessionIndex.pathsMatch("/tmp/project/", "/tmp/project"))
    XCTAssertTrue(AgentSessionIndex.pathsMatch("/tmp/project", "/tmp/project"))
    XCTAssertFalse(AgentSessionIndex.pathsMatch("", "/tmp/project"))

    // **REGRESSION.** A space is legal in a POSIX filename, so these are two different directories.
    // Trimming whitespace as "normalization" made them match, which would offer a picker for
    // history the pane does not have.
    XCTAssertFalse(AgentSessionIndex.pathsMatch("/tmp/project ", "/tmp/project"))
    XCTAssertTrue(
      AgentSessionIndex.pathsMatch("/tmp/my project", "/tmp/my project"),
      "a path with an interior space still matches itself")
    // A trailing newline IS a transport artefact of reading the value out of a JSON line.
    XCTAssertTrue(AgentSessionIndex.pathsMatch("/tmp/project\n", "/tmp/project"))

    // Case-folding would merge two genuinely different directories on a case-sensitive volume.
    XCTAssertFalse(AgentSessionIndex.pathsMatch("/tmp/Project", "/tmp/project"))

    let target = home.appendingPathComponent("real", isDirectory: true)
    let link = home.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    XCTAssertTrue(
      AgentSessionIndex.pathsMatch(link.path, target.path),
      "a session recorded through a symlink is the same directory")
  }

  // MARK: Bounds

  /// **REGRESSION.** A Codex store accumulates one file per session forever, so "read them all" is
  /// not a bound. Discovery runs on the launch path; an unbounded scan there is the bug.
  func testTheFileCapStopsTheScan() throws {
    let cwd = "/tmp/project"
    for index in 0..<50 {
      try seedCodex(day: savedAtDay, cwd: "/tmp/other-\(index)", file: "rollout-\(index).jsonl")
    }
    // The one that WOULD match, seeded last so the cap is hit before reaching it.
    try seedCodex(day: savedAtDay, cwd: cwd, file: "rollout-zzz.jsonl")

    var limits = AgentSessionIndex.Limits.standard
    limits.maxFiles = 5
    XCTAssertNil(
      makeIndex(limits: limits).backends(forCwds: [cwd], savedAt: savedAt)[cwd],
      "a capped scan publishes what it found, not what it would have found")
  }

  func testTheDeadlineStopsTheScan() throws {
    let cwd = "/tmp/project"
    try seedCodex(day: savedAtDay, cwd: cwd)

    var limits = AgentSessionIndex.Limits.standard
    limits.deadline = 1
    // A clock that jumps a minute per reading — the first budget check is already past the deadline.
    var ticks = 0
    let index = makeIndex(limits: limits) {
      defer { ticks += 1 }
      return Date(timeIntervalSince1970: Double(ticks) * 60)
    }
    XCTAssertNil(index.backends(forCwds: [cwd], savedAt: savedAt)[cwd])
  }

  /// **REGRESSION.** The Codex match was a linear scan calling `pathsMatch` per (pane, recorded)
  /// pair, and `pathsMatch` falls through to `resolvingSymlinksInPath()` on every non-equal pair —
  /// so 40 panes against a 2,000-entry set was ~160k filesystem syscalls, on the launch path, in a
  /// loop that never consulted the budget. Matching is now a Set probe.
  ///
  /// Asserted by cost, not by wall clock: a pane with NO codex history is the worst case, because
  /// it can never short-circuit. The whole call has to stay well inside the deadline.
  func testCodexMatchingDoesNotScaleWithTheNumberOfRecordedSessions() throws {
    for index in 0..<400 {
      try seedCodex(day: savedAtDay, cwd: "/tmp/other-\(index)", file: "rollout-\(index).jsonl")
    }
    let panes = (0..<40).map { "/tmp/no-history-\($0)" }

    let started = Date()
    let found = makeIndex().backends(forCwds: panes, savedAt: savedAt)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertTrue(found.isEmpty, "none of these panes has any history")
    XCTAssertLessThan(
      elapsed, AgentSessionIndex.Limits.standard.deadline,
      "matching must not do per-pair symlink resolution")
  }

  /// A pane whose directory is recorded through a symlink still matches — the set carries both the
  /// textual and the resolved form, so O(1) lookup did not cost the symlink case.
  func testCodexMatchesASessionRecordedThroughASymlink() throws {
    let target = home.appendingPathComponent("real", isDirectory: true)
    let link = home.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    try seedCodex(day: savedAtDay, cwd: link.path)

    XCTAssertEqual(
      makeIndex().backends(forCwds: [target.path], savedAt: savedAt)[target.path], [.codex])
  }

  func testCancellationStopsTheScan() throws {
    let cwd = "/tmp/project"
    try seedClaude(directory: AgentSessionIndex.claudeSlugHint(for: cwd), cwd: cwd)

    let found = makeIndex().backends(forCwds: [cwd], savedAt: savedAt, isCancelled: { true })
    XCTAssertNil(found[cwd])
  }

  /// A symlinked candidate file is a path out of the store we were pointed at; following one would
  /// let anything that can write into an agent directory aim our reads elsewhere.
  func testSymlinkedCandidateFilesAreNotFollowed() throws {
    let cwd = "/tmp/project"
    let real = home.appendingPathComponent("elsewhere/session.jsonl")
    try write(
      [#"{"type":"user","cwd":"/tmp/project"}"#], to: real, modified: savedAt)

    let directory = home.appendingPathComponent(
      ".claude/projects/\(AgentSessionIndex.claudeSlugHint(for: cwd))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("session.jsonl"), withDestinationURL: real)

    XCTAssertNil(makeIndex().backends(forCwds: [cwd], savedAt: savedAt)[cwd])
  }

  // MARK: Absence

  func testAMissingStoreYieldsNoOffersAndNoThrow() {
    XCTAssertTrue(makeIndex().backends(forCwds: ["/tmp/project"], savedAt: savedAt).isEmpty)
  }

  func testNoCwdsIsANoOp() {
    XCTAssertTrue(makeIndex().backends(forCwds: [], savedAt: savedAt).isEmpty)
  }

  /// The store belongs to the developer, not to the test suite.
  func testDiscoveryIsDisabledUnderXCTestWithNoSeededRoot() {
    XCTAssertNil(AgentSessionIndex.shared, "a unit test must never read the real ~/.claude")
  }
}
