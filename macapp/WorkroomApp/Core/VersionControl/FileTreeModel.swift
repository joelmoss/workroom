import Combine
import Foundation
import WorkroomSystem
import WorkroomVCS

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
  /// The repository folder the tree shows, relative to `currentPath` ("" for all of it): a
  /// followed folder inside a repository (#809). The listing is the whole repository's, so a move
  /// to another of its folders re-roots without listing again.
  private var subfolder = ""
  /// The last listing's tree, before `subfolder` picks the part shown.
  private var listedRoots: [FileNode] = []
  /// Listing a plain folder outside any repository (#809): from disk, one level at a time.
  private var isPlain = false
  /// A repository folder git lists nothing under (an ignored `build` or `node_modules`) is read
  /// from disk instead, as a plain folder is.
  private var readsSubfolderFromDisk = false
  /// Directories read from disk, by tree-relative path ("" for a plain folder's root).
  private var plainListings: [String: [FileNode]] = [:]
  /// The directory a disk-read tree starts at: "" for a plain folder, the subfolder for an ignored
  /// repository folder, nil for a tree git lists.
  private var diskBase: String? {
    if isPlain { return "" }
    return readsSubfolderFromDisk ? subfolder : nil
  }
  private var plainTask: Task<Void, Never>?
  private let runner: StatusCommandRunning
  private var watcher: HostFileWatcher?
  private var loadTask: Task<Void, Never>?
  /// The listing in flight, if any. Cancelling it stops waiting, NOT the work: on the daemon path
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
    plainTask?.cancel()
    listing?.task.cancel()
    // No `watcher?.stop()`: this model is the watcher's only owner, and `HostFileWatcher` stops its
    // watch in its own `deinit` (a nonisolated deinit can't reach the main-actor property anyway).
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
    subfolder = ""
    isPlain = false
    // No watcher refreshes a remote tree, so coming back to it is when it is read again. One this
    // app can't reach, or whose recorded path can't name a location, shows nothing, never that path
    // on this Mac.
    let location = target.remoteLocation
    if let location, currentLocation == location { return reload() }
    activate(location: location)
  }

  /// Point the model at what a followed folder's Files section lists (#809), or `nil` to clear. A
  /// move between folders of one repository re-roots the tree it already has, listing nothing.
  func activate(root: FilesRoot?) {
    switch root {
    case nil:
      activate(path: nil)
    case .repository(let path, let subfolder):
      if isPlain { forgetPath() }
      if path == currentPath {
        guard subfolder != self.subfolder else { return }
        self.subfolder = subfolder
        expanded = []
        plainListings = [:]
        reroot()
        return
      }
      activate(path: path, subfolder: subfolder, plain: false)
    case .folder(let path):
      if !isPlain { forgetPath() }
      activate(path: path, subfolder: "", plain: true)
    }
  }

  /// Leave the current path, so the next activation of it is not taken for a no-op: a switch
  /// between listing modes on one path.
  private func forgetPath() { currentPath = nil }

  /// Point the model at a target directory (a workroom/project root), or `nil` to clear. Starts
  /// watching it and lists it. No-op if already on this path (so re-renders don't re-list).
  /// Raw paths are the local persisted-record boundary; normalization finishes before watching.
  func activate(path: String?) {
    if isPlain || !subfolder.isEmpty, path == currentPath { forgetPath() }
    activate(path: path, subfolder: "", plain: false)
  }

  private func activate(path: String?, subfolder: String, plain: Bool) {
    // Compared against the RAW path, never against `currentLocation.path`: `RepositoryLocation`
    // canonicalizes (resolves symlinks — `/tmp` is `/private/tmp` on macOS), so re-selecting the
    // same on-screen target would otherwise look like a fresh activation on every re-render,
    // dropping `expanded` and re-listing. `currentPath` is this method's own bookkeeping and is
    // never overwritten by `activate(location:)`.
    guard path != currentPath else { return }
    loadTask?.cancel()
    cancelListing()
    currentPath = path
    self.subfolder = subfolder
    isPlain = plain
    readsSubfolderFromDisk = false
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
    listedRoots = []
    plainListings = [:]
    roots = []
    expanded = []
    guard let location else {
      state = .idle
      return
    }
    state = .loading
    // A remote tree is listed by its daemon, and not watched: `HostFileWatcher` watches local paths
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
  /// child process; through the daemon it only abandons the wait, so a burst of watch events would
  /// stack that many listings on the host.
  func reload() {
    guard let location = currentLocation else { return }
    if isPlain { return listPlain(Array(plainListings.keys) + [""], at: location) }
    if let listing, listing.location == location {
      followUp = true
      return
    }
    cancelListing()
    startListing(location)
  }

  private func cancelListing() {
    plainTask?.cancel()
    plainTask = nil
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
      listedRoots = FileTreeBuilder.build(from: paths)
      state = .loaded
      reroot()
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

  /// Expand/collapse a directory row. No-op for files. A plain folder's directory is listed the
  /// first time it opens.
  func toggle(_ node: FileNode) {
    guard node.isDirectory else { return }
    if expanded.contains(node.path) {
      expanded.remove(node.path)
    } else {
      expanded.insert(node.path)
      if diskBase != nil, plainListings[node.path] == nil, let location = currentLocation {
        listPlain([node.path], at: location)
      }
    }
  }

  /// Show the part of the listed tree under `subfolder`. Where git lists nothing (an ignored or
  /// empty folder), the folder is read from disk instead, so it never reads as empty when it
  /// isn't; its paths stay relative to the repository's root.
  private func reroot() {
    var nodes: [FileNode]? = listedRoots
    var walked = ""
    for component in subfolder.split(separator: "/").map(String.init) {
      walked = walked.isEmpty ? component : walked + "/" + component
      let path = walked
      nodes = nodes?.first { $0.isDirectory && $0.path == path }?.children
    }
    if let nodes {
      readsSubfolderFromDisk = false
      setRoots(nodes)
      return
    }
    readsSubfolderFromDisk = true
    if plainListings[subfolder] == nil { state = .loading }
    if let location = currentLocation {
      listPlain(Array(plainListings.keys) + [subfolder], at: location)
    }
  }

  /// Publish `nodes` only when they differ, so a re-read that changed nothing re-renders nothing.
  private func setRoots(_ nodes: [FileNode]) {
    if roots != nodes { roots = nodes }
  }

  // MARK: Plain folders (#809)

  /// List `directories` (tree-relative, "" for the root) from disk, off the main actor, and graft
  /// them into the tree from `diskBase` down. Hidden entries are left out, as `ls` and Finder leave
  /// them. A base that cannot be read leaves nothing to show.
  private func listPlain(_ directories: [String], at location: RepositoryLocation) {
    let wanted = Array(Set(directories))
    let previous = plainTask
    plainTask = Task { [weak self] in
      await previous?.value
      let listed =
        (try? await runBlocking { Self.readPlain(wanted, under: location.path) }) ?? [:]
      guard !Task.isCancelled, let self, self.currentLocation == location,
        let base = self.diskBase
      else { return }
      for directory in wanted { self.plainListings[directory] = listed[directory] }
      guard self.plainListings[base] != nil else {
        self.setRoots([])
        self.state = .unavailable
        return
      }
      self.setRoots(self.plainTree(base))
      self.state = .loaded
    }
  }

  /// The plain folder's tree below `directory`, from what has been listed: an unlisted directory
  /// has no children yet.
  private func plainTree(_ directory: String) -> [FileNode] {
    (plainListings[directory] ?? []).map { node in
      guard node.isDirectory else { return node }
      return FileNode(
        name: node.name, path: node.path, isDirectory: true, children: plainTree(node.path))
    }
  }

  /// Read each of `directories` under `root`; a directory that cannot be read is missing from the
  /// result.
  nonisolated static func readPlain(_ directories: [String], under root: String) -> [String:
    [FileNode]]
  {
    var result: [String: [FileNode]] = [:]
    let manager = FileManager.default
    for directory in directories {
      let url =
        directory.isEmpty
        ? URL(fileURLWithPath: root, isDirectory: true)
        : URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(directory)
      guard
        let entries = try? manager.contentsOfDirectory(
          at: url, includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles])
      else { continue }
      let nodes = entries.map { entry -> FileNode in
        let name = entry.lastPathComponent
        let path = directory.isEmpty ? name : directory + "/" + name
        let isDirectory =
          (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return FileNode(
          name: name, path: path, isDirectory: isDirectory, children: isDirectory ? [] : nil)
      }
      result[directory] = FileTreeBuilder.sorted(nodes)
    }
    return result
  }

  private func startWatching(_ path: String) {
    let watcher = HostFileWatcher { [weak self] changed, overflow in
      guard let self else { return }
      // A plain folder can be `~`, whose watch never rests: only a change in a listed directory
      // re-reads it.
      if self.isPlain {
        if overflow || Self.touchesListed(changed, root: path, listed: Set(self.plainListings.keys))
        {
          self.reload()
        }
      } else if Self.isRelevantChange(changed, overflow: overflow) {
        self.reload()
      }
    }
    watcher.start(path: path)
    self.watcher = watcher
  }

  /// Whether any of `changed` (absolute paths, as the watch reports them) is an entry of a listed
  /// directory of the plain folder at `root`. The watch may name `/private/var` for `/var`.
  nonisolated static func touchesListed(_ changed: [String], root: String, listed: Set<String>)
    -> Bool
  {
    let trimmed = root == "/" ? "" : root
    let bases = [trimmed, "/private" + trimmed]
    return changed.contains { path in
      for base in bases where path == base || path.hasPrefix(base + "/") {
        let relative = String(path.dropFirst(min(path.count, base.count + 1)))
        // Hidden entries are never listed, so a `.zsh_history` write in `~` re-reads nothing.
        if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
        let parent = (relative as NSString).deletingLastPathComponent
        if listed.contains(parent) || listed.contains(relative) { return true }
      }
      return false
    }
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
    /// The file service refused or failed this once (daemon lock contention, a full request budget,
    /// an I/O error). Like `.interrupted`, it says nothing about the tree, so an existing one stays.
    case transient(String)
    case failed(RepositoryRoutingError)
  }

  /// A listing error that's neither truncation nor a routing verdict. The daemon reports a vanished
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
  /// workroomd — is `router.files`'s decision.
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
