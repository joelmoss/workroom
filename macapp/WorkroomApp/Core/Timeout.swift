import Foundation

/// Thrown by `withTimeout` when the operation outruns its deadline.
struct VCSTimeoutError: Error {}

/// Run `operation`, throwing `VCSTimeoutError` if it doesn't finish within `seconds`. On timeout the
/// operation task is cancelled and its eventual result dropped.
///
/// This is the timeout seam the VCS resolvers (`BranchResolver`, `WorkroomStatusResolver`) rely on
/// now that their reads go through `VCSProviding` — which, unlike the old CLI command-runners, has
/// no built-in per-call timeout/kill. Caveat: an in-flight *synchronous* backend read (libgit2 /
/// jj-lib over UniFFI) can't be interrupted mid-call, so on timeout it keeps running to completion
/// on its own thread and its result is abandoned. That still delivers the resolvers' contract — one
/// wedged repo abandons only its own row and never blocks the others.
///
/// Implemented as a first-to-settle race over a single continuation, NOT a `withThrowingTaskGroup`:
/// a task group awaits ALL its children before returning, so when the deadline child wins the group
/// would still block on the (uncancellable, synchronous) operation child until it finished —
/// silently defeating the timeout for exactly the wedged-read case it exists to bound. The
/// continuation resumes the caller the instant either side settles.
func withTimeout<T: Sendable>(
  seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
    let gate = TimeoutGate(cont)
    let op = Task {
      do { gate.settle(.success(try await operation())) } catch { gate.settle(.failure(error)) }
    }
    Task {
      try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
      gate.settle(.failure(VCSTimeoutError()))
      // Best-effort: abandons the loser (uncancellable native work runs on to no effect).
      op.cancel()
    }
  }
}

/// Resumes a `withTimeout` continuation exactly once — the operation-completes vs deadline-fires race.
private final class TimeoutGate<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  private let cont: CheckedContinuation<T, Error>
  init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }
  func settle(_ result: Result<T, Error>) {
    lock.lock()
    let first = !done
    done = true
    lock.unlock()
    if first { cont.resume(with: result) }
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
