import WorkroomDomain

/// What a window's inspector is about (#803): the one value its header and every section (Details,
/// Changes, History, Pull Request, Files) read, in place of the selected sidebar item. Each window
/// has its own (`AppStore.inspectorSubject`), derived from that window's selection alone.
enum InspectorSubject: Equatable, Sendable {
  /// The selected workroom or project, while it has an open tab.
  case target(SidebarID)
  /// The folder the focused terminal of a standalone terminal or terminal group is in.
  case followed(FollowedFolder)
  /// Nothing to inspect: no selection, a selection with no open tab, or the Quick Terminal.
  case nothing

  /// The sidebar item the inspector is about, nil for a followed folder and for nothing. What an
  /// action keyed by a sidebar item (the workroom's menu, a commit, a pull request action) takes.
  var sidebarID: SidebarID? {
    if case .target(let sid) = self { return sid }
    return nil
  }

  /// What the version-control sections (Changes, History, Pull Request and the toolbar) reload on.
  /// A followed folder inside a repository keys on the repository's root, so a `cd` within one
  /// repository reloads nothing; outside one it keys on the folder those sections name.
  var repositoryKey: String {
    switch self {
    case .target(let sid): return sid.targetID?.encoded ?? ""
    case .followed(let followed):
      return followed.repository.map { "repository\u{1F}\($0.root)" }
        ?? "folder\u{1F}\(followed.folder)"
    case .nothing: return ""
    }
  }

  /// What the Files section reloads on: a followed folder's tree follows every folder change.
  var folderKey: String {
    switch self {
    case .target(let sid): return sid.targetID?.encoded ?? ""
    case .followed(let followed): return "folder\u{1F}\(followed.folder)"
    case .nothing: return ""
    }
  }
}

/// The folder an inspector follows for a standalone terminal or a terminal group (#803): the
/// focused terminal's folder on this Mac, and the git repository containing it.
struct FollowedFolder: Equatable, Sendable {
  /// The focused terminal's folder: its live working directory, else the folder it started in.
  var folder: String
  /// The innermost git repository containing `folder`, nil outside one.
  var repository: Repository?

  struct Repository: Equatable, Sendable {
    /// The repository's root: the top level of the working tree `folder` is in.
    var root: String
    /// Its checked-out branch, nil when HEAD is detached.
    var branch: String?
    /// Whether the app can write to it (commit, push), not only read it.
    var isWritable: Bool
    /// The folder's path within `root` ("" at the root, no trailing slash), from the folder's real
    /// path: what the Files section and its breadcrumb read, since the shell's spelling of the
    /// folder need not start with git's spelling of the root (#809).
    var subfolder: String = ""
    /// `root` as the shell spells it (`~/dev/app` for a `~/dev` symlinked elsewhere, `/tmp/x` for
    /// `/private/tmp/x`), nil when it is spelled as `root`. Display only: `root` is the identity.
    var spelledRoot: String? = nil

    /// The root as the header, Details and the Files breadcrumb show it.
    var displayRoot: String { spelledRoot ?? root }
  }
}
