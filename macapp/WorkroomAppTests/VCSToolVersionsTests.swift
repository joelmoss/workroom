import XCTest

@testable import Workroom

/// `VCSToolVersions` — the declared tool floors (git 2.41 required, jj 0.43 optional) and the
/// per-project-VCS scoping of what a below-floor tool disables.
///
/// The parsing tests exist because the remote commands fail *atomically* on an old tool, so a
/// mis-parsed version silently either blocks a working install or admits a broken one. The scoping
/// tests are the ones most likely to catch a regression: it is easy to write a global "tools ok?"
/// boolean that wrongly lets an old `jj` disable a git project's toolbar.
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

  func testParsesJJVersion() {
    XCTAssertEqual(VCSToolVersions.firstVersion(in: "jj 0.43.0")?.raw, "0.43.0")
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
    XCTAssertEqual(
      VCSToolVersions.status(result("jj 0.43.0"), floor: VCSToolVersions.jjFloor), .ok("0.43.0"))
  }

  func testBelowTheJJFloor() {
    XCTAssertEqual(
      VCSToolVersions.status(result("jj 0.17.0"), floor: VCSToolVersions.jjFloor),
      .belowFloor("0.17.0"))
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
    let r = CommandResult(stdout: "", stderr: "jj 0.43.0", exitCode: 0, timedOut: false)
    XCTAssertEqual(VCSToolVersions.status(r, floor: VCSToolVersions.jjFloor), .ok("0.43.0"))
  }

  /// Never cry wolf: an unreadable probe must not disable a feature that may well work.
  func testUnknownIsTreatedAsUsable() {
    let report = VCSToolVersions.Report(git: .unknown, jj: .unknown)
    XCTAssertTrue(report.allowsRemoteActions(vcs: "git"))
    XCTAssertTrue(report.allowsRemoteActions(vcs: "jj"))
    XCTAssertTrue(report.warnings(hasJJProject: true).isEmpty)
  }

  // MARK: Required vs optional, and per-VCS scoping

  func testEverythingOkAllowsBoth() {
    let report = VCSToolVersions.Report(git: .ok("2.55.0"), jj: .ok("0.43.0"))
    XCTAssertTrue(report.allowsRemoteActions(vcs: "git"))
    XCTAssertTrue(report.allowsRemoteActions(vcs: "jj"))
    XCTAssertTrue(report.warnings(hasJJProject: true).isEmpty)
  }

  /// jj is OPTIONAL: a git-only user must never be warned about a tool they don't use.
  func testMissingJJIsSilentWithoutAJJProject() {
    let report = VCSToolVersions.Report(git: .ok("2.55.0"), jj: .notInstalled)
    XCTAssertTrue(report.warnings(hasJJProject: false).isEmpty)
    XCTAssertTrue(report.allowsRemoteActions(vcs: "git"))
  }

  /// …but with a jj project registered it is worth saying, and it disables jj projects ONLY.
  func testMissingJJWarnsAndDisablesOnlyJJProjects() {
    let report = VCSToolVersions.Report(git: .ok("2.55.0"), jj: .notInstalled)
    let warnings = report.warnings(hasJJProject: true)
    XCTAssertEqual(warnings.count, 1)
    XCTAssertEqual(warnings.first?.tool, "jj")
    XCTAssertTrue(
      report.allowsRemoteActions(vcs: "git"), "an absent jj must NOT disable a git project")
    XCTAssertFalse(report.allowsRemoteActions(vcs: "jj"))
  }

  func testOldJJDisablesOnlyJJProjects() {
    let report = VCSToolVersions.Report(git: .ok("2.55.0"), jj: .belowFloor("0.17.0"))
    XCTAssertTrue(
      report.allowsRemoteActions(vcs: "git"), "an old jj must NOT disable a git project")
    XCTAssertFalse(report.allowsRemoteActions(vcs: "jj"))
    XCTAssertEqual(report.warnings(hasJJProject: true).map(\.tool), ["jj"])
  }

  /// git is REQUIRED, and a colocated jj repo drives git underneath — so an old git disables both.
  func testOldGitDisablesBothVCSKinds() {
    let report = VCSToolVersions.Report(git: .belowFloor("2.30.0"), jj: .ok("0.43.0"))
    XCTAssertFalse(report.allowsRemoteActions(vcs: "git"))
    XCTAssertFalse(report.allowsRemoteActions(vcs: "jj"), "jj drives git for its network ops")
    XCTAssertEqual(report.warnings(hasJJProject: false).map(\.tool), ["git"])
  }

  func testAbsentGitDisablesBothAndUsesBrokenInstallCopy() {
    let report = VCSToolVersions.Report(git: .notInstalled, jj: .ok("0.43.0"))
    XCTAssertFalse(report.allowsRemoteActions(vcs: "git"))
    XCTAssertFalse(report.allowsRemoteActions(vcs: "jj"))
    let warning = report.warnings(hasJJProject: false).first
    XCTAssertEqual(warning?.tool, "git")
    XCTAssertTrue(
      warning?.title.contains("isn’t installed") == true,
      "absent git needs broken-install copy, not too-old copy: \(warning?.title ?? "nil")")
  }

  func testBothBrokenWarnsAboutBoth() {
    let report = VCSToolVersions.Report(git: .belowFloor("2.30.0"), jj: .belowFloor("0.17.0"))
    XCTAssertEqual(report.warnings(hasJJProject: true).map(\.tool), ["git", "jj"])
  }

  // MARK: Probe

  /// `probeJJ: false` must not spawn `jj --version` at all — a git-only user shouldn't pay for a
  /// process, and `env` would report 127 for a tool they legitimately don't have.
  func testProbeSkipsJJEntirelyWhenNotNeeded() async {
    let runner = RecordingVersionRunner(
      responses: [
        "git": CommandResult(
          stdout: "git version 2.55.0", stderr: "", exitCode: 0,
          timedOut: false)
      ])
    let report = await VCSToolVersions.probe(runner: runner, probeJJ: false)
    let executables = await runner.executables()
    XCTAssertEqual(report.git, .ok("2.55.0"))
    XCTAssertEqual(executables, ["git"], "jj must not be spawned")
    XCTAssertTrue(report.warnings(hasJJProject: false).isEmpty)
  }

  func testProbeReadsBothWhenJJIsNeeded() async {
    let runner = RecordingVersionRunner(
      responses: [
        "git": CommandResult(
          stdout: "git version 2.55.0", stderr: "", exitCode: 0, timedOut: false),
        "jj": CommandResult(stdout: "jj 0.43.0", stderr: "", exitCode: 0, timedOut: false),
      ])
    let report = await VCSToolVersions.probe(runner: runner, probeJJ: true)
    let executables = await runner.executables()
    XCTAssertEqual(report.git, .ok("2.55.0"))
    XCTAssertEqual(report.jj, .ok("0.43.0"))
    XCTAssertEqual(executables, ["git", "jj"])
  }

  func testProbeAsksForVersionFlag() async {
    let runner = RecordingVersionRunner(
      responses: [
        "git": CommandResult(
          stdout: "git version 2.55.0", stderr: "", exitCode: 0,
          timedOut: false)
      ])
    _ = await VCSToolVersions.probe(runner: runner, probeJJ: false)
    let calls = await runner.calls()
    XCTAssertEqual(calls.first?.args, ["--version"])
  }

  // MARK: Copy

  func testRequiredVersionReadsAsTwoComponentsWhenPatchIsZero() {
    XCTAssertEqual(VCSToolVersions.gitFloor.shortDescription, "2.41")
    XCTAssertEqual(VCSToolVersions.jjFloor.shortDescription, "0.43")
    XCTAssertEqual(SemanticVersion("1.2.3")!.shortDescription, "1.2.3")
  }

  func testBelowFloorCopyNamesBothFoundAndRequired() {
    let report = VCSToolVersions.Report(git: .belowFloor("2.30.0"), jj: .ok("0.43.0"))
    let warning = report.warnings(hasJJProject: false).first
    XCTAssertTrue(warning?.title.contains("2.41") == true, "must name the requirement")
    XCTAssertTrue(warning?.detail.contains("2.30.0") == true, "must name what was found")
  }

  // MARK: - VCSToolVersionCache: never pin an absence

  /// A `.notInstalled` verdict must NOT be cached. It comes from exit 127 — the tool wasn't on PATH —
  /// and at launch the PATH may still be the deterministic floor, because `ShellEnvironment.path()`
  /// returns the floor until the detached interactive-shell probe lands and nothing joins that probe.
  /// The floor covers Homebrew but not a shim dir, Nix or MacPorts, so a jj living in one read as
  /// missing and the cache pinned "jj isn't installed" for the whole process (`cached` is cleared only
  /// by the tests-only `reset()`). Re-probing costs one `--version`.
  func testAbsentToolIsNotCachedSoALaterProbeCanSeeAnEnrichedPath() async {
    let runner = RecordingVersionRunner(responses: [
      "git": CommandResult(stdout: "git version 2.55.0", stderr: "", exitCode: 0, timedOut: false)
      // no "jj" response ⇒ the runner returns 127, i.e. not on PATH
    ])
    let cache = VCSToolVersionCache()

    _ = await cache.report(probeJJ: true, runner: runner)
    _ = await cache.report(probeJJ: true, runner: runner)

    let jjProbes = await runner.executables().filter { $0 == "jj" }.count
    XCTAssertEqual(jjProbes, 2, "an absent tool was cached, pinning it for the whole session")
  }

  /// The other direction: a settled verdict IS cached, so this doesn't turn into a probe per call.
  func testPresentToolsAreStillCached() async {
    let runner = RecordingVersionRunner(responses: [
      "git": CommandResult(stdout: "git version 2.55.0", stderr: "", exitCode: 0, timedOut: false),
      "jj": CommandResult(stdout: "jj 0.43.0", stderr: "", exitCode: 0, timedOut: false),
    ])
    let cache = VCSToolVersionCache()

    _ = await cache.report(probeJJ: true, runner: runner)
    _ = await cache.report(probeJJ: true, runner: runner)

    let probes = await runner.executables().count
    XCTAssertEqual(probes, 2, "a good report should be cached, not re-probed")
  }

  /// `probeJJ: false` reports jj `.notInstalled` WITHOUT running it. That is not an absence we
  /// discovered, so it must not block caching — otherwise every launch with no jj project registered
  /// re-probes `git --version` on every call.
  func testSkippedJJDoesNotBlockCaching() async {
    let runner = RecordingVersionRunner(responses: [
      "git": CommandResult(stdout: "git version 2.55.0", stderr: "", exitCode: 0, timedOut: false)
    ])
    let cache = VCSToolVersionCache()

    _ = await cache.report(probeJJ: false, runner: runner)
    _ = await cache.report(probeJJ: false, runner: runner)

    let gitProbes = await runner.executables().filter { $0 == "git" }.count
    XCTAssertEqual(gitProbes, 1, "a skipped jj was mistaken for a discovered absence")
  }

}

/// Records which executables were asked for, so a test can assert `jj` was never spawned.
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
