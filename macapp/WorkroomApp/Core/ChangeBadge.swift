import SwiftUI

/// The change-kind badge the Changes panel puts in front of every changed file: a monospaced letter
/// plus a themed colour, and the spelled-out word used by the accessibility label and tooltip.
///
/// Lives here rather than inline on the row view so it can be unit-tested — the mapping is exactly
/// the kind of seven-case switch that silently drifts. It drifted once already: `.conflicted` used
/// to render as `"C"` in `diffRemoveFg`, i.e. deletion's colour, so a file needing resolution read
/// as a removal. `"!"` + `tokens.conflict` matches what `DiffViewer` and `ChangesetDetailView`
/// already show for a conflict.
///
/// Those two views still carry their own hardcoded palettes (`.green`/`.yellow`/`.red`/`.orange`);
/// folding them onto this mapping is a tracked follow-up (it restyles every kind in both views, so
/// it wants its own visual pass) — see TODOS.md.
enum ChangeBadge {
  /// The one-character badge. `!` for a conflict (not `C`): it reads as "needs attention" and lines
  /// up with the other two views.
  static func letter(_ change: ChangedFile.Change) -> String {
    switch change {
    case .modified: return "M"
    case .added: return "A"
    case .deleted: return "D"
    case .renamed: return "R"
    case .untracked: return "?"
    case .conflicted: return "!"
    case .other: return "\u{2022}"
    }
  }

  /// The badge colour, resolved from the active theme's tokens.
  static func color(_ change: ChangedFile.Change, _ tokens: ThemeTokens) -> Color {
    switch change {
    case .added: return tokens.diffAddFg
    case .deleted: return tokens.diffRemoveFg
    case .conflicted: return tokens.conflict
    case .modified, .renamed: return tokens.warning
    case .untracked, .other: return tokens.fgMuted
    }
  }

  /// The change kind spelled out, for the row's accessibility label and tooltip.
  static func word(_ change: ChangedFile.Change) -> String {
    switch change {
    case .modified: return "modified"
    case .added: return "added"
    case .deleted: return "deleted"
    case .renamed: return "renamed"
    case .untracked: return "untracked"
    case .conflicted: return "conflicted"
    case .other: return "changed"
    }
  }
}
