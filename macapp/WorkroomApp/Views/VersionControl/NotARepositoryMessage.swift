import DesignSystem
import SwiftUI

/// What a version-control section (History; Changes and Pull Request too, #807) says when the
/// folder a terminal's inspector follows is in no git repository (#803): why it is empty, and the
/// folder, `~`-relative, beneath. Laid out as `InlineMessage`, the glyph and both lines at its
/// insets, so it sits where the section's other one-line states do.
struct NotARepositoryMessage: View {
  /// The followed folder.
  let path: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
      Image(systemName: "folder.badge.questionmark").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text("Not a git repository").font(FontRole.body).foregroundStyle(.secondary)
        Text(StatusBarCwdSegment.abbreviate(path))
          .font(FontRole.detail).foregroundStyle(.tertiary)
          .lineLimit(1).truncationMode(.middle)
      }
    }
    .padding(.vertical, Spacing.s).padding(.horizontal, Spacing.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .help("\(path) is not in a git repository")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Not a git repository: \(path)")
    .accessibilityIdentifier("inspector.notARepository")
  }
}

#Preview("NotARepositoryMessage") {
  NotARepositoryMessage(path: NSHomeDirectory() + "/Downloads/scratch")
    .frame(width: 280)
}
