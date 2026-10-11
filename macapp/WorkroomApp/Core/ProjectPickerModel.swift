import Foundation
import WorkroomDomain

/// New Workroom project picker (issue #81): a thin adapter over the generic `PickerModel` that
/// matches the query against each project's `displayName`. The shared core lives in `PickerModel`
/// so the New / Open pickers can't drift; this preserves the project-specific call sites and keeps
/// `ProjectPickerModelTests` exercising the behaviour through the adapter.
///
///   type ──► filtered(projects, query)     → the visible rows
///   ↑/↓  ──► move(highlight, by:, count:)   → clamped index, NO side effects (creation is click/⏎ only)
///   ⏎    ──► selection(filtered, highlight) → the project to create, or nil (empty / no-match guard)
enum ProjectPickerModel {
  /// Projects matching `query` by fuzzy, multi-token subsequence over `displayName` (issue #94
  /// follow-up): the query is split on whitespace and every token must be a case-insensitive
  /// subsequence of the name (so "ap" matches "alpha", "pro a" needs both tokens). An empty query
  /// returns every project in the original order.
  static func filtered(_ projects: [Project], query: String) -> [Project] {
    PickerModel.fuzzyFiltered(projects, query: query) { $0.displayName }
  }

  /// Clamp `index` into a list of `count` items. Returns 0 for an empty list.
  static func clamped(_ index: Int, count: Int) -> Int {
    PickerModel.clamped(index, count: count)
  }

  /// Move `highlight` by `delta`, clamped to `[0, count-1]`. No side effects.
  static func move(highlight: Int, by delta: Int, count: Int) -> Int {
    PickerModel.move(highlight: highlight, by: delta, count: count)
  }

  /// The project Return/click should create: `filtered[highlight]`, or nil when out of range.
  static func selection(filtered: [Project], highlight: Int) -> Project? {
    PickerModel.selection(filtered: filtered, highlight: highlight)
  }
}
