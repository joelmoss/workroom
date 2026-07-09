import Foundation

/// Watches a single directory tree for filesystem changes via FSEvents and invokes `onChange` on the
/// main actor with the changed paths. Used to keep the *selected* workroom's VCS status + Changes
/// detail live while you edit in its terminal, and to drive the Files inspector's tree (issue #24
/// follow-up).
///
/// **FSEvents `latency` is NOT a reliable debounce under load.** The stream's `latency` is only an
/// upper bound on coalescing: under a high-churn burst (e.g. `npm install` writing tens of thousands
/// of files), the kernel flushes many small batches as its buffer fills — measured at ~70 callbacks
/// per second, NOT one callback per `latency` window. A naive consumer that re-probes VCS per raw
/// callback then forks ~70 `git`/`jj` processes per second and floods the main actor (the create-time
/// CPU spike this class caused before the fix). So this watcher applies its OWN **leading + trailing**
/// coalescing on top of the stream: it fires `onChange` immediately on the first callback after an
/// idle period (leading — the panel reacts promptly), accumulates the *union* of changed paths from
/// every subsequent raw callback, and fires `onChange` once more after `coalesceWindow` of quiet
/// (trailing — reflects the final on-disk state). A sustained burst therefore yields ~2 `onChange`
/// calls total (leading + trailing), not ~70/sec.
///
/// `onChange` receives the coalesced changed paths (deduped), so the caller can still ignore
/// VCS-internal churn (e.g. a jj snapshot writing under `.jj/`, which would otherwise self-trigger).
/// One watch at a time — `start(path:)` replaces any prior watch and resets coalescing state;
/// `stop()` tears down the stream and cancels any pending trailing emit.
final class WorkroomFileWatcher {
  private var stream: FSEventStreamRef?
  private var watchedPath: String?
  private let queue = DispatchQueue(label: "com.developwithstyle.workroom.fswatch")
  private let latency: TimeInterval
  /// App-level trailing debounce window (see class doc). Injectable so tests don't wait real seconds.
  private let coalesceWindow: TimeInterval
  private let onChange: @MainActor ([String]) -> Void

  // MARK: Coalescing state — mutated ONLY on `queue` (the FSEvents dispatch queue), so no locking.
  /// Accumulated changed paths not yet delivered (union across raw callbacks within a burst).
  private var pending: Set<String> = []
  /// Whether a burst window is currently open (leading already fired, trailing pending).
  private var windowOpen = false
  /// Timestamp of the most recent raw callback, to detect `coalesceWindow` of quiet for the trailing edge.
  private var lastActivity = Date.distantPast
  /// Bumped by `stop()`/`start()` so an in-flight scheduled trailing check for an old watch is discarded.
  private var generation = 0

  init(
    latency: TimeInterval = 1.0, coalesceWindow: TimeInterval = 1.0,
    onChange: @escaping @MainActor ([String]) -> Void
  ) {
    self.latency = latency
    self.coalesceWindow = coalesceWindow
    self.onChange = onChange
  }

  deinit { stop() }

  /// Begin watching `path` (recursively). No-op if already watching the same path; otherwise replaces
  /// the prior watch and resets coalescing state.
  func start(path: String) {
    if watchedPath == path, stream != nil { return }
    stop()
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil, release: nil, copyDescription: nil)
    // UseCFTypes → `eventPaths` arrives as a CFArray of CFString (clean `[String]` bridge).
    // NoDefer → the first event after an idle period fires at the *start* of the latency window, so
    // the panel reacts promptly rather than waiting a full `latency` after you start typing.
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
    let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<WorkroomFileWatcher>.fromOpaque(info).takeUnretainedValue()
      let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
      // Runs on `queue` (set via FSEventStreamSetDispatchQueue) — safe to touch coalescing state.
      watcher.ingest(paths)
    }
    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault, callback, &context, [path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
    else { return }
    self.stream = stream
    self.watchedPath = path
    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
  }

  func stop() {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
    self.watchedPath = nil
    // Reset coalescing state on the queue so a pending trailing check can't fire after teardown.
    queue.async { [weak self] in
      guard let self else { return }
      self.generation &+= 1
      self.pending.removeAll()
      self.windowOpen = false
      self.lastActivity = .distantPast
    }
  }

  // MARK: - Leading + trailing coalescing (all on `queue`)

  /// Fold a raw FSEvents batch into the burst. Fires the leading edge immediately when a burst opens,
  /// then relies on `scheduleTrailing` to flush the accumulated remainder once writes go quiet.
  private func ingest(_ paths: [String]) {
    lastActivity = Date()
    if !windowOpen {
      // Leading edge: deliver this batch now, open the burst window, and arm the trailing check.
      windowOpen = true
      pending.removeAll()
      deliver(paths)
      scheduleTrailing()
    } else {
      // Inside an open burst: accumulate for the trailing emit (union dedupes).
      pending.formUnion(paths)
    }
  }

  /// After `coalesceWindow`, flush the accumulated paths (trailing edge) if writes have gone quiet;
  /// otherwise re-arm, so a sustained burst collapses into a single trailing emit once it ends.
  private func scheduleTrailing() {
    let gen = generation
    queue.asyncAfter(deadline: .now() + coalesceWindow) { [weak self] in
      guard let self, gen == self.generation, self.windowOpen else { return }
      let quietFor = Date().timeIntervalSince(self.lastActivity)
      if quietFor >= self.coalesceWindow {
        let batch = self.pending
        self.pending.removeAll()
        self.windowOpen = false
        if !batch.isEmpty { self.deliver(Array(batch)) }
      } else {
        // Still active — re-check after the remaining quiet time elapses.
        self.scheduleTrailing()
      }
    }
  }

  /// Hop to the main actor to invoke `onChange`. Empty batches are never delivered.
  private func deliver(_ paths: [String]) {
    guard !paths.isEmpty else { return }
    Task { @MainActor in self.onChange(paths) }
  }
}
