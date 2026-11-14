import Foundation
import WorkroomDomain

/// This Mac's Railway creates whose reply was lost (ADR 0071's amendment, review 5 of #623): the
/// create asked Railway for a sandbox, and the answer never arrived, so Railway may have made one
/// that only its id would name, and the ledger never got the id. Workroom never guesses which
/// sandbox that was: the launch sweep never touches such an entry, and it is never forgotten by
/// age. It stays on the ledger until the user resolves it, here: by destroying one of its
/// candidates, or by dismissing it.
///
/// A create's **candidates** are the sandboxes it might have made: live ones in the entry's own
/// environment that no record names, no other entry of this Mac's ledger names, and that Railway
/// made from `before` before the intent to `after` after it. They are read fresh on each call and
/// never written down: they are what the user chooses among, never authority to destroy.
public struct RailwayLostCreates: Sendable {
  /// One create whose reply was lost: when it began, and where it asked.
  public struct Create: Equatable, Hashable, Identifiable, Sendable {
    /// The ledger entry's intent.
    public var id: UUID
    public var started: Date
    /// The environment it asked in; nil for an entry from before entries named it, when no
    /// placement is known.
    public var environmentID: String?
    public var workspaceID: String?
    public var projectID: String?

    public init(
      id: UUID, started: Date, environmentID: String?, workspaceID: String?, projectID: String?
    ) {
      self.id = id
      self.started = started
      self.environmentID = environmentID
      self.workspaceID = workspaceID
      self.projectID = projectID
    }
  }

  /// Where this Mac's placement keeps its hosts: what an entry from before entries named their
  /// environment was made in.
  public struct Placement: Sendable {
    public var environmentID: String
    public var workspaceID: String?
    public var projectID: String?

    public init(environmentID: String, workspaceID: String?, projectID: String?) {
      self.environmentID = environmentID
      self.workspaceID = workspaceID
      self.projectID = projectID
    }
  }

  public enum Failure: Error, Equatable, LocalizedError {
    /// The create's environment isn't known, so nothing can be listed for it.
    case placeUnknown
    /// This sign-in can't see the workspace the create asked in, whose environment would list as
    /// empty.
    case workspaceNotSeen
    /// This sign-in sees the workspace but not the project the create asked in (or Railway won't
    /// name it), whose environment would list as empty too.
    case projectNotSeen
    /// The sandbox is no longer one of the create's candidates (recorded, named by another create,
    /// gone, or elsewhere), so it isn't destroyed.
    case notACandidate(String)
    /// Railway didn't confirm the destroy: what it said.
    case unconfirmed(String)
    /// The create is no longer on the ledger: resolved already, perhaps by the other build.
    case resolved

    public var errorDescription: String? {
      switch self {
      case .placeUnknown:
        "Workroom doesn't know which Railway environment this create asked in."
      case .workspaceNotSeen:
        "Railway's sign-in can't see the workspace this create asked in. Sign in to Railway with "
          + "the account that made it to see its sandboxes."
      case .projectNotSeen:
        "Railway's sign-in can't see the project this create asked in, so Workroom can't tell "
          + "whether it left a sandbox, and one may still be billing. Sign in to Railway with the "
          + "account that made it to see its sandboxes."
      case .notACandidate(let sandbox):
        "Railway sandbox \(sandbox) is no longer one this create may have made, so Workroom left "
          + "it alone."
      case .unconfirmed(let said): said
      case .resolved: "This create was already resolved."
      }
    }
  }

  /// How long before an intent Railway's clock may put its sandbox (the two clocks differ), and
  /// how long after it: the create's own request, its token refresh and the call, each bounded,
  /// has reached Railway by then.
  public static let before: TimeInterval = 120
  public static let after: TimeInterval = 300

  let api: RailwayAPI
  let ledger: RailwayCreateLedger
  let placement: Placement?

  /// The lost creates in the ledger in `directory` (`RailwayHostDriver.Configuration.keys`),
  /// asked of Railway through `api`. `placement` places an entry that names no environment.
  public init(api: RailwayAPI, directory: URL, placement: Placement?) {
    self.api = api
    ledger = RailwayCreateLedger(directory: directory)
    self.placement = placement
  }

  /// Every entry with no sandbox older than `grace`: a younger one may be a create still waiting
  /// for its reply, here or in the other build sharing the ledger. Never asks Railway.
  public func creates(now: Date = Date(), grace: TimeInterval = RailwayHostDriver.sweepGrace)
    async throws -> [Create]
  {
    try await ledger.entries().filter {
      $0.sandbox == nil && now.timeIntervalSince($0.started) >= grace
    }.sorted { $0.started < $1.started }.map(create)
  }

  private func create(_ entry: RailwayCreateLedger.Entry) -> Create {
    guard let environment = entry.environmentID else {
      return Create(
        id: entry.intent, started: entry.started, environmentID: placement?.environmentID,
        workspaceID: placement?.workspaceID, projectID: placement?.projectID)
    }
    let placed = placement?.environmentID == environment ? placement : nil
    return Create(
      id: entry.intent, started: entry.started, environmentID: environment,
      workspaceID: entry.workspaceID, projectID: entry.projectID ?? placed?.projectID)
  }

  /// The sandboxes `create` may have made, read now (see the type), oldest first: none of them
  /// named by `recorded`, the sandboxes config's records name.
  public func candidates(of create: Create, recorded: Set<String>) async throws
    -> [RailwaySandbox]
  {
    try await listing(of: create, recorded: recorded).candidates
  }

  /// `candidates`, with the project the create's environment is in, as it was proven seen.
  private func listing(of create: Create, recorded: Set<String>) async throws
    -> (candidates: [RailwaySandbox], projectID: String)
  {
    guard let environment = create.environmentID else { throw Failure.placeUnknown }
    // An environment in a workspace, or a project, the sign-in can't see lists as empty, which
    // would read as no candidates.
    guard try await api.sees(workspace: create.workspaceID) else {
      throw Failure.workspaceNotSeen
    }
    var project = create.projectID
    if project == nil { project = try await api.project(ofEnvironment: environment) }
    guard let project, try await api.sees(project: project, in: create.workspaceID) else {
      throw Failure.projectNotSeen
    }
    let named = Set(try await ledger.entries().compactMap(\.sandbox))
    let from = create.started.addingTimeInterval(-Self.before)
    let to = create.started.addingTimeInterval(Self.after)
    let window = from...to
    let candidates = try await api.sandboxes(environmentID: environment).filter { sandbox in
      guard sandbox.environmentID == environment, !RailwaySandbox.isEnding(sandbox.status),
        !recorded.contains(sandbox.id), !named.contains(sandbox.id),
        let made = sandbox.createdAt.flatMap(Self.date)
      else { return false }
      return window.contains(made)
    }.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
    return (candidates, project)
  }

  /// Destroys `sandbox`, which the user chose as `create`'s, and takes `create` off the ledger
  /// once Railway confirms it is gone. Only a sandbox that is a candidate now (`candidates`) is
  /// destroyed: one recorded, named by another create, gone or elsewhere since the user saw the
  /// list throws `notACandidate`. A destroy Railway didn't confirm keeps the entry.
  ///
  /// The check, the destroy and the drop hold `resolveLock` together, so Release and Nightly,
  /// sharing the ledger, never each destroy a different candidate of one create: the second
  /// finds it resolved. A lock of its own, not the ledger's, which isn't reentrant and which a
  /// create takes to begin: holding it across Railway's calls would hold up every create.
  public func destroy(_ sandbox: String, of create: Create, recorded: Set<String>) async throws {
    try await resolveLock.withLock {
      try await destroyNow(sandbox, of: create, recorded: recorded)
    }
  }

  /// Held while a lost create is resolved, by either app: long enough for a destroy's calls to
  /// Railway (a listing, the destroy and its check), each bounded by the request's own timeout.
  var resolveLock: CrossProcessLock {
    CrossProcessLock(
      path: ledger.directory.appendingPathComponent("lost-create.lock"), timeout: .seconds(300))
  }

  private func destroyNow(_ sandbox: String, of create: Create, recorded: Set<String>)
    async throws
  {
    guard
      try await ledger.entries().contains(where: { $0.intent == create.id && $0.sandbox == nil })
    else { throw Failure.resolved }
    let listing = try await listing(of: create, recorded: recorded)
    guard listing.candidates.contains(where: { $0.id == sandbox }) else {
      throw Failure.notACandidate(sandbox)
    }
    let record = RailwayHostRecord(
      projectID: listing.projectID, environmentID: create.environmentID ?? "", sandboxID: sandbox,
      hostKey: "", workspaceID: create.workspaceID)
    if let failure = await api.destroyConfirmed(record) { throw Failure.unconfirmed(failure) }
    try await ledger.drop([create.id])
  }

  /// Takes `create` off the ledger, destroying nothing: the user has checked Railway themselves.
  public func dismiss(_ create: Create) async throws {
    try await resolveLock.withLock { try await ledger.drop([create.id]) }
  }

  /// Railway's `DateTime`, ISO 8601 with or without fractional seconds.
  public static func date(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}
