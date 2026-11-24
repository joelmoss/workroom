import Foundation

/// What the Files section lists (#809): a repository's working tree, or the part of it under one
/// of its folders, or a plain folder outside any repository.
enum FilesRoot: Equatable, Sendable {
  /// `root`'s tracked and untracked-but-not-ignored files under `subfolder` ("" for all of them),
  /// as git lists them. File paths stay relative to `root`, so a file is the same file whichever of
  /// its folders the tree shows.
  case repository(root: String, subfolder: String)
  /// A folder outside any repository, listed from disk one level at a time.
  case folder(String)

  /// The folder the tree shows, as an absolute path.
  var path: String {
    switch self {
    case .repository(let root, let subfolder):
      return subfolder.isEmpty ? root : (root as NSString).appendingPathComponent(subfolder)
    case .folder(let path): return path
    }
  }

  /// The folder a file's tree-relative path is relative to: what a file opened from the tree reads.
  var fileRoot: String {
    switch self {
    case .repository(let root, _): return root
    case .folder(let path): return path
    }
  }
}

/// The trail above a followed folder's Files tree (#809): from the repository's root, or `~` (else
/// `/`) outside one, down to the terminal's folder. Clicking a segment browses that folder in Files
/// alone; the terminal keeps its folder, and its next folder change snaps Files back.
struct FilesBreadcrumb: Equatable, Sendable {
  struct Segment: Equatable, Sendable {
    /// What the segment reads: a folder's name, `~`, or `/`.
    var name: String
    /// The folder's absolute path, for its tooltip.
    var path: String
    /// What browsing to it lists.
    var root: FilesRoot
  }

  enum Base: Equatable, Sendable {
    case repository, home, fileSystem
  }

  /// Base first, the terminal's folder last.
  var segments: [Segment]
  var base: Base
  /// The segment the tree shows: the last unless browsed away.
  var shownIndex: Int

  /// The terminal's own folder, always the last segment.
  var leafIndex: Int { segments.count - 1 }
  /// Whether the tree shows a folder other than the terminal's.
  var isBrowsedAway: Bool { shownIndex != leafIndex }

  /// The trail to `folder`. Inside a repository it starts at the root and walks git's own
  /// `subfolder` (so the shell's spelling of `folder` need not start with git's root); outside one
  /// it starts at `home` when `folder` is in it, else at `/`. `shown` is the folder browsed to.
  static func make(
    folder: String, repository: FollowedFolder.Repository?, home: String,
    shown: FilesRoot? = nil
  ) -> FilesBreadcrumb {
    var segments: [Segment] = []
    let base: Base
    if let repository {
      base = .repository
      // Listed by the real root, shown in the shell's spelling of it.
      let root = repository.root
      let shownRoot = repository.displayRoot
      segments.append(
        Segment(
          name: Self.name(of: shownRoot), path: shownRoot,
          root: .repository(root: root, subfolder: "")))
      var walked: [String] = []
      for component in repository.subfolder.split(separator: "/").map(String.init) {
        walked.append(component)
        let subfolder = walked.joined(separator: "/")
        segments.append(
          Segment(
            name: component, path: (shownRoot as NSString).appendingPathComponent(subfolder),
            root: .repository(root: root, subfolder: subfolder)))
      }
    } else {
      let trimmedHome = Self.trimmed(home)
      let start: String
      if folder == trimmedHome || folder.hasPrefix(trimmedHome + "/"), trimmedHome != "/" {
        base = .home
        start = trimmedHome
        segments.append(Segment(name: "~", path: trimmedHome, root: .folder(trimmedHome)))
      } else {
        base = .fileSystem
        start = ""
        segments.append(Segment(name: "/", path: "/", root: .folder("/")))
      }
      var walked = start
      for component in folder.dropFirst(start.count).split(separator: "/").map(String.init) {
        walked += "/" + component
        segments.append(Segment(name: component, path: walked, root: .folder(walked)))
      }
    }
    let shownIndex = shown.flatMap { shown in segments.firstIndex { $0.root == shown } }
    return FilesBreadcrumb(
      segments: segments, base: base, shownIndex: shownIndex ?? segments.count - 1)
  }

  private static func name(of path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? path : name
  }

  private static func trimmed(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}

extension FollowedFolder.Repository {
  /// This repository with `folder` placed in it (#809): `subfolder` from the folder's real path
  /// against the root's, and `spelledRoot` from the folder's own spelling, so a symlinked `~/dev` or
  /// `/tmp` keeps its `~` or `/tmp` in the header and the breadcrumb. Touches the disk (`realpath`),
  /// so it runs off the main actor. A folder whose real path is not under the root (a
  /// `core.worktree` pointing elsewhere) is left at the root, spelled as the root is.
  nonisolated func placed(in folder: String) -> Self {
    var placed = self
    guard let real = Self.realPath(folder) else { return placed }
    let realRoot = Self.realPath(root) ?? root
    let subfolder: String
    if real == realRoot {
      subfolder = ""
    } else if real.hasPrefix(realRoot == "/" ? "/" : realRoot + "/") {
      subfolder = String(real.dropFirst(realRoot == "/" ? 1 : realRoot.count + 1))
    } else {
      return placed
    }
    placed.subfolder = subfolder
    let depth = subfolder.split(separator: "/").count
    let spelled = folder.split(separator: "/").map(String.init)
    guard spelled.count >= depth else { return placed }
    let spelledRoot = "/" + spelled.dropLast(depth).joined(separator: "/")
    if spelledRoot != root, Self.realPath(spelledRoot) == realRoot {
      placed.spelledRoot = spelledRoot
    }
    return placed
  }

  /// `realpath(3)`: unlike `resolvingSymlinksInPath`, it keeps `/private`, as the root does.
  private nonisolated static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
