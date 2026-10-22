import Foundation
import WorkroomVCS

/// Where the daemon is installed on a host: its socket, and beside it its binary and Ghostty's
/// resources (#239).
public enum DaemonInstall {
  /// The container image's socket (`vcs/scripts/ssh-fixture/entrypoint.sh`), for a driver that
  /// doesn't say otherwise.
  public static let defaultSocket = "/run/workroom/workroomd.sock"

  /// Where the daemon lives on a host: beside its socket.
  public static func binary(besideSocket socket: String) -> String {
    (socket as NSString).deletingLastPathComponent + "/workroomd"
  }

  /// Where a host made before the daemon was renamed (#525) has it: `wr-agent`, in `agent/` where
  /// the new layout has `daemon/`, else beside the socket (a container's `/run/workroom`). Only
  /// Nightly and Dev builds ever made such hosts; the app refuses them (`DaemonBootstrap`'s
  /// `olderLayout`) rather than migrate them (eng review D3). Retired by #526.
  /// What a host with the old layout tells the user, wherever it is met: the bootstrap, and a
  /// pane's attach.
  public static let formerLayoutMessage = RepositoryRoutingError.olderLayoutMessage

  public static func formerBinary(besideSocket socket: String) -> String {
    let directory = (socket as NSString).deletingLastPathComponent
    let parent = (directory as NSString).deletingLastPathComponent
    return (directory as NSString).lastPathComponent == "daemon"
      ? parent + "/agent/wr-agent" : directory + "/wr-agent"
  }

  /// Where Ghostty's terminfo and shell integration live on a host: beside the daemon, in the
  /// socket's 0700 directory (#239).
  public static func resources(besideSocket socket: String) -> String {
    (socket as NSString).deletingLastPathComponent + "/ghostty"
  }
}
