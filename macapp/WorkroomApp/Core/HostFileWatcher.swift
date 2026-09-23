import Foundation

/// A watch on one directory tree that prefers the host agent and falls back to local FSEvents.
/// The drop-in for `WorkroomFileWatcher` at all three watch sites (the Files tree, the selected
/// workroom, the per-project `.git`/`.jj` dir): same `start(path:)` / `stop()`, same "deliver on the
/// main actor" contract, plus an `overflow` flag on every delivery.
///
/// **Routing.** A local host's running agent serves the watch when it has the File service. When it
/// does not — a pre-upgrade agent kept alive for its terminals, or any failure to reach or subscribe
/// to one — this falls back to `WorkroomFileWatcher` (FSEvents in this process), so a panel is never
/// left with no watch at all. The fallback is dropped the moment an agent subscription succeeds.
///
/// **Reconnect.** A subscription dies with its connection, and `HostConnectionManager` never
/// reconnects on its own. So the loop below RE-ACQUIRES through the router (which reconnects, and
/// spawns the agent if it is gone) whenever a subscription ends, backing off while that fails. This is
/// what makes a killed agent, or a Mac that slept through a socket timeout, recover without the user
/// touching anything.
///
/// **One synthetic refresh per gap.** Anything that could have been missed while no watch was live —
/// the connection dropping, the root vanishing, the switch between FSEvents and the agent — is
/// reported once as `onChange([], overflow: true)`. `overflow` is relevant to every consumer filter,
/// so the panel re-reads whatever it shows instead of trusting state from before the gap.
///
/// Coalescing happens on the agent (see `watch.rs`); this delivers each batch as it arrives.
///
/// Like `WorkroomFileWatcher`, call `start`/`stop` from the main thread. `onChange` runs on the main
/// actor.
/// The public handle. It owns nothing that runs: the long-lived loop belongs to `WatchCore`, which
/// the loop's own task keeps alive, so the LOOP cannot keep THIS object alive. That is what lets
/// `deinit` stop the watch. Without the split the task's strong reference made `deinit` unreachable
/// while a subscription was running, and an owner that was simply dropped (a closed window's
/// `AppStore`) left its subscriptions and their reconnect loops holding agent slots forever.
final class HostFileWatcher {
  private let core: WatchCore

  init(
    router: RepositoryRouter = .shared, onChange: @escaping @MainActor ([String], Bool) -> Void
  ) {
    core = WatchCore(router: router, onChange: onChange)
  }

  deinit { core.stop() }

  /// Begin watching `path` recursively. No-op if already watching it; otherwise replaces the prior
  /// watch.
  func start(path: String) { core.start(path: path) }

  func stop() { core.stop() }
}

private final class WatchCore {
  private let router: RepositoryRouter
  private let onChange: @MainActor ([String], Bool) -> Void

  private let lock = NSLock()
  private var path: String?
  private var task: Task<Void, Never>?
  private var fallback: WorkroomFileWatcher?
  /// Bumped by every `start`/`stop`, so a loop that lost the race to a newer one delivers nothing.
  private var generation = 0

  init(
    router: RepositoryRouter = .shared, onChange: @escaping @MainActor ([String], Bool) -> Void
  ) {
    self.router = router
    self.onChange = onChange
  }

  /// Begin watching `path` recursively. No-op if already watching it; otherwise replaces the prior
  /// watch.
  func start(path: String) {
    let alreadyWatching: Bool = lock.withLock { self.path == path && self.task != nil }
    if alreadyWatching { return }
    stop()
    let generation: Int = lock.withLock {
      self.path = path
      self.generation += 1
      return self.generation
    }
    let task = Task { [weak self] in
      guard let self else { return }
      await self.run(path: path, generation: generation)
    }
    lock.withLock { self.task = task }
  }

  func stop() {
    let (task, fallback) = lock.withLock { () -> (Task<Void, Never>?, WorkroomFileWatcher?) in
      generation += 1
      path = nil
      defer {
        self.task = nil
        self.fallback = nil
      }
      return (self.task, self.fallback)
    }
    task?.cancel()
    fallback?.stop()
  }

  private func current(_ generation: Int) -> Bool {
    lock.withLock { self.generation == generation }
  }

  private func deliver(_ paths: [String], overflow: Bool, generation: Int) {
    guard current(generation) else { return }
    let onChange = self.onChange
    Task { @MainActor in onChange(paths, overflow) }
  }

  /// Start the local FSEvents fallback.
  ///
  /// **On the main actor, always.** `WorkroomFileWatcher` is main-thread-only by contract, and this
  /// used to call it from the cooperative pool: several watchers starting at once (a window opening
  /// arms one per project) then ran `FSEventStreamStart` concurrently, which crashes inside
  /// CoreFoundation (`CFFileDescriptorEnableCallBacks`, SIGBUS). Hopping to the main actor also makes
  /// the liveness check and the start atomic with `stop()`, which the owners call from there: a `stop()`
  /// that lands first leaves nothing to start, and one that lands after stops what this started.
  private func startFallback(path: String, generation: Int) async {
    let watcher: WorkroomFileWatcher? = lock.withLock {
      guard self.generation == generation, fallback == nil else { return nil }
      let watcher = WorkroomFileWatcher { [weak self] paths in
        self?.deliver(paths, overflow: false, generation: generation)
      }
      fallback = watcher
      return watcher
    }
    guard let watcher else { return }
    await MainActor.run {
      let live = lock.withLock { self.generation == generation && fallback === watcher }
      if live { watcher.start(path: path) }
    }
  }

  /// Returns whether a fallback watcher was running, which is a handoff: it may have been holding a
  /// change in its coalescing window, and stopping it discards that.
  @discardableResult
  private func stopFallback(generation: Int) async -> Bool {
    let stopped: WorkroomFileWatcher? = lock.withLock {
      guard self.generation == generation else { return nil }
      defer { fallback = nil }
      return fallback
    }
    guard let stopped else { return false }
    await MainActor.run { stopped.stop() }
    return true
  }

  private func run(path: String, generation: Int) async {
    var backoff: Duration = .milliseconds(500)
    var gap = false
    while !Task.isCancelled, current(generation) {
      guard let location = try? await RepositoryLocation.local(path) else {
        // Not a usable path: nothing an agent could watch, so the local watcher's own behavior stands.
        await startFallback(path: path, generation: generation)
        return
      }
      let (events, continuation) = AsyncStream<FileWatchEvent>.makeStream(
        bufferingPolicy: .unbounded)
      var handle: FileWatchHandle?
      var providerCannotWatch = false
      do {
        let files = try await router.files(for: location)
        handle = try await files.watch(root: location.path) { continuation.yield($0) }
        providerCannotWatch = handle == nil
      } catch {
        handle = nil
      }
      guard !Task.isCancelled, current(generation) else {
        await handle?.cancel()
        return
      }

      guard let handle else {
        // The agent cannot serve this watch right now. Watch locally so the panel stays live, tell
        // the consumer once that it may have missed something, and — unless the provider is simply
        // native and never will — try the agent again later.
        await startFallback(path: path, generation: generation)
        if gap {
          deliver([], overflow: true, generation: generation)
          gap = false
        }
        if providerCannotWatch { return }
        try? await Task.sleep(for: backoff)
        backoff = min(backoff * 2, .seconds(30))
        continue
      }

      // A change the fallback had seen but not yet delivered dies with it, and the agent's watch
      // never saw it, so a handoff is a gap like any other.
      if await stopFallback(generation: generation) { gap = true }
      backoff = .milliseconds(500)
      if gap {
        deliver([], overflow: true, generation: generation)
        gap = false
      }
      var endedByAgent = false
      subscription: for await event in events {
        guard current(generation) else { break subscription }
        switch event {
        case .changed(let paths, let overflow):
          deliver(paths, overflow: overflow, generation: generation)
        case .ended:
          endedByAgent = true
          break subscription
        case .lost:
          break subscription
        }
      }
      await handle.cancel()
      // An `ended` subscription is one the AGENT gave up on (the root vanished, or the OS watcher
      // failed). Subscribing straight back would spin one watch/unwatch round trip per iteration for
      // as long as that stays true, so it waits; a lost connection does not, because reconnecting is
      // the whole point.
      if endedByAgent { try? await Task.sleep(for: .seconds(1)) }
      // The subscription is over, however it ended. Whatever happened while nothing was watching is
      // unknown, and is reported once when the next watch (agent or fallback) is live.
      gap = true
    }
  }
}
