import CryptoKit
import Darwin
import Foundation

/// A short, private socket namespace for this app launch's SSH control exchanges. It never
/// discovers or joins a master from the user's ssh configuration or another app process.
struct SSHControlConnection: Sendable {
  private static let launchDirectory = URL(
    fileURLWithPath:
      "/tmp/wrssh-\(getuid())-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))",
    isDirectory: true)

  let root: URL
  let directory: URL

  init(namespace: String, root: URL = launchDirectory) {
    self.root = root
    let hash = SHA256.hash(data: Data(namespace.utf8))
      .map { String(format: "%02x", $0) }.joined()
    directory = root.appendingPathComponent(String(hash.prefix(10)), isDirectory: true)
  }

  var path: String { directory.appendingPathComponent("%C").path }

  func options() throws -> [String] {
    // %C is OpenSSH's hash of the resolved peer. Reserve its 40 bytes and the random suffix
    // OpenSSH appends while binding, rather than discovering a long path after authentication.
    guard path.utf8.count - 2 + 40 + 17 < 104 else {
      throw HostDriverError.invalidConfiguration("the private SSH socket path is too long")
    }
    try prepare(root)
    try prepare(directory)
    return [
      "-o", "ControlMaster=auto", "-o", "ControlPersist=60", "-o", "ControlPath=\(path)",
    ]
  }

  private func prepare(_ url: URL) throws {
    let files = FileManager.default
    do {
      try files.createDirectory(
        at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    } catch {
      // Another exchange may have created the same launch directory. Validate what exists;
      // never follow a symlink or repair a directory other users could already have written.
      guard files.fileExists(atPath: url.path) else { throw error }
    }
    let attributes = try files.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
      let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
      permissions & 0o077 == 0
    else {
      throw HostDriverError.invalidConfiguration("the private SSH folder is not secure")
    }
  }
}
