import Foundation

// The `workroom --json` public API's model (schema_version 1), which the app decodes and the
// packages share. Decoders are lenient: unknown fields are ignored so a newer bundled or
// standalone CLI won't break the app. What only the app can say about these types (a host's kind
// and machine name, a workroom's terminal target and remote note) is in the app's extensions.

public struct Warning: Codable, Hashable, Sendable {
  public let kind: String
  public let message: String
  public let path: String?
  public let vcs: String?

  public init(kind: String, message: String, path: String?, vcs: String?) {
    self.kind = kind
    self.message = message
    self.path = path
    self.vcs = vcs
  }

}

/// What a host this driver made needs to be reached and destroyed again by a driver in a later
/// launch (#253): the `container` part of its host descriptor. The client key and the agent's
/// socket are the driver's own (`Provisioning`), and the container's name follows from the
/// host's ID.
public struct ContainerHostRecord: Codable, Hashable, Sendable {
  public let address: String
  public let port: Int
  public let user: String
  public let hostKey: String
  /// The image a workroom an older build derived from a base was run from, which only it uses;
  /// nil for any other host.
  public let image: String?
  /// The Docker context it runs in (`Provisioning.context`). nil, as every record made before
  /// #309 has it, follows the environment and the CLI's current context, as those always did.
  public var context: String? = nil

  public init(
    address: String, port: Int, user: String, hostKey: String, image: String?,
    context: String? = nil
  ) {
    self.address = address
    self.port = port
    self.user = user
    self.hostKey = hostKey
    self.image = image
    self.context = context
  }

  enum CodingKeys: String, CodingKey {
    case address, port, user, image, context
    case hostKey = "host_key"
  }
}

/// A host descriptor from `list --json` (#249), which the app writes with `workroom host set`.
/// On a workroom, present means the workroom lives on another host, and its `path` is a path
/// there. On a project, it records the project's base machine (#252), and the project itself is
/// still on this Mac. The app owns the schema (the `HostDriver` is Swift, OQ21); the CLI reads
/// only presence and `state`. Decoded as leniently as the CLI reads it: any non-null value counts
/// as present, and each field that does not decode is nil, so a malformed descriptor still keeps a
/// remote workroom away from every local action instead of failing the whole listing.
public struct HostDescriptor: Codable, Hashable, Sendable {
  public var state: String? = nil
  /// Which `HostDriver` made the host: `container` or `apple-container` (`ContainerHostDriver`),
  /// or `boxd` (`BoxdHostDriver`, #356).
  public var driver: String? = nil
  /// The bundle ID of the build that made the host, whose key and labels it carries: a Dev and a
  /// Nightly app share config but not keys, so each adopts only its own hosts.
  public var provisioner: String? = nil
  /// The host's `HostID.remote` ID.
  public var id: UUID? = nil
  /// A workroom's broker grant, which destroying it cancels.
  public var grantID: String? = nil
  /// The ID a workroom's grant and its agent's route to the broker are keyed by
  /// (`RemoteProvisioning.provision`). Chosen before the host exists, so not the host's.
  public var workroomID: UUID? = nil
  /// A workroom's GitHub repository, `owner/name`, and its clone URL, for its PR and CI status
  /// (`RemoteWorkrooms.registrations`). An older build's base recorded the same fields, with the
  /// clone's `path`.
  public var repository: String? = nil
  public var cloneURL: String? = nil
  public var path: String? = nil
  /// How `ContainerHostDriver` finds the host again, including the Docker context it runs in.
  public var container: ContainerHostRecord? = nil
  /// A project's bases when an older build made more than one (#309): one per container runtime
  /// and Docker context, each a whole base descriptor. nil for a project with one base, whose
  /// descriptor is the base itself. Read only to retire them (`BaseRetirement`); it goes once no
  /// build that made bases is in use.
  public var bases: [HostDescriptor]? = nil
  /// `relay` for a local container base or workroom whose git credentials come from the Mac's
  /// relay instead of the broker (#309); nil for the broker.
  public var credentials: String? = nil
  /// A boxd host's org, as `boxd auth` named the active one when it was made; nil is the account's
  /// own (#356).
  public var org: String? = nil
  /// A boxd host's account, `boxd auth`'s `user_id` when it was made (#356). Every personal
  /// account's org is nil, so the org alone can't tell two accounts apart.
  public var account: String? = nil

  /// Whether git's credentials on this host come through the Mac's relay (#309).
  public var isRelayed: Bool { credentials == "relay" }

  public var isDestroyed: Bool { state == "destroyed" }

  enum CodingKeys: String, CodingKey {
    case state, driver, provisioner, id, repository, path, container, bases, credentials, org
    case account
    case grantID = "grant_id"
    case workroomID = "workroom_id"
    case cloneURL = "clone_url"
  }

  public init(
    state: String? = nil, driver: String? = nil, provisioner: String? = nil, id: UUID? = nil,
    grantID: String? = nil, workroomID: UUID? = nil, repository: String? = nil,
    cloneURL: String? = nil, path: String? = nil, container: ContainerHostRecord? = nil,
    bases: [HostDescriptor]? = nil, credentials: String? = nil, org: String? = nil,
    account: String? = nil
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
    self.bases = bases
    self.credentials = credentials
    self.org = org
    self.account = account
  }

  public init(from decoder: Decoder) throws {
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
    container = try? fields?.decodeIfPresent(ContainerHostRecord.self, forKey: .container)
    bases = try? fields?.decodeIfPresent([HostDescriptor].self, forKey: .bases)
    credentials = try? fields?.decodeIfPresent(String.self, forKey: .credentials)
    org = try? fields?.decodeIfPresent(String.self, forKey: .org)
    account = try? fields?.decodeIfPresent(String.self, forKey: .account)
  }
}

public struct Workroom: Codable, Identifiable, Hashable, Sendable {
  public let name: String
  public let path: String
  public let vcsName: String
  public let warnings: [Warning]
  /// nil for a workroom on this Mac.
  public var host: HostDescriptor? = nil
  /// GUI-only display alias (issue #41). NOT part of the `--json` contract — the CLI never sends
  /// it; it's injected post-decode in `AppStore.apply` from `Defaults[.workroomLabels]`. Absent
  /// from `CodingKeys` (with a default) so the synthesised decoder skips it. Intentionally a
  /// stored property, so synthesised `Equatable`/`Hashable` include it: a label change must make
  /// the value compare unequal for SwiftUI to re-render. Identity stays `id == name` (the
  /// immutable workspace name), so routing/selection/terminal-keying are unaffected, and nothing
  /// keys a dict/set on a whole `Workroom`, so the hash change is harmless.
  public var label: String? = nil

  public var id: String { name }
  public var hasBlockingWarning: Bool { warnings.contains { $0.kind == "DirectoryMissing" } }
  public var isRemote: Bool { host != nil }

  /// The name to show in the UI: the label when one is set, else the real workspace name. The
  /// single place the label-vs-name choice is made; every display site routes through this.
  public var displayName: String { Workroom.normalizedLabel(label) ?? name }

  /// Canonical label normaliser (issue #41): trim surrounding whitespace; treat empty/whitespace-only
  /// as "no label" (nil). The one definition reused by `displayName`, `AppStore.setWorkroomLabel`'s
  /// write boundary, and `WorkroomLabelSheetModel`'s validation — so the "is this blank?" rule can't
  /// drift between them.
  public static func normalizedLabel(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  public init(
    name: String, path: String, vcsName: String, warnings: [Warning], host: HostDescriptor? = nil,
    label: String? = nil
  ) {
    self.name = name
    self.path = path
    self.vcsName = vcsName
    self.warnings = warnings
    self.host = host
    self.label = label
  }

  enum CodingKeys: String, CodingKey {
    case name, path, warnings, host
    case vcsName = "vcs_name"
    // `label` is deliberately omitted — it's a GUI-only field, not part of the CLI JSON contract.
  }
}

public struct Project: Codable, Identifiable, Hashable, Sendable {
  public let path: String
  public let vcs: String
  public let workrooms: [Workroom]
  /// The project's base machine (#252), or nil when it has none. The project is still on this Mac.
  public var host: HostDescriptor? = nil
  /// The branch new workrooms start from, origin's copy first; nil means origin's default branch.
  public var baseBranch: String? = nil

  public init(
    path: String, vcs: String, workrooms: [Workroom], host: HostDescriptor? = nil,
    baseBranch: String? = nil
  ) {
    self.path = path
    self.vcs = vcs
    self.workrooms = workrooms
    self.host = host
    self.baseBranch = baseBranch
  }

  enum CodingKeys: String, CodingKey {
    case path, vcs, workrooms, host
    case baseBranch = "base_branch"
  }

  public var id: String { path }
  public var displayName: String { (path as NSString).lastPathComponent }
}

// MARK: - Envelopes

/// Common envelope header present on every response; used to detect error responses
/// before decoding a command-specific payload.
public struct Envelope: Codable, Sendable {
  public let ok: Bool
  public let schemaVersion: Int?
  public let error: CLIErrorBody?

  public init(ok: Bool, schemaVersion: Int?, error: CLIErrorBody?) {
    self.ok = ok
    self.schemaVersion = schemaVersion
    self.error = error
  }

  enum CodingKeys: String, CodingKey {
    case ok, error
    case schemaVersion = "schema_version"
  }
}

public struct CLIErrorBody: Codable, Sendable {
  public let kind: String
  public let message: String

  public init(kind: String, message: String) {
    self.kind = kind
    self.message = message
  }

}

public struct ListResponse: Codable, Sendable {
  public let projects: [Project]
  public let workroomsDir: String?
  public let configPath: String?
  /// The app-wide base branch for projects that name none (`workroom base set --global`).
  public var baseBranch: String? = nil

  public init(
    projects: [Project], workroomsDir: String?, configPath: String?, baseBranch: String? = nil
  ) {
    self.projects = projects
    self.workroomsDir = workroomsDir
    self.configPath = configPath
    self.baseBranch = baseBranch
  }

  enum CodingKeys: String, CodingKey {
    case projects
    case workroomsDir = "workrooms_dir"
    case configPath = "config_path"
    case baseBranch = "base_branch"
  }
}

public struct CreateResponse: Codable, Sendable {
  public let name: String
  public let path: String
  public let vcs: String
  public let project: String
  /// For the user, when the workroom started from a ref that may be out of date because the fetch
  /// before it failed.
  public var warning: String? = nil

  public init(name: String, path: String, vcs: String, project: String, warning: String? = nil) {
    self.name = name
    self.path = path
    self.vcs = vcs
    self.project = project
    self.warning = warning
  }

}

/// `add-project` success payload. `path` is the canonical (symlink-resolved,
/// ~-expanded) project path the CLI registered — the app selects the project by
/// it after a reload. `vcs` is "git".
public struct AddProjectResponse: Codable, Sendable {
  public let path: String
  public let vcs: String

  public init(path: String, vcs: String) {
    self.path = path
    self.vcs = vcs
  }

}

/// `delete-project --from-disk` success payload. The CLI runs teardowns + drops the project
/// from config, then returns the directories (project root first, then workrooms) for the app
/// to move to the Bin — the CLI never deletes them itself (issue #108).
public struct DeleteProjectResponse: Codable, Sendable {
  public let trashPaths: [String]?

  public init(trashPaths: [String]?) {
    self.trashPaths = trashPaths
  }

  enum CodingKeys: String, CodingKey {
    case trashPaths = "trash_paths"
  }
}

/// A streamed event from the CLI's stderr in --json mode (one NDJSON object per line)
/// while the result envelope stays on stdout. `type` discriminates:
///  - "log": a line of setup/teardown output (`text`, `phase`).
///  - "created": the new workroom exists (`name`, `path`) but setup is still running;
///    `setup` reports whether a setup script will run, so the GUI can block on its log.
public struct StreamEvent: Decodable, Sendable {
  public let type: String
  public let phase: String?
  public let text: String?
  public let name: String?
  public let path: String?
  public let setup: Bool?
  /// On "created": the create's fetch warning, which arrives before setup runs.
  public var warning: String? = nil

  public init(
    type: String, phase: String?, text: String?, name: String?, path: String?, setup: Bool?,
    warning: String? = nil
  ) {
    self.type = type
    self.phase = phase
    self.text = text
    self.name = name
    self.path = path
    self.setup = setup
    self.warning = warning
  }

}
