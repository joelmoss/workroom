import Foundation
import Synchronization

/// Where this Mac keeps its Railway hosts (ADR 0071, #629): the workspace the user picked, the
/// `Workroom` project in it, and this Mac's own environment there. Kept in a file the app puts
/// where Release and Nightly both read it and a Dev build has its own, so a Mac moved with
/// Migration Assistant keeps its environment, and a Mac rebuilt from scratch gets a new one.
public struct RailwayPlacement: Codable, Equatable, Sendable {
  /// The workspace the user picked in the setup sheet, for the next project.
  public var selectedWorkspaceID: String?
  /// The workspace holding the recorded project, which the sign-in must reach.
  public var workspaceID: String?
  public var projectID: String?
  /// This Mac's environment in the project: every sandbox it makes goes here.
  public var environmentID: String?

  public init(
    selectedWorkspaceID: String? = nil, workspaceID: String? = nil, projectID: String? = nil,
    environmentID: String? = nil
  ) {
    self.selectedWorkspaceID = selectedWorkspaceID
    self.workspaceID = workspaceID
    self.projectID = projectID
    self.environmentID = environmentID
  }

  enum CodingKeys: String, CodingKey {
    case selectedWorkspaceID = "selected_workspace_id"
    case workspaceID = "workspace_id"
    case projectID = "project_id"
    case environmentID = "environment_id"
  }

  /// The project the user's hosts go in, by name: picked when the workspace has one, else made.
  public static let projectName = "Workroom"
}

/// The placement's file. A missing or unreadable one is no placement yet.
public final class RailwayPlacementStore: Sendable {
  public let file: URL
  private let lock = Mutex(())

  public init(file: URL) { self.file = file }

  /// The lock file Release and Nightly share for a placement (`ensure`), beside the placement.
  /// A file of its own: the placement is written atomically, which replaces its inode.
  public var lockFile: URL {
    file.deletingLastPathComponent().appendingPathComponent("placement.lock")
  }

  public func read() -> RailwayPlacement {
    lock.withLock { _ in decoded() }
  }

  /// Changes the placement and writes it whole.
  public func update(_ change: (inout RailwayPlacement) -> Void) throws {
    try lock.withLock { _ in
      var placement = decoded()
      change(&placement)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(placement).write(to: file, options: .atomic)
    }
  }

  /// The file's placement, or none for a missing or unreadable file. Under `lock`.
  private func decoded() -> RailwayPlacement {
    (try? Data(contentsOf: file)).flatMap {
      try? JSONDecoder().decode(RailwayPlacement.self, from: $0)
    } ?? RailwayPlacement()
  }

  /// This Mac's environment in the project `project` names, or with none the recorded project,
  /// else the `Workroom` project, of `workspaceID`, making whatever isn't recorded yet: the
  /// `Workroom` project is picked by name or made, then the environment is made, named
  /// `environmentName`. Each id is recorded as soon as Railway returns it, so a retry after a
  /// failure never makes a second project or environment. The setup sheet runs it with the project
  /// the user picked; a create whose setup never placed this Mac runs it with none.
  ///
  /// Another workspace or project than the recorded one starts again there, but only once this
  /// Mac's environment holds no sandbox: the launch sweep lists only the current environment, so
  /// one left behind, recorded or not, would bill with no sweep to find it. Otherwise it throws
  /// `RailwayPlacementError.environmentHoldsSandboxes`, or Railway's error when it can't list
  /// them, and the placement stays. A listing is trusted only when the sign-in sees the workspace
  /// the environment is in, which lists as empty otherwise: else it throws
  /// `RailwayPlacementError.workspaceNotSeen`.
  public func ensure(
    workspaceID: String, project: RailwayProjectPick? = nil, api: RailwayAPI,
    environmentName: String
  ) async throws -> (projectID: String, environmentID: String) {
    // One at a time: the creates a setup sheet carries on start together, and two would each
    // make a project and an environment. Across Release and Nightly too, which share the file:
    // the whole transaction holds the placement's lock, and reads the placement only once it
    // has it, so what the other app made meanwhile is used, not made again.
    let lock = CrossProcessLock(path: lockFile, timeout: Self.lockTimeout)
    return try await RailwaySerial.shared.run {
      try await lock.withLock {
        try await self.ensureNow(
          workspaceID: workspaceID, project: project, api: api, environmentName: environmentName)
      }
    }
  }

  /// How long a placement waits for the other app's: it holds the lock across its calls to
  /// Railway (a listing, a project, an environment), each bounded by the request's own timeout.
  static let lockTimeout: Duration = .seconds(300)

  private func ensureNow(
    workspaceID: String, project: RailwayProjectPick?, api: RailwayAPI, environmentName: String
  ) async throws -> (projectID: String, environmentID: String) {
    var placement = read()
    // The project picked, by id: nil for none, and for a `Workroom` project still to be made.
    let picked: String?
    switch project {
    case nil: picked = nil
    case .existing(let id): picked = id
    case .workroom: picked = try await Self.workroomProject(in: workspaceID, api: api)
    }
    let moves =
      placement.workspaceID != workspaceID
      || (project != nil && picked != placement.projectID)
    if moves {
      if let leaving = placement.environmentID {
        // An environment in a workspace the sign-in can't see lists as empty: only a sign-in that
        // sees it may trust the listing.
        let seen = try await api.grantedWorkspaces().map(\.id)
        guard let from = placement.workspaceID, seen.contains(from) else {
          throw RailwayPlacementError.workspaceNotSeen
        }
        let live = try await api.sandboxes(environmentID: leaving).filter {
          !["DESTROYED", "DESTROYING"].contains($0.status)
        }
        guard live.isEmpty else {
          throw RailwayPlacementError.environmentHoldsSandboxes(live.count)
        }
      }
      try update {
        $0.workspaceID = workspaceID
        $0.projectID = picked
        $0.environmentID = nil
      }
      placement = read()
    }
    let projectID: String
    if let recorded = placement.projectID {
      projectID = recorded
    } else {
      if let existing = try await Self.workroomProject(in: workspaceID, api: api) {
        projectID = existing
      } else {
        projectID = try await api.createProject(
          name: RailwayPlacement.projectName, workspaceID: workspaceID)
      }
      try update { $0.projectID = projectID }
    }
    if let environmentID = placement.environmentID { return (projectID, environmentID) }
    let environmentID = try await api.createEnvironment(
      name: environmentName, projectID: projectID)
    try update { $0.environmentID = environmentID }
    return (projectID, environmentID)
  }

  /// The id of `workspaceID`'s project named `Workroom`, if it has one.
  private static func workroomProject(in workspaceID: String, api: RailwayAPI) async throws
    -> String?
  {
    try await api.projects(workspaceID: workspaceID).first {
      $0.name == RailwayPlacement.projectName
    }?.id
  }

  /// A name for this Mac's environment: its own name, and a random suffix, since two Macs can
  /// share a name. The environment is known by its id; the name is for Railway's dashboard.
  public static func environmentName(
    computer: String = ProcessInfo.processInfo.hostName, suffix: String = randomSuffix()
  ) -> String {
    let base = computer.split(separator: ".").first.map(String.init) ?? computer
    let slug = String(
      base.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
    ).split(separator: "-").joined(separator: "-")
    return "mac-\(slug.isEmpty ? "unnamed" : String(slug.prefix(40)))-\(suffix)"
  }

  public static func randomSuffix() -> String {
    String(UUID().uuidString.lowercased().prefix(6))
  }
}

/// The project the setup sheet picked for this Mac's environment (story 14).
public enum RailwayProjectPick: Hashable, Sendable {
  /// A project already in the workspace, by id.
  case existing(String)
  /// The workspace's project named `Workroom`, made when it has none.
  case workroom
}

/// Why this Mac's Railway hosts can't move to another workspace or project.
public enum RailwayPlacementError: LocalizedError, Equatable {
  /// This Mac's environment still holds `count` sandboxes that haven't been destroyed.
  case environmentHoldsSandboxes(Int)
  /// Railway's sign-in can't see the workspace this Mac's environment is in (another account, or
  /// none recorded), so its listing of the environment's sandboxes can't be trusted as empty.
  case workspaceNotSeen

  public var errorDescription: String? {
    switch self {
    case .workspaceNotSeen:
      return "Railway's sign-in can't see the workspace this Mac's Railway environment is in, so "
        + "Workroom can't tell whether sandboxes are still there, and would lose track of them in "
        + "another workspace or project. Sign in to Railway with the account that set it up, then "
        + "try again."
    case .environmentHoldsSandboxes(let count):
      let sandboxes = count == 1 ? "a sandbox" : "\(count) sandboxes"
      return "This Mac's Railway environment still has \(sandboxes), and Workroom would lose "
        + "track of \(count == 1 ? "it" : "them") in another workspace or project. Delete this "
        + "Mac's Railway workrooms first, or the sandboxes on Railway's dashboard, then try again."
    }
  }
}

/// Runs this Mac's Railway setup steps one at a time, in order: making the placement, and making
/// and registering the Mac's key, which concurrent first creates would otherwise each do. In this
/// app only: the placement and the key each take a file lock the other build shares too.
public actor RailwaySerial {
  public static let shared = RailwaySerial()
  private var tail: Task<Void, Never>?

  public func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let previous = tail
    let task = Task<T, Error> {
      await previous?.value
      return try await body()
    }
    tail = Task { _ = try? await task.value }
    return try await task.value
  }
}

/// A project in a workspace, as the setup sheet offers it.
public struct RailwayProject: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

extension RailwayAPI {
  /// The projects in `workspaceID` the sign-in can see.
  public func projects(workspaceID: String) async throws -> [RailwayProject] {
    struct Answer: Decodable {
      struct Connection: Decodable {
        struct Edge: Decodable {
          struct Node: Decodable {
            let id: String
            let name: String
          }
          let node: Node
        }
        let edges: [Edge]
      }
      let projects: Connection
    }
    return try await query(
      "query projects($workspaceId: String) { projects(workspaceId: $workspaceId) "
        + "{ edges { node { id name } } } }",
      variables: ["workspaceId": .string(workspaceID)], as: Answer.self
    ).projects.edges.map { RailwayProject(id: $0.node.id, name: $0.node.name) }
  }

  public func createProject(name: String, workspaceID: String) async throws -> String {
    struct Answer: Decodable {
      struct Project: Decodable { let id: String }
      let projectCreate: Project
    }
    return try await query(
      "mutation projectCreate($input: ProjectCreateInput!) { projectCreate(input: $input) "
        + "{ id } }",
      variables: ["input": ["name": .string(name), "workspaceId": .string(workspaceID)]],
      as: Answer.self
    ).projectCreate.id
  }

  public func createEnvironment(name: String, projectID: String) async throws -> String {
    struct Answer: Decodable {
      struct Environment: Decodable { let id: String }
      let environmentCreate: Environment
    }
    return try await query(
      "mutation environmentCreate($input: EnvironmentCreateInput!) { environmentCreate(input: "
        + "$input) { id } }",
      variables: [
        "input": [
          "name": .string(name), "projectId": .string(projectID), "skipInitialDeploys": true,
        ]
      ], as: Answer.self
    ).environmentCreate.id
  }
}
