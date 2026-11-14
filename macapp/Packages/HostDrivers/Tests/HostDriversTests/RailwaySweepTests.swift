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
        environmentID: "env-1", projectID: "prj-1", workspaceID: "ws-1", keys: keys ?? self.keys,
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
    // The sign-in sees this Mac's workspace and the one its placement left.
    railway.answer(
      "me",
      data: [
        "me": [
          "workspaces": [
            ["id": "ws-1", "name": "Mine", "plan": "PRO"],
            ["id": "ws-old", "name": "Before", "plan": "PRO"],
          ]
        ]
      ])
    railway.answer(
      "projects", data: ["projects": ["edges": [["node": ["id": "prj-1", "name": "Workroom"]]]]])
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
    let failures = try await driver(railway).sweep(keeping: ["sbx-kept"])
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

    let failures = try await driver.sweep(keeping: [])
    XCTAssertEqual(failures, [])
    XCTAssertEqual(destroyed(railway), [])
    XCTAssertEqual(railway.graphQLRequests.count, before, "a sweep with nothing due asked Railway")
    let kept = await driver.pendingSandboxes
    XCTAssertEqual(kept, ["sbx-1", "sbx-other-build"])
  }

  // MARK: A reply that was lost

  /// A create whose `sandboxCreate` reply was lost after it was sent: its intent is on the ledger
  /// with no sandbox, written before Railway was asked.
  private func loseACreatesReply() async throws -> RailwayCreateLedger.Entry {
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
    XCTAssertEqual(entries.count, 1)
    let intent = try XCTUnwrap(entries.first)
    XCTAssertNil(intent.sandbox)
    return intent
  }

  /// Sandboxes made `seconds` after `entry`'s intent, by Railway's clock.
  private static func made(_ seconds: TimeInterval, after entry: RailwayCreateLedger.Entry)
    -> String
  {
    iso(entry.started.addingTimeInterval(seconds))
  }

  /// The lost creates this Mac's ledger holds, as the app lists them: with no grace, so a create
  /// just made counts.
  private func lostCreates(
    _ railway: StubRailway, tokens: any RailwayAccessTokenProviding = Tokens()
  )
    -> RailwayLostCreates
  {
    RailwayLostCreates(
      api: RailwayAPI(transport: railway, tokens: tokens), directory: keys,
      placement: .init(environmentID: "env-1", workspaceID: "ws-1", projectID: "prj-1"))
  }

  /// Value: protects=Workroom never guesses which sandbox a lost create made: however close to the
  /// intent Railway made a sandbox nothing names, no sweep destroys it, nor lists the environment
  /// to look (review 5, D1, the owner's decision); fails_when=any sweep, at this launch or a
  /// relaunch, destroys a sandbox whose id this Mac's ledger never held, or drops the lost entry;
  /// seam=create and RailwayHostDriver.sweep over StubRailway and the ledger
  func testTheSweepNeverDestroysASandboxWhoseIDItNeverSawWhateverItsTiming() async throws {
    let intent = try await loseACreatesReply()
    let listed = railway([
      Self.sandbox("sbx-at-once", createdAt: Self.made(0, after: intent)),
      Self.sandbox("sbx-just-after", createdAt: Self.made(4, after: intent)),
      Self.sandbox("sbx-long-after", createdAt: Self.made(3600, after: intent)),
      Self.sandbox("sbx-before", createdAt: Self.made(-3600, after: intent)),
    ])
    for sweep in 1...3 {
      // A relaunch each time: a driver of its own.
      let failures = try await driver(listed).sweep(keeping: [], grace: 0)
      XCTAssertEqual(failures, [], "sweep \(sweep)")
    }
    XCTAssertEqual(destroyed(listed), [])
    XCTAssertTrue(requests(listed, "sandboxes").isEmpty, "a sweep listed the environment")
    let left = try await ledger.entries()
    XCTAssertEqual(left, [intent], "a sweep took the lost entry off")
  }

  /// Value: protects=a lost create stays until the user resolves it: listed after every sweep and
  /// a relaunch, while one still within the grace (a create under way, perhaps in the other build)
  /// and one whose sandbox Railway named are not (review 5, D1); fails_when=a lost entry is
  /// forgotten by age or by a sweep, or a create under way or a named one shows as lost;
  /// seam=RailwayLostCreates.creates and RailwayHostDriver.sweep over StubRailway and the ledger
  func testALostCreateSurvivesEverySweepAndARelaunchUntilResolved() async throws {
    let intent = try await loseACreatesReply()
    let railway = railway([])
    try await ledger.update {
      $0 += [
        .init(started: Date(), environmentID: "env-1", workspaceID: "ws-1"),
        .init(started: Self.longAgo, sandbox: "sbx-named", environmentID: "env-1"),
      ]
    }
    let young = try await lostCreates(railway).creates()
    XCTAssertEqual(young, [], "a lost create showed within the grace")

    try await ledger.update { $0.removeAll { $0.sandbox == nil && $0.intent != intent.intent } }
    try await ledger.update { entries in
      for index in entries.indices where entries[index].intent == intent.intent {
        entries[index].started = Self.longAgo
      }
    }
    for sweep in 1...3 {
      _ = try await driver(railway).sweep(keeping: [])
      let lost = try await lostCreates(railway).creates()
      XCTAssertEqual(lost.map(\.id), [intent.intent], "sweep \(sweep)")
      XCTAssertEqual(lost.first?.environmentID, "env-1")
      XCTAssertEqual(lost.first?.workspaceID, "ws-1")
    }
  }

  /// Value: protects=a lost create's candidates are the sandboxes it might have made, read fresh
  /// each time and never written down as authority: live, unrecorded, named by no other create of
  /// this Mac, in the entry's own environment, made near the intent (review 5, D1);
  /// fails_when=a recorded, ledgered, destroyed, other-environment or far-off sandbox is offered,
  /// a candidate that went is still offered, or the candidates reach the ledger;
  /// seam=RailwayLostCreates.candidates over StubRailway and the ledger
  func testALostCreatesCandidatesAreReadFreshAndNeverKept() async throws {
    let intent = try await loseACreatesReply()
    try await ledger.update {
      $0.append(.init(started: Date(), sandbox: "sbx-ledgered", environmentID: "env-1"))
    }
    let before = try await ledger.entries()
    let rows = [
      Self.sandbox("sbx-a", createdAt: Self.made(3, after: intent)),
      Self.sandbox("sbx-b", createdAt: Self.made(200, after: intent)),
      Self.sandbox("sbx-recorded", createdAt: Self.made(2, after: intent)),
      Self.sandbox("sbx-ledgered", createdAt: Self.made(2, after: intent)),
      Self.sandbox("sbx-gone", status: "DESTROYED", createdAt: Self.made(1, after: intent)),
      Self.sandbox("sbx-far", createdAt: Self.made(-3600, after: intent)),
      Self.sandbox("sbx-unparsed", createdAt: "soon"),
    ]
    let railway = railway(rows)
    let lost = try await lostCreates(railway).creates(grace: 0)
    let create = try XCTUnwrap(lost.first)
    let first = try await lostCreates(railway).candidates(of: create, recorded: ["sbx-recorded"])
    XCTAssertEqual(first.map(\.id), ["sbx-a", "sbx-b"])
    XCTAssertEqual(
      requests(railway, "sandboxes").compactMap { $0["environmentId"] as? String }, ["env-1"])
    // Live ones only, so the pager's page cap counts live sandboxes (review 5, D2.6).
    XCTAssertEqual(requests(railway, "sandboxes").first?["active"] as? Bool, true)

    // sbx-a is gone from Railway now: the next read doesn't offer it.
    let later = self.railway(Array(rows.dropFirst()))
    let second = try await lostCreates(later).candidates(of: create, recorded: ["sbx-recorded"])
    XCTAssertEqual(second.map(\.id), ["sbx-b"])
    let after = try await ledger.entries()
    XCTAssertEqual(after, before, "reading candidates changed the ledger")
  }

  /// Value: protects=the user resolves a lost create by destroying the one candidate they choose,
  /// and only a sandbox that is still a candidate: never a recorded one, one another create names,
  /// or one in another environment, and the entry stays when Railway didn't confirm the destroy
  /// (review 5, D1); fails_when=a destroy reaches a non-candidate, the entry outlives a confirmed
  /// destroy, or goes with an unconfirmed one; seam=RailwayLostCreates.destroy over StubRailway
  /// and the ledger
  func testDestroyingALostCreatesCandidateResolvesIt() async throws {
    let intent = try await loseACreatesReply()
    let railway = railway([
      Self.sandbox("sbx-a", createdAt: Self.made(3, after: intent)),
      Self.sandbox("sbx-recorded", createdAt: Self.made(2, after: intent)),
      Self.sandbox("sbx-far", createdAt: Self.made(-3600, after: intent)),
    ])
    let lost = lostCreates(railway)
    let creates = try await lost.creates(grace: 0)
    let create = try XCTUnwrap(creates.first)
    for refused in ["sbx-recorded", "sbx-far", "sbx-nowhere"] {
      do {
        try await lost.destroy(refused, of: create, recorded: ["sbx-recorded"])
        XCTFail("\(refused): destroyed a sandbox that is no candidate")
      } catch RailwayLostCreates.Failure.notACandidate {}
    }
    XCTAssertEqual(destroyed(railway), [])

    // Railway refuses, and still has it: unconfirmed, so the entry stays.
    railway.answer("sandboxDestroy") { _ in
      RailwayHTTPResponse(
        status: 200, body: Data(#"{"errors":[{"message":"Railway is down"}]}"#.utf8))
    }
    railway.answer("sandbox", data: ["sandbox": ["id": "sbx-a", "status": "RUNNING"]])
    do {
      try await lost.destroy("sbx-a", of: create, recorded: ["sbx-recorded"])
      XCTFail("an unconfirmed destroy resolved the lost create")
    } catch RailwayLostCreates.Failure.unconfirmed {}
    var left = try await ledger.entries()
    XCTAssertEqual(left.map(\.intent), [intent.intent])

    railway.answer(
      "sandboxDestroy", data: ["sandboxDestroy": ["id": "sbx-a", "status": "DESTROYING"]])
    try await lost.destroy("sbx-a", of: create, recorded: ["sbx-recorded"])
    XCTAssertEqual(destroyed(railway), ["sbx-a"])
    XCTAssertEqual(
      requests(railway, "sandboxDestroy").compactMap { $0["environmentId"] as? String }.last,
      "env-1")
    left = try await ledger.entries()
    XCTAssertEqual(left, [])
  }

  /// Value: protects=the user can dismiss a lost create's notice without destroying anything, even
  /// signed out, and only that create's entry goes (review 5, D1); fails_when=dismissing destroys
  /// a sandbox, needs Railway, or takes another entry off; seam=RailwayLostCreates.dismiss over
  /// StubRailway and the ledger
  func testDismissingALostCreateResolvesItWithoutDestroyingAnything() async throws {
    let intent = try await loseACreatesReply()
    try await ledger.update { $0.append(.init(started: Self.longAgo, sandbox: "sbx-named")) }
    let railway = railway([Self.sandbox("sbx-a", createdAt: Self.made(3, after: intent))])
    let lost = lostCreates(railway, tokens: SignedOut())
    let creates = try await lost.creates(grace: 0)
    let create = try XCTUnwrap(creates.first)
    let asked = railway.graphQLRequests.count
    try await lost.dismiss(create)
    XCTAssertEqual(railway.graphQLRequests.count, asked, "dismissing asked Railway")
    let left = try await ledger.entries()
    XCTAssertEqual(left.compactMap(\.sandbox), ["sbx-named"])
    let none = try await lost.creates(grace: 0)
    XCTAssertEqual(none, [])
  }

  /// Value: protects=the lost-create cells beyond today's environment (review 5, D1 and D2.11): an
  /// entry made in an environment the placement left lists and destroys there; one in a workspace
  /// the sign-in can't see lists nothing (an unseen environment would list as empty) but can
  /// still be dismissed; a legacy entry with no placement to place it can't list; and a create
  /// already resolved, by the other build perhaps, destroys nothing; fails_when=candidates come
  /// from or a destroy goes to another environment, an unseen workspace is listed, or a resolved
  /// create's candidate is destroyed; seam=RailwayLostCreates over StubRailway and the ledger
  func testALostCreateIsResolvedInItsOwnEnvironmentOrSaysWhyNot() async throws {
    let started = Self.longAgo
    let at = Self.iso(started.addingTimeInterval(4))
    try await ledger.update {
      $0 = [
        .init(started: started, environmentID: "env-old", workspaceID: "ws-old"),
        .init(started: started, environmentID: "env-hidden", workspaceID: "ws-hidden"),
        .init(started: started),
      ]
    }
    let railway = railway([Self.sandbox("sbx-old", createdAt: at, environment: "env-old")])
    // A legacy entry with no placement to say where it was made.
    let unplaced = RailwayLostCreates(
      api: RailwayAPI(transport: railway, tokens: Tokens()), directory: keys, placement: nil)
    let creates = try await unplaced.creates()
    XCTAssertEqual(creates.count, 3)
    let old = try XCTUnwrap(creates.first { $0.environmentID == "env-old" })
    let hidden = try XCTUnwrap(creates.first { $0.environmentID == "env-hidden" })
    let legacy = try XCTUnwrap(creates.first { $0.environmentID == nil })

    let found = try await unplaced.candidates(of: old, recorded: [])
    XCTAssertEqual(found.map(\.id), ["sbx-old"])
    try await unplaced.destroy("sbx-old", of: old, recorded: [])
    XCTAssertEqual(
      requests(railway, "sandboxDestroy").map {
        "\($0["id"] as? String ?? "?")@\($0["environmentId"] as? String ?? "?")"
      }, ["sbx-old@env-old"])

    let listed = requests(railway, "sandboxes").count
    do {
      _ = try await unplaced.candidates(of: hidden, recorded: [])
      XCTFail("listed an environment the sign-in can't see")
    } catch RailwayLostCreates.Failure.workspaceNotSeen {}
    XCTAssertEqual(requests(railway, "sandboxes").count, listed)
    try await unplaced.dismiss(hidden)

    do {
      _ = try await unplaced.candidates(of: legacy, recorded: [])
      XCTFail("listed for an entry with no environment")
    } catch RailwayLostCreates.Failure.placeUnknown {}

    // Resolved already (its destroy above took it off): its candidate is left alone.
    try await unplaced.dismiss(legacy)
    do {
      try await unplaced.destroy("sbx-old", of: old, recorded: [])
      XCTFail("a resolved create destroyed a sandbox")
    } catch RailwayLostCreates.Failure.resolved {}
    XCTAssertEqual(requests(railway, "sandboxDestroy").count, 1)
    let left = try await ledger.entries()
    XCTAssertEqual(left, [])
  }

  /// Value: protects=a Railway whose `sandboxes` has no `active` argument still lists, without it,
  /// rather than failing every placement move and lost create's candidates (review 5, D2.6, whose
  /// argument no live check has read yet); fails_when=a refusal naming the argument fails the
  /// listing, or any other GraphQL error is retried; seam=RailwayAPI.sandboxes over StubRailway
  func testAListingFallsBackWhenRailwayRefusesTheActiveFilter() async throws {
    let railway = railway([])
    railway.answer("sandboxes") { request in
      let variables = StubRailway.graphQLBody(request)["variables"] as? [String: Any] ?? [:]
      let answer: [String: Any] =
        variables["active"] != nil
        ? ["errors": [["message": #"Unknown argument "active" on field "Query.sandboxes"."#]]]
        : [
          "data": [
            "sandboxes": StubRailway.lastPage([
              ["id": "sbx-a", "status": "RUNNING", "environmentId": "env-1"]
            ])
          ]
        ]
      return RailwayHTTPResponse(
        status: 200, body: try JSONSerialization.data(withJSONObject: answer))
    }
    let api = RailwayAPI(transport: railway, tokens: Tokens())
    let listed = try await api.sandboxes(environmentID: "env-1")
    XCTAssertEqual(listed.map(\.id), ["sbx-a"])

    railway.answer("sandboxes") { _ in
      RailwayHTTPResponse(
        status: 200, body: Data(#"{"errors":[{"message":"Railway is down"}]}"#.utf8))
    }
    let before = requests(railway, "sandboxes").count
    do {
      _ = try await api.sandboxes(environmentID: "env-1")
      XCTFail("a failed listing read as a list")
    } catch RailwayAPIError.graphQL {}
    XCTAssertEqual(requests(railway, "sandboxes").count, before + 1, "another error was retried")
  }

  /// Value: protects=a ledger an earlier build wrote, with the candidates it kept for an ambiguous
  /// lost reply, still reads, so its lost create is listed rather than set aside unreadable
  /// (review 5, D1); fails_when=the old `candidates` key makes the ledger unreadable;
  /// seam=RailwayCreateLedger.entries and RailwayLostCreates.creates over the ledger's file
  func testALedgerAnEarlierBuildWroteWithCandidatesStillReads() async throws {
    let intent = UUID()
    let rows: [[String: Any]] = [
      [
        "intent": intent.uuidString, "started": Self.iso(Self.longAgo),
        "environmentID": "env-1", "workspaceID": "ws-1", "candidates": ["sbx-a", "sbx-b"],
      ]
    ]
    try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: rows).write(
      to: keys.appendingPathComponent("create-ledger.json"))
    let lost = try await lostCreates(railway([])).creates()
    XCTAssertEqual(lost.map(\.id), [intent])
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
      (
        "200 with errors and partial data",
        200, #"{"data":{"sandboxCreate":null},"errors":[{"message":"timeout"}]}"#, true
      ),
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

  /// Tokens that hand out one until `fail` is set, then throw it, as a sign-out, a failed refresh
  /// or a cancel does before a request goes out.
  private final class FailingTokens: RailwayAccessTokenProviding, Sendable {
    let failure = Mutex<(any Error)?>(nil)
    func accessToken() async throws -> String {
      if let error = failure.withLock({ $0 }) { throw error }
      return "at-1"
    }
    func accessTokenRejected(_ token: String) async {}
  }

  /// Value: protects=a create whose `sandboxCreate` never reached Railway (signed out, a refresh
  /// that failed, a cancel before sending, a second token that failed after a 401) drops its
  /// intent, so no phantom lost create is shown for the user to resolve, while one
  /// whose request went out and lost its answer keeps it (review 4, X4); fails_when=a failure
  /// before anything was sent keeps the intent, or a lost link after sending drops it;
  /// seam=create over StubRailway with a token provider that fails from the create's request on
  func testACreateThatSentNothingToRailwayDropsItsIntent() async throws {
    let rows: [(name: String, failure: any Error, answer: Int?, kept: Bool)] = [
      ("signed out", RailwaySessionError.signedOut, nil, false),
      ("refresh failed", URLError(.notConnectedToInternet), nil, false),
      ("cancelled before sending", CancellationError(), nil, false),
      ("a 401, then no token", RailwaySessionError.signedOut, 401, false),
      ("the link lost after sending", URLError(.networkConnectionLost), 0, true),
    ]
    for row in rows {
      try await ledger.update { $0 = [] }
      try? FileManager.default.removeItem(at: keys.appendingPathComponent("id_ed25519"))
      let railway = railway([])
      let tokens = FailingTokens()
      switch row.answer {
      case nil:
        // The Mac's key is registered: the create's next request is its sandboxCreate.
        railway.answer("sshPublicKeyCreate") { _ in
          tokens.failure.withLock { $0 = row.failure }
          return RailwayHTTPResponse(
            status: 200, body: Data(#"{"data":{"sshPublicKeyCreate":{"id":"key-1"}}}"#.utf8))
        }
      case 401:
        railway.answer("sandboxCreate") { _ in
          tokens.failure.withLock { $0 = row.failure }
          return RailwayHTTPResponse(status: 401, body: Data())
        }
      default:
        railway.answer("sandboxCreate") { _ in throw row.failure }
      }
      do {
        _ = try await driver(railway, tokens: tokens).create()
        XCTFail("\(row.name): the create went through")
      } catch {}
      let left = try await ledger.entries()
      XCTAssertEqual(left.count, row.kept ? 1 : 0, row.name)
    }
  }

  /// Value: protects=a sweep that needs the workspaces Railway couldn't list is owed again, and
  /// one destroy Railway refused is reported without stopping the rest; fails_when=a signed-out
  /// sweep reads as a workspace the sign-in can't see and drops the entry, or a refused destroy is
  /// lost, ends the sweep, or leaves the ledger; seam=RailwayHostDriver.sweep over StubRailway
  func testASweepRailwayCannotAnswerThrowsAndARefusedDestroyIsReported() async throws {
    try writeLedger([("sbx-old", "env-old", "ws-old")])
    do {
      _ = try await driver(railway([Self.sandbox("sbx-a")]), tokens: SignedOut()).sweep(
        keeping: [])
      XCTFail("a signed-out sweep went through")
    } catch RailwaySessionError.signedOut {}
    var left = try await ledger.entries()
    XCTAssertEqual(left.count, 1, "the entry wasn't owed again")
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
    let failures = try await driver(railway).sweep(keeping: [])
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

  /// Value: protects=every way a create ends takes its own ledger entry off, whether or not
  /// Railway's sandbox id made it into the entry, so no entry outlives its sandbox to be shown
  /// as a lost create (review 3, I2 and I6); fails_when=an entry whose id write failed
  /// stays after its host is recorded, destroyed or undone, or a named entry stays after a
  /// destroy or an undo; seam=create, recorded, destroy and the create's undo over StubRailway
  /// and the ledger, with the ledger's folder read-only while the id is written
  func testEveryWayOutOfACreateTakesItsEntryOff() async throws {
    enum Way: String { case recorded, destroy, undo }
    for (named, way) in [
      (false, Way.recorded), (false, .destroy), (false, .undo), (true, .destroy), (true, .undo),
    ] {
      let cell = "\(named ? "named" : "lost-reply") entry × \(way)"
      let keys = root.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: keys.appendingPathComponent("hosts"), withIntermediateDirectories: true)
      let railway = railway([])
      let path = keys.path
      if !named {
        // The id write fails: the folder is read-only from Railway's answer to the first read.
        railway.answer("sandboxCreate") { _ in
          chmod(path, 0o500)
          return RailwayHTTPResponse(
            status: 200,
            body: Data(#"{"data":{"sandboxCreate":{"id":"sbx-1","status":"CREATING"}}}"#.utf8))
        }
      }
      let status = way == .undo ? "FAILED" : "RUNNING"
      railway.answer("sandbox") { _ in
        chmod(path, 0o700)
        return RailwayHTTPResponse(
          status: 200,
          body: Data(#"{"data":{"sandbox":{"id":"sbx-1","status":"\#(status)"}}}"#.utf8))
      }
      addTeardownBlock { chmod(path, 0o700) }
      let driver = driver(railway, keys: keys)
      let ledger = RailwayCreateLedger(directory: keys)
      do {
        let host = try await driver.create()
        let during = try await ledger.entries()
        XCTAssertEqual(during.count, 1, cell)
        XCTAssertEqual(during.first?.sandbox, named ? "sbx-1" : nil, cell)
        switch way {
        case .recorded:
          var descriptor = HostDescriptor(driver: "railway")
          driver.record(host, in: &descriptor)
          await driver.recorded(descriptor)
        case .destroy: try await driver.destroy(host)
        case .undo: XCTFail("\(cell): a failed sandbox became a host")
        }
      } catch {
        XCTAssertEqual(way, .undo, "\(cell): \(error)")
      }
      let left = try await ledger.entries()
      XCTAssertEqual(left, [], cell)
    }
  }

  /// Value: protects=a create whose undo couldn't destroy its sandbox keeps its ledger entry, named
  /// or not; the driver that holds the sandbox never sweeps it from under itself; and a relaunch's
  /// sweep destroys it by its id, or keeps an entry with no id for the user (review 4, Y6: the
  /// undo-destroy-fails and sweep-held cells; review 5, D1); fails_when=a failed undo drops the
  /// entry, so the sandbox bills with nothing to find it, a sweep destroys a sandbox its own
  /// driver holds, or one whose id it never saw; seam=create, the
  /// create's undo and RailwayHostDriver.sweep over StubRailway and the ledger, the ledger's
  /// folder read-only while the id is written
  func testAnUndoThatCouldNotDestroyKeepsItsEntryForALaterSweep() async throws {
    for named in [true, false] {
      let cell = named ? "named" : "lost-reply"
      let keys = root.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: keys.appendingPathComponent("hosts"), withIntermediateDirectories: true)
      let railway = railway([Self.sandbox("sbx-1", createdAt: Self.iso(Date()))])
      let path = keys.path
      if !named {
        railway.answer("sandboxCreate") { _ in
          chmod(path, 0o500)
          return RailwayHTTPResponse(
            status: 200,
            body: Data(#"{"data":{"sandboxCreate":{"id":"sbx-1","status":"CREATING"}}}"#.utf8))
        }
      }
      // It fails to start, and Railway won't destroy it: still destroying after the try, which
      // may bill on.
      let tried = Mutex(false)
      railway.answer("sandbox") { _ in
        chmod(path, 0o700)
        let status = tried.withLock { $0 } ? "DESTROYING" : "FAILED"
        return RailwayHTTPResponse(
          status: 200,
          body: Data(#"{"data":{"sandbox":{"id":"sbx-1","status":"\#(status)"}}}"#.utf8))
      }
      railway.answer("sandboxDestroy") { _ in
        tried.withLock { $0 = true }
        return RailwayHTTPResponse(
          status: 200, body: Data(#"{"errors":[{"message":"Railway is down"}]}"#.utf8))
      }
      addTeardownBlock { chmod(path, 0o700) }
      let made = driver(railway, keys: keys)
      let ledger = RailwayCreateLedger(directory: keys)
      do {
        _ = try await made.create()
        XCTFail("\(cell): a failed sandbox became a host")
      } catch HostDriverError.leftBehind {}
      var left = try await ledger.entries()
      XCTAssertEqual(left.count, 1, "\(cell): the failed undo dropped its entry")
      XCTAssertEqual(left.first?.sandbox, named ? "sbx-1" : nil, cell)

      // The driver still holds it: its own sweep leaves it.
      railway.answer(
        "sandboxDestroy", data: ["sandboxDestroy": ["id": "sbx-1", "status": "DESTROYING"]])
      // The undo's own tries.
      let undone = requests(railway, "sandboxDestroy").count
      let own = try await made.sweep(keeping: [], grace: 0)
      XCTAssertEqual(own, [], cell)
      XCTAssertEqual(
        requests(railway, "sandboxDestroy").count, undone,
        "\(cell): swept a sandbox its driver holds")

      // A relaunch's sweep destroys it by its id; one whose id never reached the ledger is never
      // guessed at, and waits for the user (`RailwayLostCreates`).
      let swept = try await driver(railway, keys: keys).sweep(keeping: [], grace: 0)
      XCTAssertEqual(swept, [], cell)
      XCTAssertEqual(
        requests(railway, "sandboxDestroy").dropFirst(undone).compactMap { $0["id"] as? String },
        named ? ["sbx-1"] : [], cell)
      left = try await ledger.entries()
      XCTAssertEqual(left.count, named ? 0 : 1, cell)
    }
  }

  // MARK: The environment each create was made in

  /// The ledger as a build before entries named their environment, or as this one writes them:
  /// `(sandbox, environment, workspace)` per entry, made long ago.
  private func writeLedger(_ entries: [(String?, String?, String?)]) throws {
    let started = ISO8601DateFormatter().string(from: Self.longAgo)
    let rows: [[String: Any]] = entries.map { sandbox, environment, workspace in
      var row: [String: Any] = ["intent": UUID().uuidString, "started": started]
      if let sandbox { row["sandbox"] = sandbox }
      if let environment { row["environmentID"] = environment }
      if let workspace { row["workspaceID"] = workspace }
      return row
    }
    try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: rows).write(
      to: keys.appendingPathComponent("create-ledger.json"))
  }

  /// Value: protects=a sandbox made before this Mac's placement moved is destroyed in the
  /// environment it was made in, and one in a workspace this sign-in can't see is kept for a
  /// sign-in that can, never dropped or destroyed by today's placement (review 3, C2);
  /// fails_when=the sweep destroys by today's environment, drops an entry it can't see, lists an
  /// environment it can't see, or reads a ledger from before entries named their environment as
  /// empty; seam=RailwayHostDriver.sweep over StubRailway and the ledger
  func testTheSweepDestroysEachEntryInTheEnvironmentItWasMadeIn() async throws {
    try writeLedger([
      ("sbx-old", "env-old", "ws-old"),
      ("sbx-hidden", "env-hidden", "ws-hidden"),
      (nil, "env-hidden", "ws-hidden"),
      ("sbx-legacy", nil, nil),
    ])
    let railway = railway([])
    let failures = try await driver(railway).sweep(keeping: [])

    let destroys = requests(railway, "sandboxDestroy").map {
      "\($0["id"] as? String ?? "?")@\($0["environmentId"] as? String ?? "?")"
    }
    XCTAssertEqual(Set(destroys), ["sbx-old@env-old", "sbx-legacy@env-1"])
    XCTAssertFalse(
      requests(railway, "sandboxes").contains { $0["environmentId"] as? String == "env-hidden" },
      "listed an environment the sign-in can't see")
    let left = try await ledger.entries()
    XCTAssertEqual(left.count, 2, "\(left)")
    XCTAssertTrue(left.allSatisfy { $0.environmentID == "env-hidden" }, "\(left)")
    XCTAssertTrue(failures.contains { $0.contains("sbx-hidden") }, "\(failures)")
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
