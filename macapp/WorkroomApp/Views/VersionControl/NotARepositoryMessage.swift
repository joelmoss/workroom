import DesignSystem
import SwiftUI

/// What a version-control section (History; Changes and Pull Request too, #807) says when the
/// folder a terminal's inspector follows is in no git repository (#803), or when git couldn't tell
/// which one it is in: why it is empty, and the folder, `~`-relative, beneath. Laid out as
/// `InlineMessage`, the glyph and both lines at its insets, so it sits where the section's other
/// one-line states do.
struct NotARepositoryMessage: View {
  /// The followed folder.
  let path: String
  /// Git couldn't tell which repository the folder is in (`FollowedFolder.repositoryUndetermined`),
  /// rather than answering that it is in none.
  var undetermined = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
      Image(systemName: undetermined ? "exclamationmark.triangle" : "folder.badge.questionmark")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(FontRole.body).foregroundStyle(.secondary)
        Text(StatusBarCwdSegment.abbreviate(path))
          .font(FontRole.detail).foregroundStyle(.tertiary)
          .lineLimit(1).truncationMode(.middle)
      }
    }
    .padding(.vertical, Spacing.s).padding(.horizontal, Spacing.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(Self.help(path: path, undetermined: undetermined))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title): \(path)")
    .accessibilityIdentifier(
      undetermined ? "inspector.repositoryUndetermined" : "inspector.notARepository")
  }

  private var title: String {
    undetermined ? "Couldn’t read the repository" : "Not a git repository"
  }

  /// The tooltip, which the header shares.
  static func help(path: String, undetermined: Bool) -> String {
    undetermined
      ? "git couldn’t tell which repository \(path) is in. It may be on a slow or disconnected "
        + "volume, or owned by another user (add it to safe.directory). Workroom tries again shortly."
      : "\(path) is not in a git repository"
  }
}

#Preview("NotARepositoryMessage") {
  VStack {
    NotARepositoryMessage(path: NSHomeDirectory() + "/Downloads/scratch")
    NotARepositoryMessage(path: "/Volumes/share/app", undetermined: true)
  }
  .frame(width: 280)
}
