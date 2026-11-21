import Foundation

// `events.subscribe` on `Service::TerminalApi` (ADR 0079), as the app reads it: only
// `session.input`, the event `terminal.send` tells before it types into a session (#689), so the
// app can mark who is typing into a pane (#696). The daemon's side is
// `vcs/crates/workroomd/src/terminal/api/events.rs`.

/// What the app hears of the terminal API's events.
public enum TerminalInputEvent: Sendable, Equatable {
  /// `sender` is typing into `session`: the session the send came from, or nil for a send from no
  /// pane (a script outside Workroom).
  case input(session: UUID, sender: UUID?)
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

  /// The subscribe request: every session's typing, whatever scope the daemon finds the app's
  /// process in (a Dev app started from a pane descends from that pane's shell), and no `since`,
  /// so nothing typed before the app subscribed is replayed as typing now.
  public static let subscribeRequest = Data(
    #"{"method":"events.subscribe","params":{"all":true,"types":["session.input"]}}"#.utf8)

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

    var input: TerminalInputEvent? {
      guard event == "session.input", let session = session.flatMap(UUID.init(uuidString:))
      else { return nil }
      return .input(session: session, sender: sender.flatMap(UUID.init(uuidString:)))
    }
  }
}

/// How a subscription to the terminal API's events ended.
public enum TerminalInputAvailability: Sendable, Equatable {
  /// Subscribed: live events follow on the handler.
  case available
  /// The daemon refused it, with its error's message (`Busy` past its subscription limits).
  case refused(String)
  /// The daemon predates the terminal API.
  case unsupported
}
