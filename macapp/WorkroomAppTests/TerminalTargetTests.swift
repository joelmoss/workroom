import Defaults
import XCTest

@testable import Workroom

final class TerminalTargetTests: XCTestCase {

  func testWorkroomTargetIDsAreDistinctAcrossProjects() {
    // The latent bug this fixes: two same-named workrooms in different projects must NOT
    // share a terminal/log. Project-scoped ids guarantee distinct keys.
    let a = Workroom(name: "sunny", path: "/wr/a/sunny", vcsName: "workroom/sunny", warnings: [])
    let b = Workroom(name: "sunny", path: "/wr/b/sunny", vcsName: "workroom/sunny", warnings: [])
    XCTAssertNotEqual(a.target(inProject: "/proj-a").id, b.target(inProject: "/proj-b").id)
    XCTAssertEqual(a.target(inProject: "/proj-a").id, "wr|/proj-a|sunny")
  }

  func testRootTargetID() {
    let p = Project(path: "/proj-a", vcs: "git", workrooms: [])
    XCTAssertEqual(p.rootTarget.id, "root|/proj-a")
    XCTAssertNotEqual(p.rootTarget.id, "wr|/proj-a|sunny")
  }

  func testWorkroomMissingFlagFromBlockingWarning() {
    let wr = Workroom(
      name: "x", path: "/nope", vcsName: "workroom/x",
      warnings: [Warning(kind: "DirectoryMissing", message: "gone", path: "/nope", vcs: nil)])
    XCTAssertTrue(wr.target(inProject: "/proj-a").isMissing)
  }

  func testRootMissingForNonexistentPath() {
    let p = Project(path: "/definitely/not/a/real/path/zzz", vcs: "git", workrooms: [])
    XCTAssertTrue(p.rootTarget.isMissing)
  }

  /// `list --json` (#249): `host` present means remote, whatever its shape, and a bad one must not
  /// fail the whole listing.
  func testHostDescriptorsDecodeFromList() throws {
    let json = Data(
      """
      {"ok":true,"schema_version":1,"projects":[{"path":"/p","vcs":"git",
        "host":{"provider":"boxd"},
        "workrooms":[
          {"name":"local","path":"/wr/local","vcs_name":"workroom/local","warnings":[]},
          {"name":"remote","path":"/home/r","vcs_name":"workroom/remote","warnings":[],
           "host":{"id":"h1","provider":"boxd","state":"running","extra":[1]}},
          {"name":"gone","path":"/home/g","vcs_name":"workroom/gone",
           "warnings":[{"kind":"HostDestroyed","message":"host destroyed by its provider"}],
           "host":{"state":"destroyed"}},
          {"name":"odd","path":"/home/o","vcs_name":"workroom/odd","warnings":[],"host":"boxd"},
          {"name":"null","path":"/wr/null","vcs_name":"workroom/null","warnings":[],"host":null}
        ]}]}
      """.utf8)
    let workrooms = try JSONDecoder().decode(ListResponse.self, from: json).projects[0].workrooms
    let byName = Dictionary(uniqueKeysWithValues: workrooms.map { ($0.name, $0) })
    XCTAssertFalse(byName["local"]!.isRemote)
    XCTAssertTrue(byName["remote"]!.isRemote)
    XCTAssertEqual(byName["remote"]!.host?.isDestroyed, false)
    XCTAssertEqual(byName["gone"]!.host?.isDestroyed, true)
    XCTAssertTrue(byName["odd"]!.isRemote)
    XCTAssertFalse(byName["null"]!.isRemote)
    XCTAssertNotNil(try JSONDecoder().decode(ListResponse.self, from: json).projects[0].host)
    XCTAssertNil(try JSONDecoder().decode(ListResponse.self, from: json).projects[0].baseBranch)
  }

  /// The create's fetch warning decodes from both the "created" event and the success payload.
  func testCreateWarningDecodesFromTheEventAndThePayload() throws {
    let event = try JSONDecoder().decode(
      StreamEvent.self,
      from: Data(
        #"{"type":"created","name":"a","path":"/w/a","setup":false,"warning":"stale"}"#.utf8))
    XCTAssertEqual(event.warning, "stale")
    let response = try JSONDecoder().decode(
      CreateResponse.self,
      from: Data(#"{"name":"a","path":"/w/a","vcs":"git","project":"/p","warning":"stale"}"#.utf8))
    XCTAssertEqual(response.warning, "stale")
  }

  /// The app-wide base branch arrives at the top level of `list --json`.
  func testListDecodesTheGlobalBaseBranch() throws {
    let json = Data(
      #"{"ok":true,"schema_version":1,"projects":[],"base_branch":"upstream/main"}"#.utf8)
    XCTAssertEqual(
      try JSONDecoder().decode(ListResponse.self, from: json).baseBranch, "upstream/main")
  }

  /// A base names another remote only when the part before the slash is one, as the CLI reads it.
  func testSplitBaseMatchesTheCLIsRule() {
    let remotes = ["origin", "upstream"]
    XCTAssertTrue(RemoteWorkrooms.splitBase("develop", remotes: remotes) == ("origin", "develop"))
    XCTAssertTrue(RemoteWorkrooms.splitBase("origin/main", remotes: remotes) == ("origin", "main"))
    XCTAssertTrue(
      RemoteWorkrooms.splitBase("upstream/main", remotes: remotes) == ("upstream", "main"))
    XCTAssertTrue(
      RemoteWorkrooms.splitBase("release/1.0", remotes: remotes) == ("origin", "release/1.0"))
    XCTAssertTrue(
      RemoteWorkrooms.splitBase("upstream/", remotes: remotes) == ("origin", "upstream/"))
  }

  /// The project's base branch arrives under the CLI's snake_case key.
  func testListDecodesAProjectsBaseBranch() throws {
    let json = Data(
      """
      {"ok":true,"schema_version":1,"projects":[{"path":"/p","vcs":"git",
        "base_branch":"develop","workrooms":[]}]}
      """.utf8)
    let project = try JSONDecoder().decode(ListResponse.self, from: json).projects[0]
    XCTAssertEqual(project.baseBranch, "develop")
  }

  /// The app's own descriptor (#253) survives a write and a `list --json` read, and its record is
  /// enough to find a container host again; a field of the wrong type is dropped on its own.
  func testHostDescriptorRoundTripsTheAppsSchema() throws {
    let id = UUID()
    let descriptor = HostDescriptor(
      driver: "container", id: id, grantID: "g1", repository: "o/r",
      cloneURL: "https://github.com/o/r.git", path: "/home/workroom/r",
      container: ContainerHostDriver.Record(
        address: "127.0.0.1", port: 2222, user: "workroom", hostKey: "ssh-ed25519 AAAA",
        image: nil))
    let json = try JSONEncoder().encode(descriptor)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    XCTAssertEqual(object["grant_id"] as? String, "g1")
    XCTAssertEqual(
      (object["container"] as? [String: Any])?["host_key"] as? String, "ssh-ed25519 AAAA")
    XCTAssertNil(object["state"], "an unset field is written as absent, not null")
    XCTAssertEqual(try JSONDecoder().decode(HostDescriptor.self, from: json), descriptor)
    XCTAssertEqual(
      descriptor.base,
      RemoteProvisioning.Base(
        host: id, repository: "o/r", cloneURL: "https://github.com/o/r.git",
        path: "/home/workroom/r"))

    let odd = try JSONDecoder().decode(
      HostDescriptor.self,
      from: Data(#"{"id":"not-a-uuid","state":"destroyed","container":{"port":"x"}}"#.utf8))
    XCTAssertNil(odd.id)
    XCTAssertNil(odd.container)
    XCTAssertTrue(odd.isDestroyed)
  }

  /// A remote workroom is unavailable on this Mac (every local action guards on `isMissing`) but
  /// never shown as a missing directory; a destroyed host is its own state.
  /// A serving remote workroom opens panes (#253), and stays `isMissing` for every other local
  /// action; one being created, failed or destroyed opens none.
  func testARemoteWorkroomOpensPanesOnlyWhenServing() {
    let id = UUID()
    func target(_ host: HostDescriptor) -> TerminalTarget {
      Workroom(name: "x", path: "/home/w", vcsName: "workroom/x", warnings: [], host: host)
        .target(inProject: "/proj")
    }
    let mine = RemoteWorkrooms.provisioner
    let serving = target(HostDescriptor(provisioner: mine, id: id))
    XCTAssertEqual(serving.remoteHost, id)
    XCTAssertTrue(serving.opensTerminals)
    XCTAssertTrue(serving.isMissing, "a remote path must stay out of every local action")
    for state in ["creating", "failed", "destroyed"] {
      XCTAssertFalse(
        target(HostDescriptor(state: state, provisioner: mine, id: id)).opensTerminals, state)
    }
    XCTAssertFalse(target(HostDescriptor(provisioner: mine)).opensTerminals, "no host ID")
    XCTAssertFalse(
      target(HostDescriptor(provisioner: "another.build", id: id)).opensTerminals,
      "another build's host takes another key")
  }

  func testUnavailabilityReasons() {
    func target(_ warnings: [Warning], _ host: HostDescriptor?) -> TerminalTarget {
      Workroom(name: "x", path: "/p", vcsName: "workroom/x", warnings: warnings, host: host)
        .target(inProject: "/proj")
    }
    let missing = Warning(kind: "DirectoryMissing", message: "gone", path: "/p", vcs: nil)
    let destroyed = Warning(kind: "HostDestroyed", message: "destroyed", path: nil, vcs: nil)

    XCTAssertNil(target([], nil).unavailability)
    XCTAssertFalse(target([], nil).isMissing)
    XCTAssertEqual(target([missing], nil).unavailability, .directoryMissing)
    XCTAssertEqual(target([], HostDescriptor()).unavailability, .remote)
    XCTAssertTrue(target([], HostDescriptor()).isMissing)
    XCTAssertEqual(
      target([destroyed], HostDescriptor(state: "destroyed")).unavailability, .hostDestroyed)
    XCTAssertTrue(target([destroyed], HostDescriptor(state: "destroyed")).isMissing)
  }

  /// A remote workroom whose panes don't open says why (#253).
  func testAnUnopenedRemoteWorkroomSaysWhy() {
    let mine = RemoteWorkrooms.provisioner
    func detail(_ host: HostDescriptor) -> String {
      let target = Workroom(
        name: "x", path: "/home/w", vcsName: "workroom/x", warnings: [], host: host
      ).target(inProject: "/proj")
      return target.terminalUnavailability?.detail(for: target) ?? ""
    }

    XCTAssertTrue(
      detail(HostDescriptor(state: "creating", provisioner: mine)).contains("isn't ready"))
    XCTAssertTrue(
      detail(HostDescriptor(state: "failed", provisioner: mine, id: UUID()))
        .contains("Delete it to finish"))
    XCTAssertTrue(
      detail(HostDescriptor(provisioner: "another.build", id: UUID())).contains("another.build"))
    XCTAssertNil(
      Workroom(
        name: "x", path: "/home/w", vcsName: "workroom/x", warnings: [],
        host: HostDescriptor(provisioner: mine, id: UUID())
      ).remoteNote, "a serving workroom opens")
  }
}
