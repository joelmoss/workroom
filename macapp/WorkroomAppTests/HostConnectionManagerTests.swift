import Foundation
import XCTest

@testable import Workroom

final class HostConnectionManagerTests: XCTestCase {
  func testDisconnectDuringStatusIsUnavailableNotMissingRepository() async throws {
    let manager = HostConnectionManager()
    let router = RepositoryRouter(connections: manager)
    let root = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    try router.register(.init(location: root, backend: .git, sharedLocation: root))
    let connection = ConnectionFixture(delayStatus: true)
    let lease = try await manager.connect(host: root.host) { connection }
    let pending = Task { await WorkroomStatusResolver().resolve(location: root, router: router) }
    try await connection.statusStarted.arrived()
    await manager.disconnect(lease)
    let status = try await withTimeout(seconds: 2) { await pending.value }
    XCTAssertNil(status.dirty)
    XCTAssertEqual(status.failure, .unavailable)
    XCTAssertEqual(
      String(describing: HostConnectionError.connectionLost),
      HostConnectionError.connectionLost.localizedDescription)
    await connection.statusRelease.open()
  }

  func testAlreadyCancelledCallerCannotReplaceConnectionOrStartOperation() async throws {
    let manager = HostConnectionManager()
    let host = HostID.remote(UUID())
    let lease = try await manager.connect(host: host) { ConnectionFixture() }
    let release = ConnectionSignal()
    let cancelled = Task {
      await release.wait()
      do {
        _ = try await manager.connect(host: host) {
          XCTFail("cancelled caller started handshake")
          return ConnectionFixture()
        }
        XCTFail("cancelled connect succeeded")
      } catch { XCTAssertTrue(error is CancellationError) }
      do {
        _ = try await manager.perform(on: lease) {
          XCTFail("cancelled caller invoked provider")
          return 1
        }
        XCTFail("cancelled operation succeeded")
      } catch { XCTAssertTrue(error is CancellationError) }
    }
    cancelled.cancel()
    await release.open()
    await cancelled.value
    let state = await manager.snapshot(for: host)
    XCTAssertEqual(state.lease, lease)
    XCTAssertEqual(state.status, .connected)
    await manager.disconnect(lease)
  }

  func testServiceWithWrongContextCannotCrossHostBoundary() async throws {
    let manager = HostConnectionManager()
    let router = RepositoryRouter(connections: manager)
    let root = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    let wrong = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    for location in [root, wrong] {
      try router.register(.init(location: location, backend: .git, sharedLocation: location))
    }
    let wrongContext = try router.registeredContext(for: wrong)
    let connection = ConnectionFixture(readerContext: wrongContext)
    let lease = try await manager.connect(host: root.host) { connection }
    do {
      _ = try await router.reader(for: root)
      XCTFail("accepted another host's reader")
    } catch { XCTAssertEqual(error as? HostConnectionError, .mismatchedContext) }
    do {
      _ = try await router.writer(for: root)
      XCTFail("accepted another host's supporting reader")
    } catch { XCTAssertEqual(error as? HostConnectionError, .mismatchedContext) }
    await manager.disconnect(lease)
  }

  func testCancelledWriteReportsUnknownOutcomeAndDoesNotDisconnectOtherCallers() async throws {
    let manager = HostConnectionManager()
    let router = RepositoryRouter(connections: manager)
    let root = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    try router.register(.init(location: root, backend: .git, sharedLocation: root))
    let connection = ConnectionFixture()
    let lease = try await manager.connect(host: root.host) { connection }
    let writer = try await router.writer(for: root)
    let write = Task {
      await writer.commit(request: .init(message: "test", files: [], mode: .commit))
    }
    try await connection.writeStarted.arrived()
    write.cancel()
    let result = try await withTimeout(seconds: 2) { await write.value }
    guard case .failed(.other(let detail)) = result else {
      return XCTFail("cancelled write succeeded")
    }
    XCTAssertTrue(detail.contains("may have completed"))
    let content = try await writer.reader.fileContent(rev: "HEAD", path: "file")
    XCTAssertEqual(content, "fixture")
    await connection.writeRelease.open()
    try await connection.writeFinished.arrived()
    let count = await connection.commits.value
    XCTAssertEqual(count, 1)
    await manager.disconnect(lease)
  }

  func testDisconnectFailsPendingWorkBeforeItCompletesAndNeverReplays() async throws {
    let manager = HostConnectionManager()
    let host = HostID.remote(UUID())
    let connection = ConnectionFixture()
    let lease = try await manager.connect(host: host) { connection }
    let started = ConnectionSignal()
    let release = ConnectionSignal()
    let finished = ConnectionSignal()
    let pending = Task {
      try await manager.perform(on: lease) {
        await started.open()
        await release.wait()  // Intentionally ignores cancellation, like an accepted remote write.
        await finished.open()
        return "old result"
      }
    }
    try await started.arrived()
    await manager.disconnect(lease)
    do {
      _ = try await withTimeout(seconds: 2) { try await pending.value }
      XCTFail("disconnected operation succeeded")
    } catch { XCTAssertEqual(error as? HostConnectionError, .connectionLost) }
    let replacement = ConnectionFixture()
    let next = try await manager.connect(host: host) { replacement }
    XCTAssertNotEqual(lease, next)
    await release.open()
    try await finished.arrived()
    await manager.disconnect(lease)  // Late transport loss from the old generation.
    let state = await manager.snapshot(for: host)
    XCTAssertEqual(state.lease, next)
    XCTAssertEqual(state.status, .connected)
    do {
      _ = try await manager.perform(on: lease) {
        XCTFail("replayed old work")
        return 0
      }
      XCTFail("accepted stale lease")
    } catch { XCTAssertEqual(error as? HostConnectionError, .staleGeneration) }
    try await connection.closed.arrived()
    await manager.disconnect(next)
  }

  func testCancellationOnlyCancelsItsWaiterAndConnectionRemainsUsable() async throws {
    let manager = HostConnectionManager()
    let connection = ConnectionFixture()
    let lease = try await manager.connect(host: .local) { connection }
    let started = ConnectionSignal()
    let release = ConnectionSignal()
    let pending = Task {
      try await manager.perform(on: lease) {
        await started.open()
        await release.wait()
        return 1
      }
    }
    try await started.arrived()
    pending.cancel()
    do {
      _ = try await withTimeout(seconds: 2) { try await pending.value }
      XCTFail("cancelled waiter succeeded")
    } catch { XCTAssertTrue(error is CancellationError) }
    let result = try await manager.perform(on: lease) { 2 }
    XCTAssertEqual(result, 2)
    await release.open()
    await manager.disconnect(lease)
  }

  func testSupersededHandshakeClosesLateConnection() async throws {
    let manager = HostConnectionManager()
    let host = HostID.remote(UUID())
    let started = ConnectionSignal()
    let release = ConnectionSignal()
    let stale = ConnectionFixture()
    let pending = Task {
      try await manager.connect(host: host) {
        await started.open()
        await release.wait()
        return stale
      }
    }
    try await started.arrived()
    let connection = ConnectionFixture()
    let next = try await manager.connect(host: host) { connection }
    do {
      _ = try await withTimeout(seconds: 2) { try await pending.value }
      XCTFail("superseded handshake succeeded")
    } catch { XCTAssertEqual(error as? HostConnectionError, .staleGeneration) }
    await release.open()
    try await stale.closed.arrived()
    let state = await manager.snapshot(for: host)
    XCTAssertEqual(state.lease, next)
    XCTAssertEqual(state.status, .connected)
    await manager.disconnect(next)
  }

  func testCancelledHandshakeClosesLateConnectionAndFailureCanReconnect() async throws {
    let manager = HostConnectionManager()
    let host = HostID.remote(UUID())
    let started = ConnectionSignal()
    let release = ConnectionSignal()
    let connection = ConnectionFixture()
    let pending = Task {
      try await manager.connect(host: host) {
        await started.open()
        await release.wait()
        return connection
      }
    }
    try await started.arrived()
    pending.cancel()
    do {
      _ = try await withTimeout(seconds: 2) { try await pending.value }
      XCTFail("cancelled handshake succeeded")
    } catch { XCTAssertTrue(error is CancellationError) }
    await release.open()
    try await connection.closed.arrived()
    do {
      _ = try await manager.connect(host: host) { throw VCSError.io("handshake failed") }
      XCTFail("failed handshake succeeded")
    } catch { XCTAssertTrue(error is VCSError) }
    let failed = await manager.snapshot(for: host)
    XCTAssertEqual(failed.status, .disconnected)
    let lease = try await manager.connect(host: host) { ConnectionFixture() }
    await manager.disconnect(lease)
  }

  func testConnectionEventsLetEveryWindowRefreshAndTransportEndFailsPendingReads() async throws {
    let manager = HostConnectionManager()
    let host = HostID.remote(UUID())
    var first = await manager.updates(for: host).makeAsyncIterator()
    var second = await manager.updates(for: host).makeAsyncIterator()
    let initial = await first.next()
    XCTAssertEqual(initial?.status, .disconnected)
    _ = await second.next()
    let connection = ConnectionFixture()
    let lease = try await manager.connect(host: host) { connection }
    let one = await first.next()
    let two = await second.next()
    XCTAssertEqual(one, two)
    XCTAssertEqual(one?.lease, lease)
    XCTAssertEqual(one?.status, .connected)
    let started = ConnectionSignal()
    let release = ConnectionSignal()
    let read = Task {
      try await manager.perform(on: lease) {
        await started.open()
        await release.wait()
        return "late read"
      }
    }
    try await started.arrived()
    connection.loss.finish()
    do {
      _ = try await withTimeout(seconds: 2) { try await read.value }
      XCTFail("transport EOF did not fail read")
    } catch { XCTAssertEqual(error as? HostConnectionError, .connectionLost) }
    let disconnected = await first.next()
    XCTAssertEqual(disconnected?.status, .disconnected)
    let next = try await manager.connect(host: host) { ConnectionFixture() }
    let refreshed = await first.next()
    let slowWindow = await second.next()
    XCTAssertEqual(refreshed?.lease, next)
    XCTAssertEqual(slowWindow, refreshed)
    XCTAssertNotEqual(refreshed?.lease, one?.lease)
    await release.open()
    await manager.disconnect(next)
  }

  func testRoutersShareHostConnectionButSamePathOnOtherHostIsIsolated() async throws {
    let manager = HostConnectionManager()
    let first = RepositoryRouter(connections: manager)
    let second = RepositoryRouter(connections: manager)
    let location = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    let other = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    for router in [first, second] {
      for root in [location, other] {
        try router.register(.init(location: root, backend: .git, sharedLocation: root))
      }
    }
    let connection = ConnectionFixture(marker: "one")
    let lease = try await manager.connect(host: location.host) { connection }
    let separate = try await manager.connect(host: other.host) { ConnectionFixture(marker: "two") }
    let reader = try await first.reader(for: location)
    let writer = try await second.writer(for: location)
    XCTAssertEqual(reader.context, writer.context)
    let firstValue = try await reader.fileContent(rev: "HEAD", path: "file")
    let secondValue = try await writer.reader.fileContent(rev: "HEAD", path: "file")
    XCTAssertEqual(firstValue, "one")
    XCTAssertEqual(secondValue, "one")
    let independent = try await first.reader(for: other)
    await manager.disconnect(lease)
    let otherValue = try await independent.fileContent(rev: "HEAD", path: "file")
    XCTAssertEqual(otherValue, "two")
    do {
      _ = try await second.reader(for: location)
      XCTFail("disconnected router returned service")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .unavailable(location.host)) }
    let next = try await manager.connect(host: location.host) { ConnectionFixture(marker: "new") }
    do {
      _ = try await reader.log(limit: 1)
      XCTFail("old reader followed reconnect")
    } catch { XCTAssertEqual(error as? HostConnectionError, .staleGeneration) }
    do {
      _ = try await writer.commitPreflight()
      XCTFail("stale preflight became success")
    } catch { XCTAssertEqual(error as? HostConnectionError, .staleGeneration) }
    let oldWrite = await writer.fetch(remote: "origin")
    guard case .failed = oldWrite else { return XCTFail("old writer followed reconnect") }
    let fresh = try await second.reader(for: location)
    let newValue = try await fresh.fileContent(rev: "HEAD", path: "file")
    XCTAssertEqual(newValue, "new")
    await manager.disconnect(next)
    await manager.disconnect(separate)
  }

  func testAcceptedWriteFailsOnLossWithoutRetryingOnReplacement() async throws {
    let manager = HostConnectionManager()
    let router = RepositoryRouter(connections: manager)
    let location = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    try router.register(.init(location: location, backend: .jj, sharedLocation: location))
    let connection = ConnectionFixture()
    let lease = try await manager.connect(host: location.host) { connection }
    let writer = try await router.writer(for: location)
    let write = Task {
      await writer.commit(request: .init(message: "test", files: [], mode: .commit))
    }
    try await connection.writeStarted.arrived()
    await manager.disconnect(lease)
    let result = try await withTimeout(seconds: 2) { await write.value }
    guard case .failed(.other(let detail)) = result else { return XCTFail("lost write succeeded") }
    XCTAssertTrue(detail.contains("may have completed"))
    let replacement = ConnectionFixture()
    let next = try await manager.connect(host: location.host) { replacement }
    await connection.writeRelease.open()
    try await connection.writeFinished.arrived()
    let oldCount = await connection.commits.value
    let newCount = await replacement.commits.value
    XCTAssertEqual(oldCount, 1)
    XCTAssertEqual(newCount, 0)
    await manager.disconnect(next)
  }
}

private actor ConnectionSignal {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    isOpen = true
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume() }
  }
  func arrived() async throws {
    try await withTimeout(seconds: 3) { await self.wait() }
  }
}

private actor ConnectionCount {
  private(set) var value = 0
  func increment() { value += 1 }
}

private final class ConnectionFixture: HostServiceConnection, Sendable {
  let disconnection: AsyncStream<Void>
  let loss: AsyncStream<Void>.Continuation
  let closed = ConnectionSignal()
  let writeStarted = ConnectionSignal()
  let writeRelease = ConnectionSignal()
  let writeFinished = ConnectionSignal()
  let statusStarted = ConnectionSignal()
  let statusRelease = ConnectionSignal()
  let commits = ConnectionCount()
  let marker: String
  let readerContext: RepositoryContext?
  let delayStatus: Bool

  init(
    marker: String = "fixture", readerContext: RepositoryContext? = nil, delayStatus: Bool = false
  ) {
    self.marker = marker
    self.readerContext = readerContext
    self.delayStatus = delayStatus
    (disconnection, loss) = AsyncStream<Void>.makeStream()
  }
  func reader(context: RepositoryContext) throws -> VCSProviding {
    ConnectionReader(context: readerContext ?? context, marker: marker, connection: self)
  }
  func writer(context: RepositoryContext, reader: VCSProviding) throws -> VCSWriting {
    ConnectionWriter(context: context, reader: reader, connection: self)
  }
  func close() async { await closed.open() }
}

private struct ConnectionReader: VCSProviding {
  let context: RepositoryContext
  let marker: String
  let connection: ConnectionFixture
  func log(limit: Int) async throws -> VCSHistoryPage { .init(commits: [], reachedEnd: true) }
  func changeset(commitID: String) async throws -> VCSChangeset { throw VCSError.io("unused") }
  func fileDiff(commitID: String, path: String) async throws -> String { marker }
  func workingFileDiff(path: String, base: VCSWorkingDiffBase) async throws -> String { marker }
  func fileContent(rev: String, path: String) async throws -> String? { marker }
  func commitParentFileContent(commitID: String, path: String) async throws -> String? { marker }
  func workingBaseFileContent(base: VCSWorkingDiffBase, path: String) async throws -> String? {
    marker
  }
  func workingStatus() async throws -> WorkroomStatus {
    if connection.delayStatus {
      await connection.statusStarted.open()
      await connection.statusRelease.wait()
    }
    return .init(dirty: false)
  }
  func currentRef() async throws -> VCSRef { .none }
}

private struct ConnectionWriter: VCSWriting {
  let context: RepositoryContext
  let reader: VCSProviding
  let connection: ConnectionFixture
  func remoteState() async -> VCSRemoteResolution { .absent }
  func fetch(remote: String) async -> VCSRemoteActionResult { .ok(summary: "fetched") }
  func push(current: VCSRef, remote: String, setUpstream: Bool, anonymousRevision: String) async
    -> VCSRemoteActionResult
  { .ok(summary: "pushed") }
  func pullRebase(current: VCSRef, remote: String, tracking: VCSTracking?) async
    -> VCSRemoteActionResult
  { .ok(summary: "pulled") }
  func abortRebase() async -> VCSRemoteActionResult { .ok(summary: "aborted") }
  func commit(request: VCSCommitRequest) async -> VCSCommitResult {
    await connection.commits.increment()
    await connection.writeStarted.open()
    await connection.writeRelease.wait()
    await connection.writeFinished.open()
    return .ok(summary: "committed", revision: "new")
  }
  func stagedContentAtRisk(files: [ChangedFile]) async throws -> [String] { [] }
  func commitPreflight() async throws -> VCSCommitPreflight { throw VCSError.io("unused") }
}
