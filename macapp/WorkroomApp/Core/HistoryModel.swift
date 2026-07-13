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
        // Off the main actor: the providers do blocking work (UniFFI / libgit2 / jj CLI).
        let page = try await Task.detached(priority: .userInitiated) {
          try await resolve(root).log(root: root, limit: limit)
        }.value
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
