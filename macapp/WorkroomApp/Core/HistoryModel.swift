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

  private let pageSize: Int
  private let resolve: @Sendable (URL) throws -> VCSProviding
  private(set) var root: URL?
  private var task: Task<Void, Never>?

  init(
    pageSize: Int = 100,
    resolve: @escaping @Sendable (URL) throws -> VCSProviding = { try VCS.provider(for: $0) }
  ) {
    self.pageSize = pageSize
    self.resolve = resolve
  }

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
    load(limit: max(pageSize, commits.count))
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

  /// Grow the page by one `pageSize` (the "Load more" affordance).
  func loadMore() {
    guard root != nil, !reachedEnd, state != .loading else { return }
    load(limit: commits.count + pageSize)
  }

  /// Await the in-flight load — for tests and for a view that wants to sequence after a refresh.
  func awaitCurrentLoad() async { await task?.value }

  private func load(limit: Int) {
    guard let root else { return }
    task?.cancel()
    state = .loading
    let resolve = self.resolve
    task = Task { [weak self] in
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
        self.state = .loaded
      } catch {
        if Task.isCancelled { return }
        self?.state = .failed("\(error)")
      }
    }
  }
}
