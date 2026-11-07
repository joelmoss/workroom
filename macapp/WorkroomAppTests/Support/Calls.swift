import Synchronization

/// What a fake was called with, in order, from any thread. A test's closures are `@Sendable`, so
/// they cannot append to a captured `var`.
final class Calls<Value: Sendable>: Sendable {
  private let values = Mutex<[Value]>([])

  var all: [Value] { values.withLock { $0 } }

  func add(_ value: Value) { values.withLock { $0.append(value) } }
}

/// How many times something happened, from any thread.
final class Counter: Sendable {
  private let value = Mutex(0)

  var count: Int { value.withLock { $0 } }

  func add() { value.withLock { $0 += 1 } }

  /// Counts one more and returns the new count, for a fake that answers by attempt.
  func next() -> Int {
    value.withLock {
      $0 += 1
      return $0
    }
  }
}

/// One value, read and written from any thread.
final class Locked<Value: Sendable>: Sendable {
  private let value: Mutex<Value>

  init(_ value: Value) { self.value = Mutex(value) }

  func get() -> Value { value.withLock { $0 } }

  func set(_ newValue: Value) { value.withLock { $0 = newValue } }
}
