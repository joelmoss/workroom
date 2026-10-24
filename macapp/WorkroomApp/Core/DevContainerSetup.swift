import CryptoKit
import Foundation
import HostDrivers
import WorkroomSystem

/// How a container create turns a repository's dev container into a container (#308): the image,
/// the folders, the environments and the lifecycle commands, from its devcontainer.json
/// (`DevContainerConfig`), its features' contributions, and the image itself. Pure, so the create
/// (`AppStore+WorkroomCreation`) only fetches, builds and runs.
enum DevContainerSetup {
  /// The image a project with no devcontainer.json, or one going on the default, is made from (eng
  /// review D8): the devcontainers project's plain Ubuntu (26.04; user `vscode` with passwordless
  /// sudo, git, zsh, curl), by its multi-platform index digest, so Docker on an Intel Mac gets the
  /// amd64 one. Nothing is added to it. Read from the registry 2026-10-23 (tag `ubuntu`).
  static let pinnedDefaultImage =
    "mcr.microsoft.com/devcontainers/base@sha256:"
    + "91eff046d5c12318fc98e59258982b87ba896c467427ed8b5dab5a02107a5db7"

  /// Where the workroom's checkout goes: the file's `workspaceFolder`, its variables substituted
  /// (VS Code's templates write `/workspaces/${localWorkspaceFolderBasename}`), else the spec's
  /// default, `/workspaces/<repository>`. The container's own folder isn't known yet, so
  /// `variables` has none.
  static func workspaceFolder(
    _ config: DevContainerConfig?, repository: String, variables: DevContainerConfig.Variables
  ) -> String {
    let named = config?.workspaceFolder.flatMap { $0.isEmpty ? nil : variables.substitute($0) }
    return named ?? "/workspaces/\(repository)"
  }

  /// The spec's `${devcontainerId}`, unique to the container it is made for: each workroom is a
  /// container of its own, so two of one project never share a volume named by it (as
  /// docker-in-docker's `/var/lib/docker`). There is no rebuild for it to survive.
  static func newDevcontainerID() -> String {
    UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
  }

  /// The users the features' scripts are told about (`_REMOTE_USER` and the rest), and the one the
  /// workroom runs as: the file's, else the image's devcontainer metadata, else its own, else root.
  /// A user's home is guessed as the images lay it out, since the image isn't run to ask.
  static func users(
    _ config: DevContainerConfig?, image: ContainerHostDriver.ImageConfig
  ) -> DevContainerFeatures.Users {
    let container = config?.containerUser ?? image.metadataUser ?? image.user ?? "root"
    let remote = config?.remoteUser ?? container
    func home(_ user: String) -> String { user == "root" ? "/root" : "/home/\(user)" }
    return .init(
      container: container, remote: remote, containerHome: home(container),
      remoteHome: home(remote))
  }

  /// The file's `containerEnv`, its variables substituted: set on the container.
  static func containerEnvironment(
    _ config: DevContainerConfig?, variables: DevContainerConfig.Variables
  ) -> [String: String] {
    (config?.containerEnv ?? [:]).mapValues(variables.substitute)
  }

  /// The file's `remoteEnv`, its variables substituted, `${containerEnv:…}` reading the image's
  /// environment under the file's `containerEnv`. A variable it unsets (null) is left out: the
  /// login shell's value stands.
  static func remoteEnvironment(
    _ config: DevContainerConfig?, image: ContainerHostDriver.ImageConfig,
    variables: DevContainerConfig.Variables
  ) -> [String: String] {
    var variables = variables
    variables.containerEnv = image.environment.merging(
      containerEnvironment(config, variables: variables)
    ) { _, file in file }
    return (config?.remoteEnv ?? [:]).compactMapValues { $0.map(variables.substitute) }
  }

  /// The container to make from `image` (#308). Its environment is `containerEnv` with `remoteEnv`
  /// on top: the daemon is the only process tree in the container, so a pane's shell has both, as
  /// the spec has it for terminals (a login shell's profile can still set a variable over them).
  static func spec(
    image: String, config: DevContainerConfig?, contributions: DevContainerFeatures.Contributions,
    remoteEnvironment: [String: String], variables: DevContainerConfig.Variables,
    workspaceFolder: String
  ) -> ContainerHostDriver.ContainerSpec {
    let mounts = (contributions.mounts + (config?.mounts ?? [])).map {
      ContainerHostDriver.Mount(
        type: $0.type, source: $0.source.map(variables.substitute),
        target: variables.substitute($0.target), readOnly: $0.readOnly)
    }
    return ContainerHostDriver.ContainerSpec(
      image: image, user: config?.remoteUser ?? config?.containerUser,
      environment: containerEnvironment(config, variables: variables).merging(remoteEnvironment) {
        _, remote in remote
      },
      mounts: mounts, runArgs: (config?.runArgs ?? []).map(variables.substitute),
      privileged: (config?.privileged ?? false) || contributions.privileged,
      capAdd: unique(contributions.capAdd + (config?.capAdd ?? [])),
      securityOpt: unique(contributions.securityOpt + (config?.securityOpt ?? [])),
      workspaceFolder: workspaceFolder,
      ownedVolumes: unique(
        mounts.compactMap { mount in
          mount.type == "volume" ? mount.source : nil
        }.filter { $0.contains(variables.devcontainerId) }))
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  /// The container's lifecycle commands to run after the clone, in the spec's order: each hook's
  /// features' commands, in install order, then the file's own. A hook with none is left out.
  static func hooks(
    _ config: DevContainerConfig?, contributions: DevContainerFeatures.Contributions
  ) -> [(hook: DevContainerConfig.Hook, commands: [DevContainerConfig.Command])] {
    DevContainerConfig.Hook.inContainer.compactMap { hook in
      let commands =
        contributions.lifecycle.filter { $0.hook == hook }.map(\.command)
        + (config?.lifecycle[hook].map { [$0] } ?? [])
      return commands.isEmpty ? nil : (hook, commands)
    }
  }

  /// A hook's script, as `workroomd run-script` runs it: in the checkout, with `remoteEnv` on top
  /// of the login shell's environment, each command in turn, stopping at the first that fails. A
  /// string runs in `/bin/sh`, an array without a shell, an object's entries at once, each of
  /// which must succeed (the spec's three forms).
  static func hookScript(
    _ hook: DevContainerConfig.Hook, commands: [DevContainerConfig.Command], checkout: String,
    environment: [String: String]
  ) -> String {
    let q = PosixShell.quoted
    var lines = [
      "#!/bin/sh", "# \(hook.rawValue), from devcontainer.json, written by Workroom.",
      "cd \(q(checkout)) || exit 1",
    ]
    for (name, value) in environment.sorted(by: { $0.key < $1.key }) where isName(name) {
      lines.append("export \(name)=\(q(value))")
    }
    func line(_ command: DevContainerConfig.Command) -> String {
      switch command {
      case .shell(let text): return "/bin/sh -c \(q(text))"
      case .exec(let argv): return argv.map(q).joined(separator: " ")
      case .parallel: return ":"  // never nested (`DevContainerConfig.Named`)
      }
    }
    for command in commands {
      guard case .parallel(let entries) = command else {
        lines.append("\(line(command)) || exit $?")
        continue
      }
      lines.append("pids=")
      for entry in entries {
        lines.append("\(line(entry.command)) & pids=\"$pids $!\"")
      }
      lines.append(
        "failed=0; for pid in $pids; do wait \"$pid\" || failed=1; done; "
          + "[ \"$failed\" = 0 ] || exit 1")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// A name `export` takes.
  private static func isName(_ name: String) -> Bool {
    name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
  }

  /// What a container records of the config it was made from, for the Details pane to say when the
  /// repository's has moved on (eng review D7): the devcontainer.json's bytes, hashed, or the image
  /// it went on without one.
  static func configDigest(file: Data?, image: String) -> String {
    guard let file else { return "image:\(image)" }
    return "sha256:" + SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
  }

  /// What the Details pane says when the repository's devcontainer.json (`current`, its digest, nil
  /// when it has none) isn't what the container was made from (`recorded`): a change applies to new
  /// workrooms only (eng review D7). Nil when they agree, or for a container made before #308.
  static func configNote(recorded: String?, current: String?) -> String? {
    guard let recorded else { return nil }
    let madeFromImage = recorded.hasPrefix("image:")
    switch (madeFromImage, current) {
    case (true, nil): return nil
    case (true, _?):
      return "The repository has a devcontainer.json now. New workrooms are made from it; this "
        + "one stays as it was made."
    case (false, nil):
      return "The repository's devcontainer.json is gone. New workrooms use the default image; "
        + "this one stays as it was made."
    case (false, let current?):
      return current == recorded
        ? nil
        : "The repository's devcontainer.json has changed since this container was made. New "
          + "workrooms are made from the new one; this one stays as it was made."
    }
  }
}
