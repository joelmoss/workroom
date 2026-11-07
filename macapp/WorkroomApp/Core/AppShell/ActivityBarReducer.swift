import Foundation

/// Pure, headless-testable navigation logic for the right activity bar. Kept out of the SwiftUI view
/// (mirrors `EdgeRevealReducer` / `InspectorPanePolicy`) so every branch is unit-tested in the fast
/// `WorkroomAppTests` gate rather than only through a GUI-only XCUITest.
///
/// The three input sources deliberately behave differently:
/// - `.iconClick`: clicking the ACTIVE section's icon while its pane is open collapses the pane (the
///   bar stays); clicking any other icon — or the active icon while the pane is hidden — opens +
///   selects it.
/// - `.shortcut`: a keyboard shortcut ALWAYS opens + selects. It never closes an open pane, so
///   ⌥⌘C on an already-open Changes pane keeps it open rather than surprising the user by toggling.
/// - `.toggleVisibility`: the title-bar toggle flips pane visibility WITHOUT changing the selection.
enum ActivityBarReducer {
  struct State: Equatable {
    var active: ActivitySection
    var visible: Bool
  }

  enum Action: Equatable {
    case iconClick(ActivitySection)
    case shortcut(ActivitySection)
    case toggleVisibility
  }

  static func reduce(_ state: State, _ action: Action) -> State {
    switch action {
    case .iconClick(let section):
      if section == state.active, state.visible {
        return State(active: section, visible: false)
      }
      return State(active: section, visible: true)
    case .shortcut(let section):
      return State(active: section, visible: true)
    case .toggleVisibility:
      return State(active: state.active, visible: !state.visible)
    }
  }
}
