import Combine
import Foundation

/// The live data source behind the inspector's **Files** section: lists the selected target's
/// working tree (via git, falling back to jj), builds the tree, tracks which directories are
/// expanded, and reloads when the filesystem changes. All the data-shaping is delegated to the pure
/// helpers in `FileTree.swift`; this owns the I/O + observable state.
///
/// `@MainActor` so SwiftUI reads it directly; the listing itself runs off-main inside
/// `StatusCommandRunner` (it drains the child's pipes on background queues), so the main actor only
/// touches the small parsed result.
@MainActor
final class FileTreeModel: ObservableObject {
  enum State: Equatable {
    /// No target selected.
    case idle
    /// Listing for the first time (no tree yet to show).
    case loading
    /// `roots` is current (may be empty — an empty repo).
    case loaded
    /// Not a git/jj repo, or the tool is missing — nothing to list.
    case unavailable
    case failed(String)
  }

  /// The sorted root nodes of the current target's tree.
  @Published private(set) var roots: [FileNode] = []
  @Published private(set) var state: State = .idle
  /// Expanded directory paths. Reset on target switch; the panel toggles entries.
  @Published var expanded: Set<String> = []

  /// Max rows the panel renders at once (a guard for pathologically large trees); the panel notes
  /// any overflow rather than silently truncating.
  static let renderCap = 4000

  /// The visible rows for the current tree + expansion — what the panel iterates.
  var rows: [FileTreeRow] { FileTreeBuilder.flatten(roots, expanded: expanded) }

  private var currentPath: String?
  private var currentLocation: RepositoryLocation?
  private let runner: StatusCommandRunning
  private let gate: JJSnapshotGate
  private var watcher: HostFileWatcher?
  private var loadTask: Task<Void, Never>?
  /// The listing in flight, if any. Cancelling it stops waiting but NOT the work: on the agent path
  /// the request has already left, and the host keeps listing (and, for jj, holding the working-copy
  /// lock) until it finishes. So a burst of reloads must not each start their own — that would queue
  /// N host-side listings behind each other for one screenful of tree. See `reload()`.
  private struct Listing {
    let id: UUID
    let location: RepositoryLocation
    let task: Task<Void, Never>
  }
  private var listing: Listing?
  /// A reload arrived while `listing` was in flight for the same location: run exactly one more when
  /// it finishes, so the tree still ends up reflecting the LAST change.
  private var followUp = false

  init(runner: StatusCommandRunning = StatusCommandRunner(), gate: JJSnapshotGate = .shared) {
    self.runner = runner
    self.gate = gate
  }

  deinit {
    loadTask?.cancel()
    listing?.task.cancel()
    watcher?.stop()
  }

  /// Point the model at a target directory (a workroom/project root), or `nil` to clear. Starts
  /// watching it and lists it. No-op if already on this path (so re-renders don't re-list).
  /// Raw paths are the local persisted-record boundary; normalization finishes before watching.
  func activate(path: String?) {
    // Compared against the RAW path, never against `currentLocation.path`: `RepositoryLocation`
    // canonicalizes (resolves symlinks — `/tmp` is `/private/tmp` on macOS), so re-selecting the
    // same on-screen target would otherwise look like a fresh activation on every re-render,
    // dropping `expanded` and re-listing. `currentPath` is this method's own bookkeeping and is
    // never overwritten by `activate(location:)`.
    guard path != currentPath else { return }
    loadTask?.cancel()
    cancelListing()
    currentPath = path
    expanded = []
    currentLocation = nil
    watcher?.stop()
    watcher = nil
    roots = []
    guard let path else {
      state = .idle
      return
    }
    state = .loading
    loadTask = Task { [weak self] in
      do {
        let location = try await RepositoryLocation.local(path)
        guard !Task.isCancelled, let self, self.currentPath == path else { return }
        self.activate(location: location)
      } catch { self?.state = .unavailable }
    }
  }

  func activate(location: RepositoryLocation?) {
    guard currentLocation != location || (location == nil && currentPath != nil) else { return }
    loadTask?.cancel()
    cancelListing()
    watcher?.stop()
    watcher = nil
    currentLocation = location
    roots = []
    expanded = []
    guard let location else {
      state = .idle
      return
    }
    guard location.host == .local else {
      state = .failed(RepositoryRoutingError.unavailable(location.host).localizedDescription)
      return
    }
    state = .loading
    loadTask = Task { [weak self] in
      let exists =
        (try? await runBlocking {
          var directory: ObjCBool = false
          return FileManager.default.fileExists(atPath: location.path, isDirectory: &directory)
            && directory.boolValue
        }) ?? false
      guard !Task.isCancelled, let self, self.currentLocation == location else { return }
      guard exists else {
        self.state = .unavailable
        return
      }
      self.startWatching(location.path)
      self.reload()
    }
  }

  /// Re-list the current target (a manual refresh, or after a watched filesystem change). Keeps the
  /// existing tree visible while the new listing runs.
  ///
  /// At most ONE listing per location is in flight, plus at most one follow-up. Each `reload()` used
  /// to cancel the previous listing and start another, which was free while cancelling killed the
  /// child process; through the agent it only abandons the wait, so a burst of watch events would
  /// stack that many listings on the host.
  func reload() {
    guard let location = currentLocation else { return }
    guard location.host == .local else {
      state = .failed(RepositoryRoutingError.unavailable(location.host).localizedDescription)
      return
    }
    if let listing, listing.location == location {
      followUp = true
      return
    }
    cancelListing()
    startListing(location)
  }

  private func cancelListing() {
    listing?.task.cancel()
    listing = nil
    followUp = false
  }

  private func startListing(_ location: RepositoryLocation) {
    let id = UUID()
    let task = Task { [weak self, runner, gate] in
      let result = await FileTreeModel.list(location: location, runner: runner, gate: gate)
      self?.finishListing(id: id, location: location, result: result)
    }
    listing = Listing(id: id, location: location, task: task)
  }

  private func finishListing(id: UUID, location: RepositoryLocation, result: ListResult) {
    // Keyed by id, not just location: a listing that was cancelled and replaced by a fresh one for
    // the SAME location (switch away and back) must not paint or retire its successor. A target that
    // has since been replaced is dropped too.
    guard listing?.id == id, currentLocation == location else { return }
    listing = nil
    apply(result)
    if followUp {
      followUp = false
      startListing(location)
    }
  }

  private func apply(_ result: ListResult) {
    switch result {
    case .listing(let paths):
      roots = FileTreeBuilder.build(from: paths)
      state = .loaded
    case .failed(let error):
      roots = []
      state = .failed(error.localizedDescription)
    case .tooLarge:
      roots = []
      state = .failed(FileServiceError.listingTruncated.localizedDescription)
    case .unavailable:
      roots = []
      state = .unavailable
    case .interrupted:
      // An external kill, not evidence `path` stopped being a repo — leave whatever tree/state
      // is already showing alone (the same "keep the existing tree visible" contract this
      // function already promises while a listing is in flight) rather than blanking it.
      break
    }
  }

  /// Expand/collapse a directory row. No-op for files.
  func toggle(_ node: FileNode) {
    guard node.isDirectory else { return }
    if expanded.contains(node.path) {
      expanded.remove(node.path)
    } else {
      expanded.insert(node.path)
    }
  }

  private func startWatching(_ path: String) {
    let watcher = HostFileWatcher { [weak self] changed, overflow in
      // Ignore pure VCS-internal churn (a jj snapshot under `.jj/`, git writing `.git/`) so the tree
      // doesn't self-trigger an endless reload; any real working-tree edit still refreshes it. The
      // paths are ABSOLUTE host paths, so the `/.git/` test needs the leading slash. An `overflow`
      // batch says some changes are unlisted, so it is relevant whatever the listed paths are.
      let relevant =
        overflow || changed.contains { !$0.contains("/.git/") && !$0.contains("/.jj/") }
      if relevant { self?.reload() }
    }
    watcher.start(path: path)
    self.watcher = watcher
  }

  /// The outcome of listing a working tree — richer than a bare optional so a killed probe can be
  /// told apart from a genuine "not a repo" or "tool missing".
  enum ListResult: Equatable {
    case listing([String])
    /// Neither tool yielded a listing for an ordinary reason (not a repo, tool missing).
    case unavailable
    /// The listing exceeded the capture cap. Distinct from `.unavailable` because the repo is fine and
    /// the answer is "too many files to list", and never shown as a shortened tree.
    case tooLarge
    /// A tool's probe was killed by a signal — our own cancellation is caught earlier by the caller
    /// checking `Task.isCancelled`, so reaching this means an EXTERNAL kill (OS memory pressure, a
    /// crash). Distinct from `.unavailable`: this says nothing about whether `path` is a repo, so
    /// the caller must not blank an existing tree over it — the sensible read is "try again", not
    /// "this isn't a repo any more".
    case interrupted
    case failed(RepositoryRoutingError)
  }

  /// Immutable git listing is allowed without registration. The JJ fallback snapshots and needs the
  /// registered shared repository (its working-copy lock is keyed by it); unknown ownership is an
  /// explicit failure. WHERE the listing runs — this process, or wr-agent — is `router.files`'s
  /// decision; the git-then-jj order, and so the fact that a colocated jj repo lists through
  /// immutable git, is this function's and does not depend on the backend.
  static func list(
    location: RepositoryLocation, runner: StatusCommandRunning,
    gate: JJSnapshotGate = .shared, router: RepositoryRouter = .shared
  ) async -> ListResult {
    guard location.host == .local else { return .failed(.unavailable(location.host)) }
    let files: FileProviding
    do {
      files = try await router.files(for: location, runner: runner, gate: gate)
    } catch {
      return .failed(error as? RepositoryRoutingError ?? .unavailable(location.host))
    }
    var sawSignal = false
    for vcs in [FileListVCS.git, .jj] {
      let result: CommandResult
      do {
        result = try await files.list(vcs)
      } catch FileServiceError.listingTruncated {
        return .tooLarge
      } catch let error as RepositoryRoutingError {
        return .failed(error)
      } catch {
        return .failed(.unavailable(location.host))
      }
      if result.ok { return .listing(FileListing.parse(result.stdout, vcs: vcs)) }
      // A killed probe is not evidence `path` isn't a repo — remember it, but still try the other
      // tool before giving up, exactly as an ordinary failure does.
      if result.signaled { sawSignal = true }
    }
    return sawSignal ? .interrupted : .unavailable
  }
}
