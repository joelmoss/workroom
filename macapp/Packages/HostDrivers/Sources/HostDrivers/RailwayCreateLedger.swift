import Foundation

/// This Mac's Railway creates (ADR 0071's amendment): the only sandboxes the launch sweep may
/// destroy. A sandbox has no name or label, and an environment can be shared by more than one Mac
/// (a `placement.json` copied by Migration Assistant or a Time Machine restore), so "in this Mac's
/// environment and named by no record" is not enough to call a sandbox this Mac's: another Mac's
/// live host reads exactly so. A create writes its intent here before it asks Railway for a
/// sandbox, and fills in the sandbox's id when Railway answers; recording the host (its config
/// write), destroying it, or sweeping it takes the entry off.
///
/// Kept beside the Mac's Railway key (`Configuration.keys`), so Release and Nightly, which share
/// the environment and config (ADR 0036), share it too. Every read-modify-write holds a `flock` on
/// a lock file beside it (`CrossProcessLock`), so the two apps never lose each other's entries.
public struct RailwayCreateLedger: Sendable {
  /// One create: when it began, and the sandbox Railway named, once it did.
  public struct Entry: Codable, Equatable, Sendable {
    public var intent: UUID
    public var started: Date
    public var sandbox: String?

    public init(intent: UUID = UUID(), started: Date, sandbox: String? = nil) {
      self.intent = intent
      self.started = started
      self.sandbox = sandbox
    }
  }

  public let directory: URL

  public init(directory: URL) { self.directory = directory }

  var file: URL { directory.appendingPathComponent("create-ledger.json") }
  var lockFile: URL { directory.appendingPathComponent("create-ledger.lock") }

  /// Every entry. A ledger that can't be read is set aside (`create-ledger.json.unreadable`) and
  /// reads as empty: losing track of a sandbox leaves it billing, which the user can see on
  /// Railway's dashboard, where reading another Mac's for this one's would destroy it.
  public func entries() async throws -> [Entry] {
    try await update { _ in }
  }

  /// Writes a new create's intent, started `now`, before anything is made: a create whose intent
  /// can't be written makes no sandbox, since no sweep would ever account for it.
  public func begin(now: Date = Date()) async throws -> UUID {
    let entry = Entry(started: now)
    try await update { $0.append(entry) }
    return entry.intent
  }

  /// Fills in the sandbox Railway made for `intent`.
  public func name(_ intent: UUID, sandbox: String) async throws {
    try await update { entries in
      for index in entries.indices where entries[index].intent == intent {
        entries[index].sandbox = sandbox
      }
    }
  }

  /// Takes `intents` off.
  public func drop(_ intents: Set<UUID>) async throws {
    guard !intents.isEmpty else { return }
    try await update { $0.removeAll { intents.contains($0.intent) } }
  }

  /// Takes off every entry naming one of `sandboxes`.
  public func forget(_ sandboxes: Set<String>) async throws {
    guard !sandboxes.isEmpty else { return }
    try await update { $0.removeAll { $0.sandbox.map(sandboxes.contains) ?? false } }
  }

  /// Reads, changes and writes the ledger under the cross-process lock, and returns what it
  /// wrote. An empty ledger has no file.
  @discardableResult
  public func update(_ change: (inout [Entry]) -> Void) async throws -> [Entry] {
    try await CrossProcessLock(path: lockFile).withLock {
      let before = read()
      var entries = before
      change(&entries)
      guard entries != before else { return entries }
      if entries.isEmpty {
        try? FileManager.default.removeItem(at: file)
      } else {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try Self.encoder.encode(entries).write(to: file, options: .atomic)
      }
      return entries
    }
  }

  private func read() -> [Entry] {
    guard let data = try? Data(contentsOf: file) else { return [] }
    guard let entries = try? Self.decoder.decode([Entry].self, from: data) else {
      let aside = file.appendingPathExtension("unreadable")
      try? FileManager.default.removeItem(at: aside)
      try? FileManager.default.moveItem(at: file, to: aside)
      return []
    }
    return entries
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
