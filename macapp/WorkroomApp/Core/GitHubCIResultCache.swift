import Foundation

/// A cached answer retains when GitHub actually supplied it. Reapplying it must not renew the TTL.
struct CIStatusSnapshot: Sendable {
  let resolution: CIResolution
  let checkedAt: Date

  init(_ resolution: CIResolution, checkedAt: Date = Date()) {
    self.resolution = resolution
    self.checkedAt = checkedAt
  }
}

/// Completed CI facts belong to a repository/commit, not a sidebar row. Keep the existing five-minute
/// policy while still resolving HEAD on every selection, so a new commit never inherits old CI.
/// No tasks live here: each probe retains its caller's cancellation and concurrency bounds.
actor GitHubCIResultCache {
  static let defaultTTL: TimeInterval = 300
  struct Key: Hashable, Sendable {
    let repository: GitHubRepository
    let commit: String
  }

  struct Ticket: Sendable {
    let key: Key
    let revision: UUID
  }

  enum Lookup: Sendable {
    case cached(CIStatusSnapshot)
    case probe(Ticket)
  }

  private struct Entry {
    let result: CIStatusSnapshot
    let at: ContinuousClock.Instant
  }

  private let ttl: Duration
  private let now: @Sendable () -> ContinuousClock.Instant
  private var entries: [Key: Entry] = [:]
  private var active: [Key: (revision: UUID, count: Int)] = [:]

  init(
    ttl: Duration = .seconds(GitHubCIResultCache.defaultTTL),
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.ttl = ttl
    self.now = now
  }

  func lookup(repository: GitHubRepository, commit: String, force: Bool) -> Lookup {
    let key = Key(repository: repository, commit: commit)
    let instant = now()
    entries = entries.filter { $0.value.at.duration(to: instant) < ttl }
    if !force, let entry = entries[key] { return .cached(entry.result) }
    // Concurrent ordinary probes can both finish usefully. A forced refresh begins a new revision,
    // so an older in-flight answer cannot overwrite the refreshed cache when it finishes late.
    var flight = active[key] ?? (revision: UUID(), count: 0)
    if force { flight = (UUID(), 0) }
    flight.count += 1
    active[key] = flight
    return .probe(Ticket(key: key, revision: flight.revision))
  }

  @discardableResult
  func record(_ result: CIResolution, for ticket: Ticket, cancelled: Bool) -> CIStatusSnapshot {
    let snapshot = CIStatusSnapshot(result)
    guard var flight = active[ticket.key], flight.revision == ticket.revision else {
      return snapshot
    }
    flight.count -= 1
    active[ticket.key] = flight.count == 0 ? nil : flight
    guard !cancelled, result != .keepPrior else { return snapshot }
    entries[ticket.key] = Entry(result: snapshot, at: now())
    return snapshot
  }
}
