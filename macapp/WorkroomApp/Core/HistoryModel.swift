import Foundation

/// Store-owned state for the History pane (issue #59): a paged, newest-first commit log for the
/// selected workroom, read through `VCSProviding`. Re-pointed on selection (like `FileTreeModel`);
/// refreshes on demand. Pagination re-fetches a growing prefix and replaces the list (DAG-safe —
/// decision A1: a jj merge graph makes cursor pagination lossy), so there are no dupes/gaps.
@MainActor
final class HistoryModel: ObservableObject {
  enum State: Equatable {
    case idle  // no workroom selected
    case loading
    case loaded
    case failed(String)

    /// True once a load has *settled* into a result (loaded or failed) — the states from which
    /// `activate` should re-read on re-entry, vs `.idle`/`.loading` (nothing to refresh yet / a load
    /// is already in flight).
    var isSettled: Bool {
      switch self {
      case .loaded, .failed: return true
      case .idle, .loading: return false
      }
    }
  }

  @Published private(set) var commits: [VCSCommit] = []
  @Published private(set) var reachedEnd = false
  @Published private(set) var state: State = .idle
  /// What the page's push states were measured against — page-level, so the rows can word their
  /// unpushed tooltip with the actual origin branch name. `nil` ⇒ nothing to compare against.
  @Published private(set) var pushScope: VCSPushScope?

  private let pageSize: Int
  /// Ceiling on the loaded window (10 pages). Not layout hygiene — a `LazyVStack` already keeps drawing
  /// proportional to what's on screen. This bounds the **read**: `load` re-fetches a growing prefix, so
  /// a window a user grew once is re-walked in full on every `refresh()`, and refresh fires per ref
  /// write from the VCS-metadata watcher. That is one commit decode (message, author, refs) per row of
  /// the window, per commit anyone makes. Mirrors the render caps the other panes already have
  /// (`FileTreeModel.renderCap`, `ChangesPanel.renderCap`), which is also why the pane says so in
  /// words rather than silently ignoring "Load more".
  private let maxWindow: Int
  private let resolve: @Sendable (URL) throws -> VCSProviding
  /// Trailing debounce in front of every read — see `load`. Matches the selected-workroom status
  /// probe's own coalesce window (`AppStore.selectionDebounce`); injectable so tests needn't wait.
  private let debounce: TimeInterval
  private(set) var root: URL?
  private var task: Task<Void, Never>?

  init(
    pageSize: Int = 100,
    maxWindow: Int = 1000,
    debounce: TimeInterval = 0.3,
    resolve: @escaping @Sendable (URL) throws -> VCSProviding = { try VCS.provider(for: $0) }
  ) {
    self.pageSize = pageSize
    self.maxWindow = max(pageSize, maxWindow)
    self.debounce = debounce
    self.resolve = resolve
  }

  /// True once the loaded window has hit `maxWindow`, so "Load more" would be a no-op.
  ///
  /// Derived from the existing `@Published commits` rather than published separately, and deliberately
  /// NOT folded into `reachedEnd`: that means "no older commits exist", and a model that conflated the
  /// two would be lying to every caller that reads it.
  var atWindowCap: Bool { commits.count >= maxWindow }

  /// The cap itself, so the pane can name the number it is showing rather than hardcode it.
  var windowCap: Int { maxWindow }

  /// Point the model at a repo (or clear it with `nil`). No-op if already focused there. Loads the
  /// first page.
  func focus(_ root: URL?) {
    guard self.root != root else { return }
    self.root = root
    commits = []
    reachedEnd = false
    guard root != nil else {
      task?.cancel()
      state = .idle
      return
    }
    load(limit: pageSize)
  }

  /// Reload the currently-shown range (on pane-appear / app-focus / the refresh button).
  func refresh() {
    guard root != nil else { return }
    // Clamped as well as `loadMore`: belt and braces, so a window grown before the cap existed (or by a
    // future caller) can't re-inflate itself here on every ref write.
    load(limit: min(max(pageSize, commits.count), maxWindow))
  }

  /// Ensure fresh data when the History section (re)activates (the panel's `.task`). On a genuine
  /// re-entry — same root and a load already *settled* (loaded OR failed) — pull fresh; otherwise
  /// defer to `focus` (loads a new root, no-ops mid-load on the same one). The `isSettled` guard does
  /// double duty: it prevents a redundant second load when the store just called `focus` eagerly on
  /// selection/section-entry (state `.loading`), and it retries after a transient `.failed` (plain
  /// `focus` would no-op on the same root and leave the pane stuck showing the error).
  func activate(_ root: URL?) {
    if self.root == root, root != nil, state.isSettled {
      refresh()
    } else {
      focus(root)
    }
  }

  /// Grow the page by one `pageSize` (the "Load more" affordance), up to `maxWindow`.
  func loadMore() {
    guard root != nil, !reachedEnd, state != .loading, !atWindowCap else { return }
    load(limit: min(commits.count + pageSize, maxWindow))
  }

  /// Await the in-flight load — for tests and for a view that wants to sequence after a refresh.
  func awaitCurrentLoad() async { await task?.value }

  /// Load `limit` commits, **debounced**. The loading state is published immediately (so the pane shows
  /// its loader the instant it's asked) but the read itself waits out `debounce` first, and a superseding
  /// call cancels this one before it ever dispatches.
  ///
  /// The debounce lives HERE, not at the call sites, because every caller can burst: arrow-key cycling
  /// the sidebar re-points the model per row, `HistoryPanel`'s `.task` re-fires per activation-key
  /// change, and the VCS-metadata watcher fires per ref write. It has to be a *pre-dispatch* wait
  /// because cancelling doesn't stop work already handed to GCD — `runBlocking`'s read can't be
  /// interrupted mid-flight (see `Timeout.swift`), so a cancelled load still holds a global-queue
  /// thread to completion. Without the wait, N rapid selections meant N concurrent full revwalks
  /// competing with the status sweep for the same pool: the shape of the "History pane loads forever"
  /// bug this model was already fixed for once.
  private func load(limit: Int) {
    guard let root else { return }
    task?.cancel()
    state = .loading
    let resolve = self.resolve
    let debounce = self.debounce
    task = Task { [weak self] in
      if debounce > 0 {
        try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
        if Task.isCancelled { return }
      }
      do {
        // The provider's log read blocks its thread (jj-lib over UniFFI / libgit2). Run it on GCD via
        // `runBlocking`, NOT `Task.detached` — the cooperative pool is fixed-width and the
        // per-workroom status snapshots fanned out on selection saturate it, which starved this read
        // (the pane "loaded forever" until the pool drained; a tab switch just bought it time).
        let page = try await runBlocking { try resolve(root).log(root: root, limit: limit) }
        if Task.isCancelled { return }
        guard let self else { return }
        self.commits = page.commits
        self.reachedEnd = page.reachedEnd
        self.pushScope = page.pushScope
        self.state = .loaded
      } catch {
        if Task.isCancelled { return }
        self?.state = .failed("\(error)")
      }
    }
  }
}
