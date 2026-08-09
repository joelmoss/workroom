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
  ) throws -> (status: Int32, stderr: String) {
    let process = Process()
    process.executableURL = try ghosttyLink()
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment
      .merging(["XDG_STATE_HOME": stateHome.path]) { _, new in new }

    let errPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = errPipe
    try process.run()
    // Drain before waiting: a pipe that fills would deadlock a process we then wait on.
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: errData, as: UTF8.self))
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
}
