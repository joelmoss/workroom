import Foundation
import WorkroomDomain
import XCTest

/// `HostKind` and `HostDescriptor`'s typed views (ADR 0066). The strings here are stored contracts:
/// config.json's `driver` and `state`, the `WORKROOM_HOST` scripts read, and the keys Settings
/// saves host options under.
final class HostKindTests: XCTestCase {
  private static let every = HostKind.all

  /// Value: protects=a recorded host keeps its driver across builds; fails_when=a kind's `driver`
  /// string or its parse drifts, so config.json's hosts read as unknown and stop opening;
  /// why_new=the four provider enums merged into one; seam=none; no_claim=the drivers themselves
  func testEachKindIsTheDriverItNames() {
    XCTAssertEqual(
      Self.every.map(\.driver),
      ["container", "apple-container", "boxd", "exedev", "railway", "ssh"])
    for kind in Self.every {
      XCTAssertEqual(HostKind(driver: kind.driver), kind, kind.driver)
    }
    XCTAssertNil(HostKind(driver: "future"))
    XCTAssertNil(HostKind(driver: ""))
    XCTAssertNil(HostKind(driver: "exeDev"), "the Settings key is not a driver")
  }

  func testScriptsAreToldThePlainName() {
    XCTAssertEqual(
      Self.every.map(\.workroomHost), ["docker", "apple", "boxd", "exedev", "railway", "ssh"])
  }

  /// Value: protects=the host options a user saved in Settings; fails_when=a kind's key is taken
  /// from its `driver` (`exedev`), and every saved exe.dev option is lost; why_new=HostProvider's
  /// raw value was the key; seam=none; no_claim=Defaults itself
  func testOnlyBoxdAndExeDevTakeHostOptionsUnderTheirSavedKeys() {
    XCTAssertEqual(
      Self.every.filter(\.takesHostOptions), [.boxd, .exeDev], "the Settings order changed")
    XCTAssertEqual(Self.every.compactMap(\.hostOptionsKey), ["boxd", "exeDev"])
    XCTAssertEqual(HostKind.boxd.hostImageKind, .snapshot)
    XCTAssertEqual(HostKind.exeDev.hostImageKind, .containerImage)
    for kind in Self.every where !kind.takesHostOptions {
      XCTAssertNil(kind.hostImageKind, kind.driver)
      XCTAssertNil(
        HostOptions.resolve(for: kind, create: nil, project: nil, settings: nil), kind.driver)
    }
  }

  func testOnlyAContainerIsOnThisMac() {
    XCTAssertEqual(
      Self.every.map(\.isRemoteProvider), [false, false, true, true, true, true])
    XCTAssertEqual(
      HostKind.remoteProviders, [.boxd, .exeDev, .railway, .ssh], "the menu's order changed")
  }

  /// Value: protects=a Railway workroom reached again after a relaunch; fails_when=the sandbox,
  /// environment or pinned key is lost or renamed in config.json; why_new=#629; seam=none;
  /// no_claim=the driver's use of it
  func testARailwayRecordSurvivesConfigUnderItsStoredKeys() throws {
    let record = RailwayHostRecord(
      projectID: "prj", environmentID: "env", sandboxID: "sbx", hostKey: "ssh-ed25519 AAAA")
    let data = try JSONEncoder().encode(HostDescriptor(driver: "railway", railway: record))
    let json = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])["railway"]
    XCTAssertEqual(
      json as? [String: String],
      [
        "project_id": "prj", "environment_id": "env", "sandbox_id": "sbx",
        "host_key": "ssh-ed25519 AAAA",
      ])
    let read = try JSONDecoder().decode(HostDescriptor.self, from: data)
    XCTAssertEqual(read.kind, .railway)
    XCTAssertEqual(read.railway, record)
  }

  /// Value: protects=a host this build can't name is never handled as one it can; fails_when=a
  /// missing or unknown driver reads as some kind (a boxd host once fell back to Docker);
  /// why_new=typed view over the string; seam=none; no_claim=the delete's own Docker fallback
  func testADescriptorsKindIsNilForADriverThisBuildDoesntKnow() throws {
    XCTAssertEqual(HostDescriptor(driver: "boxd").kind, .boxd)
    XCTAssertEqual(HostDescriptor(driver: "apple-container").kind, .container(.apple))
    XCTAssertNil(HostDescriptor().kind, "no driver is not Docker here")
    let future = try JSONDecoder().decode(
      HostDescriptor.self,
      from: Data(#"{"driver":"future","state":"migrating","account":"usr_1"}"#.utf8))
    XCTAssertNil(future.kind)
    XCTAssertEqual(future.driver, "future")
    XCTAssertEqual(future.account, "usr_1")
  }

  func testLifecycleReadsEveryState() {
    XCTAssertEqual(HostDescriptor().lifecycle, .serving)
    XCTAssertEqual(HostDescriptor(state: "creating").lifecycle, .creating)
    XCTAssertEqual(HostDescriptor(state: "failed").lifecycle, .failed)
    XCTAssertEqual(HostDescriptor(state: "destroyed").lifecycle, .destroyed)
    XCTAssertTrue(HostDescriptor(state: "destroyed").isDestroyed)
    XCTAssertFalse(HostDescriptor(state: "failed").isDestroyed)
  }

  /// Value: protects=a host a newer build put in a state this one doesn't know; fails_when=an
  /// unknown state reads as serving (its panes would open on a host that isn't ready) or is
  /// rewritten; why_new=typed view over the string; seam=none; no_claim=what a newer build means
  func testAnUnknownStateIsKeptAndIsNotServing() throws {
    var host = try JSONDecoder().decode(
      HostDescriptor.self, from: Data(#"{"driver":"boxd","state":"migrating"}"#.utf8))
    XCTAssertEqual(host.lifecycle, .unknown("migrating"))
    XCTAssertNotEqual(host.lifecycle, .serving)

    host.lifecycle = host.lifecycle
    XCTAssertEqual(host.state, "migrating")
    let again = try JSONDecoder().decode(HostDescriptor.self, from: JSONEncoder().encode(host))
    XCTAssertEqual(again.state, "migrating")
  }

  /// The CLI reads `destroyed` itself (ADR 0040), so the written string is a contract.
  func testSettingALifecycleWritesItsState() {
    var host = HostDescriptor(driver: "ssh")
    host.lifecycle = .creating
    XCTAssertEqual(host.state, "creating")
    host.lifecycle = .failed
    XCTAssertEqual(host.state, "failed")
    host.lifecycle = .destroyed
    XCTAssertEqual(host.state, "destroyed")
    host.lifecycle = .serving
    XCTAssertNil(host.state)
  }
}
