import XCTest

@testable import Workroom

/// The File service end to end: the shipped Rust agent, the real Swift client, real repositories and
/// real filesystem changes. Mirrors `AgentVCSIntegrationTests`, and is where the two halves of the
/// wire contract (`file.rs`/`watch.rs` and `AgentFileProvider`/`AgentVCSConnection`) are proven to agree.
final class AgentFileIntegrationTests: XCTestCase {
  private var roots: [URL] = []
  private var agents: [AgentHarness] = []
  private var fakes: [FakeAgent] = []
  private var connections: [AgentVCSConnection] = []

  override func tearDown() {
    for agent in agents { agent.stop() }
    for fake in fakes { fake.stop() }
    for root in roots { try? FileManager.default.removeItem(at: root) }
    agents = []
    fakes = []
    roots = []
    connections = []
    super.tearDown()
  }

  // MARK: Fixtures

  private var environment: [String: String] {
    var env = ProcessInfo.processInfo.environment
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

  private func gitRepo() throws -> URL {
    let root = try root()
    try run("git", ["init", "-b", "main"], at: root)
    try run("git", ["config", "user.name", "Test"], at: root)
    try run("git", ["config", "user.email", "test@example.com"], at: root)
    return root
  }

  private func connect() async throws -> (AgentVCSConnection, AgentHarness) {
    let agent = try AgentHarness.start(environment: environment)
    agents.append(agent)
    let connection = try await AgentVCSConnection.connect(
      host: .local, socketPath: agent.socketPath)
    connections.append(connection)
    return (connection, agent)
  }

  private func context(_ root: URL, shared: Bool = false) async throws -> FileContext {
    let location = try await RepositoryLocation.local(root.path)
    return FileContext(location: location, sharedLocation: shared ? location : nil)
  }

  private func agentFiles(_ root: URL, connection: AgentVCSConnection) async throws -> FileProviding
  {
    try connection.files(context: try await context(root))
  }

  // MARK: Negotiation

  func testAnAgentWithTheFileServiceNegotiatesItAndVCSStillWorks() async throws {
    let (connection, _) = try await connect()
    let root = try gitRepo()
    let fileContext = try await context(root)
    XCTAssertNoThrow(try connection.files(context: fileContext))
    // The VCS reads that shipped before the File service are untouched by its negotiation.
    let location = try await RepositoryLocation.local(root.path)
    let router = RepositoryRouter()
    try router.register(.init(location: location, backend: .git, sharedLocation: location))
    let reader = try connection.reader(context: try router.registeredContext(for: location))
    XCTAssertEqual(reader.context.location, location)
    await connection.close()
  }

  /// AC2: a protocol-2 agent silently DROPS File envelopes, so the version is checked against the raw
  /// greeting before any is sent. Proven against a stand-in that records every service byte it gets.
  func testAProtocol2AgentIsNeverSentAFileEnvelopeAndReportsBackendVersion() async throws {
    let fake = try FakeAgent(version: 2)
    fakes.append(fake)
    let connection = try await AgentVCSConnection.connect(
      host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    let root = try gitRepo()
    let fileContext = try await context(root)
    XCTAssertThrowsError(try connection.files(context: fileContext)) { error in
      guard case VCSError.backendVersion = error else {
        return XCTFail("expected backendVersion, got \(error)")
      }
    }
    // Negotiation happened (VCS answered) and File was never spoken.
    XCTAssertEqual(Set(fake.receivedServices), [2], "only VCS envelopes may reach a v2 agent")
    await connection.close()
  }

  /// A protocol-3 peer HAS the service, so a probe that goes unanswered is a transient failure, not
  /// proof of an old agent. Reporting `backendVersion` here silently selected native access for the
  /// connection's whole life; it must be an explicit failure (and retire the connection so the next
  /// acquisition probes again).
  func testAV3AgentThatNeverAnswersTheFileProbeIsAFailureNotAnOldAgent() async throws {
    let fake = try FakeAgent(version: 3)
    fakes.append(fake)
    let connection = try await AgentVCSConnection.connect(
      host: .local, socketPath: fake.socketPath)
    connections.append(connection)
    XCTAssertTrue(fake.receivedServices.contains(3), "a protocol-3 peer is probed")
    let root = try gitRepo()
    let fileContext = try await context(root)
    XCTAssertThrowsError(try connection.files(context: fileContext)) { error in
      XCTAssertEqual(
        error as? HostConnectionError,
        .serviceUnavailable("File service negotiation failed; reconnecting."))
    }
  }

  /// The viewer's "too large" state and the agent's read ceiling are two literals in two languages.
  /// If the viewer's cap rose alone, every open between them would fail as "File unavailable" instead
  /// of showing the too-large state. Read from the agent's own capabilities reply.
  func testTheViewersReadCapIsTheAgentsReadCeiling() async throws {
    let (connection, _) = try await connect()
    let reply = try await connection.fileRequest(AgentFileRequest(method: "capabilities"))
    let capabilities = try AgentFileReply<AgentFileCapabilities>.decode(reply)
    XCTAssertEqual(capabilities.maxReadBytes, PlainFileViewer.maxBytes)
    XCTAssertEqual(capabilities.version, 1)
  }

  /// A local host never loses its files to its agent: whatever stops the agent being obtained, the
  /// router hands back a provider that lists and reads natively, and `watch` THROWS (so the watcher
  /// keeps trying the agent) instead of returning nil (which would read as "never").
  func testALocalHostNeverLosesItsFilesToItsAgent() async throws {
    let root = try gitRepo()
    try "x\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let location = try await RepositoryLocation.local(root.path)

    let failures: [Error] = [
      VCSError.backendVersion("old agent"), HostConnectionError.connectionLost,
      HostConnectionError.requestTimedOut, RepositoryRoutingError.unavailable(.local),
    ]
    for failure in failures {
      let router = RepositoryRouter(localFiles: { _ in throw failure })
      let files = try await router.files(for: location)
      let listing = try await files.list(.git)
      XCTAssertEqual(FileListing.parse(listing.stdout, vcs: .git), ["a.txt"], "\(failure)")
      let data = try await files.read(path: "a.txt", symlinks: .refuse, maxBytes: 100)
      XCTAssertEqual(data, Data("x\n".utf8), "\(failure)")
      do {
        _ = try await files.watch(root: root.path) { _ in }
        XCTFail("watch must throw while the agent is unavailable, got nil or a handle")
      } catch { XCTAssertTrue(error is HostConnectionError, "\(error)") }
    }

    // No agent configured at all (every test router): plain native, and `watch` is nil.
    let native = try await RepositoryRouter().files(for: location)
    XCTAssertTrue(native is NativeFileProvider)
    let handle = try await native.watch(root: root.path) { _ in }
    XCTAssertNil(handle)

    // Cancellation is the one thing that propagates: retrying work its caller abandoned helps nobody.
    let cancelled = RepositoryRouter(localFiles: { _ in throw CancellationError() })
    do {
      _ = try await cancelled.files(for: location)
      XCTFail("a cancelled acquisition must propagate")
    } catch { XCTAssertTrue(error is CancellationError) }

    // A REMOTE host has no native path: unavailability stays an explicit failure.
    let remote = try RepositoryLocation.remote(host: UUID(), path: "/private/tmp")
    do {
      _ = try await RepositoryRouter(localFiles: { _ in throw VCSError.backendVersion("old") })
        .files(for: remote)
      XCTFail("a remote host must never get a native provider")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .unavailable(remote.host)) }
  }

  /// The agent dying MID-SESSION: a provider that was working starts failing at the transport level,
  /// and the same idempotent request is re-run natively instead of failing the panel.
  func testAnAgentThatDiesMidSessionFallsBackToNativeForListingAndReading() async throws {
    let (connection, agent) = try await connect()
    let root = try gitRepo()
    try "x\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let location = try await RepositoryLocation.local(root.path)
    let router = RepositoryRouter(localFiles: { try connection.files(context: $0) })
    let files = try await router.files(for: location)

    let before = try await files.list(.git)
    XCTAssertEqual(FileListing.parse(before.stdout, vcs: .git), ["a.txt"], "served by the agent")

    agent.stop()
    let after = try await files.list(.git)
    XCTAssertEqual(FileListing.parse(after.stdout, vcs: .git), ["a.txt"], "served natively")
    let data = try await files.read(path: "a.txt", symlinks: .refuse, maxBytes: 100)
    XCTAssertEqual(data, Data("x\n".utf8))
  }

  func testAFileServiceIsBoundToItsHostAndRefusedOnAClosedConnection() async throws {
    let (connection, _) = try await connect()
    let root = try gitRepo()
    let foreign = FileContext(
      location: try RepositoryLocation.remote(host: UUID(), path: "/private/tmp"),
      sharedLocation: nil)
    XCTAssertThrowsError(try connection.files(context: foreign)) {
      XCTAssertEqual($0 as? HostConnectionError, .mismatchedContext)
    }
    let files = try await agentFiles(root, connection: connection)
    await connection.close()
    let fileContext = try await context(root)
    XCTAssertThrowsError(try connection.files(context: fileContext)) {
      XCTAssertEqual($0 as? HostConnectionError, .connectionLost)
    }
    // A provider that outlived its connection fails explicitly rather than returning empty data.
    do {
      _ = try await files.list(.git)
      XCTFail("a closed connection must fail")
    } catch { XCTAssertEqual(error as? HostConnectionError, .connectionLost) }
  }

  // MARK: Listing

  func testAgentListingMatchesTheNativeListingForGitIncludingAwkwardNames() async throws {
    let (connection, _) = try await connect()
    let root = try gitRepo()
    try ".build/\n".write(
      to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".build"), withIntermediateDirectories: true)
    for name in ["tracked.txt", "untracked.txt", "with space.txt", "with\nnewline.txt", "café.txt"]
    {
      try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try "x".write(
      to: root.appendingPathComponent(".build/ignored.o"), atomically: true, encoding: .utf8)
    try run("git", ["add", ".gitignore", "tracked.txt"], at: root)

    let context = try await context(root)
    let agent = try connection.files(context: context)
    let native = NativeFileProvider(context: context)
    let viaAgent = try await agent.list(.git)
    let viaNative = try await native.list(.git)
    XCTAssertEqual(viaAgent.exitCode, 0)
    XCTAssertEqual(
      FileListing.parse(viaAgent.stdout, vcs: .git), FileListing.parse(viaNative.stdout, vcs: .git))
    XCTAssertFalse(viaAgent.stdout.contains("ignored.o"))
    XCTAssertTrue(viaAgent.stdout.contains("with\nnewline.txt"))
  }

  func testListingOutsideARepositoryIsTheToolsOwnFailureOnBothPaths() async throws {
    let (connection, _) = try await connect()
    let root = try root()
    let context = try await context(root)
    let viaAgent = try await connection.files(context: context).list(.git)
    let viaNative = try await NativeFileProvider(context: context).list(.git)
    XCTAssertNotEqual(viaAgent.exitCode, 0)
    XCTAssertEqual(viaAgent.exitCode, viaNative.exitCode)
  }

  func testAnUnregisteredJJListingIsRefusedBeforeAnythingIsSent() async throws {
    let (connection, _) = try await connect()
    let root = try gitRepo()
    let files = try await agentFiles(root, connection: connection)  // sharedLocation == nil
    do {
      _ = try await files.list(.jj)
      XCTFail("an unregistered jj listing must not reach the agent")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .registrationRequired) }
  }

  /// D12: over the capture cap is a typed failure, never a short list. The native cap is injectable;
  /// the agent's 4 MiB cap is proven in `file_service.rs` against a 22,000-file repository.
  func testANativeListingOverTheCaptureCapIsATypedFailure() async throws {
    let root = try gitRepo()
    for index in 0..<50 {
      try "x".write(
        to: root.appendingPathComponent("file-number-\(index).txt"), atomically: true,
        encoding: .utf8)
    }
    let context = try await context(root)
    let capped = NativeFileProvider(context: context, runner: StatusCommandRunner(maxBytes: 100))
    do {
      _ = try await capped.list(.git)
      XCTFail("a truncated listing must throw")
    } catch { XCTAssertEqual(error as? FileServiceError, .listingTruncated) }

    let whole = try await NativeFileProvider(context: context).list(.git)
    XCTAssertFalse(whole.stdoutTruncated)
    let result = await FileTreeModel.list(
      location: context.location, runner: StatusCommandRunner(maxBytes: 100),
      router: RepositoryRouter())
    XCTAssertEqual(result, .tooLarge)
  }

  // MARK: Reading

  func testAReadRoundTripsBytesIncludingAMultiEnvelopeReply() async throws {
    let (connection, _) = try await connect()
    let root = try gitRepo()
    let bytes = Data((0..<2_500_000).map { UInt8($0 % 251) })
    try bytes.write(to: root.appendingPathComponent("big.bin"))
    try Data().write(to: root.appendingPathComponent("empty"))
    let files = try await agentFiles(root, connection: connection)
    let big = try await files.read(path: "big.bin", symlinks: .refuse, maxBytes: 8 * 1024 * 1024)
    XCTAssertEqual(big, bytes)
    let empty = try await files.read(path: "empty", symlinks: .refuse, maxBytes: 10)
    XCTAssertTrue(empty.isEmpty)
  }

  /// One matrix, run against BOTH providers: a check that exists on one path and not the other is the
  /// bug (the native path used to check a path and then open it, and never guarded against a FIFO).
  func testTheContainmentMatrixHoldsOnTheAgentPath() async throws {
    let (connection, _) = try await connect()
    let root = try gitRepo()
    try await assertContainmentMatrix(
      try await agentFiles(root, connection: connection), root: root)
  }

  func testTheContainmentMatrixHoldsOnTheNativePath() async throws {
    let root = try gitRepo()
    try await assertContainmentMatrix(
      NativeFileProvider(context: try await context(root)), root: root)
  }

  private func assertContainmentMatrix(
    _ files: FileProviding, root: URL, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let fm = FileManager.default
    let outside = try root.deletingLastPathComponent().appendingPathComponent(
      "outside-\(UUID().uuidString)")
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    roots.append(outside)
    let evil = root.deletingLastPathComponent().appendingPathComponent(
      root.lastPathComponent + "-evil")
    try fm.createDirectory(at: evil, withIntermediateDirectories: true)
    roots.append(evil)
    try "secret".write(
      to: outside.appendingPathComponent("secret"), atomically: true, encoding: .utf8)
    try "evil".write(to: evil.appendingPathComponent("x"), atomically: true, encoding: .utf8)
    try fm.createDirectory(
      at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    try fm.createDirectory(
      at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try "hello".write(
      to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
    try "0123456789A".write(  // 11 bytes
      to: root.appendingPathComponent("big"), atomically: true, encoding: .utf8)
    try fm.createSymbolicLink(
      atPath: root.appendingPathComponent("alias").path, withDestinationPath: "src/a.txt")
    try fm.createSymbolicLink(
      atPath: root.appendingPathComponent("escape").path,
      withDestinationPath: outside.appendingPathComponent("secret").path)
    try fm.createSymbolicLink(
      atPath: root.appendingPathComponent("linked").path, withDestinationPath: outside.path)
    try fm.createSymbolicLink(
      atPath: root.appendingPathComponent("prefix").path,
      withDestinationPath: evil.appendingPathComponent("x").path)
    XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)

    func read(_ path: String, _ policy: FileSymlinkPolicy, max: Int = 100) async -> Result<
      Data, Error
    > {
      do {
        return .success(try await files.read(path: path, symlinks: policy, maxBytes: max))
      } catch {
        return .failure(error)
      }
    }
    func refused(_ path: String, _ policy: FileSymlinkPolicy, _ label: String) async {
      let result = await read(path, policy)
      guard case .failure(let error) = result, case FileServiceError.refused = error else {
        return XCTFail(
          "\(label) [\(policy)] should be refused, got \(result)", file: file, line: line)
      }
    }

    for policy in [FileSymlinkPolicy.followWithinRoot, .refuse] {
      let plain = await read("src/a.txt", policy)
      XCTAssertEqual(try plain.get(), Data("hello".utf8), file: file, line: line)
      await refused("escape", policy, "a link out of the root")
      await refused("linked/secret", policy, "a directory link out of the root")
      await refused("pipe", policy, "a FIFO")
      await refused("sub", policy, "a directory")
    }
    // The two policies differ on exactly one thing: a link that stays inside the root.
    let followed = await read("alias", .followWithinRoot)
    XCTAssertEqual(try followed.get(), Data("hello".utf8), file: file, line: line)
    await refused("alias", .refuse, "a leaf link")
    await refused("prefix", .followWithinRoot, "a sibling sharing the root's name prefix")

    let missing = await read("nope", .refuse)
    guard case .failure(let missingError) = missing, case FileServiceError.notFound = missingError
    else { return XCTFail("a missing file is notFound, got \(missing)", file: file, line: line) }
    let traversal = await read("../x", .refuse)
    guard case .failure(let traversalError) = traversal,
      case FileServiceError.failed = traversalError
    else { return XCTFail("a climbing path is rejected, got \(traversal)", file: file, line: line) }

    let over = await read("big", .refuse, max: 10)
    guard case .failure(let overError) = over, case FileServiceError.tooLarge = overError
    else { return XCTFail("over max_bytes is tooLarge, got \(over)", file: file, line: line) }
    let atLimit = await read("big", .refuse, max: 11)
    XCTAssertEqual(try atLimit.get().count, 11, file: file, line: line)
  }

  // MARK: Watching

  private final class Deliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(paths: [String], overflow: Bool)] = []
    func add(_ paths: [String], _ overflow: Bool) {
      lock.withLock { items.append((paths, overflow)) }
    }
    var all: [(paths: [String], overflow: Bool)] { lock.withLock { items } }
    func touched(_ name: String) -> Bool {
      all.contains { $0.paths.contains { $0.hasSuffix(name) } }
    }
    func wait(_ timeout: TimeInterval = 8, until condition: () -> Bool) async -> Bool {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
      }
      return condition()
    }
  }

  func testASubscriptionDeliversARealChangeAndStopsAfterUnwatch() async throws {
    let (connection, _) = try await connect()
    let root = try root()
    let files = try await agentFiles(root, connection: connection)
    let seen = Deliveries()
    let watched = try await files.watch(root: root.path) { event in
      if case .changed(let paths, let overflow) = event { seen.add(paths, overflow) }
    }
    let handle = try XCTUnwrap(watched)
    // Settle: FSEvents may still be reporting the directory's own creation.
    _ = await seen.wait(1.5) { false }

    try "1".write(to: root.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
    let got = await seen.wait { seen.touched("first.txt") }
    XCTAssertTrue(got, "a leading event carrying the changed path")
    XCTAssertTrue(seen.all.allSatisfy { !$0.overflow })

    await handle.cancel()
    let before = seen.all.count
    try "2".write(to: root.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
    _ = await seen.wait(2.5) { false }
    XCTAssertEqual(seen.all.count, before, "nothing is delivered after unwatch")
  }

  /// The coalescing bound, end to end: a sustained burst is two-ish deliveries, not one per write.
  func testABurstOfWritesCoalescesToAFewDeliveries() async throws {
    let (connection, _) = try await connect()
    let root = try root()
    let files = try await agentFiles(root, connection: connection)
    let seen = Deliveries()
    let watched = try await files.watch(root: root.path) { event in
      if case .changed(let paths, let overflow) = event { seen.add(paths, overflow) }
    }
    let handle = try XCTUnwrap(watched)
    _ = await seen.wait(1.5) { false }
    let baseline = seen.all.count
    for index in 0..<300 {
      try "x".write(
        to: root.appendingPathComponent("burst-\(index).txt"), atomically: true, encoding: .utf8)
    }
    let last = await seen.wait { seen.touched("burst-299.txt") }
    XCTAssertTrue(last, "the trailing delivery reports the final state")
    let deliveries = seen.all.count - baseline
    XCTAssertLessThanOrEqual(deliveries, 4, "300 writes must not be ~300 deliveries")
    await handle.cancel()
  }

  func testEverySubscriptionLearnsWhenItsConnectionIsLost() async throws {
    let (connection, _) = try await connect()
    let root = try root()
    let files = try await agentFiles(root, connection: connection)
    let lost = expectation(description: "lost")
    let watched = try await files.watch(root: root.path) { event in
      if event == .lost { lost.fulfill() }
    }
    let handle = try XCTUnwrap(watched)
    await connection.close()
    await fulfillment(of: [lost], timeout: 5)
    await handle.cancel()  // idempotent, and harmless on a dead connection
  }

  /// The host watcher end to end: routed to the agent, and re-subscribed after the connection dies
  /// with exactly one synthetic refresh for the gap.
  @MainActor
  func testTheHostWatcherReconnectsAfterALostConnectionWithOneSyntheticRefresh() async throws {
    let agent = try AgentHarness.start(environment: environment)
    agents.append(agent)
    let root = try root()
    let seen = Deliveries()
    let current = ConnectionBox()
    let router = RepositoryRouter(localFiles: { [socket = agent.socketPath] context in
      let connection = try await AgentVCSConnection.connect(host: .local, socketPath: socket)
      current.set(connection)
      return try connection.files(context: context)
    })
    let watcher = HostFileWatcher(router: router) { paths, overflow in seen.add(paths, overflow) }
    watcher.start(path: root.path)
    defer { watcher.stop() }
    _ = await seen.wait(2) { false }
    try "1".write(to: root.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
    let first = await seen.wait { seen.touched("before.txt") }
    XCTAssertTrue(first)

    let before = seen.all.filter { $0.paths.isEmpty && $0.overflow }.count
    await current.connection?.close()
    let refreshed = await seen.wait {
      seen.all.filter { $0.paths.isEmpty && $0.overflow }.count == before + 1
    }
    XCTAssertTrue(refreshed, "one synthetic refresh once the new subscription is live")
    _ = await seen.wait(1.5) { false }
    XCTAssertEqual(
      seen.all.filter { $0.paths.isEmpty && $0.overflow }.count, before + 1,
      "and no more than one for one gap")

    try "2".write(to: root.appendingPathComponent("after.txt"), atomically: true, encoding: .utf8)
    let after = await seen.wait { seen.touched("after.txt") }
    XCTAssertTrue(after, "changes flow again on the new generation")
  }

  /// With no agent (or one that predates the File service) the same watcher is FSEvents, unchanged.
  @MainActor
  func testTheHostWatcherFallsBackToLocalFSEventsWhenTheAgentCannotWatch() async throws {
    let root = try root()
    let seen = Deliveries()
    let watcher = HostFileWatcher(
      router: RepositoryRouter(localFiles: { _ in throw VCSError.backendVersion("old") })
    ) { paths, overflow in seen.add(paths, overflow) }
    watcher.start(path: root.path)
    defer { watcher.stop() }
    _ = await seen.wait(1.5) { false }
    try "1".write(to: root.appendingPathComponent("native.txt"), atomically: true, encoding: .utf8)
    // `WorkroomFileWatcher` reports the CHANGED DIRECTORY, not the file (no per-file events), so this
    // asserts that a delivery arrives, not what it names. Never `overflow`: nothing was missed.
    let got = await seen.wait { !seen.all.isEmpty }
    XCTAssertTrue(got)
    XCTAssertTrue(seen.all.allSatisfy { !$0.overflow })
  }

  private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentVCSConnection?
    func set(_ connection: AgentVCSConnection) { lock.withLock { value = connection } }
    var connection: AgentVCSConnection? { lock.withLock { value } }
  }
}

/// A stand-in for a pre-File agent: greets with `version`, answers the VCS `capabilities` probe so
/// `connect()` succeeds, and records the service byte of every envelope it receives.
///
/// `status: true` also answers `Service::Status` (`0x04`) and can push an unsolicited ceiling prompt;
/// left off, the Status probe goes unanswered exactly as a pre-#208 protocol-3 agent's would.
///
/// `forward: true` answers `Service::Forward` (`0x05`) — **scripted, not socket-backed**: it replies
/// to OPEN, echoes DATA straight back and mirrors EOF, and it records the stream id and opcode of
/// every Forward envelope it receives. The real socket semantics are covered end to end against the
/// shipped binary in `AgentPortForwardingTests`; this exists for what that structurally cannot show —
/// which opcodes, and which stream ids, the client actually sent. `forwardRefusal` makes every OPEN
/// fail with that `connect` detail instead.
final class FakeAgent: @unchecked Sendable {
  let socketPath: String
  private let listener: Int32
  private let directory: URL
  private let lock = NSLock()
  private var services: [UInt8] = []
  private var clients: [Int32] = []
  private var forwardTraffic: [(stream: UInt32, opcode: UInt8)] = []

  var receivedServices: [UInt8] { lock.withLock { services } }

  /// Every Forward envelope received, in arrival order.
  var receivedForwards: [(stream: UInt32, opcode: UInt8)] { lock.withLock { forwardTraffic } }

  func forwards(opcode: UInt8) -> [UInt32] {
    receivedForwards.filter { $0.opcode == opcode }.map(\.stream)
  }

  /// One `status` reply, with the box busy past a 4h ceiling and a prompt pending.
  static let statusJSON = """
    {"version":1,"result":{"running":true,"verdict":"BUSY","busy":true,\
    "classifier_verdict":"BUSY","monotonic":15000.0,"awake_seconds":14400.5,\
    "awake_ceiling_exceeded":true,"prompt_pending":true,"prompt_deadline":15600.0,\
    "asserting":true,"suppressed":false,"ceiling_seconds":14400.0,\
    "prompt_timeout_seconds":600.0,"ask_at_ceiling":true,"cpu_fraction":0.0021,\
    "verdict_written":true}}
    """

  static let ceilingPromptJSON =
    #"{"version":1,"event":"awake_ceiling_prompt","awake_seconds":14400.5,"prompt_deadline":15600.0}"#

  /// Pushes an event on the Status service, stream 0 — the agent's own stream. The ceiling prompt by
  /// default; any body, so a malformed or unknown event can be proven dropped.
  func pushCeilingPrompt(body json: String = FakeAgent.ceilingPromptJSON) {
    let body = Data(json.utf8)
    var envelope = Data([4])
    for value in [UInt32(0), UInt32(body.count + 1)] {
      var value = value.bigEndian
      withUnsafeBytes(of: &value) { envelope.append(contentsOf: $0) }
    }
    envelope.append(1)
    envelope.append(body)
    lock.withLock {
      for client in clients {
        _ = envelope.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
      }
    }
  }

  private let forward: Bool
  private let forwardRefusal: String?
  private let forwardEpilogue: Int

  init(
    version: UInt16, status: Bool = false, forward: Bool = false, forwardRefusal: String? = nil,
    forwardEpilogue: Int = 0
  ) throws {
    self.forward = forward
    self.forwardRefusal = forwardRefusal
    self.forwardEpilogue = forwardEpilogue
    directory = URL(fileURLWithPath: "/tmp/wra-fake-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    socketPath = directory.appendingPathComponent("a.sock").path
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, listen(listener, 4) == 0 else {
      throw NSError(domain: "FakeAgent", code: Int(errno))
    }
    let listenerFD = self.listener
    DispatchQueue.global().async { [weak self] in
      while true {
        let client = accept(listenerFD, nil, nil)
        guard client >= 0 else { return }
        self?.lock.withLock { self?.clients.append(client) }
        DispatchQueue.global().async { self?.serve(client, version: version, status: status) }
      }
    }
  }

  func stop() {
    close(listener)
    lock.withLock { for client in clients { close(client) } }
    try? FileManager.default.removeItem(at: directory)
  }

  private func serve(_ client: Int32, version: UInt16, status: Bool) {
    let magic = Array("WRA1".utf8)
    let hello = magic + [UInt8(version >> 8), UInt8(version & 0xFF), 0]
    guard send(client, hello, hello.count, 0) == hello.count else { return }
    var buffer = Data()
    var greeted = false
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = recv(client, &chunk, chunk.count, 0)
      guard count > 0 else { return }
      buffer.append(contentsOf: chunk.prefix(count))
      if !greeted {
        guard buffer.count >= 7 else { continue }
        let end = 7 + Int(buffer[6])
        guard buffer.count >= end else { continue }
        buffer = Data(buffer.dropFirst(end))
        greeted = true
      }
      while buffer.count >= 9 {
        let bytes = Array(buffer.prefix(9))
        let stream = bytes[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let length = bytes[5..<9].reduce(0) { ($0 << 8) | Int($1) }
        guard buffer.count >= 9 + length else { break }
        let payload = Data(buffer.dropFirst(9).prefix(length))
        buffer = Data(buffer.dropFirst(9 + length))
        lock.withLock { services.append(bytes[0]) }
        if bytes[0] == 5 && forward {
          handleForward(client, stream: stream, payload: payload)
          continue
        }
        let request = String(decoding: payload, as: UTF8.self)
        let body: Data
        switch bytes[0] {
        case 2 where request.contains("capabilities"):
          body = Data(#"{"version":1,"result":{"version":1,"reads":9,"exec":2}}"#.utf8)
        case 4 where status && request.contains("keep"):
          body = Data(#"{"version":1,"result":{"kept":true}}"#.utf8)
        case 4 where status:
          body = Data(Self.statusJSON.utf8)
        default:
          continue
        }
        var reply = Data([bytes[0]])
        for value in [stream, UInt32(body.count + 1)] {
          var value = value.bigEndian
          withUnsafeBytes(of: &value) { reply.append(contentsOf: $0) }
        }
        reply.append(1)
        reply.append(body)
        _ = reply.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
      }
    }
  }

  /// The agent half of `Service::Forward`. A Forward payload is an OPCODE byte then a body, never a
  /// chunk flag then JSON, so it is answered here rather than through the reply builder above.
  private func handleForward(_ client: Int32, stream: UInt32, payload: Data) {
    guard let opcode = payload.first else { return }
    lock.withLock { forwardTraffic.append((stream, opcode)) }
    let body = Data(payload.dropFirst())
    switch opcode {
    case 0x01:  // OPEN
      if let refusal = forwardRefusal {
        let error = #"{"version":1,"error":{"connect":"\#(refusal)"}}"#
        sendForward(client, stream: stream, opcode: 0x02, body: Data(error.utf8))
        // A refusal is followed immediately by CLOSE, exactly as `forward.rs` does it.
        sendForward(client, stream: stream, opcode: 0x05, body: Data())
      } else {
        sendForward(
          client, stream: stream, opcode: 0x02,
          body: Data(#"{"version":1,"result":{"opened":true}}"#.utf8))
      }
    case 0x03:  // DATA — echoed, so a round trip needs no socket on this side
      sendForward(client, stream: stream, opcode: 0x03, body: body)
    case 0x04:  // EOF
      // With an epilogue, this is the shape a request/response server has: the request body ends,
      // the whole response goes out, and the peer half-closes immediately behind it. DATA and EOF
      // land back to back on the client's reader thread, which is what makes a teardown that does
      // not wait for its own write queue lose the response.
      if forwardEpilogue > 0 {
        sendForward(
          client, stream: stream, opcode: 0x03,
          body: Data(repeating: 0xAB, count: forwardEpilogue))
      }
      sendForward(client, stream: stream, opcode: 0x04, body: Data())
    default:
      break  // CLOSE is recorded and needs no answer.
    }
  }

  /// Deliberately takes no lock: it is called from the per-client serve thread with that client's
  /// descriptor in hand, and `handleForward` is already holding nothing.
  private func sendForward(_ client: Int32, stream: UInt32, opcode: UInt8, body: Data) {
    var envelope = Data([5])
    for value in [stream, UInt32(body.count + 1)] {
      var value = value.bigEndian
      withUnsafeBytes(of: &value) { envelope.append(contentsOf: $0) }
    }
    envelope.append(opcode)
    envelope.append(body)
    _ = envelope.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
  }
}
