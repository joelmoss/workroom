import Foundation

// `Service::ProgramStatus` (#358): what a program in a terminal reports about itself over OSC 7501,
// as the agent keeps it. The schema is pinned by `testdata/program-status/*.json`, which the agent's
// serializer tests and this package's decode tests both read.

/// A record's state. `clear` is not one: the agent applies it and the record is gone.
public enum ProgramStatusState: String, Sendable, Equatable {
  case idle, working, done, blocked, error
}

/// What a `blocked` record waits for.
public enum ProgramStatusKind: String, Sendable, Equatable {
  case none, permission, question, auth
}

/// One record of a session, as the agent sends it: `app` already inherited from its ancestors,
/// `title` and `message` already sanitised.
public struct ProgramStatusRecord: Sendable, Equatable {
  public let id: String
  public let state: ProgramStatusState
  public let kind: ProgramStatusKind
  /// 0-100, or -1 for "no percentage". Not shown anywhere.
  public let progress: Int
  public let app: String
  public let title: String
  public let message: String
  /// Which time this record entered `blocked`, from one counter per session, so a request that
  /// resolves and a new one with the same id never share a number. 0 for a record never blocked.
  public let episode: UInt64
  /// Whether the program that reported it answered the agent's support probe in its current run.
  /// Only these may notify: a bare `printf` of a report still shows, but never alerts.
  public let notify: Bool
  /// Set only on a command result (#473): the shell, not the program, reported it, and this is
  /// how its command exited. `message` is then the command line, or empty.
  public let exitCode: Int32?

  public init(
    id: String, state: ProgramStatusState, kind: ProgramStatusKind = .none, progress: Int = -1,
    app: String = "", title: String = "", message: String = "", episode: UInt64 = 0,
    notify: Bool = false, exitCode: Int32? = nil
  ) {
    self.id = id
    self.state = state
    self.kind = kind
    self.progress = progress
    self.app = app
    self.title = title
    self.message = message
    self.episode = episode
    self.notify = notify
    self.exitCode = exitCode
  }
}

public enum ProgramStatusEvent: Sendable, Equatable {
  /// Every record of `session`, never a delta, so a lost event is healed by the next.
  case status(
    boot: String, session: UUID, revision: UInt64, reporting: Bool, records: [ProgramStatusRecord])
  case ended(boot: String, session: UUID)
  /// Closes the snapshot that follows a subscribe: a session the snapshot did not name has gone.
  case snapshotComplete(boot: String, sessions: [UUID])
  /// The connection ended. Never on the wire: delivered once by the connection itself, as
  /// `FileWatchEvent.lost` is, so a subscriber knows to subscribe again on the next one.
  case lost

  /// The event in `payload`, nil for an event kind this build does not know (a newer agent may
  /// add one). Records with an unknown state or kind, or a missing field, are left out one by one
  /// and counted in `droppedRecords`; only a payload that is not an event at all throws.
  public static func decode(_ payload: Data) throws -> (event: Self?, droppedRecords: Int) {
    let wire = try JSONDecoder().decode(Wire.self, from: payload)
    switch wire.event {
    case "status":
      guard let boot = wire.boot, let session = wire.session.flatMap(UUID.init(uuidString:)),
        let revision = wire.revision, let records = wire.records
      else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "status")) }
      let kept = records.compactMap(\.record)
      return (
        .status(
          boot: boot, session: session, revision: revision, reporting: wire.reporting ?? false,
          records: kept),
        records.count - kept.count
      )
    case "ended":
      guard let boot = wire.boot, let session = wire.session.flatMap(UUID.init(uuidString:))
      else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "ended")) }
      return (.ended(boot: boot, session: session), 0)
    case "snapshot-complete":
      guard let boot = wire.boot, let sessions = wire.sessions else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: [], debugDescription: "snapshot-complete"))
      }
      return (.snapshotComplete(boot: boot, sessions: sessions.compactMap(UUID.init)), 0)
    default:
      return (nil, 0)
    }
  }

  private struct Wire: Decodable {
    let event: String
    let boot: String?
    let session: String?
    let revision: UInt64?
    let reporting: Bool?
    let records: [LossyRecord]?
    let sessions: [String]?
  }

  /// Decodes one record or nothing, so one bad record never costs the event.
  private struct LossyRecord: Decodable {
    let record: ProgramStatusRecord?

    private struct Fields: Decodable {
      let id: String
      let state: String
      let kind: String
      let progress: Int
      let app: String
      let title: String
      let message: String
      let episode: UInt64
      let notify: Bool
      let exitCode: Int32?
    }

    init(from decoder: Decoder) throws {
      guard let fields = try? Fields(from: decoder),
        let state = ProgramStatusState(rawValue: fields.state),
        let kind = ProgramStatusKind(rawValue: fields.kind)
      else {
        record = nil
        return
      }
      record = ProgramStatusRecord(
        id: fields.id, state: state, kind: kind, progress: fields.progress, app: fields.app,
        title: fields.title, message: fields.message, episode: fields.episode,
        notify: fields.notify, exitCode: fields.exitCode)
    }
  }
}

/// A Program Status request (`program_status.rs`).
public struct AgentProgramStatusRequest: Encodable, Sendable {
  public var version = 1
  public let method: String
  public var session: String?
  public var revision: UInt64?
  public var states: [String]?

  public init(
    method: String, session: UUID? = nil, revision: UInt64? = nil, states: [String]? = nil
  ) {
    self.method = method
    // The agent's session ids are lowercase (`SessionId::to_hyphenated`).
    self.session = session?.uuidString.lowercased()
    self.revision = revision
    self.states = states
  }
}

/// How a subscribe ended.
public enum ProgramStatusAvailability: Sendable, Equatable {
  /// Subscribed: the snapshot and live events follow on the handler.
  case available
  /// The agent has the service but cannot keep status, with its reason (built without
  /// `terminal-state`).
  case unavailable(String)
  /// The agent predates the service.
  case unsupported
}
