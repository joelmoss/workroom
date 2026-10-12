import Foundation

/// A host instance, independent of its current network address.
public enum HostID: Hashable, Sendable {
  case local
  case remote(UUID)
}

public enum RepositoryRoutingError: Error, Equatable, Sendable, LocalizedError,
  CustomStringConvertible
{
  case invalidPath(String)
  case mixedHosts
  case unavailable(HostID)
  /// A boxd box asleep, or one boxd refused to answer about (signed out, another account), which a
  /// background read leaves be: connecting would wake it (#356).
  case asleep(HostID)
  /// A boxd machine boxd says is not found: deleted, or in another org or account (#356).
  case gone(HostID)
  case registrationRequired

  public var description: String { errorDescription ?? "Repository unavailable" }

  /// What a read of an asleep boxd host says (#356), here and on the Changes panel.
  public static let asleepMessage =
    "The box is asleep, or boxd could not say (check the boxd CLI and `boxd auth`). Open the "
    + "workroom to reach it."

  public var errorDescription: String? {
    switch self {
    case .invalidPath(let path): return "Invalid repository path: \(path)"
    case .mixedHosts: return "Working and shared repositories must be on the same host."
    case .unavailable: return "Repository service unavailable."
    case .asleep: return Self.asleepMessage
    case .gone:
      return "This workroom's boxd machine is gone, or in a boxd org or account that isn't active."
    case .registrationRequired:
      return "Reload projects to register this repository before changing it."
    }
  }
}
