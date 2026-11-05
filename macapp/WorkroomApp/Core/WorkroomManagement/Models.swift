import Foundation
import HostDrivers
import WorkroomDomain

// Mirrors the `workroom --json` public API (schema_version 1). Decoders are lenient:
// unknown fields are ignored so a newer bundled/standalone CLI won't break the app.

// MARK: - Project root (sidebar root row)
//
// The root is the project directory itself — always selectable, always the first child in
// the sidebar, never deletable. Its branch label is a GUI-only concern (the
// `workroom` CLI never shows it), so it is resolved app-side by BranchResolver, NOT carried
// in the `list --json` contract.

/// A place a terminal can be opened: a workroom or a project root. The id is
/// project-scoped, so same-named workrooms in different projects (and roots) never share a
/// terminal or setup log.
struct TerminalTarget: Identifiable, Hashable {
  let id: String
  let title: String
  let path: String
  /// Why this target cannot be opened on this Mac, or nil when it can. Every local action (terminal,
  /// editor, run command, status) guards on `isMissing`; only the rendering sites tell the reasons
  /// apart.
  let unavailability: Unavailability?
  /// The host of a remote workroom whose panes this app can reach (#253): set only while its host
  /// is recorded and serving. Panes
  /// mount there; every other local action still guards on `isMissing`, which stays true.
  var remoteHost: UUID? = nil
  /// Why a remote workroom's panes don't open here (`Workroom.remoteNote`).
  var remoteNote: String? = nil
  /// What kind of host a remote workroom is on (`HostDescriptor.kindDescription`), for its icon's
  /// tooltip (#309).
  var hostKind: String? = nil
  /// The name its host's provider lists it under (`HostDescriptor.machineName`).
  var machineName: String? = nil
  /// Where a remote workroom's host is, for its icon: nil for a workroom on this Mac, and for one
  /// whose record names no driver this build knows.
  var hostPlace: RemoteWorkrooms.Place? = nil
  /// A remote workroom's own id (`HostDescriptor.workroomID`): the same on every Mac, where `id`
  /// holds this Mac's project path (#255).
  var remoteWorkroomID: UUID? = nil

  var isMissing: Bool { unavailability != nil }

  /// The tooltip of a remote workroom's icon: what kind of host it is, and the machine to look for
  /// in its provider's dashboard.
  var hostTooltip: String {
    [hostKind, machineName.map { "Machine: \($0)" }].compactMap { $0 }.joined(separator: "\n")
  }

  /// The glyph that marks a workroom: its place's for one on a host (#309), the network for a
  /// remote one whose place is unknown, and a cube for one on this Mac itself. A root takes a house
  /// instead.
  var workroomGlyph: String {
    hostPlace?.icon ?? (isRemoteWorkroom ? "network" : "cube")
  }

  /// A remote workroom, reachable or not: its path names nothing on this Mac.
  var isRemoteWorkroom: Bool {
    remoteHost != nil || unavailability == .remote || unavailability == .hostDestroyed
  }

  /// What a session in this target is tagged with (`SessionMetadataKey.workroom`), and what the
  /// app matches a session's tag against: the workroom's own id for a remote workroom that has
  /// one, `id` otherwise (#255).
  var sessionWorkroomKey: String { remoteWorkroomID?.uuidString ?? id }

  /// Why no pane can mount here, or nil when one can: `unavailability`, except for a remote
  /// workroom whose host this app reaches.
  var terminalUnavailability: Unavailability? { remoteHost == nil ? unavailability : nil }
  var opensTerminals: Bool { terminalUnavailability == nil }

  /// The location on its host of a remote workroom this app reaches, else nil. Never resolved from
  /// the path alone, which can't name a host: one project's remote workrooms share a path on
  /// different hosts (#253). A local target resolves its path itself.
  var remoteLocation: RepositoryLocation? {
    remoteHost.flatMap { try? RepositoryLocation.remote(host: $0, path: path) }
  }

  enum Unavailability: Hashable {
    /// A local directory that no longer exists.
    case directoryMissing
    /// A workroom on another host. Its path is not a path on this Mac. Whether its panes open there
    /// is `TerminalTarget.remoteHost` (#253).
    case remote
    /// A remote workroom whose host its provider destroyed. Not a missing directory.
    case hostDestroyed
    /// A workroom still being created (#483): its creation pane stands in for it.
    case creating

    var title: String {
      switch self {
      case .directoryMissing: return "Directory not found"
      case .remote: return "Remote workroom"
      case .hostDestroyed: return "Host destroyed"
      case .creating: return "Creating workroom"
      }
    }

    var systemImage: String {
      switch self {
      case .directoryMissing: return "questionmark.folder"
      case .remote: return "network"
      case .hostDestroyed: return "xmark.icloud"
      case .creating: return "hammer"
      }
    }

    func detail(for target: TerminalTarget) -> String {
      switch self {
      case .directoryMissing:
        return "\(target.title) points at a path that no longer exists.\n\(target.path)"
      case .remote:
        if let note = target.remoteNote {
          return "\(target.title) is a remote workroom. \(note)\n\(target.path)"
        }
        return "\(target.title) is on another host, and this build cannot open it.\n\(target.path)"
      case .hostDestroyed:
        return "\(target.title)'s host was destroyed by its provider.\n\(target.path)"
      case .creating:
        return "A workroom of \(target.title) is still being created."
      }
    }
  }

  // The id format lives ONLY here (and in the two builders below). Anything that needs a
  // target id — terminal/log keying, reaping — goes through these, so the project-scoping
  // that fixes the same-name collision can't drift.
  static func workroomID(project: String, name: String) -> String { "wr|\(project)|\(name)" }
  static func rootID(project: String) -> String { "root|\(project)" }
  /// A create's pane before its workroom has a name (#483).
  static func creationID(_ id: UUID) -> String { "creation:\(id.uuidString)" }
}

extension TerminalTarget {
  /// A local target: missing means its directory is gone.
  init(id: String, title: String, path: String, isMissing: Bool) {
    self.init(
      id: id, title: title, path: path, unavailability: isMissing ? .directoryMissing : nil)
  }
}

extension Workroom {
  /// The terminal target for this workroom within `projectPath`. `title` is the `displayName`
  /// (label when set, else name), so every consumer that reads `target.title` off a resolved target
  /// — missing-directory messages, split accessibility — shows the label automatically (issue #41).
  /// The id stays keyed on the immutable `name`.
  func target(inProject projectPath: String) -> TerminalTarget {
    TerminalTarget(
      id: TerminalTarget.workroomID(project: projectPath, name: name),
      title: displayName, path: path, unavailability: unavailability,
      remoteHost: reachableHost, remoteNote: remoteNote, hostKind: host?.kindDescription,
      machineName: host?.machineName, hostPlace: host.flatMap(RemoteHosts.DriverKey.init)?.place,
      remoteWorkroomID: host?.workroomID)
  }

  /// Why this remote workroom's panes don't open here: nil for a serving one, a destroyed one, and a
  /// local one.
  var remoteNote: String? {
    guard let host, !host.isDestroyed, reachableHost == nil else { return nil }
    if !RemoteWorkrooms.ownsHost(host) {
      return
        "Another Workroom build made it (\(host.provisioner ?? "unknown")), and only that build "
        + "can open it."
    }
    switch host.state {
    case "creating":
      return "It isn't ready: it is being created, or creating it was interrupted. If nothing is "
        + "creating it, delete it."
    case "failed":
      return "Creating it failed, and part of it may still be running. Delete it to finish."
    default:
      // Serving, but naming no host to open.
      return "Its record names no host to open. Delete it."
    }
  }

  /// Whether its host is a Docker or Apple container on this Mac, not a remote provider's machine.
  var isContainer: Bool { host.flatMap(RemoteHosts.DriverKey.init)?.runtime != nil }
  var isSSH: Bool { host?.driver == RemoteWorkrooms.sshDriver }

  /// A host with no `state` is serving: "creating", "failed" and "destroyed" are not. Only one this
  /// build owns (`RemoteWorkrooms.ownsHost`): another build's container takes its key.
  var reachableHost: UUID? {
    guard let host, host.state == nil, RemoteWorkrooms.ownsHost(host),
      host.driver != RemoteWorkrooms.sshDriver || RemoteHosts.DriverKey(host) != nil
    else { return nil }
    return host.id
  }

  private var unavailability: TerminalTarget.Unavailability? {
    if let host { return host.isDestroyed ? .hostDestroyed : .remote }
    return hasBlockingWarning ? .directoryMissing : nil
  }
}

extension Project {
  /// The always-present project-root target. The project directory can disappear like a
  /// workroom directory, so `isMissing` is checked against the filesystem.
  var rootTarget: TerminalTarget {
    TerminalTarget(
      id: TerminalTarget.rootID(project: path), title: displayName, path: path,
      isMissing: !FileManager.default.fileExists(atPath: path))
  }
}

/// Pure mapping from a resolved `RootRef` to the root row's visual treatment. Extracted
/// from the view so it is unit-testable. `dim` means "unusual" (detached / no branch).
enum RootPresentation {
  struct Style: Equatable {
    let label: String
    let tooltip: String
    let accessibility: String
    let dim: Bool  // de-emphasize (detached / none)
  }

  static func make(_ ref: RootRef) -> Style {
    switch ref.kind {
    case .branch:
      let name = normalized(ref.branch) ?? "root"
      return Style(
        label: name, tooltip: "Project root · on \(name)",
        accessibility: "Project root, on \(name)", dim: false)
    case .detached:
      let name = normalized(ref.branch) ?? "detached"
      return Style(
        label: name, tooltip: "Project root · detached HEAD",
        accessibility: "Project root, detached at \(name)", dim: true)
    case .none:
      return Style(
        label: "root", tooltip: "Project root",
        accessibility: "Project root", dim: true)
    }
  }

  /// Treats "" / whitespace like nil (the Go side may emit "" rather than null).
  private static func normalized(_ s: String?) -> String? {
    guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return s
  }
}

extension HostDescriptor {
  /// What kind of host this is, for the workroom's icon in the sidebar (#309): a container on this
  /// Mac, on Docker (naming its context when it has one) or Apple's runtime, or a remote provider by
  /// its driver's name.
  var kindDescription: String {
    if driver == RemoteWorkrooms.sshDriver {
      return "SSH host · \(sshDestination ?? "unknown host")"
    }
    switch driver.flatMap(RemoteWorkrooms.Runtime.init(rawValue:)) {
    case .docker:
      let context = container?.context.map { " (\($0))" } ?? ""
      return "Docker container\(context) on this Mac"
    case .apple:
      return "Apple container on this Mac"
    case nil:
      let provider = RemoteHosts.DriverKey(self)?.place.displayName ?? driver
      return provider.map { "Remote workroom on \($0)" } ?? "Remote workroom"
    }
  }

  /// The name the host's provider lists it under, so it can be found in boxd's or exe.dev's
  /// dashboard, or in `docker ps`: every driver names a host `workroom-<id>`.
  var machineName: String? {
    driver == RemoteWorkrooms.sshDriver
      ? sshDestination
      : (isDestroyed ? nil : id.map(ContainerHostDriver.containerName))
  }
}
