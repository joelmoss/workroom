import Observation
import Synchronization

/// Whether anything `read` read has changed since `observeChange(_:)` tracked it. Observation
/// calls its `onChange` as a `@Sendable` closure, which cannot set a test's captured `var`.
final class ObservedChange: Sendable {
  private let fired = Mutex(false)

  var happened: Bool { fired.withLock { $0 } }

  fileprivate func fire() { fired.withLock { $0 = true } }
}

/// Tracks the observable properties `read` reads; the result turns true at the first write to any
/// of them, as `withObservationTracking`'s `onChange` does (once).
func observeChange(_ read: () -> Void) -> ObservedChange {
  let change = ObservedChange()
  withObservationTracking(read) { change.fire() }
  return change
}
