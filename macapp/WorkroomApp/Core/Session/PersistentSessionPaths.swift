import Darwin
import Foundation

/// Secure locations for the session helper's unix socket and the bundled helper itself.
///
/// Primary: Application Support (per bundle id, so Dev/Nightly/Release never share sessions — nor
/// do two workrooms' Dev builds, which `make` gives distinct ids, `Scripts/dev-identity.sh`).
/// Fallback: `/tmp/workroom-<uid>` when the preferred path exceeds `sun_path` or can't be made.
///
/// Everything here takes a `SessionBackend` explicitly, with no default, because there is no such
/// thing as "the" backend: during the migration the Swift helper still owns the sessions it
/// created while the daemon owns the new ones, and which helper a path belongs to is a property of
/// the SESSION. A default here would silently answer for the wrong one.
///
/// The two must never meet — distinct binaries and, more importantly, distinct socket names, so
/// neither can end up bound to the other's socket.
enum PersistentSessionPaths {
  /// The Swift helper's socket name, kept as-is so an installed build's existing sessions are
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

  /// The Linux daemon the app bundles for `architecture` (`uname -m` on the host: `aarch64` or
  /// `x86_64`), for pushing to a remote host (`DaemonBootstrap`, #231). Put in
  /// `Contents/Resources` by `build-daemon.sh`, sealed as a resource rather than codesigned. Nil
  /// only for a bundle missing that file.
  static func linuxDaemonURL(architecture: String) -> URL? {
    guard
      let url = Bundle.main.resourceURL?.appendingPathComponent(
        "workroomd-linux-\(architecture)"),
      FileManager.default.isReadableFile(atPath: url.path)
    else { return nil }
    return url
  }

  /// Where `backend`'s socket is, for every caller that connects to it or starts one there. For the
  /// daemon that is wherever one already answers, under either name (`daemonSocket`); for the
  /// legacy helper it is its one fixed path.
  static func resolveSocketPath(
    fileManager: FileManager = .default,
    backend: SessionBackend
  ) throws -> String {
    if let directory = UITestFixture.liveDaemonDirectory {
      try prepareDirectory(URL(fileURLWithPath: directory), fileManager: fileManager)
      return directory + "/" + backend.socketFileName
    }
    if backend == .daemon {
      return try daemonSocket(fileManager: fileManager).path
    }
    if let preferred = try? preferredSocketPath(fileManager: fileManager, backend: backend),
      preferred.utf8.count < sunPathLimit
    {
      return preferred
    }
    return try fallbackSocketPath(fileManager: fileManager, backend: backend)
  }

  /// The daemon's socket: `live` is one that answers, if any does, and `path` is where to connect
  /// or start one.
  struct DaemonSocket: Equatable {
    var live: String?
    var path: String
  }

  /// The daemon socket on this Mac, from its two directories (`daemonSocket(preferredDirectory:…)`).
  static func daemonSocket(fileManager: FileManager = .default) throws -> DaemonSocket {
    if let directory = UITestFixture.liveDaemonDirectory {
      let path = directory + "/" + SessionBackend.daemon.socketFileName
      return DaemonSocket(live: isLive(path) ? path : nil, path: path)
    }
    // Either directory may be unusable, as `resolveSocketPath` has always allowed: Application
    // Support that can't be made falls back to /tmp, where a daemon may already be, and a /tmp
    // folder another user owns matters only when Application Support's path is too long.
    let preferred = try?
      (preferredSocketPath(fileManager: fileManager, backend: .daemon) as NSString)
      .deletingLastPathComponent
    let fallback: String?
    do {
      fallback = try (fallbackSocketPath(fileManager: fileManager, backend: .daemon) as NSString)
        .deletingLastPathComponent
    } catch {
      guard let preferred,
        (preferred + "/" + SessionBackend.daemon.socketFileName).utf8.count < sunPathLimit
      else { throw error }
      fallback = nil
    }
    return daemonSocket(
      preferredDirectory: preferred, fallbackDirectory: fallback, answers: isLive)
  }

  /// The daemon was `wr-agent` on `agent.sock` until #525, and a stable user's running daemon keeps
  /// that name until it exits: a hand-off keeps its argv, lock and log, so nothing renames it in
  /// place (eng review D4). So the daemon is looked for under both names, in both directories (a
  /// longer name can push the Application Support path past `sun_path`, which moves a NEW daemon to
  /// the fallback while the running one stays put), and found by whether it answers, not whether
  /// its file exists: a crash or reboot leaves the file behind, and starting on a dead old name
  /// would keep that name forever. With nothing answering, a new daemon starts on the new name, in
  /// the directory `resolveSocketPath` has always picked. At least one directory is given (the
  /// caller throws otherwise). The old name goes with #526.
  static func daemonSocket(
    preferredDirectory: String?, fallbackDirectory: String?, answers: (String) -> Bool
  ) -> DaemonSocket {
    func fits(_ path: String) -> Bool { path.utf8.count < sunPathLimit }
    let name = SessionBackend.daemon.socketFileName
    let newPreferred = preferredDirectory.map { $0 + "/" + name }
    let newFallback = fallbackDirectory.map { $0 + "/" + name }
    let standard =
      newPreferred.flatMap { fits($0) ? $0 : nil } ?? newFallback ?? newPreferred ?? name
    let candidates =
      [standard] + [newFallback].compactMap { $0 }
      + [preferredDirectory, fallbackDirectory].compactMap { $0 }
      .map { $0 + "/" + SessionBackend.formerDaemonSocket }
    let live = candidates.filter(fits).first(where: answers)
    return DaemonSocket(live: live, path: live ?? standard)
  }

  /// Whether a daemon is on `path`: it answers, or, under the old name, it holds its single-instance
  /// lock (`serve.rs`). The lock covers a v2.1.0 daemon too busy to accept: a full backlog refuses a
  /// connect, and taking that for "gone" would start a second daemon under the new name beside one
  /// holding terminals. Only the old name: no daemon starts on it any more, so the probe's moment
  /// on the lock can't make a starting one think another holds it. Under the new name the daemon's
  /// own lock already keeps a second one out.
  static func isLive(_ path: String) -> Bool {
    answers(path)
      || ((path as NSString).lastPathComponent == SessionBackend.formerDaemonSocket
        && holdsLock(path))
  }

  /// Whether a daemon holds the lock beside `path` (`<name>.lock`, the daemon's
  /// `socket.with_extension("lock")`), which it keeps for as long as it runs. A shared lock tried
  /// and given straight back: it never blocks, and refused means an exclusive holder.
  static func holdsLock(_ path: String) -> Bool {
    let lock = (path as NSString).deletingPathExtension + ".lock"
    let descriptor = open(lock, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
    flock(descriptor, LOCK_UN)
    return false
  }

  /// Whether a daemon is listening on `path`: a unix `connect` succeeds. A socket file nothing
  /// listens on is refused, and a missing one is not found; neither answers.
  static func answers(_ path: String) -> Bool {
    guard var address = PersistentSessionControlClient.address(for: path) else { return false }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
      }
    }
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
  /// `/tmp` socket and fight over the same helper whenever any of them falls back to this path.
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
