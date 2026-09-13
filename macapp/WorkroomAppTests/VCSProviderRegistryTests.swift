import Foundation
import XCTest

@testable import Workroom

/// `VCSProviderRegistry` — the seam that lets a repo's provider be declared rather than probed for.
///
/// Every assertion here uses a directory with **no** `.git` and no `.jj`, because that is what makes
/// them discriminating: `VCS.repoKind(at:)` reports `.unsupported` for such a path and
/// `VCS.provider(for:)` throws. So a test that passes can only have gone through the registry. It is
/// also the shape of the case this exists for — a remote workroom's directory is not on this Mac, so
/// the probe sees exactly nothing.
final class VCSProviderRegistryTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    VCSProviderRegistry.shared.removeAll()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("wr-registry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    VCSProviderRegistry.shared.removeAll()
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  /// The negative control, asserted rather than assumed: without a registration this path has no
  /// provider at all. Every other test in this file is only meaningful because of this one.
  func testAnUnregisteredPathWithNoRepoOnDiskStillFails() {
    XCTAssertThrowsError(try VCS.provider(for: directory)) { error in
      guard case VCSError.unsupportedRepo = error else {
        return XCTFail("expected unsupportedRepo, got \(error)")
      }
    }
  }

  func testARegisteredPathResolvesWithoutTouchingTheFilesystem() throws {
    VCSProviderRegistry.shared.replace(with: [directory.path: "git"])
    XCTAssertTrue(try VCS.provider(for: directory) is GitProvider)

    VCSProviderRegistry.shared.replace(with: [directory.path: "jj"])
    XCTAssertTrue(try VCS.provider(for: directory) is RustJJProvider)
  }

  /// `/tmp` is a symlink to `/private/tmp`, and a registered path may carry a trailing slash. Both
  /// sides of the lookup normalise, so a caller's URL does not have to match the registered string
  /// byte for byte — it would otherwise silently miss and fall through to the probe.
  func testLookupNormalisesSymlinksAndTrailingSlashes() throws {
    VCSProviderRegistry.shared.replace(with: [directory.path + "/": "git"])
    XCTAssertTrue(try VCS.provider(for: directory) is GitProvider)

    let viaSymlink = URL(fileURLWithPath: "/tmp/wr-registry-symlink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: viaSymlink, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: viaSymlink) }
    VCSProviderRegistry.shared.replace(with: [viaSymlink.path: "jj"])
    XCTAssertTrue(
      try VCS.provider(for: URL(fileURLWithPath: "/private" + viaSymlink.path)) is RustJJProvider,
      "the same directory reached through /private must resolve")
  }

  /// `replace` is a replacement, not a merge: the projects payload is the complete set of repos
  /// that exist, so one dropped from it must stop resolving rather than linger.
  func testReplaceDropsWhatIsNoLongerThere() throws {
    VCSProviderRegistry.shared.replace(with: [directory.path: "git"])
    XCTAssertNotNil(VCSProviderRegistry.shared.provider(for: directory))

    VCSProviderRegistry.shared.replace(with: [:])
    XCTAssertNil(VCSProviderRegistry.shared.provider(for: directory))
  }

  /// A local repo is registered too, so this pins that registration and probe agree — the refactor
  /// must not change what a local path resolves to.
  func testARegisteredLocalRepoAgreesWithTheProbe() throws {
    let repo = directory.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)

    XCTAssertTrue(try VCS.provider(for: repo) is GitProvider, "probe, before registration")
    VCSProviderRegistry.shared.replace(with: [repo.path: "git"])
    XCTAssertTrue(try VCS.provider(for: repo) is GitProvider, "registry, after")
  }

  /// `replace` drops a backend name neither provider knows, rather than storing it and leaving the
  /// two readers to each re-check.
  ///
  /// This only became load-bearing when `VCS.writer(for:)` started reading the same map. An unknown
  /// name resolves to no provider, so the READ side degrades to the filesystem probe whether or not
  /// the guard is there — which is why that assertion cannot be the test. The writer builds
  /// `CLIVCSWriter(vcs:)` straight from the stored string, so a stored `"hg"` would spawn a binary
  /// called `hg` with git's arguments. Asserted through the writer for that reason.
  func testAnUnknownBackendNameIsRefusedAtTheDoor() {
    VCSProviderRegistry.shared.replace(with: [directory.path: "hg"])

    XCTAssertNil(VCSProviderRegistry.shared.vcs(for: directory))
    XCTAssertNil(VCSProviderRegistry.shared.provider(for: directory))
    // Falls through to the probe, which finds no repo — rather than returning a writer that would
    // shell out to `hg`.
    XCTAssertThrowsError(try VCS.writer(for: directory)) { error in
      guard case VCSError.unsupportedRepo = error else {
        return XCTFail("expected unsupportedRepo, got \(error)")
      }
    }
  }

  func testOnlyTheVCSNamesTheCLIEmitsAreRecognised() {
    XCTAssertNotNil(VCSProviderRegistry.factory(forVCS: "git"))
    XCTAssertNotNil(VCSProviderRegistry.factory(forVCS: "jj"))
    // An unrecognised name registers nothing, so the path keeps falling through to the probe
    // rather than resolving to a confidently wrong backend.
    XCTAssertNil(VCSProviderRegistry.factory(forVCS: "hg"))
    XCTAssertNil(VCSProviderRegistry.factory(forVCS: ""))
  }

  /// The trap this registration has already fallen into once, in `statusWorkItems`: a workroom's
  /// VCS *type* is its project's, while `Workroom.vcsName` is a branch/workspace name.
  ///
  /// Driven through `entries(for:)` rather than `factory(forVCS:)`, because only this can tell the
  /// two apart. A test that asserted `factory(forVCS: "workroom/feature") == nil` would stay green
  /// if the registration loop were changed to read `vcsName` — it would simply register nothing for
  /// any workroom, and the assertion would never notice. So the project here is `jj` while its
  /// workroom's `vcsName` is a plausible-looking `"git"`: reading the wrong field resolves the
  /// workroom to the wrong backend rather than to nothing, which is the failure that would actually
  /// ship.
  ///
  /// Both readers are asserted. `VCS.writer(for:)` resolves through the same registration, and a
  /// writer that routed on `vcsName` would run `git` commands against a jj workspace.
  func testWorkroomsRegisterUnderTheirProjectsVCSNotTheirOwnName() throws {
    let project = Project(
      path: directory.appendingPathComponent("proj").path,
      vcs: "jj",
      workrooms: [
        Workroom(
          name: "feature", path: directory.appendingPathComponent("proj/wr").path,
          vcsName: "git", warnings: [])
      ])

    VCSProviderRegistry.shared.replace(with: VCSProviderRegistry.entries(for: [project]))

    XCTAssertTrue(
      VCSProviderRegistry.shared.provider(for: URL(fileURLWithPath: project.path))
        is RustJJProvider,
      "the project root must resolve to its own vcs")
    XCTAssertTrue(
      VCSProviderRegistry.shared.provider(for: URL(fileURLWithPath: project.workrooms[0].path))
        is RustJJProvider,
      "a jj project's workroom is a jj workspace, whatever its vcsName says")

    let writer = try VCS.writer(for: URL(fileURLWithPath: project.workrooms[0].path))
    XCTAssertEqual(
      (writer as? CLIVCSWriter)?.vcs, "jj",
      "the writer routes on the project's vcs too — vcsName would spawn git against a jj workspace")
  }

  /// `workingStatus` is on `VCSProviding` now, and its default THROWS rather than reporting a clean
  /// working copy.
  ///
  /// The difference matters more than it looks. A default returning an empty `WorkroomStatus` would
  /// make a backend that forgot the method present as a working app with a permanently clean badge
  /// — a failure that survives a release because nothing about it looks broken. A throw surfaces on
  /// the row instead. Both real backends override it, so this only ever catches a new one.
  func testTheWorkingStatusDefaultThrowsRatherThanReportingClean() {
    struct NotAVCS: VCSProviding {
      func log(root: URL, limit: Int) throws -> VCSHistoryPage {
        VCSHistoryPage(commits: [], reachedEnd: true)
      }
      func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
        throw VCSError.unsupportedRepo("stub")
      }
      func fileDiff(root: URL, commitID: String, path: String) async throws -> String { "" }
      func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String
      { "" }
      func fileContent(root: URL, rev: String, path: String) async throws -> String? { nil }
      func currentRef(root: URL) async throws -> VCSRef { throw VCSError.unsupportedRepo("stub") }
    }

    XCTAssertThrowsError(try NotAVCS().workingStatus(root: directory)) { error in
      guard case VCSError.unsupportedRepo = error else {
        return XCTFail("expected unsupportedRepo, got \(error)")
      }
    }
  }

  func testAnUnrecognisedProjectVCSRegistersNothing() {
    let project = Project(
      path: directory.appendingPathComponent("hgproj").path, vcs: "hg",
      workrooms: [
        Workroom(
          name: "w", path: directory.appendingPathComponent("hgproj/w").path, vcsName: "hg",
          warnings: [])
      ])
    XCTAssertTrue(
      VCSProviderRegistry.entries(for: [project]).isEmpty,
      "an unknown backend must fall through to the probe, not resolve to a wrong one")
  }

  /// That `apply` actually calls the registration — the link the two tests above cannot see.
  ///
  /// Driven through the real `reload()` with a faked CLI, so what is asserted is the observable
  /// outcome of a list landing: a path that has no repo on disk resolves, which it cannot do
  /// unless the projects payload reached the registry.
  func testAListingRegistersItsProjectsThroughTheStore() async throws {
    let root = directory.appendingPathComponent("listed", isDirectory: true).path
    let workroomPath = directory.appendingPathComponent("listed/wr", isDirectory: true).path
    let store = await AppStore(
      cli: StubListingCLI(
        listed: Project(
          path: root, vcs: "git",
          workrooms: [Workroom(name: "wr", path: workroomPath, vcsName: "main", warnings: [])])))

    await store.reload()

    XCTAssertTrue(
      VCSProviderRegistry.shared.provider(for: URL(fileURLWithPath: root)) is GitProvider,
      "the project root was never registered")
    XCTAssertTrue(
      VCSProviderRegistry.shared.provider(for: URL(fileURLWithPath: workroomPath)) is GitProvider,
      "the workroom was never registered")
    // The writer reads the same registration, and neither path has a repo on disk to fall back to.
    XCTAssertEqual(
      (try VCS.writer(for: URL(fileURLWithPath: workroomPath)) as? CLIVCSWriter)?.vcs, "git",
      "the writer still routes by probing the filesystem")
  }
}

/// A CLI that answers `list` with one fixed project and does nothing else.
private struct StubListingCLI: WorkroomCLIProtocol {
  let listed: Project

  func list(warnings: String, project: String?) async throws -> ListResponse {
    ListResponse(projects: [listed], workroomsDir: nil, configPath: nil)
  }
  func addProject(_ path: String, create: Bool) async throws -> String { listed.path }
  func create(
    project: String, onLog: ((String) -> Void)?, onReady: ((String, String, Bool) -> Void)?
  ) async throws -> CreateResponse {
    CreateResponse(name: "", path: "", vcs: "git", project: project)
  }
  func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {}
  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
  ) async throws -> [URL] { [] }
}
