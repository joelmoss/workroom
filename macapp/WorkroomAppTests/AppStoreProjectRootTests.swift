import XCTest

@testable import Workroom

/// `AppStore.projectRoot(forTarget:)` (VCS-foundation eng-review — jj snapshot serialization) keys
/// `JJSnapshotGate`, so a wrong answer silently defeats the gate for that call site (a workroom's
/// diff would gate on the wrong/no project root instead of the shared repo it actually belongs to).
/// Covers root target, workroom target, cross-project non-collision, and the unknown-target nil case.
@MainActor
final class AppStoreProjectRootTests: XCTestCase {

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
    store.projects = projects
    return store
  }

  private func project(_ path: String, workrooms: [String]) -> Project {
    Project(
      path: path, vcs: "git",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "workroom/\($0)", warnings: [])
      })
  }

  func testRootTargetResolvesItsOwnPath() {
    let a = project("/a", workrooms: ["main"])
    let store = makeStore([a])
    XCTAssertEqual(store.projectRoot(forTarget: a.rootTarget), "/a")
  }

  func testWorkroomTargetResolvesParentProjectPath() {
    let a = project("/a", workrooms: ["main"])
    let store = makeStore([a])
    let workroomTarget = a.workrooms[0].target(inProject: a.path)
    XCTAssertEqual(store.projectRoot(forTarget: workroomTarget), "/a")
  }

  /// The same workroom NAME in two different projects must resolve to each project's OWN root, not
  /// the other's — the exact same-name collision `TerminalTarget`'s id scheme is designed to avoid.
  func testWorkroomTargetsInDifferentProjectsDoNotCollide() {
    let a = project("/a", workrooms: ["main"])
    let b = project("/b", workrooms: ["main"])
    let store = makeStore([a, b])
    XCTAssertEqual(store.projectRoot(forTarget: a.workrooms[0].target(inProject: a.path)), "/a")
    XCTAssertEqual(store.projectRoot(forTarget: b.workrooms[0].target(inProject: b.path)), "/b")
  }

  /// A target that no longer matches any live project (e.g. deleted mid-render) resolves to nil
  /// rather than a stale/garbage root — `DiffResolver` treats nil as "don't gate", never as a key.
  func testUnknownTargetResolvesNil() {
    let a = project("/a", workrooms: ["main"])
    let store = makeStore([a])
    let ghost = Workroom(name: "gone", path: "/a/gone", vcsName: "workroom/gone", warnings: [])
      .target(inProject: "/a")
    XCTAssertNil(store.projectRoot(forTarget: ghost))
  }
}
