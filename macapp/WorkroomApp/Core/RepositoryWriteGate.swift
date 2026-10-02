import Foundation

/// Serializes repository WRITES per project (VCS-foundation eng-review). git worktrees of one
/// project share the backing `.git`, so two writes running at once — a commit in one workroom, a
/// fetch or pull in another — contend for the same `index.lock` / `packed-refs.lock` and one of
/// them fails. `CLIVCSWriter.gated` routes every commit, fetch, push and pull through this gate so
/// a project's writes run one at a time. Reads are not gated.
///
/// A single global gate would needlessly serialize unrelated projects against each other, so this
/// keys per project: a chain-of-tails per key, implemented as a plain `actor` (no `NSLock`/
/// `DispatchQueue` — mirrors the `DiffCache` actor already in this codebase for a similar
/// cross-call-site coordination need). `tails` is never evicted — bounded by the number of
/// distinct projects written to in a process lifetime, not by call volume.
///
/// **Callers must pass the raw, untimed call as `operation`.** `withTimeout` (see `Timeout.swift`)
/// can't truly cancel a running `git` process — it only abandons *waiting* on it, and the process
/// keeps running to completion underneath. If a timeout wrapped the operation *inside* the gate,
/// the gate would treat the call as "done" the instant it's abandoned, letting the next queued
/// write start while the abandoned one still physically holds the lock — reproducing the exact
/// race this gate exists to close. So the correct composition is always
/// `withTimeout(seconds:) { gate.run(projectRoot:) { rawCall() } }` — the timeout wraps the
/// *wait*, the gate wraps the *ordering*, the call is innermost and un-timed.
///
/// **A genuinely-hung (never-returning) call is bounded, not fatal to the queue.** Because a
/// predecessor's call can't be cancelled (above), naively `await`-ing it forever would mean one
/// wedged `git` process permanently blocks every future same-project write. `maxChainWait` fixes
/// this: a new call waits for its predecessor only up to that ceiling, then gives up waiting and
/// runs its own operation anyway. The abandoned predecessor keeps running harmlessly in the
/// background (nothing awaits it once given up on); the chain self-heals within one ceiling's
/// worth of delay instead of wedging forever. The cost: giving up on a predecessor early
/// re-admits the ORIGINAL race (two operations physically overlapping) for that one occurrence —
/// but only in the rare genuine-wedge case, not for routine (fast, bounded) contention, which
/// `maxChainWait` is sized well above. The app also refuses a second write on a project while one
/// is running (`ProjectStore`'s writing-project counters), so two writes never queue here together.
actor RepositoryWriteGate {
  /// The process-wide gate. Must be process-global, not an `AppStore` property — `AppStore` is
  /// instantiated fresh per window (`WorkroomApp.swift`), so a gate stored there would serialize
  /// nothing across windows even though multiple windows commonly sweep the same projects.
  static let shared = RepositoryWriteGate()

  /// Default for `maxChainWait` — how long a new call waits for a same-project predecessor before
  /// giving up on it and running anyway (see the type doc's "genuinely-hung" section). Routine
  /// writes finish well inside it, so this should only ever be hit by a genuine wedge, never by
  /// routine same-project queuing.
  static let defaultMaxChainWait: TimeInterval = 30

  private let maxChainWait: TimeInterval
  /// The most recently scheduled call's completion, per project root — the tail of that project's
  /// chain. A new call waits for this before running, then becomes the new tail.
  private var tails: [RepositoryLocation: Task<Void, Never>] = [:]

  /// Non-private so tests construct an isolated gate instead of sharing the process-wide singleton.
  /// `maxChainWait` is injectable (default `defaultMaxChainWait`) so a test can use a short ceiling
  /// to exercise self-healing without a real 30s wait — mirrors `DiffCache(budget:)`.
  init(maxChainWait: TimeInterval = RepositoryWriteGate.defaultMaxChainWait) {
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
    let location = try await RepositoryLocation.local(projectRoot)
    return try await run(repository: location, operation)
  }

  /// A validated shared identity is the ordering key. Cancellation only cancels the wait;
  /// a started operation retains this tail until its actual completion.
  func run<T: Sendable>(
    repository: RepositoryLocation, _ operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    let previous = tails[repository]
    // This dependency wait is not a child of the cancellable operation. Otherwise cancelling
    // queued B could complete its tail while A still runs, allowing C to pass both of them.
    let dependency = Task<Void, Never> {
      if let previous {
        _ = try? await withTimeout(seconds: maxChainWait) { await previous.value }
      }
    }
    let task = Task<T, Error> {
      await dependency.value
      try Task.checkCancellation()
      // Shielded once started. This is what makes the doc above — "a started operation retains
      // this tail until its actual completion" — true for EVERY write path rather than only by
      // accident. It holds for a local writer because a `Process` inside `runBlocking` cannot
      // observe Swift cancellation and simply runs on. An agent-routed write DOES observe it:
      // without the shield, cancelling returns immediately and releases this tail while
      // wr-agent's `git commit` is still running, so the next same-project write starts on top of
      // it and hits `index.lock`.
      //
      // Deliberately here and not in `AgentCommandRunner`: the gate is the thing that must
      // outlive the child. Shielding inside the runner instead covered every command it forwards,
      // including `remoteState`'s ungated reads, so a superseded refresh squatted one of the
      // connection's 32 shared slots until the agent answered.
      return try await Task.detached(priority: Task.currentPriority) {
        try await operation()
      }.value
    }
    tails[repository] = Task<Void, Never> { _ = try? await task.value }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
