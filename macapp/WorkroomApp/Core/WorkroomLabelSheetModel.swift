import Foundation
import WorkroomDomain

/// Pure presentation/validation rules for `WorkroomLabelSheet` (issue #41), extracted so the
/// submit-enabled logic is unit-testable without rendering SwiftUI — mirrors `DeleteProjectSheetModel`.
///
/// A label is a display-only alias. The sheet lets the user set or edit it; *removal* is a separate
/// context-menu action ("Remove Label"), so the sheet never submits a blank value — it just disables
/// the button. Submit is allowed only when the trimmed input is a real change to a non-empty,
/// non-colliding label.
enum WorkroomLabelSheetModel {
  /// The outcome of validating the field, driving both the button's enabled state and the inline
  /// collision warning.
  struct Validation: Equatable {
    let canSubmit: Bool
    /// True when the input duplicates another workroom's display name in the same project — shown as
    /// a warning so the user understands *why* submit is disabled (vs. simply being blank/unchanged).
    let collides: Bool
  }

  /// Validate `input` for a workroom whose current label is `current`, against the display names of
  /// its **siblings** (every other workroom in the same project, each already resolved to its
  /// label-or-name). Reuses `WorkroomDomain.Workroom.normalizedLabel` so the "is this blank?" rule matches
  /// `displayName` exactly.
  ///
  /// Disabled when the normalized input is empty, unchanged from the current label, or equal to a
  /// sibling's display name (which would render two rows identically).
  static func validate(input: String, current: String?, siblingDisplayNames: [String]) -> Validation
  {
    guard let normalized = WorkroomDomain.Workroom.normalizedLabel(input) else {
      return Validation(canSubmit: false, collides: false)  // blank ⇒ no label; use Remove instead
    }
    if normalized == WorkroomDomain.Workroom.normalizedLabel(current) {
      return Validation(canSubmit: false, collides: false)  // unchanged
    }
    if siblingDisplayNames.contains(normalized) {
      return Validation(canSubmit: false, collides: true)
    }
    return Validation(canSubmit: true, collides: false)
  }
}
