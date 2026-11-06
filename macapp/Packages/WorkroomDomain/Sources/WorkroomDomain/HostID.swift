import Foundation

/// A host instance, independent of its current network address.
public enum HostID: Hashable, Sendable {
  case local
  case remote(UUID)
}

extension HostID {
  /// What a host an older Nightly made tells the user, wherever it is met: a connect
  /// (`RepositoryRoutingError.olderLayout`), a pane's attach (`DaemonInstall.formerLayoutMessage`)
  /// and an older container (`HostDriverError.olderContainerMessage`).
  public static let olderLayoutMessage =
    "This workroom's host was set up by an older Workroom Nightly, which this build can't open. "
    + "Delete the workroom and create it again."
}
