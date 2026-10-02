import Combine
import Foundation

/// The live data source behind the inspector's **Files** section: lists the selected target's
/// working tree (via git), builds the tree, tracks which directories are
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
    /// Not a git repo, or the tool is missing — nothing to list.
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
  private var watcher: HostFileWatcher?
  private var loadTask: Task<Void, Never>?
  /// The listing in flight, if any. Cancelling it stops waiting but NOT the work: on the agent path
  /// the request has already left, and the host keeps listing until it finishes. So a burst of reloads must not each start their own — that would queue
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

  /// Where listings are routed; tests pass one whose remote hosts connect nothing.
  private let router: RepositoryRouter

  init(runner: StatusCommandRunning = StatusCommandRunner(), router: RepositoryRouter = .shared) {
    self.runner = runner
    self.router = router
  }

  deinit {
    loadTask?.cancel()
    listing?.task.cancel()
    watcher?.stop()
  }

  /// Point the model at `target`'s tree: a remote workroom's by its location on its host, which its
  /// path alone can't name (#253), and any other's by its path.
  func activate(target: TerminalTarget?) {
    guard let target, target.isRemoteWorkroom else {
      // A remote tree left `currentPath` nil, which `activate(path: nil)` takes for a no-op.
      if target == nil, currentPath == nil { return activate(location: nil) }
      return activate(path: target?.path)
    }
    // Forgotten, so a later `activate(path:)` back to that path is not taken for a no-op.
    currentPath = nil
    // No watcher refreshes a remote tree, so coming back to it is when it is read again. One this
    // app can't reach, or whose recorded path can't name a location, shows nothing, never that path
    // on this Mac.
    let location = target.remoteLocation
    if let location, currentLocation == location { return reload() }
    activate(location: location)
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
    state = .loading
    // A remote tree is listed by its agent, and not watched: `HostFileWatcher` watches local paths
    // only, so it refreshes on reactivation and Reload.
    guard location.host == .local else { return reload() }
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
    let task = Task { [weak self, runner, router] in
      let result = await FileTreeModel.list(location: location, runner: runner, router: router)
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
      // function already promises while a listing is in flight) rather than blanking it. With nothing
      // showing yet there is nothing to keep, and staying `.loading` would spin for good.
      if state == .loading {
        state = .failed("The file listing was interrupted. Reload to try again.")
      }
    case .transient(let message):
      // As `.interrupted`: the service said no this time, which says nothing about the tree.
      if state == .loading { state = .failed(message) }
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
      if Self.isRelevantChange(changed, overflow: overflow) { self?.reload() }
    }
    watcher.start(path: path)
    self.watcher = watcher
  }

  /// Ignore pure VCS-internal churn (git writing `.git/`) so the tree doesn't self-trigger an endless
  /// reload; any real working-tree edit still refreshes it. `.jj/` too: a colocated repo left from jj
  /// can still have `jj` run in it, and Workroom never writes `.jj`. The paths are ABSOLUTE host
  /// paths, so the tests need the leading slash. An `overflow` batch says some changes are unlisted,
  /// so it is relevant whatever the listed paths are.
  nonisolated static func isRelevantChange(_ changed: [String], overflow: Bool) -> Bool {
    overflow || changed.contains { !$0.contains("/.git/") && !$0.contains("/.jj/") }
  }

  /// The outcome of listing a working tree — richer than a bare optional so a killed probe can be
  /// told apart from a genuine "not a repo" or "tool missing".
  enum ListResult: Equatable {
    case listing([String])
    /// git yielded no listing for an ordinary reason (not a repo, tool missing).
    case unavailable
    /// The listing exceeded the capture cap. Distinct from `.unavailable` because the repo is fine and
    /// the answer is "too many files to list", and never shown as a shortened tree.
    case tooLarge
    /// The probe was killed by a signal — our own cancellation is caught earlier by the caller
    /// checking `Task.isCancelled`, so reaching this means an EXTERNAL kill (OS memory pressure, a
    /// crash). Distinct from `.unavailable`: this says nothing about whether `path` is a repo, so
    /// the caller must not blank an existing tree over it — the sensible read is "try again", not
    /// "this isn't a repo any more".
    case interrupted
    /// The file service refused or failed this once (agent lock contention, a full request budget,
    /// an I/O error). Like `.interrupted`, it says nothing about the tree, so an existing one stays.
    case transient(String)
    case failed(RepositoryRoutingError)
  }

  /// A listing error that is neither truncation nor a routing verdict. The agent reports a vanished
  /// working directory and an I/O hiccup as the same `Io` failure, so the disk decides, for every
  /// error: a folder that is confirmed gone (or no longer a directory) is `.unavailable` and blanks
  /// the tree; anything else, including a check that itself failed, keeps it.
  /// `onThisMac` false for a path on a remote host, which says nothing about this Mac's disk.
  nonisolated static func listFailure(_ error: Error, path: String, onThisMac: Bool = true) async
    -> ListResult
  {
    var gone = false
    if onThisMac {
      gone =
        (try? await runBlocking { () -> Bool in
          // Not `fileExists`, which is also false when existence cannot be determined (a parent
          // directory that became unreadable), and would blank a tree that is still there.
          do {
            let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == false
          } catch CocoaError.fileReadNoSuchFile {
            return true
          } catch {
            return false
          }
        }) ?? false
    }
    if gone { return .unavailable }
    if case VCSError.lockContention = error {
      return .transient("The repository is busy. Reload to try again.")
    }
    return .transient(error.localizedDescription)
  }

  /// git listing is allowed without registration. WHERE the listing runs — this process, or
  /// wr-agent — is `router.files`'s decision.
  static func list(
    location: RepositoryLocation, runner: StatusCommandRunning,
    router: RepositoryRouter = .shared
  ) async -> ListResult {
    let onThisMac = location.host == .local
    if onThisMac {
      // A folder without its own `.git` (e.g. a workspace Jujutsu made before #266) is no
      // repository: git run there would discover an ANCESTOR repository and list that tree instead.
      let root = URL(fileURLWithPath: location.path)
      guard (try? await runBlocking({ isGitRepo(at: root) })) == true else { return .unavailable }
    }
    let files: FileProviding
    do {
      files = try await router.files(for: location, runner: runner)
    } catch {
      return .failed(error as? RepositoryRoutingError ?? .unavailable(location.host))
    }
    let result: CommandResult
    do {
      result = try await files.list()
    } catch FileServiceError.listingTruncated {
      return .tooLarge
    } catch let error as RepositoryRoutingError {
      return .failed(error)
    } catch {
      return await listFailure(error, path: location.path, onThisMac: onThisMac)
    }
    if result.ok { return .listing(FileListing.parse(result.stdout)) }
    // A killed probe is not evidence `path` isn't a repo. `timedOut` implies `signaled` (the
    // timeout SIGTERMs the child), and a timeout says nothing about an EXTERNAL kill —
    // `CommandResult.signaled`'s own doc says to test it first. Left as `.interrupted` it would also
    // leave a first load spinning forever.
    return result.signaled && !result.timedOut ? .interrupted : .unavailable
  }
}
