import Foundation
import Synchronization
import WorkroomDomain
import XCTest

@testable import HostDrivers

/// The Railway launch sweep (#630, ADR 0071 and its amendment) with Railway stubbed at HTTP
/// (`StubRailway`): a sandbox has no name or label, and an environment may be shared by another
/// Mac, so only a sandbox this Mac's create ledger accounts for, and no host record names, is
/// destroyed.
final class RailwaySweepTests: XCTestCase {
  private struct Tokens: RailwayAccessTokenProviding {
    func accessToken() async throws -> String { "at-1" }
    func accessTokenRejected(_ token: String) async {}
  }

  private struct SignedOut: RailwayAccessTokenProviding {
    func accessToken() async throws -> String { throw RailwaySessionError.signedOut }
    func accessTokenRejected(_ token: String) async {}
  }

  /// Made well before any create still under way could have made it.
  static let old = "2026-11-01T09:00:00.000Z"
  /// Longer ago than the sweep's grace.
  static let longAgo = Date().addingTimeInterval(-2 * RailwayHostDriver.sweepGrace)

  private var root: URL!

  override func setUp() {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-railway-sweep-\(UUID().uuidString)")
    let root = root!
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
  }

  private var keys: URL { root.appendingPathComponent("railway") }
  private var ledger: RailwayCreateLedger { RailwayCreateLedger(directory: keys) }

  private func driver(
    _ railway: StubRailway, tokens: any RailwayAccessTokenProviding = Tokens(),
    keys: URL? = nil, relay: RailwayHostDriverTests.StubRelay = .init()
  ) -> RailwayHostDriver {
    RailwayHostDriver(
      configuration: .init(
        environmentID: "env-1", projectID: "prj-1", keys: keys ?? self.keys,
        relayHost: RailwayHostDriverTests.relayHost, hostSetup: .checkout,
        pollInterval: .milliseconds(1)),
      api: RailwayAPI(transport: railway, tokens: tokens),
      directory: (keys ?? self.keys).appendingPathComponent("hosts"), runner: relay)
  }

  /// A sandbox row as `sandboxes` lists it.
  private static func sandbox(
    _ id: String, status: String = "RUNNING", createdAt: String = old,
    environment: String = "env-1"
  ) -> [String: Any] {
    ["id": id, "status": status, "createdAt": createdAt, "environmentId": environment]
  }

  private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

  /// A Railway whose `sandboxes` lists `rows` on one page, that destroys whatever it is asked,
  /// and that makes `sbx-1`, RUNNING at once, for a create.
  private func railway(_ rows: [[String: Any]]) -> StubRailway {
    let railway = StubRailway()
    railway.answer(
      "sandboxes",
      data: [
        "sandboxes": [
          "edges": rows.map { ["cursor": $0["id"]!, "node": $0] },
          "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
        ]
      ])
    railway.answer("sandboxDestroy") { request in
      let variables = StubRailway.graphQLBody(request)["variables"] as? [String: Any] ?? [:]
      let body = try JSONSerialization.data(withJSONObject: [
        "data": ["sandboxDestroy": ["id": variables["id"]!, "status": "DESTROYING"]]
      ])
      return RailwayHTTPResponse(status: 200, body: body)
    }
    railway.answer("sshPublicKeys", data: ["sshPublicKeys": StubRailway.lastPage([])])
    railway.answer("sshPublicKeyCreate", data: ["sshPublicKeyCreate": ["id": "key-1"]])
    railway.answer(
      "sandboxCreate", data: ["sandboxCreate": ["id": "sbx-1", "status": "CREATING"]])
    railway.answer("sandbox", data: ["sandbox": ["id": "sbx-1", "status": "RUNNING"]])
    return railway
  }

  private func requests(_ railway: StubRailway, _ field: String) -> [[String: Any]] {
    railway.graphQLRequests.map(StubRailway.graphQLBody)
      .filter { ($0["query"] as? String)?.contains("\(field)(") == true }
      .map { $0["variables"] as? [String: Any] ?? [:] }
  }

  private func destroyed(_ railway: StubRailway) -> Set<String> {
    Set(requests(railway, "sandboxDestroy").compactMap { $0["id"] as? String })
  }

  /// Ledger entries a create wrote long ago, with these sandboxes (nil: a lost reply).
  private func ledgered(_ sandboxes: [String?], started: Date = longAgo) async throws {
    try await ledger.update { entries in
      entries += sandboxes.map { .init(started: started, sandbox: $0) }
    }
  }

  // MARK: Only this Mac's creates

  /// Value: protects=two Macs sharing one environment (a placement copied by Migration Assistant
  /// or a Time Machine restore) never destroy each other's hosts (review D2); fails_when=a Mac's
  /// launch sweep destroys a sandbox its own ledger doesn't name, as another Mac's live host, which
  /// its records can't name, is; seam=create and RailwayHostDriver.sweep over StubRailway, from two
  /// Railway folders (two Macs) in one environment
  func testTheSweepNeverDestroysASandboxAnotherMacMadeInTheSameEnvironment() async throws {
    let railway = railway([Self.sandbox("sbx-1"), Self.sandbox("sbx-b")])
    // Mac A makes sbx-1 and records it in its own config.
    let macA = driver(railway)
    let host = try await macA.create()
    var descriptor = HostDescriptor(driver: "railway")
    macA.record(host, in: &descriptor)
    await macA.recorded(descriptor)

    // Mac B, with its own Railway folder and records (sbx-b), sweeps the same environment.
    let macB = driver(railway, keys: root.appendingPathComponent("mac-b"))
    let failures = try await macB.sweep(keeping: ["sbx-b"], grace: 0)
    XCTAssertEqual(failures, [])
    XCTAssertEqual(destroyed(railway), [], "Mac B destroyed Mac A's host")
  }

  /// Value: protects=no sandbox this Mac made is left billing that no workroom names, a recorded
  /// one is kept, and nothing else in the environment is touched (ADR 0071's amendment);
  /// fails_when=a ledgered, unrecorded sandbox survives, a recorded one goes, an unledgered one
  /// goes, or a sweep with every reply in hand lists the environment; seam=RailwayHostDriver.sweep
  /// over StubRailway and the ledger
  func testTheSweepDestroysWhatThisMacsLedgerNamesThatNoRecordNames() async throws {
    let railway = railway([
      Self.sandbox("sbx-orphan"), Self.sandbox("sbx-kept"), Self.sandbox("sbx-unledgered"),
    ])
    try await ledgered(["sbx-orphan", "sbx-kept"])
    let failures = try await driver(railway).sweep(keeping: ["sbx-kept"], recordsHere: true)
    XCTAssertEqual(failures, [])
    XCTAssertEqual(destroyed(railway), ["sbx-orphan"])
    XCTAssertTrue(requests(railway, "sandboxes").isEmpty, "listed with every reply in hand")
    for variables in requests(railway, "sandboxDestroy") {
      XCTAssertEqual(variables["environmentId"] as? String, "env-1", "\(variables)")
    }
    let left = try await ledger.entries()
    XCTAssertEqual(left, [], "the destroyed and the recorded entries stayed")
  }

  /// Value: protects=a create still under way keeps its sandbox, in this app or in the other build
  /// sharing the ledger (Release and Nightly, ADR 0036), and with nothing due Railway isn't asked;
  /// fails_when=the sweep destroys a sandbox whose create hasn't recorded it yet, or calls Railway
  /// for a young entry; seam=create and RailwayHostDriver.sweep over StubRailway
  func testTheSweepLeavesACreateStillUnderWay() async throws {
    let railway = railway([Self.sandbox("sbx-1"), Self.sandbox("sbx-other-build")])
    let driver = driver(railway)
    _ = try await driver.create()  // This app's create, not yet recorded: held.
    try await ledgered(["sbx-other-build", nil], started: Date())
    let before = railway.graphQLRequests.count

    let failures = try await driver.sweep(keeping: [], recordsHere: true)
    XCTAssertEqual(failures, [])
    XCTAssertEqual(destroyed(railway), [])
    XCTAssertEqual(railway.graphQLRequests.count, before, "a sweep with nothing due asked Railway")
    let kept = await driver.pendingSandboxes
    XCTAssertEqual(kept, ["sbx-1", "sbx-other-build"])
  }

  // MARK: A reply that was lost

  /// Value: protects=a create whose reply was lost still leaves nothing billing: its sandbox is
  /// the one nothing names that Railway made just after the intent, and only it goes;
  /// fails_when=the create forgets the intent, writes it after asking Railway, or the sweep
  /// destroys another Mac's sandbox made outside the window, a recorded one, or one with a
  /// createdAt it can't read; seam=create and RailwayHostDriver.sweep over StubRailway
  func testACreateWhoseReplyWasLostIsReconciledByWhenItsSandboxWasMade() async throws {
    let failing = railway([])
    let keys = self.keys
    let intentFirst = Mutex<Bool?>(nil)
    failing.answer("sandboxCreate") { _ in
      let file = keys.appendingPathComponent("create-ledger.json")
      let entries = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [Any]
      intentFirst.withLock { $0 = entries?.count == 1 }
      throw URLError(.networkConnectionLost)
    }
    do {
      _ = try await driver(failing).create()
      XCTFail("the create went through")
    } catch {}
    XCTAssertEqual(intentFirst.withLock { $0 }, true, "Railway was asked before the intent")
    let entries = try await ledger.entries()
    let intent = try XCTUnwrap(entries.first)
    XCTAssertNil(intent.sandbox)

    let listed = railway([
      Self.sandbox("sbx-lost", createdAt: Self.iso(intent.started.addingTimeInterval(4))),
      Self.sandbox("sbx-other-mac", createdAt: Self.iso(intent.started.addingTimeInterval(-3600))),
      Self.sandbox("sbx-recorded", createdAt: Self.iso(intent.started.addingTimeInterval(2))),
      Self.sandbox("sbx-unparsed", createdAt: "soon"),
      Self.sandbox(
        "sbx-gone", status: "DESTROYED", createdAt: Self.iso(intent.started.addingTimeInterval(1))
      ),
    ])
    // With no record of this environment (a lost config, a throwaway HOME), a sandbox no record
    // names says nothing: it may be a retried create's, only its lost record naming it. Kept, and
    // the intent waits.
    let unconfigured = try await driver(listed).sweep(keeping: [], recordsHere: false, grace: 0)
    XCTAssertEqual(unconfigured, [])
    XCTAssertEqual(destroyed(listed), [])
    XCTAssertTrue(requests(listed, "sandboxes").isEmpty)
    var left = try await ledger.entries()
    XCTAssertEqual(left.count, 1, "the lost reply was dropped unmatched")

    let failures = try await driver(listed).sweep(keeping: ["sbx-recorded"], grace: 0)
    XCTAssertEqual(failures, [])
    XCTAssertEqual(destroyed(listed), ["sbx-lost"])
    left = try await ledger.entries()
    XCTAssertEqual(left, [])
  }

  /// Value: protects=when the window holds more sandboxes than lost replies, none is destroyed,
  /// since one may be another Mac's; and a window with none settles its intent; fails_when=the
  /// sweep guesses among candidates, or keeps an intent that matched nothing forever;
  /// seam=RailwayHostDriver.sweep over StubRailway and the ledger
  func testALostReplyThatCannotBeToldApartDestroysNothing() async throws {
    let started = Self.longAgo
    try await ledgered([nil], started: started)
    let ambiguous = railway([
      Self.sandbox("sbx-a", createdAt: Self.iso(started.addingTimeInterval(3))),
      Self.sandbox("sbx-b", createdAt: Self.iso(started.addingTimeInterval(5))),
    ])
    let failures = try await driver(ambiguous).sweep(keeping: [], recordsHere: true)
    XCTAssertEqual(destroyed(ambiguous), [])
    XCTAssertEqual(failures.count, 1, "\(failures)")
    XCTAssertTrue(failures.first?.contains("sbx-a, sbx-b") == true, "\(failures)")
    var left = try await ledger.entries()
    XCTAssertEqual(left, [], "reported again at every launch")

    try await ledgered([nil], started: started)
    let empty = railway([Self.sandbox("sbx-later", createdAt: Self.iso(Date()))])
    let none = try await driver(empty).sweep(keeping: [], recordsHere: true)
    XCTAssertEqual(none, [])
    XCTAssertEqual(destroyed(empty), [])
    left = try await ledger.entries()
    XCTAssertEqual(left, [])
  }

  /// Value: protects=only an answer that says Railway made nothing drops a create's intent, so a
  /// sandbox a failed-looking reply did make is still swept, never left billing (review 3, C1);
  /// fails_when=a server error, an unreadable body, or a 200 with errors (partial data) drops the
  /// intent, or a client error (4xx, a refused sign-in) keeps it; seam=create over StubRailway and
  /// the ledger
  func testOnlyAClientErrorDropsACreatesIntent() async throws {
    let errors = #"{"errors":[{"message":"Sandbox limit reached"}]}"#
    let rows: [(name: String, status: Int, body: String, kept: Bool)] = [
      ("503 with GraphQL errors", 503, errors, true),
      ("503 unreadable", 503, "<html>bad gateway</html>", true),
      ("500 empty", 500, "", true),
      ("200 with errors and partial data",
        200, #"{"data":{"sandboxCreate":null},"errors":[{"message":"timeout"}]}"#, true),
      ("200 with errors", 200, errors, true),
      ("200 unreadable", 200, "not json", true),
      ("400", 400, errors, false),
      ("422", 422, #"{"errors":[{"message":"bad input"}]}"#, false),
      ("401 twice", 401, "", false),
    ]
    for row in rows {
      try await ledger.update { $0 = [] }
      let railway = railway([])
      railway.answer("sandboxCreate") { _ in
        RailwayHTTPResponse(status: row.status, body: Data(row.body.utf8))
      }
      do {
        _ = try await driver(railway).create()
        XCTFail("\(row.name): the create went through")
      } catch {}
      let left = try await ledger.entries()
      XCTAssertEqual(left.count, row.kept ? 1 : 0, row.name)
    }
  }

  /// Value: protects=a sweep that needs a listing Railway couldn't give is owed again, and one
  /// destroy Railway refused is reported without stopping the rest; fails_when=a signed-out
  /// listing reads as an empty environment and drops the intent, or a refused destroy is lost, ends
  /// the sweep, or leaves the ledger; seam=RailwayHostDriver.sweep over StubRailway
  func testASweepRailwayCannotAnswerThrowsAndARefusedDestroyIsReported() async throws {
    try await ledgered([nil])
    do {
      _ = try await driver(railway([Self.sandbox("sbx-a")]), tokens: SignedOut()).sweep(
        keeping: [], recordsHere: true)
      XCTFail("a signed-out sweep read as an empty environment")
    } catch RailwaySessionError.signedOut {}
    var left = try await ledger.entries()
    XCTAssertEqual(left.count, 1, "the lost reply wasn't owed again")
    try await ledger.update { $0 = [] }

    let railway = railway([Self.sandbox("sbx-stuck"), Self.sandbox("sbx-b")])
    railway.answer("sandboxDestroy") { request in
      let variables = StubRailway.graphQLBody(request)["variables"] as? [String: Any] ?? [:]
      let id = variables["id"] as? String ?? ""
      let body =
        id == "sbx-stuck"
        ? #"{"errors":[{"message":"Railway is down"}]}"#
        : #"{"data":{"sandboxDestroy":{"id":"\#(id)","status":"DESTROYING"}}}"#
      return RailwayHTTPResponse(status: 200, body: Data(body.utf8))
    }
    railway.answer("sandbox", data: ["sandbox": ["id": "sbx-stuck", "status": "RUNNING"]])
    try await ledgered(["sbx-stuck", "sbx-b"])
    let failures = try await driver(railway).sweep(keeping: [], recordsHere: true)
    XCTAssertEqual(failures.count, 1, "\(failures)")
    XCTAssertTrue(failures.first?.contains("sbx-stuck") == true, "\(failures)")
    XCTAssertEqual(destroyed(railway), ["sbx-stuck", "sbx-b"])
    left = try await ledger.entries()
    XCTAssertEqual(left.compactMap(\.sandbox), ["sbx-stuck"])
  }

  // MARK: Recording

  /// Value: protects=a sandbox whose host record was never written (the config write failed, or
  /// the app quit first) is still swept, and one whose record was written never is (review #1);
  /// fails_when=filling in the descriptor takes the sandbox off the ledger before the write, or the
  /// written record leaves it on; seam=create, record, recorded and RailwayHostDriver.sweep over
  /// StubRailway, across two drivers (a relaunch)
  func testASandboxLeavesTheLedgerOnlyOnceItsRecordIsWritten() async throws {
    let crashed = railway([Self.sandbox("sbx-1")])
    let made = driver(crashed)
    let host = try await made.create()
    var descriptor = HostDescriptor(driver: "railway")
    made.record(host, in: &descriptor)
    // The config write failed: nothing names it, and the ledger still does.
    let pending = await made.pendingSandboxes
    XCTAssertEqual(pending, ["sbx-1"])
    let swept = try await driver(crashed).sweep(keeping: [], grace: 0)
    XCTAssertEqual(swept, [])
    XCTAssertEqual(destroyed(crashed), ["sbx-1"])

    // Written this time: nothing is pending, and a relaunch's sweep asks Railway nothing.
    let recorded = railway([Self.sandbox("sbx-1")])
    let again = driver(recorded)
    let second = try await again.create()
    var written = HostDescriptor(driver: "railway")
    again.record(second, in: &written)
    await again.recorded(written)
    let none = try await driver(recorded).sweep(keeping: [], grace: 0)
    XCTAssertEqual(none, [])
    XCTAssertEqual(destroyed(recorded), [])
    XCTAssertTrue(requests(recorded, "sandboxes").isEmpty)
  }

  // MARK: Release and Nightly together

  /// A `flock` on `file` from another open file, as the other build holds it, until `release`.
  private func holdLock(_ file: URL) throws -> () -> Void {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    XCTAssertGreaterThanOrEqual(fd, 0)
    XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    let released = Mutex(false)
    let release = {
      guard
        !released.withLock({
          let was = $0
          $0 = true
          return was
        })
      else { return }
      flock(fd, LOCK_UN)
      close(fd)
    }
    addTeardownBlock(release)
    return release
  }

  /// Value: protects=Release and Nightly, which share the ledger and the Mac's key, never lose
  /// each other's ledger entries or make two keys (review #6); fails_when=a create writes the
  /// ledger, or makes the key, while the other app holds its lock; seam=create over StubRailway
  /// with the lock files held from another open file
  func testACreateWaitsForTheOtherAppsLedgerAndKeyLocks() async throws {
    for lock in ["create-ledger.lock", "keys.lock"] {
      let railway = railway([])
      let relay = RailwayHostDriverTests.StubRelay()
      let keys = root.appendingPathComponent(lock)
      let release = try holdLock(keys.appendingPathComponent(lock))
      let driver = driver(railway, keys: keys, relay: relay)
      let create = Task { try await driver.create() }
      try await Task.sleep(for: .milliseconds(300))
      XCTAssertTrue(requests(railway, "sandboxCreate").isEmpty, "\(lock): created meanwhile")
      if lock == "keys.lock" {
        XCTAssertTrue(relay.calls(to: "ssh-keygen").isEmpty, "made a key meanwhile")
      }
      release()
      _ = try await create.value
      XCTAssertEqual(requests(railway, "sandboxCreate").count, 1, lock)
    }
  }
}
