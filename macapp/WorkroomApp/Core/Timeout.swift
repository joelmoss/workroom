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
///
/// Also observes the CALLING task's own cancellation (`withTaskCancellationHandler`, the same shape
/// `JJSnapshotGate.run` uses) — without it, a caller that's cancelled from outside (e.g. a superseded
/// status sweep) still had to wait out the full race above before this could return, wasting the
/// wait's own time and, downstream of `JJSnapshotGate`, occupying that project's queue slot for
/// nothing. `onCancel` only unblocks the WAIT early, with `VCSCancellationError`; the underlying
/// synchronous native call is exactly as uncancellable as the timeout path already documents above.
func withTimeout<T: Sendable>(
  seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  let cancelBox = TimeoutCancelBox()
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
      let gate = TimeoutGate(cont)
      let op = Task {
        do { gate.settle(.success(try await operation())) } catch { gate.settle(.failure(error)) }
      }
      cancelBox.attach {
        gate.settle(.failure(VCSCancellationError()))
        op.cancel()
      }
      Task {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        gate.settle(.failure(VCSTimeoutError()))
        // Best-effort: abandons the loser (uncancellable native work runs on to no effect).
        op.cancel()
      }
    }
  } onCancel: {
    cancelBox.fire()
  }
}

/// Thrown by `withTimeout` when the CALLING task was cancelled before the operation/deadline race
/// settled on its own — distinct from `VCSTimeoutError` (the deadline actually elapsed) and from
/// Swift's own `CancellationError` (so a `catch is CancellationError` elsewhere in this seam's
/// callers can't accidentally swallow it; every caller of `withTimeout` already has explicit
/// `catch is VCSTimeoutError` handling to extend).
struct VCSCancellationError: Error {}

/// Bridges `withTaskCancellationHandler`'s `onCancel` — which Swift may invoke BEFORE `operation`
/// even starts (a task already cancelled at the call site), concurrently with it, or not at all — to
/// whatever `withTimeout` needs to run early-cancel. `onCancel` runs synchronously on whichever
/// thread calls `.cancel()`, so both sides are lock-guarded rather than assuming an ordering.
private final class TimeoutCancelBox: @unchecked Sendable {
  private let lock = NSLock()
  private var action: (() -> Void)?
  private var firedEarly = false

  /// Registers what "cancelled" means for this call. If `fire()` already ran (the task was
  /// cancelled before this attached), runs `action` immediately instead of stashing it.
  func attach(_ action: @escaping () -> Void) {
    lock.lock()
    let already = firedEarly
    if !already { self.action = action }
    lock.unlock()
    if already { action() }
  }

  func fire() {
    lock.lock()
    firedEarly = true
    let action = self.action
    self.action = nil
    lock.unlock()
    action?()
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
