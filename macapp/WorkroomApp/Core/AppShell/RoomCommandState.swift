import SwiftUI
import WorkroomVCS

/// The inspected target's menu presentation. Status clocks, line counts, reviews and other
/// targets' status writes do not change these values and must not rebuild every command (#534).
struct RoomCommandState: Equatable {
  struct PullRequest: Equatable {
    let number: Int
    let url: String
    let draftAction: PRAction?
  }

  let canCommit: Bool
  let pullRequest: PullRequest?
  let canChangeDraft: Bool
  let canRevealInFinder: Bool

  @MainActor static func read(_ store: AppStore) -> Self {
    // Keep the filesystem-dependent Finder gate fresh on the same status updates as before,
    // without making the Commands body itself observe the whole status dictionary.
    let canReveal = store.selectedTarget.map { !$0.isMissing } ?? false
    guard !store.hasModalPresentation, let sid = store.inspectorTargetID else {
      return Self(
        canCommit: false, pullRequest: nil, canChangeDraft: false, canRevealInFinder: canReveal)
    }
    let pr = store.githubCLIStatus == .available ? store.workroomStatuses[sid]?.pr : nil
    let draftAction = pr.flatMap {
      PRAction.available(for: $0).first { $0 == .markReady || $0 == .convertToDraft }
    }
    return Self(
      canCommit: store.canCommit(sid),
      pullRequest: pr.map { PullRequest(number: $0.number, url: $0.url, draftAction: draftAction) },
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
