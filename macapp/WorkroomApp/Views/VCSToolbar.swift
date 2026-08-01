import SwiftUI

/// Every number the VCS toolbar uses, in one place.
///
/// The horizontal ones are chosen so the toolbar aligns *by construction* with the section header
/// beneath it rather than by eye: `outerInset` + `glyphSlot` + `glyphSpacing` puts the branch glyph's
/// centre and the branch name's left edge exactly where `SectionHeader`'s chevron centre and title land
/// (`InspectorSplitView.headerLabel` uses the same 12 / 12 / 7).
enum VCSToolbarMetrics {
  /// 11pt semibold title (13pt line) + 1pt + 10pt caption (12pt line) = 26, plus 5pt above and below.
  /// Two lines genuinely don't fit the section headers' 34pt, and 36 also reads as a distinct band.
  ///
  /// The count pills sit on the title line, so that row is as tall as a `.caption2` capsule rather than
  /// 13pt whenever one is shown. That takes the stack a couple of points past 26 and leaves the band
  /// unchanged — the slack was already there, which is why the pills could move up without this number
  /// moving with them.
  static let height: CGFloat = 36
  static let outerInset: CGFloat = 12
  /// Inner edges of the segments — tighter than `outerInset` so the middle segment isn't starved.
  static let innerInset: CGFloat = 8
  /// Matches `SectionHeader`'s chevron `.frame(width: 12)`.
  static let glyphSlot: CGFloat = 12
  /// Matches `SectionHeader`'s `HStack(spacing: 7)`.
  static let glyphSpacing: CGFloat = 7
  /// Between the inspector's 11pt header glyphs and the pane bar's 13pt action icons: it has to hold
  /// against a bold 11pt title without reading as a pane-bar button.
  static let glyph: CGFloat = 12
  /// 22pt well plus 4pt either side — `ToolbarIconButtonStyle.footprint` rounded to a divider-bounded cell.
  static let fetchWidth: CGFloat = 30

  static let titleFont = Font.system(size: 11, weight: .semibold)
  static let captionFont = Font.system(size: 10)
  /// The single-line states. A lone 10pt dim line in a 36pt bar reads as a rendering bug, so the solo
  /// subtitle is a step up in both size and contrast.
  static let soloFont = Font.system(size: 11)

  /// ONE floor, shared by the branch and sync segments, because the two are equal width.
  ///
  /// Equal width is what makes the bar read as two halves plus a button rather than three arbitrary
  /// cells, and it's only achievable if both segments have the same floor as well as the same `maxWidth`:
  /// an `HStack` divides slack evenly, so unequal minimums stay unequal by their difference at every
  /// width. The value is set by the narrowest inspector — `2 × 114 + fetchWidth + 2 dividers = 260`,
  /// exactly the 260pt minimum. (It replaces a 100/126 split with a 220 cap on the branch cell; the cap
  /// existed to stop a short name hoarding width, which an even division already does.)
  static let segmentMinWidth: CGFloat = 114

  /// Verbatim from `PRNumberBadge`, so the toolbar's pill matches the ref pill 40pt below it.
  static let pillHorizontalPadding: CGFloat = 5
  static let pillVerticalPadding: CGFloat = 1
  /// The pill's ↑/↓ glyph. Smaller than `glyph` on purpose — it sits inside a `.caption2` capsule and
  /// has to read as a direction marker beside the count, not as an icon in its own right.
  static let pillArrowGlyph: CGFloat = 7
}

/// The VCS toolbar: current branch, a sync segment that shows and performs the right remote action, and
/// a fetch button — divided into three full-height cells.
///
/// Lives at the top of `RightInspector`, above the section stack, and only for the Changes activity
/// section. Deliberately a plain SwiftUI view inside the inspector's content and **never** a `.toolbar`
/// modifier: the window toolbar is kept an empty AppKit `NSToolbar` because a SwiftUI toolbar item's
/// overflow `menuFormRepresentation` caused a multi-second app hang.
struct VCSToolbar: View {
  /// Observed EXPLICITLY, like `HistoryPanel`'s and `FilesPanel`'s models.
  ///
  /// `RemoteStateModel` is its own `ObservableObject`; `AppStore` merely holds it and does not forward
  /// its `objectWillChange`. Reading it through `store.remoteState` alone renders the first state and
  /// then never repaints — clicking Push set `inFlight`, ran the push and recorded the result, and the
  /// toolbar showed none of it. Caught by `VCSToolbarUITests.testClickingPushRequestsAPush`.
  @ObservedObject var model: RemoteStateModel

  @EnvironmentObject var store: AppStore
  /// `ThemeService.shared` isn't observed by SwiftUI, so a theme switch would otherwise leave the
  /// hairlines stale. Same pattern as `ActivityBar`.
  @State private var themeTick = 0

  private var theme: ThemeTokens { ThemeService.shared.tokens }

  /// The toolbar's whole state, resolved in one place so the three segments can't disagree.
  private func presentation(now: Date) -> VCSSyncPresentation {
    VCSSyncPresenter.make(
      state: model.snapshot, hasTarget: model.target != nil,
      toolsUsable: store.vcsAllowsRemoteActions(vcs: model.target?.vcs ?? "git"),
      // `activeAction`, not `inFlight`: the label must describe THIS workroom. `inFlight` is the
      // model-wide lock, so rendering it directly showed "Pushing…" on a workroom that wasn't pushing.
      activity: model.activeAction.map { .running($0) } ?? .idle,
      failure: model.lastFailure, lastAction: model.lastAction, now: now)
  }

  var body: some View {
    // Only the relative timestamp needs to tick, so `TimelineView` wraps the whole bar but the schedule
    // is coarse (30s) and every other value is already `@Published`. Confining it to just the timestamp
    // `Text` would need the presentation recomputed per-subview, which is worse.
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let p = presentation(now: context.date)
      HStack(spacing: 0) {
        // The branch and sync cells are EQUAL width: same floor, same `maxWidth: .infinity`, and no
        // `layoutPriority` on either. All three parts are load-bearing — an `HStack` splits slack evenly
        // only between views that are equally flexible, so a priority override or a different floor
        // reintroduces the imbalance. (An earlier version gave sync `layoutPriority(1)` AND
        // `maxWidth: .infinity`, so it was offered the whole width first and claimed it, pinning the
        // branch cell at its floor even in a wide inspector: `feature/login` rendered as `fe…gin`.)
        VCSBranchSegment(name: branchName, vcs: model.target?.vcs)
          .frame(minWidth: VCSToolbarMetrics.segmentMinWidth, maxWidth: .infinity)
        divider
        VCSSyncSegment(presentation: p, onAct: { perform(p.action) })
          .frame(minWidth: VCSToolbarMetrics.segmentMinWidth, maxWidth: .infinity)
        divider
        VCSFetchSegment(
          isRunning: model.activeAction == .fetch,
          isEnabled: model.canFetch
            && store.vcsAllowsRemoteActions(vcs: model.target?.vcs ?? "git"),
          onFetch: { perform(.fetch) }
        )
        .frame(width: VCSToolbarMetrics.fetchWidth)
      }
      .frame(height: VCSToolbarMetrics.height)
      .frame(maxWidth: .infinity)
      .overlay(alignment: .bottom) { theme.border.frame(height: 1) }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("vcs.toolbar")
    }
    .id(themeTick)
    .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in themeTick += 1 }
  }

  /// Full-bleed, unlike `TitlebarDivider` (a 14pt inline group rule) — it's what makes the three cells
  /// read as segments rather than as a row of controls.
  private var divider: some View {
    Rectangle().fill(theme.border).frame(width: 1).frame(maxHeight: .infinity)
  }

  /// Read through the one accessor every branch-showing surface uses, so this can't disagree with the
  /// status bar or the sidebar.
  private var branchName: String? {
    model.target.flatMap { store.branchName(for: $0.sid) }
  }

  /// Hands straight to the store, which owns the dirty-tree confirmation gate.
  ///
  /// The gate used to live here, and that was the bug: the Source Control menu calls
  /// `performRemoteAction` directly, so ⌥⇧⌘P autostashed a dirty tree with no warning while this button
  /// warned. A gate only one of two entry points honours isn't a gate.
  private func perform(_ action: VCSRemoteAction?) {
    guard let action else { return }
    store.performRemoteAction(action)
  }
}

/// Segment 1: the current branch. **Display only — not a control.**
///
/// Not a dropdown, and not a button either. Workrooms **are** branches — a workroom's identity is its
/// directory name, with no branch field anywhere in the config — so switching a workroom's branch would
/// make its name permanently wrong, and the jj equivalent (`jj new <bookmark>`) was reproduced removing
/// a file from the working copy and orphaning the workroom's commit. With switching gone there is no
/// action left that belongs on the branch name, so this is a label: no `Button`, no hover well, no
/// chevron. Each of those would promise something that doesn't happen.
///
/// It still carries a `.help` — middle truncation hides the middle of a long name, and the tooltip is
/// how you read the whole thing — plus a right-click "Copy Branch Name". Neither is a click action.
private struct VCSBranchSegment: View {
  let name: String?
  /// The target's backend (`"git"` / `"jj"`), nil when nothing is selected. Every string in this segment
  /// derives from it through `VCSSyncPresenter`, so the caption, the tooltip and the spoken label can't
  /// drift out of agreement — and the mapping stays unit-testable rather than inline here.
  let vcs: String?

  private var noun: String { VCSSyncPresenter.refNoun(vcs: vcs) }
  private var caption: String { VCSSyncPresenter.refCaption(vcs: vcs) }
  private var theme: ThemeTokens { ThemeService.shared.tokens }

  var body: some View {
    HStack(spacing: VCSToolbarMetrics.glyphSpacing) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: VCSToolbarMetrics.glyph))
        .foregroundStyle(theme.fgMuted)
        .frame(width: VCSToolbarMetrics.glyphSlot)
      // The caption is unconditional. It used to sit in a `ViewThatFits` ladder against a name-only
      // variant, which dropped it far more often than intended and in the wrong circumstances:
      // `ViewThatFits` measures each variant's IDEAL width, and a `.lineLimit(1)` truncating `Text`
      // reports its FULL untruncated string as its ideal — so the caption was vetoed by a long *name*,
      // never by a narrow cell. jj repos lost it almost always (bookmark names, or the ancestor bookmark
      // a workspace's unbookmarked `@` resolves to, run longer than a `feature/login`) while git repos
      // kept it, which is exactly the asymmetry that got reported. The name truncates instead; at the
      // 114pt floor the caption truncates too, which is honest degradation rather than a silent drop.
      VStack(alignment: .leading, spacing: 1) {
        Text(caption)
          .font(VCSToolbarMetrics.captionFont)
          .foregroundStyle(theme.fgDim)
          .lineLimit(1)
          .truncationMode(.tail)
        nameText
      }
      Spacer(minLength: 0)
    }
    .padding(.leading, VCSToolbarMetrics.outerInset)
    .padding(.trailing, VCSToolbarMetrics.innerInset)
    // The cell's own layout, WITHOUT `vcsToolbarSegment`'s hover fill: that treatment marks a segment as
    // clickable, and this one isn't. `contentShape` is still needed so the tooltip and context menu have
    // the full cell as their hit region rather than just the glyph and text glyphs.
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .help(name ?? "No \(noun) resolved yet")
    // A `Button` was implicitly ONE accessibility element; a plain `HStack` is not, so without this its
    // caption and name would be exposed as two unrelated strings.
    .accessibilityElement(children: .ignore)
    // Caption AND name in the LABEL, not split across label + value.
    //
    // `.accessibilityValue` does not survive on this element: once it stopped being a `Button` and got
    // collapsed with `children: .ignore`, AppKit maps it to a static-text element whose value the
    // modifier no longer sets — it read back as the empty string, which failed both tests that assert the
    // name. (`ChangesPanel`'s combined header shows the mirror-image of the same mapping: there the
    // children's text lands in the VALUE and the label comes back empty.) The label is the one field that
    // reliably carries what we set, so both parts go in it — and VoiceOver reads it as one phrase, which
    // is what a two-line label is anyway.
    .accessibilityLabel("\(caption): \(name ?? "unknown")")
    .accessibilityIdentifier("vcs.toolbar.branch")
    .contextMenu {
      // Offered as a menu item rather than making the label selectable: `.textSelection(.enabled)`
      // swallows real mouseDown, which would stop this segment being clickable with an actual mouse
      // while synthetic test clicks kept passing.
      if let name {
        Button("Copy \(noun.capitalized) Name") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(name, forType: .string)
        }
      }
    }
  }

  /// `.middle` truncation, because a long branch's distinguishing part is usually its tail
  /// (`joel/history-refs-pill`) — the same reasoning the Changes header and status bar already follow.
  private var nameText: some View {
    Text(name ?? "—")
      .font(VCSToolbarMetrics.titleFont)
      .lineLimit(1)
      .truncationMode(.middle)
  }
}

/// Segment 2: what to do about the remote, and doing it.
///
/// Line order is inverted relative to segment 1 — bold title over dim subtitle — which is what the
/// reference design specifies. The consequence is that the two segments' bold lines do **not** share a
/// baseline: both blocks are 26pt and vertically centred, so a caption-first block sits low and a
/// title-first block sits high. The full-height divider between them is what makes that read as two
/// groups rather than a misalignment. Called out because it looks like a bug and isn't.
private struct VCSSyncSegment: View {
  let presentation: VCSSyncPresentation
  let onAct: () -> Void

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var theme: ThemeTokens { ThemeService.shared.tokens }

  private var toneColor: Color {
    switch presentation.tone {
    case .normal: return theme.fgDim
    case .warning: return theme.warning
    case .failure: return theme.failure
    }
  }

  var body: some View {
    Button(action: onAct) {
      HStack(spacing: VCSToolbarMetrics.glyphSpacing) {
        if let symbol = presentation.symbol {
          Image(systemName: symbol)
            .font(.system(size: VCSToolbarMetrics.glyph))
            .foregroundStyle(presentation.tone == .normal ? theme.fgMuted : toneColor)
            .frame(width: VCSToolbarMetrics.glyphSlot)
        } else if presentation.action != nil, isRunning {
          ProgressView().controlSize(.mini).frame(width: VCSToolbarMetrics.glyphSlot)
        }
        content
      }
      .padding(.horizontal, VCSToolbarMetrics.innerInset)
      .vcsToolbarSegment(hovering: hovering && presentation.isEnabled, reduceMotion: reduceMotion)
    }
    .buttonStyle(.plain)
    .disabled(!presentation.isEnabled)
    // Deliberately NO disabled dim, unlike `ToolbarIconButtonStyle`. Every disabled state here is a
    // MESSAGE, not a withheld action — "No remote configured", "No repository", "Pushing…", and the
    // `.failure`-toned retry line — so all of them have to stay readable; the suppressed hover well is
    // what says "not clickable". An `.opacity(0.4)` here also COMPOUNDS: the text is already
    // `fgMuted` (fg @ 0.65), so it landed at an effective 0.26, fainter than `fgDim` (0.40) — the
    // placeholder tier — and dimmed error copy along with it. That convention's 0.4 is right only
    // because it sits on full-strength `fg`.
    .onHover { hovering = $0 }
    .help(presentation.help)
    .accessibilityLabel(presentation.accessibility)
    .accessibilityValue(presentation.accessibilityValue)
    .accessibilityIdentifier("vcs.toolbar.sync")
    // Only when a lock file is blocking the repo. Workroom deliberately doesn't delete it — telling a
    // live git's lock from an abandoned one isn't possible from outside the process, and deleting a live
    // one corrupts the index — so the fix is the user's to make, and these hand them the file rather
    // than making them retype a path out of a tooltip.
    .contextMenu {
      if let lockPath = presentation.lockPath {
        Button("Copy Lock File Path") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(lockPath, forType: .string)
        }
        Button("Reveal Lock File in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lockPath)])
        }
      }
    }
  }

  private var isRunning: Bool { presentation.title?.hasSuffix("…") == true }

  @ViewBuilder private var content: some View {
    if presentation.isSingleLine {
      HStack(spacing: VCSToolbarMetrics.glyphSpacing) {
        // Centred and a step up in size/contrast: a lone dim 10pt line in a 36pt bar reads as broken.
        Text(presentation.subtitle)
          .font(VCSToolbarMetrics.soloFont)
          .foregroundStyle(presentation.tone == .normal ? theme.fgMuted : toneColor)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 4)
        pills
      }
    } else {
      VStack(alignment: .leading, spacing: 1) {
        // The pills ride the TITLE line rather than the whole cell. As siblings of this VStack they
        // narrowed BOTH lines, and the line they cost the most was the one that could least afford it:
        // the timestamp is the longest string in the bar ("Fetched 22 minutes ago") and the only one
        // whose full form is worth reading, while the title above it is short and has an abbreviation
        // ladder to fall back on. Now the timestamp gets the segment's whole width and the pills
        // compete only with the title, which is what the ladder is for.
        HStack(spacing: VCSToolbarMetrics.glyphSpacing) {
          // Longest variant first — `ViewThatFits` takes the first that fits, so inverting this order
          // silently defeats the whole ladder. `VCSSyncPresentationTests` pins the ordering.
          ViewThatFits(in: .horizontal) {
            ForEach(presentation.titleVariants, id: \.self) { variant in
              Text(variant).font(VCSToolbarMetrics.titleFont).lineLimit(1)
            }
          }
          Spacer(minLength: 4)
          pills
        }
        // The staleness caveat abbreviates but survives. It must NOT be the first thing dropped: the
        // count pill it qualifies is pinned, so losing the caveat first would leave an unverified number
        // standing alone.
        ViewThatFits(in: .horizontal) {
          Text(presentation.subtitle)
          Text(presentation.subtitleShort)
        }
        .font(VCSToolbarMetrics.captionFont)
        .foregroundStyle(toneColor)
        .lineLimit(1)
        .truncationMode(.tail)
      }
      // The cell no longer has a `Spacer` of its own to fill it, so the VStack claims the width — which
      // is also what lets the subtitle's ladder measure against the full cell.
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Ahead first, then behind — the diverged order the presenter fixes (`↓` before `↑` is decided there,
  /// not here; this just renders `badge` then `secondaryBadge`).
  @ViewBuilder private var pills: some View {
    if let badge = presentation.badge { VCSCountPill(badge: badge) }
    if let secondary = presentation.secondaryBadge { VCSCountPill(badge: secondary) }
  }
}

/// Segment 3: fetch.
///
/// `arrow.down.circle`, not `arrow.clockwise`: the Changes header's Refresh button is already
/// `arrow.clockwise` roughly 40pt below and 10pt to the left, and two near-identical circular-arrow
/// glyphs meaning different things (re-read local status vs contact the remote) is a real confusion.
/// The down-arrow also matches the ↓ direction language of the count pills.
private struct VCSFetchSegment: View {
  let isRunning: Bool
  let isEnabled: Bool
  let onFetch: () -> Void

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var theme: ThemeTokens { ThemeService.shared.tokens }

  var body: some View {
    Button(action: onFetch) {
      Group {
        if isRunning {
          // `.mini`, not `.small`: small is ~16pt and would overflow the 12pt glyph slot.
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: "arrow.down.circle")
            .font(.system(size: VCSToolbarMetrics.glyph))
            // Unlike segment 2 this IS a bare affordance, so unavailable should read as unavailable —
            // but as ONE tier, not a multiply. `fgDim` is fg @ 0.40, the same effective alpha
            // `ToolbarIconButtonStyle`'s `.opacity(0.4)` produces on its full-strength glyphs.
            .foregroundStyle(isEnabled ? theme.fgMuted : theme.fgDim)
        }
      }
      .frame(maxWidth: .infinity)
      .vcsToolbarSegment(hovering: hovering && isEnabled, reduceMotion: reduceMotion)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled || isRunning)
    .onHover { hovering = $0 }
    .help(isRunning ? "Fetching…" : "Fetch from the remote")
    .accessibilityLabel("Fetch")
    .accessibilityIdentifier("vcs.toolbar.fetch")
  }
}

/// A count pill: `5 ↑` / `3 ↓`.
///
/// Geometry and font copied from `PRNumberBadge` so it matches the ref pill in the Changes header just
/// below. Both directions use the same `surface` fill rather than hue-coding: the arrow carries the
/// direction (shape, not colour) and a count is a quantity, not a severity.
private struct VCSCountPill: View {
  let badge: VCSSyncPresentation.Badge
  private var theme: ThemeTokens { ThemeService.shared.tokens }

  var body: some View {
    HStack(spacing: 2) {
      Text("\(badge.count)").font(.caption2).fontWeight(.semibold).monospacedDigit()
      Image(systemName: badge.direction == .ahead ? "arrow.up" : "arrow.down")
        .font(.system(size: VCSToolbarMetrics.pillArrowGlyph, weight: .semibold))
    }
    .foregroundStyle(theme.fgMuted)
    .padding(.horizontal, VCSToolbarMetrics.pillHorizontalPadding)
    .padding(.vertical, VCSToolbarMetrics.pillVerticalPadding)
    .background(Capsule().fill(theme.surface))
    // The highest-information 30pt in the bar — it must never yield.
    .fixedSize()
    // The spoken form comes from the sync button's `accessibilityValue`; a pill read separately would
    // just be a bare number with no subject.
    .accessibilityHidden(true)
  }
}

extension View {
  /// One hover treatment for all three segments: the whole divider-bounded cell fills.
  ///
  /// Deliberately not the 22pt inset well `InspectorHeaderButton` uses — that's right for a control
  /// floating in a header row, but inside a cell whose bounds are drawn by hairlines a small inner well
  /// reads as a mistake. Opacity is animated, never the view tree: an implicit tree animation
  /// interpolates a glyph's 1pt pixel re-round into a visible slide (see `ToolbarIconButtonStyle`).
  fileprivate func vcsToolbarSegment(hovering: Bool, reduceMotion: Bool) -> some View {
    self
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .background(
        ThemeService.shared.tokens.hover
          .opacity(hovering ? 1 : 0)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
      )
      .contentShape(Rectangle())
  }
}
