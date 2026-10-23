import WorkroomVCS
import XCTest

@testable import Workroom

/// A repository's `devcontainer.json` (`DevContainerConfig`): what a container workroom is made
/// from (#308), and the ports it forwards to this Mac.
final class DevContainerConfigTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func parse(_ text: String) throws -> DevContainerConfig {
    try DevContainerConfig.parse(Data(text.utf8))
  }

  // MARK: What the container is made from

  func testAnImageConfigNamesItsImage() throws {
    XCTAssertEqual(
      try parse(#"{"image": "mcr.microsoft.com/devcontainers/base:ubuntu"}"#).source,
      .image("mcr.microsoft.com/devcontainers/base:ubuntu"))
  }

  /// `build.context` defaults to the file's own folder ("."), as the spec has it; paths stay as
  /// written, relative to the file, for the caller to resolve.
  func testABuildConfigKeepsItsDockerfileContextArgsTargetAndOptions() throws {
    let config = try parse(
      #"""
      {
        "build": {
          "dockerfile": "Dockerfile",
          "context": "..",
          "args": { "NODE": "22" },
          "target": "dev",
          "options": ["--add-host=host.docker.internal:host-gateway"],
        },
      }
      """#)
    XCTAssertEqual(
      config.source,
      .build(
        .init(
          dockerfile: "Dockerfile", context: "..", args: ["NODE": "22"], target: "dev",
          options: ["--add-host=host.docker.internal:host-gateway"])))
    XCTAssertEqual(
      try parse(#"{"build": {"dockerfile": "Containerfile"}}"#).source,
      .build(.init(dockerfile: "Containerfile", context: ".")))
  }

  /// The older top-level spelling VS Code still reads.
  func testTheLegacyTopLevelDockerFileAndContextAreABuild() throws {
    XCTAssertEqual(
      try parse(#"{"dockerFile": "Dockerfile", "context": ".."}"#).source,
      .build(.init(dockerfile: "Dockerfile", context: "..")))
  }

  /// No image and no Dockerfile is not a parse error: the create says what is missing.
  func testAConfigWithNeitherHasNoSource() throws {
    XCTAssertNil(try parse(#"{"forwardPorts": [3000]}"#).source)
  }

  /// A Compose config describes services, not one container: flagged for the create to refuse.
  func testAComposeConfigIsFlagged() throws {
    let config = try parse(#"{"dockerComposeFile": "docker-compose.yml", "service": "app"}"#)
    XCTAssertTrue(config.usesCompose)
    XCTAssertFalse(try parse(#"{"image": "x"}"#).usesCompose)
  }

  // MARK: The container's settings

  /// `remoteEnv` may set a variable to null, which unsets it for the tools.
  func testEnvironmentUsersAndWorkspaceFolder() throws {
    let config = try parse(
      #"""
      {
        "image": "x",
        "containerEnv": { "TZ": "Europe/London" },
        "remoteEnv": { "PATH": "${containerEnv:PATH}:/opt/bin", "NOISY": null },
        "containerUser": "root",
        "remoteUser": "vscode",
        "workspaceFolder": "/workspaces/app",
      }
      """#)
    XCTAssertEqual(config.containerEnv, ["TZ": "Europe/London"])
    XCTAssertEqual(config.remoteEnv, ["PATH": "${containerEnv:PATH}:/opt/bin", "NOISY": nil])
    XCTAssertEqual(config.containerUser, "root")
    XCTAssertEqual(config.remoteUser, "vscode")
    XCTAssertEqual(config.workspaceFolder, "/workspaces/app")
  }

  /// The string form takes the Docker CLI's `--mount` syntax, with its spellings (`src`,
  /// `destination`, a bare `readonly`); the object form takes `source`, `target`, `type`. Docker's
  /// own default type is a volume. A key only Docker Desktop reads (`consistency`) is dropped.
  func testMountsInBothForms() throws {
    let config = try parse(
      #"""
      {
        "image": "x",
        "mounts": [
          "source=${localEnv:HOME}/.ssh,target=/home/vscode/.ssh,type=bind,consistency=cached",
          "src=cache,dst=/cache,readonly",
          { "source": "dind", "target": "/var/lib/docker", "type": "volume" },
        ],
      }
      """#)
    XCTAssertEqual(
      config.mounts,
      [
        .init(type: "bind", source: "${localEnv:HOME}/.ssh", target: "/home/vscode/.ssh"),
        .init(type: "volume", source: "cache", target: "/cache", readOnly: true),
        .init(type: "volume", source: "dind", target: "/var/lib/docker"),
      ])
  }

  /// A mount needs somewhere to go.
  func testAMountWithNoTargetIsAnError() {
    XCTAssertThrowsError(try parse(#"{"image": "x", "mounts": ["source=a,type=bind"]}"#))
  }

  func testRunFlags() throws {
    let config = try parse(
      #"""
      {
        "image": "x",
        "runArgs": ["--network=host"],
        "privileged": true,
        "capAdd": ["SYS_PTRACE"],
        "securityOpt": ["seccomp=unconfined"],
      }
      """#)
    XCTAssertEqual(config.runArgs, ["--network=host"])
    XCTAssertTrue(config.privileged)
    XCTAssertEqual(config.capAdd, ["SYS_PTRACE"])
    XCTAssertEqual(config.securityOpt, ["seccomp=unconfined"])
    let bare = try parse(#"{"image": "x"}"#)
    XCTAssertEqual(bare.runArgs, [])
    XCTAssertFalse(bare.privileged)
  }

  // MARK: Lifecycle commands

  /// A string runs in /bin/sh; an array runs without a shell; an object's entries run in parallel,
  /// each a string or an array, kept in name order so a row lists them the same way every time.
  func testLifecycleCommandsInEachForm() throws {
    let config = try parse(
      #"""
      {
        "image": "x",
        "initializeCommand": "touch ${localEnv:HOME}/.zsh_history",
        "onCreateCommand": ["npm", "ci"],
        "postCreateCommand": { "web": "npm run build", "db": ["bin/rails", "db:prepare"] },
        "postStartCommand": "service postgresql start",
        "postAttachCommand": "echo hi",
      }
      """#)
    XCTAssertEqual(
      config.lifecycle,
      [
        .initialize: .shell("touch ${localEnv:HOME}/.zsh_history"),
        .onCreate: .exec(["npm", "ci"]),
        .postCreate: .parallel([
          .init(name: "db", command: .exec(["bin/rails", "db:prepare"])),
          .init(name: "web", command: .shell("npm run build")),
        ]),
        .postStart: .shell("service postgresql start"),
        .postAttach: .shell("echo hi"),
      ])
    XCTAssertNil(config.lifecycle[.updateContent])
  }

  /// The spec's order of the container's own commands, after the clone.
  func testTheContainerCommandsRunInTheSpecsOrder() {
    XCTAssertEqual(
      DevContainerConfig.Hook.inContainer,
      [.onCreate, .updateContent, .postCreate, .postStart])
  }

  func testALifecycleCommandOfTheWrongTypeIsAnError() {
    XCTAssertThrowsError(try parse(#"{"image": "x", "postCreateCommand": 3}"#))
  }

  // MARK: Features

  /// Each feature's options object as written; a string is the spec's shorthand for its `version`
  /// option. Option values are strings or booleans.
  func testFeaturesAndTheirOptions() throws {
    let config = try parse(
      #"""
      {
        "image": "x",
        "features": {
          "ghcr.io/devcontainers/features/node:1": { "version": "22", "installYarn": false },
          "ghcr.io/devcontainers/features/go:1": "1.23",
          "ghcr.io/devcontainers/features/github-cli:1": {},
        },
        "overrideFeatureInstallOrder": ["ghcr.io/devcontainers/features/go"],
      }
      """#)
    XCTAssertEqual(
      config.features,
      [
        "ghcr.io/devcontainers/features/node:1": [
          "version": .string("22"), "installYarn": .bool(false),
        ],
        "ghcr.io/devcontainers/features/go:1": ["version": .string("1.23")],
        "ghcr.io/devcontainers/features/github-cli:1": [:],
      ])
    XCTAssertEqual(config.overrideFeatureInstallOrder, ["ghcr.io/devcontainers/features/go"])
  }

  func testAFeatureValueOfTheWrongTypeIsAnError() {
    XCTAssertThrowsError(try parse(#"{"image": "x", "features": {"a": 1}}"#))
    XCTAssertThrowsError(try parse(#"{"image": "x", "features": {"a": {"o": 1}}}"#))
  }

  // MARK: Keys Workroom can't honour (eng review D10)

  /// Each key that can't work in a workroom is named with why, for the creation pane's warning
  /// row; keys only an editor reads (`name`, `customizations`) and ones Workroom satisfies anyway
  /// (`init`, `waitFor`) say nothing.
  func testIgnoredKeysAreNamedWithWhy() throws {
    let config = try parse(
      #"""
      {
        "name": "app",
        "image": "x",
        "customizations": { "vscode": {} },
        "init": true,
        "waitFor": "postCreateCommand",
        "workspaceMount": "source=${localWorkspaceFolder},target=/w,type=bind",
        "workspaceFolder": "/w",
        "appPort": 3000,
        "hostRequirements": { "cpus": 4 },
        "postAttachCommand": "echo hi",
        "overrideCommand": false,
        "forwardPorts": [3000, "db:5432"],
        "shinyNewKey": 1,
      }
      """#)
    XCTAssertEqual(
      config.ignoredKeys(on: .docker).map(\.key),
      [
        "appPort", "forwardPorts \"db:5432\"", "hostRequirements", "overrideCommand",
        "postAttachCommand", "shinyNewKey", "workspaceMount",
      ])
    XCTAssertTrue(config.ignoredKeys(on: .docker).allSatisfy { !$0.reason.isEmpty })
  }

  /// `overrideCommand: true` is what Workroom does anyway.
  func testOverrideCommandTrueIsNotIgnored() throws {
    XCTAssertEqual(
      try parse(#"{"image": "x", "overrideCommand": true}"#).ignoredKeys(on: .docker).map(\.key),
      [])
  }

  /// Docker's run flags mean nothing to Apple's runtime, which also has no privileged mode or
  /// security options; it does take added capabilities.
  func testDockerOnlyFlagsAreIgnoredOnApplesRuntime() throws {
    let config = try parse(
      #"""
      {
        "image": "x", "runArgs": ["--network=host"], "privileged": true,
        "securityOpt": ["seccomp=unconfined"], "capAdd": ["SYS_PTRACE"],
      }
      """#)
    XCTAssertEqual(config.ignoredKeys(on: .docker).map(\.key), [])
    XCTAssertEqual(
      config.ignoredKeys(on: .apple).map(\.key), ["privileged", "runArgs", "securityOpt"])
  }

  // MARK: Variables

  private let variables = DevContainerConfig.Variables(
    localEnv: ["HOME": "/Users/joel", "EMPTY": ""],
    containerEnv: ["PATH": "/usr/bin:/bin"],
    localWorkspaceFolder: "/Users/joel/dev/acme-web",
    containerWorkspaceFolder: "/workspaces/acme-web",
    devcontainerId: "c0ffee")

  /// The spec's variables; a default after a second colon (which may itself hold colons) is used
  /// when the variable is unset; an unset one without a default is blank; `${env:…}` is VS Code's
  /// older spelling of `${localEnv:…}`.
  func testVariablesAreSubstituted() {
    let cases: [(String, String)] = [
      ("${localEnv:HOME}/.ssh", "/Users/joel/.ssh"),
      ("${env:HOME}", "/Users/joel"),
      ("[${localEnv:MISSING}]", "[]"),
      ("${localEnv:MISSING:fallback}", "fallback"),
      ("${localEnv:MISSING:http://a:b}", "http://a:b"),
      ("[${localEnv:EMPTY:unused}]", "[]"),
      ("${containerEnv:PATH}:/opt/bin", "/usr/bin:/bin:/opt/bin"),
      ("${localWorkspaceFolder}", "/Users/joel/dev/acme-web"),
      ("${localWorkspaceFolderBasename}", "acme-web"),
      ("${containerWorkspaceFolder}/node_modules", "/workspaces/acme-web/node_modules"),
      ("${containerWorkspaceFolderBasename}", "acme-web"),
      ("vol-${devcontainerId}", "vol-c0ffee"),
      ("${unknownVariable} and $HOME stay", "${unknownVariable} and $HOME stay"),
      ("${localEnv:HOME", "${localEnv:HOME"),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(variables.substitute(input), expected, input)
    }
  }

  // MARK: Ports

  /// The spec's file is JSON with comments: comments and trailing commas read, a `"host:port"`
  /// entry (another host's port, which the daemon can't reach) is skipped, a repeat is forwarded
  /// once, and `portsAttributes` gives a single port's label and `requireLocalPort`.
  func testItReadsTheSpecsPortFields() throws {
    let file = """
      // Format details: https://aka.ms/devcontainer.json
      {
        "name": "app",
        "image": "mcr.microsoft.com/devcontainers/base", /* a comment */
        "forwardPorts": [3000, "db:5432", 5173, 3000,],
        "portsAttributes": {
          "3000": { "label": "Web", "requireLocalPort": true, "onAutoForward": "openBrowser" },
          "9000-9010": { "label": "Range" },
        },
      }
      """
    XCTAssertEqual(
      try parse(file).ports,
      [.init(port: 3000, label: "Web", requireLocalPort: true), .init(port: 5173)])
  }

  /// Nothing to forward is an empty list, not an error: a dev container that declares no ports, and
  /// numbers no port can be.
  func testNoPortsOrInvalidOnesForwardNothing() throws {
    XCTAssertEqual(try parse(#"{"image": "x"}"#).ports, [])
    XCTAssertEqual(try parse(#"{"forwardPorts": [0, -1, 70000, 8080.5, true]}"#).ports, [])
  }

  func testAFileThatIsNotJSONIsAnError() {
    XCTAssertThrowsError(try parse("forwardPorts: [3000]"))
    XCTAssertThrowsError(try parse(#"{"forwardPorts": 3000}"#))
  }

  // MARK: Finding the file

  /// `.devcontainer/devcontainer.json` first, then `.devcontainer.json`, as the spec looks; nil
  /// when the repository has neither.
  func testItReadsTheFileTheSpecFindsFirst() async throws {
    let files = try await provider()
    let none = try await DevContainerConfig.read(files)
    XCTAssertNil(none)

    try write(".devcontainer.json", #"{"forwardPorts": [1]}"#)
    let root = try await DevContainerConfig.read(files)
    XCTAssertEqual(root?.path, ".devcontainer.json")

    try write(".devcontainer/devcontainer.json", #"{"forwardPorts": [2]}"#)
    let folder = try await DevContainerConfig.read(files)
    XCTAssertEqual(folder?.path, ".devcontainer/devcontainer.json")
    XCTAssertEqual(
      try folder.map { try DevContainerConfig.parse($0.data).ports }, [.init(port: 2)])
  }

  /// A failure other than "no such file" is the read's failure, never "no dev container": the
  /// caller tries again later rather than settle on forwarding nothing.
  func testAFailedReadIsNotAMissingFile() async throws {
    try write(".devcontainer/devcontainer.json", String(repeating: " ", count: 300 * 1024))
    let files = try await provider()
    do {
      _ = try await DevContainerConfig.read(files)
      XCTFail("an oversized file read as none")
    } catch FileServiceError.tooLarge {}
  }

  private func provider() async throws -> FileProviding {
    let location = try await RepositoryLocation.local(root.path)
    return NativeFileProvider(context: FileContext(location: location, sharedLocation: nil))
  }

  private func write(_ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }
}
