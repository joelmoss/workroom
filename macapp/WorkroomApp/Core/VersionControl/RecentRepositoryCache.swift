import Foundation

/// The last-known reads of the few repositories followed most recently (#803, QA round 2): what a
/// revisit shows at once while its fresh read runs in the background, so going back to a terminal
/// never flashes "Checking…" or "Loading history…". Keyed by canonical root.
///
/// Data only, never a standing: an entry is no hold, registration or watch, so nothing is ever
/// written through it. Writes still address the live registration (`VCSStatusService.writeLocation`).
typealias RecentRepositoryCache<Value> = RecentCache<String, Value>

/// A bounded memory of the entries used most recently: once `capacity` is reached, the least
/// recently used goes first. What bounds the per-window memories a long session would otherwise grow
/// without end (#812 F7): the folders a window resolved, their expansion and scroll, and the
/// repositories it followed lately.
///
/// Reading or writing an entry makes it the most recently used, in O(1): a scroll writes its offset
/// every frame. Only an insert past `capacity` scans, to find the entry to drop.
struct RecentCache<Key: Hashable, Value> {
  /// How many entries it remembers.
  let capacity: Int
  /// What `store` keeps of a value: all of it by default. A cache that keeps a revisit's first
  /// paint can keep less than the live value holds (`WorkroomStatus.recalled`).
  private let prepare: (Value) -> Value
  private var entries: [Key: (value: Value, used: UInt64)] = [:]
  private var clock: UInt64 = 0

  init(capacity: Int = 8, prepare: @escaping (Value) -> Value = { $0 }) {
    self.capacity = max(1, capacity)
    self.prepare = prepare
  }

  /// Least recently used first.
  var keys: [Key] { entries.sorted { $0.value.used < $1.value.used }.map(\.key) }

  var count: Int { entries.count }

  /// `key`'s entry, now the most recently used.
  mutating func value(for key: Key) -> Value? {
    guard let entry = entries[key] else { return nil }
    clock += 1
    entries[key] = (entry.value, clock)
    return entry.value
  }

  /// Remember `value` for `key`, as the most recently used, dropping the least recently used
  /// beyond `capacity`.
  mutating func store(_ value: Value, for key: Key) {
    clock += 1
    let isNew = entries.updateValue((prepare(value), clock), forKey: key) == nil
    guard isNew, entries.count > capacity,
      let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key
    else { return }
    entries[oldest] = nil
  }

  /// Forget `key`.
  mutating func remove(_ key: Key) { entries[key] = nil }

  /// Forget every entry `shouldRemove` matches.
  mutating func removeAll(where shouldRemove: (Key, Value) -> Bool) {
    entries = entries.filter { !shouldRemove($0.key, $0.value.value) }
  }

  /// Dictionary-style access: a read is a use, as `value(for:)` is; writing nil forgets.
  subscript(key: Key) -> Value? {
    mutating get { value(for: key) }
    set {
      if let newValue { store(newValue, for: key) } else { remove(key) }
    }
  }
}
