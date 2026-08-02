import Foundation

/// The commit sheet's target, carried the way `PendingVCSAction` carries a confirmation's.
///
/// `.sheet(item:)` keys on `id`, so the sheet's `@State` — the draft and the selection — is rebuilt
/// per target and can never leak from one workroom into another.
struct PendingCommit: Identifiable, Equatable, Sendable {
  let sid: SidebarID
  /// `"git"` or `"jj"`. Decides whether per-file selection is offered at all and which second verb
  /// the menu carries.
  let vcs: String
  var id: String { "\(vcs)-\(sid.hashValue)" }
}

/// The commit sheet's pure logic: what the message is, what is selected, and what the button says.
///
/// Separated from the view for the reason `ChangeBadge` and `VCSSyncPresenter` are: these are
/// many-case decisions that drift silently, and none of them is reachable from a test through
/// SwiftUI. The view holds state and renders; every rule below is decided here.
enum CommitDraft {

  /// Compose the message git or jj will record.
  ///
  /// Summary and body are joined by a BLANK line, which is the convention every tool downstream
  /// relies on to split a subject from its body. Both halves are trimmed, and an empty body yields a
  /// subject-only message with no trailing newlines for `--cleanup` to strip.
  static func message(summary: String, body: String) -> String {
    let subject = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return detail.isEmpty ? subject : "\(subject)\n\n\(detail)"
  }

  /// The message to record, preserving `original` byte for byte when neither field was edited.
  ///
  /// `split` and `message` are deliberately not inverses: `split` takes line 0 as the summary and the
  /// rest as the body, while `message` always rejoins them with a BLANK line. So a stored jj
  /// description of `"one\ntwo"` — no blank separator, which jj permits — came back as
  /// `"one\n\ntwo"`. The user pressed Describe without touching the text and their message changed
  /// underneath them.
  ///
  /// Normalising is right for a message the user actually wrote here (the blank line is what every
  /// tool downstream splits on). Rewriting one they didn't touch is not. This tells the two apart.
  static func message(summary: String, body: String, preserving original: String?) -> String {
    guard let original else { return message(summary: summary, body: body) }
    let stored = split(message: original)
    guard stored.summary == summary, stored.body == body else {
      return message(summary: summary, body: body)
    }
    return original
  }

  /// Split a stored message back into the two fields, for prefilling from jj's `@` description.
  ///
  /// The first line is the summary and everything after the first blank line is the body. Used
  /// against the FULL description — `JJCommitChanges.description` carries only the first line, so
  /// prefilling from that and describing again would silently discard the body.
  static func split(message: String) -> (summary: String, body: String) {
    let normalized = message.replacingOccurrences(of: "\r\n", with: "\n")
    var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else { return ("", "") }
    let summary = lines.removeFirst().trimmingCharacters(in: .whitespaces)
    let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return (summary, body)
  }

  /// The files a commit would record, given what the user has EXCLUDED.
  ///
  /// Deselections are stored, never selections, and this is the reason. Coding agents run in this
  /// app's own embedded terminals and write files continuously, so the change set moves underneath
  /// an open dialog. With a set of *selected* paths there are only two possible behaviours when a new
  /// path appears — include it silently (committing a file nobody reviewed, which is the exact defect
  /// per-file selection exists to prevent) or reset the selection (throwing away the user's
  /// deliberate exclusions). Storing exclusions makes a new file arrive checked, which is the honest
  /// default, and makes an exclusion survive every refresh.
  ///
  /// A path that vanishes from the change set drops out on its own, so the excluded set never needs
  /// pruning.
  static func selected(from files: [ChangedFile], excluding excluded: Set<String>) -> [ChangedFile]
  {
    files.filter { !excluded.contains($0.path) }
  }

  /// The primary button's label. Names the count so what is about to be recorded is never implicit —
  /// once the list scrolls, "Commit" alone is an unverifiable claim.
  static func commitLabel(selectedCount: Int, vcs: String) -> String {
    // jj commits the whole change and offers no per-file selection, so a count would imply a choice
    // that isn't on offer.
    guard vcs != "jj" else { return "Commit" }
    switch selectedCount {
    case 1: return "Commit 1 file"
    default: return "Commit \(selectedCount) files"
    }
  }

  /// Why Commit is unavailable, as a sentence, or nil when it is available.
  ///
  /// Returned as text rather than a Bool because these must render as a persistent inline line: four
  /// different blocked states explained only by a tooltip would be invisible to anyone who doesn't
  /// hover a control that already looks dead, and unavailable to VoiceOver entirely.
  static func blockedReason(
    vcs: String, summary: String, selectedCount: Int, totalCount: Int, conflicted: Bool,
    sequencer: String?
  ) -> String? {
    if let reason = repoStateBlockedReason(conflicted: conflicted, sequencer: sequencer) {
      return reason
    }
    if totalCount == 0 && vcs != "jj" {
      return "Nothing has changed in this workroom yet."
    }
    if vcs != "jj" && selectedCount == 0 {
      return "Select at least one file to commit."
    }
    return summaryBlockedReason(summary)
  }

  /// Why the message-only verb — git's Amend, jj's Describe — is unavailable.
  ///
  /// The repo-state and summary rules, and deliberately NOT the file-count ones: both verbs rewrite a
  /// message and take no pathspec, so "select at least one file" is not a precondition for either.
  /// Sharing the rest is the point. The button used to enforce only its own summary check, which left
  /// it live over unresolved conflicts that the primary refused and the engine then rejected anyway —
  /// and it trimmed a different character set, so a summary of one newline blocked Commit while Amend
  /// would rewrite the last commit's message with it.
  static func messageOnlyBlockedReason(
    summary: String, conflicted: Bool, sequencer: String?
  ) -> String? {
    repoStateBlockedReason(conflicted: conflicted, sequencer: sequencer)
      ?? summaryBlockedReason(summary)
  }

  /// The states of the repo itself that stop any commit verb, shared by both rules above.
  static func repoStateBlockedReason(conflicted: Bool, sequencer: String?) -> String? {
    if let sequencer {
      return "A \(sequencer) is in progress. Finish it in the terminal before committing."
    }
    // git refuses to commit unmerged paths outright. jj records conflicts inside commits and would
    // happily accept this, but "Commit" reading as "done" over unresolved conflicts is a UX decision,
    // not a capability one — so both backends say the same thing.
    if conflicted {
      return "Some files still have unresolved conflicts. Resolve them first."
    }
    return nil
  }

  /// One trimming rule for every verb, so two buttons can never disagree about what "empty" means.
  static func summaryBlockedReason(_ summary: String) -> String? {
    summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Write a summary to describe this change." : nil
  }
}
