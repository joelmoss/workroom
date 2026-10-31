import Foundation
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// Counts real status-probe subprocesses, with a hermetic gh script instead of network traffic.
private final class StatusProbeRecorder: StatusCommandRunning, @unchecked Sendable {
  private let script: String
  private let lock = NSLock()
  private var calls: [(String, Int32)] = []

  init(script: String) { self.script = script }

  func reset() { lock.withLock { calls.removeAll() } }

  var counts: [String: Int] {
    lock.withLock {
      calls.reduce(into: [:]) { result, call in result[call.0, default: 0] += 1 }
    }
  }

  var failures: Int { lock.withLock { calls.filter { $0.1 != 0 }.count } }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    let result: CommandResult
    if executable == "gh" {
      result = await StatusCommandRunner().run(
        "/bin/sh", [script] + args, in: directory, timeout: timeout)
    } else {
      result = await StatusCommandRunner().run(executable, args, in: directory, timeout: timeout)
    }
    let command = executable == "git" && args.first == "-c" ? Array(args.dropFirst(2)) : args
    let key = ([executable] + command.prefix(executable == "gh" ? 2 : 1)).joined(separator: " ")
    lock.withLock { calls.append((key, result.exitCode)) }
    return result
  }
}

@MainActor
final class StatusSweepBenchmarkTests: XCTestCase {
  private struct Fixture: Sendable {
    let directory: URL
    let store: AppStore
    let recorder: StatusProbeRecorder
    let project: Project
  }

  private func fixture(workrooms: Int) async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workroom-status-benchmark-\(UUID().uuidString)", isDirectory: true
    )
    .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let root = directory.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let runner = StatusCommandRunner()
    let environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    func git(_ args: [String]) async throws {
      let result = await runner.run(
        "/usr/bin/git", args, in: root.path, timeout: 10, environment: environment)
      guard result.ok else {
        throw NSError(domain: "StatusSweepBenchmark", code: Int(result.exitCode))
      }
    }
    try await git(["init", "-b", "main"])
    try await git([
      "-c", "user.name=Benchmark", "-c", "user.email=benchmark@example.invalid", "commit",
      "--allow-empty", "-m", "fixture",
    ])
    var rooms: [Workroom] = []
    for index in 0..<workrooms {
      let name = "room-\(index)"
      let path = directory.appendingPathComponent(name).path
      // An identity, or git looks up the hostname for one, which can outlast the timeout above.
      try await git([
        "-c", "user.name=Benchmark", "-c", "user.email=benchmark@example.invalid", "worktree",
        "add", "-b", name, path,
      ])
      rooms.append(Workroom(name: name, path: path, vcsName: "git", warnings: []))
    }
    let script = directory.appendingPathComponent("gh.sh")
    try """
    case "$1 $2" in
      'auth status') printf '%s\\n' '{"hosts":{"github.com":[{"state":"success","active":true}]}}' ;;
      'repo view') printf '%s\\n' 'https://github.com/fixture/status' ;;
      'api graphql') printf '%s\\n' '{"data":{"repository":{"object":{"statusCheckRollup":{"state":"SUCCESS"}}}}}' ;;
      'pr list') printf '%s\\n' '[{"number":9,"title":"Fixture","state":"OPEN","isDraft":false,"url":"https://github.com/fixture/status/pull/9","reviewDecision":null}]' ;;
      'pr checks') printf '%s\\n' '[{"name":"build","bucket":"pass"}]' ;;
      *) exit 2 ;;
    esac
    """.write(to: script, atomically: true, encoding: .utf8)
    let project = Project(path: root.path, vcs: "git", workrooms: rooms)
    let store = AppStore(
      cli: FakeWorkroomCLI(canonical: root.path, projects: [project]),
      remoteState: RemoteStateModel(
        makeWriter: { _ in FixtureVCSWriter() }, autoFetchInterval: .greatestFiniteMagnitude))
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "no sessions in status benchmark") },
      ownership: { _ in .notOwned })
    let recorder = StatusProbeRecorder(script: script.path)
    store.statusResolver = WorkroomStatusResolver(runner: recorder)
    return Fixture(directory: directory, store: store, recorder: recorder, project: project)
  }

  private func cleanUp(_ fixture: Fixture) async {
    let store = fixture.store
    store.statusSweepTask?.cancel()
    store.selectionStatusTask?.cancel()
    store.watchRefreshTask?.cancel()
    store.workroomFileWatcher.stop()
    store.projects = []
    store.updateRootBranchWatches()
    await store.statusSweepTask?.value
    await store.selectionStatusTask?.value
    await store.watchRefreshTask?.value
    await store.terminals.reapAll()
    try? FileManager.default.removeItem(at: fixture.directory)
  }

  func testSelectionsReuseFreshCIForTheSameCommit() async throws {
    let fixture = try await fixture(workrooms: 1)
    addTeardownBlock { await self.cleanUp(fixture) }
    let store = fixture.store
    store.projects = [fixture.project]
    RepositoryRouter.shared.replaceLocal(try await RepositoryRouter.prepare(store.projects))
    var firstCheckedAt: Date?
    for sid in [
      SidebarID.root(project: fixture.project.path),
      .workroom(project: fixture.project.path, name: "room-0"),
    ] {
      store.selectedTargetID = sid
      await store.selectionStatusTask?.value
      XCTAssertEqual(store.workroomStatuses[sid]?.ci, .passing)
      XCTAssertEqual(store.workroomStatuses[sid]?.pr?.number, 9)
      if let firstCheckedAt {
        XCTAssertEqual(
          store.workroomStatuses[sid]?.ciCheckedAt, firstCheckedAt,
          "selecting a row must not extend the original CI result's five-minute lifetime")
      } else {
        firstCheckedAt = store.workroomStatuses[sid]?.ciCheckedAt
      }
    }
    XCTAssertEqual(
      fixture.recorder.counts["gh api graphql"], 1,
      "the same repository/commit CI result should be reused across fresh selections")
    XCTAssertEqual(fixture.recorder.counts["gh pr list"], 2, "PR details must still refresh")
    XCTAssertEqual(fixture.recorder.counts["gh pr checks"], 2, "PR checks must still refresh")
  }

  func testStatusSubprocessCounts() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run make app-bench-status")
    let fixture = try await fixture(workrooms: 20)
    addTeardownBlock { await self.cleanUp(fixture) }
    let store = fixture.store
    let recorder = fixture.recorder
    let output = BenchmarkFixtures.reportURL(named: "status-sweep")
    var phases: [[String: Any]] = []
    let start = ContinuousClock.now
    await store.bootstrap(restore: false)
    try await Task.sleep(until: start.advanced(by: .seconds(10)), clock: .continuous)
    await store.statusSweepTask?.value
    phases.append([
      "phase": "launch_first_10_seconds", "commands": recorder.counts,
      "nonzero_exits": recorder.failures,
      "listing_generations": store.projectStore.latestLoad?.generation ?? 0,
      "resolved_items": store.workroomStatuses.count,
    ])
    recorder.reset()
    await store.reloadIfStale()
    await store.statusSweepTask?.value
    phases.append(["phase": "focus_at_10_seconds", "commands": recorder.counts])
    for index in [0, 1, 0] {
      recorder.reset()
      store.selectedTargetID = .workroom(project: fixture.project.path, name: "room-\(index)")
      await store.selectionStatusTask?.value
      phases.append([
        "phase": "select_room_\(index)", "commands": recorder.counts,
        "nonzero_exits": recorder.failures,
      ])
      XCTAssertEqual(
        store.selectedTargetID.flatMap { store.workroomStatuses[$0]?.pr?.number }, 9)
    }
    try BenchmarkFixtures.write(
      ["configuration": "Debug", "items": 21, "gh": "local subprocess fixture", "phases": phases],
      to: output)
  }

  func testNewCommitsAndManualRefreshStillQueryCI() async throws {
    let fixture = try await fixture(workrooms: 1)
    addTeardownBlock { await self.cleanUp(fixture) }
    let store = fixture.store
    store.projects = [fixture.project]
    RepositoryRouter.shared.replaceLocal(try await RepositoryRouter.prepare(store.projects))
    store.selectedTargetID = .root(project: fixture.project.path)
    await store.selectionStatusTask?.value
    XCTAssertEqual(fixture.recorder.counts["gh api graphql"], 1)

    let commit = await StatusCommandRunner().run(
      "/usr/bin/git",
      [
        "-c", "user.name=Benchmark", "-c", "user.email=benchmark@example.invalid", "commit",
        "--allow-empty", "-m", "new tip",
      ], in: fixture.project.path, timeout: 10,
      environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    XCTAssertTrue(commit.ok)
    store.scheduleSelectedStatusRefresh()
    await store.selectionStatusTask?.value
    XCTAssertEqual(
      fixture.recorder.counts["gh api graphql"], 2,
      "a new HEAD on the same branch must never reuse the old commit's CI")

    store.refreshWorkroomStatuses(force: true)
    await store.statusSweepTask?.value
    XCTAssertEqual(
      fixture.recorder.counts["gh api graphql"], 4,
      "manual Refresh must query both root and workroom even with cached CI")
  }

  func testIgnoredFileBatchesDoNotSpawnStatusCommandsLocally() async throws {
    let fixture = try await fixture(workrooms: 1)
    addTeardownBlock { await self.cleanUp(fixture) }
    let store = fixture.store
    try "ignored/\n".write(
      toFile: fixture.project.path + "/.git/info/exclude", atomically: true, encoding: .utf8)
    store.projects = [fixture.project]
    RepositoryRouter.shared.replaceLocal(try await RepositoryRouter.prepare(store.projects))
    let sid = SidebarID.workroom(project: fixture.project.path, name: "room-0")
    store.selectedTargetID = sid
    await store.selectionStatusTask?.value
    store.workroomFileWatcher.stop()
    fixture.recorder.reset()
    let path = fixture.project.workrooms[0].path + "/ignored/output.txt"
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    for index in 0..<3 {
      try "build output \(index)\n".write(toFile: path, atomically: true, encoding: .utf8)
      // Delivered batches are the consumer seam: OS notification/coalescing is not timed here.
      store.handleWorkroomFileChange([path])
      await store.watchRefreshTask?.value
    }
    XCTAssertEqual(store.workroomStatuses[sid]?.dirty, false, "Git ignores the generated output")
    let visible = fixture.project.workrooms[0].path + "/source.txt"
    try "visible edit\n".write(toFile: visible, atomically: true, encoding: .utf8)
    store.handleWorkroomFileChange([visible])
    await store.watchRefreshTask?.value
    XCTAssertEqual(
      store.workroomStatuses[sid]?.dirty, true, "the native refresh must still detect real edits")
    XCTAssertTrue(
      fixture.recorder.counts.isEmpty,
      "local filesystem refreshes must stay on the native read path and never query GitHub")
  }
}
