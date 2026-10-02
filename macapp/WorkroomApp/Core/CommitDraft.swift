import Foundation

/// The commit sheet's target, carried the way `PendingVCSAction` carries a confirmation's.
///
/// `.sheet(item:)` keys on `id`, so the sheet's `@State` — the draft and the selection — is rebuilt
/// per target and can never leak from one workroom into another.
struct PendingCommit: Identifiable, Equatable, Sendable {
  let sid: SidebarID
  var id: String { "\(sid.hashValue)" }
}

/// The commit sheet's pure logic: what the message is, what is selected, and what the button says.
///
/// Separated from the view for the reason `ChangeBadge` and `VCSSyncPresenter` are: these are
/// many-case decisions that drift silently, and none of them is reachable from a test through
/// SwiftUI. The view holds state and renders; every rule below is decided here.
enum CommitDraft {

  /// Compose the message git will record.
  ///
  /// Summary and body are joined by a BLANK line, which is the convention every tool downstream
  /// relies on to split a subject from its body. Both halves are trimmed, and an empty body yields a
  /// subject-only message with no trailing newlines for `--cleanup` to strip.
  static func message(summary: String, body: String) -> String {
    let subject = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return detail.isEmpty ? subject : "\(subject)\n\n\(detail)"
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
  static func commitLabel(selectedCount: Int) -> String {
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
    summary: String, selectedCount: Int, totalCount: Int, conflicted: Bool, sequencer: String?
  ) -> String? {
    if let reason = repoStateBlockedReason(conflicted: conflicted, sequencer: sequencer) {
      return reason
    }
    if totalCount == 0 {
      return "Nothing has changed in this workroom yet."
    }
    if selectedCount == 0 {
      return "Select at least one file to commit."
    }
    return summaryBlockedReason(summary)
  }

  /// Why the message-only verb, Amend, is unavailable.
  ///
  /// The repo-state and summary rules, and deliberately NOT the file-count ones: both verbs rewrite a
  /// message and takes no pathspec, so "select at least one file" is not a precondition for it.
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
    // git refuses to commit unmerged paths outright.
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

/// Only a failed preflight can be retried. Clicks while a read is pending cannot start another
/// callback that might arrive after the sheet has begun committing.
struct CommitPreflightState {
  private enum State { case idle, loading, ready, failed }
  private var state: State = .idle
  var isReady: Bool { state == .ready }
  /// The sheet's actions are disabled while this is true: a click would only be rejected by `begin()`.
  var isLoading: Bool { state == .loading }

  mutating func begin() -> Bool {
    guard state == .idle || state == .failed else { return false }
    state = .loading
    return true
  }

  @discardableResult
  mutating func finish(succeeded: Bool) -> Bool {
    guard state == .loading else { return false }
    state = succeeded ? .ready : .failed
    return true
  }
}
