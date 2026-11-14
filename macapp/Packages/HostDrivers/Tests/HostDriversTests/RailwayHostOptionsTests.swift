import Foundation
import Synchronization
import WorkroomDomain
import WorkroomSystem
import XCTest

@testable import HostDrivers

/// A Railway host's host options (#633): its region, size and host image (Railway's default or a
/// checkpoint in this Mac's environment), and the checkout a checkpoint carries cleared with the
/// `gh` token. Railway is stubbed at HTTP (`StubRailway`) and ssh through the command runner
/// (`StubRelay`).
final class RailwayHostOptionsTests: XCTestCase {
  typealias StubRelay = RailwayHostDriverTests.StubRelay

  static let token = "gho_FAKE_test_token_0633"

  private final class Tokens: RailwayAccessTokenProviding, Sendable {
    func accessToken() async throws -> String { "at-1" }
    func accessTokenRejected(_ token: String) async {}
  }

  private var root: URL!

  override func setUp() {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-railway-options-\(UUID().uuidString)")
    let root = root!
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
  }

  /// A Railway that makes `sbx-1`, RUNNING at once, whose environment `env-1` holds the
  /// checkpoint `prepared`, in a Hobby workspace `ws-1`.
  private func railway(checkpoints: [String] = ["prepared"]) -> StubRailway {
    let railway = StubRailway()
    railway.answer("sshPublicKeys", data: ["sshPublicKeys": StubRailway.lastPage([])])
    railway.answer("sshPublicKeyCreate", data: ["sshPublicKeyCreate": ["id": "key-1"]])
    railway.answer(
      "sandboxCreate", data: ["sandboxCreate": ["id": "sbx-1", "status": "CREATING"]])
    railway.answer("sandbox", data: ["sandbox": ["id": "sbx-1", "status": "RUNNING"]])
    railway.answer(
      "sandboxDestroy", data: ["sandboxDestroy": ["id": "sbx-1", "status": "DESTROYING"]])
    railway.answer(
      "sandboxCheckpoints",
      data: [
        "sandboxCheckpoints": checkpoints.map {
          [
            "id": $0, "key": $0, "environmentId": "env-1",
            "createdAt": "2026-11-13T10:00:00Z",
          ]
        }
      ])
    railway.answer(
      "me",
      data: [
        "me": [
          "workspaces": [
            ["id": "ws-0", "name": "Other", "plan": "PRO"],
            ["id": "ws-1", "name": "Mine", "plan": "HOBBY"],
          ]
        ]
      ])
    return railway
  }

  private func driver(_ railway: StubRailway, _ relay: StubRelay) -> RailwayHostDriver {
    let token: @Sendable () async throws -> String = { Self.token }
    return RailwayHostDriver(
      configuration: .init(
        environmentID: "env-1", projectID: "prj-1", workspaceID: "ws-1",
        keys: root.appendingPathComponent("railway"),
        relayHost: RailwayHostDriverTests.relayHost, hostSetup: .checkout,
        pollInterval: .milliseconds(1), gitHubToken: token),
      api: RailwayAPI(transport: railway, tokens: Tokens()),
      directory: root.appendingPathComponent("hosts"), runner: relay)
  }

  private func sent(_ railway: StubRailway, _ field: String) -> [[String: Any]] {
    railway.graphQLRequests.map(StubRailway.graphQLBody)
      .filter { ($0["query"] as? String)?.contains("\(field)(") == true }
      .compactMap { $0["variables"] as? [String: Any] }
  }

  // MARK: Create

  /// Value: protects=a Railway host is made in the region and size and from the checkpoint its
  /// host options resolved (stories 19, 20, 22), still never idling out; fails_when=an option is
  /// dropped, sent under another name, memory isn't a number of GB, or the idle timeout returns;
  /// why_new=#633; seam=OptionedProvisioningDriver.create over StubRailway; no_claim=that live
  /// Railway accepts these shapes (from the TypeScript SDK's `SandboxCreateInput`)
  func testACreateSendsTheResolvedRegionSizeAndCheckpoint() async throws {
    let railway = railway()
    let driver = driver(railway, StubRelay())

    _ = try await driver.create(
      options: ResolvedHostOptions(
        image: "prepared", cpu: 4, memory: "8GB", region: "europe-west4-drams3a"))

    let input = try XCTUnwrap(sent(railway, "sandboxCreate").last?["input"] as? [String: Any])
    XCTAssertEqual(input["environmentId"] as? String, "env-1")
    XCTAssertEqual(input["idleTimeoutMinutes"] as? Int, 0)
    XCTAssertEqual(input["region"] as? String, "europe-west4-drams3a")
    let resources = try XCTUnwrap(input["resources"] as? [String: Any])
    XCTAssertEqual(resources["cpu"] as? Double, 4)
    XCTAssertEqual(resources["memoryGB"] as? Double, 8)
    XCTAssertEqual((input["template"] as? [String: Any])?["name"] as? String, "prepared")
  }

  /// Value: protects=Railway's own defaults when nothing is chosen; fails_when=a create with no
  /// options sends a region, size or template of Workroom's making; seam=create over StubRailway
  func testACreateOnProviderDefaultsSendsNoOptions() async throws {
    let railway = railway()
    _ = try await driver(railway, StubRelay()).create(options: ResolvedHostOptions())

    let input = try XCTUnwrap(sent(railway, "sandboxCreate").last?["input"] as? [String: Any])
    XCTAssertEqual(Set(input.keys), ["environmentId", "idleTimeoutMinutes"])
    XCTAssertTrue(sent(railway, "sandboxCheckpoints").isEmpty, "a default image read checkpoints")
  }

  /// Value: protects=a checkpoint is used only on the Mac whose environment holds it (story 23);
  /// fails_when=a checkpoint saved at a level another Mac shares makes a sandbox here, or fails
  /// only after a sandbox bills; why_new=#633, ADR 0071; seam=create over StubRailway
  func testACheckpointNotInThisMacsEnvironmentIsRefusedBeforeAnySandbox() async throws {
    let railway = railway(checkpoints: ["mine"])
    do {
      _ = try await driver(railway, StubRelay()).create(
        options: ResolvedHostOptions(image: "elsewhere"))
      XCTFail("a checkpoint from another environment made a host")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertTrue(detail.contains("elsewhere"), detail)
      XCTAssertTrue(detail.contains("checkpoint"), detail)
    }
    XCTAssertEqual(sent(railway, "sandboxCheckpoints").last?["environmentId"] as? String, "env-1")
    XCTAssertTrue(sent(railway, "sandboxCreate").isEmpty, "a sandbox was made")
  }

  /// Value: protects=a typo'd memory size fails with its reason before anything bills;
  /// fails_when=an unreadable size is sent, or dropped silently; seam=create over StubRailway
  func testAnUnreadableMemorySizeIsRefusedBeforeAnySandbox() async throws {
    let railway = railway()
    do {
      _ = try await driver(railway, StubRelay()).create(
        options: ResolvedHostOptions(memory: "lots"))
      XCTFail("an unreadable memory size made a host")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertTrue(detail.contains("lots"), detail)
    }
    XCTAssertTrue(sent(railway, "sandboxCreate").isEmpty, "a sandbox was made")
  }

  // MARK: Reading the options

  /// Value: protects=the option fields offer only this Mac's checkpoints, and sizes up to the
  /// workspace's plan maximum (stories 20, 23); fails_when=checkpoints are listed from another
  /// environment, or the size is another workspace's plan; why_new=#633;
  /// seam=HostOptionsReading.readHostOptions over StubRailway; no_claim=the plan maxima, from
  /// Railway's docs table (no API field gives them)
  func testTheOptionsReadListsThisEnvironmentsCheckpointsAndThePlansSizes() async throws {
    let railway = railway(checkpoints: ["prepared", "node-22"])

    let facts = try await driver(railway, StubRelay()).readHostOptions()

    XCTAssertEqual(
      facts,
      .railway(
        RailwayHostOptions(
          checkpoints: ["prepared", "node-22"],
          size: RailwayHostOptions.Size(vcpu: 4, memoryGB: 4, maxVCPU: 8, maxMemoryGB: 8))))
    XCTAssertEqual(sent(railway, "sandboxCheckpoints").last?["environmentId"] as? String, "env-1")
  }

  /// Value: protects=a plan Workroom doesn't know still shows its checkpoints; fails_when=an
  /// unknown plan fails the read, or is given a made-up maximum; seam=readHostOptions
  func testAnUnknownPlanReadsNoSize() async throws {
    let railway = railway()
    railway.answer(
      "me", data: ["me": ["workspaces": [["id": "ws-1", "name": "Mine", "plan": "ENTERPRISE"]]]])

    let facts = try await driver(railway, StubRelay()).readHostOptions()

    XCTAssertEqual(facts, .railway(RailwayHostOptions(checkpoints: ["prepared"], size: nil)))
  }

  func testPlanSizesFollowRailwaysTable() {
    XCTAssertEqual(
      RailwayHostOptions.Size(plan: .free),
      RailwayHostOptions.Size(vcpu: 2, memoryGB: 2, maxVCPU: 2, maxMemoryGB: 2))
    XCTAssertEqual(
      RailwayHostOptions.Size(plan: .pro),
      RailwayHostOptions.Size(vcpu: 8, memoryGB: 8, maxVCPU: 32, maxMemoryGB: 32))
    XCTAssertNil(RailwayHostOptions.Size(plan: .other("ENTERPRISE")))
  }

  func testTheFourRegionsAreRailwaysIDs() {
    XCTAssertEqual(
      RailwayHostOptions.regions.map(\.id),
      ["us-west2", "us-east4-eqdc4a", "europe-west4-drams3a", "asia-southeast1-eqsg3a"])
    XCTAssertEqual(RailwayHostOptions.defaultRegion, "us-west2")
  }

  // MARK: Checkout clearing

  /// Value: protects=a host made from a checkpoint starts with neither another workroom's
  /// checkout nor its `gh` token, and can still clone a private repository (story 24);
  /// fails_when=the token file (or its half-written copy) survives the clear, the clear touches
  /// a folder that isn't this project's checkout, or the Mac's token isn't written back;
  /// why_new=#633; seam=CheckoutClearingDriver.clearCheckout over StubRelay
  func testClearingACheckpointsCheckoutRemovesTheTokenThenWritesTheMacsBack() async throws {
    let railway = railway()
    let relay = StubRelay()
    let driver = driver(railway, relay)
    let host = try await driver.create(options: ResolvedHostOptions(image: "prepared"))
    let before = relay.calls(to: "ssh").count

    try await driver.clearCheckout(
      at: "/root/acme", of: "git@github.com:acme/app.git", on: host)

    let logins = Array(relay.calls(to: "ssh").dropFirst(before))
    XCTAssertEqual(logins.count, 2, "\(logins.map(\.args))")
    let clear = try XCTUnwrap(logins.first?.args.last)
    XCTAssertEqual(
      clear,
      RailwayHostDriver.clearCheckoutCommand(
        path: "/root/acme", cloneURL: "git@github.com:acme/app.git",
        tokenPath: RailwayHostDriver.gitHubTokenPath))
    XCTAssertEqual(
      logins.last.flatMap(\.stdin).map { String(decoding: $0, as: UTF8.self) },
      Self.token, "the Mac's token wasn't written back")
  }

  /// Value: protects=the clear's host command removes the token and its half-written copy even
  /// when no checkout is there, and keeps a folder that isn't this project's; fails_when=the
  /// early exit for a missing checkout skips the token, or another folder is removed;
  /// seam=the clear's host command, run by a real shell
  func testTheClearCommandRemovesBothTokenFilesAndOnlyThisProjectsCheckout() throws {
    let manager = FileManager.default
    let token = root.appendingPathComponent("state/gh-token")
    try manager.createDirectory(
      at: token.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "old".write(to: token, atomically: true, encoding: .utf8)
    try "old".write(
      to: token.appendingPathExtension("new"), atomically: true, encoding: .utf8)

    let missing = root.appendingPathComponent("nothing-here").path
    let none = try shell(
      RailwayHostDriver.clearCheckoutCommand(
        path: missing, cloneURL: "git@github.com:acme/app.git", tokenPath: token.path))
    XCTAssertEqual(none.status, 0, none.output)
    XCTAssertFalse(manager.fileExists(atPath: token.path), "the token survived")
    XCTAssertFalse(manager.fileExists(atPath: token.path + ".new"), "its copy survived")

    let other = root.appendingPathComponent("other")
    try manager.createDirectory(at: other, withIntermediateDirectories: true)
    let kept = try shell(
      RailwayHostDriver.clearCheckoutCommand(
        path: other.path, cloneURL: "git@github.com:acme/app.git", tokenPath: token.path))
    XCTAssertNotEqual(kept.status, 0, "a folder that isn't a checkout cleared")
    XCTAssertTrue(manager.fileExists(atPath: other.path), "another folder was removed")
  }

  // MARK: A checkpoint's disk

  /// Value: protects=a host restored from a checkpoint of a used host gets its own identity and
  /// none of the source's terminals or pane layouts; fails_when=railway.sh keeps the source's
  /// machine id, screens or layouts because they are already there; why_new=#633 (checkpoints
  /// copy the disk); seam=railway.sh, run against a throwaway /etc and state folder
  func testTheHostSetupGivesACheckpointsCopyItsOwnIdentityAndNoOldScreens() throws {
    let manager = FileManager.default
    let etc = root.appendingPathComponent("etc")
    let state = root.appendingPathComponent("state")
    let screens = state.appendingPathComponent("screens")
    let layouts = state.appendingPathComponent("layouts")
    for dir in [etc, screens, layouts] {
      try manager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    try "sourcemachineid\n".write(
      to: etc.appendingPathComponent("machine-id"), atomically: true, encoding: .utf8)
    try "source-id\n".write(
      to: etc.appendingPathComponent("workroom-identity"), atomically: true, encoding: .utf8)
    try "old".write(to: screens.appendingPathComponent("s1"), atomically: true, encoding: .utf8)
    try "old".write(to: layouts.appendingPathComponent("l1"), atomically: true, encoding: .utf8)

    let id = "0a1b2c3d-0000-4000-8000-00000000abcd"
    let script = try HostSetup.checkout.script("railway")
    let run = try shell(
      "WORKROOM_ETC=\(PosixShell.quoted(etc.path)) sh -s -- \(id) "
        + "\(PosixShell.quoted(state.appendingPathComponent("daemon/workroomd.sock").path)) "
        + PosixShell.quoted(screens.path),
      stdin: script)

    XCTAssertEqual(run.status, 0, run.output)
    XCTAssertEqual(
      try String(contentsOf: etc.appendingPathComponent("machine-id"), encoding: .utf8),
      "0a1b2c3d000040008000" + "00000000abcd\n")
    XCTAssertEqual(
      try String(contentsOf: etc.appendingPathComponent("workroom-identity"), encoding: .utf8),
      id + "\n")
    XCTAssertEqual(try manager.contentsOfDirectory(atPath: screens.path), [])
    XCTAssertFalse(manager.fileExists(atPath: layouts.appendingPathComponent("l1").path))
  }

  private func shell(_ command: String, stdin: String = "") throws -> (
    status: Int32, output: String
  ) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}
