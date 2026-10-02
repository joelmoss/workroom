import XCTest

@testable import Workroom

/// `VCSToolVersions` — the declared git floor (2.41) and what a below-floor or missing git disables.
///
/// The parsing tests exist because the remote commands fail *atomically* on an old tool, so a
/// mis-parsed version silently either blocks a working install or admits a broken one.
final class VCSToolVersionsTests: XCTestCase {

  private func result(_ stdout: String, exit: Int32 = 0, timedOut: Bool = false) -> CommandResult {
    CommandResult(stdout: stdout, stderr: "", exitCode: exit, timedOut: timedOut)
  }

  // MARK: Parsing

  func testParsesGitVersion() {
    XCTAssertEqual(VCSToolVersions.firstVersion(in: "git version 2.55.0")?.raw, "2.55.0")
  }

  /// Apple's git appends a build suffix in parentheses. `(Apple` and `Git-154)` must not be mistaken
  /// for the version.
  func testParsesAppleGitVersion() {
    let found = VCSToolVersions.firstVersion(in: "git version 2.39.5 (Apple Git-154)")
    XCTAssertEqual(found?.raw, "2.39.5")
  }

  func testParsesTwoComponentVersion() {
    XCTAssertEqual(VCSToolVersions.firstVersion(in: "git version 2.41")?.parsed.core, [2, 41, 0])
  }

  func testRejectsOutputWithNoVersion() {
    XCTAssertNil(VCSToolVersions.firstVersion(in: "command not found"))
    XCTAssertNil(VCSToolVersions.firstVersion(in: ""))
    XCTAssertNil(VCSToolVersions.firstVersion(in: "   \n  "))
  }

  // MARK: Floors

  /// Exactly at the floor must PASS. An off-by-one here locks out the version we chose to support.
  func testExactlyAtTheGitFloorIsOk() {
    XCTAssertEqual(
      VCSToolVersions.status(result("git version 2.41.0"), floor: VCSToolVersions.gitFloor),
      .ok("2.41.0"))
  }

  func testJustBelowTheGitFloorIsBelowFloor() {
    XCTAssertEqual(
      VCSToolVersions.status(result("git version 2.40.9"), floor: VCSToolVersions.gitFloor),
      .belowFloor("2.40.9"))
    XCTAssertEqual(
      VCSToolVersions.status(
        result("git version 2.39.5 (Apple Git-154)"),
        floor: VCSToolVersions.gitFloor),
      .belowFloor("2.39.5"))
  }

  func testAboveTheFloorIsOk() {
    XCTAssertEqual(
      VCSToolVersions.status(result("git version 2.55.0"), floor: VCSToolVersions.gitFloor),
      .ok("2.55.0"))
  }

  // MARK: Statuses

  func testExit127IsNotInstalledNotBelowFloor() {
    XCTAssertEqual(
      VCSToolVersions.status(
        result("", exit: CommandResult.commandNotFound),
        floor: VCSToolVersions.gitFloor),
      .notInstalled)
  }

  func testTimeoutIsUnknown() {
    XCTAssertEqual(
      VCSToolVersions.status(result("", timedOut: true), floor: VCSToolVersions.gitFloor), .unknown)
  }

  func testUnparseableOutputIsUnknown() {
    XCTAssertEqual(
      VCSToolVersions.status(result("wat"), floor: VCSToolVersions.gitFloor), .unknown)
  }

  func testVersionOnStderrIsStillRead() {
    let r = CommandResult(stdout: "", stderr: "git version 2.55.0", exitCode: 0, timedOut: false)
    XCTAssertEqual(VCSToolVersions.status(r, floor: VCSToolVersions.gitFloor), .ok("2.55.0"))
  }

  /// Never cry wolf: an unreadable probe must not disable a feature that may well work.
  func testUnknownIsTreatedAsUsable() {
    let report = VCSToolVersions.Report(git: .unknown)
    XCTAssertTrue(report.allowsRemoteActions)
    XCTAssertTrue(report.warnings.isEmpty)
  }

  // MARK: What a broken git disables

  func testOkGitAllowsRemoteActionsSilently() {
    let report = VCSToolVersions.Report(git: .ok("2.55.0"))
    XCTAssertTrue(report.allowsRemoteActions)
    XCTAssertTrue(report.warnings.isEmpty)
  }

  /// git is REQUIRED, so an old git disables remote actions and says so.
  func testOldGitDisablesRemoteActions() {
    let report = VCSToolVersions.Report(git: .belowFloor("2.30.0"))
    XCTAssertFalse(report.allowsRemoteActions)
    XCTAssertEqual(report.warnings.map(\.tool), ["git"])
  }

  func testAbsentGitDisablesRemoteActionsAndUsesBrokenInstallCopy() {
    let report = VCSToolVersions.Report(git: .notInstalled)
    XCTAssertFalse(report.allowsRemoteActions)
    let warning = report.warnings.first
    XCTAssertEqual(warning?.tool, "git")
    XCTAssertTrue(
      warning?.title.contains("isn’t installed") == true,
      "absent git needs broken-install copy, not too-old copy: \(warning?.title ?? "nil")")
  }

  // MARK: Probe

  /// The probe spawns `git --version` and nothing else.
  func testProbeRunsOnlyGit() async {
    let runner = RecordingVersionRunner(
      responses: [
        "git": CommandResult(
          stdout: "git version 2.55.0", stderr: "", exitCode: 0,
          timedOut: false)
      ])
    let report = await VCSToolVersions.probe(runner: runner)
    let executables = await runner.executables()
    XCTAssertEqual(report.git, .ok("2.55.0"))
    XCTAssertEqual(executables, ["git"])
    XCTAssertTrue(report.warnings.isEmpty)
  }

  func testProbeAsksForVersionFlag() async {
    let runner = RecordingVersionRunner(
      responses: [
        "git": CommandResult(
          stdout: "git version 2.55.0", stderr: "", exitCode: 0,
          timedOut: false)
      ])
    _ = await VCSToolVersions.probe(runner: runner)
    let calls = await runner.calls()
    XCTAssertEqual(calls.first?.args, ["--version"])
  }

  // MARK: Copy

  func testRequiredVersionReadsAsTwoComponentsWhenPatchIsZero() {
    XCTAssertEqual(VCSToolVersions.gitFloor.shortDescription, "2.41")
    XCTAssertEqual(SemanticVersion("1.2.3")!.shortDescription, "1.2.3")
  }

  func testBelowFloorCopyNamesBothFoundAndRequired() {
    let report = VCSToolVersions.Report(git: .belowFloor("2.30.0"))
    let warning = report.warnings.first
    XCTAssertTrue(warning?.title.contains("2.41") == true, "must name the requirement")
    XCTAssertTrue(warning?.detail.contains("2.30.0") == true, "must name what was found")
  }

  // MARK: - VCSToolVersionCache: never pin an absence

  /// A `.notInstalled` verdict must NOT be cached. It comes from exit 127 — the tool wasn't on PATH —
  /// and at launch the PATH may still be the deterministic floor, because `ShellEnvironment.path()`
  /// returns the floor until the detached interactive-shell probe lands and nothing joins that probe.
  /// The floor covers Homebrew but not a shim dir, Nix or MacPorts, so a git living in one read as
  /// missing and the cache pinned "Git isn't installed" for the whole process (`cached` is cleared
  /// only by the tests-only `reset()`). Re-probing costs one `--version`.
  func testAbsentToolIsNotCachedSoALaterProbeCanSeeAnEnrichedPath() async {
    // No "git" response ⇒ the runner returns 127, i.e. not on PATH.
    let runner = RecordingVersionRunner(responses: [:])
    let cache = VCSToolVersionCache()

    _ = await cache.report(runner: runner)
    _ = await cache.report(runner: runner)

    let gitProbes = await runner.executables().filter { $0 == "git" }.count
    XCTAssertEqual(gitProbes, 2, "an absent tool was cached, pinning it for the whole session")
  }

  /// The other direction: a settled verdict IS cached, so this doesn't turn into a probe per call.
  func testPresentToolIsStillCached() async {
    let runner = RecordingVersionRunner(responses: [
      "git": CommandResult(stdout: "git version 2.55.0", stderr: "", exitCode: 0, timedOut: false)
    ])
    let cache = VCSToolVersionCache()

    _ = await cache.report(runner: runner)
    _ = await cache.report(runner: runner)

    let probes = await runner.executables().count
    XCTAssertEqual(probes, 1, "a good report should be cached, not re-probed")
  }

  // MARK: - VCSToolVersionCache: TTLs

  /// A `.belowFloor` verdict must clear after its (short) TTL, so a user who upgrades and is told to
  /// relaunch actually sees it clear without relaunching — the bug the single, pinned-forever cache
  /// used to have. `.ok` gets a long TTL by contrast (see `testStillCachedWithinTheDefaultLongTTL`).
  func testBelowFloorExpiresAfterItsShortTTLAndReprobes() async {
    let runner = RecordingVersionRunner(responses: [
      "git": CommandResult(stdout: "git version 2.30.0", stderr: "", exitCode: 0, timedOut: false)
    ])
    let cache = VCSToolVersionCache(ttl: .seconds(60), belowFloorTTL: .milliseconds(20))

    let first = await cache.report(runner: runner)
    XCTAssertEqual(first.git, .belowFloor("2.30.0"))

    try? await Task.sleep(for: .milliseconds(60))

    _ = await cache.report(runner: runner)
    let gitProbes = await runner.executables().filter { $0 == "git" }.count
    XCTAssertEqual(gitProbes, 2, "a stale belowFloor verdict must re-probe, not stay pinned")
  }

  /// The counterpart: within the TTL, a settled verdict — including `.belowFloor` — must NOT
  /// re-probe on every call. Only proven with an injectable clock would this be airtight against a
  /// slow CI runner, but the default TTL (60s) is generous enough that two immediate calls prove the
  /// cache is doing anything at all.
  func testStillCachedWithinTheDefaultLongTTL() async {
    let runner = RecordingVersionRunner(responses: [
      "git": CommandResult(stdout: "git version 2.55.0", stderr: "", exitCode: 0, timedOut: false)
    ])
    let cache = VCSToolVersionCache()

    _ = await cache.report(runner: runner)
    _ = await cache.report(runner: runner)

    let gitProbes = await runner.executables().filter { $0 == "git" }.count
    XCTAssertEqual(gitProbes, 1)
  }

}

/// Records which executables were asked for, so a test can assert what was spawned.
private actor RecordingVersionRunner: StatusCommandRunning {
  struct Call: Sendable {
    let executable: String
    let args: [String]
  }

  private var recorded: [Call] = []
  private let responses: [String: CommandResult]

  init(responses: [String: CommandResult]) { self.responses = responses }

  func executables() -> [String] { recorded.map(\.executable) }
  func calls() -> [Call] { recorded }

  nonisolated func run(
    _ executable: String, _ args: [String], in directory: String, timeout: TimeInterval
  ) async -> CommandResult {
    await record(executable, args)
    return responses[executable]
      ?? CommandResult(
        stdout: "", stderr: "", exitCode: CommandResult.commandNotFound,
        timedOut: false)
  }

  private func record(_ executable: String, _ args: [String]) {
    recorded.append(Call(executable: executable, args: args))
  }
}
