import Foundation
import WorkroomDomain

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
  /// A provider host whose provider Workroom isn't signed in to any more (a Railway sign-in
  /// revoked or expired, #629): a background read leaves it be until the user signs in again.
  case signedOut(HostID)
  /// A host an older Nightly made, which this build can't open and has to be made again: one from
  /// before the daemon was renamed (#525), or a container from before #308, reached over ssh.
  case olderLayout(HostID)
  case registrationRequired

  public var description: String { errorDescription ?? "Repository unavailable" }

  /// What a read of an asleep boxd host says (#356), here and on the Changes panel.
  public static let asleepMessage =
    "The box is asleep, or boxd could not say (check the boxd CLI and `boxd auth`). Open the "
    + "workroom to reach it."

  /// What a read of a host its provider no longer has says: a boxd machine not found, or a
  /// Railway sandbox destroyed, failed or missing (#356, #629). Its clone went with it.
  public static let goneMessage =
    "This workroom's host is gone: it was deleted on its provider (or, on boxd, it's in an org "
    + "or account that isn't active). Its work went with it, so remove the workroom."

  /// What a read of a host whose provider sign-in ended says (#629), here and on the Changes panel.
  public static let signedOutMessage =
    "Workroom is signed out of Railway, so it can't check on this workroom's sandbox. Sign in to "
    + "Railway to reach it again."

  public var errorDescription: String? {
    switch self {
    case .olderLayout: return HostID.olderLayoutMessage
    case .invalidPath(let path): return "Invalid repository path: \(path)"
    case .mixedHosts: return "Working and shared repositories must be on the same host."
    case .unavailable: return "Repository service unavailable."
    case .asleep: return Self.asleepMessage
    case .gone: return Self.goneMessage
    case .signedOut: return Self.signedOutMessage
    case .registrationRequired:
      return "Reload projects to register this repository before changing it."
    }
  }
}
