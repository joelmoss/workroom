import DaemonConnection
import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS

/// A container create's dev container (#308; design doc, "Any image, reached over `docker exec`"):
/// before the container, its devcontainer.json is read from the judged commit, its
/// initializeCommand runs on this Mac, and its image is pulled or built (with any features); after
/// the clone and "Copy local files", its lifecycle commands run in the container, in the spec's
/// order, ahead of `scripts/workroom_setup`. Each part reports its creation row
/// (`ProvisioningProgress`), and `DevContainerSetup` does the arithmetic.
enum ContainerCreate {
  /// The devcontainer.json a create uses: where it is in the repository, the exact bytes this Mac
  /// judged (#308, eng review D4), and what they say.
  struct File: Sendable {
    let path: String
    let data: Data
    let config: DevContainerConfig
    /// The base commit has none, so this is the project root's copy (eng review S3): what it
    /// builds from is the root's too, which may not be committed yet.
    var fromRoot = false
  }

  enum Failure: Error, LocalizedError, Equatable {
    case unreadable(file: String, detail: String)
    case noImage(file: String)
    case outsideRepository(file: String, path: String)
    case initializeFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
      switch self {
      case .unreadable(let file, let detail): return "\(file) can't be read: \(detail)"
      case .noImage(let file):
        return "\(file) names neither an image nor a Dockerfile to build, so there's nothing to "
          + "make the container from."
      case .outsideRepository(let file, let path):
        return "\(file) builds from \(path), which is outside the repository."
      case .initializeFailed(let why): return "initializeCommand failed: \(why)"
      case .exportFailed(let why): return "Couldn't read the repository's files to build: \(why)"
      }
    }
  }

  /// The judged devcontainer.json, or nil when the create goes on the default image: none was
  /// judged (the repository has none, or the user chose Continue With Default Image).
  static func file(in status: TrustStatus?) throws -> File? {
    guard let judged = status?.scripts.first(where: \.isDevContainer) else { return nil }
    let path = judged.file ?? DevContainerConfig.paths[0]
    do {
      return File(
        path: path, data: judged.approvalBytes,
        config: try DevContainerConfig.parse(judged.approvalBytes),
        fromRoot: judged.origin == "root")
    } catch {
      throw Failure.unreadable(file: path, detail: error.localizedDescription)
    }
  }

  /// What the create goes on with once the image is ready.
  struct Prepared: Sendable {
    let spec: ContainerHostDriver.ContainerSpec
    /// The checkout's path in the container.
    let workspaceFolder: String
    /// Each lifecycle command's script, in the order they run.
    let hooks: [(hook: DevContainerConfig.Hook, script: String)]
    /// `remoteEnv`, resolved, for the setup script.
    let remoteEnvironment: [String: String]
    /// What the container records it was made from (eng review D7).
    let configDigest: String
    let configFile: String?
    /// Whether the image was pulled rather than built from a Dockerfile.
    let pulled: Bool
    /// Keys and features Workroom left out, one line each, for the config row's warning.
    let warnings: [String]
  }

  /// Everything before the container: the config row, initializeCommand, the pull or build, and
  /// the container's spec. `start` is the judged commit, which a build's files come from.
  static func prepare(
    _ file: File?, project: String, repository: String, start: String,
    runtime: RemoteWorkrooms.Runtime, driver: ContainerHostDriver, defaultImage: String,
    environment: [String: String] = ProcessInfo.processInfo.environment, featureCache: URL
  ) async throws -> Prepared {
    let config = file?.config
    // Where its Dockerfile, build context and local features are read: the judged commit, or the
    // root's folder as it is.
    let revision = file?.fromRoot == true ? nil : start
    var warnings: [String] = []
    if let file, let config {
      ProvisioningProgress.reportStep?(.config)
      ProvisioningProgress.log?(.config, "Read \(file.path) at \(start.prefix(12))")
      warnings += config.ignoredKeys(on: runtime).map { "\($0.key) is left out: \($0.reason)" }
      for line in warnings { ProvisioningProgress.log?(.config, line) }
    }
    if let command = config?.lifecycle[.initialize] {
      try await ProvisioningProgress.step(.initialize) {
        try await runOnMac(command, in: project)
      }
    }

    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workroom-devcontainer-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    // The file's folder in the repository, which its relative paths start from.
    let folder = (file.map { ($0.path as NSString).deletingLastPathComponent } ?? "")
    let variables = { (workspace: String) in
      DevContainerConfig.Variables(
        localEnv: environment, localWorkspaceFolder: project, containerWorkspaceFolder: workspace,
        devcontainerId: DevContainerSetup.devcontainerID(project: project))
    }
    let workspace = DevContainerSetup.workspaceFolder(config, repository: repository)

    var image: String
    var pulled = true
    switch config?.source {
    case nil:
      if let file { throw Failure.noImage(file: file.path) }
      image = defaultImage
    case .image(let named):
      image = named
    case .build(let build):
      pulled = false
      let file = file?.path ?? ""
      let context = try repositoryPath(folder, build.context, file: file)
      let dockerfile = try repositoryPath(folder, build.dockerfile, file: file)
      let source = scratch.appendingPathComponent("source", isDirectory: true)
      image = "workroom-build-\(UUID().uuidString.prefix(8).lowercased())"
      try await ProvisioningProgress.step(.build) {
        try await export(project: project, at: revision, paths: [context, dockerfile], to: source)
        try await driver.build(
          dockerfile: source.appendingPathComponent(dockerfile),
          context: source.appendingPathComponent(context), tag: image,
          arguments: build.args.mapValues(variables(workspace).substitute), target: build.target,
          options: build.options)
      }
    }
    if pulled {
      try await ProvisioningProgress.step(.image) { try await driver.ensureImage(image) }
    }

    var contributions = DevContainerFeatures.Contributions()
    if let config, !config.features.isEmpty {
      let base = image
      let built = "workroom-build-\(UUID().uuidString.prefix(8).lowercased())"
      try await ProvisioningProgress.step(.build) {
        // A feature named by a path is one of the repository's, read where the file was.
        let source = scratch.appendingPathComponent("features-source", isDirectory: true)
        let local = config.features.keys.contains { $0.hasPrefix("./") || $0.hasPrefix("../") }
        if local {
          try await export(project: project, at: revision, paths: [folder], to: source)
        }
        let features = try await DevContainerFeatures.resolve(
          config.features, override: config.overrideFeatureInstallOrder,
          source: DevContainerFeatures.OCISource(
            session: .shared, cache: featureCache,
            configFolder: local ? source.appendingPathComponent(folder) : nil))
        let baseImage = try await driver.imageConfig(base)
        let context = scratch.appendingPathComponent("features", isDirectory: true)
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        let dockerfile = try DevContainerFeatures.writeContext(
          at: context, base: base, features: features,
          users: DevContainerSetup.users(config, image: baseImage),
          imageUser: baseImage.user ?? "root")
        try await driver.build(dockerfile: dockerfile, context: context, tag: built)
        contributions = DevContainerFeatures.contributions(of: features)
      }
      image = built
      if !contributions.entrypoints.isEmpty {
        warnings.append(
          "The entrypoint of \(contributions.entrypoints.joined(separator: ", ")) doesn't run: "
            + "Workroom's daemon is the container's entrypoint")
      }
    }

    let resolved = try await driver.imageConfig(image)
    let remoteEnvironment = DevContainerSetup.remoteEnvironment(
      config, image: resolved, variables: variables(workspace))
    let spec = DevContainerSetup.spec(
      image: image, config: config, contributions: contributions,
      remoteEnvironment: remoteEnvironment, variables: variables(workspace),
      workspaceFolder: workspace)
    let hooks = DevContainerSetup.hooks(config, contributions: contributions).map {
      (
        $0.hook,
        DevContainerSetup.hookScript(
          $0.hook, commands: $0.commands, checkout: workspace, environment: remoteEnvironment)
      )
    }
    return Prepared(
      spec: spec, workspaceFolder: workspace, hooks: hooks, remoteEnvironment: remoteEnvironment,
      configDigest: DevContainerSetup.configDigest(file: file?.data, image: image),
      configFile: file?.path, pulled: pulled, warnings: warnings)
  }

  /// `relative`, from the file's `folder`, as a path in the repository; outside it is refused.
  static func repositoryPath(_ folder: String, _ relative: String, file: String) throws -> String {
    var parts: [Substring] = []
    for part in (folder + "/" + relative).split(separator: "/") {
      switch part {
      case ".": continue
      case "..":
        guard !parts.isEmpty else { throw Failure.outsideRepository(file: file, path: relative) }
        parts.removeLast()
      default: parts.append(part)
      }
    }
    return parts.isEmpty ? "." : parts.joined(separator: "/")
  }

  /// `paths` of the repository at `revision`, written under `directory` as a checkout of it would
  /// have them (`git archive`); with no revision, as they are in the project's folder.
  private static func export(
    project: String, at revision: String?, paths: [String], to directory: URL
  ) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let q = PosixShell.quoted
    let listed = Set(paths).sorted().map(q).joined(separator: " ")
    let script =
      (revision.map { "git -C \(q(project)) archive --format=tar \(q($0)) -- \(listed)" }
        ?? "tar -c -f - -C \(q(project)) -- \(listed)")
      + " | tar -x -f - -C \(q(directory.path))"
    let (status, said) = try await shell(script, in: project, timeout: 300)
    guard status == 0 else { throw Failure.exportFailed(said) }
  }

  /// initializeCommand, on this Mac in the project's folder (eng review D6), its output in the
  /// row's log. 10 minutes, as a lifecycle command in the container.
  private static func runOnMac(_ command: DevContainerConfig.Command, in project: String)
    async throws
  {
    let script = DevContainerSetup.hookScript(
      .initialize, commands: [command], checkout: project, environment: [:])
    let (status, said) = try await shell(script, in: project, timeout: 600, log: .initialize)
    guard status == 0 else {
      let last = said.split(separator: "\n").last.map(String.init) ?? ""
      throw Failure.initializeFailed("it exited \(status)\(last.isEmpty ? "" : ": \(last)")")
    }
  }

  /// `/bin/sh -c script` on this Mac, with its output, line by line, in `log`'s row when given.
  private static func shell(
    _ script: String, in directory: String, timeout: TimeInterval,
    log step: ProvisioningProgress.Step? = nil
  ) async throws -> (status: Int32, output: String) {
    let sink = step.flatMap { step in
      ProvisioningProgress.log.map { log in { @Sendable (line: String) in log(step, line) } }
    }
    let lines = RemoteProvisioning.LineSplitter { sink?($0) }
    defer { lines.finish() }
    let stream = try HostStream.spawn(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "cd \(PosixShell.quoted(directory)) && \(script)"],
      environment: ProcessInfo.processInfo.environment, handshakeTimeout: 10, purpose: .exchange)
    do {
      return try await stream.communicate(
        nil, timeout: timeout, onOutput: { data, stderr in lines.add(data, stderr) })
    } catch {
      stream.end()
      throw error
    }
  }

  /// The digest (`DevContainerSetup.configDigest`) of the devcontainer.json `ref` has in `project`
  /// on this Mac, or nil when it has none, for the Details pane's note (eng review D7).
  static func configDigest(project: String, ref: String) async -> String? {
    for path in DevContainerConfig.paths {
      let q = PosixShell.quoted
      guard
        let (status, text) = try? await shell(
          "git cat-file --filters \(q("\(ref):\(path)")) 2>/dev/null", in: project, timeout: 10),
        status == 0
      else { continue }
      return DevContainerSetup.configDigest(file: Data(text.utf8), image: "")
    }
    return nil
  }

  // MARK: After the clone

  /// Runs `hook`'s script in the container as the remote user, through `workroomd run-script`:
  /// written first to the hooks folder, where a later start's connect finds postStartCommand
  /// again (`ContainerHostDriver.runPostStartIfNeeded`). Nil when it passed; else why not. A
  /// postStartCommand is marked done either way, so panes don't wait on it.
  static func runHook(
    _ hook: DevContainerConfig.Hook, script: String, on host: HostID, driver: any HostDriver,
    daemonBinary: String, folder: String = ContainerHostDriver.hooksFolder,
    done: String = ContainerHostDriver.postStartDone,
    onLine: @escaping @Sendable (String) -> Void
  ) async -> String? {
    let q = PosixShell.quoted
    let path = folder + "/" + hook.rawValue
    do {
      let write = try await driver.exec(
        "mkdir -p \(q(folder)) && cat > \(q(path)) && chmod 755 \(q(path))", on: host)
      let written = try await write.communicate(Data(script.utf8), timeout: 30)
      guard written.status == 0 else {
        return "\(hook.rawValue) couldn't be written to the container: \(written.output)"
      }
      let lines = RemoteProvisioning.LineSplitter(onLine)
      defer { lines.finish() }
      let run = try await driver.exec(
        "\(q(daemonBinary)) run-script --dir / --timeout \(Int(RemoteProvisioning.scriptTimeout))"
          + " -- \(q(path))"
          + (hook == .postStart ? "; status=$?; : > \(q(done)); exit $status" : ""),
        on: host)
      let status: Int32
      do {
        (status, _) = try await run.communicate(
          nil, timeout: RemoteProvisioning.scriptTimeout + 30,
          onOutput: { data, stderr in lines.add(data, stderr) })
      } catch {
        run.end()
        throw error
      }
      switch status {
      case 0: return nil
      case 124: return "The dev container's \(hook.rawValue) timed out after 10 minutes."
      default: return "The dev container's \(hook.rawValue) failed: it exited \(status)."
      }
    } catch {
      return "The dev container's \(hook.rawValue) failed: \(error.localizedDescription)"
    }
  }
}
