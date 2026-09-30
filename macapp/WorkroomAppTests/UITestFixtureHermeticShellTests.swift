import XCTest

@testable import Workroom

/// The hermetic shell a UI-test launch gives its terminals (issue #268): Ghostty's zsh integration,
/// none of the developer's rc files. These pin the seam's decisions; the terminal-level proof is
/// `TerminalHermeticShellUITests`.
final class UITestFixtureHermeticShellTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "workroom-hermetic-shell-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func apply(
    active: Bool = true, bundleID: String? = "com.example.test"
  ) throws -> (applied: Bool, environment: [String: String]) {
    var environment: [String: String] = [:]
    let applied = try UITestFixture.applyHermeticShell(
      active: active, bundleID: bundleID, root: root, set: { environment[$0] = $1 })
    return (applied, environment)
  }

  func testUILaunchSetsShellAndZDOTDIR() throws {
    let result = try apply()
    XCTAssertTrue(result.applied)
    XCTAssertEqual(result.environment["SHELL"], "/bin/zsh")
    let directory = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    XCTAssertEqual(result.environment["ZDOTDIR"], directory.path)
    XCTAssertEqual(Set(result.environment.keys), ["SHELL", "ZDOTDIR"], "nothing else is touched")
  }

  /// A hosted unit run, a release build and a plain launch all take this path: the process
  /// environment must be left alone and no folder created.
  func testNotAUILaunchTouchesNothing() throws {
    let result = try apply(active: false)
    XCTAssertFalse(result.applied)
    XCTAssertTrue(result.environment.isEmpty)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
  }

  /// Ghostty sources the redirected `.zshenv`, `.zprofile` and `.zlogin`, so anything left by an
  /// earlier run would execute on every later launch. The folder holds exactly one file.
  func testFolderIsResetToOnlyTheGeneratedRC() throws {
    let directory = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in [".zshenv", ".zprofile", ".zlogin", ".zsh_history", ".zshrc"] {
      try Data("echo stray\n".utf8).write(to: directory.appendingPathComponent(name))
    }
    try files.createDirectory(
      at: directory.appendingPathComponent("nested", isDirectory: true),
      withIntermediateDirectories: true)

    _ = try apply()

    XCTAssertEqual(try files.contentsOfDirectory(atPath: directory.path), [".zshrc"])
    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent(".zshrc"), encoding: .utf8),
      UITestFixture.hermeticShellRC, "a stray .zshrc is overwritten, not kept")
  }

  /// The path is predictable and the reset deletes what it lists, so a symlink planted there would
  /// aim the deletion at someone else's directory. It is refused, and the target is left alone.
  func testSymlinkedFolderIsRefusedAndItsTargetIsUntouched() throws {
    let files = FileManager.default
    let target = root.appendingPathComponent("someone-elses-directory", isDirectory: true)
    try files.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
    let link = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    try files.createSymbolicLink(at: link, withDestinationURL: target)

    XCTAssertThrowsError(try apply()) { error in
      guard case .folderIsSymlink = error as? UITestFixture.HermeticShellError else {
        return XCTFail("expected folderIsSymlink, got \(error)")
      }
    }

    XCTAssertEqual(try files.contentsOfDirectory(atPath: target.path), ["keep.txt"])
  }

  /// A symlink whose target is gone still is not a folder we made.
  func testDanglingSymlinkIsRefused() throws {
    let link = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: root.appendingPathComponent("gone", isDirectory: true))

    XCTAssertThrowsError(try apply()) { error in
      guard case .folderIsSymlink = error as? UITestFixture.HermeticShellError else {
        return XCTFail("expected folderIsSymlink, got \(error)")
      }
    }
  }

  /// Something that is not a directory sits at the folder path: not ours to replace.
  func testARegularFileAtTheFolderPathIsRefused() throws {
    let path = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    try Data("not a directory".utf8).write(to: path)

    XCTAssertThrowsError(try apply()) { error in
      guard case .folderNotOurs = error as? UITestFixture.HermeticShellError else {
        return XCTFail("expected folderNotOurs, got \(error)")
      }
    }
    XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "not a directory")
  }

  /// A `.zshrc` that is a symlink is removed, not followed: zsh would source whatever it points at.
  func testASymlinkedZshrcIsReplacedAndItsTargetIsUntouched() throws {
    let files = FileManager.default
    let directory = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("elsewhere.zsh")
    try Data("keep".utf8).write(to: target)
    try files.createSymbolicLink(
      at: directory.appendingPathComponent(".zshrc"), withDestinationURL: target)

    _ = try apply()

    let rc = directory.appendingPathComponent(".zshrc")
    XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: rc.path))
    XCTAssertEqual(try String(contentsOf: rc, encoding: .utf8), UITestFixture.hermeticShellRC)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
  }

  /// An earlier version created the folder 0755. Ours, so it is tightened, not refused.
  func testAnOwnedFolderWithLooseModeIsTightened() throws {
    let files = FileManager.default
    let directory = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    try files.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

    _ = try apply()

    let mode = try XCTUnwrap(
      files.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int)
    XCTAssertEqual(mode & 0o777, 0o700)
  }

  /// `.zshrc` is exempt from the sweep, so a leftover that is not a regular file would never be
  /// cleaned: a directory there would make the write fail on every launch.
  func testANonRegularZshrcIsReplacedWithTheGeneratedFile() throws {
    let files = FileManager.default
    let directory = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    try files.createDirectory(
      at: directory.appendingPathComponent(".zshrc", isDirectory: true),
      withIntermediateDirectories: true)

    _ = try apply()

    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent(".zshrc"), encoding: .utf8),
      UITestFixture.hermeticShellRC)
  }

  /// A launch that finds the rc already correct must not rewrite it: an atomic write replaces the
  /// file, and a second launch of the same bundle id sweeping the folder could then delete the
  /// first one's temporary file mid-write and crash it. Same inode = untouched.
  func testAnAlreadyCorrectRCIsNotRewritten() throws {
    _ = try apply()
    let rc = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
      .appendingPathComponent(".zshrc")
    func inode() throws -> Int {
      try XCTUnwrap(
        FileManager.default.attributesOfItem(atPath: rc.path)[.systemFileNumber] as? Int)
    }
    let before = try inode()

    _ = try apply()

    XCTAssertEqual(try inode(), before)
  }

  /// The bundle id lands in a path component, so it must stay one.
  func testBundleIDIsKeptToOneSafePathComponent() {
    let directory = UITestFixture.hermeticZDOTDIR(bundleID: "a/b/../c d", in: root)
    XCTAssertEqual(directory.deletingLastPathComponent(), root)
    XCTAssertEqual(directory.lastPathComponent, "workroom-tests-zdotdir-a_b_.._c_d")
  }

  /// No bundle id would put every such launch in one folder, defeating the per-identity split.
  func testMissingBundleIDFailsRatherThanSharingAFolder() throws {
    XCTAssertThrowsError(try apply(bundleID: nil))
  }

  /// zsh sources `.zshrc.zwc` INSTEAD of `.zshrc` when it is newer, so a stray compiled file would
  /// run on every launch while the generated `.zshrc` (and every assertion on it) looked right.
  func testAStrayCompiledZshrcIsRemoved() throws {
    let directory = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("compiled".utf8).write(to: directory.appendingPathComponent(".zshrc.zwc"))

    _ = try apply()

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(".zshrc.zwc").path))
  }

  /// The `.zshrc*` exemption exists so another launch's in-flight atomic-write temp file survives
  /// the sweep. Pinned so narrowing it to `== ".zshrc"` cannot go unnoticed.
  func testAnotherLaunchsTemporaryZshrcSiblingSurvivesTheSweep() throws {
    let directory = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sibling = directory.appendingPathComponent(".zshrc.tmp-in-flight")
    try Data("x".utf8).write(to: sibling)

    _ = try apply()

    XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
  }

  /// A stray symlink entry (`.zshenv -> somewhere`) is removed, never followed.
  func testAStrayStartupFileSymlinkIsRemovedWithoutFollowingIt() throws {
    let files = FileManager.default
    let directory = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("outside.zsh")
    try Data("keep".utf8).write(to: target)
    try files.createSymbolicLink(
      at: directory.appendingPathComponent(".zshenv"), withDestinationURL: target)

    _ = try apply()

    XCTAssertNil(try? files.destinationOfSymbolicLink(atPath: directory.path + "/.zshenv"))
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
  }

  /// Too strict is as unusable as too loose: the sweep or the write would fail on every launch.
  func testAnOwnedFolderThatIsTooStrictIsRepaired() throws {
    let files = FileManager.default
    let directory = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    try files.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])

    _ = try apply()

    let mode = try XCTUnwrap(
      files.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int)
    XCTAssertEqual(mode & 0o777, 0o700)
  }

  func testEachBundleIDGetsItsOwnFolder() throws {
    let first = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.one", in: root)
    let second = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.two", in: root)
    XCTAssertNotEqual(first, second)
  }

  /// If the folder cannot be prepared the environment must stay untouched AND the caller must be
  /// told: `WorkroomApp.init` turns the throw into a crash, because carrying on would run the
  /// developer's real rc files.
  func testFailureThrowsAndSetsNothing() throws {
    let notADirectory = root.appendingPathComponent("a-file")
    try Data().write(to: notADirectory)
    var environment: [String: String] = [:]
    XCTAssertThrowsError(
      try UITestFixture.applyHermeticShell(
        active: true, bundleID: "com.example.test", root: notADirectory,
        set: { environment[$0] = $1 }))
    XCTAssertTrue(environment.isEmpty)
  }

  /// Run an interactive `/bin/zsh` on `echo hi; exit` with `directory` as `ZDOTDIR`, and fail rather
  /// than hang if it does not come back.
  @discardableResult
  private func runInteractiveZsh(zdotdir directory: URL) throws -> (status: Int32, output: String) {
    let timeout: TimeInterval = 20
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-i"]
    process.environment = [
      "HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm", "ZDOTDIR": directory.path,
    ]
    let stdin = Pipe()
    process.standardInput = stdin
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    // Throwing write: the legacy `write(_:)` raises an Objective-C exception on EPIPE, which would
    // take the whole hosted test process down instead of failing one test.
    try stdin.fileHandleForWriting.write(contentsOf: Data("echo hi\nexit\n".utf8))
    try stdin.fileHandleForWriting.close()
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      // SIGKILL: an interactive zsh ignores SIGTERM.
      kill(process.processIdentifier, SIGKILL)
      _ = exited.wait(timeout: .now() + 5)
      XCTFail("zsh did not exit within \(Int(timeout))s")
    }
    let text =
      String(
        data: (try? output.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
    return (process.terminationStatus, text)
  }

  /// The rc's one job, against the real zsh: a session run with the prepared folder as `ZDOTDIR`
  /// writes no history into it. Without `unset HISTFILE`, `/etc/zshrc` puts `.zsh_history` there.
  func testRealZshWritesNothingIntoTheFolder() throws {
    let directory = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    try UITestFixture.prepareHermeticZDOTDIR(at: directory)

    let run = try runInteractiveZsh(zdotdir: directory)

    // The session has to have RUN: a zsh that died at startup would leave the folder untouched and
    // make the assertion below pass without proving anything.
    XCTAssertEqual(run.status, 0)
    XCTAssertTrue(run.output.contains("hi"), "the zsh session did not run its command")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path), [".zshrc"],
      "zsh wrote something into the hermetic ZDOTDIR")
  }

  /// The control for the test above: the same session with an EMPTY `.zshrc` does write history
  /// here. Where it does not (a customised `/etc/zshrc`, a future macOS), the test above would pass
  /// without proving anything, so this is skipped visibly rather than left silently green.
  func testControlZshWithoutTheRCWritesHistory() throws {
    let directory = root.appendingPathComponent("control", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data().write(to: directory.appendingPathComponent(".zshrc"))

    try runInteractiveZsh(zdotdir: directory)

    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(".zsh_history").path),
      "this machine's zsh does not write history here, so the test above proves nothing on it")
  }

  // MARK: The launch probe

  func testLaunchProbeRunsOnlyOutsideUnitRunsAndUILaunches() {
    XCTAssertTrue(UITestFixture.runsLaunchShellProbe(environment: [:], isUILaunch: false))
    XCTAssertFalse(UITestFixture.runsLaunchShellProbe(environment: [:], isUILaunch: true))
    XCTAssertFalse(
      UITestFixture.runsLaunchShellProbe(
        environment: ["XCTestConfigurationFilePath": "/x.xctestconfiguration"], isUILaunch: false))
    XCTAssertFalse(
      UITestFixture.runsLaunchShellProbe(
        environment: ["XCTestConfigurationFilePath": "/x.xctestconfiguration"], isUILaunch: true))
  }
}
