import Foundation

// Mirrors the `workroom --json` public API (schema_version 1). Decoders are lenient:
// unknown fields are ignored so a newer bundled/standalone CLI won't break the app.

struct Warning: Codable, Hashable {
  let kind: String
  let message: String
  let path: String?
  let vcs: String?
}

/// A host descriptor from `list --json` (#249), which the app writes with `workroom host set`.
/// On a workroom, present means the workroom lives on another host, and its `path` is a path
/// there. On a project, it records the project's base machine (#252), and the project itself is
/// still on this Mac. The app owns the schema (the `HostDriver` is Swift, OQ21); the CLI reads
/// only presence and `state`. Decoded as leniently as the CLI reads it: any non-null value counts
/// as present, and each field that does not decode is nil, so a malformed descriptor still keeps a
/// remote workroom away from every local action instead of failing the whole listing.
struct HostDescriptor: Codable, Hashable {
  var state: String? = nil
  /// Which `HostDriver` made the host: `container` (`ContainerHostDriver`).
  var driver: String? = nil
  /// The bundle ID of the build that made the host, whose key and labels it carries: a Dev and a
  /// Nightly app share config but not keys, so each adopts only its own hosts.
  var provisioner: String? = nil
  /// The host's `HostID.remote` ID.
  var id: UUID? = nil
  /// A workroom's broker grant, which destroying it cancels.
  var grantID: String? = nil
  /// The ID a workroom's grant and its agent's route to the broker are keyed by
  /// (`RemoteProvisioning.derive`). Chosen before the host exists, so not the host's.
  var workroomID: UUID? = nil
  /// A base's repository, as `RemoteProvisioning.Base` records it.
  var repository: String? = nil
  var cloneURL: String? = nil
  var path: String? = nil
  /// How `ContainerHostDriver` finds the host again.
  var container: ContainerHostDriver.Record? = nil

  var isDestroyed: Bool { state == "destroyed" }

  enum CodingKeys: String, CodingKey {
    case state, driver, provisioner, id, repository, path, container
    case grantID = "grant_id"
    case workroomID = "workroom_id"
    case cloneURL = "clone_url"
  }

  init(
    state: String? = nil, driver: String? = nil, provisioner: String? = nil, id: UUID? = nil,
    grantID: String? = nil, workroomID: UUID? = nil, repository: String? = nil,
    cloneURL: String? = nil, path: String? = nil, container: ContainerHostDriver.Record? = nil
  ) {
    self.state = state
    self.driver = driver
    self.provisioner = provisioner
    self.id = id
    self.grantID = grantID
    self.workroomID = workroomID
    self.repository = repository
    self.cloneURL = cloneURL
    self.path = path
    self.container = container
  }

  init(from decoder: Decoder) throws {
    let fields = try? decoder.container(keyedBy: CodingKeys.self)
    state = try? fields?.decodeIfPresent(String.self, forKey: .state)
    driver = try? fields?.decodeIfPresent(String.self, forKey: .driver)
    provisioner = try? fields?.decodeIfPresent(String.self, forKey: .provisioner)
    id = try? fields?.decodeIfPresent(UUID.self, forKey: .id)
    grantID = try? fields?.decodeIfPresent(String.self, forKey: .grantID)
    workroomID = try? fields?.decodeIfPresent(UUID.self, forKey: .workroomID)
    repository = try? fields?.decodeIfPresent(String.self, forKey: .repository)
    cloneURL = try? fields?.decodeIfPresent(String.self, forKey: .cloneURL)
    path = try? fields?.decodeIfPresent(String.self, forKey: .path)
    container = try? fields?.decodeIfPresent(ContainerHostDriver.Record.self, forKey: .container)
  }

  /// A project's base, when the descriptor records a whole one.
  var base: RemoteProvisioning.Base? {
    guard let id, let repository, let cloneURL, let path else { return nil }
    return RemoteProvisioning.Base(host: id, repository: repository, cloneURL: cloneURL, path: path)
  }
}

struct Workroom: Codable, Identifiable, Hashable {
  let name: String
  let path: String
  let vcsName: String
  let warnings: [Warning]
  /// nil for a workroom on this Mac.
  var host: HostDescriptor? = nil
  /// GUI-only display alias (issue #41). NOT part of the `--json` contract — the CLI never sends
  /// it; it's injected post-decode in `AppStore.apply` from `Defaults[.workroomLabels]`. Absent
  /// from `CodingKeys` (with a default) so the synthesised decoder skips it. Intentionally a
  /// stored property, so synthesised `Equatable`/`Hashable` include it: a label change must make
  /// the value compare unequal for SwiftUI to re-render. Identity stays `id == name` (the
  /// immutable workspace name), so routing/selection/terminal-keying are unaffected, and nothing
  /// keys a dict/set on a whole `Workroom`, so the hash change is harmless.
  var label: String? = nil

  var id: String { name }
  var hasBlockingWarning: Bool { warnings.contains { $0.kind == "DirectoryMissing" } }
  var isRemote: Bool { host != nil }

  /// The name to show in the UI: the label when one is set, else the real workspace name. The
  /// single place the label-vs-name choice is made; every display site routes through this.
  var displayName: String { Workroom.normalizedLabel(label) ?? name }

  /// Canonical label normaliser (issue #41): trim surrounding whitespace; treat empty/whitespace-only
  /// as "no label" (nil). The one definition reused by `displayName`, `AppStore.setWorkroomLabel`'s
  /// write boundary, and `WorkroomLabelSheetModel`'s validation — so the "is this blank?" rule can't
  /// drift between them.
  static func normalizedLabel(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  enum CodingKeys: String, CodingKey {
    case name, path, warnings, host
    case vcsName = "vcs_name"
    // `label` is deliberately omitted — it's a GUI-only field, not part of the CLI JSON contract.
  }
}

struct Project: Codable, Identifiable, Hashable {
  let path: String
  let vcs: String
  let workrooms: [Workroom]
  /// The project's base machine (#252), or nil when it has none. The project is still on this Mac.
  var host: HostDescriptor? = nil

  var id: String { path }
  var displayName: String { (path as NSString).lastPathComponent }
}

// MARK: - Project root (sidebar root row)
//
// The root is the project directory itself — always selectable, always the first child in
// the sidebar, never deletable. Its branch label is a GUI-only concern (the
// `workroom` CLI never shows it), so it is resolved app-side by BranchResolver, NOT carried
// in the `list --json` contract.

/// What kind of reference the working copy is on. Drives the root row's label treatment
/// (see RootPresentation). `ref_kind`-style, self-describing — the renderer needs no
/// `project.vcs` cross-reference.
enum RefKind: Hashable {
  case branch  // on a branch
  case detached  // detached HEAD — showing a short SHA
  case none  // no branch resolvable, or not yet resolved
}

/// A project root's resolved label. `branch` is normalized to nil (never "") so an empty
/// result is unambiguously `.none`.
struct RootRef: Hashable {
  let branch: String?
  let kind: RefKind

  static let unresolved = RootRef(branch: nil, kind: .none)
}

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
  /// The host of a remote workroom whose panes this app can reach (#253): set only while remote
  /// workrooms are on (`RemoteWorkrooms.isEnabled`) and its host is recorded and serving. Panes
  /// mount there; every other local action still guards on `isMissing`, which stays true.
  var remoteHost: UUID? = nil
  /// Why a remote workroom's panes don't open here, when that isn't simply this build
  /// (`Workroom.remoteNote`).
  var remoteNote: String? = nil

  var isMissing: Bool { unavailability != nil }

  /// A remote workroom, reachable or not: its path names nothing on this Mac.
  var isRemoteWorkroom: Bool {
    remoteHost != nil || unavailability == .remote || unavailability == .hostDestroyed
  }

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

    var title: String {
      switch self {
      case .directoryMissing: return "Directory not found"
      case .remote: return "Remote workroom"
      case .hostDestroyed: return "Host destroyed"
      }
    }

    var systemImage: String {
      switch self {
      case .directoryMissing: return "questionmark.folder"
      case .remote: return "network"
      case .hostDestroyed: return "xmark.icloud"
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
      }
    }
  }

  // The id format lives ONLY here (and in the two builders below). Anything that needs a
  // target id — terminal/log keying, reaping — goes through these, so the project-scoping
  // that fixes the same-name collision can't drift.
  static func workroomID(project: String, name: String) -> String { "wr|\(project)|\(name)" }
  static func rootID(project: String) -> String { "root|\(project)" }
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
      remoteHost: reachableHost, remoteNote: remoteNote)
  }

  /// Why this remote workroom's panes don't open here, for one this build could otherwise reach:
  /// nil for a serving one, a destroyed one, and a local one.
  var remoteNote: String? {
    guard let host, !host.isDestroyed, reachableHost == nil else { return nil }
    if host.provisioner != RemoteWorkrooms.provisioner {
      return
        "Another Workroom build made it (\(host.provisioner ?? "unknown")), and only that build "
        + "can open it."
    }
    if !RemoteWorkrooms.isEnabled { return "Remote workrooms are turned off in this build." }
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

  /// A host with no `state` is serving: "creating", "failed" and "destroyed" are not. Only this
  /// build's: another build's host takes its key.
  var reachableHost: UUID? {
    guard let host, host.state == nil, host.provisioner == RemoteWorkrooms.provisioner,
      RemoteWorkrooms.isEnabled
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

// MARK: - Envelopes

/// Common envelope header present on every response; used to detect error responses
/// before decoding a command-specific payload.
struct Envelope: Codable {
  let ok: Bool
  let schemaVersion: Int?
  let error: CLIErrorBody?

  enum CodingKeys: String, CodingKey {
    case ok, error
    case schemaVersion = "schema_version"
  }
}

struct CLIErrorBody: Codable {
  let kind: String
  let message: String
}

struct ListResponse: Codable {
  let projects: [Project]
  let workroomsDir: String?
  let configPath: String?

  enum CodingKeys: String, CodingKey {
    case projects
    case workroomsDir = "workrooms_dir"
    case configPath = "config_path"
  }
}

struct CreateResponse: Codable {
  let name: String
  let path: String
  let vcs: String
  let project: String
}

/// `add-project` success payload. `path` is the canonical (symlink-resolved,
/// ~-expanded) project path the CLI registered — the app selects the project by
/// it after a reload. `vcs` is "git".
struct AddProjectResponse: Codable {
  let path: String
  let vcs: String
}

/// `delete-project --from-disk` success payload. The CLI runs teardowns + drops the project
/// from config, then returns the directories (project root first, then workrooms) for the app
/// to move to the Bin — the CLI never deletes them itself (issue #108).
struct DeleteProjectResponse: Codable {
  let trashPaths: [String]?

  enum CodingKeys: String, CodingKey {
    case trashPaths = "trash_paths"
  }
}

/// A streamed event from the CLI's stderr in --json mode (one NDJSON object per line)
/// while the result envelope stays on stdout. `type` discriminates:
///  - "log": a line of setup/teardown output (`text`, `phase`).
///  - "created": the new workroom exists (`name`, `path`) but setup is still running;
///    `setup` reports whether a setup script will run, so the GUI can block on its log.
struct StreamEvent: Decodable {
  let type: String
  let phase: String?
  let text: String?
  let name: String?
  let path: String?
  let setup: Bool?
}
