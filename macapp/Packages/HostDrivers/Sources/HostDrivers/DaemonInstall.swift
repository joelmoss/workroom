import Foundation

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

  /// Where Ghostty's terminfo and shell integration live on a host: beside the daemon, in the
  /// socket's 0700 directory (#239).
  public static func resources(besideSocket socket: String) -> String {
    (socket as NSString).deletingLastPathComponent + "/ghostty"
  }
}
