import Foundation
import WorkroomVCS

public enum HostConnectionError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible
{
  case connectionLost
  /// Refused locally, before a single byte reached the socket — the connection was already closed,
  /// the stream counter is exhausted, or the 32-slot request pool is full. Distinct from
  /// `connectionLost` because the caller can say "this definitely did not run", which for a WRITE
  /// is the difference between a safe retry and one that double-applies a commit or a push.
  case notDispatched
  /// The request was sent and its deadline passed with no reply. Distinct from `connectionLost`
  /// because the connection is fine — the PEER is not answering — and the two want opposite
  /// recoveries: `LocalAgentVCS` catches `connectionLost` to spawn wr-agent and retry, which is
  /// right for a dead agent and useless against a hung one, since the second candidate exits
  /// without binding while the first still holds the single-instance flock.
  ///
  /// Like `connectionLost` and unlike `notDispatched`, the request DID leave this process, so a
  /// write that fails this way has an unknown outcome.
  case requestTimedOut
  case staleGeneration
  case mismatchedContext
  case serviceUnavailable(String)

  public var description: String { errorDescription ?? "Host service unavailable." }

  public var errorDescription: String? {
    switch self {
    case .connectionLost:
      return "Host connection lost. An operation may have completed; refresh before retrying."
    case .notDispatched:
      return "Host service did not take the request; nothing was sent. Try again."
    case .requestTimedOut:
      return "Host service did not answer in time. An operation may have completed; refresh before "
        + "retrying."
    case .staleGeneration:
      return "Host connection changed. Refresh repository data before retrying."
    case .mismatchedContext:
      return "Host service returned a different repository context."
    case .serviceUnavailable(let detail):
      return "Host service unavailable: \(detail)"
    }
  }
}
