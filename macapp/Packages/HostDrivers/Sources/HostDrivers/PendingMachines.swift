import Foundation

/// Remote provider machines (boxd, exe.dev) a create began that no config record names yet (#373),
/// so a crash before config records one still leaves it named. A driver writes an entry before
/// the CLI call that makes the machine, and takes it off once it removed the machine again. The
/// create takes it off the moment a record naming it is written (`Recorder.forgettingPending`),
/// and each reload takes off any that config names (`RemoteHosts.adopt`). So an entry names only
/// a machine this build began making and config never recorded. One file beside the drivers'
/// hosts, which is this build's alone (`RemoteWorkrooms.directory` is per bundle ID).
///
/// The sweep removes only these, never every unrecorded `workroom-*` machine: the names carry no
/// build, and no config holds every build's (Release and Nightly share one, each Dev build keeps
/// its own), so a listing could not tell another build's create still under way from a leftover. A machine whose record was lost after it was written
/// is not named here and stays.
public enum PendingMachines {
  public struct Entry: Codable, Equatable, Sendable {
    public let id: UUID
    /// The host descriptor's `driver`, `org` and `account`: the driver key that removes it.
    public let driver: String
    public var org: String? = nil
    public var account: String? = nil
    /// The launch whose sweep first found it unrecorded (`launch`), or nil before any did.
    public var unrecordedIn: UUID? = nil
    /// When it was written down (`add`).
    public var made: Date? = nil

    public init(
      id: UUID, driver: String, org: String? = nil, account: String? = nil,
      unrecordedIn: UUID? = nil, made: Date? = nil
    ) {
      self.id = id
      self.driver = driver
      self.org = org
      self.account = account
      self.unrecordedIn = unrecordedIn
      self.made = made
    }
  }

  /// This launch, for the two-launch rule.
  public static let launch = UUID()
  private static let fileName = "pending-machines.json"
  private static let lock = NSLock()

  public static func entries(in directory: URL) -> [Entry] {
    lock.withLock { read(directory) }
  }

  /// Writes `entry` down, before the call that makes its machine.
  public static func add(_ entry: Entry, in directory: URL) throws {
    var entry = entry
    entry.made = entry.made ?? Date()
    try update(in: directory) { $0.append(entry) }
  }

  /// Takes `ids` off: config records their hosts now, or they are gone.
  public static func forget(_ ids: Set<UUID>, in directory: URL) {
    guard !ids.isEmpty else { return }
    try? update(in: directory) { $0.removeAll { ids.contains($0.id) } }
  }

  /// Removes, through `destroy`, those of `ids` (one driver key's unrecorded entries) that an
  /// earlier launch's sweep found unrecorded too and that were made more than `grace` ago, at
  /// most `cap`, and marks the rest for the next launch: a config that failed to read once costs
  /// nothing (#284's rule), and a create still under way in another copy of this build is never
  /// taken. Nothing goes when the marks cannot be written. Returns what failed; a machine whose
  /// removal failed stays named for the next launch, not the next reload.
  public static func sweep(
    _ ids: Set<UUID>, in directory: URL, launch: UUID = launch, now: Date = Date(),
    grace: TimeInterval = grace, cap: Int = 3, destroy: (UUID) async throws -> Void
  ) async -> [String] {
    var confirmed: [UUID] = []
    do {
      try update(in: directory) { entries in
        for index in entries.indices where ids.contains(entries[index].id) {
          let entry = entries[index]
          if let seen = entry.unrecordedIn, seen != launch {
            if entry.made.map({ now.timeIntervalSince($0) >= grace }) ?? true {
              confirmed.append(entry.id)
            }
          } else {
            entries[index].unrecordedIn = launch
          }
        }
      }
    } catch {
      return ["recording unrecorded machines: \(error.localizedDescription)"]
    }
    var failures: [String] = []
    if confirmed.count > cap {
      failures.append(
        "\(confirmed.count - cap) unrecorded machine(s) left for a later launch: at most \(cap) go"
          + " per sweep")
    }
    for id in confirmed.prefix(cap) {
      do {
        try await destroy(id)
        forget([id], in: directory)
      } catch {
        // Left named, for a later launch: signed in to another account, say.
        failures.append("machine \(id): \(error.localizedDescription)")
      }
    }
    return failures
  }

  /// How old an entry must be before it goes: longer than any create takes to record its machine
  /// (the machine and its setup; the clone comes after), so another copy of this build running at
  /// once never loses one.
  public static let grace: TimeInterval = 60 * 60

  private static func read(_ directory: URL) -> [Entry] {
    (try? JSONDecoder().decode(
      [Entry].self, from: Data(contentsOf: directory.appendingPathComponent(fileName)))) ?? []
  }

  /// Rewrites the file as `change` leaves it, removing it once it is empty.
  private static func update(in directory: URL, _ change: (inout [Entry]) -> Void) throws {
    try lock.withLock {
      let file = directory.appendingPathComponent(fileName)
      var entries = read(directory)
      let before = entries
      change(&entries)
      guard entries != before else { return }
      guard !entries.isEmpty else {
        try FileManager.default.removeItem(at: file)
        return
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
  }
}
