import Foundation

// `events.subscribe` on `Service::TerminalApi` (ADR 0079), as the app reads it: `session.input`,
// the event `terminal.send` tells before it types into a session (#689), so the app can mark who
// is typing into a pane (#696); and what `workroom new` and `workroom close` ask of the app
// (#693), a `session.created` with `opened` and a `session.ended` with `closed`. The daemon's side
// is `vcs/crates/workroomd/src/terminal/api/events.rs`.

/// What `workroom new` asked the app to show (#693): a `session.created`'s `opened`, with the
/// session's own fields the app needs to show it.
public struct TerminalOpenRequest: Sendable, Equatable {
  /// Where a split goes, beside the pane that asked.
  public enum Split: String, Sendable, Equatable {
    case right
    case down
  }

  /// The new session.
  public let session: UUID
  /// The session that asked for it, nil from no pane.
  public let by: UUID?
  /// The split asked for, nil for a tab.
  public let split: Split?
  /// The Mac to show it, as its pane's attach named it; nil when no pane has the asking session,
  /// and every Mac lists it as detached.
  public let hostname: String?
  /// What the session is tagged with (its scope's id), nil for none.
  public let workroom: String?
  /// Its label, the tab's name, nil for none.
  public let label: String?
  /// Whether it is a run session (`workroom new --run`).
  public let run: Bool

  public init(
    session: UUID, by: UUID?, split: Split?, hostname: String?, workroom: String?,
    label: String?, run: Bool
  ) {
    self.session = session
    self.by = by
    self.split = split
    self.hostname = hostname
    self.workroom = workroom
    self.label = label
    self.run = run
  }
}

/// What the app hears of the terminal API's events.
public enum TerminalInputEvent: Sendable, Equatable {
  /// `sender` is typing into `session`: the session the send came from, or nil for a send from no
  /// pane (a script outside Workroom).
  case input(session: UUID, sender: UUID?)
  /// `workroom new` made a session and asks the app to show it (#693).
  case opened(TerminalOpenRequest)
  /// `workroom close` ended `session`: the app closes its tab or split (#693).
  case closed(session: UUID)
  /// The connection ended. Never on the wire: delivered once by the connection itself, as
  /// `ProgramStatusEvent.lost` is, so the subscriber knows to subscribe again on the next one.
  case lost

  /// One reply of the subscription's stream, `{"revision", "result" | "error", "more"}`.
  public enum Reply: Sendable, Equatable {
    /// An event: `event` is nil for one the app does not read (a snapshot's `session`,
    /// `snapshot-complete`, `place`, any other type, or one a newer daemon adds).
    case event(TerminalInputEvent?, more: Bool)
    /// The daemon refused the subscription, with its error's `kind` and `message`. Ends the stream.
    case refused(kind: String, message: String)
  }

  /// Reads one reply. Throws only for a payload that is no reply at all.
  public static func decode(reply payload: Data) throws -> Reply {
    let wire = try JSONDecoder().decode(Wire.self, from: payload)
    if let error = wire.error {
      return .refused(kind: error.kind ?? "", message: error.message ?? "")
    }
    guard let result = wire.result else {
      throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no result"))
    }
    return .event(result.input, more: wire.more ?? false)
  }

  /// The subscribe request: every session's typing, creations and ends, whatever scope the daemon
  /// finds the app's process in (a Dev app started from a pane descends from that pane's shell),
  /// and no `since`, so nothing typed, opened or closed before the app subscribed is replayed as
  /// happening now. A daemon that knows no `session.input` (one from before #689) refuses the
  /// whole of it, and has no `new` or `close` either.
  public static let subscribeRequest = Data(
    #"{"method":"events.subscribe","params":{"all":true,"types":["session.input","session.created","session.ended"]}}"#
      .utf8)

  /// The request that ends this connection's subscription on `stream` on the daemon
  /// (`events.unsubscribe`, #696).
  public static func unsubscribeRequest(stream: UInt32) -> Data {
    Data(#"{"method":"events.unsubscribe","params":{"stream":\#(stream)}}"#.utf8)
  }

  private struct Wire: Decodable {
    let result: Event?
    let error: Failure?
    let more: Bool?
  }

  private struct Failure: Decodable {
    let kind: String?
    let message: String?
  }

  private struct Event: Decodable {
    let event: String?
    let session: String?
    let sender: String?
    let scope: Scope?
    let label: String?
    let run: Bool?
    let opened: Opened?
    let closed: Bool?

    struct Scope: Decodable {
      let id: String?
    }

    struct Opened: Decodable {
      let by: String?
      let split: String?
      let hostname: String?
    }

    var input: TerminalInputEvent? {
      guard let session = session.flatMap(UUID.init(uuidString:)) else { return nil }
      switch event {
      case "session.input":
        return .input(session: session, sender: sender.flatMap(UUID.init(uuidString:)))
      // Only a session `workroom new` made: the app's own say nothing of `opened`.
      case "session.created":
        guard let opened else { return nil }
        return .opened(
          TerminalOpenRequest(
            session: session, by: opened.by.flatMap(UUID.init(uuidString:)),
            split: opened.split.flatMap(TerminalOpenRequest.Split.init(rawValue:)),
            hostname: opened.hostname, workroom: scope?.id, label: label, run: run ?? false))
      // Only a session `workroom close` ended: one whose shell exited keeps its pane.
      case "session.ended" where closed == true:
        return .closed(session: session)
      default:
        return nil
      }
    }
  }
}

/// A live subscription to who types where: `end()` ends it, here and on the daemon, which frees
/// its place there (a connection holds 8). Its subscriber ends it when it stops listening (its
/// task cancelled, or its host forgotten); otherwise it lasts as long as the connection.
public struct TerminalInputSubscription: Sendable, Equatable {
  /// The stream it was asked on, which names it to `events.unsubscribe`.
  public let stream: UInt32
  private let ending: @Sendable () -> Void

  public init(stream: UInt32, end: @escaping @Sendable () -> Void) {
    self.stream = stream
    ending = end
  }

  public func end() { ending() }

  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.stream == rhs.stream }
}

/// How a subscription to the terminal API's events ended.
public enum TerminalInputAvailability: Sendable, Equatable {
  /// Subscribed: live events follow on the handler until the subscription ends.
  case available(TerminalInputSubscription)
  /// The daemon refused it, with its error's message (`Busy` past its subscription limits).
  case refused(String)
  /// The daemon has no typing to tell: it predates the terminal API, or `session.input`.
  case unsupported
}
