import Foundation

/// The three numbers every split shares: the pane floors and the gutter between panes. Both splits
/// read them, the workroom split (`AppStore+WorkroomSplit`, `WorkroomSplitView`) and the terminal
/// split (`TerminalPanes`, `PaneTreeView`), and so do the layout math and the fit guards in
/// `PaneTreeLayout`, so the renderer's clamp and the guards can never disagree about a floor.
public enum PaneMetrics {
  /// Smallest usable pane WIDTH (points). A split is refused when it would shrink a pane below this;
  /// the renderer applies the same minimum as its divider clamp.
  ///
  /// Width and height need different floors because a pane's chrome is horizontal: a row of toolbar
  /// furniture is what sets the width floor, and it is wider than people guess. That furniture used to
  /// live in the tab strip; since issue #150 each pane carries it in its own title bar, so the budget
  /// moved but the arithmetic barely did. The *widest* bar a pane can show is a diff pane's FULL row:
  /// four 20pt button footprints (Open File, split right, split down, close) plus the ~60pt
  /// unified/side-by-side switch, a 9pt divider and the 2pt spacings ≈ 155pt trailing, plus the bar's
  /// 10pt leading inset. (The overflow menu is not in that total — it belongs to the COLLAPSED row,
  /// which renders instead of this one, never beside it.) At 300pt that leaves the title ~135pt.
  ///
  /// The buttons are deliberately denser than the title bars above — see `PaneTitleBarMetrics`. They
  /// were 28pt footprints at 6pt spacing, which left the title only ~100pt here; the floor did not
  /// move with them, so the change bought the title width rather than allowing narrower panes.
  ///
  /// 300pt is also about 41 terminal columns, which is the first width where a terminal is honestly
  /// usable rather than merely non-degenerate.
  public static let minPaneWidth: CGFloat = 300
  /// Smallest usable pane HEIGHT (points). Raised 120 → 150 with issue #150: a pane now carries 56pt
  /// of horizontal chrome (a 28pt title bar above the content and a 28pt status bar below it) where it
  /// used to carry 28. 150 keeps the same ~94pt of actual content the old 120 left, rather than
  /// shrinking every stacked pane to roughly four terminal rows.
  ///
  /// Read together with `TerminalPanes.fits(splitting:)`, which measures the whole PANE rect —
  /// chrome included — for every content kind, so this number means the same thing for a terminal and
  /// a diff pane.
  public static let minPaneHeight: CGFloat = 150
  /// Inter-pane gutter thickness (points), shared by the fit guard and the renderer. No separator
  /// rule is drawn anymore, so this is just the gap between panes and the width of the (invisible)
  /// resize hit-zone — kept tight, since the panes' own rounded borders mark the boundary.
  public static let dividerThickness: CGFloat = 2
}
