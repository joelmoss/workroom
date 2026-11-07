import Observation

/// How many times what a read observed has changed. Observation calls `onChange` synchronously on
/// the writing thread, which in these tests is the main actor running them, so the unchecked
/// count is never touched concurrently.
final class ChangeCount: @unchecked Sendable {
  private(set) var value = 0

  /// Count the next change to whatever `read` reads (Observation reports one change per watch).
  func watch(_ read: () -> Void) {
    withObservationTracking(read) { [self] in value += 1 }
  }
}
