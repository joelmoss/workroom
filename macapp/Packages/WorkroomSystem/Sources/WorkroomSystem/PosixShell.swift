import Foundation

public enum PosixShell {
  /// One POSIX shell word, whatever `text` holds.
  public static func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
