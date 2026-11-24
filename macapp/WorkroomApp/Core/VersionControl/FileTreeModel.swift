import Combine
import CryptoKit
import Foundation
import WorkroomSystem
import WorkroomVCS

/// The live data source behind the inspector's **Files** section: lists the selected target's
/// working tree (via git), builds the tree, tracks which directories are
/// expanded, and reloads when the filesystem changes. All the data-shaping is delegated to the pure
/// helpers in `FileTree.swift`; this owns the I/O + observable state.
///
/// `@MainActor` so SwiftUI reads it directly. The listing, its parse and the tree build all run
/// off the main actor (`listTree`), which hands back one finished tree; a listing whose output is
/// byte-identical to the last one builds and publishes nothing (#812 perf, F1).
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
  /// Expanded directory paths; the panel toggles entries. Reset on a target switch, and restored
  /// for a followed folder the tree returns to (#810).
  @Published var expanded: Set<String> = [] {
    didSet { updateWatchScope() }
  }

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
  /// The last listing's tree, before `subfolder` picks the part shown, with the signature of the
  /// output it was built from and its directories. The three are set and cleared together.
  private var listedRoots: [FileNode] = []
  private var listingSignature: ListingSignature?
  private var listedDirectories: Set<String> = []
  /// The built trees of the repositories listed most recently, by `treeKey` (#812 perf, F2): a
  /// revisit shows its tree at once and re-lists in the background.
  private var recentTrees = RecentRepositoryCache<BuiltTree>()
  /// The `treeKey` each recently activated raw path resolved to, so a revisit by path finds its
  /// tree before the path is resolved again.
  private var recentTreeKeys = RecentRepositoryCache<String>(capacity: 32)
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
  /// Whether the tree remembers each folder's expansion (#810): a followed folder's tree only
  /// (`activate(root:)`); a workroom's starts collapsed on every switch, as it always has.
  private var remembersExpansion = false
  /// Each followed folder's expanded directories, by `shownFolderKey`.
  private var expansionMemory: [ShownFolder: Set<String>] = [:]
  /// The folder the tree shows, and how it is listed: what its expansion is remembered under.
  private var shownFolderKey: ShownFolder? {
    guard remembersExpansion, let currentPath else { return nil }
    return ShownFolder(isPlain: isPlain, path: currentPath, subfolder: subfolder)
  }
  private struct ShownFolder: Hashable {
    var isPlain: Bool
    var path: String
    var subfolder: String
  }
  /// The disk read in flight, and the directories asked for while it ran: at most one read plus
  /// one follow-up, however many reloads arrive (#812 perf, F6).
  private var plainTask: Task<Void, Never>?
  private var plainTaskID: UUID?
  private var plainPending: Set<String>?
  private let runner: StatusCommandRunning
  private var watcher: HostFileWatcher?
  /// The folder the tree watches once its existence is confirmed, kept while paused.
  private var watchRoot: String?
  /// What the watch's off-main filter compares changes against.
  private let interest = WatchInterest()
  /// Files isn't shown (#812 perf, F4): nothing is watched, and the tree re-lists once on
  /// `resume()` if it was watching when paused.
  private var paused = false
  private var dirty = false
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

  /// How long a stat or a disk read of the tree's folder may take: a stale network mount blocks one
  /// until the kernel gives up. Each runs under `GitRepositoryProbe.blockingRead`, so a read still
  /// blocked is joined rather than started again.
  private let diskReadTimeout: TimeInterval
  /// Whether a path is a folder on disk. A seam for tests.
  private let isFolder: @Sendable (String) -> Bool
  /// Reads directories of a plain folder from disk (`readPlain`). A seam for tests.
  private let readDirectories: @Sendable ([String], String) -> [String: [FileNode]]

  init(
    runner: StatusCommandRunning = StatusCommandRunner(), router: RepositoryRouter = .shared,
    diskReadTimeout: TimeInterval = 3,
    isFolder: @escaping @Sendable (String) -> Bool = GitRepositoryProbe.isFolder,
    readDirectories: @escaping @Sendable ([String], String) -> [String: [FileNode]] = {
      FileTreeModel.readPlain($0, under: $1)
    }
  ) {
    self.runner = runner
    self.router = router
    self.diskReadTimeout = diskReadTimeout
    self.isFolder = isFolder
    self.readDirectories = readDirectories
  }

  deinit {
    loadTask?.cancel()
    plainTask?.cancel()
    listing?.task.cancel()
    // No `watcher?.stop()`: this model is the watcher's only owner, and `HostFileWatcher` stops its
    // watch in its own `deinit` (a nonisolated deinit can't reach the main-actor property anyway).
  }

  /// Whether the tree's folder is being watched. For tests.
  var isWatching: Bool { watcher != nil }

  /// Files stopped being shown: stop watching, keeping the tree. A change made meanwhile is caught
  /// by `resume()`.
  func pause() {
    guard !paused else { return }
    paused = true
    if watcher != nil { dirty = true }
    watcher?.stop()
    watcher = nil
  }

  /// Files is shown again: watch again, and re-list once if the tree went unwatched. A fresh
  /// activation since the pause has listed already.
  func resume() {
    guard paused else { return }
    paused = false
    if let watchRoot, watcher == nil { startWatching(watchRoot) }
    if dirty {
      dirty = false
      reload()
    }
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
    forgetPath()
    subfolder = ""
    isPlain = false
    remembersExpansion = false
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
        // Set first: a workroom's tree at this same path becomes a followed one here.
        remembersExpansion = true
        guard subfolder != self.subfolder else { return }
        rememberExpansion()
        self.subfolder = subfolder
        expanded = recalledExpansion()
        rerootListed()
        return
      }
      activate(path: path, subfolder: subfolder, plain: false, remembers: true)
    case .folder(let path):
      if !isPlain { forgetPath() }
      activate(path: path, subfolder: "", plain: true, remembers: true)
    }
  }

  /// Keep the shown folder's expansion for when the tree returns to it.
  private func rememberExpansion() {
    guard let key = shownFolderKey else { return }
    expansionMemory[key] = expanded.isEmpty ? nil : expanded
  }

  /// The expansion the shown folder had when the tree last left it; none for a workroom's tree.
  private func recalledExpansion() -> Set<String> {
    shownFolderKey.flatMap { expansionMemory[$0] } ?? []
  }

  /// Leave the current path, so the next activation of it is not taken for a no-op: a switch
  /// between listing modes on one path.
  private func forgetPath() {
    rememberExpansion()
    currentPath = nil
  }

  /// Point the model at a target directory (a workroom/project root), or `nil` to clear. Starts
  /// watching it and lists it. No-op if already on this path (so re-renders don't re-list).
  /// Raw paths are the local persisted-record boundary; normalization finishes before watching.
  func activate(path: String?) {
    if !isPlain, !subfolder.isEmpty, path == currentPath {
      // The repository a followed subfolder showed, at its root: the same listing, re-rooted.
      rememberExpansion()
      remembersExpansion = false
      subfolder = ""
      expanded = []
      rerootListed()
      return
    }
    if isPlain, path == currentPath { forgetPath() }
    activate(path: path, subfolder: "", plain: false)
  }

  /// Show another folder of the listed repository, re-listing only if a change outside what was
  /// shown arrived meanwhile.
  private func rerootListed() {
    plainListings = [:]
    reroot()
    if interest.takeStale() { reload() }
  }

  private func activate(path: String?, subfolder: String, plain: Bool, remembers: Bool = false) {
    // Compared against the RAW path, never against `currentLocation.path`: `RepositoryLocation`
    // canonicalizes (resolves symlinks — `/tmp` is `/private/tmp` on macOS), so re-selecting the
    // same on-screen target would otherwise look like a fresh activation on every re-render,
    // dropping `expanded` and re-listing. `currentPath` is this method's own bookkeeping and is
    // never overwritten by `activate(location:)`.
    guard path != currentPath else { return }
    loadTask?.cancel()
    cancelListing()
    rememberExpansion()
    currentPath = path
    self.subfolder = subfolder
    isPlain = plain
    remembersExpansion = remembers
    readsSubfolderFromDisk = false
    plainListings = [:]
    expanded = recalledExpansion()
    currentLocation = nil
    stopWatching()
    guard let path else {
      clearTree()
      state = .idle
      return
    }
    // A repository listed lately shows its last tree at once; the activation re-lists it.
    if !plain, let key = recentTreeKeys.value(for: path), let cached = recentTrees.value(for: key) {
      seed(cached)
    } else {
      clearTree()
      state = .loading
    }
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
    stopWatching()
    currentLocation = location
    plainListings = [:]
    dirty = false
    expanded = recalledExpansion()
    guard let location else {
      clearTree()
      state = .idle
      return
    }
    let key = Self.treeKey(location)
    if let currentPath { recentTreeKeys.store(key, for: currentPath) }
    if !isPlain, let cached = recentTrees.value(for: key) {
      seed(cached)
    } else {
      clearTree()
      state = .loading
    }
    // A remote tree is listed by its daemon, and not watched: `HostFileWatcher` watches local paths
    // only, so it refreshes on reactivation and Reload.
    guard location.host == .local else { return reload() }
    loadTask = Task { [weak self, isFolder, diskReadTimeout] in
      // Keyed as the probe keys its own folder stat, so the two join on a wedged mount. One that
      // outruns the timeout reads as unavailable.
      let exists =
        await GitRepositoryProbe.blockingRead(
          "folder\u{0}\(location.path)", timeout: diskReadTimeout, { isFolder(location.path) })
        ?? false
      guard !Task.isCancelled, let self, self.currentLocation == location else { return }
      guard exists else {
        self.forgetTree()
        self.state = .unavailable
        return
      }
      self.watchRoot = location.path
      if !self.paused { self.startWatching(location.path) }
      self.reload()
    }
  }

  /// Show `cached` as the listed tree.
  private func seed(_ cached: BuiltTree) {
    listedRoots = cached.roots
    listingSignature = cached.signature
    listedDirectories = cached.directories
    if state != .loaded { state = .loaded }
    reroot()
  }

  /// Drop the listed tree and what is shown of it.
  private func clearTree() {
    Self.releaseOffMain(listedRoots)
    listedRoots = []
    listingSignature = nil
    listedDirectories = []
    if !roots.isEmpty { roots = [] }
  }

  /// Drop the listed tree and forget it for a revisit: the folder stopped listing.
  private func forgetTree() {
    if let currentLocation { recentTrees.remove(Self.treeKey(currentLocation)) }
    clearTree()
  }

  /// Free a replaced tree away from the main actor: tens of thousands of nodes take a while.
  private static func releaseOffMain(_ nodes: [FileNode]) {
    guard !nodes.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async { withExtendedLifetime(nodes) {} }
  }

  private func stopWatching() {
    watcher?.stop()
    watcher = nil
    watchRoot = nil
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
    if isPlain { return listPlain(visibleDirectories, at: location) }
    interest.clearStale()
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
    plainTaskID = nil
    plainPending = nil
    listing?.task.cancel()
    listing = nil
    followUp = false
  }

  private func startListing(_ location: RepositoryLocation) {
    let id = UUID()
    let previous = listingSignature
    let task = Task { [weak self, runner, router] in
      let result = await FileTreeModel.listTree(
        location: location, runner: runner, router: router, unless: previous)
      self?.finishListing(id: id, location: location, result: result)
    }
    listing = Listing(id: id, location: location, task: task)
  }

  private func finishListing(id: UUID, location: RepositoryLocation, result: TreeListing) {
    // Keyed by id, not just location: a listing that was cancelled and replaced by a fresh one for
    // the SAME location (switch away and back) must not paint or retire its successor. A target that
    // has since been replaced is dropped too.
    guard listing?.id == id, currentLocation == location else { return }
    listing = nil
    apply(result, at: location)
    if followUp {
      followUp = false
      startListing(location)
    }
  }

  private func apply(_ result: TreeListing, at location: RepositoryLocation) {
    switch result {
    case .unchanged:
      // The same output as the tree shown: nothing to build or publish.
      if state != .loaded { state = .loaded }
    case .tree(let built):
      let replaced = listedRoots
      listedRoots = built.roots
      listingSignature = built.signature
      listedDirectories = built.directories
      recentTrees.store(built, for: Self.treeKey(location))
      if state != .loaded { state = .loaded }
      reroot()
      Self.releaseOffMain(replaced)
    case .other(let other):
      apply(other)
    }
  }

  private func apply(_ result: ListResult) {
    switch result {
    case .listing:
      // `listTree` reports a listing as a built tree, never as paths.
      break
    case .failed(let error):
      forgetTree()
      state = .failed(error.localizedDescription)
    case .tooLarge:
      forgetTree()
      state = .failed(FileServiceError.listingTruncated.localizedDescription)
    case .unavailable:
      forgetTree()
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

  /// Expand/collapse a directory row. No-op for files. A disk-read directory is read again each
  /// time it opens, showing what was read before meanwhile; a listed one re-lists if a change it
  /// may show arrived while it was collapsed.
  func toggle(_ node: FileNode) {
    guard node.isDirectory else { return }
    if expanded.contains(node.path) {
      expanded.remove(node.path)
      return
    }
    expanded.insert(node.path)
    if diskBase != nil, let location = currentLocation {
      let inside = node.path + "/"
      listPlain(visibleDirectories.filter { $0 == node.path || $0.hasPrefix(inside) }, at: location)
    } else if interest.takeStale() {
      reload()
    }
  }

  /// Show the part of the listed tree under `subfolder`. Where git lists nothing (an ignored or
  /// empty folder), the folder is read from disk instead, so it never reads as empty when it
  /// isn't; its paths stay relative to the repository's root.
  private func reroot() {
    defer { updateWatchScope() }
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
      // An expansion recalled for the folder (#810) lists its directories too.
      listPlain(visibleDirectories, at: location)
    }
  }

  /// Publish `nodes` only when they differ, so a re-read that changed nothing re-renders nothing.
  private func setRoots(_ nodes: [FileNode]) {
    if roots != nodes { roots = nodes }
  }

  /// The directories the tree shows: the folder it starts at, and each expanded directory below
  /// it whose ancestors are all expanded. What a reload re-reads and what the watch looks at.
  private var visibleDirectories: [String] {
    let base = diskBase ?? subfolder
    return [base] + expanded.filter { Self.isVisible($0, below: base, expanded: expanded) }.sorted()
  }

  /// Whether `directory` shows below `base`: each folder between them is expanded.
  nonisolated static func isVisible(_ directory: String, below base: String, expanded: Set<String>)
    -> Bool
  {
    guard directory != base, base.isEmpty || directory.hasPrefix(base + "/") else { return false }
    var parent = (directory as NSString).deletingLastPathComponent
    while parent != base {
      guard !parent.isEmpty, expanded.contains(parent) else { return false }
      parent = (parent as NSString).deletingLastPathComponent
    }
    return true
  }

  // MARK: Plain folders (#809)

  /// List `directories` (tree-relative, "" for the root) from disk, off the main actor, and graft
  /// them into the tree from `diskBase` down. Hidden entries are left out, as `ls` and Finder leave
  /// them. A base that cannot be read leaves nothing to show.
  ///
  /// One read at a time: directories asked for while one runs are read together once it finishes,
  /// so a burst of watch events costs one more read, not one each (#812 perf, F6).
  ///
  /// The read runs under the timeout, joining one of the same directories still blocked (a wedged
  /// mount), so a burst of watch events blocks one thread, not one each. A read that outruns it
  /// keeps whatever the tree shows; with nothing listed yet, the folder is unavailable.
  private func listPlain(_ directories: [String], at location: RepositoryLocation) {
    if plainTask != nil {
      plainPending = (plainPending ?? []).union(directories)
      return
    }
    readPlainDirectories(Set(directories), at: location)
  }

  private func readPlainDirectories(_ directories: Set<String>, at location: RepositoryLocation) {
    // Sorted, so the same directories make the same key.
    let wanted = directories.sorted()
    let key = (["plain", location.path] + wanted).joined(separator: "\u{0}")
    let id = UUID()
    plainTaskID = id
    plainTask = Task { [weak self, readDirectories, diskReadTimeout] in
      let listed = await GitRepositoryProbe.blockingRead(
        key, timeout: diskReadTimeout, { readDirectories(wanted, location.path) })
      guard let self, self.plainTaskID == id else { return }
      self.plainTask = nil
      self.plainTaskID = nil
      let pending = self.plainPending
      self.plainPending = nil
      guard !Task.isCancelled, self.currentLocation == location, let base = self.diskBase
      else { return }
      defer { if let pending { self.readPlainDirectories(pending, at: location) } }
      guard let listed else {
        if self.plainListings[base] == nil {
          self.setRoots([])
          self.state = .unavailable
        }
        return
      }
      for directory in wanted { self.plainListings[directory] = listed[directory] }
      guard self.plainListings[base] != nil else {
        self.setRoots([])
        self.state = .unavailable
        return
      }
      self.setRoots(self.plainTree(base))
      if self.state != .loaded { self.state = .loaded }
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

  // MARK: Watching

  /// Watch `path`. The watch's filter runs off the main actor against `interest`, so a change
  /// the tree doesn't show (a `~/Library` write under a plain `~`, a save in a collapsed folder)
  /// never reaches the main actor (#812 perf, F3).
  private func startWatching(_ path: String) {
    updateWatchScope()
    let interest = interest
    let watcher = HostFileWatcher(
      admit: { changed, overflow in interest.admit(changed, overflow: overflow) },
      onChange: { [weak self] _, _ in self?.reload() })
    watcher.start(path: path)
    self.watcher = watcher
  }

  /// Hand the watch's filter what the tree shows now.
  private func updateWatchScope() {
    guard let location = currentLocation, location.host == .local else {
      return interest.set(nil)
    }
    interest.set(
      WatchScope(
        root: location.path, plain: isPlain, base: isPlain ? "" : subfolder,
        visible: Set(visibleDirectories), known: listedDirectories, home: Self.home))
  }

  /// The home folder, canonical: a tree too broad to re-list on every change in it.
  nonisolated static let home = VCSStatusService.canonicalPath(NSHomeDirectory())

  /// What the watch compares a change against: the tree's folder, how it lists, the folder it
  /// shows (`base`, repository-relative), the directories shown, and every directory the listing
  /// holds.
  struct WatchScope: Sendable {
    var root: String
    var plain: Bool
    var base: String
    var visible: Set<String>
    var known: Set<String>
    var home: String
  }

  /// What a batch of changes means for the tree: nothing, something it doesn't show (re-listed
  /// when the tree next shows more), or something it shows.
  enum WatchVerdict: Equatable, Sendable {
    case ignore
    case stale
    case reload
  }

  /// What `changed` (absolute paths, as the watch reports them) means for the tree in `scope`.
  ///
  /// A plain folder, or a repository too broad to watch whole (`~`, `/`), re-reads only for an
  /// entry of a shown directory (`touchesListed`). Any other repository walks each change down
  /// from the shown folder through what is expanded: an entry of a shown directory, a folder git
  /// doesn't list (a new one, or an ignored `node_modules`), or a removal all re-list; a change
  /// inside a collapsed folder, or outside the followed one, only marks the tree stale. git's own
  /// directories never count.
  nonisolated static func watchVerdict(
    _ changed: [String], overflow: Bool, scope: WatchScope, exists: (String) -> Bool
  ) -> WatchVerdict {
    if overflow { return .reload }
    if scope.plain || HostFileWatcher.isTooBroadToWatch(scope.root, home: scope.home) {
      return touchesListed(changed, root: scope.root, listed: scope.visible) ? .reload : .ignore
    }
    let baseParts = scope.base.split(separator: "/").map(String.init)
    var verdict = WatchVerdict.ignore
    for path in changed {
      guard let relative = relativePath(path, root: scope.root) else { continue }
      let parts = relative.split(separator: "/").map(String.init)
      if parts.contains(".git") || parts.contains(".jj") { continue }
      switch repositoryVerdict(
        parts, baseParts: baseParts, path: path, scope: scope, exists: exists)
      {
      case .reload: return .reload
      case .stale: verdict = .stale
      case .ignore: break
      }
    }
    return verdict
  }

  private nonisolated static func repositoryVerdict(
    _ parts: [String], baseParts: [String], path: String, scope: WatchScope,
    exists: (String) -> Bool
  ) -> WatchVerdict {
    guard parts.starts(with: baseParts) else { return .stale }
    var directory = scope.base
    for index in baseParts.count..<parts.count {
      if index == parts.count - 1 { return .reload }
      let candidate = directory.isEmpty ? parts[index] : directory + "/" + parts[index]
      if scope.visible.contains(candidate) {
        directory = candidate
        continue
      }
      if !scope.known.contains(candidate) { return .reload }
      return exists(path) ? .stale : .reload
    }
    // The shown folder itself.
    return .reload
  }

  /// `path` relative to `root`, which the watch may name with a `/private` prefix; nil outside it.
  private nonisolated static func relativePath(_ path: String, root: String) -> String? {
    let trimmed = root == "/" ? "" : root
    for base in [trimmed, "/private" + trimmed] {
      if path == base { return "" }
      if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
    }
    return nil
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

  // MARK: Listing

  /// The outcome of listing a working tree — richer than a bare optional so a killed probe can be
  /// told apart from a genuine "not a repo" or "tool missing".
  enum ListResult: Equatable, Sendable {
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

  /// A listing's output, by length and digest: what tells a re-list that changed nothing.
  struct ListingSignature: Equatable, Sendable {
    let length: Int
    let digest: Data

    nonisolated init(_ output: String) {
      let bytes = Data(output.utf8)
      length = bytes.count
      digest = Data(SHA256.hash(data: bytes))
    }
  }

  /// A built listing: its tree, every directory in it, and the output it was built from.
  struct BuiltTree: Sendable {
    let roots: [FileNode]
    let directories: Set<String>
    let signature: ListingSignature
  }

  /// What `listTree` hands the main actor: a finished tree, word that the output is the one the
  /// tree was built from, or why there is no listing.
  enum TreeListing: Sendable {
    case unchanged
    case tree(BuiltTree)
    case other(ListResult)
  }

  /// The cache key of `location`'s tree.
  nonisolated static func treeKey(_ location: RepositoryLocation) -> String {
    "\(location.host)\u{0}\(location.path)"
  }

  /// List `location` and build its tree, all off the main actor. Output whose signature is
  /// `previous` builds nothing.
  nonisolated static func listTree(
    location: RepositoryLocation, runner: StatusCommandRunning,
    router: RepositoryRouter = .shared, unless previous: ListingSignature?
  ) async -> TreeListing {
    switch await fetch(location: location, runner: runner, router: router) {
    case .result(let result):
      return .other(result)
    case .output(let output):
      return (try? await runBlocking { build(output, unless: previous) }) ?? .other(.interrupted)
    }
  }

  /// The tree `output` lists, or `.unchanged` when it is the output `previous` signs.
  nonisolated static func build(_ output: String, unless previous: ListingSignature?)
    -> TreeListing
  {
    let signature = ListingSignature(output)
    if signature == previous { return .unchanged }
    let roots = FileTreeBuilder.build(from: FileListing.parse(output))
    var directories = Set<String>()
    func collect(_ nodes: [FileNode]) {
      for node in nodes where node.isDirectory {
        directories.insert(node.path)
        collect(node.children ?? [])
      }
    }
    collect(roots)
    return .tree(BuiltTree(roots: roots, directories: directories, signature: signature))
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
  nonisolated static func list(
    location: RepositoryLocation, runner: StatusCommandRunning,
    router: RepositoryRouter = .shared
  ) async -> ListResult {
    switch await fetch(location: location, runner: runner, router: router) {
    case .output(let output): return .listing(FileListing.parse(output))
    case .result(let result): return result
    }
  }

  /// A listing's raw output, or why there is none.
  private enum Fetched: Sendable {
    case output(String)
    case result(ListResult)
  }

  private nonisolated static func fetch(
    location: RepositoryLocation, runner: StatusCommandRunning, router: RepositoryRouter
  ) async -> Fetched {
    let onThisMac = location.host == .local
    if onThisMac {
      // A folder without its own `.git` (e.g. a workspace Jujutsu made before #266) is no
      // repository: git run there would discover an ANCESTOR repository and list that tree instead.
      let root = URL(fileURLWithPath: location.path)
      guard (try? await runBlocking({ isGitRepo(at: root) })) == true else {
        return .result(.unavailable)
      }
    }
    let files: FileProviding
    do {
      files = try await router.files(for: location, runner: runner)
    } catch {
      return .result(.failed(error as? RepositoryRoutingError ?? .unavailable(location.host)))
    }
    let result: CommandResult
    do {
      result = try await files.list()
    } catch FileServiceError.listingTruncated {
      return .result(.tooLarge)
    } catch let error as RepositoryRoutingError {
      return .result(.failed(error))
    } catch {
      return .result(await listFailure(error, path: location.path, onThisMac: onThisMac))
    }
    if result.ok { return .output(result.stdout) }
    // A killed probe is not evidence `path` isn't a repo. `timedOut` implies `signaled` (the
    // timeout SIGTERMs the child), and a timeout says nothing about an EXTERNAL kill —
    // `CommandResult.signaled`'s own doc says to test it first. Left as `.interrupted` it would also
    // leave a first load spinning forever.
    return .result(result.signaled && !result.timedOut ? .interrupted : .unavailable)
  }
}

/// What the Files watch compares changes against, off the main actor: the latest `WatchScope`
/// the model handed it, and whether a change it doesn't show has arrived since the last listing.
/// `@unchecked Sendable`: every field is read and written under `lock`.
private final class WatchInterest: @unchecked Sendable {
  private let lock = NSLock()
  private var scope: FileTreeModel.WatchScope?
  private var stale = false

  func set(_ scope: FileTreeModel.WatchScope?) { lock.withLock { self.scope = scope } }

  /// Whether a change the tree doesn't show arrived since the last listing; clears it.
  func takeStale() -> Bool {
    lock.withLock {
      defer { stale = false }
      return stale
    }
  }

  func clearStale() { lock.withLock { stale = false } }

  /// Whether `changed` re-lists the tree. Runs on the watch's own thread, never the main actor.
  func admit(_ changed: [String], overflow: Bool) -> Bool {
    guard let scope = lock.withLock({ self.scope }) else { return overflow }
    let verdict = FileTreeModel.watchVerdict(
      changed, overflow: overflow, scope: scope,
      exists: { FileManager.default.fileExists(atPath: $0) })
    switch verdict {
    case .reload: return true
    case .stale:
      lock.withLock { stale = true }
      return false
    case .ignore: return false
    }
  }
}
