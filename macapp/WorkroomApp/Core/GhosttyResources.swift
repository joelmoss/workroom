import Foundation

/// Where the bundled libghostty runtime resources live, and how they reach the engine.
///
/// `Resources/ghostty/` carries the `xterm-ghostty` terminfo entry and the per-shell integration
/// scripts (see `Resources/ghostty/SOURCE.md`). libghostty finds them through
/// `GHOSTTY_RESOURCES_DIR`, which must be exported **before** `ghostty_init` — the engine captures
/// the environment there, so a later write would not be seen.
///
/// Two callers, deliberately: `GhosttyApp` on the GUI path, and `main.swift` on the CLI path. An
/// invocation through the `Contents/MacOS/ghostty` symlink never constructs a `GhosttyApp`, so it
/// has to export the variable itself.
enum GhosttyResources {
  /// The bundled `ghostty/` tree, or nil when it is missing or incomplete.
  static var bundledURL: URL? {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("ghostty"),
      FileManager.default.fileExists(
        atPath: url.appendingPathComponent("shell-integration").path)
    else { return nil }
    return url
  }

  /// Export `GHOSTTY_RESOURCES_DIR`, or clear it when the resources are missing. Returns the
  /// resolved tree so the caller can keep validating inside it.
  @discardableResult
  static func exportResourcesDir() -> URL? {
    guard let url = bundledURL else {
      unsetenv("GHOSTTY_RESOURCES_DIR")
      return nil
    }
    setenv("GHOSTTY_RESOURCES_DIR", url.path, 1)
    return url
  }
}
