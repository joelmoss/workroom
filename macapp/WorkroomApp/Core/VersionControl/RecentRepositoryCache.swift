import Foundation

/// The last-known reads of the few repositories followed most recently (#803, QA round 2): what a
/// revisit shows at once while its fresh read runs in the background, so going back to a terminal
/// never flashes "Checking…" or "Loading history…". Keyed by canonical root; the least recently
/// used entry goes first once `capacity` is reached.
///
/// Data only, never a standing: an entry is no hold, registration or watch, so nothing is ever
/// written through it. Writes still address the live registration (`VCSStatusService.writeLocation`).
struct RecentRepositoryCache<Value> {
  /// How many repositories it remembers.
  let capacity: Int
  /// Least recently used first.
  private(set) var keys: [String] = []
  private var values: [String: Value] = [:]

  init(capacity: Int = 8) {
    self.capacity = max(1, capacity)
  }

  /// `key`'s entry, now the most recently used.
  mutating func value(for key: String) -> Value? {
    guard let value = values[key] else { return nil }
    touch(key)
    return value
  }

  /// Remember `value` for `key`, as the most recently used, dropping the least recently used
  /// beyond `capacity`.
  mutating func store(_ value: Value, for key: String) {
    values[key] = value
    touch(key)
    while keys.count > capacity { values[keys.removeFirst()] = nil }
  }

  /// Forget `key`.
  mutating func remove(_ key: String) {
    values[key] = nil
    keys.removeAll { $0 == key }
  }

  private mutating func touch(_ key: String) {
    keys.removeAll { $0 == key }
    keys.append(key)
  }
}
