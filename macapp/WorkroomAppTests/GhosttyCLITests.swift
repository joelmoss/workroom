import XCTest

@testable import Workroom

/// `Contents/MacOS/ghostty` is a relative symlink to the app binary, which makes this one binary
/// also Ghostty's `+action` CLI (libghostty carries the whole action set — see
/// `Resources/ghostty/SOURCE.md`). Ghostty's bundled shell integration calls
/// `"$GHOSTTY_BIN_DIR/ghostty" +ssh-cache` on every `ssh` when `ssh-terminfo` is enabled, and the
/// engine sets `GHOSTTY_BIN_DIR` itself to the running executable's directory.
///
/// Everything about that arrangement fails **silently**: a missing symlink, a wrong `argv[0]`
/// branch, or a broken dispatch all just mean `ssh-terminfo` users quietly re-push terminfo on
/// every connect. Nothing errors and nothing logs. Hence this suite.
///
/// Kept separate from `GhosttyResourcesTests`, whose contract is the `Resources/ghostty` byte
/// manifest — these tests share no setup with it (they reach for `executableURL`, not
/// `resourceURL`) and spawn processes, which a manifest checker should not.
final class GhosttyCLITests: XCTestCase {
  /// `Contents/MacOS`, resolved from what actually shipped rather than from a build setting.
  private func macOSDir() throws -> URL {
    try XCTUnwrap(
      Bundle.main.executableURL?.deletingLastPathComponent(),
      "the test host must have an executable — without it there is no Contents/MacOS to check")
  }

  private func ghosttyLink() throws -> URL {
    try macOSDir().appendingPathComponent("ghostty")
  }

  /// Run the shipped `ghostty` with a throwaway `XDG_STATE_HOME`.
  ///
  /// The isolation is load-bearing, not hygiene theatre: `+ssh-cache` reads and writes
  /// `${XDG_STATE_HOME}/ghostty/ssh_cache` (upstream `src/cli/ssh-cache/DiskCache.zig`, which
  /// defaults to `~/.local/state`). Without the override, `make app-test` would read — and once
  /// `--add` is exercised, permanently alter — the developer's own ssh terminfo cache.
  @discardableResult
  private func runGhostty(
    _ arguments: [String], stateHome: URL, file: StaticString = #filePath, line: UInt = #line
  ) throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = try ghosttyLink()
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment
      .merging(["XDG_STATE_HOME": stateHome.path]) { _, new in new }

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    // Drain before waiting: a pipe that fills would deadlock a process we then wait on.
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      process.terminationStatus, String(decoding: outData, as: UTF8.self),
      String(decoding: errData, as: UTF8.self)
    )
  }

  private func makeStateHome() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ghostty-cli-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  /// The symlink must exist, be a symlink, and be **relative** — an absolute target breaks the
  /// moment the bundle is copied or mounted from the DMG.
  func testGhosttySymlinkIsEmbedded() throws {
    let link = try ghosttyLink()
    let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
    XCTAssertEqual(
      attributes[.type] as? FileAttributeType, .typeSymbolicLink,
      "Contents/MacOS/ghostty must be a symlink to the app binary")

    let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    XCTAssertFalse(
      target.hasPrefix("/"),
      "the ghostty symlink must be relative; an absolute target breaks in a copied or mounted bundle"
    )

    let executableName = try XCTUnwrap(Bundle.main.executableURL?.lastPathComponent)
    XCTAssertEqual(
      target, executableName,
      "the symlink must point at this configuration's app binary (Workroom / Workroom Dev / Nightly)"
    )
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: link.path),
      "the ghostty symlink must resolve to something runnable")
  }

  /// The real test of dispatch: not that a process exited 0, but that the action reached code that
  /// wrote the cache. An exit-0-only assertion would still pass if `+ssh-cache` silently no-opped.
  func testGhosttyRunsSshCacheActionAndWritesCache() throws {
    let stateHome = try makeStateHome()

    XCTAssertEqual(try runGhostty(["+ssh-cache"], stateHome: stateHome).status, 0)
    XCTAssertEqual(
      try runGhostty(["+ssh-cache", "--add=example.com"], stateHome: stateHome).status, 0)

    let cache = stateHome.appendingPathComponent("ghostty/ssh_cache")
    let contents = try String(contentsOf: cache, encoding: .utf8)
    XCTAssertTrue(
      contents.contains("example.com"),
      "the +ssh-cache action must have written the host into \(cache.path); got: \(contents)")
  }

  /// A cache **miss** exits non-zero, and the shell wrapper branches on exactly that. Uses the
  /// `--host=` form `Resources/ghostty/shell-integration/bash/ghostty.bash` uses, so this exercises
  /// a miss rather than the argument parser.
  func testGhosttyPropagatesCacheMissExitCode() throws {
    let stateHome = try makeStateHome()
    let result = try runGhostty(["+ssh-cache", "--host=never-seen.example"], stateHome: stateHome)
    XCTAssertEqual(
      result.status, 1,
      "a cache miss must exit non-zero — the shell wrapper falls through to infocmp on it")
  }

  /// `+ssh` is the action `shell-integration/{bash,zsh}` now call (the inline wrapper was replaced
  /// upstream around 2026-05-04/05 — see `Resources/ghostty/SOURCE.md`), and it does not exist at
  /// all before that: the old pin this bump replaces has no `+ssh` action, so grepping the OLD
  /// vendored scripts finds no such call. Mirrors `testGhosttyRunsSshCacheActionAndWritesCache`'s
  /// exit-0 assertion (`release.sh:212-216` asserts `+ssh-cache` dispatch on the shipped artifact
  /// the same way), plus a stdout-content check — proving the *help* subcommand actually ran,
  /// rather than merely exiting 0 the way a no-op could.
  func testGhosttySshHelpDispatches() throws {
    let stateHome = try makeStateHome()
    let result = try runGhostty(["+ssh", "--help"], stateHome: stateHome)
    XCTAssertEqual(result.status, 0, "`+ssh --help` must exit 0; stderr: \(result.stderr)")
    XCTAssertTrue(
      result.stdout.contains("Wrap `ssh`"),
      "expected +ssh's own help text, not a generic/empty response; got: \(result.stdout)")
    XCTAssertTrue(
      result.stdout.contains("--terminfo"),
      "expected the --terminfo flag documented, confirming this is +ssh's real help and not a "
        + "stale cached string; got: \(result.stdout)")
  }

  /// An unknown action fails in `ghostty_init` (which parses and stores it), before
  /// `ghostty_cli_try_action` ever runs. `main.swift` turns that into a message and exit 1.
  func testGhosttyRejectsInvalidAction() throws {
    let stateHome = try makeStateHome()
    let result = try runGhostty(["+definitely-not-an-action"], stateHome: stateHome)
    XCTAssertEqual(result.status, 1)
    XCTAssertTrue(
      result.stderr.contains("invalid action"),
      "an unknown +action should be reported, not silently ignored; got: \(result.stderr)")
  }

  /// Invoked as `ghostty` with no action, we must identify ourselves and exit — **not** fall
  /// through and launch a second Workroom. The engine puts `Contents/MacOS` on every pane's PATH,
  /// so this binary shadows a real Ghostty.app inside Workroom; a user who types `ghostty` deserves
  /// to be told which binary answered.
  func testGhosttyBareInvocationIdentifiesItself() throws {
    let stateHome = try makeStateHome()
    let result = try runGhostty([], stateHome: stateHome)
    XCTAssertEqual(result.status, 1)
    XCTAssertTrue(
      result.stderr.contains("Workroom"),
      "a bare `ghostty` must name Workroom so the shadowing is diagnosable; got: \(result.stderr)")
    XCTAssertTrue(
      result.stderr.contains("+actions"),
      "it should also say what this binary can do; got: \(result.stderr)")
  }

  /// Regression cover for the entry-point restructure: under its real name, with no `+action`, the
  /// binary must take the app path. `main.swift` branches on `argv[0]`, so a mistake there would
  /// make the GUI unlaunchable — or worse, make every app launch exit 1.
  ///
  /// Asserted indirectly: the app path is what the test host itself took to run this suite. If the
  /// `argv[0]` branch were wrong for the real executable name, this bundle would never have loaded.
  func testAppBinaryTakesTheAppPath() throws {
    let executableName = try XCTUnwrap(Bundle.main.executableURL?.lastPathComponent)
    XCTAssertNotEqual(
      executableName, "ghostty",
      "the app binary must not be named `ghostty`, or every launch would take the CLI branch")
    XCTAssertTrue(
      executableName.hasPrefix("Workroom"),
      "expected the app path to be running this suite, got executable name: \(executableName)")
  }

  // MARK: - Shell-integration `ssh` wrapper (issue: the fake-ssh regression cover)

  /// A stub `ssh` on `PATH`, ahead of the real one, that just echoes its argv to stderr and exits
  /// 0. `testGhosttySshHelpDispatches` above proves `+ssh --help` dispatches; this closes the gap
  /// that leaves: that `+ssh` — and the shell FUNCTION that calls it, which is exactly what this
  /// bump's resource regeneration rewrote — actually translates `GHOSTTY_SHELL_FEATURES` into the
  /// right flags and env, without a real network round-trip to a real host.
  private func makeStubSSH() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ghostty-fake-ssh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appendingPathComponent("ssh")
    try "#!/bin/bash\necho \"FAKE_SSH_ARGS: $@\" >&2\nexit 0\n".write(
      to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return dir
  }

  /// Sources the real vendored `bash/ghostty.bash` and calls its `ssh` function — the actual shipped
  /// bytes `GhosttyResourcesTests` pins, not a hand-copied approximation of the wrapper logic.
  ///
  /// The script hard-gates on interactive mode (`[[ "$-" != *i* ]] && return`), since it expects to
  /// run as part of a real shell startup — hence `bash -i`. `--norc --noprofile` keep that from also
  /// loading the actual developer's `.bashrc`, which has nothing to do with what's under test here.
  @discardableResult
  private func runShellWrapperSSH(
    features: String, sshArgs: [String], file: StaticString = #filePath, line: UInt = #line
  ) throws -> (status: Int32, stderr: String) {
    let script = try XCTUnwrap(
      Bundle.main.resourceURL?
        .appendingPathComponent("ghostty/shell-integration/bash/ghostty.bash").path)
    let fakeSSHDir = try makeStubSSH()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
      "--norc", "--noprofile", "-i", "-c",
      "source '\(script)'; ssh \(sshArgs.joined(separator: " "))",
    ]
    process.environment = ProcessInfo.processInfo.environment.merging([
      "GHOSTTY_SHELL_FEATURES": features,
      "GHOSTTY_BIN_DIR": try macOSDir().path,
      "PATH": fakeSSHDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""),
    ]) { _, new in new }

    let errPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = errPipe
    try process.run()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: errData, as: UTF8.self))
  }

  /// Both `ssh-env` and `ssh-terminfo` on: the real `ssh` must be called with env-forwarding flags
  /// AND the host/port args passed through untouched. `+ssh` also attempts a terminfo install
  /// against the stub over a `ControlMaster` connection, which fails harmlessly (the stub isn't a
  /// real ssh) and logs a warning — that warning, not the actual `ssh` call, is what's ignored here.
  func testShellIntegrationSshWrapperForwardsEnvWhenEnabled() throws {
    let result = try runShellWrapperSSH(
      features: "ssh-env,ssh-terminfo", sshArgs: ["myhost.example", "-p", "2222"])
    XCTAssertTrue(
      result.stderr.contains("FAKE_SSH_ARGS:"),
      "the stub ssh was never invoked at all; got: \(result.stderr)")
    XCTAssertTrue(
      result.stderr.contains("SetEnv=TERM=xterm-256color")
        && result.stderr.contains("SendEnv=COLORTERM"),
      "ssh-env was enabled, so env-forwarding flags must reach the real ssh call; got: \(result.stderr)"
    )
    XCTAssertTrue(
      result.stderr.contains("myhost.example") && result.stderr.contains("-p 2222"),
      "the original ssh args must pass through unchanged; got: \(result.stderr)")
  }

  /// `ssh-terminfo` only (no `ssh-env`): the wrapper must translate that into `--forward-env=false`,
  /// which `+ssh` must honour by NOT adding the `SetEnv`/`SendEnv` flags to the real `ssh` call —
  /// proving the flag actually suppresses forwarding, not just that it was accepted.
  func testShellIntegrationSshWrapperSkipsEnvForwardingWhenDisabled() throws {
    let result = try runShellWrapperSSH(features: "ssh-terminfo", sshArgs: ["myhost.example"])
    XCTAssertTrue(
      result.stderr.contains("FAKE_SSH_ARGS:"),
      "the stub ssh was never invoked at all; got: \(result.stderr)")
    XCTAssertFalse(
      result.stderr.contains("SetEnv=") || result.stderr.contains("SendEnv="),
      "ssh-env was NOT enabled, so no env-forwarding flags should reach the real ssh call; "
        + "got: \(result.stderr)")
  }

  /// No `ssh-*` feature at all: the wrapper function must not even be defined, so a plain `ssh`
  /// resolves straight to whatever is on `PATH` — proving the gate itself, not just its flag
  /// translation, since a wrapper that always ran (even as a no-op) would still be a behavior change
  /// from upstream's un-integrated `ssh`.
  func testShellIntegrationSshWrapperIsUndefinedWithoutFeature() throws {
    let script = try XCTUnwrap(
      Bundle.main.resourceURL?
        .appendingPathComponent("ghostty/shell-integration/bash/ghostty.bash").path)
    let fakeSSHDir = try makeStubSSH()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["--norc", "--noprofile", "-i", "-c", "source '\(script)'; type -t ssh"]
    process.environment = ProcessInfo.processInfo.environment.merging([
      "GHOSTTY_SHELL_FEATURES": "",
      "PATH": fakeSSHDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""),
    ]) { _, new in new }
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()
    try process.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let out = String(decoding: outData, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    XCTAssertEqual(
      out, "file",
      "without an ssh-* feature, `ssh` must resolve to the PATH binary (`type -t` reports \"file\"), "
        + "not a shell function — got: \(out)")
  }
}
