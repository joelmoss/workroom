import DaemonConnection
import HostDrivers
import WorkroomVCS
import XCTest

@testable import Workroom

/// A repository's dev container turned into a container (#308): the default image, the folders,
/// the environments, the container's flags and the lifecycle commands' scripts.
final class DevContainerSetupTests: XCTestCase {
  private let variables = DevContainerConfig.Variables(
    localEnv: ["HOME": "/Users/me", "TOKEN": "t0k"], localWorkspaceFolder: "/Users/me/src/app",
    containerWorkspaceFolder: "/workspaces/app", devcontainerId: "abc")

  private func config(_ json: String) throws -> DevContainerConfig {
    try DevContainerConfig.parse(Data(json.utf8))
  }

  /// No setting is the pinned image, by digest; a setting (trimmed) replaces it.
  func testTheDefaultImageIsThePinnedOneUnlessThisMacChoseAnother() {
    XCTAssertTrue(
      DevContainerSetup.defaultImage(setting: nil).hasPrefix(
        "mcr.microsoft.com/devcontainers/base@sha256:"))
    XCTAssertEqual(
      DevContainerSetup.defaultImage(setting: "  "), DevContainerSetup.pinnedDefaultImage)
    XCTAssertEqual(DevContainerSetup.defaultImage(setting: " node:22 "), "node:22")
  }

  func testTheCheckoutGoesInTheWorkspaceFolderElseUnderWorkspaces() throws {
    XCTAssertEqual(DevContainerSetup.workspaceFolder(nil, repository: "app"), "/workspaces/app")
    XCTAssertEqual(
      DevContainerSetup.workspaceFolder(
        try config(#"{"image": "x", "workspaceFolder": "/src"}"#), repository: "app"), "/src")
  }

  /// The file's user, else the image's devcontainer metadata, else its own, else root; the remote
  /// user is the container user unless the file says.
  func testUsersComeFromTheFileThenTheImage() throws {
    let image = ContainerHostDriver.ImageConfig(
      user: nil, metadataUser: "vscode", environment: [:])
    XCTAssertEqual(DevContainerSetup.users(nil, image: image).remote, "vscode")
    XCTAssertEqual(DevContainerSetup.users(nil, image: image).remoteHome, "/home/vscode")
    let bare = ContainerHostDriver.ImageConfig(user: nil, metadataUser: nil, environment: [:])
    XCTAssertEqual(DevContainerSetup.users(nil, image: bare).containerHome, "/root")
    let users = DevContainerSetup.users(
      try config(#"{"image": "x", "containerUser": "app", "remoteUser": "dev"}"#), image: image)
    XCTAssertEqual([users.container, users.remote], ["app", "dev"])
  }

  /// `remoteEnv` reads `${containerEnv:…}` from the image's environment under the file's
  /// `containerEnv`, and `${localEnv:…}` from this Mac's; a null one is left out.
  func testRemoteEnvReadsTheImageAndContainerEnvironment() throws {
    let file = try config(
      #"""
      {"image": "x",
       "containerEnv": {"TOOLS": "/opt/tools", "TOKEN": "${localEnv:TOKEN}"},
       "remoteEnv": {"PATH": "${containerEnv:PATH}:${containerEnv:TOOLS}/bin",
                     "WHERE": "${containerWorkspaceFolder}", "GONE": null}}
      """#)
    let image = ContainerHostDriver.ImageConfig(
      user: nil, metadataUser: nil, environment: ["PATH": "/usr/bin:/bin"])
    XCTAssertEqual(
      DevContainerSetup.remoteEnvironment(file, image: image, variables: variables),
      ["PATH": "/usr/bin:/bin:/opt/tools/bin", "WHERE": "/workspaces/app"])
    XCTAssertEqual(
      DevContainerSetup.containerEnvironment(file, variables: variables),
      ["TOOLS": "/opt/tools", "TOKEN": "t0k"])
  }

  /// The container's flags: the features' mounts and capabilities before the file's, each once,
  /// privileged when either asks, variables substituted, and `remoteEnv` over `containerEnv`.
  func testTheSpecMergesFeaturesAndTheFile() throws {
    let file = try config(
      #"""
      {"image": "x", "remoteUser": "dev", "containerEnv": {"A": "1", "B": "file"},
       "mounts": ["source=${localEnv:HOME}/.cache,target=/cache,type=bind"],
       "capAdd": ["SYS_PTRACE"], "runArgs": ["--label=${devcontainerId}"]}
      """#)
    var added = DevContainerFeatures.Contributions()
    added.mounts = [.init(type: "volume", source: "dind", target: "/var/lib/docker")]
    added.capAdd = ["SYS_PTRACE", "NET_ADMIN"]
    added.privileged = true
    let spec = DevContainerSetup.spec(
      image: "built:1", config: file, contributions: added, remoteEnvironment: ["B": "remote"],
      variables: variables, workspaceFolder: "/workspaces/app")
    XCTAssertEqual(spec.image, "built:1")
    XCTAssertEqual(spec.user, "dev")
    XCTAssertEqual(spec.environment, ["A": "1", "B": "remote"])
    XCTAssertEqual(
      spec.mounts,
      [
        .init(type: "volume", source: "dind", target: "/var/lib/docker"),
        .init(type: "bind", source: "/Users/me/.cache", target: "/cache"),
      ])
    XCTAssertEqual(spec.capAdd, ["SYS_PTRACE", "NET_ADMIN"])
    XCTAssertTrue(spec.privileged)
    XCTAssertEqual(spec.runArgs, ["--label=abc"])
    XCTAssertEqual(spec.workspaceFolder, "/workspaces/app")
  }

  /// The spec's order, onCreate to postStart, each hook's features' commands before the file's;
  /// initializeCommand (the Mac's) and postAttachCommand (not run) aren't among them.
  func testHooksRunInTheSpecsOrderFeaturesFirst() throws {
    let file = try config(
      #"""
      {"image": "x", "initializeCommand": "init", "postAttachCommand": "attach",
       "postStartCommand": "start", "onCreateCommand": "create"}
      """#)
    var added = DevContainerFeatures.Contributions()
    added.lifecycle = [("ghcr.io/x/y", .postStart, .shell("feature-start"))]
    let hooks = DevContainerSetup.hooks(file, contributions: added)
    XCTAssertEqual(hooks.map(\.hook), [.onCreate, .postStart])
    XCTAssertEqual(hooks[1].commands, [.shell("feature-start"), .shell("start")])
    XCTAssertTrue(DevContainerSetup.hooks(nil, contributions: .init()).isEmpty)
  }

  /// The scripts, run for real: in the checkout, with `remoteEnv`, a string through `sh`, an
  /// array without one, an object's entries at once; the first failure stops it, and one failing
  /// entry of an object fails the hook.
  func testHookScriptsRunEachFormInTheCheckout() throws {
    let checkout = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hooks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: checkout) }
    let script = DevContainerSetup.hookScript(
      .postCreate,
      commands: [
        .shell("echo \"$GREETING $(pwd)\" > said"),
        .exec(["touch", "with space"]),
        .parallel([
          .init(name: "a", command: .shell("sleep 0.2; touch a")),
          .init(name: "b", command: .exec(["touch", "b"])),
        ]),
      ],
      checkout: checkout.path, environment: ["GREETING": "it's me", "not a name": "x"])
    XCTAssertEqual(try run(script).status, 0)
    let said = try String(contentsOf: checkout.appendingPathComponent("said"), encoding: .utf8)
    // `pwd` may name the temporary folder through /private.
    XCTAssertTrue(
      said.hasPrefix("it's me /") && said.hasSuffix("/\(checkout.lastPathComponent)\n"), said)
    for file in ["with space", "a", "b"] {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: checkout.appendingPathComponent(file).path))
    }

    let stops = DevContainerSetup.hookScript(
      .onCreate, commands: [.shell("exit 7"), .exec(["touch", "never"])], checkout: checkout.path,
      environment: [:])
    XCTAssertEqual(try run(stops).status, 7)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: checkout.appendingPathComponent("never").path))

    let oneFails = DevContainerSetup.hookScript(
      .onCreate,
      commands: [
        .parallel([
          .init(name: "a", command: .shell("exit 3")), .init(name: "b", command: .shell("true")),
        ])
      ], checkout: checkout.path, environment: [:])
    XCTAssertEqual(try run(oneFails).status, 1)
  }

  private func run(_ script: String) throws -> (status: Int32, output: String) {
    try SessionBackendProbe.run(
      URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 10)
  }

  /// Details says when the repository's devcontainer.json isn't what the container was made from:
  /// changed, added or gone; nothing when it's the same, or for a container that recorded nothing.
  func testTheDetailsNoteSaysWhenTheConfigMovedOn() {
    let note = DevContainerSetup.configNote
    XCTAssertNil(note("sha256:a", "sha256:a"))
    XCTAssertNil(note("image:x", nil))
    XCTAssertNil(note(nil, "sha256:a"))
    XCTAssertTrue(note("sha256:a", "sha256:b")?.contains("has changed") == true)
    XCTAssertTrue(note("image:x", "sha256:b")?.contains("has a devcontainer.json now") == true)
    XCTAssertTrue(note("sha256:a", nil)?.contains("is gone") == true)
  }

  /// A container remembers its devcontainer.json by its bytes, or the image it went on without one.
  func testTheConfigDigestNamesTheFileOrTheImage() {
    XCTAssertEqual(DevContainerSetup.configDigest(file: nil, image: "x:1"), "image:x:1")
    XCTAssertEqual(
      DevContainerSetup.configDigest(file: Data("{}".utf8), image: "x:1"),
      "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
  }
}

/// A lifecycle command run in the container (#308), against this Mac's own shell standing in for
/// the container and a stand-in `workroomd run-script`: written to the hooks folder, run, its
/// output streamed, and a postStartCommand marked done whether or not it passed.
final class ContainerHookTests: XCTestCase {
  private struct ShellHost: HostDriver {
    func create() async throws -> HostID { .local }
    func destroy(_ host: HostID) async throws {}
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.notImplemented("stream")
    }
    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      try HostStream.spawn(
        URL(fileURLWithPath: "/bin/sh"), ["-c", command], environment: [:],
        handshakeTimeout: 5, purpose: .exchange)
    }
  }

  private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func add(_ line: String) { lock.withLock { lines.append(line) } }
  }

  func testAHookIsWrittenRunAndAPostStartMarkedDoneEitherWay() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hook-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // `run-script --dir <dir> --timeout <secs> -- <script>`, as the daemon takes it.
    let daemon = root.appendingPathComponent("workroomd")
    try "#!/bin/sh\ncd \"$3\" && exec \"$7\"\n".write(to: daemon, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemon.path)
    let folder = root.appendingPathComponent("hooks").path
    let done = root.appendingPathComponent("done")
    func run(_ hook: DevContainerConfig.Hook, _ command: String, _ lines: Lines) async -> String? {
      await ContainerCreate.runHook(
        hook,
        script: DevContainerSetup.hookScript(
          hook, commands: [.shell(command)], checkout: root.path, environment: [:]),
        on: .local, driver: ShellHost(), daemonBinary: daemon.path, folder: folder,
        done: done.path, onLine: { lines.add($0) })
    }

    let said = Lines()
    let passed = await run(.postCreate, "echo one; echo two >&2", said)
    XCTAssertNil(passed)
    XCTAssertEqual(Set(said.all), ["one", "two"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/postCreateCommand"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: done.path), "only postStart marks done")

    let failed = await run(.postStart, "exit 4", Lines())
    XCTAssertEqual(failed, "The dev container's postStartCommand failed: it exited 4.")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: done.path), "a failed postStart held panes")
  }
}
