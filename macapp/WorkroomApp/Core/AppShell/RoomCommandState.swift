import SwiftUI
import WorkroomVCS

/// The inspected target's menu presentation. Status clocks, line counts, reviews and other
/// targets' status writes do not change these values and must not rebuild every command (#534).
struct RoomCommandState: Equatable {
  struct PullRequest: Equatable {
    let number: Int
    let url: String
    let draftAction: PRAction?
    /// What the draft item acts on, read with `number`: a click after a `cd` then still pairs
    /// the repository the menu showed with its own pull request.
    let target: VCSActionTarget
  }

  let canCommit: Bool
  let pullRequest: PullRequest?
  let canChangeDraft: Bool
  let canRevealInFinder: Bool

  @MainActor static func read(_ store: AppStore) -> Self {
    // Keep the filesystem-dependent Finder gate fresh on the same status updates as before,
    // without making the Commands body itself observe the whole status dictionary.
    let canReveal = store.selectedTarget.map { !$0.isMissing } ?? false
    // Commit and the pull request items act on a followed repository too, registered in place or
    // not (#808): Commit on what `inspectorActionTarget` names, so nowhere the app can't write to;
    // the pull request on `inspectorPullRequestTarget`'s, since `gh` writes only on GitHub.
    guard !store.modals.hasModalPresentation else {
      return Self(
        canCommit: false, pullRequest: nil, canChangeDraft: false, canRevealInFinder: canReveal)
    }
    let target = store.inspectorPullRequestTarget
    let pr =
      store.vcsStatus.githubCLIStatus == .available
      ? target.flatMap { store.vcsStatus.status(for: $0)?.pr } : nil
    let draftAction = pr.flatMap {
      PRAction.available(for: $0).first { $0 == .markReady || $0 == .convertToDraft }
    }
    return Self(
      canCommit: store.canCommit(store.inspectorActionTarget),
      pullRequest: pr.flatMap { pr in
        target.map {
          PullRequest(number: pr.number, url: pr.url, draftAction: draftAction, target: $0)
        }
      },
      canChangeDraft: draftAction != nil && !store.prActionInFlight,
      canRevealInFinder: canReveal)
  }
}

private struct RoomCommandStateKey: FocusedValueKey {
  typealias Value = RoomCommandState
}

extension FocusedValues {
  var roomCommandState: RoomCommandState? {
    get { self[RoomCommandStateKey.self] }
    set { self[RoomCommandStateKey.self] = newValue }
  }
}

/// Isolate status observation here so deriving the focused value does not invalidate RootView.
struct RoomCommandStateValues: ViewModifier {
  let store: AppStore

  func body(content: Content) -> some View {
    content.focusedSceneValue(\.roomCommandState, RoomCommandState.read(store))
  }
}
