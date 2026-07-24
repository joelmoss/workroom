import Foundation

/// Serializes jj working-copy snapshots per project root (VCS-foundation eng-review). A jj
/// `working_status`/`workingFileDiff(.workingCopy)` call *snapshots* `@` — it takes the
/// per-workspace working-copy lock and, if the tree changed, commits a **repo-level** transaction
/// against the shared op-store. All of a project's workrooms (secondary jj workspaces) fund into
/// that same repo-level store, and git worktrees of one project share the backing `.git`, so
/// concurrent snapshots across a project's workrooms can contend (observed live as a
/// `packed-refs.lock could not be obtained` error) even though each workspace's own lock is never
/// itself shared cross-workroom.
///
/// A single global gate would needlessly serialize unrelated projects against each other, so this
/// keys per project root: a chain-of-tails per key, implemented as a plain `actor` (no `NSLock`/
/// `DispatchQueue` — mirrors the `DiffCache` actor already in this codebase for a similar
/// cross-call-site coordination need). `tails` is never evicted — bounded by the number of
/// distinct project roots swept in a process lifetime, not by call volume.
///
/// **Callers must pass the raw, untimed native call as `operation`.** `withTimeout` (see
/// `Timeout.swift`) can't truly cancel a synchronous jj-lib call — it only abandons *waiting* on
/// it, and the call keeps running to completion on its own thread underneath. If a timeout wrapped
/// the operation *inside* the gate, the gate would treat the call as "done" the instant it's
/// abandoned, letting the next queued call start snapshotting while the abandoned one still
/// physically holds the lock — reproducing the exact race this gate exists to close. So the
/// correct composition is always `withTimeout(seconds:) { gate.run(projectRoot:) { rawCall() } }`
/// — the timeout wraps the *wait*, the gate wraps the *ordering*, the native call is innermost and
/// un-timed.
///
/// **A genuinely-hung (never-returning) native call is bounded, not fatal to the queue.** Because a
/// predecessor's call can't be cancelled (above), naively `await`-ing it forever would mean a truly
/// wedged jj-lib call (jj CLI pipe deadlocks have happened before in this codebase's history)
/// permanently blocks every future same-project call — worse than the pre-gate world, where each
/// lane's own independent timeout at least bounded ITS OWN wait. `maxChainWait` fixes this: a new
/// call waits for its predecessor only up to that ceiling, then gives up waiting and runs its own
/// operation anyway. The abandoned predecessor keeps running harmlessly in the background (nothing
/// awaits it once given up on); the chain self-heals within one ceiling's worth of delay instead of
/// wedging forever. The cost: giving up on a predecessor early re-admits the ORIGINAL race (two
/// operations physically overlapping) for that one occurrence — but only in the rare genuine-wedge
/// case, not for routine (fast, bounded) contention, which `maxChainWait` is sized well above.
actor JJSnapshotGate {
  /// The process-wide gate. Must be process-global, not an `AppStore` property — `AppStore` is
  /// instantiated fresh per window (`WorkroomApp.swift`), so a gate stored there would serialize
  /// nothing across windows even though multiple windows commonly sweep the same projects.
  static let shared = JJSnapshotGate()

  /// Default for `maxChainWait` — how long a new call waits for a same-project predecessor before
  /// giving up on it and running anyway (see the type doc's "genuinely-hung" section). Deliberately
  /// much larger than `WorkroomStatusResolver.jjGatedWaitTimeout` (15s, the caller-facing per-call
  /// budget) — a single healthy jj snapshot normally finishes in well under a second, so this should
  /// only ever be hit by a genuine wedge, never by routine same-project queuing.
  static let defaultMaxChainWait: TimeInterval = 30

  private let maxChainWait: TimeInterval
  /// The most recently scheduled call's completion, per project root — the tail of that project's
  /// chain. A new call waits for this before running, then becomes the new tail.
  private var tails: [String: Task<Void, Never>] = [:]

  /// Non-private so tests construct an isolated gate instead of sharing the process-wide singleton.
  /// `maxChainWait` is injectable (default `defaultMaxChainWait`) so a test can use a short ceiling
  /// to exercise self-healing without a real 30s wait — mirrors `DiffCache(budget:)`.
  init(maxChainWait: TimeInterval = JJSnapshotGate.defaultMaxChainWait) {
    self.maxChainWait = maxChainWait
  }

  /// Run `operation` after any earlier same-`projectRoot` call has genuinely finished, OR after
  /// `maxChainWait` elapses waiting on it (self-healing — see the type doc). Calls for different
  /// project roots never wait on each other. A call cancelled before its turn arrives never invokes
  /// `operation`. `operation` must never itself call `run(projectRoot:)` for the SAME `projectRoot`
  /// (directly or transitively) — that would wait on its own tail and deadlock that project's queue
  /// for up to `maxChainWait`. No current caller does this; it's a caller invariant, not something
  /// this type can detect or guard against.
  func run<T: Sendable>(
    projectRoot: String, _ operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    let previous = tails[projectRoot]
    let task = Task<T, Error> {
      if let previous {
        // `withTimeout`, not a task group: a task group awaits all children before returning, so a
        // still-wedged `previous` would block this wait past its own ceiling — exactly the trap
        // `Timeout.swift`'s own doc warns about. `withTimeout` races via a continuation instead, so
        // it actually returns at the ceiling regardless of whether `previous` has finished.
        _ = try? await withTimeout(seconds: maxChainWait) { await previous.value }
      }
      try Task.checkCancellation()
      return try await operation()
    }
    tails[projectRoot] = Task<Void, Never> { _ = try? await task.value }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
