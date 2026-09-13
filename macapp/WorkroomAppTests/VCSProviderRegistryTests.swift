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
    VCSProviderRegistry.shared.replace(with: [directory.path: { GitProvider() }])
    XCTAssertTrue(try VCS.provider(for: directory) is GitProvider)

    VCSProviderRegistry.shared.replace(with: [directory.path: { RustJJProvider() }])
    XCTAssertTrue(try VCS.provider(for: directory) is RustJJProvider)
  }

  /// `/tmp` is a symlink to `/private/tmp`, and a registered path may carry a trailing slash. Both
  /// sides of the lookup normalise, so a caller's URL does not have to match the registered string
  /// byte for byte — it would otherwise silently miss and fall through to the probe.
  func testLookupNormalisesSymlinksAndTrailingSlashes() throws {
    VCSProviderRegistry.shared.replace(with: [directory.path + "/": { GitProvider() }])
    XCTAssertTrue(try VCS.provider(for: directory) is GitProvider)

    let viaSymlink = URL(fileURLWithPath: "/tmp/wr-registry-symlink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: viaSymlink, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: viaSymlink) }
    VCSProviderRegistry.shared.replace(with: [viaSymlink.path: { RustJJProvider() }])
    XCTAssertTrue(
      try VCS.provider(for: URL(fileURLWithPath: "/private" + viaSymlink.path)) is RustJJProvider,
      "the same directory reached through /private must resolve")
  }

  /// `replace` is a replacement, not a merge: the projects payload is the complete set of repos
  /// that exist, so one dropped from it must stop resolving rather than linger.
  func testReplaceDropsWhatIsNoLongerThere() throws {
    VCSProviderRegistry.shared.replace(with: [directory.path: { GitProvider() }])
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
    VCSProviderRegistry.shared.replace(with: [repo.path: { GitProvider() }])
    XCTAssertTrue(try VCS.provider(for: repo) is GitProvider, "registry, after")
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
  /// VCS *type* is its project's, while `Workroom.vcsName` is a branch/workspace name. Registering
  /// on `vcsName` would resolve nothing for every workroom.
  func testWorkroomsRegisterUnderTheirProjectsVCSNotTheirOwnName() {
    let workroom = Workroom(
      name: "feature", path: directory.appendingPathComponent("wr").path,
      vcsName: "workroom/feature", warnings: [])
    XCTAssertNil(
      VCSProviderRegistry.factory(forVCS: workroom.vcsName),
      "vcsName is a branch name; treating it as a type must not resolve")
  }
}
