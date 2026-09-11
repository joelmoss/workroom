import Combine
import Foundation
import XCTest

@testable import Workroom

final class AgentUsageTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  func testRecognizesOnlyDirectAgentCommandsAndKnownTitles() {
    XCTAssertEqual(AgentTitleRecognition.backend(for: "claude"), .claude)
    XCTAssertEqual(AgentTitleRecognition.backend(for: "claude --resume abc"), .claude)
    XCTAssertEqual(
      AgentTitleRecognition.backend(for: "/opt/homebrew/bin/claude --model opus"), .claude)
    XCTAssertEqual(AgentTitleRecognition.backend(for: "Claude Code"), .claude)
    XCTAssertEqual(AgentTitleRecognition.backend(for: "codex --full-auto"), .codex)
    XCTAssertEqual(AgentTitleRecognition.backend(for: "/usr/local/bin/codex"), .codex)
    XCTAssertEqual(AgentTitleRecognition.backend(for: "Codex"), .codex)

    for title in ["echo claude", "myclaude", "codex-helper", "Claude Code setup", "", "pwd"] {
      XCTAssertNil(AgentTitleRecognition.backend(for: title), "false positive for \(title)")
    }
    XCTAssertNil(AgentTitleRecognition.backend(for: nil))
  }

  func testRecognizesOnlyDirectAgentProcessNames() {
    XCTAssertEqual(AgentProcessRecognition.backend(forProcessName: "claude"), .claude)
    XCTAssertEqual(
      AgentProcessRecognition.backend(forProcessName: "/opt/homebrew/bin/codex"), .codex)
    for name in ["node", "claude-helper", "codex-agent", "Claude Code", ""] {
      XCTAssertNil(AgentProcessRecognition.backend(forProcessName: name))
    }
    XCTAssertNil(AgentProcessRecognition.backend(forProcessName: nil))
  }

  func testPaceAtStartMidpointAndEnd() {
    let duration: TimeInterval = 300
    let reset = now.addingTimeInterval(duration)
    let window = AgentQuotaWindow(
      kind: .fiveHour, usedPercentage: 40, duration: duration, resetsAt: reset)
    XCTAssertEqual(window.pace(at: now).percentagePoints, 40, accuracy: 0.001)
    XCTAssertEqual(
      window.pace(at: now.addingTimeInterval(150)).percentagePoints, -10, accuracy: 0.001)
    XCTAssertEqual(window.pace(at: reset).percentagePoints, -60, accuracy: 0.001)
    XCTAssertEqual(
      window.pace(at: now.addingTimeInterval(-100)).percentagePoints, 40, accuracy: 0.001)
  }

  /// The pace pin's position, hoisted out of two view methods that each carried this expression
  /// verbatim while claiming to avoid a second copy of it.
  func testSustainablePacePercentageTracksElapsedTime() {
    let window = AgentQuotaWindow(
      kind: .fiveHour, usedPercentage: 42, duration: 300,
      resetsAt: now.addingTimeInterval(150))
    // Half the window elapsed ⇒ the pin sits at 50%, wherever usage happens to be.
    XCTAssertEqual(window.sustainablePacePercentage(at: now), 50, accuracy: 0.001)
    XCTAssertEqual(window.sustainablePacePercentage(at: window.resetsAt), 100, accuracy: 0.001)
    // Before the window opened, and long past its reset: both ends stay on the track.
    XCTAssertEqual(
      window.sustainablePacePercentage(at: now.addingTimeInterval(-1000)), 0, accuracy: 0.001)
    XCTAssertEqual(
      window.sustainablePacePercentage(at: window.resetsAt.addingTimeInterval(9999)), 100,
      accuracy: 0.001)
  }

  func testPaceDescriptionsAndPercentageClamping() {
    XCTAssertEqual(
      AgentPace(percentagePoints: 6.4).accessibilityDescription, "6% in deficit")
    XCTAssertEqual(AgentPace(percentagePoints: -3.2).accessibilityDescription, "3% in reserve")
    XCTAssertEqual(
      AgentQuotaWindow(kind: .weekly, usedPercentage: 130, duration: 10, resetsAt: now)
        .usedPercentage, 100)
    XCTAssertEqual(
      AgentQuotaWindow(kind: .weekly, usedPercentage: -4, duration: 10, resetsAt: now)
        .usedPercentage, 0)
  }

  /// The bar-fill severity bands (issue #168). Pinned here rather than left in the view that draws
  /// them: this rule used to be a bare `> 15` inside a PRIVATE method of `TerminalStatusBar`, which
  /// no test could reach. The boundary compares `roundedPoints`, so a raw 15.4 — which both
  /// remaining numeric surfaces describe as "15% in deficit" — stays `.warning` rather than
  /// colouring as critical.
  func testPaceSeverityThresholds() {
    XCTAssertEqual(AgentPace(percentagePoints: -20).severity, .onPace)
    XCTAssertEqual(AgentPace(percentagePoints: 0).severity, .onPace)
    // Rounds to 0 ⇒ not over pace at all, matching `isOver`.
    XCTAssertEqual(AgentPace(percentagePoints: 0.4).severity, .onPace)
    XCTAssertEqual(AgentPace(percentagePoints: 1).severity, .warning)
    XCTAssertEqual(AgentPace(percentagePoints: 15).severity, .warning)
    XCTAssertEqual(AgentPace(percentagePoints: 15.4).severity, .warning)
    XCTAssertEqual(
      AgentPace(percentagePoints: 15.4).accessibilityDescription, "15% in deficit")
    // 15.6 rounds to 16, so it crosses on the value the user is shown, not on the raw double.
    XCTAssertEqual(AgentPace(percentagePoints: 15.6).severity, .critical)
    XCTAssertEqual(AgentPace(percentagePoints: 16).severity, .critical)
    XCTAssertEqual(AgentPace(percentagePoints: 90).severity, .critical)
  }

  /// `QuotaBar.fill(for:_:)` is the only thing carrying severity in the footer now that the pace
  /// text is gone, so swapping two arms of its switch would ship green. Modelled on
  /// `ChangeBadgeTests`, which exists because a colour switch drifted once before.
  @MainActor func testQuotaBarFillMapsEachSeverityToItsOwnToken() {
    let tokens = ThemeService.shared.tokens
    XCTAssertEqual(QuotaBar.fill(for: .onPace, tokens), tokens.accent)
    XCTAssertEqual(QuotaBar.fill(for: .warning, tokens), tokens.warning)
    XCTAssertEqual(QuotaBar.fill(for: .critical, tokens), tokens.failure)
  }

  func testRelativeResetDescriptionCapsAtTwoUnits() {
    let window = AgentQuotaWindow(
      kind: .weekly, usedPercentage: 10, duration: 10, resetsAt: now.addingTimeInterval(93_000))
    XCTAssertEqual(window.resetDescription(at: now), "resets in 1d 1h")
    XCTAssertEqual(window.resetDescription(at: now.addingTimeInterval(92_999)), "resets in 1m")
    XCTAssertEqual(window.resetDescription(at: window.resetsAt), "resets now")
  }

  func testClaudeDecodesBothWindowsUnknownFieldsAndMissingWindow() throws {
    let both = Data(
      """
      {"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":2000003600,"future":1},"seven_day":{"used_percentage":41.2,"resets_at":2000604800}},"ignored":true}
      """.utf8)
    let snapshot = try XCTUnwrap(AgentUsageDecoding.claude(data: both, capturedAt: now, now: now))
    XCTAssertEqual(snapshot.backend, .claude)
    XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
    XCTAssertEqual(snapshot.windows.map(\.usedPercentage), [23.5, 41.2])

    let one = Data(#"{"five_hour":{"used_percentage":17,"resets_at":2000003600}}"#.utf8)
    XCTAssertEqual(
      AgentUsageDecoding.claude(data: one, capturedAt: now, now: now)?.windows.count, 1)
  }

  func testClaudeRejectsMalformedPartialAndExpiredData() {
    XCTAssertNil(AgentUsageDecoding.claude(data: Data("{".utf8), capturedAt: now, now: now))
    let expired = Data(#"{"five_hour":{"used_percentage":10,"resets_at":1999999999}}"#.utf8)
    XCTAssertNil(AgentUsageDecoding.claude(data: expired, capturedAt: now, now: now))
    let partial = Data(#"{"five_hour":{"used_percentage":10}}"#.utf8)
    XCTAssertNil(AgentUsageDecoding.claude(data: partial, capturedAt: now, now: now))
  }

  /// Every empty-quota footer has to be able to say WHY, so each way the Claude cache comes up empty
  /// gets its own sentence.
  func testClaudeReadDistinguishesMissingUnreadableAndResetCaches() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cacheURL = root.appendingPathComponent("claude-rate-limits.json")

    func reason() -> String {
      guard
        case .failure(let value) = AgentUsageDecoding.readClaudeSnapshot(
          cacheURL: cacheURL, now: now)
      else { return "" }
      return value
    }

    XCTAssertTrue(reason().contains("hasn't received"), reason())
    try Data("{".utf8).write(to: cacheURL)
    XCTAssertTrue(reason().contains("couldn't be read"), reason())
    try Data(#"{"five_hour":{"used_percentage":10,"resets_at":1999999999}}"#.utf8).write(
      to: cacheURL)
    XCTAssertTrue(reason().contains("since reset"), reason())

    try Data(#"{"five_hour":{"used_percentage":10,"resets_at":2000003600}}"#.utf8).write(
      to: cacheURL)
    let read = AgentUsageDecoding.readClaudeSnapshot(cacheURL: cacheURL, now: now)
    XCTAssertEqual(read.snapshot?.windows.first?.usedPercentage, 10)
  }

  /// A stored snapshot expires where it sits, with no refresh running to record why — so the reason
  /// has to be derived when the footer reads it, not when the file was read.
  @MainActor func testStoredSnapshotThatExpiresExplainsItselfWithoutARefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cacheURL = root.appendingPathComponent("claude-rate-limits.json")
    try Data(#"{"five_hour":{"used_percentage":10,"resets_at":2000003600}}"#.utf8).write(
      to: cacheURL)

    let clock = Clock(value: now)
    let monitor = AgentUsageMonitor(
      codexSessionsURL: root.appendingPathComponent("sessions"), claudeCacheURL: cacheURL,
      now: { clock.value }, startAutomatically: false)
    XCTAssertTrue(monitor.unavailableReason(for: .claude).contains("has been read yet"))

    monitor.refresh()
    for _ in 0..<200 where monitor.loading.contains(.claude) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertNotNil(monitor.snapshot(for: .claude))

    clock.value = now.addingTimeInterval(4_000)
    XCTAssertNil(monitor.snapshot(for: .claude))
    XCTAssertTrue(
      monitor.unavailableReason(for: .claude).contains("since reset"),
      monitor.unavailableReason(for: .claude))
  }

  private final class Clock: @unchecked Sendable {
    var value: Date
    init(value: Date) { self.value = value }
  }

  func testCodexDecodesAdvertisedWindowsAndNewestCumulativeSnapshot() throws {
    let older = rollout(
      timestamp: "2033-05-18T03:33:20.000Z", primary: (5, 300, 2_000_003_600), secondary: nil)
    let newer = rollout(
      timestamp: "2033-05-18T03:34:20.000Z", primary: (42, 300, 2_000_003_600),
      secondary: (61, 10080, 2_000_604_800))
    let data = Data((older + "\n" + newer + "\n").utf8)
    let snapshot = try XCTUnwrap(
      AgentUsageDecoding.codexRollout(
        data: data, fileSize: UInt64(data.count), modifiedAt: now, now: now))
    XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
    XCTAssertEqual(snapshot.windows.map(\.usedPercentage), [42, 61])
  }

  func testCodexSupportsOneOrNonstandardAdvertisedWindowAndSkipsMalformedTail() throws {
    let valid = rollout(
      timestamp: "2033-05-18T03:33:20Z", primary: (12, 60, 2_000_003_600), secondary: nil)
    let data = Data((valid + "\n{partial").utf8)
    let snapshot = try XCTUnwrap(
      AgentUsageDecoding.codexRollout(
        data: data, fileSize: UInt64(data.count), modifiedAt: now, now: now))
    XCTAssertEqual(snapshot.windows.count, 1)
    XCTAssertEqual(snapshot.windows[0].kind, .duration(minutes: 60))
  }

  func testCodexReadUsesBoundedTailAndFallsBackFromMalformedNewestFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let validURL = root.appendingPathComponent("valid.jsonl")
    let valid =
      String(repeating: "x", count: 8_000) + "\n"
      + rollout(
        timestamp: "2033-05-18T03:33:20Z", primary: (33, 300, 2_000_003_600), secondary: nil)
      + "\n"
    try Data(valid.utf8).write(to: validURL)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-1)], ofItemAtPath: validURL.path)
    let malformedURL = root.appendingPathComponent("newest.jsonl")
    try Data("{partial".utf8).write(to: malformedURL)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: malformedURL.path)

    let read = AgentUsageDecoding.readCodex(sessionsRoot: root, now: now, maximumTailBytes: 1024)
    let snapshot = try XCTUnwrap(read.snapshot)
    XCTAssertEqual(snapshot.windows[0].usedPercentage, 33)
  }

  /// What the read asks to be watched: the directories Codex is actually appending to, plus the
  /// ancestors that will have to create tomorrow's directory — never every directory in the tree.
  /// The monitor reopens one descriptor per directory in this set, on the main actor, so an
  /// unbounded set is a main-thread stall that grows with the user's history (issue: app hang in
  /// `rebuildWatches`).
  func testCodexReadWatchesOnlyTheNewestRolloutDirectoriesAndTheirAncestors() throws {
    // Standardized to match what `AgentUsageDecoding.watchDirectories` returns: it standardizes
    // every URL it hands back, so expectations built off a raw `temporaryDirectory` compare two
    // differently-normalized spellings on any machine whose temp dir carries a `/private` prefix.
    let root = FileManager.default.temporaryDirectory.standardizedFileURL
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let month = root.appendingPathComponent("2033/05")
    var days: [URL] = []
    for day in 1...(AgentUsageDecoding.candidateLimit + 2) {
      let directory = month.appendingPathComponent(String(format: "%02d", day))
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("rollout.jsonl")
      try Data(
        (rollout(
          timestamp: "2033-05-18T03:33:20Z", primary: (7, 300, 2_000_003_600), secondary: nil)
          + "\n").utf8
      ).write(to: file)
      // Oldest first, so the two lowest-numbered days fall outside the candidate cap.
      try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(TimeInterval(day))], ofItemAtPath: file.path)
      days.append(directory)
    }

    let read = AgentUsageDecoding.readCodex(sessionsRoot: root, now: now)
    let watched = Set(read.watchDirectories.map(\.path))
    XCTAssertEqual(read.watchDirectories.first?.path, root.path)
    XCTAssertEqual(
      watched,
      Set(
        ([root, root.appendingPathComponent("2033"), month]
          + days.suffix(
            AgentUsageDecoding.candidateLimit)).map(\.path)))
    for stale in days.prefix(2) { XCTAssertFalse(watched.contains(stale.path)) }
  }

  /// The read that finds nothing new must publish NOTHING.
  ///
  /// Every `@Published` write invalidates every view observing the monitor, and the status bar's
  /// `ViewThatFits` instantiates all of its children to measure them — so the common read (same
  /// numbers, Claude's bridge having merely rewritten its cache file) has to be silent. Two things
  /// used to break that and neither is visible from the published values alone, which is why this
  /// counts `objectWillChange` instead: `capturedAt` rides in `AgentQuotaSnapshot`'s synthesized
  /// `==` and moves with the file's mtime on every rewrite, and `loading` toggled on and off for a
  /// backend that never resolves. Deleting either guard leaves every value assertion in this file
  /// passing.
  @MainActor func testASecondIdenticalReadPublishesNothing() async throws {
    let root = FileManager.default.temporaryDirectory.standardizedFileURL
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cacheURL = root.appendingPathComponent("claude-rate-limits.json")
    try Data(#"{"five_hour":{"used_percentage":10,"resets_at":2000003600}}"#.utf8).write(
      to: cacheURL)

    let monitor = AgentUsageMonitor(
      codexSessionsURL: root.appendingPathComponent("sessions"), claudeCacheURL: cacheURL,
      now: { self.now }, startAutomatically: false)

    var publishes = 0
    let subscription = monitor.objectWillChange.sink { _ in publishes += 1 }
    defer { subscription.cancel() }

    monitor.refresh()
    await settle { monitor.completedReadCount == 1 }
    XCTAssertEqual(monitor.completedReadCount, 1, "first read never landed")
    XCTAssertNotNil(monitor.snapshot(for: .claude))
    XCTAssertGreaterThan(publishes, 0, "the first read must publish — it put a snapshot on screen")

    // Exactly what the Claude bridge does on every status-line invocation: same bytes, new mtime.
    // The mtime is set explicitly, not just implied by rewriting — two back-to-back writes can land
    // in one timestamp tick, and then `capturedAt` never moves and this test proves nothing.
    try Data(#"{"five_hour":{"used_percentage":10,"resets_at":2000003600}}"#.utf8).write(
      to: cacheURL)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(120)], ofItemAtPath: cacheURL.path)
    XCTAssertNotEqual(
      try XCTUnwrap(
        FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date),
      try XCTUnwrap(monitor.snapshot(for: .claude)).capturedAt,
      "the rewrite has to move the mtime, or the capturedAt half of this test is vacuous")
    let afterFirst = publishes
    monitor.refresh()
    // Wait for the READ to land, not for a value to change: a read that correctly publishes nothing
    // changes nothing, so any published-state predicate here would return before the read ran.
    await settle { monitor.completedReadCount == 2 }
    XCTAssertEqual(monitor.completedReadCount, 2, "second read never landed")
    XCTAssertEqual(
      publishes, afterFirst,
      "a read that found the same numbers published \(publishes - afterFirst) time(s)")
  }

  /// What the monitor actually holds descriptors on, and that it is rebuilt every read rather than
  /// memoized. `watchedDirectoryPaths` is populated only from `open()` calls that SUCCEEDED, so a
  /// regression that records wanted-but-unopened paths shows up here.
  @MainActor func testWatchesCoverTheRolloutChainAndTheClaudeCacheDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.standardizedFileURL
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    let day = sessions.appendingPathComponent("2033/05/18")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    try Data(
      (rollout(timestamp: "2033-05-18T03:33:20Z", primary: (7, 300, 2_000_003_600), secondary: nil)
        + "\n").utf8
    ).write(to: day.appendingPathComponent("rollout.jsonl"))
    let cacheURL = root.appendingPathComponent("claude-rate-limits.json")
    try Data(#"{"five_hour":{"used_percentage":10,"resets_at":2000003600}}"#.utf8).write(
      to: cacheURL)

    let monitor = AgentUsageMonitor(
      codexSessionsURL: sessions, claudeCacheURL: cacheURL, now: { self.now },
      startAutomatically: false)
    monitor.refresh()
    await settle { monitor.completedReadCount == 1 }

    XCTAssertEqual(
      monitor.watchedDirectoryPaths,
      Set(
        [
          sessions, sessions.appendingPathComponent("2033"),
          sessions.appendingPathComponent("2033/05"), day, root,
        ].map(\.path)))

    // Rebuilt, not memoized: a second read with an unchanged set must still hold every descriptor.
    monitor.refresh()
    await settle { monitor.completedReadCount == 2 }
    XCTAssertEqual(monitor.watchedDirectoryPaths.count, 5)
  }

  /// A directory that does not exist yet falls back to its nearest existing parent.
  ///
  /// The Claude bridge's directory is absent until the bridge is enabled, and `~/.codex/sessions`
  /// can be deleted. Dropping a missing path outright leaves nothing watching for its creation, and
  /// since these watches are the only automatic trigger, it would never be noticed at all.
  @MainActor func testMissingDirectoriesAreWatchedAtTheirNearestExistingParent() async throws {
    let root = FileManager.default.temporaryDirectory.standardizedFileURL
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let monitor = AgentUsageMonitor(
      codexSessionsURL: root.appendingPathComponent("sessions"),
      claudeCacheURL: root.appendingPathComponent("bridge/claude-rate-limits.json"),
      now: { self.now }, startAutomatically: false)
    monitor.refresh()
    await settle { monitor.completedReadCount == 1 }

    XCTAssertTrue(
      monitor.watchedDirectoryPaths.contains(root.path),
      "neither missing directory fell back to an existing parent, so nothing is watched: "
        + "\(monitor.watchedDirectoryPaths)")
  }

  /// An EMPTY newest date directory still has to be watched.
  ///
  /// Codex creates `sessions/YYYY/MM/DD` before it writes anything into it, and a directory watch is
  /// not recursive — so a set derived only from directories that already hold a rollout misses the
  /// one the next rollout lands in, and the quota sits stale until some unrelated event fires.
  /// Reproduced against the full-tree walk this replaced, which did catch it.
  func testWatchSetIncludesTheNewestDateDirectoryEvenBeforeItHoldsARollout() throws {
    let root = FileManager.default.temporaryDirectory.standardizedFileURL
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let withRollout = root.appendingPathComponent("2033/05/18")
    try FileManager.default.createDirectory(at: withRollout, withIntermediateDirectories: true)
    try Data(
      (rollout(timestamp: "2033-05-18T03:33:20Z", primary: (7, 300, 2_000_003_600), secondary: nil)
        + "\n").utf8
    ).write(to: withRollout.appendingPathComponent("rollout.jsonl"))
    // Tomorrow, created but not yet written to — exactly the state Codex leaves behind between
    // starting a session and appending its first record.
    let empty = root.appendingPathComponent("2033/05/19")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

    let read = AgentUsageDecoding.readCodex(sessionsRoot: root, now: now)
    let watched = Set(read.watchDirectories.map(\.path))
    XCTAssertTrue(
      watched.contains(empty.path),
      "the newest date directory is unwatched, so its first rollout will notify nobody")
    XCTAssertTrue(watched.contains(withRollout.path))
    XCTAssertNotNil(read.snapshot, "the rollout that does exist must still be read")
  }

  /// A cancelled read must do no work and claim no watches.
  ///
  /// `readCodex` runs inside `runBlocking`'s GCD closure where `Task.isCancelled` is always false,
  /// so the supersede path rides entirely on this injected probe. Nothing else in the suite passes
  /// it: every other test awaits `completedReadCount` before refreshing again, so two reads never
  /// actually race and the early-returns are never taken.
  func testACancelledCodexReadReturnsNothingAndClaimsNoWatches() throws {
    let root = FileManager.default.temporaryDirectory.standardizedFileURL
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let day = root.appendingPathComponent("2033/05/18")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    try Data(
      (rollout(timestamp: "2033-05-18T03:33:20Z", primary: (7, 300, 2_000_003_600), secondary: nil)
        + "\n").utf8
    ).write(to: day.appendingPathComponent("rollout.jsonl"))

    // Baseline: the same tree DOES produce a snapshot and watches when nothing cancels, so the
    // assertions below cannot be satisfied by a read that simply found nothing.
    let live = AgentUsageDecoding.readCodex(sessionsRoot: root, now: now, isCancelled: { false })
    XCTAssertNotNil(live.snapshot)
    XCTAssertFalse(live.watchDirectories.isEmpty)

    let cancelled = AgentUsageDecoding.readCodex(
      sessionsRoot: root, now: now, isCancelled: { true })
    XCTAssertNil(cancelled.snapshot)
    XCTAssertTrue(
      cancelled.watchDirectories.isEmpty,
      "a cancelled read must not report a watch set — apply would install it")
  }

  /// The spinner belongs to the click that asked for it.
  ///
  /// `pendingBackends` excludes a backend that has already recorded a failure, so an AUTOMATIC read
  /// landing mid-retry would recompute `loading` without it and take the spinner away — the exact
  /// "no visible response" the `userInitiated` flag exists to prevent. Automatic reads may only add.
  @MainActor func testUserInitiatedSpinnerSurvivesAnAutomaticRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.standardizedFileURL
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // No Claude cache file and no Codex sessions tree: both backends settle as unavailable.
    let monitor = AgentUsageMonitor(
      codexSessionsURL: root.appendingPathComponent("sessions"),
      claudeCacheURL: root.appendingPathComponent("claude-rate-limits.json"), now: { self.now },
      startAutomatically: false)

    monitor.refresh()
    await settle { monitor.completedReadCount == 1 }
    XCTAssertFalse(monitor.readFailures.isEmpty, "both backends should have settled as failed")
    XCTAssertTrue(monitor.loading.isEmpty)

    // An automatic read never re-raises a settled backend...
    monitor.refresh()
    XCTAssertTrue(monitor.loading.isEmpty, "an automatic read must not flag a settled backend")
    await settle { monitor.completedReadCount == 2 }

    // ...but a click must, and a watch event landing underneath it must not undo that.
    monitor.refresh(userInitiated: true)
    XCTAssertEqual(monitor.loading, Set(AgentBackend.allCases))
    monitor.refresh()
    XCTAssertEqual(
      monitor.loading, Set(AgentBackend.allCases),
      "an automatic refresh stole the spinner from a user-initiated retry")
  }

  /// `capturedAt` comes from the rollout's own timestamp, not the file's mtime.
  ///
  /// The parser was swapped from `ISO8601DateFormatter` to a cached `ISO8601FormatStyle`, and the
  /// failure path is silent: `parseISO8601` returning nil falls back to `modifiedAt`. Every other
  /// test here asserts percentages against an absolute `resets_at`, so a parser that returned nil
  /// for every input would leave the whole file green.
  func testCapturedAtComesFromTheRolloutTimestampNotTheFileMtime() throws {
    let root = FileManager.default.temporaryDirectory.standardizedFileURL
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("rollout.jsonl")
    // Fractional seconds: the path the style with `includingFractionalSeconds` has to take.
    try Data(
      (rollout(
        timestamp: "2033-05-18T03:33:20.553Z", primary: (7, 300, 2_000_003_600), secondary: nil)
        + "\n").utf8
    ).write(to: file)
    let mtime = now.addingTimeInterval(90_000)
    try FileManager.default.setAttributes(
      [.modificationDate: mtime], ofItemAtPath: file.path)

    let snapshot = try XCTUnwrap(
      AgentUsageDecoding.readCodex(sessionsRoot: root, now: now).snapshot)
    XCTAssertEqual(
      snapshot.capturedAt.timeIntervalSince1970, 2_000_000_000.553, accuracy: 0.0005,
      "capturedAt should be the parsed rollout timestamp")
    XCTAssertNotEqual(
      snapshot.capturedAt, mtime, "capturedAt fell back to the file mtime — the parse failed")
  }

  /// Poll rather than await the monitor's task: `refresh()` owns it privately, and an
  /// `XCTNSPredicateExpectation` reads a cached snapshot of the value.
  @MainActor private func settle(until condition: () -> Bool) async {
    for _ in 0..<200 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func rollout(
    timestamp: String, primary: (Double, Int, Int)?, secondary: (Double, Int, Int)?
  ) -> String {
    func window(_ value: (Double, Int, Int)?) -> String {
      guard let value else { return "null" }
      return
        "{\"used_percent\":\(value.0),\"window_minutes\":\(value.1),\"resets_at\":\(value.2),\"future\":true}"
    }
    return
      "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{"
      + "\"type\":\"token_count\",\"info\":{},\"rate_limits\":{"
      + "\"primary\":\(window(primary)),\"secondary\":\(window(secondary)),\"future\":1}}}"
  }
}
