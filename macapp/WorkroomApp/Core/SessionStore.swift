import Foundation
import OSLog

/// Reads and writes the saved session (issue #46) — the file behind `SessionSnapshot`.
///
/// **Every operation is best-effort.** The app must behave identically with the file absent, empty,
/// unreadable, or corrupt: a session that fails to load is a launch with no restore, never an error
/// the user sees. Failures log and are swallowed.
///
/// The URL is injectable so unit tests point at a temp directory — which also keeps the whole
/// feature clear of `Defaults`, and therefore clear of the single-writer rule parallel test workers
/// impose on a shared UserDefaults domain (`SharedPrefDefaultsTests`).
final class SessionStore {
  /// Where the file lives, **scoped by bundle id**.
  ///
  /// The scoping is mandatory, not tidiness: `GhosttyApp` already writes into
  /// `Application Support/Workroom/` from all three identities (Workroom, Workroom Dev, Workroom
  /// Nightly), so an unscoped path would let a Dev run's fixture temp-dir workrooms be restored into
  /// the release build. UserDefaults gets that separation free from the bundle id; a file has to buy
  /// it back.
  static func defaultURL(
    bundleID: String? = Bundle.main.bundleIdentifier,
    fileManager: FileManager = .default
  ) -> URL {
    let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Workroom", isDirectory: true)
      .appendingPathComponent(bundleID ?? "com.developwithstyle.workroom", isDirectory: true)
    return root.appendingPathComponent("session.json")
  }

  /// The store production and the UI tests should use.
  ///
  /// In fixture mode this is a **no-op unless a test names a file**. The path is bundle-id scoped, so
  /// a fixture launch would otherwise write over the developer's own `Workroom Dev` session — and the
  /// fixture's temp-directory workrooms would then be restored into a real launch.
  static func forCurrentEnvironment() -> SessionStore {
    // Unit tests inject their own store, but `AppStore.markSessionDirty` reaches the SHARED
    // coordinator — so without this a `make app-test` run writes the developer's own `Workroom Dev`
    // session file and scrollback sidecars as a side effect of exercising tab mutations. Same
    // isolation the app already applies at `WorkroomApp.swift:42` and `AppStore.swift:750`.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
      UITestFixture.sessionFilePath == nil
    {
      return SessionStore(url: SessionStore.defaultURL(), isDisabled: true)
    }
    guard UITestFixture.isActive else { return SessionStore() }
    guard let path = UITestFixture.sessionFilePath else {
      return SessionStore(url: SessionStore.defaultURL(), isDisabled: true)
    }
    return SessionStore(url: URL(fileURLWithPath: path))
  }

  let url: URL
  /// A disabled store reads nothing and writes nothing — fixture mode without a named session file.
  private let isDisabled: Bool
  /// Where an undecodable file is moved once, so a bug report has something to attach instead of the
  /// evidence being deleted.
  var quarantineURL: URL {
    url.deletingLastPathComponent().appendingPathComponent("session.corrupt.json")
  }

  /// True once a file written by a NEWER schema has been read. Every write is then refused for the
  /// rest of the run — otherwise this build silently destroys a session it could not understand, and
  /// three build identities ship side by side, so that rollback is a real path rather than a
  /// hypothetical one.
  private(set) var writesDisabled = false

  private let fileManager: FileManager
  private let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "session")
  /// Encoding and the write happen here so neither runs on the main actor; only the capture does.
  private let queue = DispatchQueue(
    label: "com.developwithstyle.workroom.session", qos: .utility)

  init(
    url: URL = SessionStore.defaultURL(), fileManager: FileManager = .default,
    isDisabled: Bool = false
  ) {
    self.url = url
    self.fileManager = fileManager
    self.isDisabled = isDisabled
  }

  // MARK: Read

  enum ReadOutcome: Equatable {
    /// Nothing usable — a fresh install, an unreadable file, or one this build cannot decode. The
    /// caller falls back to its cold-start path.
    case none
    case restored(SessionFile, SessionSanitizeReport)
    /// Written by a newer build: restore nothing, and `writesDisabled` is now true.
    case newerSchema

    static func == (lhs: ReadOutcome, rhs: ReadOutcome) -> Bool {
      switch (lhs, rhs) {
      case (.none, .none), (.newerSchema, .newerSchema): return true
      case (.restored(let lf, let lr), .restored(let rf, let rr)):
        return lf.windows == rf.windows && lf.schemaVersion == rf.schemaVersion && lr == rr
      default: return false
      }
    }
  }

  func read() -> ReadOutcome {
    guard !isDisabled, fileManager.fileExists(atPath: url.path) else { return .none }

    // Refused BEFORE decoding: the element caps in `SessionLimits` bound how many things a file
    // describes, not how many bytes one of them spends.
    if let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int,
      size > SessionLimits.maxFileBytes
    {
      logger.error("session file is \(size) bytes, over the limit — quarantining")
      quarantine()
      return .none
    }

    guard let data = try? Data(contentsOf: url) else {
      logger.error("session file unreadable")
      return .none
    }
    guard !data.isEmpty else { return .none }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let file = try? decoder.decode(SessionFile.self, from: data) else {
      logger.error("session file could not be decoded — quarantining")
      quarantine()
      return .none
    }

    switch file.compatibility {
    case .newer:
      let message =
        "session file schema \(file.schemaVersion) is newer than "
        + "\(SessionFile.currentSchemaVersion) — not restoring, writes disabled for this run"
      logger.notice("\(message, privacy: .public)")
      writesDisabled = true
      return .newerSchema
    case .unreadable:
      logger.notice("session file schema \(file.schemaVersion) has no migration — discarding")
      return .none
    case .current:
      break
    }

    let (sanitized, report) = file.sanitized()
    if !report.isEmpty {
      logger.notice("session file dropped entries — \(report.summary, privacy: .public)")
    }
    // A file whose windows all dropped is not a session. Saying so lets the caller take its
    // cold-start fallback instead of launching emptier than deleting the file would have.
    guard !sanitized.windows.isEmpty else { return .none }
    return .restored(sanitized, report)
  }

  // MARK: Write

  /// Persist off the main actor. Coalescing is the caller's job (see `AppStore+Session`).
  ///
  /// `completion` reports on the main actor whether the bytes actually reached disk. The caller needs
  /// it: it gates a write on "did this change since last time?", and treating a failed write as
  /// written would suppress every retry of the same state until something else changed.
  func write(_ file: SessionFile, completion: (@MainActor (Bool) -> Void)? = nil) {
    guard !isDisabled, !writesDisabled else {
      if let completion {
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(false) } }
      }
      return
    }
    queue.async { [weak self] in
      let ok = self?.persist(file) ?? false
      guard let completion else { return }
      DispatchQueue.main.async { MainActor.assumeIsolated { completion(ok) } }
    }
  }

  /// Persist before returning — the quit path, where the process may not survive long enough for an
  /// async write to land.
  @discardableResult
  func writeSynchronously(_ file: SessionFile) -> Bool {
    guard !isDisabled, !writesDisabled else { return false }
    return queue.sync { self.persist(file) }
  }

  func clear() {
    guard !isDisabled else { return }
    queue.sync { try? self.fileManager.removeItem(at: self.url) }
  }

  // MARK: Scrollback sidecars (issue #144)

  /// One plain-text file per pane, beside `session.json`. Deliberately NOT inside it: that document
  /// is rewritten on every coalesced save, and a few hundred KB of terminal output per pane has no
  /// business riding along with the layout.
  var scrollbackDirectory: URL {
    url.deletingLastPathComponent().appendingPathComponent("scrollback", isDirectory: true)
  }

  /// Rejects a key that could address anything outside the scrollback directory.
  ///
  /// The keys this app writes are `TabSession.key` UUID strings, which are filesystem-safe by
  /// construction — but `session.json` is a plain file a user (or anything running as them) can edit,
  /// and `URL.appendingPathComponent` does **not** normalise: a key of `../../../x` yields a path
  /// that escapes on access (measured). Since `readScrollback` *deletes* a file that fails
  /// validation, an unchecked key is an arbitrary-file-delete primitive at launch.
  ///
  /// A separator check rather than a strict UUID match, so the rule bites the actual hazard without
  /// making the key format part of the on-disk contract.
  nonisolated static func isSafeScrollbackKey(_ key: String) -> Bool {
    guard !key.isEmpty, key.count <= 128, !key.hasPrefix(".") else { return false }
    return !key.contains("/") && !key.contains(":") && !key.contains("\0")
  }

  private func scrollbackURL(forTabKey key: String) -> URL? {
    guard Self.isSafeScrollbackKey(key) else {
      logger.error("refusing an unsafe scrollback key")
      return nil
    }
    return scrollbackDirectory.appendingPathComponent("\(key).txt")
  }

  func writeScrollback(_ text: String, forTabKey key: String) {
    guard !isDisabled, !writesDisabled, !text.isEmpty else { return }
    guard let fileURL = scrollbackURL(forTabKey: key) else { return }
    do {
      // Owner-only, on the directory as well as the file: a sidecar is verbatim terminal output, so
      // it can hold whatever the user's shell printed — tokens, `env` dumps, connection strings. The
      // default 0644 would leave that readable by every other account on the machine.
      try fileManager.createDirectory(
        at: scrollbackDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try Data(text.utf8).write(to: fileURL, options: .atomic)
      // `.atomic` writes a temp file and renames, so the mode has to be set after the rename.
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      // Best-effort like everything else here: a pane with no sidecar simply restores empty.
      logger.error("scrollback write failed: \(error.localizedDescription)")
    }
  }

  /// The saved text for a pane, or nil when there is none, it is unreadable, or it fails validation.
  ///
  /// A file that fails validation is **deleted**: it would fail identically on every future launch,
  /// and unlike `session.json` a scrollback sidecar has no diagnostic value worth quarantining.
  func readScrollback(forTabKey key: String) -> String? {
    guard !isDisabled, let fileURL = scrollbackURL(forTabKey: key) else { return nil }
    guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

    if let size = try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
      size > SessionLimits.maxScrollbackFileBytes
    {
      logger.notice("scrollback sidecar is \(size) bytes, over the limit — discarding")
      try? fileManager.removeItem(at: fileURL)
      return nil
    }
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    guard let text = String(data: data, encoding: .utf8) else {
      logger.notice("scrollback sidecar is not valid UTF-8 — discarding")
      try? fileManager.removeItem(at: fileURL)
      return nil
    }
    let cleaned = Self.strippingControlBytes(text)
    return cleaned.isEmpty ? nil : cleaned
  }

  /// Drop sidecars for panes that are no longer in the session.
  ///
  /// Runs once after the write pass, unconditionally — including when every write failed. A pane
  /// whose capture is now empty wrote no sidecar, so its old one is removed here and yesterday's
  /// output cannot reappear under today's empty pane.
  func pruneScrollback(keeping keys: Set<String>) {
    guard !isDisabled else { return }
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: scrollbackDirectory, includingPropertiesForKeys: nil)
    else { return }
    for entry in entries where entry.pathExtension == "txt" {
      let key = entry.deletingPathExtension().lastPathComponent
      if !keys.contains(key) { try? fileManager.removeItem(at: entry) }
    }
  }

  /// Remove C0 control bytes except newline, carriage return and tab.
  ///
  /// The captured text is rendered output, never raw PTY bytes, so it carries no escape sequences to
  /// begin with. This exists so a hand-edited sidecar cannot inject one and leave the parser
  /// mid-sequence on replay. CR is kept: the divider is CRLF.
  nonisolated static func strippingControlBytes(_ text: String) -> String {
    String(
      text.unicodeScalars.filter { scalar in
        scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar.value >= 0x20
      })
  }

  @discardableResult
  private func persist(_ file: SessionFile) -> Bool {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // Readable and diff-stable on purpose: "delete this file and relaunch" is a support instruction
    // a user can follow, and the file is something a bug report can usefully attach.
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    guard let data = try? encoder.encode(file) else {
      logger.error("session snapshot could not be encoded")
      return false
    }
    do {
      // `Data.write(.atomic)` does NOT create intermediate directories, and the bundle-id
      // subdirectory does not exist on a first run — without this every write fails silently.
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      // Atomic: a reader sees the complete old document or the complete new one, never a partial
      // write from a process that died mid-save.
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      logger.error("session snapshot could not be written: \(error.localizedDescription)")
      return false
    }
  }

  /// Move a file this build cannot read aside — once. A prior quarantine is replaced rather than
  /// accumulating; the newest failure is the useful one.
  private func quarantine() {
    try? fileManager.removeItem(at: quarantineURL)
    do {
      try fileManager.moveItem(at: url, to: quarantineURL)
    } catch {
      // If it cannot even be moved, delete it — leaving it in place would fail the same way on
      // every launch forever.
      try? fileManager.removeItem(at: url)
    }
  }
}
