import WorkroomSessionProtocol
import XCTest

@testable import Workroom

/// Choosing between this Mac's copy of a remote workroom's layout and its host's (#255), against an
/// in-memory host that keeps revisions as `layout.rs` does.
final class HostLayoutSyncTests: XCTestCase {
  /// A host's layouts: revision-checked puts, and a hook to let "another Mac" write in between.
  private final class FakeHost: HostLayoutStore, @unchecked Sendable {
    private let lock = NSLock()
    private var layouts: [String: AgentLayout] = [:]
    private(set) var puts = 0
    var refuse: AgentLayoutError?
    /// Runs once, just before the next put is checked: another Mac's write landing first.
    var beforePut: ((FakeHost) -> Void)?

    func seed(_ key: String, revision: UInt64, blob: String) {
      lock.withLock { layouts[key] = AgentLayout(revision: revision, blob: blob) }
    }

    func get(_ key: String) async throws -> AgentLayout {
      lock.withLock { layouts[key] ?? AgentLayout(revision: 0, blob: nil) }
    }

    func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64 {
      let hook = lock.withLock { () -> ((FakeHost) -> Void)? in
        defer { beforePut = nil }
        return beforePut
      }
      hook?(self)
      return try lock.withLock {
        puts += 1
        if let refuse { throw refuse }
        let current = layouts[key]?.revision ?? 0
        guard current == expected else { throw AgentLayoutError.stale(revision: current) }
        layouts[key] = AgentLayout(revision: current + 1, blob: blob)
        return current + 1
      }
    }
  }

  private let key = "WORKROOM"
  private let session = UUID()

  private func layout(_ title: String, revision: UInt64? = nil, stale: Bool? = nil)
    -> TargetSession
  {
    var target = TargetSession(
      targetID: "mine",
      tabs: [
        TabSession(
          key: "k-\(title)", kind: TabSession.terminalKind,
          terminal: TerminalPayload(defaultTitle: title, sessionID: session.uuidString))
      ], focusedKey: "k-\(title)")
    target.hostRevision = revision
    target.hostLayoutStale = stale
    return target
  }

  private func titles(_ resolution: HostLayoutResolution) -> [String] {
    resolution.session?.tabs.compactMap { $0.terminal?.defaultTitle } ?? []
  }

  /// An empty host is seeded from this Mac's copy, which is restored as it is.
  func testAnEmptyHostIsSeededFromThisMacsCopy() async throws {
    let host = FakeHost()
    let resolution = try await HostLayoutSync.resolve(
      held: layout("mine"), key: key, targetID: "mine", store: host)
    XCTAssertEqual(titles(resolution), ["mine"])
    XCTAssertEqual(resolution.revision, 1)
    let kept = try await host.get(key)
    XCTAssertEqual(kept.revision, 1)
  }

  /// Two Macs seeding at once: the one refused adopts the other's layout rather than overwriting
  /// it (R3-3).
  func testASeedAnotherMacGotInFirstAdoptsItsLayout() async throws {
    let host = FakeHost()
    let theirs = try HostLayout.encode(layout("theirs"), key: key)
    host.beforePut = { $0.seed(self.key, revision: 1, blob: theirs) }
    let resolution = try await HostLayoutSync.resolve(
      held: layout("mine"), key: key, targetID: "mine", store: host)
    XCTAssertEqual(titles(resolution), ["theirs"])
    XCTAssertEqual(resolution.revision, 1)
  }

  /// A host layout newer than the one this Mac last saw wins, with this Mac's focus put back.
  func testANewerHostLayoutWins() async throws {
    let host = FakeHost()
    host.seed(key, revision: 5, blob: try HostLayout.encode(layout("theirs"), key: key))
    let resolution = try await HostLayoutSync.resolve(
      held: layout("mine", revision: 4), key: key, targetID: "mine", store: host)
    XCTAssertEqual(titles(resolution), ["theirs"])
    XCTAssertEqual(resolution.revision, 5)
    XCTAssertEqual(resolution.session?.focusedKey, "k-theirs", "focus found by the same session")
    XCTAssertEqual(host.puts, 0)
  }

  /// The host's revision is the one this Mac last saw: this Mac's copy is the host's already.
  func testAnUnchangedHostLeavesThisMacsCopy() async throws {
    let host = FakeHost()
    host.seed(key, revision: 4, blob: try HostLayout.encode(layout("old"), key: key))
    let resolution = try await HostLayoutSync.resolve(
      held: layout("mine", revision: 4), key: key, targetID: "mine", store: host)
    XCTAssertEqual(titles(resolution), ["mine"])
    XCTAssertEqual(host.puts, 0)
  }

  /// A Mac with no copy of its own takes the host's.
  func testAMacWithNoCopyTakesTheHosts() async throws {
    let host = FakeHost()
    host.seed(key, revision: 2, blob: try HostLayout.encode(layout("theirs"), key: key))
    let resolution = try await HostLayoutSync.resolve(
      held: nil, key: key, targetID: "mine", store: host)
    XCTAssertEqual(titles(resolution), ["theirs"])
    XCTAssertEqual(resolution.session?.targetID, "mine")
  }

  /// A stale copy (a write that never reached the host) wins and is written at the host's current
  /// revision; one the host still refuses stays stale (R3-1, D14).
  func testAStaleCopyWinsAndIsWritten() async throws {
    let host = FakeHost()
    host.seed(key, revision: 7, blob: try HostLayout.encode(layout("theirs"), key: key))
    let resolution = try await HostLayoutSync.resolve(
      held: layout("mine", revision: 6, stale: true), key: key, targetID: "mine", store: host)
    XCTAssertEqual(titles(resolution), ["mine"])
    XCTAssertEqual(resolution.revision, 8)
    XCTAssertFalse(resolution.stale)

    let full = FakeHost()
    full.refuse = .tooLarge("over the cap")
    let kept = try await HostLayoutSync.resolve(
      held: layout("mine", revision: 6, stale: true), key: key, targetID: "mine", store: full)
    XCTAssertEqual(titles(kept), ["mine"])
    XCTAssertTrue(kept.stale)
    XCTAssertFalse(kept.refused, "a size refusal is not another Mac's write")
  }

  /// A refused write retries at the revision it was told, at most three times, then gives up stale.
  func testAWriteRetriesAtTheCurrentRevisionAndIsBounded() async {
    let host = FakeHost()
    host.seed(key, revision: 3, blob: "{}")
    let written = await HostLayoutSync.write(layout("mine"), key: key, expected: 1, store: host)
    XCTAssertEqual(written.revision, 4)
    XCTAssertEqual(host.puts, 2, "one refused at 1, one accepted at 3")

    final class AlwaysMoves: HostLayoutStore, @unchecked Sendable {
      var puts = 0
      func get(_ key: String) async throws -> AgentLayout { AgentLayout(revision: 0, blob: nil) }
      func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64 {
        puts += 1
        throw AgentLayoutError.stale(revision: expected + 1)
      }
    }
    let busy = AlwaysMoves()
    let gaveUp = await HostLayoutSync.write(layout("mine"), key: key, expected: 0, store: busy)
    XCTAssertTrue(gaveUp.stale)
    XCTAssertTrue(gaveUp.refused)
    XCTAssertEqual(busy.puts, 3)
  }

  /// A layout from a newer build is never written over (D5), however this Mac's copy stands: when
  /// its copy is stale, and on a later launch that holds the newer layout's own revision.
  func testANewerBuildsLayoutIsNeverWrittenOver() async throws {
    let host = FakeHost()
    host.seed(key, revision: 9, blob: #"{"schemaVersion": 99, "target": {}}"#)
    let stale = try await HostLayoutSync.resolve(
      held: layout("mine", revision: 8, stale: true), key: key, targetID: "mine", store: host)
    XCTAssertTrue(stale.readOnly)
    XCTAssertEqual(titles(stale), ["mine"])
    let later = try await HostLayoutSync.resolve(
      held: layout("mine", revision: 9), key: key, targetID: "mine", store: host)
    XCTAssertTrue(later.readOnly, "read-only only on the launch that first saw it")
    XCTAssertEqual(host.puts, 0)
  }

  /// A host whose layouts were reset holds an older revision than this Mac last saw: the host's is
  /// still the one restored, not this Mac's copy written over it.
  func testAHostBelowThisMacsRevisionIsStillTheHosts() async throws {
    let host = FakeHost()
    host.seed(key, revision: 2, blob: try HostLayout.encode(layout("theirs"), key: key))
    let resolution = try await HostLayoutSync.resolve(
      held: layout("mine", revision: 6), key: key, targetID: "mine", store: host)
    XCTAssertEqual(titles(resolution), ["theirs"])
    XCTAssertEqual(resolution.revision, 2)
    XCTAssertEqual(host.puts, 0)
  }

  /// A write refused because another Mac wrote first never retries over a newer build's layout
  /// (D5): the layout that beat it is read before the retry.
  func testARetryNeverOverwritesANewerBuildsLayout() async {
    let host = FakeHost()
    host.seed(key, revision: 1, blob: try! HostLayout.encode(layout("theirs"), key: key))
    host.beforePut = {
      $0.seed(self.key, revision: 2, blob: #"{"schemaVersion": 99, "target": {}}"#)
    }
    let written = await HostLayoutSync.write(layout("mine"), key: key, expected: 1, store: host)
    XCTAssertTrue(written.readOnly)
    XCTAssertEqual(host.puts, 1)
    let kept = try? await host.get(key)
    XCTAssertEqual(kept?.revision, 2)
  }

  /// A write of this Mac's own that landed after its answer was given up on (a seed) is the
  /// host's layout: one refused write finds it there and goes in at its revision, once; a host
  /// holding anything else still refuses it for good.
  func testAWriteFindingItsOwnLateSeedGoesInOnceAtItsRevision() async throws {
    let seed = try HostLayout.encode(layout("mine"), key: key)
    let host = FakeHost()
    host.seed(key, revision: 1, blob: seed)
    let written = await HostLayoutSync.write(
      layout("edited"), key: key, expected: 0, store: host, attempts: 1, ownWrite: seed)
    XCTAssertFalse(written.stale)
    XCTAssertEqual(written.revision, 2)
    XCTAssertEqual(host.puts, 2)

    let other = FakeHost()
    other.seed(key, revision: 1, blob: try HostLayout.encode(layout("theirs"), key: key))
    let refused = await HostLayoutSync.write(
      layout("edited"), key: key, expected: 0, store: other, attempts: 1, ownWrite: seed)
    XCTAssertTrue(refused.stale)
    XCTAssertEqual(other.puts, 1)
  }

  /// A retry whose read of the layout that beat it fails is not made: that layout could be a newer
  /// build's.
  func testARetryIsNotMadeWhenTheLayoutThatBeatItCannotBeRead() async {
    final class Unreadable: HostLayoutStore, @unchecked Sendable {
      var puts = 0
      func get(_ key: String) async throws -> AgentLayout {
        throw AgentLayoutError.failed("no request slot")
      }
      func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64 {
        puts += 1
        guard expected == 2 else { throw AgentLayoutError.stale(revision: 2) }
        return 3
      }
    }
    let host = Unreadable()
    let written = await HostLayoutSync.write(layout("mine"), key: key, expected: 1, store: host)
    XCTAssertTrue(written.stale)
    XCTAssertEqual(host.puts, 1)
  }

  /// One attempt: a refusal is final, at the revision this Mac had, not retried past (a Mac that
  /// never read the host's layout this launch).
  func testASingleAttemptWriteIsNeverRetriedPastARefusal() async {
    let host = FakeHost()
    host.seed(key, revision: 3, blob: "{}")
    let written = await HostLayoutSync.write(
      layout("mine"), key: key, expected: 1, store: host, attempts: 1)
    XCTAssertTrue(written.stale)
    XCTAssertEqual(host.puts, 1)
    let kept = try? await host.get(key)
    XCTAssertEqual(kept?.revision, 3)
  }

  /// A host layout this build cannot read at all is replaced: this Mac's copy is restored and,
  /// marked as not on the host, written at the next save.
  func testAnUnreadableHostLayoutIsReplaced() async throws {
    let host = FakeHost()
    host.seed(key, revision: 5, blob: "not a layout")
    let resolution = try await HostLayoutSync.resolve(
      held: layout("mine", revision: 4), key: key, targetID: "mine", store: host)
    XCTAssertEqual(titles(resolution), ["mine"])
    XCTAssertTrue(resolution.stale)
    XCTAssertEqual(resolution.revision, 5)
  }

  /// A layout from a newer build is restored from nothing and never written over (D5); an empty one
  /// restores no tabs (D11).
  func testANewerOrEmptyHostLayout() async throws {
    let host = FakeHost()
    host.seed(key, revision: 9, blob: #"{"schemaVersion": 99, "target": {}}"#)
    let newer = try await HostLayoutSync.resolve(
      held: layout("mine", revision: 1), key: key, targetID: "mine", store: host)
    XCTAssertTrue(newer.readOnly)
    XCTAssertEqual(titles(newer), ["mine"])

    host.seed(
      key, revision: 10,
      blob: try HostLayout.encode(TargetSession(targetID: "x", tabs: []), key: key))
    let empty = try await HostLayoutSync.resolve(
      held: layout("mine", revision: 9), key: key, targetID: "mine", store: host)
    XCTAssertNil(empty.session)
    XCTAssertEqual(empty.revision, 10)
  }

  /// The host's sessions tagged with the workroom that the layout does not name come back as tabs,
  /// oldest first; others, and ones already named, do not (premise 3).
  func testSessionsTheLayoutDoesNotNameAreAppended() {
    func descriptor(_ id: UUID, workroom: String, title: String, created: String)
      -> SessionDescriptor
    {
      SessionDescriptor(
        identifier: SessionIdentifier(id), shellProcessID: 1, ttyDevice: 0,
        workingDirectory: "/w", isAttached: false,
        metadata: [
          SessionEnvironmentEntry(key: SessionMetadataKey.workroom, value: workroom),
          SessionEnvironmentEntry(key: SessionMetadataKey.title, value: title),
          SessionEnvironmentEntry(key: "created", value: created),
        ])
    }
    let newer = UUID()
    let older = UUID()
    let sessions = [
      descriptor(session, workroom: key, title: "named", created: "1"),
      descriptor(newer, workroom: key, title: "Terminal 3", created: "300"),
      descriptor(older, workroom: key, title: "Terminal 2", created: "200"),
      descriptor(UUID(), workroom: "OTHER", title: "elsewhere", created: "100"),
    ]
    let appended = HostLayoutSync.appending(
      sessions, key: key, to: layout("named"), targetID: "mine")
    XCTAssertEqual(
      appended?.tabs.compactMap { $0.terminal?.defaultTitle },
      ["named", "Terminal 2", "Terminal 3"])
    XCTAssertEqual(appended?.tabs.last?.terminal?.sessionID, newer.uuidString)

    let fromNothing = HostLayoutSync.appending(sessions, key: key, to: nil, targetID: "mine")
    XCTAssertEqual(fromNothing?.targetID, "mine")
    XCTAssertEqual(fromNothing?.tabs.count, 3)
    XCTAssertNil(HostLayoutSync.appending([], key: key, to: nil, targetID: "mine"))
  }
}
