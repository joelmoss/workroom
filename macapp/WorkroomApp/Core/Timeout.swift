import Foundation

/// Thrown by `withTimeout` when the operation outruns its deadline.
struct VCSTimeoutError: Error {}

/// Run `operation`, throwing `VCSTimeoutError` if it doesn't finish within `seconds`. The losing
/// child task is cancelled.
///
/// This is the timeout seam the VCS resolvers (`BranchResolver`, `WorkroomStatusResolver`) rely on
/// now that their reads go through `VCSProviding` — which, unlike the old CLI command-runners, has
/// no built-in per-call timeout/kill. Caveat: an in-flight *synchronous* backend read (libgit2 /
/// jj-lib over UniFFI) can't be interrupted mid-call, so on timeout its detached task keeps running
/// to completion but its result is abandoned. That still delivers the resolvers' contract — one
/// wedged repo abandons only its own row and never blocks the others — because the caller gets the
/// timeout promptly and moves on.
func withTimeout<T: Sendable>(
  seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
      throw VCSTimeoutError()
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}

/// Run a synchronous, blocking closure OFF the Swift cooperative thread pool — on GCD's global queue,
/// whose threads grow on demand.
///
/// The VCS backends' reads (jj-lib over UniFFI, libgit2) block their thread for the whole call. Run
/// on the cooperative pool (`Task.detached`), a burst of them — e.g. the per-workroom status
/// snapshots fanned out on selection (`refreshWorkroomStatuses`' task group) — saturates its fixed
/// width (≈ core count) and starves any other blocking read queued behind it. That's the "History
/// pane loads forever" bug: its read waited behind the status burst until the pool drained (a tab
/// switch just bought it time). GCD hands each read a thread immediately, so they don't starve.
///
/// Like `withTimeout`'s detached read, the call can't be cancelled mid-flight; a cancelled caller
/// just abandons the result once the closure returns.
func runBlocking<T: Sendable>(
  qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global(qos: qos).async {
      continuation.resume(with: Result(catching: work))
    }
  }
}
