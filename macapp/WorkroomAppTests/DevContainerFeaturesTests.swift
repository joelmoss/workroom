import XCTest

@testable import Workroom

/// Devcontainer features (#308, eng review D2): where each comes from, what its install script is
/// told, the order they install in, and the image they are built into.
final class DevContainerFeaturesTests: XCTestCase {
  typealias Features = DevContainerFeatures
  typealias Reference = DevContainerFeatures.Reference

  // MARK: References

  /// An OCI reference keeps its registry, repository and tag (`latest` when it names none); its key,
  /// what `installsAfter` and `overrideFeatureInstallOrder` name it by, drops the version. A URL to a
  /// tarball and a path relative to the file are the spec's other two kinds.
  func testReferencesAreParsedAsTheSpecHasThem() throws {
    XCTAssertEqual(
      try Reference("ghcr.io/devcontainers/features/node:1"),
      .oci(registry: "ghcr.io", repository: "devcontainers/features/node", tag: "1"))
    XCTAssertEqual(
      try Reference("ghcr.io/devcontainers/features/node"),
      .oci(registry: "ghcr.io", repository: "devcontainers/features/node", tag: "latest"))
    XCTAssertEqual(
      try Reference("ghcr.io/o/f/x@sha256:abc"),
      .oci(registry: "ghcr.io", repository: "o/f/x", tag: "sha256:abc"))
    XCTAssertEqual(
      try Reference("localhost:5000/o/x:2"),
      .oci(registry: "localhost:5000", repository: "o/x", tag: "2"))
    XCTAssertEqual(
      try Reference("https://example.com/devcontainer-feature-go.tgz"),
      .tarball(URL(string: "https://example.com/devcontainer-feature-go.tgz")!))
    XCTAssertEqual(try Reference("./local-tool"), .local("./local-tool"))

    XCTAssertEqual(
      try Reference("ghcr.io/devcontainers/features/node:1").key,
      "ghcr.io/devcontainers/features/node")
    XCTAssertThrowsError(try Reference("node"), "no registry or namespace")
    XCTAssertThrowsError(try Reference("/abs/path"), "absolute paths are not allowed")
  }

  // MARK: Options

  /// The spec's name rule (non-word characters become `_`, leading digits and underscores become
  /// one `_`, then upper case); a default for each option not given; booleans as `true`/`false`.
  func testOptionsBecomeTheInstallScriptsEnvironment() throws {
    let metadata = try Features.Metadata.parse(
      Data(
        #"""
        {
          "id": "node", "version": "1.2.0", "name": "Node",
          "options": {
            "version": { "type": "string", "default": "lts" },
            "install-yarn": { "type": "boolean", "default": true },
            "9lives": { "type": "string", "default": "" },
            "nodeGypDependencies": { "type": "boolean", "default": false }
          }
        }
        """#.utf8))
    XCTAssertEqual(
      Features.environment(
        for: metadata, given: ["version": .string("22"), "nodeGypDependencies": .bool(true)]),
      ["VERSION": "22", "INSTALL_YARN": "true", "_LIVES": "", "NODEGYPDEPENDENCIES": "true"])
  }

  // MARK: Install order

  /// Features served from memory, each with the metadata the test gives it.
  private struct FakeSource: DevContainerFeatures.Source {
    let metadata: [String: String]
    func fetch(_ reference: Reference) async throws -> DevContainerFeatures.Fetched {
      guard let json = metadata[reference.key] else {
        throw DevContainerFeatures.Failure.badReference("no fake \(reference.key)")
      }
      return .init(
        metadata: try Features.Metadata.parse(Data(json.utf8)),
        directory: URL(fileURLWithPath: "/fake/\(reference.key)"), digest: nil)
    }
  }

  private func meta(
    _ id: String, dependsOn: String = "{}", installsAfter: String = "[]"
  ) -> String {
    #"{"id": "\#(id)", "version": "1.0.0", "dependsOn": \#(dependsOn), "installsAfter": \#(installsAfter)}"#
  }

  private func order(
    _ declared: [String: [String: DevContainerConfig.OptionValue]], override: [String] = [],
    _ metadata: [String: String]
  ) async throws -> [String] {
    try await Features.resolve(declared, override: override, source: FakeSource(metadata: metadata))
      .map(\.reference.key)
  }

  /// With nothing between them, features install in the spec's stable order: by name.
  func testUnrelatedFeaturesInstallByName() async throws {
    let keys = ["r.io/o/zsh", "r.io/o/node", "r.io/o/git"]
    let metadata = Dictionary(uniqueKeysWithValues: keys.map { ($0, meta($0)) })
    let got = try await order(
      ["r.io/o/zsh:1": [:], "r.io/o/node:1": [:], "r.io/o/git:1": [:]], metadata)
    XCTAssertEqual(got, ["r.io/o/git", "r.io/o/node", "r.io/o/zsh"])
  }

  /// `installsAfter` orders only among features already chosen; `dependsOn` adds the feature it
  /// names, with that feature's own dependencies, and puts it first.
  func testDependenciesComeFirstAndAreAddedWhenMissing() async throws {
    let metadata = [
      "r.io/o/aws": meta("aws", installsAfter: #"["r.io/o/python"]"#),
      "r.io/o/python": meta("python", dependsOn: #"{"r.io/o/common:2": {}}"#),
      "r.io/o/common": meta("common"),
      "r.io/o/apt": meta("apt", installsAfter: #"["r.io/o/never-chosen"]"#),
    ]
    let got = try await order(
      ["r.io/o/aws:1": [:], "r.io/o/python:1": [:], "r.io/o/apt:1": [:]], metadata)
    XCTAssertEqual(got, ["r.io/o/apt", "r.io/o/common", "r.io/o/python", "r.io/o/aws"])
  }

  /// `overrideFeatureInstallOrder` gives its features priority, in its order: each round installs
  /// only the ready features of the highest priority. It never puts a feature before what it
  /// depends on, so here `c` waits for `b` while `a`, ready, goes first (the spec's algorithm as
  /// written).
  func testTheOverrideOrderWinsExceptOverDependencies() async throws {
    let metadata = [
      "r.io/o/a": meta("a"), "r.io/o/b": meta("b"), "r.io/o/d": meta("d"),
      "r.io/o/c": meta("c", dependsOn: #"{"r.io/o/b:1": {}}"#),
    ]
    let got = try await order(
      ["r.io/o/a:1": [:], "r.io/o/b:1": [:], "r.io/o/c:1": [:], "r.io/o/d:1": [:]],
      override: ["r.io/o/c", "r.io/o/d"], metadata)
    XCTAssertEqual(got, ["r.io/o/d", "r.io/o/a", "r.io/o/b", "r.io/o/c"])
  }

  func testACycleIsAnError() async {
    let metadata = [
      "r.io/o/a": meta("a", dependsOn: #"{"r.io/o/b:1": {}}"#),
      "r.io/o/b": meta("b", dependsOn: #"{"r.io/o/a:1": {}}"#),
    ]
    do {
      _ = try await order(["r.io/o/a:1": [:]], metadata)
      XCTFail("a cycle resolved")
    } catch DevContainerFeatures.Failure.cycle {} catch { XCTFail("\(error)") }
  }

  // MARK: The image

  private let users = DevContainerFeatures.Users(
    container: "vscode", remote: "vscode", containerHome: "/home/vscode",
    remoteHome: "/home/vscode")

  private func feature(
    _ key: String, _ json: String, options: [String: DevContainerConfig.OptionValue] = [:],
    directory: URL = URL(fileURLWithPath: "/fake")
  ) throws -> DevContainerFeatures.Feature {
    .init(
      reference: try Reference("\(key):1"), options: options,
      fetched: .init(
        metadata: try Features.Metadata.parse(Data(json.utf8)), directory: directory, digest: nil))
  }

  /// One layer per feature, as root: its `containerEnv` first (so `${PATH}` extends the image's),
  /// then its folder, then its `install.sh` with its options sourced; the users as build args; the
  /// image's own user back at the end.
  func testTheDockerfileInstallsEachFeatureAsRootInOrder() throws {
    let features = [
      try feature(
        "ghcr.io/devcontainers/features/go",
        #"{"id": "go", "version": "1.3.0", "containerEnv": {"PATH": "/usr/local/go/bin:${PATH}", "GOPATH": "/go"}}"#
      ),
      try feature(
        "ghcr.io/devcontainers/features/github-cli", #"{"id": "github-cli", "version": "1.1.3"}"#),
    ]
    XCTAssertEqual(
      Features.dockerfile(
        base: "mcr.microsoft.com/devcontainers/base:ubuntu", features: features,
        users: users, imageUser: "vscode"),
      """
      FROM mcr.microsoft.com/devcontainers/base:ubuntu
      USER root
      ARG _CONTAINER_USER="vscode"
      ARG _REMOTE_USER="vscode"
      ARG _CONTAINER_USER_HOME="/home/vscode"
      ARG _REMOTE_USER_HOME="/home/vscode"
      ENV GOPATH="/go"
      ENV PATH="/usr/local/go/bin:${PATH}"
      COPY features/0 /tmp/workroom-features/0
      RUN cd /tmp/workroom-features/0 && chmod +x install.sh && set -a && . ./devcontainer-features.env && set +a && ./install.sh && rm -rf /tmp/workroom-features/0
      COPY features/1 /tmp/workroom-features/1
      RUN cd /tmp/workroom-features/1 && chmod +x install.sh && set -a && . ./devcontainer-features.env && set +a && ./install.sh && rm -rf /tmp/workroom-features/1
      USER vscode

      """)
  }

  /// The build context holds each feature's folder and its options' env file under the index the
  /// Dockerfile copies.
  func testTheBuildContextHoldsEachFeaturesFolderAndOptions() throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let context = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: context)
    }
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho hi\n".utf8).write(to: source.appendingPathComponent("install.sh"))
    let node = try feature(
      "r.io/o/node",
      #"{"id": "node", "version": "1.0.0", "options": {"version": {"type": "string", "default": "lts"}}}"#,
      options: ["version": .string("22")], directory: source)

    let dockerfile = try Features.writeContext(
      at: context, base: "x", features: [node], users: users, imageUser: "root")

    XCTAssertEqual(dockerfile.lastPathComponent, "Dockerfile")
    XCTAssertEqual(
      try String(
        contentsOf: context.appendingPathComponent("features/0/install.sh"), encoding: .utf8),
      "#!/bin/sh\necho hi\n")
    XCTAssertEqual(
      try String(
        contentsOf: context.appendingPathComponent("features/0/devcontainer-features.env"),
        encoding: .utf8),
      "VERSION='22'\n")
  }

  /// What features add to the container: mounts and capabilities from every feature, privileged if
  /// any wants it, their lifecycle commands in install order (run before the file's own), and the
  /// entrypoints Workroom can't run (its daemon is the entrypoint), to warn about.
  func testFeaturesContributeToTheContainer() throws {
    let features = [
      try feature(
        "r.io/o/dind",
        #"""
        {"id": "dind", "version": "2.0.0", "privileged": true, "entrypoint": "/usr/local/share/docker-init.sh",
         "mounts": [{"source": "dind-var-lib-docker-${devcontainerId}", "target": "/var/lib/docker", "type": "volume"}],
         "postStartCommand": "echo started"}
        """#),
      try feature(
        "r.io/o/debug",
        #"{"id": "debug", "version": "1.0.0", "capAdd": ["SYS_PTRACE"], "securityOpt": ["seccomp=unconfined"], "onCreateCommand": ["true"]}"#
      ),
    ]
    let added = Features.contributions(of: features)
    XCTAssertTrue(added.privileged)
    XCTAssertEqual(added.capAdd, ["SYS_PTRACE"])
    XCTAssertEqual(added.securityOpt, ["seccomp=unconfined"])
    XCTAssertEqual(
      added.mounts,
      [
        .init(
          type: "volume", source: "dind-var-lib-docker-${devcontainerId}", target: "/var/lib/docker"
        )
      ])
    XCTAssertEqual(added.lifecycle.map(\.feature), ["r.io/o/dind", "r.io/o/debug"])
    XCTAssertEqual(added.lifecycle.map(\.hook), [.postStart, .onCreate])
    XCTAssertEqual(added.entrypoints, ["r.io/o/dind"])
  }

  // MARK: Fetching

  /// A registry stand-in: the URLs a fetch asks for and the replies, set per test.
  private final class StubRegistry: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String: (Int, [String: String], Data)] = [:]
    nonisolated(unsafe) static var asked: [(url: String, authorization: String?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// A reply keyed `<url>#authorized` answers only a request that sends a token; the plain URL's
    /// answers any other.
    override func startLoading() {
      let url = request.url!.absoluteString
      let authorization = request.value(forHTTPHeaderField: "Authorization")
      Self.asked.append((url, authorization))
      let authorized = authorization != nil ? Self.replies[url + "#authorized"] : nil
      let (status, headers, body) = authorized ?? Self.replies[url] ?? (404, [:], Data())
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
  }

  private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubRegistry.self]
    return URLSession(configuration: configuration)
  }

  /// A feature's layer: a tar of its folder, as the registry serves it.
  private func featureTar(id: String) throws -> Data {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"id": "\#(id)", "version": "1.1.3"}"#.utf8).write(
      to: folder.appendingPathComponent("devcontainer-feature.json"))
    try Data("#!/bin/sh\n".utf8).write(to: folder.appendingPathComponent("install.sh"))
    let tar = folder.appendingPathExtension("tar")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-cf", tar.path, "-C", folder.path, "."]
    try process.run()
    process.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: tar) }
    return try Data(contentsOf: tar)
  }

  /// The registry's flow: the manifest is refused with a bearer challenge, an anonymous token comes
  /// from its realm, the manifest names the feature's layer, and the layer is unpacked once its
  /// bytes match the digest the manifest gives.
  func testAnOCIFeatureIsFetchedThroughTheRegistrysChallenge() async throws {
    let layer = try featureTar(id: "github-cli")
    let digest = "sha256:" + DaemonBootstrap.digest(of: layer)
    let manifest = #"""
      {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
       "config": {"mediaType": "application/vnd.devcontainers", "digest": "sha256:00", "size": 2},
       "layers": [{"mediaType": "application/vnd.devcontainers.layer.v1+tar", "digest": "\#(digest)", "size": \#(layer.count)}]}
      """#
    let base = "https://ghcr.io/v2/devcontainers/features/github-cli"
    StubRegistry.asked = []
    StubRegistry.replies = [
      "\(base)/manifests/1": (
        401,
        [
          "WWW-Authenticate":
            #"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:devcontainers/features/github-cli:pull""#
        ], Data()
      ),
      "https://ghcr.io/token?scope=repository:devcontainers/features/github-cli:pull&service=ghcr.io":
        (200, [:], Data(#"{"token": "t0k3n"}"#.utf8)),
      "\(base)/blobs/\(digest)": (200, [:], layer),
    ]
    let source = Features.OCISource(
      session: stubSession(),
      cache: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString))
    // The manifest succeeds only once the token is sent.
    StubRegistry.replies["\(base)/manifests/1#authorized"] = (
      200, ["Docker-Content-Digest": "sha256:m4n1f35t"], Data(manifest.utf8)
    )

    let fetched = try await source.fetch(
      try Reference("ghcr.io/devcontainers/features/github-cli:1"))

    XCTAssertEqual(fetched.metadata.id, "github-cli")
    XCTAssertEqual(fetched.digest, "sha256:m4n1f35t")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: fetched.directory.appendingPathComponent("install.sh").path))
    XCTAssertEqual(
      StubRegistry.asked.last(where: { $0.url.hasSuffix("manifests/1") })?.authorization,
      "Bearer t0k3n")

    // Value: protects=a feature this Mac has unpacked is not downloaded again on the next create;
    // fails_when=the cache is checked only after the blob is fetched; why_new=only one fetch was tested; seam=none; no_claim=a real registry
    StubRegistry.replies["\(base)/blobs/\(digest)"] = nil
    StubRegistry.asked = []
    let again = try await source.fetch(
      try Reference("ghcr.io/devcontainers/features/github-cli:1"))
    XCTAssertEqual(again.directory, fetched.directory)
    XCTAssertFalse(
      StubRegistry.asked.contains { $0.url.contains("/blobs/") }, "\(StubRegistry.asked)")
  }

  /// A layer whose bytes don't match its digest is never unpacked.
  func testALayerThatDoesNotMatchItsDigestIsRefused() async throws {
    let layer = try featureTar(id: "x")
    let base = "https://r.io/v2/o/x"
    let digest = "sha256:" + String(repeating: "0", count: 64)
    StubRegistry.replies = [
      "\(base)/manifests/1": (
        200, [:],
        Data(
          #"{"layers": [{"mediaType": "application/vnd.devcontainers.layer.v1+tar", "digest": "\#(digest)"}]}"#
            .utf8)
      ),
      "\(base)/blobs/\(digest)": (200, [:], layer),
    ]
    let source = Features.OCISource(
      session: stubSession(),
      cache: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString))
    do {
      _ = try await source.fetch(try Reference("r.io/o/x:1"))
      XCTFail("a mismatched layer was used")
    } catch DevContainerFeatures.Failure.fetch(let why) {
      XCTAssertTrue(why.contains("digest"), why)
    }
  }

  // Value: protects=a cached feature is used only by a digest of the shape this Mac's own verified unpacks have; fails_when=the shape
  // check goes, and a manifest naming any folder in the cache gets that folder used unverified; why_new=only the valid-digest cache
  // hit was tested; seam=none; no_claim=a real registry
  /// A digest not shaped like a checked one (uppercase hex here) never takes a cached folder: its
  /// blob is fetched and checked, and fails.
  func testOnlyADigestOfTheRightShapeTakesTheCache() async throws {
    let base = "https://r.io/v2/o/x"
    let digest = "sha256:" + String(repeating: "A", count: 64)
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    let planted = cache.appendingPathComponent(digest.replacingOccurrences(of: ":", with: "-"))
    try FileManager.default.createDirectory(at: planted, withIntermediateDirectories: true)
    try Data(#"{"id": "planted", "version": "1.0.0"}"#.utf8).write(
      to: planted.appendingPathComponent("devcontainer-feature.json"))
    StubRegistry.replies = [
      "\(base)/manifests/1": (
        200, [:],
        Data(
          #"{"layers": [{"mediaType": "application/vnd.devcontainers.layer.v1+tar", "digest": "\#(digest)"}]}"#
            .utf8)
      ),
      "\(base)/blobs/\(digest)": (200, [:], try featureTar(id: "x")),
    ]
    let source = Features.OCISource(session: stubSession(), cache: cache)
    do {
      let fetched = try await source.fetch(try Reference("r.io/o/x:1"))
      XCTFail("a folder the digest's shape doesn't vouch for was used: \(fetched.metadata.id)")
    } catch DevContainerFeatures.Failure.fetch(let why) {
      XCTAssertTrue(why.contains("digest"), why)
    }
  }

  /// A local feature is a folder beside the devcontainer.json, and must stay inside its folder.
  func testALocalFeatureStaysBesideTheConfig() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent(".devcontainer/tool")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"id": "tool", "version": "0.1.0"}"#.utf8).write(
      to: folder.appendingPathComponent("devcontainer-feature.json"))
    let source = Features.OCISource(
      session: stubSession(), cache: root.appendingPathComponent("cache"),
      configFolder: root.appendingPathComponent(".devcontainer"))

    let fetched = try await source.fetch(.local("./tool"))
    XCTAssertEqual(fetched.metadata.id, "tool")
    do {
      _ = try await source.fetch(.local("../../etc"))
      XCTFail("a path outside the config's folder was read")
    } catch DevContainerFeatures.Failure.badReference {}
  }

  /// The real thing, by hand: a feature fetched from ghcr.io through `OCISource`, built by Apple's
  /// runtime into the devcontainers base image, and run. Skipped unless
  /// `TEST_RUNNER_WR_LIVE_FEATURE_TESTS=1` (network, and `container system start` run first).
  func testALiveFeatureBuildsOnApplesRuntime() async throws {
    guard ProcessInfo.processInfo.environment["WR_LIVE_FEATURE_TESTS"] == "1" else {
      throw XCTSkip("set TEST_RUNNER_WR_LIVE_FEATURE_TESTS=1 to fetch and build a real feature")
    }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: work) }
    let source = Features.OCISource(session: .shared, cache: work.appendingPathComponent("cache"))
    let features = try await Features.resolve(
      ["ghcr.io/devcontainers/features/github-cli:1": [:]], override: [], source: source)
    XCTAssertEqual(features.map(\.reference.key), ["ghcr.io/devcontainers/features/github-cli"])
    let context = work.appendingPathComponent("context")
    _ = try Features.writeContext(
      at: context, base: "mcr.microsoft.com/devcontainers/base:ubuntu", features: features,
      users: users, imageUser: "vscode")
    let tag = "wr-live-feature-\(UUID().uuidString.prefix(8).lowercased())"
    XCTAssertEqual(try run("/opt/homebrew/bin/container", ["build", "-t", tag, context.path]), 0)
    defer { _ = try? run("/opt/homebrew/bin/container", ["image", "delete", tag]) }
    XCTAssertEqual(
      try run("/opt/homebrew/bin/container", ["run", "--rm", tag, "gh", "--version"]), 0,
      "gh isn't in the built image")
  }

  private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  /// The env file is sourced by /bin/sh, so every value is single-quoted and a quote inside one
  /// can't end it early.
  func testTheEnvFileQuotesEveryValue() {
    XCTAssertEqual(
      Features.envFile(["B": "it's $HOME", "A": "plain"]), "A='plain'\nB='it'\\''s $HOME'\n")
  }
}
