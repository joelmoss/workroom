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

  /// The rc's one job, against the real zsh: a session run with the prepared folder as `ZDOTDIR`
  /// writes no history into it. Without `unset HISTFILE`, `/etc/zshrc` puts `.zsh_history` there.
  func testRealZshWritesNothingIntoTheFolder() throws {
    let directory = UITestFixture.hermeticZDOTDIR(bundleID: "com.example.test", in: root)
    try UITestFixture.prepareHermeticZDOTDIR(at: directory)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-i"]
    process.environment = [
      "HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm", "ZDOTDIR": directory.path,
    ]
    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    stdin.fileHandleForWriting.write(Data("echo hi\nexit\n".utf8))
    try stdin.fileHandleForWriting.close()
    process.waitUntilExit()

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path), [".zshrc"],
      "zsh wrote something into the hermetic ZDOTDIR")
  }
}
