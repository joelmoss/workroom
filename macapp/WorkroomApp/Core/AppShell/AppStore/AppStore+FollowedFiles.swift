import Foundation
import WorkroomDomain

/// A folder the Files section was browsed to from its breadcrumb (#809), and the followed folder
/// and target it was browsed from, so it never outlives either.
struct FilesBrowse: Equatable {
  var target: TargetID
  var folder: String
  var root: FilesRoot
}

/// The Files section of a followed folder (#809, ADR 0081): rooted at the terminal's folder, with
/// a breadcrumb from the repository's root (or `~`, else `/`) down to it. A breadcrumb click
/// browses another folder in Files alone; the terminal's next folder change snaps Files back.
extension AppStore {
  /// What Files lists for a followed folder: the browsed folder, else the terminal's. Nil for any
  /// other subject, whose Files lists its target's tree, and while the folder's repository is
  /// pending, which decides how it lists.
  var followedFilesRoot: FilesRoot? {
    guard case .followed(let followed) = inspectorSubject, !followed.repositoryPending else {
      return nil
    }
    if let browsed = currentFilesBrowse(followed) { return browsed.root }
    guard let repository = followed.repository else { return .folder(followed.folder) }
    return .repository(root: repository.root, subfolder: repository.subfolder)
  }

  /// The breadcrumb above a followed folder's Files tree; nil for any other subject.
  var filesBreadcrumb: FilesBreadcrumb? {
    guard case .followed(let followed) = inspectorSubject, !followed.repositoryPending else {
      return nil
    }
    return FilesBreadcrumb.make(
      folder: followed.folder, repository: followed.repository, home: NSHomeDirectory(),
      shown: currentFilesBrowse(followed)?.root)
  }

  /// The folder a file opened from the Files tree is relative to, when not the target's own.
  var filesFileRoot: String? { followedFilesRoot?.fileRoot }

  /// Point Files at the inspector's subject: a followed folder's tree, else the target's.
  func activateFileTree() {
    // A pending folder lists once its repository is known; the answer re-keys Files.
    if case .followed(let followed) = inspectorSubject, followed.repositoryPending { return }
    if let root = followedFilesRoot {
      fileTree.activate(root: root)
    } else {
      fileTree.activate(target: inspectorTarget)
    }
  }

  /// Browse breadcrumb segment `index` in Files, leaving the terminal where it is. The terminal's
  /// own folder (the last segment) returns to following it.
  func browseFiles(toSegment index: Int) {
    guard case .followed(let followed) = inspectorSubject, let target = selectedTargetID?.targetID,
      let breadcrumb = filesBreadcrumb, breadcrumb.segments.indices.contains(index)
    else { return }
    filesBrowse =
      index == breadcrumb.leafIndex
      ? nil
      : FilesBrowse(target: target, folder: followed.folder, root: breadcrumb.segments[index].root)
    activateFileTree()
  }

  /// The browse that applies to `followed`: one made from this target and this folder only.
  private func currentFilesBrowse(_ followed: FollowedFolder) -> FilesBrowse? {
    guard let browse = filesBrowse, browse.folder == followed.folder,
      browse.target == selectedTargetID?.targetID
    else { return nil }
    return browse
  }
}
