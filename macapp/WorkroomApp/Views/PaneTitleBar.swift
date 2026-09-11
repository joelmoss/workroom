import SwiftUI

/// Metrics for the detail-panel title bar (issue #150). One place, for the same reason
/// `PaneToolbarIcon` exists: the numbers are only consistent if they aren't scattered.
enum PaneTitleBarMetrics {
  /// Shared with `TerminalStatusBar` so a pane's two chrome rows are the same weight (and it matches
  /// `WorkroomPaneTitleBar` above them).
  static let height: CGFloat = TerminalPanelMetrics.chromeRowHeight
  static let leadingInset: CGFloat = 10
  /// Tighter than the leading inset so the trailing-most control lines up with the workroom title
  /// bar's, which lands 4pt inside the card's edge.
  static let trailingInset: CGFloat = 4
  /// The title's floor in the full-toolbar layout — **a tuned threshold constant**, expressed as a
  /// layout minimum rather than a width comparison so `ViewThatFits` can do the measuring (no
  /// `GeometryReader`, no `@State`). It is what makes the full row fail to fit below roughly 420pt.
  ///
  /// 160pt is ~22 characters at `.subheadline`: enough to read a file name plus a directory or two,
  /// which is the point at which collapsing the optional controls buys more than it costs.
  static let minTitle: CGFloat = 160
}

/// Which OPTIONAL trailing controls a pane title bar offers. Split right / split down / close are
/// unconditional and so aren't modelled here.
///
/// Pure and separate from the view (same rationale as `WorkroomPaneToolbarPresentation`) so the
/// matrix is unit-testable without instantiating SwiftUI, and so "is there anything before the
/// split/close group" is decided in one pass rather than by each control guessing.
enum PaneToolbarPresentation {
  struct Controls: Equatable {
    let diffMode: Bool
    let openFile: Bool
    let markdownMode: Bool

    /// Whether anything at all sits before the split/close group. Drives BOTH the rule between the
    /// two groups (a separator with nothing on one side of it is worse than no separator) and the
    /// overflow menu (with nothing to collapse, the narrow layout is the wide one).
    ///
    /// Deliberately computed rather than a stored `divider` flag, unlike its model
    /// `WorkroomPaneToolbarPresentation.Controls`: that bar separates TWO independently-absent groups,
    /// so its `divider` is `run && openIn` and carries real information. Here there is one optional
    /// group, so a stored flag would be a second name for this exact expression.
    var hasOptional: Bool { diffMode || openFile || markdownMode }
  }

  static func controls(for content: TabContent) -> Controls {
    switch content {
    // A diff pane gets the unified/side-by-side switch and "Open File" (the working copy of the file
    // being diffed, issue #117).
    case .diff:
      return Controls(diffMode: true, openFile: true, markdownMode: false)
    // Only a MARKDOWN file has a rendered form to switch to; every other file shows source either way.
    case .file(let descriptor):
      let markdown = PlainFileViewer.isMarkdown(descriptor.path)
      return Controls(diffMode: false, openFile: false, markdownMode: markdown)
    // A terminal has no per-file actions; a changeset's own `DiffViewer` header carries the switch for
    // whichever file is selected inside it, so a second one on the pane would fight it.
    case .terminal, .changeset:
      return Controls(diffMode: false, openFile: false, markdownMode: false)
    }
  }
}

/// What a pane title bar renders as its identity, and how that text truncates when the pane is too
/// narrow to show all of it.
///
/// Truncation is per content kind because the informative end differs: a shell-set terminal title is
/// front-loaded (`npm run dev — building…`), so it tail-truncates; a file path's informative end is
/// the file NAME, so it head-truncates — the same choice `TerminalStatusBar` made for this exact
/// string before issue #150 moved it up here. `.middle` was the first instinct and is wrong for both:
/// it eats the file name, which is the one part that must survive.
///
/// Returns plain strings rather than a `Text` so the mapping is unit-testable.
enum PaneTitlePresentation {
  struct Title: Equatable {
    /// Dimmed leading directories, including the trailing "/" — empty when there are none.
    let prefix: String
    /// The part rendered in the primary colour: a file name, or the whole terminal title.
    let name: String
    let truncation: Text.TruncationMode

    /// The undecorated whole, for the accessibility label and the tooltip.
    var plain: String { prefix + name }
  }

  static func title(for content: TabContent, tabTitle: String) -> Title {
    // A diff / file pane names its file by its full repo-relative path, directories dimmed. The path
    // is the pane's identity here: it is no longer in the status bar below (issue #150).
    if let path = content.filePath {
      let name = (path as NSString).lastPathComponent
      return Title(
        prefix: String(path.dropLast(name.count)), name: name, truncation: .head)
    }
    // A terminal's live/default title, or a changeset's subject.
    return Title(prefix: "", name: tabTitle, truncation: .tail)
  }
}

/// A file path with its leading directories dimmed and the file name in the primary colour. Shared by
/// `PaneTitleBar` and `DiffViewer`'s own file header so the two render a path identically.
func panePathText(prefix: String, name: String) -> Text {
  Text(prefix).foregroundStyle(.tertiary) + Text(name)
}

/// The header atop **every** detail panel (issue #150): a leading content glyph, the pane's title
/// untruncated by the tab chip's 180pt cap, and a trailing toolbar carrying that pane's own actions.
///
/// The tab strip's toolbar used to hold these, keyed on the ACTIVE tab — so in a split its buttons
/// acted on a pane other than the one you clicked. Each pane now owns its controls and acts on itself,
/// the same fix issue #139 made for workrooms.
///
/// **Store-free on purpose.** This view is mounted once per pane, beside a live libghostty surface;
/// an `@EnvironmentObject AppStore` here would re-evaluate every pane's bar on every unrelated store
/// change. `PaneLeafView` already observes both stores, so it resolves the values and passes
/// closures — the same contract `WorkroomPaneTitleBar` documents. It also makes the two presentation
/// enums above testable with no store in scope.
struct PaneTitleBar: View {
  let title: PaneTitlePresentation.Title
  /// Content-kind glyph from `TabContent.glyph` — nil for a terminal, matching the chip.
  let glyph: String?
  let controls: PaneToolbarPresentation.Controls
  /// This pane's effective diff mode / markdown mode — the lit segment. Resolved by the leaf from the
  /// tab's override and the global default.
  let diffMode: DiffViewMode
  let markdownPreview: Bool
  /// False when the diff's source was deleted — there is no working copy to open (review D4).
  let openFileEnabled: Bool
  let focused: Bool
  /// Only a pane with peers can be dragged within a split, so the drag gesture is `multiPane`-only.
  let multiPane: Bool
  /// Full title + absolute path, for the tooltip.
  let help: String
  let coordinateSpace: String
  let onSetDiffMode: (DiffViewMode) -> Void
  let onSetMarkdownPreview: (Bool) -> Void
  let onOpenFile: () -> Void
  let onSplitRight: () -> Void
  let onSplitDown: () -> Void
  let onClose: () -> Void
  let onActivate: () -> Void
  let onDragChanged: (CGPoint) -> Void
  let onDragEnded: () -> Void
  private let theme = ThemeService.shared

  var body: some View {
    // Two complete title-plus-toolbar rows; `ViewThatFits` takes the first whose combined width fits.
    // It must wrap the WHOLE row: the title and the toolbar compete for the same width, so measuring
    // the toolbar alone would answer the wrong question. When neither fits — panes CAN render below
    // `minPaneWidth`, since `PaneTreeLayout.lengths` splits evenly rather than refusing — it falls
    // back to the last candidate, which is the collapsed one. That is the intended degradation.
    //
    // This branch is entirely inside the bar. It never wraps the pane's content, so the
    // single-structural-slot invariant (`PaneLeafView`, `WorkroomPaneLeaf`) is not in play: that rule
    // is about the libghostty surface's view identity, not about chrome.
    ViewThatFits(in: .horizontal) {
      row(titleMinWidth: PaneTitleBarMetrics.minTitle, collapsed: false)
      row(titleMinWidth: nil, collapsed: true)
    }
    .frame(height: PaneTitleBarMetrics.height)
    .frame(maxWidth: .infinity)
    // `panel` (not the terminal's own background) so the bar reads as chrome, mirroring
    // `TerminalStatusBar` at the pane's other end — which puts its hairline on top, so this one puts
    // its hairline on the bottom and the pair bracket the content.
    .background(theme.tokens.panel)
    .overlay(alignment: .bottom) { theme.tokens.border.frame(height: 1) }
    // No unfocused fade of its own: this bar is INSIDE the pane, so `PaneLeafView`'s 0.3 dim scrim
    // already covers it — exactly as it covers `TerminalStatusBar`. The strip above and the workroom
    // header above that each carry a 0.45 `shouldRecede` fade precisely because they sit OUTSIDE the
    // scrim. Chrome inside a pane dims with the pane; chrome outside it fades itself.
    .contentShape(Rectangle())
    // Drag the pane by its bar to move it within the split, or up to the strip to pop it out — the
    // affordance that replaced the hover-only grip chip (issue #150), and the same gesture the
    // workroom title bar uses for its group.
    //
    // `including:` MUST be `.subviews` when solo: `GestureMask.none` would disable gestures in the
    // SUBVIEW hierarchy too, killing this bar's own buttons on every unsplit pane — and
    // `ToolbarIconButtonStyle`'s hover well is `.onHover`, not a gesture, so they would still light up
    // and look alive.
    .gesture(
      DragGesture(minimumDistance: 6, coordinateSpace: .named(coordinateSpace))
        .onChanged { onDragChanged($0.location) }
        .onEnded { _ in onDragEnded() },
      including: multiPane ? .all : .subviews
    )
    // A click on the bar's empty area focuses the pane. A terminal focuses itself through its
    // surface's first responder and a content pane through `ActivateOnPress`, but neither covers this
    // bar — it is SwiftUI chrome above the surface, outside the content's hit region.
    .onTapGesture { onActivate() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal.pane.titlebar")
    .accessibilityLabel(Text(title.plain))
    .accessibilityHint(
      multiPane ? "Drag onto a pane edge to rearrange, or to the tab strip to pop out" : "")
  }

  /// One complete row. `titleMinWidth` is what makes the full-toolbar candidate fail to fit in a
  /// narrow pane; the collapsed candidate passes nil so it can always render.
  private func row(titleMinWidth: CGFloat?, collapsed: Bool) -> some View {
    HStack(spacing: 6) {
      if let glyph {
        Image(systemName: glyph)
          .font(.system(size: 10))
          .foregroundStyle(focused ? theme.tokens.accent : theme.tokens.fgMuted)
          // The title carries the same information to VoiceOver; a second announcement of "document"
          // before every file name is noise.
          .accessibilityHidden(true)
      }
      panePathText(prefix: title.prefix, name: title.name)
        .font(.subheadline)
        .foregroundStyle(focused ? Color.primary : theme.tokens.fgMuted)
        .lineLimit(1)
        .truncationMode(title.truncation)
        // No `TabStripMetrics.maxChipTitle` cap — the chip's 180pt cap is the thing issue #150 exists
        // to escape. The title takes everything the toolbar leaves.
        .frame(minWidth: titleMinWidth, maxWidth: .infinity, alignment: .leading)
        .help(help)
      trailing(collapsed: collapsed)
    }
    .padding(.leading, PaneTitleBarMetrics.leadingInset)
    .padding(.trailing, PaneTitleBarMetrics.trailingInset)
  }

  /// This pane's actions. ONE styled group, so every control gets the same 22pt well and glyph size —
  /// which is why nothing here is a `TabToolbarButton`: that sets its own `.plain` style and 11pt
  /// glyph, so it would not inherit the group and the row would carry two button sizes.
  private func trailing(collapsed: Bool) -> some View {
    HStack(spacing: 6) {
      if collapsed {
        if controls.hasOptional {
          overflowMenu
          TitlebarDivider()
        }
      } else {
        if controls.diffMode { DiffModeSwitch(mode: diffMode, select: onSetDiffMode) }
        if controls.markdownMode {
          MarkdownModeSwitch(preview: markdownPreview, select: onSetMarkdownPreview)
        }
        if controls.openFile {
          PaneToolbarButton(
            systemImage: "doc.text", help: "Open File", accessibilityLabel: "Open File",
            identifier: "pane.toolbar.openFile", action: onOpenFile
          )
          .disabled(!openFileEnabled)
        }
        if controls.hasOptional { TitlebarDivider() }
      }
      PaneToolbarButton(
        systemImage: "rectangle.trailinghalf.inset.filled", help: "Split right (⌘D)",
        accessibilityLabel: "Split right", identifier: "pane.toolbar.splitRight",
        action: onSplitRight)
      PaneToolbarButton(
        systemImage: "rectangle.bottomhalf.inset.filled", help: "Split down (⇧⌘D)",
        accessibilityLabel: "Split down", identifier: "pane.toolbar.splitDown",
        action: onSplitDown)
      PaneToolbarButton(
        systemImage: "xmark", help: "Close (⌘W)", accessibilityLabel: "Close pane",
        identifier: "pane.toolbar.close", action: onClose)
    }
    .buttonStyle(ToolbarIconButtonStyle())
    .font(.system(size: PaneToolbarIcon.glyph))
    // Keeps its intrinsic width so the TITLE yields under width pressure, not the buttons — the same
    // reason the tab strip's toolbar was fixed-size.
    .fixedSize()
  }

  /// The optional controls, folded into a menu when the row can't show them. Split / split / close
  /// deliberately stay out of it: they are the actions the issue asked to put ON the bar.
  private var overflowMenu: some View {
    Menu {
      if controls.diffMode {
        Picker("View", selection: Binding(get: { diffMode }, set: onSetDiffMode)) {
          Label("Unified", systemImage: "text.alignleft").tag(DiffViewMode.unified)
          Label("Side by Side", systemImage: "rectangle.split.2x1").tag(DiffViewMode.sideBySide)
        }
        .pickerStyle(.inline)
      }
      if controls.markdownMode {
        Picker("View", selection: Binding(get: { markdownPreview }, set: onSetMarkdownPreview)) {
          Label("Rendered Preview", systemImage: "eye").tag(true)
          Label("Source", systemImage: "chevron.left.forwardslash.chevron.right").tag(false)
        }
        .pickerStyle(.inline)
      }
      if controls.openFile {
        Button(action: onOpenFile) { Label("Open File", systemImage: "doc.text") }
          .disabled(!openFileEnabled)
      }
    } label: {
      Image(systemName: "ellipsis")
        .foregroundStyle(.secondary)
    }
    // `.button`, NOT `.borderlessButton` — the same call the Changes panel's row menu documents
    // (`ChangesPanel.swift:268`) and `OpenInControl` makes (`TargetDetailToolbar.swift:105`).
    // `.borderlessButton` is AppKit-backed and never reports hover, so this trigger would be the one
    // control in the bar with no hover well and a glyph-sized hit area, while its neighbours light up
    // at 22pt. As a real SwiftUI button it inherits the group's `ToolbarIconButtonStyle` for free.
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("More actions")
    .accessibilityLabel("More actions")
    .accessibilityIdentifier("pane.toolbar.overflow")
  }
}

/// One icon button in the pane title bar. A view (not an inline `Button`) so it carries its own
/// `onHover`: a bare `.help` with no hover tracking can silently fail to install its tooltip — the
/// same reason `CloseWorkroomPaneButton` and `TabToolbarButton` are views.
///
/// Takes the group's inherited `ToolbarIconButtonStyle` and glyph size rather than styling itself,
/// so every control in the bar wears one well.
///
/// Internal, not private: the workroom title bar's "Close all tabs" uses it too, so the two bars a
/// pane sits between build their buttons the same way.
struct PaneToolbarButton: View {
  let systemImage: String
  let help: String
  let accessibilityLabel: String
  let identifier: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .foregroundStyle(hovering ? .primary : .secondary)
    }
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(identifier)
  }
}
