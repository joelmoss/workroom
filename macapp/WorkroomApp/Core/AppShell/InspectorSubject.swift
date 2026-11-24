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

  /// What an inspector section reloads on: a change of key re-points it.
  enum Key: Hashable, Sendable {
    /// Nothing to inspect.
    case none
    /// A workroom or project.
    case target(TargetID)
    /// A followed folder's repository, by its root.
    case repository(root: String)
    /// A followed folder in no repository, or one git couldn't tell.
    case folder(String)
    /// A followed folder whose repository git is still telling: a section waits, and re-keys on
    /// the answer.
    case pending(folder: String)
  }

  /// What the version-control sections (Changes, History, Pull Request and the toolbar) reload on.
  /// A followed folder inside a repository keys on the repository's root, so a `cd` within one
  /// repository reloads nothing; outside one it keys on the folder those sections name.
  var repositoryKey: Key {
    switch self {
    case .target(let sid): return sid.targetID.map(Key.target) ?? .none
    case .followed(let followed):
      if followed.repositoryPending { return .pending(folder: followed.folder) }
      return followed.repository.map { .repository(root: $0.root) } ?? .folder(followed.folder)
    case .nothing: return .none
    }
  }

  /// What the Files section reloads on: a followed folder's tree follows every folder change.
  var folderKey: Key {
    switch self {
    case .target(let sid): return sid.targetID.map(Key.target) ?? .none
    case .followed(let followed):
      return followed.repositoryPending
        ? .pending(folder: followed.folder) : .folder(followed.folder)
    case .nothing: return .none
    }
  }
}

/// The folder an inspector follows for a standalone terminal or a terminal group (#803): the
/// focused terminal's folder on this Mac, and the git repository containing it.
struct FollowedFolder: Equatable, Sendable {
  /// The focused terminal's folder: its live working directory, else the folder it started in.
  var folder: String
  /// The innermost git repository containing `folder`, nil outside one and until `lookup` has
  /// found it.
  var repository: Repository?
  /// How far git has got telling which repository `folder` is in.
  var lookup: Lookup = .resolved

  /// How far git has got telling which repository a followed folder is in.
  enum Lookup: Equatable, Sendable {
    /// It has answered: `repository`, or none.
    case resolved
    /// It is still running for a folder shown for the first time: the header and Details show
    /// the folder, and the repository sections wait without a message.
    case pending
    /// It couldn't tell (a timeout, a repository it refused): the folder is not known to be
    /// outside one. Nothing reads or writes a repository for it until a retry tells.
    case undetermined
  }

  /// Whether git is still telling which repository `folder` is in.
  var repositoryPending: Bool { lookup == .pending }
  /// Whether git couldn't tell which repository `folder` is in, if any.
  var repositoryUndetermined: Bool { lookup == .undetermined }
  /// Whether `folder` is known to be in no git repository: what "Not a git repository" says.
  var isOutsideRepository: Bool { repository == nil && lookup == .resolved }

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
    /// Its git directory, as git named it: where a finished command's re-check reads HEAD, with
    /// no `git` run. Nil where it isn't known.
    var gitDir: String? = nil

    /// The root as the header, Details and the Files breadcrumb show it.
    var displayRoot: String { spelledRoot ?? root }
  }

  /// This folder's repository part alone: what the version-control sections (Changes, History,
  /// Pull Request, the toolbar, the activity bar and the menu) read, so a `cd` within one
  /// repository changes nothing they see. Inside a repository the folder is its root and the
  /// subfolder is empty; outside one (or while git is telling) the folder is kept, since those
  /// sections name it.
  var repositoryPart: FollowedFolder {
    guard var repository, lookup == .resolved else { return self }
    repository.subfolder = ""
    return FollowedFolder(folder: repository.root, repository: repository, lookup: lookup)
  }

  /// This folder's own part, apart from `repositoryPart`: the folder and where it sits in its
  /// repository. What the header, Details and Files read on top of the repository part.
  var folderPart: FolderPart {
    FolderPart(folder: folder, subfolder: repository?.subfolder ?? "")
  }

  /// The folder a followed inspector shows, apart from its repository (`folderPart`).
  struct FolderPart: Equatable, Sendable {
    var folder: String
    var subfolder: String
  }
}

extension FollowedFolder {
  /// `repositoryPart` with `place` put back: the whole followed folder.
  init(repositoryPart: FollowedFolder, place: FolderPart) {
    self = repositoryPart
    if repositoryPart.repository != nil, repositoryPart.lookup == .resolved {
      folder = place.folder
      repository?.subfolder = place.subfolder
    }
  }
}
