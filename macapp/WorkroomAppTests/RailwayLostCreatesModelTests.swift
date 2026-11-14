import HostDrivers
import XCTest

@testable import Workroom

/// The app's lost Railway creates (`RailwayLostCreatesModel`, review 5 of #623) over `RailwayStub`
/// and a ledger in a folder of the test's own: listed until the user resolves them, and no
/// candidate destroyed before config's records are known.
@MainActor
final class RailwayLostCreatesModelTests: XCTestCase {
  private var directory: URL!

  override func setUp() {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-railway-lost-\(UUID().uuidString)")
    let directory = directory!
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
  }

  private func stub(started: Date) -> RailwayStub {
    let stub = RailwayStub(workspaces: [
      RailwayWorkspace(id: "ws-1", name: "Mine", plan: .hobby)
    ])
    stub.projects = ["ws-1": [RailwayProject(id: "prj-1", name: "Workroom")]]
    let iso = ISO8601DateFormatter()
    stub.sandboxes = [
      [
        "id": "sbx-lost", "status": "RUNNING", "environmentId": "env-1",
        "createdAt": iso.string(from: started.addingTimeInterval(5)),
      ],
      [
        "id": "sbx-recorded", "status": "RUNNING", "environmentId": "env-1",
        "createdAt": iso.string(from: started.addingTimeInterval(3)),
      ],
    ]
    return stub
  }

  private func model(
    _ stub: RailwayStub, recorded: Set<String>?,
    grace: TimeInterval = RailwayHostDriver.sweepGrace
  ) -> RailwayLostCreatesModel {
    let api = stub.account(store: RailwayStub.MemoryStore(RailwayStub.refreshToken)).api
    let directory = self.directory!
    return RailwayLostCreatesModel(
      lost: { RailwayLostCreates(api: api, directory: directory, placement: nil) },
      recorded: { recorded }, grace: grace)
  }

  /// Value: protects=a lost create shows in a Settings or Details view already open when it
  /// leaves its grace, with no other read to bring it up (review 6, finding 3); fails_when=the
  /// model reads the ledger once while the entry is young and never again, so the notice stays
  /// hidden while a sandbox may bill; seam=RailwayLostCreatesModel.refresh over RailwayStub and a
  /// ledger, with a short grace
  func testALostCreateShowsOnceItLeavesItsGraceWithoutAnotherRead() async throws {
    try await seed(started: Date())
    // Long enough that the first read lands inside the grace on a slow CI runner: 0.5 s didn't.
    let model = model(stub(started: Date()), recorded: [], grace: 3)
    await model.refresh()
    XCTAssertEqual(model.creates, [], "a create within its grace showed")
    let deadline = Date().addingTimeInterval(15)
    while model.creates.isEmpty, Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(model.creates.count, 1, "the lost create never showed")
  }

  private func seed(started: Date) async throws {
    try await Self.seed(directory: directory, started: started)
  }

  /// A create that lost its reply, started at `started`, on the ledger in `directory`.
  nonisolated private static func seed(directory: URL, started: Date) async throws {
    try await RailwayCreateLedger(directory: directory).update {
      $0.append(
        .init(
          started: started, environmentID: "env-1", workspaceID: "ws-1", projectID: "prj-1"))
    }
  }

  /// Value: protects=before config's records are read this launch, no lost create's candidate is
  /// offered or destroyed, since a sandbox only a record names would read as one (review 5, D1);
  /// fails_when=candidates or a destroy go through with the records unknown;
  /// seam=RailwayLostCreatesModel over RailwayStub and a ledger
  func testNoCandidateIsOfferedOrDestroyedBeforeTheRecordsAreRead() async throws {
    let started = Date().addingTimeInterval(-2 * 3600)
    try await seed(started: started)
    let stub = stub(started: started)
    let model = model(stub, recorded: nil)
    await model.refresh()
    let create = try XCTUnwrap(model.creates.first)
    do {
      _ = try await model.candidates(of: create)
      XCTFail("candidates offered with the records unread")
    } catch RailwayLostCreatesModel.Failure.recordsUnread {}
    do {
      try await model.destroy("sbx-lost", of: create)
      XCTFail("destroyed with the records unread")
    } catch RailwayLostCreatesModel.Failure.recordsUnread {}
    XCTAssertEqual(stub.destroyed, [])
    XCTAssertEqual(model.creates.map(\.id), [create.id])
  }

  /// Value: protects=a lost create shows until the user destroys a candidate or dismisses it, and
  /// candidates leave out what config's records name (review 5, D1); fails_when=a resolved create
  /// still shows, a recorded sandbox is offered, or dismissing destroys anything;
  /// seam=RailwayLostCreatesModel over RailwayStub and a ledger
  func testDestroyAndDismissResolveALostCreate() async throws {
    let started = Date().addingTimeInterval(-2 * 3600)
    try await seed(started: started)
    let stub = stub(started: started)
    let model = model(stub, recorded: ["sbx-recorded"])
    await model.refresh()
    var create = try XCTUnwrap(model.creates.first)
    let candidates = try await model.candidates(of: create)
    XCTAssertEqual(candidates.map(\.id), ["sbx-lost"])
    try await model.destroy("sbx-lost", of: create)
    XCTAssertEqual(stub.destroyed, ["sbx-lost"])
    XCTAssertEqual(model.creates, [])

    try await seed(started: started)
    await model.refresh()
    create = try XCTUnwrap(model.creates.first)
    try await model.dismiss(create)
    XCTAssertEqual(model.creates, [])
    XCTAssertEqual(stub.destroyed, ["sbx-lost"], "dismissing destroyed a sandbox")
  }
}
