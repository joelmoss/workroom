import Foundation
import WorkroomVCS

/// A repository's dev container, as its `devcontainer.json` describes it (the Development
/// Containers spec, containers.dev): what a container workroom is made from (#308), and the ports
/// it forwards to this Mac (`PortForwardingModel.forwardDeclared`). The file VS Code, Codespaces and
/// DevPod already read, so a repository that has one needs nothing new.
///
/// Parsing is strict about each value's type and lenient about what is missing: a file with neither
/// `image` nor `build`, or a Compose file, still parses, and says so (`source`, `usesCompose`), for
/// the create to refuse with a reason rather than a JSON error.
///
/// Ports: each number in `forwardPorts` is forwarded; a `"host:port"` string names a port on another
/// host (a Compose service), which the daemon can't reach, so it is skipped. `portsAttributes`, keyed
/// by a single port, gives its `label` and `requireLocalPort` (refuse rather than move the forward
/// when this Mac holds the number). Ranges and patterns in `portsAttributes` are not read.
struct DevContainerConfig: Equatable, Sendable {
  /// What the container's image comes from.
  enum Source: Equatable, Sendable {
    /// An image reference to pull.
    case image(String)
    /// A Dockerfile to build.
    case build(Build)
  }

  /// `build`, or the legacy top-level `dockerFile` and `context`. Paths are as written, relative to
  /// the file's own folder, for the caller to resolve.
  struct Build: Equatable, Sendable {
    var dockerfile: String
    /// The spec's default is the file's own folder.
    var context: String = "."
    var args: [String: String] = [:]
    var target: String? = nil
    /// Extra build flags, passed to the runtime's build as written.
    var options: [String] = []
  }

  struct Port: Equatable, Sendable {
    let port: UInt16
    var label: String? = nil
    var requireLocalPort = false
  }

  /// One of `mounts`, in either of the spec's forms. Values may hold variables
  /// (`${localEnv:HOME}`), substituted by the caller.
  struct Mount: Equatable, Sendable {
    /// `bind`, `volume` or `tmpfs`; Docker's `--mount` defaults to a volume.
    var type: String = "volume"
    /// Nil for an anonymous volume or a tmpfs.
    var source: String? = nil
    var target: String
    var readOnly = false
  }

  /// A lifecycle command's key.
  enum Hook: String, CaseIterable, Sendable {
    /// Runs on the Mac, before the image is built.
    case initialize = "initializeCommand"
    case onCreate = "onCreateCommand"
    case updateContent = "updateContentCommand"
    case postCreate = "postCreateCommand"
    case postStart = "postStartCommand"
    /// Not run: a pane attaching is not a session starting (eng review D5).
    case postAttach = "postAttachCommand"

    /// The container's own commands after the clone, in the spec's order (eng review D5, D12).
    static let inContainer: [Hook] = [.onCreate, .updateContent, .postCreate, .postStart]
  }

  /// A lifecycle command, in the spec's three forms.
  indirect enum Command: Equatable, Sendable {
    /// A string, run in /bin/sh.
    case shell(String)
    /// An array, run without a shell.
    case exec([String])
    /// An object: each entry runs in parallel, and each must succeed.
    case parallel([Named])

    /// This command with `variables` substituted in its strings, as in the file's other values:
    /// `cd ${containerWorkspaceFolder}` names the checkout, not an empty shell variable.
    func substituting(_ variables: Variables) -> Command {
      switch self {
      case .shell(let text): .shell(variables.substitute(text))
      case .exec(let argv): .exec(argv.map(variables.substitute))
      case .parallel(let entries):
        .parallel(entries.map { Named(name: $0.name, command: $0.command.substituting(variables)) })
      }
    }
  }

  struct Named: Equatable, Sendable {
    let name: String
    /// A shell or an exec command; never another parallel set.
    let command: Command
  }

  /// A feature option's value: the spec allows strings and booleans.
  enum OptionValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
  }

  /// Nil when the file names neither an image nor a Dockerfile.
  var source: Source?
  var lifecycle: [Hook: Command] = [:]
  /// Each feature's id (an OCI reference with its tag, a tarball URL, or a path relative to the
  /// file), and its options as written.
  var features: [String: [String: OptionValue]] = [:]
  /// Feature ids, without a version, to install first, in this order.
  var overrideFeatureInstallOrder: [String] = []
  /// The file describes Compose services (`dockerComposeFile`), not one container.
  var usesCompose = false
  /// The ports to forward, in the file's order, each once.
  var ports: [Port] = []
  /// Set on the container, so every process in it has them.
  var containerEnv: [String: String] = [:]
  /// Added to what tools, terminals and commands run with. A nil value unsets the variable.
  var remoteEnv: [String: String?] = [:]
  var containerUser: String?
  var remoteUser: String?
  /// Where the workroom's checkout goes in the container.
  var workspaceFolder: String?
  var mounts: [Mount] = []
  /// Container runtime flags, as written (Docker's CLI spelling).
  var runArgs: [String] = []
  var privileged = false
  var capAdd: [String] = []
  var securityOpt: [String] = []
  /// Keys the file holds that Workroom can't honour on any runtime, with why.
  private(set) var unhonoured: [IgnoredKey] = []

  /// A key a workroom leaves out, and why, for the creation pane's warning row (eng review D10).
  struct IgnoredKey: Equatable, Sendable {
    let key: String
    let reason: String
  }

  /// Every key the file holds that a workroom on `runtime` leaves out, by key.
  func ignoredKeys(on runtime: RemoteWorkrooms.Runtime) -> [IgnoredKey] {
    var keys = unhonoured
    if runtime == .apple {
      let reason = "a Docker setting, which Apple's container runtime doesn't take"
      if !runArgs.isEmpty { keys.append(IgnoredKey(key: "runArgs", reason: reason)) }
      if privileged { keys.append(IgnoredKey(key: "privileged", reason: reason)) }
      if !securityOpt.isEmpty { keys.append(IgnoredKey(key: "securityOpt", reason: reason)) }
    }
    return keys.sorted { $0.key < $1.key }
  }

  /// Keys Workroom reads, or satisfies anyway, or that only an editor reads: none is reported.
  private static let quietKeys: Set<String> = [
    "$schema", "name", "image", "build", "dockerFile", "context", "dockerComposeFile", "service",
    "runServices", "forwardPorts", "portsAttributes", "otherPortsAttributes", "containerEnv",
    "remoteEnv", "containerUser", "remoteUser", "workspaceFolder", "mounts", "runArgs",
    "privileged", "capAdd", "securityOpt", "features", "overrideFeatureInstallOrder",
    "customizations", "init", "waitFor", "userEnvProbe", "updateRemoteUserUID", "shutdownAction",
    "overrideCommand", "initializeCommand", "onCreateCommand", "updateContentCommand",
    "postCreateCommand", "postStartCommand",
  ]

  /// Keys the spec has that a workroom can't honour, with why.
  private static let unhonouredKeys: [String: String] = [
    "workspaceMount": "Workroom clones each workroom into workspaceFolder instead",
    "appPort": "Workroom forwards ports over its own connection; use forwardPorts",
    "hostRequirements": "Workroom doesn't check this Mac's CPUs, memory or GPU",
    "postAttachCommand":
      "Workroom runs postStartCommand when the container starts, not on each attach",
  ]

  /// What the spec's `${…}` variables stand for in one workroom, for the caller to apply to the
  /// values the spec allows them in (mounts, the environments, build args, run flags, commands).
  struct Variables: Equatable, Sendable {
    /// This Mac's environment.
    var localEnv: [String: String]
    /// The container's, once it runs: only `remoteEnv` may refer to it.
    var containerEnv: [String: String] = [:]
    /// The project's folder on this Mac.
    var localWorkspaceFolder: String
    var containerWorkspaceFolder: String
    var devcontainerId: String

    /// `text` with every variable this knows replaced. `${localEnv:NAME}` (and VS Code's older
    /// `${env:NAME}`) and `${containerEnv:NAME}` take a default after a second colon, used when
    /// the variable is unset; unset without one is blank. Anything else, `${…}` this doesn't know
    /// or an unclosed one, is left as written.
    func substitute(_ text: String) -> String {
      var out = ""
      var rest = text[...]
      while let open = rest.range(of: "${") {
        out += rest[..<open.lowerBound]
        guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
          out += rest[open.lowerBound...]
          return out
        }
        let name = String(rest[open.upperBound..<close])
        out += value(of: name) ?? "${\(name)}"
        rest = rest[rest.index(after: close)...]
      }
      return out + rest
    }

    private func value(of name: String) -> String? {
      let parts = name.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        .map(String.init)
      if parts.count >= 2 {
        let environment: [String: String]
        switch parts[0] {
        case "localEnv", "env": environment = localEnv
        case "containerEnv": environment = containerEnv
        default: return nil
        }
        return environment[parts[1]] ?? (parts.count == 3 ? parts[2] : "")
      }
      switch name {
      case "localWorkspaceFolder": return localWorkspaceFolder
      case "localWorkspaceFolderBasename":
        return URL(fileURLWithPath: localWorkspaceFolder).lastPathComponent
      case "containerWorkspaceFolder": return containerWorkspaceFolder
      case "containerWorkspaceFolderBasename":
        return URL(fileURLWithPath: containerWorkspaceFolder).lastPathComponent
      case "devcontainerId": return devcontainerId
      default: return nil
      }
    }
  }

  /// Where the spec looks for the file, in its order. Its third place, one folder per
  /// configuration under `.devcontainer/`, needs a choice of configuration and is not read.
  static let paths = [".devcontainer/devcontainer.json", ".devcontainer.json"]

  /// Far past any real file, which is a page of JSON.
  static let maxBytes = 256 * 1024

  /// The most ports one file has forwarded (`PortForwardingModel.forwardDeclared`). A real dev
  /// container declares a handful; each forward holds a listening descriptor for the launch.
  static let maxForwards = 32

  /// The first of `paths` that `files` has, and its bytes, or nil when it has none.
  static func read(_ files: FileProviding) async throws -> (path: String, data: Data)? {
    for path in paths {
      do {
        return (
          path, try await files.read(path: path, symlinks: .followWithinRoot, maxBytes: maxBytes)
        )
      } catch FileServiceError.notFound {
        continue
      }
    }
    return nil
  }

  /// The file's dev container. The file is JSON with comments and trailing commas allowed, as the
  /// spec has it.
  static func parse(_ data: Data) throws -> DevContainerConfig {
    let decoder = JSONDecoder()
    decoder.allowsJSON5 = true
    let file = try decoder.decode(File.self, from: data)
    var config = DevContainerConfig()
    if let image = file.image {
      config.source = .image(image)
    } else if let build = file.build {
      config.source = .build(
        Build(
          dockerfile: build.dockerfile, context: build.context ?? ".", args: build.args ?? [:],
          target: build.target, options: build.options ?? []))
    } else if let dockerfile = file.dockerFile {
      config.source = .build(Build(dockerfile: dockerfile, context: file.context ?? "."))
    }
    config.usesCompose = file.dockerComposeFile != nil
    config.containerEnv = file.containerEnv ?? [:]
    config.remoteEnv = file.remoteEnv ?? [:]
    config.containerUser = file.containerUser
    config.remoteUser = file.remoteUser
    config.workspaceFolder = file.workspaceFolder
    config.mounts = try (file.mounts ?? []).map { try $0.mount() }
    config.runArgs = file.runArgs ?? []
    config.privileged = file.privileged ?? false
    config.capAdd = file.capAdd ?? []
    config.securityOpt = file.securityOpt ?? []
    let commands = try decoder.decode([String: CommandEntry].self, from: data)
    for hook in Hook.allCases {
      if let entry = commands[hook.rawValue] { config.lifecycle[hook] = entry.command }
    }
    config.features = (file.features ?? [:]).mapValues(\.options)
    config.overrideFeatureInstallOrder = file.overrideFeatureInstallOrder ?? []
    for key in commands.keys {
      if let reason = unhonouredKeys[key] {
        config.unhonoured.append(IgnoredKey(key: key, reason: reason))
      } else if !quietKeys.contains(key) {
        config.unhonoured.append(
          IgnoredKey(key: key, reason: "not a devcontainer.json key Workroom knows"))
      }
    }
    if file.overrideCommand == false {
      config.unhonoured.append(
        IgnoredKey(
          key: "overrideCommand",
          reason: "the container runs Workroom's daemon in place of the image's own command"))
    }
    for case .other(let entry?) in file.forwardPorts ?? [] {
      config.unhonoured.append(
        IgnoredKey(
          key: "forwardPorts \"\(entry)\"",
          reason: "a port on another Compose service, which the container can't reach"))
    }
    var seen: Set<UInt16> = []
    config.ports = (file.forwardPorts ?? []).compactMap { entry in
      guard case .port(let port) = entry, seen.insert(port).inserted else { return nil }
      let attributes = file.portsAttributes?[String(port)]
      return Port(
        port: port, label: attributes?.label,
        requireLocalPort: attributes?.requireLocalPort ?? false)
    }
    return config
  }

  private struct File: Decodable {
    var image: String?
    var build: BuildObject?
    var dockerFile: String?
    var context: String?
    var dockerComposeFile: StringOrArray?
    var forwardPorts: [PortEntry]?
    var portsAttributes: [String: Attributes]?
    var containerEnv: [String: String]?
    var remoteEnv: [String: String?]?
    var containerUser: String?
    var remoteUser: String?
    var workspaceFolder: String?
    var mounts: [MountEntry]?
    var runArgs: [String]?
    var privileged: Bool?
    var capAdd: [String]?
    var securityOpt: [String]?
    var features: [String: FeatureEntry]?
    var overrideFeatureInstallOrder: [String]?
    var overrideCommand: Bool?
  }

  /// A feature's value: its options object, or the shorthand string for its `version` option.
  private struct FeatureEntry: Decodable {
    let options: [String: OptionValue]

    init(from decoder: Decoder) throws {
      let value = try decoder.singleValueContainer()
      if let version = try? value.decode(String.self) {
        options = ["version": .string(version)]
      } else {
        options = try value.decode([String: OptionEntry].self).mapValues(\.value)
      }
    }
  }

  private struct OptionEntry: Decodable {
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

  /// Any top-level value: decoded as a lifecycle command only under a hook's key. Every other key
  /// is skipped here and read by `File`.
  private struct CommandEntry: Decodable {
    let command: Command?

    init(from decoder: Decoder) throws {
      let key = decoder.codingPath.last?.stringValue ?? ""
      guard Hook(rawValue: key) != nil else {
        command = nil
        return
      }
      let value = try decoder.singleValueContainer()
      if let parallel = try? value.decode([String: Single].self) {
        command = .parallel(
          parallel.sorted { $0.key < $1.key }.map { Named(name: $0.key, command: $0.value.command) }
        )
      } else {
        command = try value.decode(Single.self).command
      }
    }
  }

  /// A string or an array: one command.
  private struct Single: Decodable {
    let command: Command

    init(from decoder: Decoder) throws {
      let value = try decoder.singleValueContainer()
      if let line = try? value.decode(String.self) {
        command = .shell(line)
      } else {
        command = .exec(try value.decode([String].self))
      }
    }
  }

  /// A mount as the file writes it: Docker's `--mount` string, or an object.
  private enum MountEntry: Decodable {
    case string(String)
    case object(MountObject)

    struct MountObject: Decodable {
      var type: String?
      var source: String?
      var target: String
      var readonly: Bool?
    }

    init(from decoder: Decoder) throws {
      let value = try decoder.singleValueContainer()
      if let string = try? value.decode(String.self) {
        self = .string(string)
      } else {
        self = .object(try value.decode(MountObject.self))
      }
    }

    func mount() throws -> Mount {
      switch self {
      case .object(let object):
        return Mount(
          type: object.type ?? "volume", source: object.source, target: object.target,
          readOnly: object.readonly ?? false)
      case .string(let string):
        var mount = Mount(target: "")
        for field in string.split(separator: ",", omittingEmptySubsequences: true) {
          let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
          let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
          let value = parts.count > 1 ? parts[1] : nil
          switch key {
          case "type": mount.type = value ?? mount.type
          case "source", "src": mount.source = value
          case "target", "destination", "dst": mount.target = value ?? ""
          case "readonly", "ro": mount.readOnly = value.map { $0 != "false" && $0 != "0" } ?? true
          default: break  // `consistency` and other Docker Desktop hints
          }
        }
        guard !mount.target.isEmpty else {
          throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "the mount \"\(string)\" names no target"))
        }
        return mount
      }
    }
  }

  private struct BuildObject: Decodable {
    var dockerfile: String
    var context: String?
    var args: [String: String]?
    var target: String?
    var options: [String]?
  }

  /// A value the spec allows as a string or an array of strings.
  private enum StringOrArray: Decodable {
    case one(String)
    case many([String])

    init(from decoder: Decoder) throws {
      let value = try decoder.singleValueContainer()
      if let one = try? value.decode(String.self) {
        self = .one(one)
      } else {
        self = .many(try value.decode([String].self))
      }
    }
  }

  private struct Attributes: Decodable {
    var label: String?
    var requireLocalPort: Bool?
  }

  private enum PortEntry: Decodable {
    case port(UInt16)
    /// Not a port number: a `"host:port"` string (kept, to report), or a value no port can be.
    case other(String?)

    init(from decoder: Decoder) throws {
      let value = try decoder.singleValueContainer()
      if let port = try? value.decode(UInt16.self), port > 0 {
        self = .port(port)
      } else {
        self = .other(try? value.decode(String.self))
      }
    }
  }
}
