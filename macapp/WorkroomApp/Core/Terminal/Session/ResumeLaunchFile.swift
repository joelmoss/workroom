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
/// does. The proof that the folder is this code's is its `marker`, which only the write that made
/// the folder writes, new: a folder found already there (another build's, or a user's of the
/// same name) never gets one, so nothing in it is ever swept, though files are still written
/// there. In a marked folder, one no relay claimed (its pane never started) is removed at a later
/// write once it is an hour old, which no relay waits; only regular files, judged without
/// following a link, as the marker is.
enum ResumeLaunchFile {
  /// The variable the relay reads the file's path from (`resume::launch::APP_FILE_VARIABLE`).
  static let variable = "WORKROOM_SESSION_RESUME"
  /// How old an unclaimed file must be before a later write removes it.
  static let abandoned: TimeInterval = 60 * 60
  /// The file the folder holds when this code made it, and only then: its proof that the launch
  /// files in it are this code's to remove (`sweep`). The daemon's own folder holds the same one
  /// (`resume::launch::MARKER`).
  static let marker = ".workroom-resume-launch-folder"
  /// What `marker` holds, which nothing else writes.
  static let markerContents = Data(
    "Workroom made this folder for its resume launch files (ADR 0082), and removes only those.\n"
      .utf8)

  /// The folder beside the daemon socket at `socketPath`.
  static func directory(socketPath: String) -> URL {
    URL(fileURLWithPath: socketPath).deletingLastPathComponent()
      .appendingPathComponent("resume-launch", isDirectory: true)
  }

  /// Writes `record` for `sessionID`'s relay into `directory`, readable by this user alone from
  /// its first byte. It runs in the record's folder, else, for a record that names none, in
  /// `savedFolder`, the pane's own (ADR 0082). Its path, or nil, and nothing written, when that
  /// folder is gone (no resume) or the file can't be made. `onThisMac` false for a remote pane's
  /// record (#826), whose folder is a path on its host: the host's daemon checks it there.
  static func write(
    _ record: ResumeRecord, for sessionID: UUID, savedFolder: String, in directory: URL,
    onThisMac: Bool = true
  ) -> String? {
    guard record.isWellFormed else { return nil }
    let cwd = record.cwd.flatMap { $0.isEmpty ? nil : $0 } ?? savedFolder
    var isDirectory: ObjCBool = false
    guard !cwd.isEmpty,
      !onThisMac
        || (FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory)
          && isDirectory.boolValue),
      makePrivate(directory),
      let data = contents(of: record, cwd: cwd)
    else { return nil }
    sweep(directory, olderThan: abandoned)
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

  /// What a file holds for `record`, to run in `cwd`: the relay's `resume::launch` reads it, and
  /// `testdata/resume-launch` holds one as this writes it, which the daemon's tests read. Its keys
  /// sorted and its slashes unescaped, so the same record is always the same bytes.
  static func contents(of record: ResumeRecord, cwd: String) -> Data? {
    let payload: [String: Any] = [
      "argv": record.argv, "cwd": cwd, "reportedAt": record.reportedAt,
    ]
    return try? JSONSerialization.data(
      withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
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

  /// Makes `directory` this user's alone: `0700` when new, and given its `marker`; an existing one
  /// must be a real folder this user owns, which is then tightened, and is never marked.
  private static func makePrivate(_ directory: URL) -> Bool {
    let path = directory.path
    let made = mkdir(path, 0o700) == 0
    if !made, errno != EEXIST { return false }
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid()
    else { return false }
    guard info.st_mode & 0o077 == 0 || chmod(path, 0o700) == 0 else { return false }
    if made { writeMarker(in: directory) }
    return true
  }

  /// Writes `marker` into the folder this code just made: new (`O_EXCL`), `0600`. A folder whose
  /// marker could not be written still takes launch files: it is only never swept.
  private static func writeMarker(in directory: URL) {
    let path = directory.appendingPathComponent(marker).path
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return }
    let written = markerContents.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    close(fd)
    if written != markerContents.count { unlink(path) }
  }

  /// Whether `directory` holds `marker` as `makePrivate` writes it: a regular file this user
  /// owns, judged without following a link, holding `markerContents`.
  static func isMarked(_ directory: URL) -> Bool {
    let path = directory.appendingPathComponent(marker).path
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
      info.st_size == markerContents.count
    else { return false }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var bytes = [UInt8](repeating: 0, count: markerContents.count + 1)
    let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
    return count == markerContents.count && Data(bytes.prefix(count)) == markerContents
  }

  /// Removes the files `name(for:)` made in `directory` that are at least `age` old, in a folder
  /// this code made (`isMarked`) alone: nothing in any other is touched.
  static func sweep(_ directory: URL, olderThan age: TimeInterval) {
    guard isMarked(directory),
      let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
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
