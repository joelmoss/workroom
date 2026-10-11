import Defaults
import Foundation

/// The global inspector layout (issue #24): loading the stored collapse state and pane weights at
/// launch, reconciling them with the current section count, and applying activity-bar actions.
/// Moved out of `AppStore.swift` as is. The state it reads and writes stays on `AppStore`
/// (`activeInspectorSection`, `inspectorSizeWeights`, the four `*SectionCollapsed` flags and
/// `isLoadingInspectorState`, whose `didSet`s persist the layout), because an extension cannot store
/// and views observe it through the store.
extension AppStore {
  // MARK: Global inspector layout (issue #24)

  /// Load the global inspector layout (collapse + pane weights) into the live state, or the default
  /// (all expanded, equal) when none is stored. Called once at launch — the layout is global, so it
  /// is deliberately NOT reloaded on workroom switches. Guarded so the resulting `didSet`s don't
  /// immediately persist the values back.
  func loadInspectorState() {
    let (collapsed, weights) = Self.reconcileInspectorState(
      Defaults[.inspectorLayout], sectionCount: InspectorSectionKind.allCases.count)
    isLoadingInspectorState = true
    changesSectionCollapsed = collapsed[InspectorSectionKind.changes.storeIndex]
    filesSectionCollapsed = collapsed[InspectorSectionKind.files.storeIndex]
    prSectionCollapsed = collapsed[InspectorSectionKind.pullRequest.storeIndex]
    historySectionCollapsed = collapsed[InspectorSectionKind.history.storeIndex]
    inspectorSizeWeights = weights
    isLoadingInspectorState = false
  }

  /// Reconcile a persisted inspector layout against the current section count. The count has changed
  /// three times — a Files section was added (3 → 4), Notifications was removed (4 → 3, issue #118),
  /// then History became a section of its own (3 → 4).
  /// Any layout whose element count doesn't match the current section count is discarded to the
  /// all-expanded / equal-weight default rather than mis-mapped onto the new ordering. `nonisolated`
  /// + pure so the migration is unit-testable without an `AppStore` / `Defaults` (issue #24).
  nonisolated static func reconcileInspectorState(
    _ state: InspectorPaneState, sectionCount count: Int
  ) -> (collapsed: [Bool], weights: [Double]) {
    let collapsed =
      state.collapsed.count == count ? state.collapsed : Array(repeating: false, count: count)
    let weights = state.weights.count == count ? state.weights : Array(repeating: 1.0, count: count)
    return (collapsed, weights)
  }

  /// Persist the live inspector layout to the global store. No-op while loading (so a load's `didSet`s
  /// don't write the values straight back), and no-op for a store that isolates its layout for testing.
  func persistInspectorState() {
    guard !isLoadingInspectorState, !isolatesInspectorLayoutForTesting else { return }
    var collapsed = [Bool](repeating: false, count: InspectorSectionKind.allCases.count)
    collapsed[InspectorSectionKind.changes.storeIndex] = changesSectionCollapsed
    collapsed[InspectorSectionKind.files.storeIndex] = filesSectionCollapsed
    collapsed[InspectorSectionKind.pullRequest.storeIndex] = prSectionCollapsed
    collapsed[InspectorSectionKind.history.storeIndex] = historySectionCollapsed
    Defaults[.inspectorLayout] = InspectorPaneState(
      collapsed: collapsed, weights: inspectorSizeWeights)
  }

  /// Record new pane weights reported by the inspector's `NSSplitView` after a divider drag, and
  /// persist them for the selected workroom.
  func updateInspectorSizeWeights(_ weights: [Double]) {
    guard weights.count == InspectorSectionKind.allCases.count, weights != inspectorSizeWeights
    else { return }
    inspectorSizeWeights = weights
    persistInspectorState()
  }

  /// Apply an activity-bar navigation action through the pure `ActivityBarReducer`. Writes the
  /// resulting pane visibility to `Defaults[.showInspector]` first, then **always** assigns
  /// `activeInspectorSection` (even when it doesn't change): `@Published` fires `objectWillChange`
  /// on every set, so this forces the bar + inspector to re-render synchronously on the click and
  /// read the freshly-written `showInspector` (which, as a bare `@Default`, invalidates async).
  func apply(_ action: ActivityBarReducer.Action) {
    let current = ActivityBarReducer.State(
      active: activeInspectorSection, visible: Defaults[.showInspector])
    let next = ActivityBarReducer.reduce(current, action)
    Defaults[.showInspector] = next.visible
    activeInspectorSection = next.active
  }
}
