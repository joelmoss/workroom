import XCTest

@testable import Workroom

/// `ShellEnvironment` has two layers and they fail differently, so they're tested differently.
///
/// The **floor** (`floorPath`) is pure given its inputs, so it's driven against fixture directories
/// — including one reproducing the `/etc/paths.d/postgresapp` layout that caused the filed bug
/// ("psql not found; skipping database copy"). That case is the regression test for this whole
/// change: if it passes, the app can resolve `psql` even when every other layer fails.
///
/// The **probe** is a real subprocess, so it's driven against stub shells written to a temp dir.
/// That's the only way to reach the paths that matter — a shell that exits non-zero, one that
/// outlives its deadline, one that prints noise on both sides of the markers — and the only way to
/// assert the two things a mock would hide: that the probe is spawned with a *cleared* PATH, and
/// that a timed-out child is actually dead afterwards rather than merely abandoned.
final class ShellEnvironmentTests: XCTestCase {
  private var tmp: URL!

  override func setUpWithError() throws {
    tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("shell-env-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    ShellEnvironment.resetForTesting()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tmp)
    ShellEnvironment.resetForTesting()
  }

  // MARK: Helpers

  private func write(_ contents: String, to name: String) throws -> String {
    let url = tmp.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url.path
  }

  private func pathsDirectory(_ files: [String: String]) throws -> String {
    let dir = tmp.appendingPathComponent("paths.d-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, contents) in files {
      try contents.write(
        to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    return dir.path
  }

  /// An executable stub standing in for the user's `$SHELL`, running `body` with the probe's
  /// script in `$2`.
  ///
  /// Written as `<name>/zsh`, and the basename is load-bearing: `loginShellExecutable` recognises
  /// a shell by its last path component, and anything it does not recognise is replaced by
  /// `/bin/sh`. A stub called `stub-shell` would therefore never run — `/bin/sh` would run the real
  /// probe script with the real `env`, and every assertion here would silently describe the host
  /// machine instead of the stub. `name` stays in the directory component so `pgrep -f` can still
  /// find a specific stub.
  private func stubShell(_ body: String, name: String = "stub-shell") throws -> String {
    let dir = tmp.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("zsh").path
    try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
  }

  /// A stub that `eval`s the probe's real script with `env` shadowed by a shell function emitting
  /// `body`. That way the markers in the output are the probe's own per-run UUID — the stub never
  /// has to know it — so these tests exercise the real marker round-trip rather than a lookalike.
  private func stubShell(reportingEnv body: String, prelude: String = "", name: String) throws
    -> String
  {
    try stubShell("\(prelude)\nenv() { \(body); }\neval \"$2\"", name: name)
  }

  private func floor(_ etcPaths: String, _ etcPathsD: String, inherited: String? = nil) -> [String]
  {
    ShellEnvironment.floorPath(etcPaths: etcPaths, etcPathsD: etcPathsD, inherited: inherited)
      .split(separator: ":").map(String.init)
  }

  // MARK: floorPath

  func testFloorReadsEtcPathsInOrder() throws {
    let etcPaths = try write("/usr/local/bin\n/usr/bin\n/bin\n", to: "paths")
    let dir = try pathsDirectory([:])
    let parts = floor(etcPaths, dir)
    XCTAssertEqual(Array(parts.prefix(3)), ["/usr/local/bin", "/usr/bin", "/bin"])
  }

  func testFloorReadsEveryPathsDFragmentSorted() throws {
    let etcPaths = try write("/usr/bin\n", to: "paths")
    let dir = try pathsDirectory([
      "20-second": "/second/bin\n",
      "10-first": "/first/bin\n",
    ])
    let parts = floor(etcPaths, dir)
    // path_helper reads the directory in order; sorted names must therefore land sorted.
    let first = try XCTUnwrap(parts.firstIndex(of: "/first/bin"))
    let second = try XCTUnwrap(parts.firstIndex(of: "/second/bin"))
    XCTAssertLessThan(first, second)
  }

  /// THE regression test for the filed bug. Postgres.app ships `/etc/paths.d/postgresapp`, which
  /// only `path_helper` reads and only a login shell runs — so before this change a Finder-launched
  /// app never saw it, and every setup script reported "psql not found".
  func testFloorPicksUpPostgresappFragment() throws {
    let etcPaths = try write("/usr/bin\n/bin\n", to: "paths")
    let dir = try pathsDirectory([
      "postgresapp": "/Applications/Postgres.app/Contents/Versions/18/bin\n"
    ])
    XCTAssertTrue(
      floor(etcPaths, dir).contains("/Applications/Postgres.app/Contents/Versions/18/bin"),
      "the floor must resolve psql without ever starting a shell")
  }

  func testFloorSkipsBlankLinesAndComments() throws {
    let etcPaths = try write("# a comment\n\n/usr/bin\n   \n", to: "paths")
    let parts = floor(etcPaths, try pathsDirectory([:]))
    XCTAssertFalse(parts.contains { $0.hasPrefix("#") })
    XCTAssertFalse(parts.contains(""))
    XCTAssertTrue(parts.contains("/usr/bin"))
  }

  func testFloorDedupesKeepingFirstOccurrence() throws {
    let etcPaths = try write("/usr/bin\n", to: "paths")
    let dir = try pathsDirectory(["dup": "/usr/bin\n/extra/bin\n"])
    let parts = floor(etcPaths, dir, inherited: "/usr/bin:/inherited/bin")
    XCTAssertEqual(parts.filter { $0 == "/usr/bin" }.count, 1)
    XCTAssertEqual(parts.first, "/usr/bin")
    XCTAssertTrue(parts.contains("/inherited/bin"))
  }

  func testFloorIncludesWellKnownExtrasWhenSystemFilesAreMissing() {
    let parts = floor("/nonexistent/paths", "/nonexistent/paths.d")
    XCTAssertTrue(parts.contains("/opt/homebrew/bin"))
    XCTAssertTrue(parts.contains("/usr/local/bin"))
  }

  func testFloorNeverReturnsEmpty() {
    let parts = floor("/nonexistent/paths", "/nonexistent/paths.d", inherited: "")
    XCTAssertFalse(parts.isEmpty)
  }

  // MARK: loginShellInvocation

  func testPOSIXShellsGetInteractiveLogin() {
    for shell in ["/bin/zsh", "/bin/bash", "/bin/sh", "/bin/dash", "/usr/local/bin/ksh"] {
      let invocation = ShellEnvironment.loginShellInvocation(script: "echo hi", shell: shell)
      XCTAssertEqual(invocation.argv.executable, shell, shell)
      XCTAssertEqual(invocation.argv.args.first, "-lic", shell)
    }
  }

  /// fish and nushell can't be driven with `-lic`, so they fall back to a login `/bin/sh -lc`.
  /// That still sources `/etc/profile`, so `path_helper` runs and they get the same floor —
  /// only their own rc-set PATH additions are missed. No test covered this branch before, and
  /// extracting the shared helper made it load-bearing for the run command too.
  func testNonPOSIXShellsFallBackToLoginBinSh() {
    for shell in ["/opt/homebrew/bin/fish", "/opt/homebrew/bin/nu", "/bin/csh"] {
      let invocation = ShellEnvironment.loginShellInvocation(script: "echo hi", shell: shell)
      XCTAssertEqual(invocation.argv.executable, "/bin/sh", shell)
      XCTAssertEqual(invocation.argv.args.first, "-lc", shell)
      XCTAssertTrue(invocation.commandString.contains("/bin/sh"), shell)
      XCTAssertTrue(invocation.commandString.contains("-lc"), shell)
    }
  }

  func testLoginShellExecutableMatchesInvocation() {
    XCTAssertEqual(ShellEnvironment.loginShellExecutable(shell: "/bin/zsh"), "/bin/zsh")
    XCTAssertEqual(ShellEnvironment.loginShellExecutable(shell: "/usr/bin/fish"), "/bin/sh")
  }

  func testCommandStringQuotesTheScript() {
    let invocation = ShellEnvironment.loginShellInvocation(
      script: "echo 'hi there'", shell: "/bin/zsh")
    XCTAssertTrue(invocation.commandString.contains("'\\''"), invocation.commandString)
  }

  // MARK: parseProbeOutput

  private func payload(_ pairs: [String], uuid: String, before: String = "", after: String = "")
    -> Data
  {
    var data = Data(before.utf8)
    data.append(Data(uuid.utf8))
    for pair in pairs {
      data.append(Data(pair.utf8))
      data.append(0)
    }
    data.append(Data(uuid.utf8))
    data.append(Data(after.utf8))
    return data
  }

  func testParsesPayloadBetweenMarkers() {
    let uuid = UUID().uuidString
    let parsed = ShellEnvironment.parseProbeOutput(
      payload(["PATH=/usr/bin", "LANG=en_GB.UTF-8"], uuid: uuid), uuid: uuid)
    XCTAssertEqual(parsed?["PATH"], "/usr/bin")
    XCTAssertEqual(parsed?["LANG"], "en_GB.UTF-8")
  }

  /// Noise arrives on BOTH sides: powerlevel10k's instant prompt before, `~/.zlogout`'s `clear`
  /// after. A "last marker pair" rule would take the closing marker plus the trailing junk as the
  /// payload — the after-case is the one that breaks it.
  func testParsesDespiteNoiseBeforeAndAfterTheMarkers() {
    let uuid = UUID().uuidString
    let parsed = ShellEnvironment.parseProbeOutput(
      payload(["PATH=/usr/bin"], uuid: uuid, before: "instant prompt\n", after: "\u{1B}[2J"),
      uuid: uuid)
    XCTAssertEqual(parsed?["PATH"], "/usr/bin")
  }

  func testParseReturnsNilWithoutBothMarkers() {
    let uuid = UUID().uuidString
    XCTAssertNil(ShellEnvironment.parseProbeOutput(Data("no markers here".utf8), uuid: uuid))
    XCTAssertNil(
      ShellEnvironment.parseProbeOutput(Data("\(uuid)PATH=/usr/bin".utf8), uuid: uuid),
      "a single marker is an unterminated payload")
  }

  func testParseReturnsNilForEmptyPayload() {
    let uuid = UUID().uuidString
    XCTAssertNil(ShellEnvironment.parseProbeOutput(payload([], uuid: uuid), uuid: uuid))
  }

  func testParseSkipsEntriesWithoutAnEqualsAndKeepsEqualsInValues() {
    let uuid = UUID().uuidString
    let parsed = ShellEnvironment.parseProbeOutput(
      payload(["PATH=/usr/bin", "JUNK", "RUBYOPT=--enable=frozen"], uuid: uuid), uuid: uuid)
    XCTAssertNil(parsed?["JUNK"])
    XCTAssertEqual(parsed?["RUBYOPT"], "--enable=frozen")
  }

  // MARK: merge

  func testAppOverridesBeatProbedValues() {
    let merged = ShellEnvironment.merge(
      probed: ["PATH": "/usr/bin", "GIT_TERMINAL_PROMPT": "1", "GIT_OPTIONAL_LOCKS": "1"],
      floor: "/usr/bin")
    XCTAssertEqual(merged["GIT_TERMINAL_PROMPT"], "0")
    XCTAssertEqual(merged["GIT_OPTIONAL_LOCKS"], "0")
  }

  /// `WORKROOM_SHELL_PROBE` is the subtle one: we inject it so users can guard expensive rc blocks,
  /// and `env` reports it straight back. Without the denylist every setup script would run with the
  /// flag set, so a script that itself starts a login shell would skip the very blocks it guards.
  func testDenylistDropsShellBookkeepingAndOurOwnMarker() {
    let merged = ShellEnvironment.merge(
      probed: [
        "PATH": "/usr/bin", "PWD": "/Users/x", "OLDPWD": "/tmp", "SHLVL": "3", "_": "/usr/bin/env",
        "WORKROOM_SHELL_PROBE": "1", "RUBYOPT": "--debug",
      ], floor: "/usr/bin")
    for key in ["PWD", "OLDPWD", "SHLVL", "_", "WORKROOM_SHELL_PROBE"] {
      XCTAssertNil(merged[key], key)
    }
    XCTAssertEqual(merged["RUBYOPT"], "--debug", "a real user variable must survive")
  }

  func testMergedPathIsProbedThenFloorDeduped() {
    let merged = ShellEnvironment.merge(
      probed: ["PATH": "/opt/homebrew/bin:/usr/bin"], floor: "/usr/bin:/floor/only")
    XCTAssertEqual(merged["PATH"], "/opt/homebrew/bin:/usr/bin:/floor/only")
  }

  func testMergedPathFallsBackToTheFloorWhenProbeHasNone() {
    let merged = ShellEnvironment.merge(probed: ["LANG": "C"], floor: "/usr/bin:/bin")
    XCTAssertEqual(merged["PATH"], "/usr/bin:/bin")
  }

  // MARK: probe

  func testProbeReadsTheEnvironmentFromARealShell() throws {
    guard case .success(let env) = ShellEnvironment.probe(shell: "/bin/sh") else {
      return XCTFail("probe against /bin/sh should succeed")
    }
    XCTAssertTrue(try XCTUnwrap(env["PATH"]).contains("/usr/bin"))
  }

  /// `path_helper` APPENDS whatever PATH it's handed after `/etc/paths` + `/etc/paths.d`. Hand it
  /// the app's own augmented PATH and Homebrew ends up at the tail — a position it never occupies
  /// in a real terminal — and the merge dedupe then locks `/usr/bin/git` in ahead of
  /// `/opt/homebrew/bin/git`. Starting from the system minimum is what keeps the ordering honest.
  func testProbeIsSpawnedWithAClearedPath() throws {
    let stub = try stubShell(
      reportingEnv: "printf 'PATH=%s' \"$PATH\"", name: "path-reporting-shell")
    guard case .success(let env) = ShellEnvironment.probe(shell: stub) else {
      return XCTFail("stub probe should succeed")
    }
    XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
  }

  func testProbeSetsTheGuardFlagForRcFiles() throws {
    let stub = try stubShell(
      reportingEnv:
        "printf 'PATH=/usr/bin'; printf '\\000'; printf 'SEEN=%s' \"$WORKROOM_SHELL_PROBE\"",
      name: "flag-reporting-shell")
    guard case .success(let env) = ShellEnvironment.probe(shell: stub) else {
      return XCTFail("stub probe should succeed")
    }
    XCTAssertEqual(env["SEEN"], "1", "rc files need a way to detect the probe and skip slow work")
  }

  func testProbeReportsSpawnFailureForAMissingShell() {
    // `/nonexistent/zsh`, not `/nonexistent/shell`: an unrecognised basename is replaced by
    // `/bin/sh`, which exists and would succeed. Only a recognised-but-absent shell reaches
    // the spawn-failure path.
    guard case .failure(let reason) = ShellEnvironment.probe(shell: "/nonexistent/zsh") else {
      return XCTFail("a missing shell must not succeed")
    }
    XCTAssertEqual(reason, .spawnFailed)
  }

  /// The flip side of the naming rule above, and the reason fish and nushell users are not left
  /// stranded: an unrecognised `$SHELL` falls back to `/bin/sh`, which still sources `/etc/profile`
  /// and so still runs `path_helper`.
  func testUnrecognisedShellFallsBackToBinShRatherThanFailing() {
    guard case .success(let env) = ShellEnvironment.probe(shell: "/opt/homebrew/bin/fish") else {
      return XCTFail("an unrecognised shell must fall back to /bin/sh, not fail")
    }
    XCTAssertNotNil(env["PATH"])
  }

  func testProbeReportsNonZeroExit() throws {
    // The `.zshrc`-ends-in-`exec tmux` class: the shell dies before reporting anything.
    let stub = try stubShell("exit 1", name: "failing-shell")
    guard case .failure(let reason) = ShellEnvironment.probe(shell: stub) else {
      return XCTFail("a non-zero shell must not succeed")
    }
    XCTAssertEqual(reason, .nonZeroExit)
  }

  func testProbeReportsMissingMarkers() throws {
    let stub = try stubShell("echo 'no markers at all'", name: "silent-shell")
    guard case .failure(let reason) = ShellEnvironment.probe(shell: stub) else {
      return XCTFail("output without markers must not succeed")
    }
    XCTAssertEqual(reason, .noMarkers)
  }

  /// Two assertions, and the second is the one that matters: the deadline must actually KILL the
  /// child, not merely stop waiting for it. A `withTimeout`-style wrapper would pass the first
  /// assertion and fail this one, leaking a shell and a thread on every create.
  func testProbeTimesOutAndKillsTheChild() throws {
    let stub = try stubShell("sleep 30", name: "wedged-shell")
    let started = Date()
    guard case .failure(let reason) = ShellEnvironment.probe(shell: stub, timeout: 0.5) else {
      return XCTFail("a wedged shell must not succeed")
    }
    XCTAssertEqual(reason, .timedOut)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the deadline did not fire")

    // Nothing of ours may outlive the probe.
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", "wedged-shell"]
    pgrep.standardOutput = Pipe()
    pgrep.standardError = Pipe()
    try pgrep.run()
    pgrep.waitUntilExit()
    XCTAssertNotEqual(pgrep.terminationStatus, 0, "the timed-out probe child is still alive")
  }

  func testProbeRunsFromHomeNotTheAppsWorkingDirectory() throws {
    // An interactive rc can read directory-local tool config (.mise.toml, .nvmrc, .envrc), and a
    // workroom may be a clone we haven't read — so the probe must never stand in one.
    let stub = try stubShell(
      reportingEnv: "printf 'PATH=/usr/bin'; printf '\\000'; printf 'CWD=%s' \"$PWD\"",
      name: "cwd-shell")
    guard case .success(let env) = ShellEnvironment.probe(shell: stub) else {
      return XCTFail("stub probe should succeed")
    }
    XCTAssertEqual(env["CWD"], FileManager.default.homeDirectoryForCurrentUser.path)
  }

  // MARK: Cache, single-flight, generations

  func testPathBeforeAnyRefreshIsTheFloor() {
    XCTAssertEqual(ShellEnvironment.path(), ShellEnvironment.floorPath())
  }

  func testEnvironmentBeforeAnyRefreshCarriesTheFloorAndTheOverrides() {
    let env = ShellEnvironment.environment()
    XCTAssertEqual(env["PATH"], ShellEnvironment.floorPath())
    XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0")
  }

  /// The property is "a failed probe never makes things worse", so it's asserted against whatever
  /// PATH was in force beforehand rather than against `floorPath()` directly — the app's own launch
  /// probe and any earlier test share this process-wide cache, and pinning to the floor would be
  /// asserting who ran first rather than what refresh does.
  func testFailedRefreshDoesNotClobberWhatWeAlreadyHad() async {
    let before = ShellEnvironment.path()
    await ShellEnvironment.refresh(shell: "/nonexistent/zsh")
    XCTAssertEqual(
      ShellEnvironment.path(), before,
      "a failed probe must leave the previous PATH standing, never clear it")
    XCTAssertTrue(
      ShellEnvironment.path().contains("/usr/bin"),
      "and whatever stands must still be a usable PATH")
  }

  /// The dialog warms the probe and Create then awaits it. Without single-flight that's two login
  /// shells racing to write one cache, and the older one can land last.
  func testConcurrentRefreshesShareOneProbe() async throws {
    let counter = tmp.appendingPathComponent("spawns").path
    let stub = try stubShell(
      reportingEnv: "sleep 0.4; printf 'PATH=/probed/bin'",
      prelude: "echo x >> \(counter)", name: "counting-shell")

    async let first = ShellEnvironment.refresh(shell: stub)
    async let second = ShellEnvironment.refresh(shell: stub)
    _ = await (first, second)

    let spawns =
      (try? String(contentsOfFile: counter, encoding: .utf8))?
      .split(separator: "\n").count ?? 0
    XCTAssertEqual(spawns, 1, "concurrent refreshes must share one probe, not race two shells")
    XCTAssertTrue(ShellEnvironment.path().hasPrefix("/probed/bin"))
  }

  func testRefreshStoresTheProbedEnvironment() async throws {
    let stub = try stubShell(
      reportingEnv: "printf 'PATH=/probed/bin'; printf '\\000'; printf 'RUBYOPT=--debug'",
      name: "good-shell")
    await ShellEnvironment.refresh(shell: stub)
    XCTAssertTrue(ShellEnvironment.path().hasPrefix("/probed/bin"))
    XCTAssertEqual(ShellEnvironment.environment()["RUBYOPT"], "--debug")
    XCTAssertEqual(
      ShellEnvironment.environment()["GIT_TERMINAL_PROMPT"], "0", "overrides still applied last")
  }

  func testConcurrentReadsDuringRefreshDoNotCrash() async throws {
    let stub = try stubShell(
      reportingEnv: "sleep 0.2; printf 'PATH=/probed/bin'", name: "slow-shell")
    async let refreshed: Void = { _ = await ShellEnvironment.refresh(shell: stub) }()
    for _ in 0..<200 { _ = ShellEnvironment.path() }
    await refreshed
    XCTAssertFalse(ShellEnvironment.path().isEmpty)
  }

  // MARK: Refresh gating

  /// Config-only `delete-project` runs no teardown, so it must not pay for a shell probe. The
  /// `await` placement itself is only reachable through the bundled binary; the gating decision is
  /// factored out so the part that can be got wrong is the part under test.
  func testOnlyCascadingDeleteProjectModesRunScripts() {
    XCTAssertFalse(
      WorkroomCLI.deleteProjectRunsScripts(withWorkrooms: false, fromDisk: false),
      "config-only removal touches nothing on disk")
    XCTAssertTrue(WorkroomCLI.deleteProjectRunsScripts(withWorkrooms: true, fromDisk: false))
    XCTAssertTrue(WorkroomCLI.deleteProjectRunsScripts(withWorkrooms: false, fromDisk: true))
  }
}
