import Foundation
import WorkroomVCS

/// A watch on one directory tree that prefers the host daemon and falls back to local FSEvents.
/// The drop-in for `WorkroomFileWatcher` at all three watch sites (the Files tree, the selected
/// workroom, the per-project `.git` dir): same `start(path:)` / `stop()`, same "deliver on the
/// main actor" contract, plus an `overflow` flag on every delivery.
///
/// **Routing.** A local host's running daemon serves the watch if it has the File service. When it
/// does not — a pre-upgrade daemon kept alive for its terminals, or any failure to reach or subscribe
/// to one — this falls back to `WorkroomFileWatcher` (FSEvents in this process), so a panel is never
/// left with no watch at all. The fallback is dropped the moment a daemon subscription succeeds.
///
/// **Reconnect.** A subscription dies with its connection, and `HostConnectionManager` never
/// reconnects on its own. So the loop below RE-ACQUIRES through the router (which reconnects, and
/// spawns the daemon if it is gone) whenever a subscription ends, backing off while that fails. This is
/// what makes a killed daemon, or a Mac that slept through a socket timeout, recover without the user
/// touching anything.
///
/// **One synthetic refresh per gap.** Anything that could have been missed while no watch was live —
/// the connection dropping, the root vanishing, the switch between FSEvents and the daemon — is
/// reported once as `onChange([], overflow: true)`. `overflow` is relevant to every consumer filter,
/// so the panel re-reads whatever it shows instead of trusting state from before the gap.
///
/// Coalescing happens on the daemon (see `watch.rs`); this delivers each batch as it arrives.
///
/// Like `WorkroomFileWatcher`, call `start`/`stop` from the main thread. `onChange` runs on the main
/// actor.
/// The public handle. It owns nothing that runs: the long-lived loop belongs to `WatchCore`, which
/// the loop's own task keeps alive, so the LOOP cannot keep THIS object alive. That is what lets
/// `deinit` stop the watch. Without the split the task's strong reference made `deinit` unreachable
/// while a subscription was running, and an owner that was simply dropped (a closed window's
/// `AppStore`) left its subscriptions and their reconnect loops holding daemon slots forever.
final class HostFileWatcher {
  private let core: WatchCore

  /// `admit`, when given, decides off the main actor whether a delivery reaches `onChange` at all,
  /// so a consumer that ignores most of a busy tree never pays a main-actor hop for it.
  /// `resolveLocation` tells the watched path's location (its symlinks resolved), nil when it can't
  /// in time. By default the probe's bounded read, joined by path: a stalled mount then holds one
  /// GCD thread for every watcher, probe and registration of that path, and each watcher's loop
  /// backs off rather than parking a thread of its own (offactor review I2). A seam for tests.
  init(
    router: RepositoryRouter = .shared,
    admit: (@Sendable ([String], Bool) -> Bool)? = nil,
    resolveLocation: @escaping @Sendable (String) async -> RepositoryLocation? = {
      await GitRepositoryProbe.localLocation($0)
    },
    onChange: @escaping @MainActor ([String], Bool) -> Void
  ) {
    core = WatchCore(
      router: router, admit: admit, resolveLocation: resolveLocation, onChange: onChange)
  }

  deinit { core.stop() }

  /// Begin watching `path` recursively. No-op if already watching it; otherwise replaces the prior
  /// watch.
  func start(path: String) { core.start(path: path) }

  func stop() { core.stop() }

  /// Whether `root` (canonical) is too broad a tree to watch whole: the disk's root, a top-level
  /// folder such as `/Users`, a volume's root, or the home folder, whose `Library` never rests. A
  /// followed folder lands wherever the user `cd`s, so its watch is bounded by this (#807 review,
  /// finding 3); a registered workroom is watched because the user chose it.
  nonisolated static func isTooBroadToWatch(_ root: String, home: String) -> Bool {
    if root == home { return true }
    let parts = root.split(separator: "/")
    return parts.count <= 1 || (parts.count == 2 && parts[0] == "Volumes")
  }
}

// `@unchecked Sendable`: every mutable field is read and written under `lock`, and the loop's task
// and the owners' calls reach it from different threads by design.
private final class WatchCore: @unchecked Sendable {
  private let router: RepositoryRouter
  private let admit: (@Sendable ([String], Bool) -> Bool)?
  private let resolveLocation: @Sendable (String) async -> RepositoryLocation?
  private let onChange: @MainActor ([String], Bool) -> Void

  private let lock = NSLock()
  private var path: String?
  private var task: Task<Void, Never>?
  private var fallback: WorkroomFileWatcher?
  /// Bumped by every `start`/`stop`, so a loop that lost the race to a newer one delivers nothing.
  private var generation = 0

  init(
    router: RepositoryRouter,
    admit: (@Sendable ([String], Bool) -> Bool)?,
    resolveLocation: @escaping @Sendable (String) async -> RepositoryLocation?,
    onChange: @escaping @MainActor ([String], Bool) -> Void
  ) {
    self.router = router
    self.admit = admit
    self.resolveLocation = resolveLocation
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
    // Behind any start of it still queued (`streamQueue`).
    if let fallback { Self.streamQueue.async { fallback.stop() } }
  }

  private func current(_ generation: Int) -> Bool {
    lock.withLock { self.generation == generation }
  }

  private func deliver(_ paths: [String], overflow: Bool, generation: Int) {
    guard current(generation) else { return }
    if let admit, !admit(paths, overflow) { return }
    let onChange = self.onChange
    Task { @MainActor in onChange(paths, overflow) }
  }

  /// Where every fallback's FSEvents stream starts and stops: one serial queue, never the main
  /// actor.
  ///
  /// **One at a time, always.** Several watchers starting at once (a window opening arms one per
  /// project) once ran `FSEventStreamStart` concurrently from the cooperative pool, which crashes
  /// inside CoreFoundation (`CFFileDescriptorEnableCallBacks`, SIGBUS); `WorkroomFileWatcher` is
  /// one-thread-at-a-time by contract, and this is that thread. It is not the main actor: creating
  /// and starting a stream reads its path, which a stalled network mount blocks, and the windows
  /// must never wait on that (Codex on #812). A stalled start holds this queue, not the app.
  ///
  /// Serial, it also makes the liveness check and the start atomic with `stop()`: a `stop()` that
  /// lands first leaves nothing to start, and one that lands after queues its stop behind the start.
  static let streamQueue = DispatchQueue(label: "com.developwithstyle.workroom.fswatch.streams")

  /// Start the local FSEvents fallback, on `streamQueue`.
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
    // Awaited, so the gap's synthetic refresh that follows is delivered only once the watch is
    // live. This waits on the loop's task, never the main actor.
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      Self.streamQueue.async { [self] in
        let live = lock.withLock { self.generation == generation && fallback === watcher }
        if live { watcher.start(path: path) }
        done.resume()
      }
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
    Self.streamQueue.async { stopped.stop() }
    return true
  }

  private func run(path: String, generation: Int) async {
    var backoff: Duration = .milliseconds(500)
    var gap = false
    // Not a usable path: nothing a daemon could watch, so the local watcher's own behavior stands.
    guard path.hasPrefix("/"), !path.contains("\0") else {
      await startFallback(path: path, generation: generation)
      return
    }
    while !Task.isCancelled, current(generation) {
      guard let location = await resolveLocation(path) else {
        // Its symlinks couldn't be resolved in time: a stalled mount. Neither the daemon nor the
        // fallback is asked (FSEvents would stall the shared stream queue on it too); try again
        // after the backoff, and report the gap once a watch is live.
        gap = true
        try? await Task.sleep(for: backoff)
        backoff = min(backoff * 2, .seconds(30))
        continue
      }
      let (events, continuation) = AsyncStream<FileWatchEvent>.makeStream(
        bufferingPolicy: .unbounded)
      var handle: FileWatchHandle?
      var providerCannotWatch = false
      do {
        let interval = LaunchSignposts.begin("Register file watch")
        defer { LaunchSignposts.end("Register file watch", interval) }
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
        // The daemon cannot serve this watch right now. Watch locally so the panel stays live, tell
        // the consumer once that it may have missed something, and — unless the provider is simply
        // native and never will — try the daemon again later.
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

      // A change the fallback had seen but not yet delivered dies with it, and the daemon's watch
      // never saw it, so a handoff is a gap like any other.
      if await stopFallback(generation: generation) { gap = true }
      backoff = .milliseconds(500)
      if gap {
        deliver([], overflow: true, generation: generation)
        gap = false
      }
      var endedByDaemon = false
      subscription: for await event in events {
        guard current(generation) else { break subscription }
        switch event {
        case .changed(let paths, let overflow):
          deliver(paths, overflow: overflow, generation: generation)
        case .ended:
          endedByDaemon = true
          break subscription
        case .lost:
          break subscription
        }
      }
      await handle.cancel()
      // An `ended` subscription is one the DAEMON gave up on (the root vanished, or the OS watcher
      // failed). Subscribing straight back would spin one watch/unwatch round trip per iteration for
      // as long as that stays true, so it waits; a lost connection does not, because reconnecting is
      // the whole point.
      if endedByDaemon { try? await Task.sleep(for: .seconds(1)) }
      // The subscription is over, however it ended. Whatever happened while nothing was watching is
      // unknown, and is reported once when the next watch (daemon or fallback) is live.
      gap = true
    }
  }
}
