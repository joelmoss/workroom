import CryptoKit
import Foundation

/// A devcontainer.json's features (containers.dev/implementors/features), built into a container
/// workroom's image (#308, eng review D2): each feature's folder is copied into a generated
/// Dockerfile and its `install.sh` run as root with its options in its environment, one layer per
/// feature, on any builder (Docker's or Apple's `container build`: COPY and RUN, no BuildKit-only
/// mounts).
enum DevContainerFeatures {
  typealias OptionValue = DevContainerConfig.OptionValue

  enum Failure: Error, Equatable, LocalizedError {
    case badReference(String)
    case badMetadata(String)
    /// Features whose dependencies never settle, named.
    case cycle([String])
    case fetch(String)

    var errorDescription: String? {
      switch self {
      case .badReference(let why): return "Not a feature reference: \(why)"
      case .badMetadata(let why): return "A feature's devcontainer-feature.json: \(why)"
      case .cycle(let keys):
        return "These features depend on each other, so none can install first: "
          + keys.joined(separator: ", ")
      case .fetch(let why): return "Couldn't download a feature: \(why)"
      }
    }
  }

  /// A feature downloaded and unpacked: its metadata, its folder, and the digest it was fetched by
  /// (an OCI manifest's), when it has one.
  struct Fetched: Sendable {
    var metadata: Metadata
    var directory: URL
    var digest: String?
  }

  /// Where features come from: the registry and the web (`OCISource`), or a test's.
  protocol Source: Sendable {
    func fetch(_ reference: Reference) async throws -> Fetched
  }

  /// A feature to install: as written (or as a dependency named it), with the options it was
  /// given, and what was fetched for it.
  struct Feature: Sendable {
    var reference: Reference
    var options: [String: OptionValue]
    var fetched: Fetched
  }

  /// `declared` (a devcontainer.json's `features`), with what they depend on added, in the order
  /// the spec installs them: each round installs the ready features (all their `dependsOn` and
  /// chosen `installsAfter` installed) of the highest `overrideFeatureInstallOrder` priority, in the
  /// spec's stable order (key, then tag oldest first, then most options). An override naming a
  /// feature that isn't chosen is ignored.
  static func resolve(
    _ declared: [String: [String: OptionValue]], override: [String], source: some Source
  ) async throws -> [Feature] {
    var features: [Feature] = []
    var pending = try declared.map { (try Reference($0.key), $0.value) }
      .sorted { $0.0.key < $1.0.key }
    // Hard edges, by index: a feature's index to the indexes it depends on.
    var dependsOn: [Int: Set<Int>] = [:]
    var parents: [(child: Int, reference: Reference, options: [String: OptionValue])] = []
    while !pending.isEmpty {
      let (reference, options) = pending.removeFirst()
      if features.contains(where: { $0.reference == reference && $0.options == options }) {
        continue
      }
      let fetched = try await source.fetch(reference)
      features.append(Feature(reference: reference, options: options, fetched: fetched))
      let index = features.count - 1
      for (id, depOptions) in fetched.metadata.dependsOn.sorted(by: { $0.key < $1.key }) {
        let dependency = try Reference(id)
        parents.append((index, dependency, depOptions))
        pending.append((dependency, depOptions))
      }
    }
    for parent in parents {
      if let dependency = features.firstIndex(where: {
        $0.reference == parent.reference && $0.options == parent.options
      }) {
        dependsOn[parent.child, default: []].insert(dependency)
      }
    }
    var after = dependsOn
    for (index, feature) in features.enumerated() {
      for key in feature.fetched.metadata.installsAfter {
        for (other, candidate) in features.enumerated()
        where other != index && candidate.reference.key == key {
          after[index, default: []].insert(other)
        }
      }
    }
    let priority: [String: Int] = Dictionary(
      override.enumerated().map { ($1, override.count - $0) }, uniquingKeysWith: max)
    var installed: [Int] = []
    var remaining = Set(features.indices)
    while !remaining.isEmpty {
      let ready = remaining.filter { (after[$0] ?? []).isSubset(of: Set(installed)) }
      guard !ready.isEmpty else {
        throw Failure.cycle(remaining.map { features[$0].reference.key }.sorted())
      }
      let top = ready.map { priority[features[$0].reference.key] ?? 0 }.max() ?? 0
      let round = ready.filter { (priority[features[$0].reference.key] ?? 0) == top }
        .sorted { stableOrder(features[$0], before: features[$1]) }
      installed += round
      remaining.subtract(round)
    }
    return installed.map { features[$0] }
  }

  /// The spec's round stable sort: key, then tag oldest to newest (`latest` newest), then the most
  /// options given, then their names and values.
  private static func stableOrder(_ a: Feature, before b: Feature) -> Bool {
    if a.reference.key != b.reference.key { return a.reference.key < b.reference.key }
    let (tagA, tagB) = (tag(a.reference), tag(b.reference))
    if tagA != tagB { return olderTag(tagA, than: tagB) }
    if a.options.count != b.options.count { return a.options.count > b.options.count }
    return describe(a.options) < describe(b.options)
  }

  private static func tag(_ reference: Reference) -> String {
    if case .oci(_, _, let tag) = reference { return tag }
    return ""
  }

  private static func olderTag(_ a: String, than b: String) -> Bool {
    if a == "latest" { return false }
    if b == "latest" { return true }
    let numbers = { (tag: String) in tag.split(separator: ".").map { Int($0) ?? 0 } }
    let (na, nb) = (numbers(a), numbers(b))
    for i in 0..<max(na.count, nb.count) {
      let (x, y) = (i < na.count ? na[i] : 0, i < nb.count ? nb[i] : 0)
      if x != y { return x < y }
    }
    return a < b
  }

  private static func describe(_ options: [String: OptionValue]) -> String {
    options.sorted { $0.key < $1.key }.map { "\($0.key)=\(render($0.value))" }.joined(
      separator: ",")
  }

  /// Where a feature comes from: the spec's three kinds.
  enum Reference: Hashable, Sendable {
    /// `<registry>/<namespace>/<id>[:tag|@digest]`; `latest` when it names no tag.
    case oci(registry: String, repository: String, tag: String)
    /// An https URL to a `devcontainer-feature-<id>.tgz`.
    case tarball(URL)
    /// `./<path>`, relative to the devcontainer.json's folder.
    case local(String)

    init(_ id: String) throws {
      if id.hasPrefix("./") || id.hasPrefix("../") {
        self = .local(id)
        return
      }
      if id.hasPrefix("https://") {
        guard let url = URL(string: id) else { throw Failure.badReference(id) }
        self = .tarball(url)
        return
      }
      guard !id.hasPrefix("/") else {
        throw Failure.badReference("\(id): a local feature is a path starting ./")
      }
      var rest = Substring(id)
      var tag = "latest"
      if let at = rest.firstIndex(of: "@") {
        tag = String(rest[rest.index(after: at)...])
        rest = rest[..<at]
      } else if let colon = rest.lastIndex(of: ":"), !rest[colon...].contains("/") {
        tag = String(rest[rest.index(after: colon)...])
        rest = rest[..<colon]
      }
      let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
      // A registry and at least a namespace and an id after it.
      guard parts.count == 2, parts[1].contains("/"), !tag.isEmpty else {
        throw Failure.badReference("\(id): it needs a registry, a namespace and an id")
      }
      self = .oci(registry: parts[0], repository: parts[1], tag: tag)
    }

    /// What `installsAfter`, `dependsOn` and `overrideFeatureInstallOrder` name it by: the
    /// reference without its version.
    var key: String {
      switch self {
      case .oci(let registry, let repository, _): return "\(registry)/\(repository)"
      case .tarball(let url): return url.absoluteString
      case .local(let path): return path
      }
    }
  }

  /// A feature's `devcontainer-feature.json`: what it is, its options, and what it adds to the
  /// image and the container.
  struct Metadata: Equatable, Sendable {
    struct Option: Equatable, Sendable {
      /// `boolean` or `string`.
      var type: String
      var defaultValue: OptionValue?
    }

    var id: String
    var version: String
    var options: [String: Option] = [:]
    /// Features this one needs installed first, each with its options: added when not chosen.
    var dependsOn: [String: [String: OptionValue]] = [:]
    /// Feature keys this one installs after, when they are chosen anyway.
    var installsAfter: [String] = []
    /// What it adds to the image and the container, in devcontainer.json's own shapes, which a
    /// feature's file shares: `containerEnv`, `mounts`, `privileged`, `capAdd`, `securityOpt` and
    /// the lifecycle commands.
    var contributed = DevContainerConfig()
    /// A script the feature wants run as the container starts. Workroom's daemon is the entrypoint,
    /// so it isn't run; the create warns.
    var entrypoint: String?

    /// The file a feature's folder describes it in.
    static let fileName = "devcontainer-feature.json"

    /// The metadata in a feature's folder.
    static func read(in directory: URL) throws -> Metadata {
      let file = directory.appendingPathComponent(fileName)
      guard let data = try? Data(contentsOf: file) else {
        throw Failure.badMetadata("\(directory.lastPathComponent) has no \(fileName)")
      }
      return try parse(data)
    }

    static func parse(_ data: Data) throws -> Metadata {
      let decoder = JSONDecoder()
      decoder.allowsJSON5 = true
      let file: File
      let contributed: DevContainerConfig
      do {
        file = try decoder.decode(File.self, from: data)
        contributed = try DevContainerConfig.parse(data)
      } catch {
        throw Failure.badMetadata(error.localizedDescription)
      }
      return Metadata(
        id: file.id, version: file.version,
        options: (file.options ?? [:]).mapValues {
          Option(type: $0.type ?? "string", defaultValue: $0.default?.value)
        },
        dependsOn: (file.dependsOn ?? [:]).mapValues { $0.mapValues(\.value) },
        installsAfter: file.installsAfter ?? [], contributed: contributed,
        entrypoint: file.entrypoint)
    }

    private struct File: Decodable {
      var id: String
      var version: String
      var options: [String: OptionObject]?
      var dependsOn: [String: [String: AnyOption]]?
      var installsAfter: [String]?
      var entrypoint: String?
    }

    private struct OptionObject: Decodable {
      var type: String?
      var `default`: AnyOption?
    }

    private struct AnyOption: Decodable {
      let value: OptionValue

      init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
          value = .bool(flag)
        } else {
          value = .string(try container.decode(String.self))
        }
      }
    }
  }

  /// What `install.sh` is given for `metadata`'s options: each option given, else its default, under
  /// the spec's variable name. Options the feature doesn't declare are passed too, as the spec's
  /// tool does.
  static func environment(for metadata: Metadata, given: [String: OptionValue]) -> [String: String]
  {
    var environment: [String: String] = [:]
    for (name, option) in metadata.options {
      if let value = given[name] ?? option.defaultValue {
        environment[variableName(name)] = render(value)
      }
    }
    for (name, value) in given where metadata.options[name] == nil {
      environment[variableName(name)] = render(value)
    }
    return environment
  }

  /// The spec's rule: `name.replace(/[^\w_]/g, '_').replace(/^[\d_]+/g, '_').toUpperCase()`.
  static func variableName(_ name: String) -> String {
    let word = name.map { $0.isLetter || $0.isNumber || $0 == "_" ? String($0) : "_" }.joined()
    let leading = word.prefix { $0.isNumber || $0 == "_" }
    let rest = word.dropFirst(leading.count)
    return ((leading.isEmpty ? "" : "_") + rest).uppercased()
  }

  private static func render(_ value: OptionValue) -> String {
    switch value {
    case .string(let string): return string
    case .bool(let flag): return flag ? "true" : "false"
    }
  }

  // MARK: Fetching

  /// Features from their registry (the OCI distribution flow, anonymous), from an https tarball, or
  /// from a folder beside the devcontainer.json. Each is unpacked under `cache`, by digest.
  struct OCISource: Source {
    let session: URLSession
    let cache: URL
    /// The devcontainer.json's folder, for `./` features; nil refuses them.
    var configFolder: URL?

    /// The layer media type the spec gives a feature's tarball.
    static let layerType = "application/vnd.devcontainers.layer.v1+tar"
    static let manifestType = "application/vnd.oci.image.manifest.v1+json"

    func fetch(_ reference: Reference) async throws -> Fetched {
      switch reference {
      case .local(let path): return try local(path)
      case .tarball(let url):
        let (data, _) = try await get(URLRequest(url: url))
        let digest = "sha256:" + Self.sha256(data)
        return Fetched(
          metadata: try Metadata.read(in: try unpack(data, as: digest)),
          directory: folder(for: digest), digest: digest)
      case .oci(let registry, let repository, let tag):
        let base = "https://\(registry)/v2/\(repository)"
        var manifestRequest = URLRequest(url: try url("\(base)/manifests/\(tag)"))
        manifestRequest.setValue(Self.manifestType, forHTTPHeaderField: "Accept")
        let (manifestData, response, token) = try await authorizedGet(manifestRequest)
        let manifest: Manifest
        do {
          manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
          throw Failure.fetch("\(reference.key): its manifest isn't one: \(error)")
        }
        guard let layer = manifest.layers.first(where: { $0.mediaType == Self.layerType }) else {
          throw Failure.fetch("\(reference.key): its manifest has no feature layer")
        }
        var blobRequest = URLRequest(url: try url("\(base)/blobs/\(layer.digest)"))
        if let token {
          blobRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (blob, _) = try await get(blobRequest)
        // Content-addressed: bytes that aren't the ones the manifest named are never unpacked.
        guard layer.digest == "sha256:" + Self.sha256(blob) else {
          throw Failure.fetch("\(reference.key): its layer doesn't match its digest")
        }
        let directory = try unpack(blob, as: layer.digest)
        return Fetched(
          metadata: try Metadata.read(in: directory), directory: directory,
          digest: response.value(forHTTPHeaderField: "Docker-Content-Digest") ?? layer.digest)
      }
    }

    private func local(_ path: String) throws -> Fetched {
      guard let configFolder else {
        throw Failure.badReference("\(path): a local feature needs a devcontainer.json's folder")
      }
      let root = configFolder.standardizedFileURL.resolvingSymlinksInPath()
      let directory = root.appendingPathComponent(path).standardizedFileURL
        .resolvingSymlinksInPath()
      guard directory.path.hasPrefix(root.path + "/") else {
        throw Failure.badReference("\(path) is outside the devcontainer.json's folder")
      }
      return Fetched(metadata: try Metadata.read(in: directory), directory: directory, digest: nil)
    }

    /// `request`, and if the registry challenges it, again with an anonymous token from the
    /// challenge's realm.
    private func authorizedGet(_ request: URLRequest) async throws -> (
      Data, HTTPURLResponse, String?
    ) {
      let (data, response) = try await session.data(for: request)
      let http = try httpResponse(response, for: request)
      guard http.statusCode == 401 else {
        try check(http, data, for: request)
        return (data, http, nil)
      }
      guard let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate"),
        let tokenURL = Self.tokenURL(challenge)
      else {
        throw Failure.fetch("\(request.url?.absoluteString ?? ""): the registry refused it")
      }
      let (tokenData, _) = try await get(URLRequest(url: tokenURL))
      guard
        let token = (try? JSONDecoder().decode(Token.self, from: tokenData))
          .flatMap({ $0.token ?? $0.access_token })
      else {
        throw Failure.fetch("\(tokenURL.host ?? ""): no token came back")
      }
      var authorized = request
      authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      let (retried, again) = try await get(authorized)
      return (retried, again, token)
    }

    /// `Bearer realm="…",service="…",scope="…"` as the URL its token comes from.
    static func tokenURL(_ challenge: String) -> URL? {
      guard challenge.lowercased().hasPrefix("bearer ") else { return nil }
      var fields: [String: String] = [:]
      for part in challenge.dropFirst("bearer ".count).split(separator: ",") {
        let pair = part.split(separator: "=", maxSplits: 1).map {
          $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        if pair.count == 2 { fields[pair[0]] = pair[1] }
      }
      guard let realm = fields["realm"], var components = URLComponents(string: realm) else {
        return nil
      }
      components.queryItems = ["scope", "service"].compactMap { key in
        fields[key].map { URLQueryItem(name: key, value: $0) }
      }
      return components.url
    }

    private func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      let (data, response) = try await session.data(for: request, delegate: DropAuthorization())
      let http = try httpResponse(response, for: request)
      try check(http, data, for: request)
      return (data, http)
    }

    private func httpResponse(_ response: URLResponse, for request: URLRequest) throws
      -> HTTPURLResponse
    {
      guard let http = response as? HTTPURLResponse else {
        throw Failure.fetch("\(request.url?.absoluteString ?? ""): not an HTTP response")
      }
      return http
    }

    private func check(_ http: HTTPURLResponse, _ data: Data, for request: URLRequest) throws {
      guard (200..<300).contains(http.statusCode) else {
        throw Failure.fetch("\(request.url?.absoluteString ?? ""): HTTP \(http.statusCode)")
      }
    }

    private func url(_ string: String) throws -> URL {
      guard let url = URL(string: string) else { throw Failure.badReference(string) }
      return url
    }

    private func folder(for digest: String) -> URL {
      cache.appendingPathComponent(
        digest.replacingOccurrences(of: ":", with: "-"), isDirectory: true)
    }

    /// Unpacks a feature's tar (gzipped or not: bsdtar reads either) into its digest's folder.
    private func unpack(_ data: Data, as digest: String) throws -> URL {
      let directory = folder(for: digest)
      if FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(Metadata.fileName).path)
      {
        return directory
      }
      try? FileManager.default.removeItem(at: directory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let archive = directory.appendingPathExtension("tar")
      try data.write(to: archive)
      defer { try? FileManager.default.removeItem(at: archive) }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      process.arguments = ["-xf", archive.path, "-C", directory.path]
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw Failure.fetch("\(digest): its layer isn't a tar archive")
      }
      return directory
    }

    static func sha256(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Manifest: Decodable {
      struct Layer: Decodable {
        var mediaType: String
        var digest: String
      }
      var layers: [Layer]
    }

    private struct Token: Decodable {
      var token: String?
      // swift-format-ignore: AlwaysUseLowerCamelCase
      var access_token: String?
    }
  }

  /// Drops a registry token when a blob request is redirected to another host (ghcr sends blobs to
  /// signed storage URLs, which refuse a stray Authorization header).
  private final class DropAuthorization: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest
    ) async -> URLRequest? {
      var next = request
      if request.url?.host != task.originalRequest?.url?.host {
        next.setValue(nil, forHTTPHeaderField: "Authorization")
      }
      return next
    }
  }

  // MARK: The image

  /// The users `install.sh` is told about (`_CONTAINER_USER`, `_REMOTE_USER` and their homes), as
  /// the create finds them in the base image.
  struct Users: Equatable, Sendable {
    var container: String
    var remote: String
    var containerHome: String
    var remoteHome: String
  }

  /// A Dockerfile that builds `features` onto `base`: one layer per feature, as root, its
  /// `containerEnv` before its script (a `${PATH}` in it extends the image's, as Docker expands it),
  /// then the image's own user again.
  static func dockerfile(base: String, features: [Feature], users: Users, imageUser: String)
    -> String
  {
    var lines = [
      "FROM \(base)", "USER root",
      "ARG _CONTAINER_USER=\(quoted(users.container))",
      "ARG _REMOTE_USER=\(quoted(users.remote))",
      "ARG _CONTAINER_USER_HOME=\(quoted(users.containerHome))",
      "ARG _REMOTE_USER_HOME=\(quoted(users.remoteHome))",
    ]
    for (index, feature) in features.enumerated() {
      for (key, value) in feature.fetched.metadata.contributed.containerEnv.sorted(by: {
        $0.key < $1.key
      }) {
        lines.append("ENV \(key)=\(quoted(value))")
      }
      let folder = "/tmp/workroom-features/\(index)"
      lines.append("COPY features/\(index) \(folder)")
      lines.append(
        "RUN cd \(folder) && chmod +x install.sh && set -a && . ./devcontainer-features.env "
          + "&& set +a && ./install.sh && rm -rf \(folder)")
    }
    lines.append("USER \(imageUser)")
    return lines.joined(separator: "\n") + "\n"
  }

  /// A Dockerfile string literal: `"` and `\` escaped, `$` left for Docker to expand.
  private static func quoted(_ value: String) -> String {
    "\""
      + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "\"", with: "\\\"") + "\""
  }

  /// Writes the build context for `dockerfile(…)` at `directory`: the Dockerfile, and each
  /// feature's folder with its options' env file under `features/<index>`. Returns the Dockerfile.
  static func writeContext(
    at directory: URL, base: String, features: [Feature], users: Users, imageUser: String
  ) throws -> URL {
    let files = FileManager.default
    for (index, feature) in features.enumerated() {
      let folder = directory.appendingPathComponent("features/\(index)", isDirectory: true)
      try files.createDirectory(
        at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
      try files.copyItem(at: feature.fetched.directory, to: folder)
      try Data(
        envFile(environment(for: feature.fetched.metadata, given: feature.options)).utf8
      ).write(to: folder.appendingPathComponent("devcontainer-features.env"))
    }
    let dockerfile = directory.appendingPathComponent("Dockerfile")
    try Data(
      self.dockerfile(base: base, features: features, users: users, imageUser: imageUser).utf8
    ).write(to: dockerfile)
    return dockerfile
  }

  /// What features add to the container they are built into.
  struct Contributions: Equatable, Sendable {
    var mounts: [DevContainerConfig.Mount] = []
    var capAdd: [String] = []
    var securityOpt: [String] = []
    /// Any feature wanting it makes the container privileged (the spec's rule).
    var privileged = false
    /// Each feature's lifecycle commands, in install order: they run before the file's own.
    var lifecycle:
      [(feature: String, hook: DevContainerConfig.Hook, command: DevContainerConfig.Command)] =
        []
    /// Features whose entrypoint Workroom can't run (its daemon is the container's entrypoint).
    var entrypoints: [String] = []

    static func == (a: Contributions, b: Contributions) -> Bool {
      a.mounts == b.mounts && a.capAdd == b.capAdd && a.securityOpt == b.securityOpt
        && a.privileged == b.privileged && a.entrypoints == b.entrypoints
        && a.lifecycle.map(\.feature) == b.lifecycle.map(\.feature)
        && a.lifecycle.map(\.hook) == b.lifecycle.map(\.hook)
        && a.lifecycle.map(\.command) == b.lifecycle.map(\.command)
    }
  }

  /// `features`' contributions, merged as the spec has it: mounts and capabilities concatenated,
  /// privileged if any one wants it.
  static func contributions(of features: [Feature]) -> Contributions {
    var added = Contributions()
    for feature in features {
      let key = feature.reference.key
      let contributed = feature.fetched.metadata.contributed
      added.mounts += contributed.mounts
      added.capAdd += contributed.capAdd
      added.securityOpt += contributed.securityOpt
      added.privileged = added.privileged || contributed.privileged
      for hook in DevContainerConfig.Hook.allCases {
        if let command = contributed.lifecycle[hook] {
          added.lifecycle.append((key, hook, command))
        }
      }
      if feature.fetched.metadata.entrypoint != nil { added.entrypoints.append(key) }
    }
    return added
  }

  /// `environment` as a file `/bin/sh` sources (`set -a; . ./devcontainer-features.env`): every
  /// value single-quoted, in name order.
  static func envFile(_ environment: [String: String]) -> String {
    environment.sorted { $0.key < $1.key }.map { key, value in
      "\(key)='\(value.replacingOccurrences(of: "'", with: "'\\''"))'\n"
    }.joined()
  }
}
