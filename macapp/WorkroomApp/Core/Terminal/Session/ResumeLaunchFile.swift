import Darwin
import Foundation

/// The file a restored pane's resume record goes to its relay in (ADR 0082, #825), when its
/// session is gone and the relay makes it again: the relay claims it (`resume::launch::claim`),
/// which removes it, and sends the record with the attach that recreates the session. A file, not
/// a variable, because a record's arguments can hold secrets and a process's environment shows in
/// process listings; only its path goes in `variable`.
///
/// **Whose files these are.** The folder is made by this code alone, `0700`, beside the daemon's
/// socket (`directory`), apart from the daemon's own launch folder. A file in it is this code's
/// when its name is `resume-<session id>-<32 hex>.json`, which `isLaunchName` checks as the relay
/// does. One no relay claimed (its pane never started) is removed at a later write once it is an
/// hour old, which no relay waits; only regular files, judged without following a link.
enum ResumeLaunchFile {
  /// The variable the relay reads the file's path from (`resume::launch::APP_FILE_VARIABLE`).
  static let variable = "WORKROOM_SESSION_RESUME"
  /// How old an unclaimed file must be before a later write removes it.
  static let abandoned: TimeInterval = 60 * 60

  /// The folder beside the daemon socket at `socketPath`.
  static func directory(socketPath: String) -> URL {
    URL(fileURLWithPath: socketPath).deletingLastPathComponent()
      .appendingPathComponent("resume-launch", isDirectory: true)
  }

  /// Writes `record` for `sessionID`'s relay into `directory`, readable by this user alone from
  /// its first byte. Its path, or nil, and nothing written, when its folder is gone (no resume,
  /// ADR 0082) or the file can't be made.
  static func write(_ record: ResumeRecord, for sessionID: UUID, in directory: URL) -> String? {
    guard let cwd = record.cwd, record.isWellFormed else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
      isDirectory.boolValue, makePrivate(directory)
    else { return nil }
    sweep(directory, olderThan: abandoned)
    let payload: [String: Any] = [
      "argv": record.argv, "cwd": cwd, "reportedAt": record.reportedAt,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    let path = directory.appendingPathComponent(name(for: sessionID)).path
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return nil }
    let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    close(fd)
    guard written == data.count else {
      unlink(path)
      return nil
    }
    return path
  }

  /// A new file's name for `sessionID`: its id lowercased and hyphenated, as the daemon writes
  /// one, and 32 random hex digits.
  static func name(for sessionID: UUID) -> String {
    let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    return "resume-\(sessionID.uuidString.lowercased())-\(nonce).json"
  }

  /// Whether `name` is one `name(for:)` makes.
  static func isLaunchName(_ name: String) -> Bool {
    guard name.hasPrefix("resume-"), name.hasSuffix(".json") else { return false }
    let stem = name.dropFirst("resume-".count).dropLast(".json".count)
    guard let dash = stem.lastIndex(of: "-") else { return false }
    let session = String(stem[..<dash])
    let nonce = stem[stem.index(after: dash)...]
    return UUID(uuidString: session)?.uuidString.lowercased() == session && nonce.count == 32
      && nonce.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }

  /// Makes `directory` this user's alone: `0700` when new; an existing one must be a real folder
  /// this user owns, which is then tightened.
  private static func makePrivate(_ directory: URL) -> Bool {
    let path = directory.path
    if mkdir(path, 0o700) != 0, errno != EEXIST { return false }
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid()
    else { return false }
    return info.st_mode & 0o077 == 0 || chmod(path, 0o700) == 0
  }

  /// Removes the files `name(for:)` made in `directory` that are at least `age` old.
  static func sweep(_ directory: URL, olderThan age: TimeInterval) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return }
    let now = Date().timeIntervalSince1970
    for name in names where isLaunchName(name) {
      let path = directory.appendingPathComponent(name).path
      var info = stat()
      guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
        now - TimeInterval(info.st_mtimespec.tv_sec) >= age
      else { continue }
      unlink(path)
    }
  }
}
