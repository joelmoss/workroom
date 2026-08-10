import Foundation

/// Owns the `gh auth status` verdict: one probe at a time, one freshness clock, for every window.
///
/// Whether you are signed in to `gh` is a fact about the MACHINE, not about a window. But `AppStore`
/// is per-window (`WorkroomApp.swift` mints one per `WindowSeed`) while the verdict lives on the
/// shared `ProjectStore`, and the staleness check used to sit *before* the await with the stamp
/// *after* it — so two windows opening together both read "no stamp yet", both forked `gh`, and the
/// later write won. This collapses that into one owner.
///
/// ```
///   caller(force: false) ─┐
///   caller(force: false) ─┼─► fresh within TTL? ──yes──► return the cached verdict
///   caller(force: false) ─┘            │no
///                                      ▼
///                          a probe already in flight? ──yes──► JOIN it (one `gh`, N waiters)
///                                      │no
///                                      ▼
///                        ┌── Task owned by THIS ACTOR, not by the caller
///                        │   (so a cancelled lane no longer SIGKILLs the gh child mid-answer)
///                        ▼
///              .verdict(x) ─► cache x, stamp the clock, hand x to every waiter
///              .keepPrior  ─► cache untouched and UNSTAMPED, waiters get the prior verdict
///
///   caller(force: true) ──► never joins a non-forced flight; starts a fresh probe
///                           (concurrent forced callers still join each other)
/// ```
///
/// Deliberately an INSTANCE, owned per-`ProjectStore` rather than a `static let shared` — the same
/// reasoning `VCSToolVersionCache` now follows too. `AppStore.init` documents that "tests build an
/// isolated `AppStore()` (own fresh `ProjectStore`)", and `make app-test` runs classes in PARALLEL —
/// with static state one test's injected fake runner can serve another test's probe, and a
/// tests-only `reset()` cannot stop an already-in-flight task from repopulating the cache
/// afterwards. Per-`ProjectStore` ownership gets that isolation from a guarantee the codebase
/// already makes.
actor GitHubAuthCache {
  typealias Probe = WorkroomStatusResolver.GHAuthProbe

  /// How long a settled verdict is trusted.
  private let ttl: Duration
  /// How long a `.notAuthenticated` verdict is trusted. Shorter, because it is both the alarming
  /// answer AND the one every ambiguous probe result falls back to, and it gates the entire PR/CI
  /// lane. A genuine logout still warns on the FIRST probe; only the caching is shortened.
  private let negativeTTL: Duration

  /// A MONOTONIC clock, not `Date`. Wall-clock time can step backwards (NTP correction, a manual
  /// change, waking in another timezone), which with `Date` arithmetic makes the elapsed interval
  /// negative — i.e. "always fresh" — pinning a verdict for as long as the clock stays behind. The
  /// local/CI lanes still stamp `Date`s; only this cache needs the guarantee, because it is the one
  /// whose staleness gate can suppress its own repair.
  private let clock = ContinuousClock()

  private var cached: (status: GitHubCLIStatus, at: ContinuousClock.Instant)?
  private var inFlight: (task: Task<GitHubCLIStatus?, Never>, forced: Bool)?
  /// Generation-stamped like `ShellEnvironment`'s probe state, so a superseded probe can't clear a
  /// newer flight or overwrite a newer verdict when it finally lands.
  private var generation = 0

  /// TTLs are injectable so tests can age a verdict in milliseconds instead of sleeping for a minute,
  /// and so the negative TTL is a one-line tuning change rather than a code change.
  init(ttl: Duration = .seconds(60), negativeTTL: Duration = .seconds(10)) {
    self.ttl = ttl
    self.negativeTTL = negativeTTL
  }

  /// The current verdict, probing only when stale (or when `force`d).
  ///
  /// `nil` means "no verdict to report": the probe told us nothing AND nothing was cached, so the
  /// caller must leave whatever it is showing alone. It is never a synonym for `.available`.
  func status(force: Bool = false, resolver: WorkroomStatusResolver) async -> GitHubCLIStatus? {
    if !force, let cached, isFresh(cached) { return cached.status }
    // A non-forced caller is happy with any answer in flight. A FORCED one (the manual Refresh
    // button) must not be handed a result from a probe that started before the user asked — that
    // would make Refresh silently not refresh — but two forced callers can share one.
    if let inFlight, !force || inFlight.forced { return await inFlight.task.value }

    generation += 1
    let gen = generation
    // Owned by the actor, NOT by the calling task: `withTaskCancellationHandler` in
    // `StatusCommandRunner` SIGKILLs the child when the awaiting task is cancelled, and a probe that
    // dies mid-answer is exactly the ambiguity this whole change is about. Cancelling a lane now
    // abandons the WAIT, while the probe runs to a real verdict for whoever asks next.
    let task = Task { [self] () -> GitHubCLIStatus? in
      let probe = await resolver.resolveGitHubCLI()
      return await record(probe, gen: gen)
    }
    inFlight = (task, force)
    return await task.value
  }

  /// Fold a finished probe into the cache. `.keepPrior` deliberately does NOT stamp: leaving the
  /// clock alone is what makes the next lane re-probe instead of trusting a non-answer for a full
  /// TTL — the mechanism behind the original "sticky for 60 seconds" half of the bug.
  private func record(_ probe: Probe, gen: Int) -> GitHubCLIStatus? {
    let current = gen == generation
    if current { inFlight = nil }
    switch probe {
    case .verdict(let status):
      // A superseded probe's verdict is real but older than the one that replaced it, so it must not
      // overwrite. Still returned to its own waiters, who asked before it was superseded.
      if current { cached = (status, clock.now) }
      return status
    case .keepPrior:
      return cached?.status
    }
  }

  private func isFresh(_ entry: (status: GitHubCLIStatus, at: ContinuousClock.Instant)) -> Bool {
    entry.at.duration(to: clock.now) < effectiveTTL(for: entry.status)
  }

  private func effectiveTTL(for status: GitHubCLIStatus) -> Duration {
    status == .notAuthenticated ? negativeTTL : ttl
  }
}
