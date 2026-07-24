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
  /// The owning project's root for `currentPath` (nil for a root target, where it equals
  /// `currentPath` itself) — threaded into `list` to key `JJSnapshotGate` for the jj branch, the
  /// same way `AppStore.projectRoot(forTarget:)` feeds `DiffResolver`.
  private var currentProjectRoot: String?
  private let runner: StatusCommandRunning
  private let gate: JJSnapshotGate
  private var watcher: WorkroomFileWatcher?
  private var loadTask: Task<Void, Never>?

  init(runner: StatusCommandRunning = StatusCommandRunner(), gate: JJSnapshotGate = .shared) {
    self.runner = runner
    self.gate = gate
  }

  deinit {
    loadTask?.cancel()
    watcher?.stop()
  }

  /// Point the model at a target directory (a workroom/project root), or `nil` to clear. Starts
  /// watching it and lists it. No-op if already on this path (so re-renders don't re-list).
  /// `projectRoot` is the owning project's root (nil ⇒ falls back to `path` itself, e.g. for a root
  /// target where they're the same) — see `currentProjectRoot`.
  func activate(path: String?, projectRoot: String? = nil) {
    guard path != currentPath else { return }
    loadTask?.cancel()
    currentPath = path
    currentProjectRoot = projectRoot
    expanded = []
    // A nil path (nothing selected / Files section hidden) or a missing directory (a vanished
    // workroom) clears the tree without spawning git/jj or a watcher.
    var isDir: ObjCBool = false
    let exists =
      path.map { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) } ?? false
    guard let path, exists, isDir.boolValue else {
      watcher?.stop()
      watcher = nil
      roots = []
      state = path == nil ? .idle : .unavailable
      return
    }
    startWatching(path)
    state = .loading
    roots = []
    reload()
  }

  /// Re-list the current target (a manual refresh, or after a watched filesystem change). Keeps the
  /// existing tree visible while the new listing runs.
  func reload() {
    guard let path = currentPath else { return }
    let projectRoot = currentProjectRoot
    loadTask?.cancel()
    loadTask = Task { [weak self] in
      guard let self else { return }
      let paths = await FileTreeModel.list(
        path: path, projectRoot: projectRoot, runner: self.runner, gate: self.gate)
      guard !Task.isCancelled, self.currentPath == path else { return }
      if let paths {
        self.roots = FileTreeBuilder.build(from: paths)
        self.state = .loaded
      } else {
        self.roots = []
        self.state = .unavailable
      }
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
    let watcher = WorkroomFileWatcher(latency: 1.0) { [weak self] changed in
      // Ignore pure VCS-internal churn (a jj snapshot under `.jj/`, git writing `.git/`) so the tree
      // doesn't self-trigger an endless reload; any real working-tree edit still refreshes it.
      let relevant = changed.contains { !$0.contains("/.git/") && !$0.contains("/.jj/") }
      if relevant { self?.reload() }
    }
    watcher.start(path: path)
    self.watcher = watcher
  }

  /// List the working tree at `path`: try git first (covers git worktrees and colocated jj repos),
  /// then jj (a non-colocated jj workspace has no `.git`). Returns the parsed repo-relative paths, or
  /// `nil` when neither tool yields a listing (not a repo / tool missing). Static + injectable
  /// runner so the git→jj fallthrough is testable. `jj file list` has no `--ignore-working-copy` —
  /// like `WorkroomStatusResolver.resolveJJ`/`DiffResolver`'s `.jjWorkingCopy`, it snapshots `@`, so
  /// it's serialized per project root through `JJSnapshotGate` (`git ls-files` is read-only and
  /// never gated). `projectRoot` falls back to `path` itself when unavailable (never skip the gate
  /// entirely — see `DiffResolver.resolve`'s identical fallback).
  static func list(
    path: String, projectRoot: String?, runner: StatusCommandRunning, gate: JJSnapshotGate = .shared
  ) async -> [String]? {
    for vcs in [FileListVCS.git, .jj] {
      let command = FileListing.command(vcs)
      let result: CommandResult
      if vcs == .jj {
        result =
          (try? await gate.run(projectRoot: projectRoot ?? path) {
            await runner.run(command.executable, command.args, in: path, timeout: 10)
          }) ?? CommandResult(stdout: "", stderr: "", exitCode: 1, timedOut: false)
      } else {
        result = await runner.run(command.executable, command.args, in: path, timeout: 10)
      }
      if result.ok { return FileListing.parse(result.stdout, vcs: vcs) }
    }
    return nil
  }
}
