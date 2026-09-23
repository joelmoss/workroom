import XCTest

@testable import Workroom

/// The shipped Rust binary and the real Swift client, with repositories created only for each test.
final class AgentVCSIntegrationTests: XCTestCase {
  private var roots: [URL] = []
  private var agents: [AgentHarness] = []

  override func tearDown() {
    for agent in agents { agent.stop() }
    for root in roots { try? FileManager.default.removeItem(at: root) }
    agents = []
    roots = []
    super.tearDown()
  }

  private var environment: [String: String] {
    var env = ProcessInfo.processInfo.environment
    // An inherited repository-location override must never redirect a setup command away from
    // the fresh temporary root, same hardening `wr-vcs-git`'s subprocess runner applies.
    for key in [
      "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
      "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    ] {
      env.removeValue(forKey: key)
    }
    env["PATH"] = ShellEnvironment.path()
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_SYSTEM"] = "/dev/null"
    return env
  }
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    return root
  }
  @discardableResult
  private func run(_ tool: String, _ args: [String], at root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + args
    process.environment = environment
    process.currentDirectoryURL = root
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
      XCTFail("\(tool) failed: \(text)")
      throw VCSError.io(text)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private func connect(host: HostID = .local) async throws -> AgentVCSConnection {
    let agent = try AgentHarness.start(environment: environment)
    agents.append(agent)
    return try await AgentVCSConnection.connect(host: host, socketPath: agent.socketPath)
  }
  private func gitRepo() throws -> URL {
    let root = try root()
    try run("git", ["init", "-b", "main"], at: root)
    try run("git", ["config", "user.name", "Test"], at: root)
    try run("git", ["config", "user.email", "test@example.com"], at: root)
    try "base\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    try run("git", ["add", "."], at: root)
    try run("git", ["commit", "-m", "initial"], at: root)
    return root
  }
  private func router(
    root: URL, backend: RepositoryBackend, connection: AgentVCSConnection
  ) async throws -> (RepositoryRouter, RepositoryLocation) {
    let location = try await RepositoryLocation.local(root.path)
    let router = RepositoryRouter(localReader: { try connection.reader(context: $0) })
    try router.register(.init(location: location, backend: backend, sharedLocation: location))
    return (router, location)
  }
  /// As `router(root:backend:connection:)`, but also wires `localWriter` — the write-path tests'
  /// analogue of `reader(for:)`'s existing coverage.
  private func writingRouter(
    root: URL, backend: RepositoryBackend, connection: AgentVCSConnection
  ) async throws -> (RepositoryRouter, RepositoryLocation) {
    let location = try await RepositoryLocation.local(root.path)
    let router = RepositoryRouter(
      localReader: { try connection.reader(context: $0) },
      localWriter: { context in
        try connection.writer(context: context, reader: try connection.reader(context: context))
      })
    try router.register(.init(location: location, backend: backend, sharedLocation: location))
    return (router, location)
  }

  func testAllNineGitReadsMatchNativeProvider() async throws {
    let root = try gitRepo()
    try "next\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    try run(
      "git", ["commit", "-am", "second line\ncontinued\n\nbody", "--date", "2001-01-01T00:00:00Z"],
      at: root)
    let connection = try await connect()
    let (router, location) = try await router(root: root, backend: .git, connection: connection)
    let reader = try await router.reader(for: location)
    let native = BoundLocalReader(context: reader.context, provider: GitProvider())
    let page = try await reader.log(limit: 10)
    let nativePage = try await native.log(limit: 10)
    XCTAssertEqual(page.commits.map(\.commitID), nativePage.commits.map(\.commitID))
    XCTAssertEqual(page.commits.map(\.authors), nativePage.commits.map(\.authors))
    XCTAssertEqual(page.commits.map(\.timestamp), nativePage.commits.map(\.timestamp))
    XCTAssertEqual(page.commits.map(\.summary), nativePage.commits.map(\.summary))
    XCTAssertEqual(page.commits.map(\.body), nativePage.commits.map(\.body))
    XCTAssertEqual(page.commits.map(\.refs), nativePage.commits.map(\.refs))
    XCTAssertEqual(page.reachedEnd, nativePage.reachedEnd)
    let id = try XCTUnwrap(page.commits.first?.commitID)
    let change = try await reader.changeset(commitID: id)
    let nativeChange = try await native.changeset(commitID: id)
    XCTAssertEqual(change.files, nativeChange.files)
    XCTAssertEqual(change.insertions, nativeChange.insertions)
    XCTAssertEqual(change.deletions, nativeChange.deletions)
    let patch = try await reader.fileDiff(commitID: id, path: "file")
    XCTAssertTrue(patch.contains("-base\n+next"))
    let content = try await reader.fileContent(rev: id, path: "file")
    let parent = try await reader.commitParentFileContent(commitID: id, path: "file")
    let base = try await reader.workingBaseFileContent(base: .workingCopy, path: "file")
    XCTAssertEqual(content, "next\n")
    XCTAssertEqual(parent, "base\n")
    XCTAssertEqual(base, "next\n")
    let ref = try await reader.currentRef()
    XCTAssertEqual(ref, VCSRef(name: "main", kind: .branch))
    try "working\n".write(
      to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    let status = try await reader.workingStatus()
    let workingPatch = try await reader.workingFileDiff(path: "file", base: .workingCopy)
    XCTAssertEqual(status.dirty, true)
    XCTAssertEqual(status.insertions, 1)
    XCTAssertEqual(status.deletions, 1)
    XCTAssertTrue(workingPatch.contains("-next\n+working"))
    await connection.close()
  }

  func testAllNineJJReadsAndUnknownOwnership() async throws {
    let root = try root()
    try run("jj", ["git", "init", "--colocate"], at: root)
    try "base\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    try run("jj", ["commit", "-m", "initial"], at: root)
    try "working\n".write(
      to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    let connection = try await connect()
    let (router, location) = try await router(root: root, backend: .jj, connection: connection)
    let reader = try await router.reader(for: location)
    let status = try await reader.workingStatus()
    XCTAssertEqual(status.dirty, true)
    XCTAssertEqual(status.changedFiles?.map(\.path), ["file"])
    let page = try await reader.log(limit: 20)
    let id = try XCTUnwrap(page.commits.first?.commitID)
    let change = try await reader.changeset(commitID: id)
    XCTAssertEqual(change.files.map(\.path), ["file"])
    let patch = try await reader.fileDiff(commitID: id, path: "file")
    let working = try await reader.workingFileDiff(path: "file", base: .workingCopy)
    XCTAssertTrue(patch.contains("-base\n+working"))
    XCTAssertTrue(working.contains("-base\n+working"))
    let content = try await reader.fileContent(rev: id, path: "file")
    let parent = try await reader.commitParentFileContent(commitID: id, path: "file")
    let base = try await reader.workingBaseFileContent(base: .workingCopy, path: "file")
    XCTAssertEqual(content, "working\n")
    XCTAssertEqual(parent, "base\n")
    XCTAssertEqual(base, "base\n")
    _ = try await reader.currentRef()
    let fallback = RepositoryRouter(localReader: { try connection.reader(context: $0) })
    let unknown = try await fallback.reader(for: location)
    _ = try await unknown.log(limit: 1)
    do {
      _ = try await unknown.workingStatus()
      XCTFail("Unknown ownership permitted a snapshot")
    } catch RepositoryRoutingError.registrationRequired {}
    await connection.close()
  }

  func testChunkedReplyAndConcurrentRequests() async throws {
    let root = try gitRepo()
    // Over one envelope after JSON escaping; this must arrive as a single complete patch.
    let large = String(repeating: "0123456789abcdef\n", count: 75000)
    try large.write(to: root.appendingPathComponent("large"), atomically: true, encoding: .utf8)
    try run("git", ["add", "."], at: root)
    try run("git", ["commit", "-m", "large"], at: root)
    let connection = try await connect()
    let (router, location) = try await router(root: root, backend: .git, connection: connection)
    let reader = try await router.reader(for: location)
    let page = try await reader.log(limit: 1)
    let id = try XCTUnwrap(page.commits.first?.commitID)
    async let patch = reader.fileDiff(commitID: id, path: "large")
    async let ref = reader.currentRef()
    let values = try await (patch, ref)
    XCTAssertGreaterThan(values.0.utf8.count, 1 << 20)
    XCTAssertEqual(values.1.name, "main")
    await connection.close()
  }

  func testConnectionLossIsUnavailableAndCannotReturnCleanStatus() async throws {
    let root = try gitRepo()
    let connection = try await connect()
    let (router, location) = try await router(root: root, backend: .git, connection: connection)
    let reader = try await router.reader(for: location)
    await connection.close()
    do {
      _ = try await reader.workingStatus()
      XCTFail("closed channel returned status")
    } catch is HostConnectionError {}
    let status = await WorkroomStatusResolver().resolve(location: location, router: router)
    XCTAssertNil(status.dirty)
    XCTAssertEqual(status.failure, .unavailable)
  }

  func testSamePathRemoteHostsCannotSubstituteConnections() async throws {
    let root = try gitRepo()
    let hostID = UUID()
    let otherID = UUID()
    let host = HostID.remote(hostID)
    let manager = HostConnectionManager()
    let connection = try await connect(host: host)
    _ = try await manager.connect(host: host) { connection }
    let router = RepositoryRouter(connections: manager)
    let location = try RepositoryLocation.remote(host: hostID, path: root.path)
    let otherLocation = try RepositoryLocation.remote(host: otherID, path: root.path)
    try router.register(.init(location: location, backend: .git, sharedLocation: location))
    try router.register(
      .init(location: otherLocation, backend: .git, sharedLocation: otherLocation))
    let reader = try await router.reader(for: location)
    let ref = try await reader.currentRef()
    XCTAssertEqual(ref.name, "main")
    do {
      _ = try await router.reader(for: otherLocation)
      XCTFail("cross-host service")
    } catch RepositoryRoutingError.unavailable {}
    await connection.close()
  }

  func testAgentDeathKeepsSnapshotChildBarrierUntilActualCompletion() async throws {
    let root = try root()
    try run("jj", ["git", "init", "--colocate"], at: root)
    try "base\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    try run("jj", ["commit", "-m", "initial"], at: root)
    try "changed\n".write(
      to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let realJJ = try run("which", ["jj"], at: root)
    let marker = root.appendingPathComponent("accepted")
    let release = root.appendingPathComponent("release")
    let wrapper = bin.appendingPathComponent("jj")
    let quote = CommandLineInstaller.shellQuoted
    let script = """
      #!/bin/sh
      if [ "$1" = diff ]; then
        echo "$$" > \(quote(marker.path))
        attempts=0
        while [ ! -e \(quote(release.path)) ]; do
          attempts=$((attempts + 1))
          [ "$attempts" -lt 500 ] || exit 124
          sleep 0.02
        done
      fi
      exec \(quote(realJJ)) "$@"
      """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    var env = environment
    env["PATH"] = bin.path + ":" + (env["PATH"] ?? "")
    let agent = try AgentHarness.start(environment: env)
    agents.append(agent)
    let connection = try await AgentVCSConnection.connect(
      host: .local, socketPath: agent.socketPath)
    let (router, location) = try await router(root: root, backend: .jj, connection: connection)
    let reader = try await router.reader(for: location)
    let pending = Task { try await reader.workingFileDiff(path: "file", base: .workingCopy) }
    defer { try? Data().write(to: release) }
    let deadline = ContinuousClock.now + .seconds(5)
    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "snapshot CLI never started")
    agent.stop()
    agents.removeLast()
    do {
      _ = try await pending.value
      XCTFail("dead agent returned a patch")
    } catch is HostConnectionError {}
    // Agent is dead; its accepted child still owns the exact barrier native writers use.
    actor Completion {
      var entered = false
      func mark() { entered = true }
    }
    let completion = Completion()
    let native = Task {
      try await JJSnapshotGate().run(repository: location) {
        await completion.mark()
      }
    }
    try await Task.sleep(for: .milliseconds(150))
    let prematurelyEntered = await completion.entered
    XCTAssertFalse(prematurelyEntered)
    try Data().write(to: release)
    try await native.value
    let didEnter = await completion.entered
    XCTAssertTrue(didEnter)
    await connection.close()
  }

  /// A single overdue reply must fail only its own waiter, never the shared connection: the agent's
  /// own bounded waits (JJ snapshot contention, subprocess timeout) can legitimately run at or above
  /// the client's per-request timeout, so treating one slow reply as "the channel is unusable" would
  /// make every other in-flight window's read fail too — see `AgentVCSConnection.request`/`fail`.
  func testOneRequestTimingOutDoesNotDisconnectAnUnrelatedInFlightRequest() async throws {
    let root = try gitRepo()
    try "next\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    try run("git", ["commit", "-am", "second"], at: root)
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let realGit = try run("which", ["git"], at: root)
    let marker = root.appendingPathComponent("accepted")
    let release = root.appendingPathComponent("release")
    let wrapper = bin.appendingPathComponent("git")
    let quote = CommandLineInstaller.shellQuoted
    // Matched by exact positional word, not `$1`: `git()`'s hardening flags land before the
    // caller's own arguments, so the literal `diff` this is standing in for is never first.
    let script = """
      #!/bin/sh
      for arg; do
        if [ "$arg" = diff ]; then
          echo "$$" > \(quote(marker.path))
          attempts=0
          while [ ! -e \(quote(release.path)) ]; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 500 ] || exit 124
            sleep 0.02
          done
          break
        fi
      done
      exec \(quote(realGit)) "$@"
      """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    var env = environment
    env["PATH"] = bin.path + ":" + (env["PATH"] ?? "")
    let agent = try AgentHarness.start(environment: env)
    agents.append(agent)
    let connection = try await AgentVCSConnection.connect(
      host: .local, socketPath: agent.socketPath)
    let (router, location) = try await router(root: root, backend: .git, connection: connection)
    let reader = try await router.reader(for: location)
    defer { try? Data().write(to: release) }
    let page = try await reader.log(limit: 1)
    let id = try XCTUnwrap(page.commits.first?.commitID)
    // Direct on the connection, with a short timeout — `AgentVCSReader` always uses the 30s
    // default, which this test cannot afford to wait out.
    let slowRequest = AgentVCSRequest(
      root: location.path, sharedRoot: location.path, backend: RepositoryBackend.git.rawValue,
      method: "file_diff", revision: id, path: "file")
    let slow = Task { try await connection.request(slowRequest, timeout: 0.2) }
    let deadline = ContinuousClock.now + .seconds(5)
    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "wrapped git never started")
    do {
      _ = try await slow.value
      XCTFail("expected the short per-request timeout to fire while the wrapper is still blocked")
    } catch let error as HostConnectionError {
      // A deadline, not a lost connection: `connect()` sends `.connectionLost` down the respawn
      // path, which cannot fix an agent that is alive but not answering.
      XCTAssertEqual(error, .requestTimedOut)
    }
    // A DIFFERENT, unrelated request on the SAME connection must still succeed — the whole
    // connection was never torn down for one overdue reply.
    let ref = try await reader.currentRef()
    XCTAssertEqual(ref.name, "main")
    // Releasing the wrapper lets the abandoned reply finally arrive; it must drain harmlessly
    // rather than being delivered as a stray/unexpected chunk that kills the connection.
    try Data().write(to: release)
    try await Task.sleep(for: .milliseconds(300))
    let refAgain = try await reader.currentRef()
    XCTAssertEqual(refAgain.name, "main")
    await connection.close()
  }

  /// Before this fix, `request` registered no cancellation handler: cancelling the calling `Task`
  /// did nothing to its suspended continuation, so it stayed in `pending` — occupying one of the
  /// 32 concurrent-request slots — until the request's own 30s timeout finally fired. A cancelled
  /// caller (e.g. a superseded status-sweep read) must fail immediately instead.
  func testCancellingARequestFailsImmediatelyInsteadOfWaitingOutTheTimeout() async throws {
    let root = try gitRepo()
    try "next\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    try run("git", ["commit", "-am", "second"], at: root)
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let realGit = try run("which", ["git"], at: root)
    let marker = root.appendingPathComponent("accepted")
    let release = root.appendingPathComponent("release")
    let wrapper = bin.appendingPathComponent("git")
    let quote = CommandLineInstaller.shellQuoted
    let script = """
      #!/bin/sh
      for arg; do
        if [ "$arg" = diff ]; then
          echo "$$" > \(quote(marker.path))
          attempts=0
          while [ ! -e \(quote(release.path)) ]; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 500 ] || exit 124
            sleep 0.02
          done
          break
        fi
      done
      exec \(quote(realGit)) "$@"
      """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    var env = environment
    env["PATH"] = bin.path + ":" + (env["PATH"] ?? "")
    let agent = try AgentHarness.start(environment: env)
    agents.append(agent)
    let connection = try await AgentVCSConnection.connect(
      host: .local, socketPath: agent.socketPath)
    let (router, location) = try await router(root: root, backend: .git, connection: connection)
    let reader = try await router.reader(for: location)
    defer { try? Data().write(to: release) }
    let page = try await reader.log(limit: 1)
    let id = try XCTUnwrap(page.commits.first?.commitID)
    let slowRequest = AgentVCSRequest(
      root: location.path, sharedRoot: location.path, backend: RepositoryBackend.git.rawValue,
      method: "file_diff", revision: id, path: "file")
    let slow = Task { try await connection.request(slowRequest, timeout: 30) }
    let deadline = ContinuousClock.now + .seconds(5)
    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "wrapped git never started")
    let cancelledAt = ContinuousClock.now
    slow.cancel()
    do {
      _ = try await slow.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
      XCTAssertLessThan(
        cancelledAt.duration(to: .now), .seconds(2),
        "cancellation must fail the request immediately, not wait out its 30s timeout")
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }
    // The connection itself, and the slot the cancelled request freed, both stay usable.
    let ref = try await reader.currentRef()
    XCTAssertEqual(ref.name, "main")
    try Data().write(to: release)
    await connection.close()
  }

  /// A still-running pre-upgrade agent (kept alive because it may own terminals) truthfully
  /// reports its own lower `Hello` version and has no VCS service at all — `AgentVCSConnection`
  /// surfaces that as `VCSError.backendVersion`. The router must serve the read natively rather
  /// than leaving the repository unavailable until the agent is manually restarted.
  func testAgentPredatingVCSSupportFallsBackToNativeReads() async throws {
    let root = try gitRepo()
    let location = try await RepositoryLocation.local(root.path)
    let router = RepositoryRouter(localReader: { _ in
      throw VCSError.backendVersion("Agent predates VCS support.")
    })
    try router.register(.init(location: location, backend: .git, sharedLocation: location))
    let reader = try await router.reader(for: location)
    let ref = try await reader.currentRef()
    XCTAssertEqual(ref.name, "main")
  }

  /// `LocalAgentVCS` had zero coverage — its whole reason to exist is coalescing concurrent callers
  /// racing to connect onto ONE attempt, exactly the class of concurrency bug `macapp/CLAUDE.md`
  /// mandates review for. Injecting `resolveSocketPath`/`binaryURL` (rather than `LocalAgentVCS`'s
  /// hardcoded `PersistentSessionPaths` statics) is what makes this testable in isolation, without
  /// touching the real per-bundle Application Support socket a live Workroom Dev instance might
  /// already own.
  func testConcurrentReadersCoalesceOntoOneConnectAttempt() async throws {
    final class Counter: @unchecked Sendable {
      private let lock = NSLock()
      private var count = 0
      func increment() {
        lock.lock()
        count += 1
        lock.unlock()
      }
      func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
      }
    }
    let root = try gitRepo()
    let agent = try AgentHarness.start(environment: environment)
    agents.append(agent)
    let attempts = Counter()
    let localAgent = LocalAgentVCS(
      manager: HostConnectionManager(),
      resolveSocketPath: {
        attempts.increment()
        return agent.socketPath
      },
      binaryURL: { try? AgentHarness.binaryURL() })
    let location = try await RepositoryLocation.local(root.path)
    let testRouter = RepositoryRouter(localReader: { try await localAgent.reader(context: $0) })
    try testRouter.register(.init(location: location, backend: .git, sharedLocation: location))
    async let first = testRouter.reader(for: location).currentRef()
    async let second = testRouter.reader(for: location).currentRef()
    async let third = testRouter.reader(for: location).currentRef()
    async let fourth = testRouter.reader(for: location).currentRef()
    let refs = try await (first, second, third, fourth)
    XCTAssertEqual(refs.0.name, "main")
    XCTAssertEqual(refs.1.name, "main")
    XCTAssertEqual(refs.2.name, "main")
    XCTAssertEqual(refs.3.name, "main")
    XCTAssertEqual(
      attempts.value(), 1, "four concurrent callers must coalesce onto one connect attempt")
  }

  // MARK: - Writes (#205)

  func testGitCommitRoutesThroughTheAgentAndMatchesNativeReads() async throws {
    let root = try gitRepo()
    try "second\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    let connection = try await connect()
    let (router, location) = try await writingRouter(
      root: root, backend: .git, connection: connection)
    let writer = try await router.writer(for: location)
    let result = await writer.commit(
      request: VCSCommitRequest(
        message: "agent commit",
        files: [ChangedFile(path: "file", change: .modified, oldPath: nil)],
        mode: .commit))
    guard case .ok(_, let revision) = result else {
      XCTFail("commit failed: \(result)")
      return
    }
    XCTAssertNotNil(revision)
    let reader = try await router.reader(for: location)
    let native = BoundLocalReader(context: reader.context, provider: GitProvider())
    let page = try await native.log(limit: 1)
    XCTAssertEqual(page.commits.first?.summary, "agent commit")
    XCTAssertEqual(page.commits.first?.commitID, revision)
    await connection.close()
  }

  /// The property the whole design leans on: the agent-backed writer's `jj commit` runs inside the
  /// SAME `JJSnapshotGate`/`JJProcessBarrier` a native writer would, and the agent's own exec
  /// service must never try to take that barrier a second time — see `vcs.rs`'s
  /// `exec_never_contends_with_a_held_snapshot_barrier` for the Rust-side proof of the same
  /// property. If this ever regressed, the commit below would hang for up to 30s and fail the test
  /// on timeout instead of completing.
  func testJJCommitRoutesThroughTheAgentWithoutContendingItsOwnSnapshotBarrier() async throws {
    let root = try root()
    try run("jj", ["git", "init", "--colocate"], at: root)
    try "base\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    try run("jj", ["commit", "-m", "initial"], at: root)
    try "changed\n".write(
      to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    let connection = try await connect()
    let (router, location) = try await writingRouter(
      root: root, backend: .jj, connection: connection)
    let writer = try await router.writer(for: location)
    let result = await writer.commit(
      request: VCSCommitRequest(message: "agent jj commit", files: [], mode: .commit))
    guard case .ok = result else {
      XCTFail("jj commit failed: \(result)")
      return
    }
    let reader = try await router.reader(for: location)
    let status = try await reader.workingStatus()
    XCTAssertEqual(status.dirty, false)
    let page = try await reader.log(limit: 5)
    XCTAssertTrue(page.commits.contains { $0.summary == "agent jj commit" })
    await connection.close()
  }

  func testPushAndPullRouteThroughTheAgentAgainstARealRemote() async throws {
    let root = try gitRepo()
    let bareRemote = try self.root()
    try run("git", ["init", "--bare", "-b", "main"], at: bareRemote)
    try run("git", ["remote", "add", "origin", bareRemote.path], at: root)
    let connection = try await connect()
    let (router, location) = try await writingRouter(
      root: root, backend: .git, connection: connection)
    let writer = try await router.writer(for: location)
    let pushed = await writer.push(
      current: VCSRef(name: "main", kind: .branch), remote: "origin", setUpstream: true,
      anonymousRevision: "")
    guard case .ok = pushed else {
      XCTFail("push failed: \(pushed)")
      return
    }
    let remoteHead = try run("git", ["rev-parse", "main"], at: bareRemote)
    let localHead = try run("git", ["rev-parse", "HEAD"], at: root)
    XCTAssertEqual(remoteHead, localHead)

    // A second clone pushes a new commit, so this workroom's `fetch`/`pullRebase` have something
    // real to bring in.
    let secondClone = try self.root()
    try run("git", ["clone", bareRemote.path, "."], at: secondClone)
    try run("git", ["config", "user.name", "Test"], at: secondClone)
    try run("git", ["config", "user.email", "test@example.com"], at: secondClone)
    try "from-second-clone\n".write(
      to: secondClone.appendingPathComponent("other"), atomically: true, encoding: .utf8)
    try run("git", ["add", "."], at: secondClone)
    try run("git", ["commit", "-m", "from second clone"], at: secondClone)
    try run("git", ["push", "origin", "main"], at: secondClone)

    let pulled = await writer.pullRebase(
      current: VCSRef(name: "main", kind: .branch), remote: "origin",
      tracking: VCSTracking(comparedTo: "origin/main", ahead: 0, behind: 1, gone: false))
    guard case .ok = pulled else {
      XCTFail("pull failed: \(pulled)")
      return
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("other").path))
    await connection.close()
  }

  /// Selecting a tracked file with no actual diff against `HEAD` classifies as `.nothingToCommit` —
  /// proving a specific, named failure (not just success/failure) survives the wire byte-for-byte,
  /// since it depends on git's own exit code AND stderr text reaching `CLIVCSWriter.classifyCommit`
  /// unmodified.
  func testAFailingAgentCommitClassifiesExactlyAsTheNativeWriterWould() async throws {
    let root = try gitRepo()
    let connection = try await connect()
    let (router, location) = try await writingRouter(
      root: root, backend: .git, connection: connection)
    let writer = try await router.writer(for: location)
    let result = await writer.commit(
      request: VCSCommitRequest(
        message: "nothing changed",
        files: [ChangedFile(path: "file", change: .modified, oldPath: nil)], mode: .commit))
    guard case .failed(.nothingToCommit) = result else {
      XCTFail("expected .nothingToCommit, got \(result)")
      return
    }
    await connection.close()
  }

  /// Mirrors `testAgentPredatingVCSSupportFallsBackToNativeReads`: a still-running pre-upgrade
  /// agent answers `capabilities` with no `writes` field at all, and `RepositoryRouter` must serve
  /// the write natively rather than leaving the repository unwritable.
  func testAgentPredatingVCSWriteSupportFallsBackToNativeWrites() async throws {
    let root = try gitRepo()
    try "second\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    let location = try await RepositoryLocation.local(root.path)
    let router = RepositoryRouter(
      localReader: { _ in throw VCSError.backendVersion("Agent predates VCS support.") },
      localWriter: { _ in throw VCSError.backendVersion("Agent predates VCS write support.") })
    try router.register(.init(location: location, backend: .git, sharedLocation: location))
    let writer = try await router.writer(for: location)
    let result = await writer.commit(
      request: VCSCommitRequest(
        message: "native fallback commit",
        files: [ChangedFile(path: "file", change: .modified, oldPath: nil)], mode: .commit))
    guard case .ok = result else {
      XCTFail("native fallback commit failed: \(result)")
      return
    }
  }

  /// The realistic shape of `testAgentPredatingVCSWriteSupportFallsBackToNativeWrites`'s scenario:
  /// a running agent whose `capabilities` reply has `reads: 9` but no `writes` (or a version the
  /// `writes` count check rejects), so `reader(for:)` resolves through the REAL agent while
  /// `writer(for:)`'s capability check alone fails — leaving the native `CLIVCSWriter` fallback
  /// wired to an agent-sourced `reader`, not a freshly-native one (`RepositoryLocation.swift`'s
  /// `writer(for:)`). A code-review pass flagged that the all-native version above never exercises
  /// this reader/writer-origin mismatch.
  func testWriteCapabilityFallbackWorksWithAnAgentSourcedReader() async throws {
    let root = try gitRepo()
    try "second\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    let connection = try await connect()
    let location = try await RepositoryLocation.local(root.path)
    let router = RepositoryRouter(
      localReader: { try connection.reader(context: $0) },
      localWriter: { _ in throw VCSError.backendVersion("Agent predates VCS write support.") })
    try router.register(.init(location: location, backend: .git, sharedLocation: location))
    // Confirms the reader really is agent-backed, not incidentally also falling back.
    let ref = try await router.reader(for: location).currentRef()
    XCTAssertEqual(ref.name, "main")
    let writer = try await router.writer(for: location)
    let result = await writer.commit(
      request: VCSCommitRequest(
        message: "mixed-origin fallback commit",
        files: [ChangedFile(path: "file", change: .modified, oldPath: nil)], mode: .commit))
    guard case .ok = result else {
      XCTFail("mixed-origin fallback commit failed: \(result)")
      return
    }
    await connection.close()
  }

  /// Both `writer(context:reader:)` guards, which nothing reached before: they are the two ways a
  /// writer can be refused BEFORE any command is built, and each has a distinct caller contract.
  /// Driven through `RepositoryRouter`, which is the only thing that can mint a `RepositoryContext`
  /// — and is the real caller, so this also pins that the router does not swallow either error.
  ///
  /// The host check is the one that matters for correctness rather than tidiness. The router keys on
  /// host-qualified identity precisely so a remote repository cannot collide with a local one at the
  /// same path (#201); a connection answering for another host's context would write to the wrong
  /// machine's repository at a path that exists on both.
  func testAWriterIsRefusedForAnotherHostAndForAClosedConnection() async throws {
    let root = try gitRepo()
    let connection = try await connect()

    // This connection's host is `.local`, so a REMOTE context handed to it must be refused. Wired as
    // the remote factory to get one built at all.
    let elsewhere = try RepositoryLocation.remote(host: UUID(), path: root.path)
    let remoteRouter = RepositoryRouter(
      remoteReader: { try connection.reader(context: $0) },
      remoteWriter: { try connection.writer(context: $0, reader: $1) })
    try remoteRouter.register(
      .init(location: elsewhere, backend: .git, sharedLocation: elsewhere))
    do {
      _ = try await remoteRouter.writer(for: elsewhere)
      XCTFail("a writer was issued for another host's context")
    } catch {
      XCTAssertEqual(error as? HostConnectionError, .mismatchedContext, "got \(error)")
    }

    // Closed: `connectionLost`, NOT `notDispatched`. The distinction is the one P1 #2 established —
    // the refusal happens before anything reaches the socket, but the caller learns it by asking for
    // a writer rather than by a request coming back, so it is a lost connection.
    //
    // It must also NOT be `VCSError.backendVersion`, the one error `writer(for:)` falls back to
    // native writes on: a closed connection is not a pre-upgrade agent, and silently writing
    // natively here would route around a connection the caller believes it is using.
    let location = try await RepositoryLocation.local(root.path)
    let localRouter = RepositoryRouter(
      localReader: { try connection.reader(context: $0) },
      localWriter: { try connection.writer(context: $0, reader: connection.reader(context: $0)) })
    try localRouter.register(.init(location: location, backend: .git, sharedLocation: location))
    await connection.close()
    do {
      _ = try await localRouter.writer(for: location)
      XCTFail("a writer was issued on a closed connection")
    } catch {
      XCTAssertEqual(error as? HostConnectionError, .connectionLost, "got \(error)")
    }
  }

  /// A live agent must actually ROUTE writes, not merely fail to refuse them. Paired with the two
  /// fallback tests above, which cover the refusal: together they pin the DECISION rather than the
  /// capability number that currently encodes it, so replacing that number with an exec-service
  /// check (TODOS item 4) does not invalidate this.
  ///
  /// `localWriter` is the only writer wired and it cannot throw `backendVersion`, so a fallback here
  /// is impossible — the commit below is the agent's own child process or nothing.
  func testACapableAgentRoutesWritesThroughTheAgentRatherThanFallingBack() async throws {
    let root = try gitRepo()
    try "second\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    let connection = try await connect()
    let location = try await RepositoryLocation.local(root.path)
    let router = RepositoryRouter(
      localReader: { try connection.reader(context: $0) },
      localWriter: { try connection.writer(context: $0, reader: connection.reader(context: $0)) })
    try router.register(.init(location: location, backend: .git, sharedLocation: location))

    let result = await (try await router.writer(for: location)).commit(
      request: VCSCommitRequest(
        message: "agent-routed commit",
        files: [ChangedFile(path: "file", change: .modified, oldPath: nil)], mode: .commit))
    guard case .ok = result else { return XCTFail("agent-routed commit failed: \(result)") }

    let log = try run("git", ["log", "-1", "--format=%s"], at: root)
    XCTAssertEqual(log.trimmingCharacters(in: .whitespacesAndNewlines), "agent-routed commit")
    await connection.close()
  }

  /// The write path's transport-failure mapping, end to end through the real client: a write whose
  /// connection dies UNDER it, after the request went out, must classify as `.outcomeUnknown` and
  /// must not offer a retry of itself.
  ///
  /// This is the property the whole `CommandResult.outcomeUnknown` partition exists for, and nothing
  /// exercised it through an actual `VCSWriting` before — the unit tests build the `CommandResult`
  /// by hand, which cannot catch the writer losing the distinction on the way through. The fetch is
  /// held open by a remote that never answers (`ext::sleep`), so the drop lands mid-command.
  func testAWriteOnALostConnectionReportsAnUnknownOutcomeAndOffersNoSelfRetry() async throws {
    let root = try gitRepo()
    try run("git", ["config", "protocol.ext.allow", "always"], at: root)
    try run("git", ["remote", "add", "origin", "ext::sleep 30"], at: root)
    let connection = try await connect()
    let location = try await RepositoryLocation.local(root.path)
    let router = RepositoryRouter(
      localReader: { try connection.reader(context: $0) },
      localWriter: { try connection.writer(context: $0, reader: connection.reader(context: $0)) })
    try router.register(.init(location: location, backend: .git, sharedLocation: location))
    let writer = try await router.writer(for: location)

    let fetch = Task { await writer.fetch(remote: "origin") }
    try await Task.sleep(for: .seconds(1))
    await connection.close()
    let result = await fetch.value
    guard case .failed(let failure) = result else {
      return XCTFail("a write on a lost connection reported success: \(result)")
    }
    // Never `.launchFailed`: that asserts nothing ran, and a dispatched command may well have.
    // Never `.other`: that offers a retry of the verb that failed.
    guard case .outcomeUnknown = failure else {
      return XCTFail("transport failure classified as \(failure)")
    }
    // Fetch is idempotent, so it is offered back — but never escalated to a write.
    XCTAssertEqual(VCSSyncPresenter.retryAction(for: failure, lastAction: .fetch), .fetch)
    XCTAssertEqual(VCSSyncPresenter.retryAction(for: failure, lastAction: .push), .fetch)
    XCTAssertNil(VCSSyncPresenter.retryAction(for: failure, lastAction: nil))
  }

  /// The other half: a write on a connection that was ALREADY closed sent nothing, so it is a plain
  /// refusal with a Retry, not "may have completed". It used to read as an unknown outcome.
  func testAWriteOnAClosedConnectionIsRefusedAsNeverSent() async throws {
    let root = try gitRepo()
    let connection = try await connect()
    let location = try await RepositoryLocation.local(root.path)
    let router = RepositoryRouter(
      localReader: { try connection.reader(context: $0) },
      localWriter: { try connection.writer(context: $0, reader: connection.reader(context: $0)) })
    try router.register(.init(location: location, backend: .git, sharedLocation: location))
    // Obtained while the connection is live, so the failure can only come from the write itself.
    let writer = try await router.writer(for: location)
    await connection.close()

    let result = await writer.fetch(remote: "origin")
    guard case .failed(.other(let reason)) = result else {
      return XCTFail("a write that was never sent is a plain, retryable failure: \(result)")
    }
    XCTAssertTrue(reason.contains("nothing was sent"), reason)
    XCTAssertEqual(VCSSyncPresenter.retryAction(for: .other(reason), lastAction: .push), .push)
  }

  /// A handshake that DROPS must stay `connectionLost` all the way out, because `LocalAgentVCS`
  /// catches exactly that case to spawn wr-agent and retry. Flattening it into `serviceUnavailable`
  /// routed a dropped handshake around the stale-socket recovery entirely — and a stale socket is
  /// the common case, not an exotic one: the daemon leaves `session.sock` behind on any `pkill`.
  ///
  /// The fixture must GREET and then hang up. An earlier version just accepted and closed, which
  /// fails at the greeting read inside `connect`'s `runBlocking` closure and leaves the function
  /// before the `catch` under test — so it passed against the reverted fix. The hello is
  /// `"WRA1"` + a big-endian u16 version + a build-string length byte (`protocol/envelope.rs`).
  func testADroppedHandshakeStaysRecoverableRatherThanBecomingUnavailable() async throws {
    let dir = try root()
    let path = dir.appendingPathComponent("dead.sock").path

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(bound, 0, "could not bind the fixture socket")
    XCTAssertEqual(Darwin.listen(fd, 1), 0)

    // Greet with a version the client accepts (>= 2), no build string, then hang up mid-handshake —
    // after the greeting, before answering `capabilities`.
    let hello: [UInt8] = Array("WRA1".utf8) + [0x00, 0x02, 0x00]
    let accepting = Task.detached {
      let peer = Darwin.accept(fd, nil, nil)
      guard peer >= 0 else { return }
      _ = hello.withUnsafeBytes { Darwin.send(peer, $0.baseAddress, $0.count, 0) }
      Darwin.close(peer)
    }
    defer {
      accepting.cancel()
      Darwin.close(fd)
    }

    do {
      _ = try await AgentVCSConnection.connect(host: .local, socketPath: path)
      XCTFail("a connection was negotiated against a socket that hung up")
    } catch {
      XCTAssertEqual(
        error as? HostConnectionError, .connectionLost,
        "a dropped handshake must stay recoverable, got \(error)")
    }
  }

  /// The regression this closes: `StatusCommandRunning.run(stdin:)` exists partly to sidestep
  /// `E2BIG`, and routing through a single un-chunked envelope reintroduced a ceiling — a LOWER one,
  /// since every NUL in the pathspec escapes to six bytes on the wire. "Select all and commit" in a
  /// large repository therefore worked natively and failed through the agent.
  ///
  /// Drives a real commit whose pathspec payload exceeds one envelope, through the real client and
  /// the bundled agent, and asserts the commit actually recorded every file.
  func testACommitWhosePathspecExceedsOneEnvelopeStillCommits() async throws {
    let root = try gitRepo()
    // Long names so the payload clears 1 MiB well before the file count gets slow to create.
    let padding = String(repeating: "p", count: 180)
    var files: [ChangedFile] = []
    for index in 0..<6000 {
      let name = "\(padding)-\(index).txt"
      try "x\n".write(
        to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
      // `.untracked`, not `.added`: that is what a new file on disk reports, and it is what routes
      // this through the intent-to-add step — whose payload is the SECOND oversized request this
      // exercises, since it carries the same paths.
      files.append(ChangedFile(path: name, change: .untracked, oldPath: nil))
    }
    // The payload `CLIVCSWriter` will send, measured the way the wire measures it.
    let payloadBytes = files.map(\.path).joined(separator: "\0").utf8.count
    XCTAssertGreaterThan(
      payloadBytes, 1 << 20,
      "the fixture no longer exceeds one envelope, so this proves nothing")

    let connection = try await connect()
    let location = try await RepositoryLocation.local(root.path)
    let router = RepositoryRouter(
      localReader: { try connection.reader(context: $0) },
      localWriter: { try connection.writer(context: $0, reader: connection.reader(context: $0)) })
    try router.register(.init(location: location, backend: .git, sharedLocation: location))

    let result = await (try await router.writer(for: location)).commit(
      request: VCSCommitRequest(message: "chunked commit", files: files, mode: .commit))
    guard case .ok = result else { return XCTFail("chunked commit failed: \(result)") }

    // Recorded, and recorded IN FULL: a truncated payload would commit a prefix and still report ok.
    let subject = try run("git", ["log", "-1", "--format=%s"], at: root)
    XCTAssertEqual(subject.trimmingCharacters(in: .whitespacesAndNewlines), "chunked commit")
    let counted = try run("git", ["show", "--name-only", "--format=", "HEAD"], at: root)
      .split(whereSeparator: \.isNewline).count
    XCTAssertEqual(counted, files.count, "the commit recorded a truncated pathspec")
    await connection.close()
  }
}
