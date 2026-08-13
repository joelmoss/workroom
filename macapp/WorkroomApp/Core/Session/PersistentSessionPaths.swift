import Darwin
import Foundation

/// Secure locations for the workroom-session unix socket and the bundled helper.
///
/// Primary: Application Support (per bundle id, so Dev/Nightly/Release never share sessions).
/// Fallback: `/tmp/workroom-<uid>` only when the preferred path exceeds `sun_path`.
enum PersistentSessionPaths {
  static let socketFileName = "session.sock"
  static let sunPathLimit = 104

  enum PathError: Error, Equatable {
    case directoryUnavailable
    case insecureFallbackDirectory
  }

  static func binaryURL() -> URL? {
    let candidates = [
      Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/workroom-session"),
      Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(
        "workroom-session"),
    ]
    return candidates.compactMap { $0 }.first {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
  }

  static func resolveSocketPath(fileManager: FileManager = .default) throws -> String {
    if let preferred = try? preferredSocketPath(fileManager: fileManager),
      preferred.utf8.count < sunPathLimit
    {
      return preferred
    }
    return try fallbackSocketPath(fileManager: fileManager)
  }

  static func preferredSocketPath(fileManager: FileManager = .default) throws -> String {
    let support = try fileManager.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let bundle = Bundle.main.bundleIdentifier ?? "com.developwithstyle.workroom"
    let directory = support.appendingPathComponent(bundle, isDirectory: true)
      .appendingPathComponent("sessions", isDirectory: true)
    try prepareDirectory(directory, fileManager: fileManager)
    return directory.appendingPathComponent(socketFileName).path
  }

  static func fallbackSocketPath(userID: uid_t = getuid(), fileManager: FileManager = .default)
    throws -> String
  {
    let directory = URL(fileURLWithPath: "/tmp/workroom-\(userID)", isDirectory: true)
    try prepareFallbackDirectory(directory, fileManager: fileManager)
    return directory.appendingPathComponent(socketFileName).path
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
