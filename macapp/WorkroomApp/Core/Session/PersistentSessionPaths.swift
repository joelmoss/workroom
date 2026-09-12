import Darwin
import Foundation

/// Secure locations for the session helper's unix socket and the bundled helper itself.
///
/// Primary: Application Support (per bundle id, so Dev/Nightly/Release never share sessions).
/// Fallback: `/tmp/workroom-<uid>` only when the preferred path exceeds `sun_path`.
///
/// Everything here takes a `SessionBackend` explicitly, with no default, because there is no such
/// thing as "the" backend: during the migration the Swift daemon still owns the sessions it
/// created while the agent owns the new ones, and which helper a path belongs to is a property of
/// the SESSION. A default here would silently answer for the wrong one.
///
/// The two must never meet — distinct binaries and, more importantly, distinct socket names, so
/// neither can end up bound to the other's socket.
enum PersistentSessionPaths {
  /// The Swift daemon's socket name, kept as-is so an installed build's existing sessions are
  /// still found after this change. `SessionBackend.socketFileName` is the general answer.
  static let socketFileName = "session.sock"
  static let sunPathLimit = 104

  enum PathError: Error, Equatable {
    case directoryUnavailable
    case insecureFallbackDirectory
  }

  static func binaryURL(for backend: SessionBackend) -> URL? {
    let name = backend.binaryName
    let candidates = [
      Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)"),
      Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
    ]
    return candidates.compactMap { $0 }.first {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
  }

  static func resolveSocketPath(
    fileManager: FileManager = .default,
    backend: SessionBackend
  ) throws -> String {
    if let preferred = try? preferredSocketPath(fileManager: fileManager, backend: backend),
      preferred.utf8.count < sunPathLimit
    {
      return preferred
    }
    return try fallbackSocketPath(fileManager: fileManager, backend: backend)
  }

  static func preferredSocketPath(
    fileManager: FileManager = .default,
    backend: SessionBackend
  ) throws -> String {
    let support = try fileManager.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let bundle = Bundle.main.bundleIdentifier ?? "com.developwithstyle.workroom"
    let directory = support.appendingPathComponent(bundle, isDirectory: true)
      .appendingPathComponent("sessions", isDirectory: true)
    try prepareDirectory(directory, fileManager: fileManager)
    return directory.appendingPathComponent(backend.socketFileName).path
  }

  /// Scoped by bundle id, same as the preferred path — the fallback only triggers when the
  /// Application Support path is too long (an unusually long username/home directory), and that
  /// length comes entirely from the username, not the bundle id, so adding it here costs nothing
  /// against `sunPathLimit`. Without it, Workroom/Workroom Dev/Workroom Nightly would share one
  /// `/tmp` socket and fight over the same daemon whenever any of them falls back to this path.
  static func fallbackSocketPath(
    userID: uid_t = getuid(),
    fileManager: FileManager = .default,
    backend: SessionBackend
  ) throws -> String {
    let bundle = Bundle.main.bundleIdentifier ?? "com.developwithstyle.workroom"
    let directory = URL(fileURLWithPath: "/tmp/workroom-\(userID)-\(bundle)", isDirectory: true)
    try prepareFallbackDirectory(directory, fileManager: fileManager)
    return directory.appendingPathComponent(backend.socketFileName).path
  }

  private static func prepareDirectory(_ url: URL, fileManager: FileManager) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
        throw PathError.directoryUnavailable
      }
      guard isDirectory.boolValue else { throw PathError.directoryUnavailable }
    } else {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private static func prepareFallbackDirectory(_ url: URL, fileManager: FileManager) throws {
    if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
      throw PathError.insecureFallbackDirectory
    }
    try prepareDirectory(url, fileManager: fileManager)
  }
}
