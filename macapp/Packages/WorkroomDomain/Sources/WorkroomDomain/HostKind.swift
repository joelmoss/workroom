import Foundation

/// Which container runtime on this Mac makes a container workroom's host (#309): Docker (Desktop,
/// OrbStack, Colima) or Apple's `container`. The raw value is the host descriptor's `driver`, a
/// stored contract: `container` predates Apple's runtime and keeps meaning Docker, so every record
/// made before stays Docker's.
public enum ContainerRuntime: String, CaseIterable, Hashable, Sendable {
  case docker = "container"
  case apple = "apple-container"

  public var displayName: String { self == .docker ? "Docker" : "Apple Container" }
  /// One of its containers, in a sentence: "a Docker container", "an Apple container".
  public var containerPhrase: String {
    self == .docker ? "a Docker container" : "an Apple container"
  }
}

/// The kind of host a remote workroom lives on (ADR 0066): a container runtime on this Mac, a
/// remote provider (boxd, exe.dev), or an SSH host. The one list of kinds: a create's place, a
/// recorded host's driver, the host options a kind takes and its scripts' `WORKROOM_HOST` all read
/// it. Which account, context or destination a driver acts for is not a kind's; that is the app's
/// driver key.
public enum HostKind: Hashable, Sendable {
  case container(ContainerRuntime)
  case boxd
  case exeDev
  /// A Railway sandbox (ADR 0071, #629).
  case railway
  case ssh

  /// The remote providers, in the order the New Workroom menu and picker list them (#259).
  public static let remoteProviders: [HostKind] = [.boxd, .exeDev, .railway, .ssh]

  /// The remote providers that take host options, in Settings' order (#575).
  public static let optionedProviders = remoteProviders.filter(\.takesHostOptions)

  /// Every kind: the container runtimes, then the remote providers.
  public static let all = ContainerRuntime.allCases.map(HostKind.container) + remoteProviders

  /// The kind a host descriptor's `driver` names, or nil for one this build doesn't know.
  public init?(driver: String) {
    guard let kind = Self.all.first(where: { $0.driver == driver }) else { return nil }
    self = kind
  }

  /// The host descriptor's `driver` for this kind, a stored contract in config.json.
  public var driver: String {
    switch self {
    case .container(let runtime): runtime.rawValue
    case .boxd: "boxd"
    case .exeDev: "exedev"
    case .railway: "railway"
    case .ssh: "ssh"
    }
  }

  /// Whether this is a remote provider's host rather than a container on this Mac. Its git takes
  /// credentials from the provider or the host's user, never the Mac's relay; it is reached by
  /// name, with nothing to adopt; and it runs whether or not this Mac has a container runtime
  /// (#259).
  public var isRemoteProvider: Bool {
    if case .container = self { return false }
    return true
  }

  public var displayName: String {
    switch self {
    case .container(let runtime): runtime.displayName
    case .boxd: "boxd"
    case .exeDev: "exe.dev"
    case .railway: "Railway"
    case .ssh: "SSH"
    }
  }

  /// Its SF Symbol, wherever a workroom or a choice of place is shown: a container on this Mac
  /// is on the local network, a remote provider's machine is in the cloud.
  public var icon: String { isRemoteProvider ? "cloud" : "network" }

  /// One of its hosts, in a sentence: "a Docker container on this Mac", "a boxd machine".
  public var hostPhrase: String {
    switch self {
    case .container(let runtime): "\(runtime.containerPhrase) on this Mac"
    case .boxd: "a boxd machine"
    case .exeDev: "an exe.dev VM"
    case .railway: "a Railway sandbox"
    case .ssh: "an SSH host"
    }
  }

  /// How the user gives this kind's hosts GitHub access, said after git's own words when a clone
  /// fails, or nil where Workroom gives it (a container takes the Mac's `gh` through the relay,
  /// #309). A remote provider's host fetches and pushes with the provider's own credentials, so
  /// it keeps working with this Mac closed. Worded for the one cause Workroom can't tell apart
  /// from git's message: the clone fails the same way for a network or GitHub outage.
  public var credentialHint: String? {
    switch self {
    case .container: nil
    case .railway:
      "If GitHub refused the clone: a Railway sandbox has no GitHub credentials of its own, so "
        + "Workroom can clone only a public repository there for now."
    case .ssh:
      "If GitHub refused the clone, set up credentials on the host: a GitHub SSH key for an "
        + "SSH URL, or `gh auth login` and `gh auth setup-git` for HTTPS."
    case .boxd:
      "If GitHub refused the clone: a boxd machine reaches GitHub through your boxd git "
        + "integration. Connect it with `boxd manage integrations connect git`."
    case .exeDev:
      "If GitHub refused the clone: an exe.dev VM reaches a GitHub repository through an exe.dev "
        + "integration for it, which Workroom adds. Check that GitHub is still connected at "
        + "https://exe.dev/integrations#github, and that `ssh exe.dev integrations list` shows the "
        + "repository attached to auto:all."
    }
  }

  /// The host's own page on its provider's dashboard, or nil for a kind that has none. Read from
  /// the providers' web apps (2026-10-20): boxd's machines list selects `?m=<name>`, and exe.dev
  /// serves `/vm/<name>` behind its sign-in.
  public func dashboardURL(machine: String) -> URL? {
    switch self {
    case .container, .ssh, .railway: return nil
    case .boxd:
      var url = URLComponents(string: "https://app.boxd.sh/machines")!
      url.queryItems = [URLQueryItem(name: "m", value: machine)]
      return url.url
    case .exeDev: return URL(string: "https://exe.dev/vm/")?.appendingPathComponent(machine)
    }
  }

  /// `WORKROOM_HOST` for a script on this kind's host (`docs/designs/scripts-on-every-workroom.md`):
  /// the runtime's or provider's plain name, not the descriptor's `driver`.
  public var workroomHost: String {
    switch self {
    case .container(.docker): "docker"
    case .container(.apple): "apple"
    case .boxd: "boxd"
    case .exeDev: "exedev"
    case .railway: "railway"
    case .ssh: "ssh"
    }
  }

  /// Whether a create of this kind takes host options (#575): boxd's and exe.dev's. A container's
  /// image and size are devcontainer.json's (ADR 0060), and an SSH host is the user's own.
  public var takesHostOptions: Bool { hostOptionsKey != nil }

  /// The key this kind's host options are saved under in this Mac's settings (ADR 0065), or nil
  /// for a kind that takes none. A stored contract: exe.dev's is `exeDev`, not its `driver`.
  public var hostOptionsKey: String? {
    switch self {
    case .boxd: "boxd"
    case .exeDev: "exeDev"
    case .container, .ssh, .railway: nil
    }
  }

  /// What this kind starts a host from when a level names a host image, or nil for a kind that
  /// takes no host options.
  public var hostImageKind: HostImageKind? {
    switch self {
    case .boxd: .snapshot
    case .exeDev: .containerImage
    case .container, .ssh, .railway: nil
    }
  }
}

/// Where a recorded host is in its life (ADR 0066): the typed view of a host descriptor's `state`.
/// No state is serving; anything this build doesn't know is kept as it was, and isn't serving.
public enum HostLifecycle: Hashable, Sendable {
  case serving
  /// A create reserved it and hasn't finished, or was interrupted.
  case creating
  /// A create or delete couldn't undo all it made; deleting it again finishes the job.
  case failed
  /// Taken down: the CLI deletes a workroom whose host is `destroyed` (ADR 0040).
  case destroyed
  case unknown(String)

  private static let known: [HostLifecycle] = [.serving, .creating, .failed, .destroyed]

  public init(state: String?) {
    // `.serving`'s state is nil, so only a string this build doesn't know reaches the fallback.
    self = Self.known.first { $0.state == state } ?? .unknown(state ?? "")
  }

  /// The descriptor's `state` for this lifecycle: nil while serving.
  public var state: String? {
    switch self {
    case .serving: nil
    case .creating: "creating"
    case .failed: "failed"
    case .destroyed: "destroyed"
    case .unknown(let state): state
    }
  }
}
