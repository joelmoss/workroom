import DaemonConnection
import WorkroomDomain
import WorkroomGit
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// The commit cases of WorkroomGit's `VCSCommitIntegrationTests` that need the app: a daemon lost
/// while staging, classified by the app's `DaemonCommandRunner`, and the store handing the
/// preflight to the dialog. The same throwaway repositories, isolated from the developer's own git
/// config; they never touch a real repository.
final class VCSCommitIntegrationTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  // MARK: helpers

  private struct MissingTool: Error { let name: String }

  private func requireTool(_ name: String) throws {
    if sh("command -v \(name)", in: NSTemporaryDirectory()).exit != 0 {
      XCTFail("`\(name)` is required for integration tests (brew install \(name))")
      throw MissingTool(name: name)
    }
  }

  private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "wr-commit-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    dirs.append(d)
    return d
  }

  @discardableResult
  private func sh(_ cmd: String, in dir: String) -> (out: String, exit: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    var env = ProcessInfo.processInfo.environment
    // Isolate from the developer's own git config, including any commit.gpgsign or hooksPath that
    // would otherwise make these tests depend on the machine they run on.
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_SYSTEM"] = "/dev/null"
    env["GIT_AUTHOR_NAME"] = "T"
    env["GIT_AUTHOR_EMAIL"] = "t@e.com"
    env["GIT_COMMITTER_NAME"] = "T"
    env["GIT_COMMITTER_EMAIL"] = "t@e.com"
    env["PATH"] = ShellEnvironment.path()
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
  }

  /// A git repo with one commit and the named files tracked.
  private func gitRepo(files: [String: String] = ["base.txt": "base\n"]) -> String {
    let dir = tempDir()
    sh("git init -q . && git config user.email t@e.com && git config user.name T", in: dir)
    for (name, contents) in files { write(contents, to: name, in: dir) }
    sh("git add -A && git commit -qm base", in: dir)
    return dir
  }

  private func write(_ contents: String, to name: String, in dir: String) {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? contents.write(to: url, atomically: true, encoding: .utf8)
  }

  /// The files touched by HEAD, one per line, so an assertion can name exactly what landed.
  private func committedFiles(_ dir: String) -> [String] {
    sh("git show --name-only --format= HEAD", in: dir).out
      .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }.sorted()
  }

  // MARK: A daemon lost while staging

  /// The real runner, except that the intent-to-add step loses contact with the daemon.
  private struct StagingLosesContact: StatusCommandRunning {
    let real = StatusCommandRunner()

    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      await run(executable, args, in: directory, timeout: timeout, stdin: nil)
    }

    func run(
      _ executable: String, _ args: [String], in directory: String, timeout: TimeInterval,
      stdin: Data?
    ) async -> CommandResult {
      if args.contains("--intent-to-add") {
        return DaemonCommandRunner.outcomeUnknown(HostConnectionError.connectionLost)
      }
      return await real.run(executable, args, in: directory, timeout: timeout, stdin: stdin)
    }
  }

  /// A lost staging step is not a lost commit: the commit was never sent, so the dialog must not
  /// say it may have been written (which also spends the Commit button).
  func testLosingContactWhileStagingIsNotAnUnknownCommit() async throws {
    try requireTool("git")
    let dir = gitRepo()
    write("fresh\n", to: "untracked.txt", in: dir)
    let staging = CLIVCSWriter(
      runner: StagingLosesContact(),
      makeProvider: { _ in GitProvider() as LocalVCSProviding },
      gate: RepositoryWriteGate(maxChainWait: 5))

    let result = await staging.commit(
      path: dir, projectRoot: dir,
      request: VCSCommitRequest(
        message: "never sent",
        files: [ChangedFile(path: "untracked.txt", change: .untracked)], mode: .commit))

    guard case .failed(.other(let reason)) = result else {
      return XCTFail("a commit that was never sent is a plain failure: \(result)")
    }
    XCTAssertTrue(reason.contains("nothing was committed"), reason)
    XCTAssertEqual(committedFiles(dir), ["base.txt"])
  }

  // MARK: The preflight reaching the dialog

  /// The pre-flight reaching the DIALOG, not just the writer.
  ///
  /// Every other commit integration test drives `CLIVCSWriter` directly, which leaves the shipped
  /// feature — `CommitSheet` asking the store, the store asking the writer — with no coverage at
  /// all. Measured, not assumed: replacing `AppStore.commitPreflight`'s body with
  /// `completion(.none)` left all 2615 tests green while the dialog opened permanently blank for
  /// every user. That is the fourth time this session a change landed somewhere nothing exercised,
  /// so the wiring gets its own test rather than a comment.
  ///
  /// Driven through the real `reload()` with a faked CLI, so what is asserted is the observable
  /// outcome of a listing landing: the store resolves the work item, builds a writer for it, and
  /// hands back what the repo actually says.
  @MainActor
  func testTheStoreDeliversThePreflightToTheDialog() async throws {
    let dir = gitRepo()
    sh("git commit -q --allow-empty -m 'the subject the dialog shows'", in: dir)
    FileManager.default.createFile(atPath: dir + "/.git/MERGE_HEAD", contents: Data())
    defer { RepositoryRouter.shared.replaceLocal([]) }

    let store = AppStore(
      cli: StubPreflightCLI(listed: Project(path: dir, vcs: "git", workrooms: [])))
    await store.reload()

    let response: Result<VCSCommitPreflight, Error> = await withCheckedContinuation {
      continuation in
      store.commitPreflight(on: .root(project: dir)) { continuation.resume(returning: $0) }
    }
    let preflight = try response.get()

    XCTAssertEqual(
      preflight.sequencer, "merge", "the parked-merge warning never reached the dialog")
    XCTAssertTrue(
      preflight.amendTarget?.contains("the subject the dialog shows") == true,
      "the amend target never reached the dialog, got: \(String(describing: preflight.amendTarget))"
    )
  }
}

/// A CLI that answers `list` with one fixed project and does nothing else.
private struct StubPreflightCLI: WorkroomCLIProtocol {
  let listed: Project

  func list(warnings: String, project: String?) async throws -> ListResponse {
    ListResponse(projects: [listed], workroomsDir: nil, configPath: nil)
  }
  func addProject(_ path: String, create: Bool) async throws -> String { listed.path }
  func create(
    project: String, onLog: ((String) -> Void)?, onReady: ((String, String, Bool) -> Void)?
  ) async throws -> CreateResponse {
    CreateResponse(name: "", path: "", vcs: "git", project: project)
  }
  func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {}
  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
  ) async throws -> [URL] { [] }
}
