import AppKit
import Defaults
import WorkroomSessionProtocol

/// One tab in a target's strip. A tab is exactly one PANE: historically always a terminal surface,
/// and since issue #66 it can instead host non-terminal content (a file diff today; more kinds
/// later), so `content` is a `TabContent` union. With splits (issue #3) a tab is still exactly one
/// pane — a "split" composes several tabs into one on-screen layout (see `PaneLayout`), it does not
/// nest panes inside a tab. The split tree, focus, ⌘1–9, reorder, and close-successor all key on the
/// tab's `id`, so a content tab is a first-class peer of a terminal tab with no special casing — a
/// split can mix a terminal pane and a diff pane. Terminal-only state lives INSIDE the `.terminal`
/// payload, so a content tab carries none of it. `TerminalTab` stays a value type on purpose: a
/// live-title/progress/preview update mutates a copy and reassigns the dict, which is what drives
/// `@Published` (a reference type would not). The surface, when present, is a shared reference the tab
/// owns; `teardown(_:)` frees it (a no-op for content tabs — they have no surface).
struct TerminalTab: Identifiable {
  let id = UUID()
  var content: TabContent

  /// Per-tab diff layout override (issue #66), set by the tab toolbar's unified/side-by-side toggle;
  /// `nil` ⇒ follow the global `Defaults[.diffViewMode]`. Lives on the tab (not the diff view) so the
  /// toolbar can set it and the pane's `DiffViewer` can read it, and so it's discarded with the tab.
  /// Only meaningful for a `.diff` tab.
  var diffViewModeOverride: DiffViewMode?

  /// Per-tab Markdown source/preview override, set by the tab toolbar's Source/Preview switch. `nil` ⇒
  /// the default (a Markdown file opens rendered, i.e. preview). Lives on the tab (not the viewer) so
  /// the toolbar can set it and the pane's `PlainFileViewer` can read it, mirroring
  /// `diffViewModeOverride`. Only meaningful for a `.file` tab whose file is Markdown.
  var markdownPreviewOverride: Bool?

  /// The terminal surface this tab owns, or nil for a content (e.g. diff) tab. The single accessor
  /// every surface-specific path (occlusion, theme reload, teardown, run-state) funnels through, so
  /// a content tab transparently does *fewer* surface operations — never more.
  var surface: GhosttySurfaceView? {
    if case .terminal(let s) = content { return s.view }
    return nil
  }

  /// What the tab strip displays: a terminal's live/idle title, or a content tab's own title (a
  /// diff's filename).
  var title: String {
    switch content {
    case .terminal(let s): return s.liveTitle ?? s.defaultTitle
    case .diff(let d): return (d.path as NSString).lastPathComponent
    case .file(let f): return (f.path as NSString).lastPathComponent
    case .changeset(let c): return c.title
    }
  }

  /// The full repo-relative path of the file this tab shows (issue #136) — what the pane footer
  /// names, and the chip's tooltip. Nil for a terminal (its footer shows the cwd instead) and for a
  /// changeset (its in-pane `DiffViewer` header already carries the path).
  ///
  /// Deliberately adjacent to `title`: both read `d.path`/`f.path`, but `title` keeps only the
  /// `lastPathComponent`. That divergence IS issue #136 — two `user.rb` chips from different
  /// directories were indistinguishable — so the two answers stay in one screenful.
  var filePath: String? { content.filePath }

  /// A content tab still in VS-Code-style preview mode (italic chip, replaced by the next preview);
  /// always false for terminals. A diff and a file share the target's single preview slot.
  var isPreview: Bool {
    switch content {
    case .diff(let d): return d.isPreview
    case .file(let f): return f.isPreview
    case .changeset(let c): return c.isPreview
    case .terminal: return false
    }
  }

  /// Whether a command is actively *working* in this terminal (issue #28) — drives the chip underline
  /// and the sidebar spinner. Driven solely by OSC 9;4 progress, like Ghostty/Muxy. Always false for
  /// content tabs (no surface, no progress).
  var isRunning: Bool {
    if case .terminal(let s) = content { return s.progressActive == true }
    return false
  }

  /// The curated CLI/TUI tool recognized as currently running in this terminal's foreground (issue
  /// #141) — a broader, data-driven sibling of `activeAgentBackend`, latched/cleared identically.
  /// Always nil for content tabs.
  var recognizedTool: RecognizedTool? {
    if case .terminal(let s) = content { return s.activeTool }
    return nil
  }

  /// A terminal tab wrapping a freshly-created surface.
  static func terminal(view: GhosttySurfaceView, defaultTitle: String) -> TerminalTab {
    TerminalTab(content: .terminal(TerminalState(view: view, defaultTitle: defaultTitle)))
  }

  /// A diff content tab from its descriptor (issue #66).
  static func diff(_ descriptor: DiffDescriptor) -> TerminalTab {
    TerminalTab(content: .diff(descriptor))
  }

  /// A read-only file content tab from its descriptor (Files inspector section).
  static func file(_ descriptor: FileDescriptor) -> TerminalTab {
    TerminalTab(content: .file(descriptor))
  }

  /// A changeset (commit detail) content tab from its descriptor (History section, issue #59).
  static func changeset(_ descriptor: ChangesetDescriptor) -> TerminalTab {
    TerminalTab(content: .changeset(descriptor))
  }
}

/// A tab's content: a terminal surface, or non-terminal content (issue #66). A closed set — the
/// renderer, occlusion, teardown, and theme reload switch on it exhaustively, so adding a kind is a
/// compiler-guided change (you can't forget a site).
enum TabContent {
  case terminal(TerminalState)
  case diff(DiffDescriptor)
  case file(FileDescriptor)
  case changeset(ChangesetDescriptor)

  /// The full repo-relative path of the file this content shows (issue #136) — see
  /// `TerminalTab.filePath`, which forwards here. Every kind that HAS a file already carries the
  /// whole path (`DiffDescriptor.path`, `FileDescriptor.path`), so nothing is resolved or rebuilt.
  ///
  /// The cases are enumerated rather than defaulted on purpose: a fifth `TabContent` kind must be a
  /// compile error here, not a footer that silently shows nothing.
  var filePath: String? {
    switch self {
    case .diff(let d): return d.path
    case .file(let f): return f.path
    // A terminal's footer shows its cwd instead; a changeset's in-pane `DiffViewer` header already
    // names the selected file (`showsFileHeader`), so a footer path would just duplicate it.
    case .terminal, .changeset: return nil
    }
  }

  /// The SF Symbol marking this content kind wherever a tab is named — the chip (`TerminalTabChip`)
  /// and the pane's own title bar (`PaneTitleBar`, issue #150). `nil` for a terminal: a terminal is
  /// the default, and the glyphs exist to say "this one is NOT a terminal" (issue #66).
  ///
  /// One source for both sites so they cannot drift; enumerated for the same reason `filePath` is —
  /// a fifth `TabContent` kind must be a compile error here, not a silently unmarked tab.
  var glyph: String? {
    switch self {
    case .terminal: return nil
    case .diff: return "plusminus"
    case .file: return "doc"
    case .changeset: return "clock"
    }
  }
}

// MARK: - Navigation-history bridge
//
// The `TabContent` → history projections live here, next to `TabContent`, so a fifth content kind is a
// compile error in ONE place instead of failing silently in several. Both switches below are
// exhaustive on purpose — no `default` arm.

extension NavPayload {
  /// The replay payload for a tab's content, or `nil` for a terminal (nothing to re-open — replay just
  /// re-focuses the tab).
  ///
  /// Two fields are normalised OUT, and for the same reason: they are not part of a location, so leaving
  /// them here would give one value two homes. `isPreview` — a Keep Open must not read as a new place.
  /// `selectedPath` — the in-commit file selection is identity, and it lives on `NavLocation` where `==`
  /// can see it; a second copy in here would let dedup read one value while replay applied the other.
  init?(_ content: TabContent) {
    switch content {
    case .terminal:
      return nil
    case .diff(var d):
      d.isPreview = false
      self = .diff(d)
    case .file(var f):
      f.isPreview = false
      self = .file(f)
    case .changeset(var c):
      c.isPreview = false
      c.selectedPath = nil
      self = .changeset(c)
    }
  }

  /// This payload as tab content, taking its preview flag from the tab it is landing in — see
  /// `TerminalSessions.setContent`.
  func makeTabContent(isPreview: Bool) -> TabContent {
    switch self {
    case .diff(var d):
      d.isPreview = isPreview
      return .diff(d)
    case .file(var f):
      f.isPreview = isPreview
      return .file(f)
    case .changeset(var c):
      c.isPreview = isPreview
      return .changeset(c)
    }
  }

  /// Whether `content` is already showing this payload — delegates to each descriptor's own identity
  /// rule (`sameFile` / `sameChangeset` via `ContentDescriptor.matches`), so the rule stays defined
  /// once per type.
  func matchesTab(_ content: TabContent) -> Bool {
    switch self {
    case .diff(let d): return d.matches(content)
    case .file(let f): return f.matches(content)
    case .changeset(let c): return c.matches(content)
    }
  }

}

extension FocusedTabSelection {
  /// The content identity of a tab, or `nil` for a terminal (no inspector row corresponds to it, and
  /// history represents it as "no content"). The single switch `current(store:sessions:)` and
  /// navigation history both resolve through.
  init?(content: TabContent) {
    switch content {
    case .changeset(let descriptor): self = .changeset(commitID: descriptor.commitID)
    case .diff(let descriptor): self = .diff(path: descriptor.path, source: descriptor.source)
    case .file(let descriptor): self = .file(path: descriptor.path)
    case .terminal: return nil
    }
  }
}

// MARK: - Saved-session bridge (issue #46)
//
// Deliberately in the SAME block as the navigation-history bridge above, for the reason that block's
// comment already gives: a fifth `TabContent` kind must be a compile error in ONE place. A second
// projection living in `SessionSnapshot.swift` would compile fine while silently never persisting
// the new kind. The switch below is exhaustive on purpose — no `default` arm.
//
// The on-disk types stay separate from the runtime ones (no descriptor gains `Codable`) so the file
// format is never hostage to an internal field rename — see `SessionSnapshot.swift`.

extension TabSession {
  /// A tab as it will be written to disk, or `nil` when it must not be persisted.
  ///
  /// Run tabs return nil: restoring one would resurrect a dev server with no `AppStore.RunState`
  /// behind it, orphaned on its port. They are identified by the surface carrying a command
  /// (`isRunCommandSurface`) rather than by `AppStore.runStates`, so a tab whose run bookkeeping has
  /// already moved on still cannot leak into the file.
  init?(key: String, tab: TerminalTab) {
    switch tab.content {
    case .terminal(let state):
      guard state.view.isRunCommandSurface == false else { return nil }
      self.init(
        key: key, kind: Self.terminalKind,
        // The LAST REPORTED cwd, which is the whole value of restoring a terminal. `state.cwd` is
        // the shell's latest report mirrored into observable state; `lastKnownCwd` is the surface's
        // own copy and covers a tab whose mirror never updated.
        terminal: TerminalPayload(
          defaultTitle: state.defaultTitle, cwd: state.cwd ?? state.view.lastKnownCwd,
          sessionID: (state.sessionID ?? state.view.persistentSessionID)?.uuidString))
    case .diff(let descriptor):
      self.init(
        key: key, kind: Self.diffKind,
        diff: DiffPayload(
          path: descriptor.path, change: descriptor.change.rawValue,
          source: DiffSourcePayload(descriptor.source), isPreview: descriptor.isPreview,
          viewMode: tab.diffViewModeOverride?.rawValue))
    case .file(let descriptor):
      self.init(
        key: key, kind: Self.fileKind,
        file: FilePayload(
          path: descriptor.path, isPreview: descriptor.isPreview,
          markdownPreview: tab.markdownPreviewOverride))
    case .changeset(let descriptor):
      self.init(
        key: key, kind: Self.changesetKind,
        changeset: ChangesetPayload(
          commitID: descriptor.commitID, title: descriptor.title,
          isPreview: descriptor.isPreview, selectedPath: descriptor.selectedPath))
    }
  }

  /// The non-terminal content this tab describes, or nil for a terminal (which needs a surface, so
  /// only `TerminalSessions` can build it) and for anything unrecognised.
  ///
  /// Deliberately lenient where the capture direction above is exhaustive: an unknown kind is a tab
  /// written by a NEWER build, and dropping it is the whole point of the lossy schema.
  var restoredContent: TabContent? {
    switch kind {
    case Self.diffKind:
      guard let payload = diff, let source = payload.source.source,
        let change = ChangedFile.Change(rawValue: payload.change)
      else { return nil }
      return .diff(
        DiffDescriptor(
          path: payload.path, change: change, source: source, isPreview: payload.isPreview))
    case Self.fileKind:
      guard let payload = file else { return nil }
      return .file(FileDescriptor(path: payload.path, isPreview: payload.isPreview))
    case Self.changesetKind:
      guard let payload = changeset else { return nil }
      return .changeset(
        ChangesetDescriptor(
          commitID: payload.commitID, title: payload.title, isPreview: payload.isPreview,
          selectedPath: payload.selectedPath))
    default:
      return nil
    }
  }

  /// The per-tab diff layout override, if this tab had one.
  var restoredDiffViewMode: DiffViewMode? { diff?.viewMode.flatMap(DiffViewMode.init(rawValue:)) }
  /// The per-tab Markdown source/preview override, if this tab had one.
  var restoredMarkdownPreview: Bool? { file?.markdownPreview }
}

/// A non-terminal content-tab payload the preview/persist openers drive uniformly (issue #59). Diffs,
/// files, and changesets differ only in how they wrap into a `TabContent` case and what makes two of
/// them the *same* tab (the dedup / retarget identity) — extracting this collapses the otherwise
/// near-identical per-kind openers into one `openContentPreview` + one `openContentPersistent`.
protocol ContentDescriptor: Sendable {
  /// VS-Code preview flag (italic chip, replaced by the next preview). The openers set it before use.
  var isPreview: Bool { get set }
  /// Wrap this descriptor into its `TabContent` case.
  func makeTabContent() -> TabContent
  /// Whether an already-open tab shows the same content — the identity used to dedupe (re-select)
  /// and to decide whether the lone preview can be retargeted in place. The preview flag is excluded,
  /// matching each type's `sameFile`.
  func matches(_ content: TabContent) -> Bool
}

/// The state a terminal tab owns: its surface plus the live-title/progress the surface reports. Kept
/// in the `.terminal` payload so a content tab carries none of it.
struct TerminalState {
  /// The 1:1 terminal surface this tab owns.
  let view: GhosttySurfaceView
  /// Daemon session this pane attaches to (separate from `tab.id`, which remints on restore).
  var sessionID: UUID?
  /// Shown until the surface reports a title — and again whenever it reports an empty one.
  let defaultTitle: String
  /// The surface's latest non-empty title (OSC 0/2 via shell integration): the running command while
  /// busy, the working directory when idle. Nil until the first report (issue #2).
  var liveTitle: String?
  /// The agent identified from the PTY foreground process (or conservatively from shell title as a
  /// fallback for multiplexed sessions). Providers repaint OSC titles while they run, so this is
  /// deliberately latched until `command_finished` instead of being derived from `liveTitle`.
  var activeAgentBackend: AgentBackend?
  /// The curated CLI/TUI tool recognized as currently running in this terminal's foreground (issue
  /// #141) — a broader, data-driven sibling of `activeAgentBackend`, latched/cleared identically.
  var activeTool: RecognizedTool?
  /// The surface's latest reported cwd (`GHOSTTY_ACTION_PWD` via shell integration), mirrored here as
  /// observable state so the detail-panel status bar shows the live directory (issue #49). Nil until
  /// the shell first reports; the status bar falls back to the surface's `lastKnownCwd` / target path.
  var cwd: String?
  /// OSC 9;4 progress — the *only* signal that drives `isRunning`, matching how Ghostty and Muxy work
  /// (neither ties "busy" to the title). `true` while the running program reports it's working,
  /// `false`/`nil` when it's idle, done, or never reported any. Reset at `command_finished`; the
  /// surface also clears it via a 15s safety timer (issue #28 follow-up).
  var progressActive: Bool?
}

/// Owns the live terminals for each target (a workroom or a project root) for the app session, so
/// switching targets/tabs hides/shows terminals instead of tearing them down (a dev server in one tab
/// keeps running while you look at another). Keyed on the project-scoped `TerminalTarget.ID`.
///
/// Split model (issue #3) is **many groups, not one**: a target can hold SEVERAL `PaneLayout` split
/// groups at once — `[ B │ C ]` and `[ E │ F ]` both grouped, with solo tabs alongside. The groups are
/// disjoint (a tab belongs to at most one) and each holds ≥2 leaves; at most one is *visible*, the one
/// containing the focused tab. Splitting two solo tabs therefore leaves existing groups alone instead
/// of replacing them (which is what the old single-layout model did — grouping C+D silently unsplit
/// A+B). Mirrors `AppStore+WorkroomSplit`, which went many-groups one level up first.
///
/// The shared tab strip lists every tab; each group's members render as a contiguous bracketed run,
/// ordered by its split tree (`displayedTabIDs`). The whole layout — tabs, order, splits, focus — is
/// captured to disk and rehydrated by `restore(_:for:)` (issue #46); ordinary workroom shells reattach
/// via `sessionID` when background sessions are on.
///
/// ```
///   STRIP:  A  [ B │ C ]  D  [ E │ F ]    focused == C  →  CONTENT renders B│C.
///              └ bracket ┘     └ bracket ┘    focused == A  →  CONTENT renders just A; both groups persist.
/// ```
@MainActor
final class TerminalSessions: ObservableObject {
  /// Every tab for a target, by id — the single source of truth for surfaces/titles.
  @Published private var tabsByTarget: [TerminalTarget.ID: [TerminalTab.ID: TerminalTab]] = [:]
  /// The strip order (loose). The displayed order normalises this so EACH group's members are a
  /// contiguous run in that group's split-tree order — see `displayedTabIDs`.
  @Published private var orderByTarget: [TerminalTarget.ID: [TerminalTab.ID]] = [:]
  /// The split groups for a target. Disjoint (a tab belongs to at most one) and each always ≥2 leaves
  /// — a lone tab is "no split". **Array order carries no meaning**: a group is addressed by
  /// membership, and the strip places each group's run at its earliest member's slot
  /// (`normalizedTabIDs`), so appending a rebuilt group is always safe.
  @Published private var splitsByTarget: [TerminalTarget.ID: [TerminalPaneLayout]] = [:]
  /// The focused/selected tab per target. Selection = this tab (+ its split, if it's a member).
  @Published private var focusedTabByTarget: [TerminalTarget.ID: TerminalTab.ID] = [:]
  /// Bumped when a *visible but non-focused* pane reports activity (D3): the renderer flashes that
  /// pane's border instead of badging it (you can see it, so no banner/badge — just a glance cue).
  /// Keyed by tab id; the value is an opaque counter the leaf view watches for changes.
  @Published private(set) var activityPulses: [TerminalTab.ID: Int] = [:]
  /// The tabs currently living in their own window (issue #172). Membership only — the windows
  /// themselves are owned by `AppStore`'s `DetachedPaneWindows`, and the two are kept in step by
  /// `detachPane`/`dockPane` firing `onPaneDetached`/`onPaneDocked`. The invariant every reader may
  /// rely on: **a tab in here has exactly one live detached window, and vice versa.**
  ///
  /// A detached tab is deliberately absent from `splitsByTarget` (detaching runs the same removal
  /// `extractFromSplit` does), so the split/divider/auto-even machinery needs no awareness of it.
  @Published private(set) var detachedTabIDs: Set<TerminalTab.ID> = []
  /// The pane rects the renderer last laid out, per target — the only measurement a CONTENT pane
  /// (diff / file / changeset) has, since it owns no `GhosttySurfaceView` whose bounds could be
  /// read. Fed by `PaneTreeView` through a preference (so it is written after layout, never during
  /// body evaluation) and consumed only by `fits`.
  ///
  /// Deliberately **not** `@Published`: it is written from a layout callback on every resize, and
  /// publishing from there would both churn the view graph and risk "Publishing changes from within
  /// view updates". Nothing renders from it — it is a measurement cache, not model state.
  var paneRects: [TerminalTarget.ID: [TerminalTab.ID: CGRect]] = [:]

  /// The rect `PaneTreeView` lays a target's whole split out in — the container those `paneRects`
  /// tile. Same feed, same posture (written after layout, never `@Published`), but a different
  /// question: the per-pane rects answer "can THIS pane be halved", while auto-even (issue #126)
  /// has to ask "can the GROUP hold another pane" and "would evening actually render evenly here".
  /// Neither is derivable from the pane rects alone once a divider has been dragged.
  ///
  /// Absent (no layout pass yet) means unmeasured, which every reader treats as permissive — the
  /// same posture `PaneTreeLayout.canSplit` takes for a zero rect.
  var paneSpace: [TerminalTarget.ID: CGRect] = [:]

  /// Issue #126's auto-even pref, read live so the Settings toggle applies to the very next split
  /// without a relaunch. Injected rather than read inline so tests can drive both states: a parallel
  /// test worker shares (and wipes) the `Defaults` domain cross-process, which is why
  /// `AppStoreCreateWorkroomTests` stopped arming auto-run through `Defaults[.runCommands]`.
  var autoEvenSplits: () -> Bool = { Defaults[.autoResizeSplitsEvenly] }
  /// Per-target running counter so tab titles ("Terminal 1", "2", …) stay stable across closes.
  private var counts: [TerminalTarget.ID: Int] = [:]
  /// The app-wide most-recently-focused pane order (issue #132), written by `setFocused` and read by
  /// `closeSuccessor`. Injectable like `makeView` so a test never mutates the singleton's order.
  var recency: SwitcherRecency = .shared
  /// Set once by `AppStore`: forwards each terminal's notification-worthy activity (OSC) up to the
  /// notification spine. A closure (not a store reference) so sessions stay ignorant of `AppStore`.
  var activityHandler: ((TerminalTarget.ID, TerminalTab.ID, TerminalActivity) -> Void)?
  /// Set once by `AppStore`: fired whenever the focused tab of a target actually changes, so
  /// navigation history (issue #26) can record the new location. A closure (not a store reference),
  /// mirroring `activityHandler`, so sessions stay ignorant of `AppStore`. `tabID` is nil when the
  /// target's focus was cleared (a `reap` passes `notify: false`, so that case never reaches here).
  var onFocusChange: ((TerminalTarget.ID, TerminalTab.ID?) -> Void)?
  /// Set once by `AppStore`: fired when a tab's recorded **location** changes underneath a focus that
  /// did not move, so navigation history can record it. `onFocusChange` cannot cover this: retargeting
  /// the shared preview tab in place mutates `content` and leaves `focusedTabByTarget` untouched, so
  /// every Changes/Files click after the first recorded nothing at all — the whole bug.
  ///
  /// "Location", not "content identity": one of the two fire sites is `setChangesetSelectedPath`, and a
  /// changeset's selected file is deliberately NOT part of content identity (`sameChangeset` excludes
  /// it, which is why the preview can be retargeted across files without becoming a different tab). It
  /// is still its own back/forward step, so it belongs here.
  ///
  /// Fired from exactly the two sites that mutate content identity (`openContentPreview`'s retarget
  /// branch and `setChangesetSelectedPath`) and nowhere else. The other opener branches all end in
  /// `setFocused` on a tab that was not focused, so `onFocusChange` already records them; firing here
  /// too would redefine this seam as "an open happened", which is not what it means.
  var onTabContentChange: ((TerminalTarget.ID, TerminalTab.ID) -> Void)?
  /// Set once by `AppStore`: the tabs just removed by a `closeTab` or `reap`, so navigation history
  /// can prune their now-dead entries (issue #26 — honest back/forward enablement).
  var onTabsRemoved: ((TerminalTarget.ID, [TerminalTab.ID]) -> Void)?
  /// Set once by `AppStore`: a surface in this target became first responder (a click into its
  /// terminal), or a tab in it was *deliberately* selected (`select` — a chip tap / ⌘1–9). Routes focus
  /// up to the *workroom* selection in a workroom split (issue #23 follow-up), so ⌘T/Run/notifications
  /// target that pane's workroom — and so a tab clicked in a co-displayed but non-focused member
  /// actually takes keyboard focus (selecting it alone leaves `surfaceActive` false, so the surface
  /// never grabs first responder). A closure (not a store reference), mirroring `onFocusChange`, so
  /// sessions stay ignorant of `AppStore`.
  var onSurfaceFocused: ((TerminalTarget.ID) -> Void)?
  /// Set once by `AppStore`: a pane just became detached and needs a window opened for it at the
  /// given SCREEN point (issue #172). A closure, not a store reference, so sessions stay ignorant of
  /// `AppStore` — the same posture as `onFocusChange`/`onTabsRemoved` above. Firing it is the second
  /// half of the one coordinated transition `detachPane` performs; nothing else may open that window.
  var onPaneDetached: ((TerminalTarget.ID, TerminalTab.ID, CGPoint) -> Void)?
  /// The mirror of `onPaneDetached`: this tab is docked again, so its window must go. Also fired by
  /// `closeTab`/`reap` by way of `undetach`, so a detached window can never outlive its tab.
  var onPaneDocked: ((TerminalTab.ID) -> Void)?
  /// Something tried to focus a detached pane. Its window is the honest answer, so `AppStore` raises
  /// it (see `setFocused`, which refuses the focus write itself).
  var onPaneRaiseRequested: ((TerminalTab.ID) -> Void)?
  /// A restored pane was detached when the session was saved, so its window must be rebuilt at the
  /// saved frame. Separate from `onPaneDetached` because restore is not a gesture: there is no cursor
  /// to place the window at, and the frame is authoritative.
  var onPaneRestoredDetached: ((TerminalTarget.ID, TerminalTab.ID, NSRect) -> Void)?

  /// Factory seam (plan T1): how a surface view is created for a target at a working directory.
  /// Overridable in tests so the lifecycle can be exercised without a real window/shell. The cwd
  /// argument lets a ⌘D split inherit the focused pane's directory.
  var makeView: (TerminalTarget, String, String?) -> GhosttySurfaceView = { _, cwd, command in
    GhosttySurfaceView(workingDirectory: cwd, command: command)
  }

  /// How a foreground command not in the curated `ToolLogoRegistry` gets tallied (issue #141
  /// follow-up). Overridable in tests so exercising `updateTitle` never writes the developer's own
  /// `Application Support` file as a side effect — same reasoning as `makeView`.
  ///
  /// Two things the production default must do, found by review:
  /// - **Hop off the main thread.** `updateTitle` runs synchronously inside `ghostty_app_tick`
  ///   (`GhosttyApp.swift`'s render/IO pump, confirmed `DispatchQueue.main`-bound), and the dedup
  ///   gate here is a title-STRING change, not a per-executable-per-session memo — every distinct
  ///   command line typed in an uncurated shell (which is most ordinary commands) does a blocking
  ///   read-decode-encode-atomic-write if this ran inline. This app has two prior documented
  ///   AppHang incidents of exactly this shape (unbounded synchronous work in a main-thread runtime
  ///   callback) — this must not be a third.
  /// - **Skip under `UITestFixture.isActive`.** Every other side-effecting path added around this
  ///   era of the codebase gates on it; without it, any XCUITest run (or an ordinary `⌘R`/`make
  ///   app-run` Dev session) writes real entries into the same file the developer inspects for
  ///   curation signal, defeating the feature's own purpose.
  var recordUnrecognizedTool: (String) -> Void = { name in
    guard !UITestFixture.isActive else { return }
    DispatchQueue.global(qos: .utility).async {
      UnrecognizedToolUsage.recordUnrecognized(name)
    }
  }

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
  static let minPaneWidth: CGFloat = 300
  /// Smallest usable pane HEIGHT (points). Raised 120 → 150 with issue #150: a pane now carries 56pt
  /// of horizontal chrome (a 28pt title bar above the content and a 28pt status bar below it) where it
  /// used to carry 28. 150 keeps the same ~94pt of actual content the old 120 left, rather than
  /// shrinking every stacked pane to roughly four terminal rows.
  ///
  /// Read together with `fits(splitting:)`, which measures the whole PANE rect — chrome included — for
  /// every content kind, so this number means the same thing for a terminal and a diff pane.
  static let minPaneHeight: CGFloat = 150
  /// Inter-pane gutter thickness (points), shared by the fit guard and the renderer. No separator
  /// rule is drawn anymore, so this is just the gap between panes and the width of the (invisible)
  /// resize hit-zone — kept tight, since the panes' own rounded borders mark the boundary.
  static let dividerThickness: CGFloat = 2

  private var appearanceObserver: NSObjectProtocol?

  /// The inline terminal agent (issue #49). Owned here so the per-tab callbacks can feed it; injected
  /// into the environment (see `WorkroomApp`) so the pane banner observes it. Opt-in, default off.
  let agentManager: TerminalAgentManager

  /// `closeTab`'s persisted-session kill, in flight. Tracked so quitting can wait for it —
  /// `closeTab` itself stays synchronous (it's called from UI actions, not `async` contexts), but
  /// an unawaited kill racing an immediate app quit would leave that tab's daemon session running
  /// despite the user having explicitly closed it moments before.
  private var pendingCloseKills: [Task<Void, Never>] = []

  /// Wait for every `closeTab`-initiated kill still in flight. Called at quit, across every
  /// window's `TerminalSessions`, alongside (not instead of) the persistence-off `endAllSessions`
  /// sweep — that sweep only fires when persistence is off, but a closed tab's session must not
  /// outlive the quit either way.
  func awaitPendingCloseKills() async {
    let tasks = pendingCloseKills
    pendingCloseKills.removeAll()
    for task in tasks { await task.value }
  }

  init() {
    // Under the UI-test agent fixture, drive a stub backend (no network) with the feature + auto on
    // so the XCUITest sees the banner; otherwise the normal opt-in, default-off real runner.
    if UITestFixture.agentStub {
      agentManager = TerminalAgentManager(
        runner: StubAgentRunner(envelope: UITestFixture.agentStubEnvelope),
        featureEnabled: { true }, autoDiagnoseEnabled: { true })
    } else {
      agentManager = TerminalAgentManager()
    }

    appearanceObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil,
      queue: .main
    ) { _ in
      // OS appearance flipped while pref = System: route through the chokepoint so chrome tokens
      // recompute (the active variant flips) alongside the terminal re-theme (issue #36).
      Task { @MainActor in ThemeService.shared.applyActiveTheme() }
    }
  }

  deinit {
    if let appearanceObserver {
      DistributedNotificationCenter.default().removeObserver(appearanceObserver)
    }
  }

  // MARK: Queries

  // THREE tab-list accessors, and since issue #172 they deliberately DISAGREE about a detached tab.
  // They look near-identical and they answer three different questions, so do not "consolidate" any
  // two of them — collapsing the first two reintroduces the blank-pane class of issue #3:
  //
  //   displayedTabIDs  "what is in the strip / the layout"   detached: EXCLUDED
  //   allTabs          "every tab this target owns"          detached: INCLUDED
  //   visibleTabIDs    "what must keep rendering"            detached: INCLUDED
  //   sessionCapture   "what must survive a relaunch"        detached: INCLUDED
  //
  // `allTabs` is the one to reach for when CLOSING or refreshing model state. Using `displayedTabIDs`
  // there is how "Close All Tabs" came to leave a popped-out pane alive with its process running.
  //
  // A detached pane is not in this window's strip, but its surface is very much on screen (in its own
  // window) and it very much has to come back after a relaunch. `normalizedTabIDs` is the shared core
  // the first and third read, so the split-anchor normalisation itself exists once.

  /// Tab ids in strip order, **excluding detached panes** — the layout and the strip both read this,
  /// so a detached tab leaves both by this one exclusion.
  func displayedTabIDs(for target: TerminalTarget) -> [TerminalTab.ID] {
    displayedTabIDs(forTargetID: target.id)
  }

  /// The id-addressed core of `displayedTabIDs(for:)`. Session capture (issue #46) walks
  /// `activeTargetIDs` and has no `TerminalTarget` value in hand, and only the id was ever used.
  func displayedTabIDs(forTargetID targetID: TerminalTarget.ID) -> [TerminalTab.ID] {
    guard !detachedTabIDs.isEmpty else { return normalizedTabIDs(forTargetID: targetID) }
    return normalizedTabIDs(forTargetID: targetID).filter { !detachedTabIDs.contains($0) }
  }

  /// Every tab a target owns, in strip order, **detached panes included** — the answer to "act on
  /// all of this target's tabs", as opposed to `tabs(for:)`'s "what the strip shows".
  ///
  /// Anything that CLOSES, REAPS or refreshes model state must use this: a detached pane is still a
  /// live tab with a live process, and `tabs(for:)` hides it. That distinction is what four bulk-close
  /// paths got wrong when `tabs(for:)` was narrowed (issue #172).
  func allTabs(for target: TerminalTarget) -> [TerminalTab] {
    let dict = tabsByTarget[target.id] ?? [:]
    return normalizedTabIDs(forTargetID: target.id).compactMap { dict[$0] }
  }

  /// Strip order with EACH group's members normalised into one contiguous run, **detached panes
  /// included**. This is the raw ordering; `displayedTabIDs` is this minus the detached ones, and
  /// `sessionCapture` reads this directly so a detached pane is persisted in its old strip position.
  ///
  /// The loose order, with every group's members replaced by that group's tree order as a contiguous
  /// block at its earliest member's slot. So each bracket is always one run and strip order always
  /// matches pane order (rearranging panes IS strip reorder). Mirrors
  /// `AppStore.displayedWorkroomTargets()`.
  func normalizedTabIDs(forTargetID targetID: TerminalTarget.ID) -> [TerminalTab.ID] {
    let order = orderByTarget[targetID] ?? []
    let groups = splitsByTarget[targetID] ?? []
    guard !groups.isEmpty else { return order }
    let groupOf = splitGroupIndices(forTargetID: targetID)
    var emitted: Set<Int> = []
    var placed: Set<TerminalTab.ID> = []
    var result: [TerminalTab.ID] = []
    for id in order {
      guard let group = groupOf[id] else {
        result.append(id)
        continue
      }
      // First member of this group in strip order: emit the whole group here (in tree order) and skip
      // its later members. `placed` keeps an id from being emitted twice even if the disjointness
      // invariant ever broke — a duplicate id in the strip is a duplicate `ForEach` identity, which
      // SwiftUI renders as garbage rather than degrading.
      guard emitted.insert(group).inserted else { continue }
      for member in groups[group].tabIDs where placed.insert(member).inserted {
        result.append(member)
      }
    }
    return result
  }

  // MARK: Session capture (issue #46)

  /// Everything one target contributes to a saved session, addressed by id.
  ///
  /// One accessor rather than four because the four dictionaries behind it are `@Published private`
  /// and should stay that way — capture reads through the public queries, and this is the single
  /// exception it needs (`counts`, which nothing else exposes).
  struct SessionCapture {
    /// Tabs in DISPLAYED order. Safe to persist as the strip order: display normalisation is a fixed
    /// point, so feeding it back in reproduces the same layout.
    let tabs: [TerminalTab]
    /// Every split group, in no meaningful order (see `splitsByTarget`).
    let splits: [TerminalPaneLayout]
    let focused: TerminalTab.ID?
    /// The "Terminal N" counter, so the next ⌘T after a restore continues the numbering.
    let counter: Int
  }

  func sessionCapture(forTargetID targetID: TerminalTarget.ID) -> SessionCapture? {
    let dict = tabsByTarget[targetID] ?? [:]
    guard !dict.isEmpty else { return nil }
    // `normalizedTabIDs`, NOT `displayedTabIDs`: a detached pane (issue #172) must be captured in its
    // old strip position or it is lost. This matters before quit as well as at quit — the app writes
    // the session on `willResignActive`, so a filtered capture would drop a detached pane from merely
    // ⌘-tabbing away.
    let ordered = normalizedTabIDs(forTargetID: targetID).compactMap { dict[$0] }
    guard !ordered.isEmpty else { return nil }
    return SessionCapture(
      tabs: ordered, splits: splitsByTarget[targetID] ?? [], focused: focusedTabByTarget[targetID],
      counter: counts[targetID] ?? ordered.count)
  }

  func tabs(for target: TerminalTarget) -> [TerminalTab] {
    let dict = tabsByTarget[target.id] ?? [:]
    return displayedTabIDs(for: target).compactMap { dict[$0] }
  }

  /// Number of live tabs for a target id (issue #30 — lets `AppStore` prune the sidebar's
  /// terminal-subtree expand flag when a close drops a target below the 2-tab disclosure threshold).
  func tabCount(forTargetID id: TerminalTarget.ID) -> Int { (tabsByTarget[id] ?? [:]).count }

  /// Whether any target owns the tab `id`. Tab ids are unique across windows, so `WindowRegistry`
  /// uses this to route an OS-notification click to the window that owns the tab (issue #70).
  func containsTab(_ id: TerminalTab.ID) -> Bool {
    tabsByTarget.values.contains { $0[id] != nil }
  }

  /// The set of target ids that currently own at least one terminal — the "active" targets backing
  /// the Workrooms View tab bar (issue #23). Filtered on **non-empty** because `closeTab` leaves an
  /// emptied target as `[:]` (key present) while `reap` removes the key entirely; both must read as
  /// inactive. Reads `@Published tabsByTarget`, so observers re-render as targets gain/lose terminals.
  var activeTargetIDs: Set<TerminalTarget.ID> {
    Set(tabsByTarget.compactMap { $0.value.isEmpty ? nil : $0.key })
  }

  /// Whether any terminal in this target is mid-command (has a live command title, issue #2) — drives
  /// the sidebar's running spinner.
  func isRunning(forTargetID id: TerminalTarget.ID) -> Bool {
    (tabsByTarget[id] ?? [:]).values.contains { $0.isRunning }
  }

  /// The **visible** group: the one containing the focused tab, or nil when the focused tab is solo.
  /// Every "is a split on screen" read keys off this — a group whose members are all unfocused
  /// persists but isn't displayed (select a member and it reappears).
  func split(for target: TerminalTarget) -> TerminalPaneLayout? {
    focusedTabByTarget[target.id].flatMap { split(containing: $0, for: target) }
  }

  /// Every split group this target owns, visible or not (empty when nothing is grouped).
  func splits(for target: TerminalTarget) -> [TerminalPaneLayout] {
    splitsByTarget[target.id] ?? []
  }

  /// The group `tabID` belongs to, or nil when it isn't grouped. Groups are disjoint, so this is the
  /// one authority on "which group is this tab in" — as opposed to `split(for:)`, which answers the
  /// narrower "which group is on screen".
  func split(containing tabID: TerminalTab.ID, for target: TerminalTarget) -> TerminalPaneLayout? {
    splitIndex(containing: tabID, for: target.id).map { splitsByTarget[target.id]![$0] }
  }

  /// Index into `splitsByTarget[targetID]` of the group holding `tabID` (nil when ungrouped).
  /// `private` on purpose: an index is only valid until the next mutation of the array, so it must
  /// not escape this file — callers outside want `split(containing:for:)`.
  private func splitIndex(containing tabID: TerminalTab.ID, for targetID: TerminalTarget.ID) -> Int?
  {
    splitsByTarget[targetID]?.firstIndex { $0.contains(tabID) }
  }

  /// `member → group index` for every grouped tab, so the strip can bracket each group's run and tell
  /// a group boundary (member of A next to member of B, or next to a solo chip) from an interior one.
  /// Empty when nothing is grouped. Build it ONCE per render pass and thread it down — it walks every
  /// leaf of every group, and the strip consults it per chip. Mirrors
  /// `AppStore.workroomSplitGroupIndices()`, first-group-wins tie-break included.
  func splitGroupIndices(for target: TerminalTarget) -> [TerminalTab.ID: Int] {
    splitGroupIndices(forTargetID: target.id)
  }

  private func splitGroupIndices(forTargetID targetID: TerminalTarget.ID) -> [TerminalTab.ID: Int] {
    var groupOf: [TerminalTab.ID: Int] = [:]
    for (index, group) in (splitsByTarget[targetID] ?? []).enumerated() {
      for id in group.tabIDs where groupOf[id] == nil { groupOf[id] = index }
    }
    return groupOf
  }

  /// Look up a tab by id (the pane renderer resolves leaves → surfaces through this).
  func tab(_ id: TerminalTab.ID, for target: TerminalTarget) -> TerminalTab? {
    tabsByTarget[target.id]?[id]
  }

  /// The surface view for a tab, located by target + tab id without a `TerminalTarget` value. Lets
  /// the run-command graceful-stop paths (issue #7) reach a live process by id alone — e.g. on quit,
  /// where `AppStore` iterates `runStates` keyed by `TerminalTarget.ID`.
  func view(
    forTab tabID: TerminalTab.ID, inTarget targetID: TerminalTarget.ID
  ) -> GhosttySurfaceView? {
    tabsByTarget[targetID]?[tabID]?.surface
  }

  /// The focused tab (selection), falling back to the first tab in strip order.
  func focusedTab(for target: TerminalTarget) -> TerminalTab? {
    let dict = tabsByTarget[target.id] ?? [:]
    if let id = focusedTabByTarget[target.id], let match = dict[id] { return match }
    return displayedTabIDs(for: target).first.flatMap { dict[$0] }
  }

  /// Alias kept so existing call sites/tests read naturally. "The active tab" is the focused pane.
  func activeTab(for target: TerminalTarget) -> TerminalTab? { focusedTab(for: target) }

  /// Whether the content area should render the split (the focused tab belongs to it) vs a solo tab.
  func isSplitVisible(for target: TerminalTarget) -> Bool { split(for: target) != nil }

  /// The tab ids currently on screen: the split's members when the split is visible, else the focused
  /// solo tab — PLUS this target's detached panes, which are on screen in their own windows. Drives
  /// occlusion.
  ///
  /// The detached half is load-bearing, not tidiness: `reconcileOcclusion` `setVisible(false)`s every
  /// tab that is not in this list, so omitting them would pause a popped-out terminal's renderer the
  /// moment anything touched this store — a black pane in a window the user is looking at. It is also
  /// why a detached pane survives the origin switching workroom: it never leaves its own window, so
  /// `viewDidMoveToWindow`'s pause path cannot fire either.
  func visibleTabIDs(for target: TerminalTarget) -> [TerminalTab.ID] {
    let detached = detachedTabIDs.filter { tabsByTarget[target.id]?[$0] != nil }
    if let split = split(for: target) { return split.tabIDs + detached }
    if let focused = focusedTab(for: target) { return [focused.id] + detached }
    return Array(detached)
  }

  // MARK: Lifecycle

  /// Create the target's first terminal the first time its pane appears. Once opened, an emptied tab
  /// set is left as-is (the user closed them on purpose).
  func ensureTab(for target: TerminalTarget) {
    if orderByTarget[target.id] == nil { addTab(for: target) }
  }

  // MARK: Session restore (issue #46)

  /// What a restore produced: how many tabs of any kind came back.
  struct RestoreResult: Equatable {
    var count: Int

    static let nothing = RestoreResult(count: 0)
  }

  /// Re-materialise a target's panes from a saved session.
  ///
  /// The only path that sets the four per-target dictionaries wholesale, so it lives here beside the
  /// mutation primitives rather than in `AppStore`. Three deliberate properties:
  ///
  /// - **Tabs get FRESH ids.** A `TerminalTab.ID` is unique across *windows* at runtime and OS
  ///   notification clicks are routed by it (`WindowRegistry.ownerOf(tabID:)`), so reviving persisted
  ///   ids would put a duplicate-id hazard one bug away for no benefit. The persisted keys are a join
  ///   key valid only within one snapshot; order, split and focus are rewired through them here.
  /// - **Focus is set with `notify: false`** (the escape `reap` uses): a restore is not a navigation,
  ///   and firing `onFocusChange` would seed back/forward with a place the user never went.
  /// - **No-op when the target already has tabs**, so a restore can never race or duplicate a live
  ///   session.
  ///
  /// Terminals come back in their remembered directory. When background sessions are on they
  /// reattach to the daemon; otherwise they are a fresh login shell. Nothing spawns here:
  /// constructing a surface is inert until it enters a window.
  @discardableResult
  func restore(
    _ session: TargetSession, for target: TerminalTarget
  ) -> RestoreResult {
    guard (tabsByTarget[target.id] ?? [:]).isEmpty else { return .nothing }

    var idsByKey: [String: TerminalTab.ID] = [:]
    var order: [TerminalTab.ID] = []
    var tabs: [TerminalTab.ID: TerminalTab] = [:]
    var restoredDetached: [(TerminalTab.ID, NSRect)] = []

    for saved in session.tabs {
      let tab: TerminalTab
      if saved.kind == TabSession.terminalKind, let payload = saved.terminal {
        // `command:` is deliberately never passed: run tabs are not persisted, and this makes even a
        // hand-edited file unable to start a process on launch.
        let cwd = Self.restoredCwd(payload.cwd, fallback: target.path)
        tab = makeTerminalTab(
          for: target,
          cwd: cwd,
          title: payload.defaultTitle,
          sessionID: payload.sessionID.flatMap(UUID.init(uuidString:)))
      } else if let content = saved.restoredContent {
        tab = TerminalTab(
          content: content, diffViewModeOverride: saved.restoredDiffViewMode,
          markdownPreviewOverride: saved.restoredMarkdownPreview)
      } else {
        continue
      }
      idsByKey[saved.key] = tab.id
      order.append(tab.id)
      tabs[tab.id] = tab
      // A pane that was in its own window comes back in one (issue #172). Recorded here and reported
      // to `AppStore` below, once the tab dictionaries are actually populated — the window's content
      // resolves the tab by id, so it must exist before the window opens.
      if let frame = saved.detachedFrame.map(NSRectFromString), frame.width > 0, frame.height > 0 {
        restoredDetached.append((tab.id, frame))
      }
    }

    guard !order.isEmpty else { return .nothing }

    tabsByTarget[target.id] = tabs
    orderByTarget[target.id] = order
    // Detached tabs resolve to NOTHING here, so a saved group naming one comes back without it.
    // `splitsByTarget`'s invariant is that a detached tab is never a member (see its doc): rendering
    // a group that contains one puts its surface in the origin pane tree as well as its own window,
    // re-homing the libghostty view and blanking the detached window — the same failure the
    // `setFocused` guard below exists to prevent, reached by a different door. `sanitized()` waves
    // the shape through because the tab is live, so the exclusion belongs here, where the detached
    // set is known. `materialize` already collapses unresolved leaves and drops a group that falls
    // below two, so a two-member group with one detached member correctly restores as no group.
    let detachedIDs = Set(restoredDetached.map(\.0))
    let restoredSplits = session.splits.compactMap { saved in
      saved.materialize { key in idsByKey[key].flatMap { detachedIDs.contains($0) ? nil : $0 } }
    }
    splitsByTarget[target.id] = restoredSplits.isEmpty ? nil : restoredSplits
    // Mark detached panes BEFORE choosing focus. `setFocused`'s own guard refuses to focus a detached
    // tab (focusing one makes `contentLayout` render it back in THIS window and re-homes the
    // libghostty view out of its own window, which then goes blank) — but that guard reads
    // `detachedTabIDs`, so with the insert below it, it could not fire during a restore. The ordinary
    // flow that reached it: detach your only pane, quit, relaunch — `closeSuccessor` returns nil for a
    // sole tab, so nothing was persisted as focused and the `?? order.first` fallback landed on the
    // detached pane (`order` deliberately includes detached tabs, issue #172). The fallback skips them
    // for the same reason. Windows still open afterwards, once the tab dictionaries are populated.
    for (tabID, _) in restoredDetached { detachedTabIDs.insert(tabID) }
    setFocused(
      session.focusedKey.flatMap { idsByKey[$0] }.flatMap {
        detachedTabIDs.contains($0) ? nil : $0
      } ?? order.first { !detachedTabIDs.contains($0) }, for: target.id, notify: false)
    // `makeTerminalTab` bumps the counter per terminal it builds, so take whichever is higher: the
    // saved value keeps "Terminal 7" from becoming "Terminal 3" again after closes.
    counts[target.id] = max(session.terminalCounter ?? 0, counts[target.id] ?? 0)
    // Open the windows AFTER the dictionaries are set: `onPaneDetached` builds a window whose content
    // looks the tab up by id. Restoring is not a user gesture, so this skips `detachPane` — the split
    // was already captured without these tabs, and membership was recorded above.
    for (tabID, frame) in restoredDetached {
      onPaneRestoredDetached?(target.id, tabID, frame)
    }
    reconcileOcclusion(for: target)
    return RestoreResult(count: order.count)
  }

  /// The directory a restored terminal should open in: the remembered one while it is still a live
  /// directory, else the target's own path. libghostty cannot spawn into a directory that no longer
  /// exists, so an unchecked value would turn a deleted folder into a dead pane.
  ///
  /// Pure and `nonisolated` so it is unit-testable without a session, a target, or a surface.
  nonisolated static func restoredCwd(_ cwd: String?, fallback: String) -> String {
    guard let cwd, !cwd.isEmpty else { return fallback }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return fallback }
    return cwd
  }

  /// Open a new solo terminal at the end of the strip and focus it (⌘T). Does not touch the split.
  @discardableResult
  func addTab(for target: TerminalTarget, sessionID: UUID? = nil) -> TerminalTab {
    let tab = makeTerminalTab(for: target, cwd: target.path, sessionID: sessionID)
    insert(tab, for: target)
    setFocused(tab.id, for: target.id)
    reconcileOcclusion(for: target)
    return tab
  }

  // MARK: Content tabs (issue #66)
  //
  //   single-click file ─▶ openDiffPreview ─┬─ persisted tab for this file+rev exists → focus it (Inv C)
  //                                          ├─ a preview tab exists → retarget IN PLACE, same id (Inv B)
  //                                          └─ else → new preview tab           (≤1 preview/target: Inv A)
  //   double-click file ─▶ openDiffPersistent ─ create-or-promote a persisted tab
  //   double-click chip / "Keep Open" ─▶ persist ─ flip preview → persisted
  //
  // EVERY branch above must end up recorded in navigation history, and they get there two ways —
  // forget this and back/forward silently stops seeing a whole content kind (that WAS the bug):
  //
  //   Inv A         ─▶ setFocused (a brand-new tab) ─▶ onFocusChange ─▶ AppStore records
  //   Inv B         ─▶ content mutates, focus does NOT ─▶ onTabContentChange ─▶ AppStore records
  //   Inv C         ─▶ focus may EARLY-RETURN (already focused) ─▶ onTabContentChange too, so a
  //                    re-select can reconcile a cursor that a replay left elsewhere
  //   persist / setDiffViewMode / setMarkdownPreview ─▶ NEITHER — a pin and a view mode are not places

  /// Open `descriptor` as the target's single PREVIEW content tab (VS-Code semantics). Returns the
  /// id of the tab now shown. Generic over `ContentDescriptor` so diffs, files, and changesets share
  /// ONE opener (issue #59): the per-kind differences are just how the descriptor builds its
  /// `TabContent` and what makes two of them the same tab. A preview tab is replaced in place by the
  /// next preview, so its id (and thus its strip slot / split position) is stable across retargets.
  ///   - already open for this exact content (preview or persisted) → just select it (Inv C);
  ///   - else the lone preview tab is retargeted IN PLACE — same id, slot, split position (Inv B);
  ///   - else a fresh preview tab (≤1 preview per target: Inv A).
  @discardableResult
  func openContentPreview<D: ContentDescriptor>(_ descriptor: D, for target: TerminalTarget)
    -> TerminalTab.ID
  {
    var desc = descriptor
    desc.isPreview = true
    if let existing = contentTab(matching: desc, in: target.id) {
      focus(existing, for: target)
      // Re-selecting content that is ALREADY the focused tab moves nothing, so `onFocusChange` stays
      // quiet — yet after a replay landed in a tab the history cursor doesn't name, the cursor and the
      // screen disagree, and staying quiet leaves the forward stack pointing at a future that is no
      // longer on screen. Report it and let `record`'s dedup decide: same place ⇒ free no-op, different
      // place ⇒ the entry the user actually re-selected, which truncates forward.
      onTabContentChange?(target.id, existing)
      return existing
    }
    if let previewID = previewTabID(in: target.id), var tab = tabsByTarget[target.id]?[previewID] {
      tab.content = desc.makeTabContent()
      tabsByTarget[target.id]?[previewID] = tab
      focus(previewID, for: target)
      // The content moved but the focus did not, so `onFocusChange` will not fire — this is the one
      // opener branch navigation history cannot otherwise see (issue #26 follow-up).
      onTabContentChange?(target.id, previewID)
      return previewID
    }
    let tab = TerminalTab(content: desc.makeTabContent())
    insert(tab, for: target)
    setFocused(tab.id, for: target.id)
    reconcileOcclusion(for: target)
    return tab.id
  }

  /// Open `descriptor` as a PERSISTED content tab (double-click). If a tab already shows this exact
  /// content, promote it (clear preview) and focus it; else append a persisted tab. The persistent
  /// sibling of `openContentPreview`.
  @discardableResult
  func openContentPersistent<D: ContentDescriptor>(_ descriptor: D, for target: TerminalTarget)
    -> TerminalTab.ID
  {
    var desc = descriptor
    desc.isPreview = false
    if let existing = contentTab(matching: desc, in: target.id) {
      persist(existing, for: target)
      focus(existing, for: target)
      onTabContentChange?(target.id, existing)  // same reconciliation as the preview dedup branch
      return existing
    }
    let tab = TerminalTab(content: desc.makeTabContent())
    insert(tab, for: target)
    setFocused(tab.id, for: target.id)
    reconcileOcclusion(for: target)
    return tab.id
  }

  /// The id of an open content tab whose content matches `descriptor` — the dedup / retarget
  /// identity (see `ContentDescriptor.matches`), the preview flag excluded. Replaces the former
  /// per-kind `diffTab`/`fileTab` matchers.
  private func contentTab(matching descriptor: some ContentDescriptor, in target: TerminalTarget.ID)
    -> TerminalTab.ID?
  {
    tabsByTarget[target]?.first { _, tab in descriptor.matches(tab.content) }?.key
  }

  /// Open a file diff as the target's single PREVIEW content tab (issue #66).
  @discardableResult
  func openDiffPreview(_ descriptor: DiffDescriptor, for target: TerminalTarget) -> TerminalTab.ID {
    openContentPreview(descriptor, for: target)
  }

  /// Open a file diff as a PERSISTED content tab (double-click in Changes).
  @discardableResult
  func openDiffPersistent(_ descriptor: DiffDescriptor, for target: TerminalTarget)
    -> TerminalTab.ID
  {
    openContentPersistent(descriptor, for: target)
  }

  /// Persist a preview content tab (double-click its chip, or "Keep Open" in its menu). No-op unless
  /// it's a preview content tab (diff, file, or changeset).
  func persist(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard var tab = tabsByTarget[target.id]?[tabID] else { return }
    switch tab.content {
    case .diff(var d) where d.isPreview:
      d.isPreview = false
      tab.content = .diff(d)
    case .file(var f) where f.isPreview:
      f.isPreview = false
      tab.content = .file(f)
    case .changeset(var c) where c.isPreview:
      c.isPreview = false
      tab.content = .changeset(c)
    default:
      return
    }
    tabsByTarget[target.id]?[tabID] = tab
  }

  /// Open a file as the target's single PREVIEW content tab (VS-Code semantics), read-only. Shares
  /// the preview slot with diffs — opening a file preview retargets the lone preview tab whatever it
  /// showed. Mirrors `openDiffPreview`.
  @discardableResult
  func openFilePreview(_ descriptor: FileDescriptor, for target: TerminalTarget) -> TerminalTab.ID {
    openContentPreview(descriptor, for: target)
  }

  /// Open a file as a PERSISTED content tab (double-click in the Files panel). Promotes an existing
  /// tab for the same file, else appends a persisted one. Mirrors `openDiffPersistent`.
  @discardableResult
  func openFilePersistent(_ descriptor: FileDescriptor, for target: TerminalTarget)
    -> TerminalTab.ID
  {
    openContentPersistent(descriptor, for: target)
  }

  /// Set a diff tab's per-tab layout override (issue #66), from the tab toolbar's unified/side-by-side
  /// toggle. Reassigns the tab value so `@Published tabsByTarget` fires and the pane's `DiffViewer`
  /// re-renders. No-op for a missing or non-diff tab.
  func setDiffViewMode(
    _ mode: DiffViewMode, forTab tabID: TerminalTab.ID, in target: TerminalTarget
  ) {
    guard var tab = tabsByTarget[target.id]?[tabID], case .diff = tab.content else { return }
    tab.diffViewModeOverride = mode
    tabsByTarget[target.id]?[tabID] = tab
  }

  /// Set the selected file within a changeset tab (the History detail's file list). Reassigns the
  /// tab value so `@Published tabsByTarget` fires and `ChangesetDetailView` re-renders the diff for
  /// the new file — without a reload (its `.task` keys on the commit id, unchanged). No-op for a
  /// missing / non-changeset tab, or when already selected.
  func setChangesetSelectedPath(
    _ path: String?, forTab tabID: TerminalTab.ID, in target: TerminalTarget
  ) {
    guard var tab = tabsByTarget[target.id]?[tabID], case .changeset(var desc) = tab.content,
      desc.selectedPath != path
    else { return }
    desc.selectedPath = path
    tab.content = .changeset(desc)
    tabsByTarget[target.id]?[tabID] = tab
    // A selection change inside a commit is its own location, and it moves no focus — so, like the
    // preview retarget, only this seam can tell navigation history about it.
    onTabContentChange?(target.id, tabID)
  }

  /// Refresh an open diff tab's change kind in place, leaving everything else about the tab alone.
  ///
  /// `DiffDescriptor.change` is captured when the tab opens but is not inert — `DiffViewer` paints it as
  /// the header letter and the tab strip disables "Open file in…" for a `.deleted` source — so it has to
  /// follow the working copy while the tab sits open. Called by `AppStore.refreshOpenDiffChangeKinds`
  /// off the status sweep.
  ///
  /// Deliberately NOT routed through `setContent`, and deliberately silent on `onTabContentChange`: that
  /// callback records a back/forward entry, and a sweep noticing a file went from modified to deleted is
  /// not somewhere the user navigated. Returns whether anything changed; the no-op case publishes
  /// nothing, so a 15s sweep can't invalidate every strip row for free.
  @discardableResult
  func refreshDiffChangeKind(
    _ change: ChangedFile.Change, forTab tabID: TerminalTab.ID, in targetID: TerminalTarget.ID
  ) -> Bool {
    guard var tab = tabsByTarget[targetID]?[tabID], case .diff(var desc) = tab.content,
      desc.change != change
    else { return false }
    desc.change = change
    tab.content = .diff(desc)
    tabsByTarget[targetID]?[tabID] = tab
    return true
  }

  /// Set a file tab's Markdown source/preview override, from the tab toolbar's Source/Preview switch.
  /// Reassigns the tab value so `@Published tabsByTarget` fires and the pane's `PlainFileViewer`
  /// re-renders. No-op for a missing or non-file tab.
  func setMarkdownPreview(
    _ preview: Bool, forTab tabID: TerminalTab.ID, in target: TerminalTarget
  ) {
    guard var tab = tabsByTarget[target.id]?[tabID], case .file = tab.content else { return }
    tab.markdownPreviewOverride = preview
    tabsByTarget[target.id]?[tabID] = tab
  }

  /// Put `payload` back into a SPECIFIC tab, in place — back/forward replay's landing primitive, and the
  /// only caller. Distinct from `openContentPreview`, which retargets whichever tab is *currently* the
  /// preview slot; replay needs the tab the location was recorded in, which may since have been pinned.
  ///
  /// Restoring a tab's own earlier content is not the same as dropping unrelated content on it, which is
  /// what the pin protects against — so `isPreview` is carried over untouched. That also keeps the
  /// ≤1-preview invariant by construction: a pinned tab stays pinned, the preview slot stays the slot,
  /// and no tab is created.
  ///
  /// Refuses a terminal tab. A tab that recorded content cannot become a terminal (only the content
  /// openers write `content`, and none of them writes `.terminal`), so this is a guard against a future
  /// caller rather than a live case — but silently freeing a live surface would be unrecoverable.
  func setContent(_ payload: NavPayload, forTab tabID: TerminalTab.ID, in target: TerminalTarget) {
    guard var tab = tabsByTarget[target.id]?[tabID] else { return }
    let wasPreview = tab.isPreview
    guard case .terminal = tab.content else {
      tab.content = payload.makeTabContent(isPreview: wasPreview)
      tabsByTarget[target.id]?[tabID] = tab
      onTabContentChange?(target.id, tabID)
      return
    }
    assertionFailure("replay must never overwrite a terminal tab's content")
  }

  /// The id of the target's single preview content tab, if one exists (the ≤1-preview invariant).

  private func previewTabID(in target: TerminalTarget.ID) -> TerminalTab.ID? {
    tabsByTarget[target]?.first { _, tab in tab.isPreview }?.key
  }

  /// Open the dedicated "run command" terminal (issue #7): a solo tab that launches `command` in
  /// `cwd`, titled "Run" until the program reports its own title, focused like any new tab — through
  /// `setFocused`, so focus observers fire (it is NOT a direct dict write; see the focus-chokepoint
  /// note on `setFocused`). The caller (`AppStore`) owns the run-state and wires `onChildExited`;
  /// this just creates and shows the tab. Also the mechanism behind an interactive Investigate
  /// session (issue #49) — `AppStore.startInvestigate` is that caller for Investigate, tracking the
  /// tab in `investigateTabs` rather than `runStates` (issue #146): a single-slot-per-target dev-server
  /// run and a freely-multiple interactive agent session are different enough lifecycles to warrant
  /// separate bookkeeping, not a shared one.
  ///
  /// Run-tab lifecycle — one `AppStore.RunState` per target; the pane stays open on exit via
  /// `wait_after_command`:
  /// ```
  ///   armed                       auto-run queued before the workroom's pane exists; consumed on mount
  ///   start (no state / armed) ─▶ spawn surface (command = $SHELL -lic '<cmd>', wait_after_command);
  ///                               focus; state = running
  ///
  ///   running ──────── Run / ⌘R ─────────▶ focus (no respawn)
  ///   running ──────── Stop (1st) ───────▶ Ctrl-C; state = running(interrupted)
  ///   running ──────── Restart ──────────▶ Ctrl-C; state = restarting
  ///   running / running(interrupted) ── child exits ─▶ stopped (pane open)
  ///   running(interrupted) ── Stop (2nd) ─▶ closeTab → ghostty_surface_free (SIGHUP, hard kill)
  ///   restarting ── child exits ─▶ close + respawn (graceful; frees the port); Stop ─▶ running(interrupted)
  ///   stopped ──────── Run / ⌘R / Restart ─▶ close + respawn
  ///   any state ────── close tab (⌘W/✕) / reap ─▶ removed (state cleared via onTabsRemoved)
  /// ```
  /// A backgrounded run tab is never the active tab, so it never mounts — and a libghostty surface
  /// spawns its process only on window-mount. We give the off-window `ensureSurfaceCreated` a sane
  /// initial size so the command starts with reasonable COLUMNS/LINES; it re-sizes on first real mount.
  static let backgroundRunInitialSize = CGSize(width: 800, height: 480)

  @discardableResult
  func addRunTab(for target: TerminalTarget, command: String, cwd: String, focus: Bool = true)
    -> TerminalTab
  {
    let tab = makeRunTab(for: target, command: command, cwd: cwd)
    insert(tab, for: target)
    if focus {
      setFocused(tab.id, for: target.id)
    } else {
      // Issue #67 (run in the background): not focusing means the pane never mounts, so spawn the
      // surface off-window now — otherwise the command would never start and the toast would lie.
      tab.surface?.ensureSurfaceCreated(initialSize: Self.backgroundRunInitialSize)
    }
    reconcileOcclusion(for: target)
    return tab
  }

  /// Respawn a run tab *in place* (issue #40). The old run tab is closed FIRST — freeing its surface
  /// hangs up the PTY (SIGHUP), releasing any bound port before the replacement spawns, the
  /// graceful-restart ordering `AppStore` depends on — but the new run tab then takes the old one's
  /// exact slot: its position in the split (same neighbour, orientation, ratio) and its place in the
  /// strip order, instead of the split collapsing and the replacement reappearing as a solo pane
  /// outside it. With no split (the run tab was solo) this is just close-then-append, like a plain
  /// `addRunTab`. Returns the new tab so the caller wires run-state + `onChildExited`, as `addRunTab` does.
  @discardableResult
  func respawnRunTab(
    replacing oldID: TerminalTab.ID, for target: TerminalTarget, command: String, cwd: String,
    focus: Bool = true
  ) -> TerminalTab {
    // Capture the old tab's place BEFORE closing it collapses its group / drops it from the order.
    let priorSplit = split(containing: oldID, for: target)
    let orderIndex = orderByTarget[target.id]?.firstIndex(of: oldID)

    closeTab(oldID, for: target)  // frees the port (SIGHUP); collapses the group — restored below

    let tab = makeRunTab(for: target, command: command, cwd: cwd)
    tabsByTarget[target.id, default: [:]][tab.id] = tab
    if let orderIndex {
      var order = orderByTarget[target.id] ?? []
      order.insert(tab.id, at: min(orderIndex, order.count))
      orderByTarget[target.id] = order
    } else {
      orderByTarget[target.id, default: []].append(tab.id)
    }
    // Re-derive the group from the pre-close tree with the new tab in the old leaf's slot — exact for
    // any depth (a 3-pane split keeps both siblings), unlike re-inserting beside a guessed neighbour.
    // The close already collapsed that group, so find what is left of it through a surviving member;
    // a two-pane group is gone entirely (index nil) and the rebuilt tree re-enters as a new group.
    if let priorSplit {
      let index = priorSplit.tabIDs.first { $0 != oldID }
        .flatMap { splitIndex(containing: $0, for: target.id) }
      setSplit(
        priorSplit.replacingLeaf(oldID, with: tab.id), groupAt: index, for: target.id,
        evening: false)
    }
    if focus {
      setFocused(tab.id, for: target.id)
    } else {
      // Background restart (issue #67): keep it unfocused, but spawn off-window so the respawned
      // command actually runs (the new tab won't mount until the user opens it).
      tab.surface?.ensureSurfaceCreated(initialSize: Self.backgroundRunInitialSize)
    }
    reconcileOcclusion(for: target)
    return tab
  }

  /// Build a run tab (issue #7) without placing it: the surface launches `command` in `cwd`, titled
  /// "Run" until the program reports its own title. "Process exited. Press any key to close"
  /// (wait_after_command) → close this tab on the keypress, without the confirm (the process has
  /// already exited). Only run tabs wire `onCloseRequested`. Shared by `addRunTab` (append + focus) and
  /// `respawnRunTab` (in-place restart, issue #40).
  private func makeRunTab(for target: TerminalTarget, command: String, cwd: String) -> TerminalTab {
    let tab = makeTerminalTab(for: target, cwd: cwd, command: command, title: "Run")
    let targetID = target.id
    let tabID = tab.id
    tab.surface?.onCloseRequested = { [weak self] in
      guard let self, let target = self.target(forID: targetID) else { return }
      self.closeTab(tabID, for: target)
    }
    return tab
  }

  /// Split the focused pane by spawning a new terminal on the trailing side (⌘D right, ⇧⌘D down).
  func splitFocusedPane(for target: TerminalTarget, orientation: SplitOrientation) {
    splitFocusedPane(for: target, edge: orientation == .horizontal ? .right : .bottom)
  }

  /// Split the focused pane on `edge` (right/left/down/up). A focused **terminal** spawns a new shell
  /// inheriting its working directory; a focused **diff** opens a second view of the SAME diff as a
  /// fresh *preview* pane (#72) — the original stays pinned, the new pane is the browsable preview
  /// slot. No-op (refused) if the focused pane is already too small to halve (D4). If the focused tab
  /// is solo, this seeds a NEW group — every other group is left exactly as it was.
  func splitFocusedPane(for target: TerminalTarget, edge: PaneEdge) {
    guard let focused = focusedTab(for: target) else { return }
    guard fits(splitting: focused, orientation: edge.orientation, for: target) else { return }

    let newTab = newPaneTab(splitting: focused, for: target)
    tabsByTarget[target.id, default: [:]][newTab.id] = newTab

    let groupIndex = splitIndex(containing: focused.id, for: target.id)
    if let groupIndex {
      // Grow the focused pane's own group beside it, on the requested side. Always an add, so it
      // always evens (issue #126) — every caller of this function is a split command.
      setSplit(
        splitsByTarget[target.id]![groupIndex].inserting(
          newTab.id, beside: focused.id, orientation: edge.orientation,
          newLeafFirst: edge.placesDroppedFirst, ratio: 0.5),
        groupAt: groupIndex, for: target.id, evening: true)
    } else {
      // Seed a NEW group from the focused solo tab. `groupAt: nil` appends, so the other groups stay
      // exactly as they are — this is the whole difference from the old single-layout model.
      let new = PaneLayout.leaf(newTab.id)
      let anchor = PaneLayout.leaf(focused.id)
      setSplit(
        .split(
          id: UUID(), orientation: edge.orientation, ratio: 0.5,
          first: edge.placesDroppedFirst ? new : anchor,
          second: edge.placesDroppedFirst ? anchor : new),
        groupAt: nil, for: target.id, evening: true)
    }
    // Place the new tab right after the focused one in the loose order (display normalises anyway).
    insertID(newTab.id, after: focused.id, for: target)
    setFocused(newTab.id, for: target.id)
    reconcileOcclusion(for: target)
  }

  /// The tab to spawn when splitting `anchor`. A **terminal** anchor → a new shell in its cwd. A
  /// **diff** anchor → a second view of the same file as a fresh PREVIEW pane (#72): the anchor is
  /// persisted so the original stays pinned (review D6), and any other preview is persisted too, so the
  /// new pane becomes the target's sole preview slot (the ≤1-preview invariant) — a later Changes-panel
  /// single-click then retargets THIS new split pane rather than the pinned original. Built directly
  /// (not via `openDiffPreview`) so the same-file dedup doesn't collapse it back onto the anchor.
  private func newPaneTab(splitting anchor: TerminalTab, for target: TerminalTarget) -> TerminalTab
  {
    if case .diff(var desc) = anchor.content {
      persist(anchor.id, for: target)  // pin the original
      if let other = previewTabID(in: target.id) { persist(other, for: target) }  // keep ≤1 preview
      desc.isPreview = true
      return TerminalTab.diff(desc)
    }
    // A changeset anchor mirrors the diff case: a second view of the same commit as a fresh preview
    // pane, the original pinned and any other preview persisted (≤1-preview invariant).
    if case .changeset(var desc) = anchor.content {
      persist(anchor.id, for: target)
      if let other = previewTabID(in: target.id) { persist(other, for: target) }
      desc.isPreview = true
      return TerminalTab.changeset(desc)
    }
    let cwd = anchor.surface?.lastKnownCwd ?? target.path
    return makeTerminalTab(for: target, cwd: cwd)
  }

  /// Split a *specific* tab — the tab toolbar's "Split right" and the chip context menu's split items
  /// (issue #72) — as opposed to `splitFocusedPane`, which always acts on the focused pane. Uses
  /// `select`, not `focus` (review D2), so a deliberate right-click/toolbar action also promotes this
  /// workroom to the focused member of a workroom split (#23); then splits the now-focused anchor (a
  /// diff anchor splits into a second diff pane, a terminal into a new shell — see `newPaneTab`).
  func splitTab(_ tabID: TerminalTab.ID, on edge: PaneEdge, for target: TerminalTarget) {
    guard let tab = tabsByTarget[target.id]?[tabID] else { return }
    // Check the fit BEFORE `select`, not after. `splitFocusedPane` refuses silently when the pane is
    // too small to halve, and `select` has already moved the focused tab and promoted this workroom
    // to the focused split member by then — so a refused split still visibly changed the selection,
    // with nothing to explain why. The anchor `splitFocusedPane` would evaluate is this same tab.
    guard fits(splitting: tab, orientation: edge.orientation, for: target) else { return }
    select(tabID, for: target)
    splitFocusedPane(for: target, edge: edge)
  }

  /// Drag-and-drop (issue #3): place `movedID` on `edge` of `destID`'s pane. One op covers both
  /// dragging a tab from the strip into a pane AND rearranging an existing pane, since panes are tabs.
  /// Two solo tabs dropped together seed a NEW group; every other group survives untouched.
  /// No-op if either tab is missing or `movedID == destID`.
  func moveTabIntoSplit(
    _ movedID: TerminalTab.ID, ontoEdge edge: PaneEdge, of destID: TerminalTab.ID,
    for target: TerminalTarget
  ) {
    guard movedID != destID, tabsByTarget[target.id]?[movedID] != nil,
      let dest = tabsByTarget[target.id]?[destID]
    else { return }
    // Same floor ⌘D obeys. Without this the two paths disagree by the whole floor: ⌘D refuses to
    // halve a pane under `minPaneWidth`, while dragging a chip onto that same pane's edge split it
    // anyway. Rearranging *within* an existing split is exempt — the pane count doesn't change, so
    // nothing new has to fit; only a drop that adds a member to this pane is measured.
    let fromIndex = splitIndex(containing: movedID, for: target.id)
    let destIndex = splitIndex(containing: destID, for: target.id)
    // An addition is a move ACROSS groups (or in from solo); two members of one group swapping places
    // leaves the pane count — and so the pane sizes — unchanged.
    let addsAMember = fromIndex == nil || fromIndex != destIndex
    if addsAMember, !fits(splitting: dest, orientation: edge.orientation, for: target) { return }

    // Detach first, insert second — and re-resolve the destination's group AFTER the detach, because
    // removing the last-but-one member deletes a group and shifts every later index. `evening` is
    // `addsAMember` on BOTH halves: a genuine move evens the group left behind and the one joined,
    // while a rearrange within one group skips evening and so keeps every ANCESTOR ratio the user
    // dragged. Not every ratio — `removingLeaf` collapses the moved leaf's immediate parent and
    // `inserting` rebuilds it at 0.5, so that one divider resets (and a two-pane group, which falls
    // below two leaves and is deleted, resets entirely). That is master's behaviour too, unchanged.
    removeFromGroup(movedID, for: target.id, evening: addsAMember)
    let index = splitIndex(containing: destID, for: target.id)
    let base = index.map { splitsByTarget[target.id]![$0] } ?? .leaf(destID)
    setSplit(
      base.inserting(
        movedID, beside: destID, orientation: edge.orientation,
        newLeafFirst: edge.placesDroppedFirst, ratio: 0.5),
      groupAt: index, for: target.id, evening: addsAMember)
    insertID(movedID, after: destID, for: target)  // display normalises the contiguous run
    setFocused(movedID, for: target.id)
    reconcileOcclusion(for: target)
  }

  /// Move a pane into its own window (issue #172). One coordinated transition: the model half here,
  /// the window half through `onPaneDetached`, so the two can never be observed apart.
  ///
  /// The model half MIRRORS `extractFromSplit` (it does not call it) — a detached tab must not remain
  /// a split member, or the layout would still try to render it. It is a mirror rather than a reuse
  /// because `extractFromSplit` focuses the tab it pulls out, which is the one thing detaching must
  /// NOT do: the focus has to go to a survivor. The successor is therefore computed BEFORE the
  /// mutation, the same ordering `closeTab` uses, because `closeSuccessor` reads the on-screen order.
  ///
  /// A preview tab is pinned on the way out: `previewTabID` scans the unfiltered `tabsByTarget`, so
  /// the next Changes/Files click would otherwise replace this pane's content in place and the
  /// popped-out window would silently become a different file.
  func detachPane(_ tabID: TerminalTab.ID, for target: TerminalTarget, at screenPoint: CGPoint) {
    guard let tab = tabsByTarget[target.id]?[tabID], !detachedTabIDs.contains(tabID) else { return }
    let wasFocused = focusedTabByTarget[target.id] == tabID
    let successor = closeSuccessor(of: tabID, for: target)
    if tab.isPreview { persist(tabID, for: target) }
    removeFromGroup(tabID, for: target.id, evening: true)
    detachedTabIDs.insert(tabID)
    if wasFocused { setFocused(successor, for: target.id) }
    reconcileOcclusion(for: target)
    onPaneDetached?(target.id, tabID, screenPoint)
  }

  /// Bring a detached pane back into the pane tree (issue #172) — the mirror of `detachPane`, and the
  /// only way a tab leaves `detachedTabIDs` while staying alive.
  ///
  /// It returns as the focused solo tab in its old strip position. There is deliberately no
  /// land-on-an-edge variant: docking is a button in the detached window's title bar, so there is no
  /// drop point to interpret. Re-splitting afterwards is the normal split gesture.
  func dockPane(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard undetach(tabID) else { return }
    focus(tabID, for: target)
    reconcileOcclusion(for: target)
  }

  /// Drop a tab's detached membership and tell `AppStore` to close its window. Returns whether the
  /// tab actually was detached, so callers can skip the rest of a dock. The single un-detach point:
  /// `dockPane` uses it, and so do `closeTab`/`reap`, which is what stops a detached window ever
  /// outliving its tab.
  @discardableResult
  private func undetach(_ tabID: TerminalTab.ID) -> Bool {
    guard detachedTabIDs.remove(tabID) != nil else { return false }
    onPaneDocked?(tabID)
    return true
  }

  /// Pull a tab out of its group so it's a solo terminal again (drag a chip clear of the group). The
  /// group dissolves if only one member would remain. No-op if the tab isn't in a group.
  func extractFromSplit(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard splitIndex(containing: tabID, for: target.id) != nil else { return }
    // A removal: the survivors keep ratios budgeted for the pane that just left, so even them.
    removeFromGroup(tabID, for: target.id, evening: true)
    setFocused(tabID, for: target.id)  // show the extracted tab on its own
    reconcileOcclusion(for: target)
  }

  /// Focus a tab (and, if it's a split member, show the split). Single entry point: chip tap, ⌘1–9,
  /// notification routing, neighbour-after-close. `select` is an alias kept for existing call sites.
  func focus(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard tabsByTarget[target.id]?[tabID] != nil else { return }
    guard focusedTabByTarget[target.id] != tabID else { return }
    setFocused(tabID, for: target.id)
    reconcileOcclusion(for: target)
  }

  /// A *deliberate* tab selection (chip tap, ⌘1–9, next/prev) — `focus` plus a request for the owning
  /// workroom to become the focused split member (via `onSurfaceFocused`). Selecting a tab in a
  /// co-displayed but non-focused workroom must move keyboard focus there, mirroring a click into that
  /// pane's body — without this the chip highlights but the terminal never focuses (the renderer keeps
  /// `surfaceActive` false until the workroom is the selected member). Fired *before* `focus` so the
  /// promotion lands even when the tab is already this target's focused tab (where `focus` early-returns)
  /// and so the focus-change history records against the now-correct workroom. A no-op outside a split
  /// or when this target is already the focused member (the store-side guard handles both).
  func select(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    onSurfaceFocused?(target.id)
    focus(tabID, for: target)
  }

  /// The single write-point for a target's focused tab (issue #26). Centralising the seven former
  /// direct writes means every focus change — `addTab`, splits, drag-into-split, `focus`, and the
  /// close-successor — fires `onFocusChange` so navigation history can record the new location.
  /// `notify: false` is used by `reap` (the target is being torn down; nothing is focused afterward,
  /// and its history entries are skipped at replay instead) and by `restore` (materialising saved
  /// panes is not a navigation). No-op when unchanged.
  ///
  /// Also the recency write-point (issue #132): quick-switcher MRU order and the close-successor
  /// (issue #160) are the same question — "where was the user last" — so both read one list, written
  /// here rather than from the `onFocusChange` observer, which would leave this file's own
  /// close-successor depending on `AppStore` having wired it up.
  ///
  /// Both writes sit under `notify`, which is what keeps them meaning "the user went here". `reap`
  /// and `restore` are the two callers that pass `notify: false`, and a restore is eager across
  /// every saved target at launch — recording those would push a pane the user has never touched to
  /// the head of the app-wide MRU, retargeting the first ⌃Tab and the first close of the session.
  private func setFocused(
    _ tabID: TerminalTab.ID?, for targetID: TerminalTarget.ID, notify: Bool = true
  ) {
    // A DETACHED pane may never become this target's focused tab (issue #172). This is the single
    // focus write-point, and every route into it clears `focus`'s only check (the tab still exists in
    // `tabsByTarget`), which a detached tab does. Letting the write through makes `contentLayout`
    // render `.leaf(detached)` back in this window, and `TerminalContainerView.mount` then re-homes
    // the libghostty view out of the detached window — which goes blank. At least six paths reach
    // here: the surface's own `mouseDown` → `onFocused` → `select`, `ActivateOnPress` on a content
    // pane, navigation history back/forward, notification routing via `ownerOf(tabID:)`, ⌃Tab's pane
    // switcher, and Files/Changes re-focusing an existing preview tab. Guarding the write-point
    // covers all of them at once; raising the pane's own window is the useful thing to do instead.
    if let tabID, detachedTabIDs.contains(tabID) {
      onPaneRaiseRequested?(tabID)
      return
    }
    guard focusedTabByTarget[targetID] != tabID else { return }
    focusedTabByTarget[targetID] = tabID
    guard notify else { return }
    recency.recordPane(tabID)
    onFocusChange?(targetID, tabID)
  }

  /// Move focus to the adjacent pane in `direction` within the visible split (⌃⌘arrows, issue #3).
  /// Returns whether focus actually moved, so the key monitor only swallows the event when it acts.
  @discardableResult
  func focusAdjacentPane(_ direction: PaneDirection, for target: TerminalTarget) -> Bool {
    guard let split = split(for: target), let focused = focusedTabByTarget[target.id],
      let next = PaneTreeLayout.adjacentPane(to: focused, direction: direction, in: split)
    else { return false }
    focus(next, for: target)
    return true
  }

  /// Reorder (drag-and-drop in the tab bar): move the dragged tab to `index` in the loose strip order,
  /// clamped to bounds. Display normalisation keeps the split's run contiguous regardless.
  func moveTab(_ draggedID: TerminalTab.ID, toIndex index: Int, for target: TerminalTarget) {
    guard var order = orderByTarget[target.id],
      let from = order.firstIndex(of: draggedID)
    else { return }
    order.remove(at: from)
    order.insert(draggedID, at: max(0, min(index, order.count)))
    orderByTarget[target.id] = order
  }

  /// Set the divider ratio of one split node (the view clamps to the points-based minimum first).
  /// Addressed by the node's own id, so it finds the right group without the caller knowing which.
  func setRatio(_ ratio: CGFloat, forSplit splitID: UUID, for target: TerminalTarget) {
    guard let index = splitsByTarget[target.id]?.firstIndex(where: { $0.containsSplit(splitID) })
    else { return }
    splitsByTarget[target.id]![index] = splitsByTarget[target.id]![index].settingRatio(
      ratio, forSplit: splitID)
  }

  /// Rebalance the VISIBLE group so every pane renders the same size (issue #83 "Resize Splits
  /// Evenly"). No-op when the focused tab is solo — the menu item acts on what is on screen, and an
  /// off-screen group keeps the dividers the user left it with.
  func equalizeSplit(for target: TerminalTarget) {
    guard let focused = focusedTabByTarget[target.id],
      let index = splitIndex(containing: focused, for: target.id)
    else { return }
    splitsByTarget[target.id]![index] = splitsByTarget[target.id]![index].equalized()
  }

  /// Close a tab. If it's a split member the split collapses to the surviving sibling subtree (and
  /// dissolves when only one member would remain). Closing the last tab leaves the target with none.
  func closeTab(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard let tab = tabsByTarget[target.id]?[tabID] else { return }
    let wasFocused = focusedTabByTarget[target.id] == tabID

    // Compute the focus successor BEFORE mutating, using the on-screen order.
    let successor = closeSuccessor(of: tabID, for: target)

    // Close the detached window first, so it can never outlive the tab it hosts (issue #172).
    undetach(tabID)
    pendingCloseKills.append(Task { await self.endPersistentSession(for: tab) })
    teardown(tab)
    tabsByTarget[target.id]?[tabID] = nil
    orderByTarget[target.id]?.removeAll { $0 == tabID }
    activityPulses[tabID] = nil

    // A lone remaining member is not a group any more; two or more get evened, since their dividers
    // still budget space for the pane that just closed (issue #126).
    removeFromGroup(tabID, for: target.id, evening: true)

    if wasFocused { setFocused(successor, for: target.id) }
    recency.forgetPanes([tabID])  // after the successor is picked, before anyone else looks
    reconcileOcclusion(for: target)
    agentManager.tabClosed(tabID)
    onTabsRemoved?(target.id, [tabID])
  }

  /// Terminate and forget every terminal for a target (on delete / when its directory disappears).
  ///
  /// Awaits every persisted session's kill before returning — the caller relies on this to delete
  /// the workroom's directory only after any daemon-held shell has actually exited (issue #7).
  func reap(_ id: TerminalTarget.ID) async {
    let removedIDs = Array((tabsByTarget[id] ?? [:]).keys)
    for removed in removedIDs { undetach(removed) }  // no detached window outlives its tab (#172)
    for tab in (tabsByTarget[id] ?? [:]).values {
      await endPersistentSession(for: tab)
      teardown(tab)
      activityPulses[tab.id] = nil
    }
    await PersistentSessionService.shared.endSessions(matchingWorkroom: id)
    tabsByTarget[id] = nil
    orderByTarget[id] = nil
    splitsByTarget[id] = nil
    setFocused(nil, for: id, notify: false)
    recency.forgetPanes(removedIDs)
    counts[id] = nil
    for removed in removedIDs {
      agentManager.tabClosed(removed)
    }
    if !removedIDs.isEmpty { onTabsRemoved?(id, removedIDs) }
  }

  func reapAll() async {
    for id in Array(tabsByTarget.keys) { await reap(id) }
  }

  /// Re-theme every live terminal — visible and hidden, solo and split alike — to the active theme
  /// for the current appearance. The terminal step of `ThemeService.applyActiveTheme()`. `force`
  /// rebuilds the config even when the appearance is unchanged (a same-appearance theme switch).
  func applyThemeToAll(force: Bool = false) {
    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    GhosttyApp.shared.reloadConfig(force: force)
    GhosttyApp.shared.setColorScheme(dark: isDark)
    let config = GhosttyApp.shared.config
    for tabs in tabsByTarget.values {
      for tab in tabs.values {
        // Content tabs have no surface to re-theme.
        guard let surface = tab.surface else { continue }
        if let config { surface.updateConfig(config) }
        surface.applyColorScheme(isDark: isDark)
      }
    }
  }

  // MARK: Occlusion (A4 / issue #3)

  /// One reconciliation pass: exactly the on-screen tabs render; every other surface for the target is
  /// paused (its shell keeps running — `setVisible(false)` toggles GPU occlusion, not the PTY). Called
  /// from every state change that can alter what's on screen (focus / split / close / move / reap).
  func reconcileOcclusion(for target: TerminalTarget) {
    let visible = Set(visibleTabIDs(for: target))
    for tab in (tabsByTarget[target.id] ?? [:]).values {
      // Only terminal tabs own a GPU surface to occlude; a content tab (diff) pauses itself by
      // unmounting from the window when it leaves the screen, so there's nothing to toggle here.
      tab.surface?.setVisible(visible.contains(tab.id))
    }
  }

  /// Flash a visible non-focused pane's border to acknowledge activity without a banner/badge (D3).
  /// Driven from `AppStore.handleActivity`.
  func pulsePaneActivity(_ tabID: TerminalTab.ID) {
    activityPulses[tabID, default: 0] += 1
  }

  // MARK: Live titles (issue #2)

  /// Show a surface-reported command title on its tab; directory/prompt titles are ignored so the
  /// command sticks until `command_finished` clears it.
  private func updateTitle(_ title: String, forTab tabID: TerminalTab.ID, target: TerminalTarget.ID)
  {
    guard let tab = tabsByTarget[target]?[tabID], case .terminal(let s) = tab.content else {
      return
    }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !Self.isDirectoryTitle(trimmed, cwd: s.view.lastKnownCwd) else {
      return
    }
    // Read once — `foregroundTool` used to re-derive this internally via a second live PID read, a
    // TOCTOU gap where the foreground process could differ between the two reads (review finding).
    let foregroundExecutableName = s.view.foregroundExecutableName
    let detectedAgent =
      s.view.foregroundAgentBackend ?? AgentTitleRecognition.backend(for: trimmed)
    let detectedTool =
      ToolLogoRegistry.tool(forExecutableName: foregroundExecutableName)
      ?? ToolLogoRegistry.tool(forTitle: trimmed)
    guard
      s.liveTitle != trimmed || (s.activeAgentBackend == nil && detectedAgent != nil)
        || (s.activeTool == nil && detectedTool != nil)
    else {
      return
    }
    // Usage tracking for issue #141: a genuinely new foreground command that ISN'T in the curated
    // registry at all (not merely missing its fetched asset — `matchingEntry` is the ungated check)
    // gets tallied, so a periodic look at the file shows which non-curated tools are worth adding
    // next. Gated on `s.liveTitle != trimmed` (a real title change, not a repaint of the same still-
    // unrecognized command) so a long-running unmatched program is counted once, not per repaint.
    if s.liveTitle != trimmed, detectedTool == nil,
      let rawName = foregroundExecutableName,
      ToolLogoRegistry.matchingEntry(forExecutableName: rawName) == nil
    {
      recordUnrecognizedTool(rawName)
    }
    mutateTerminalState(tabID, target: target) {
      $0.liveTitle = trimmed
      if $0.activeAgentBackend == nil { $0.activeAgentBackend = detectedAgent }
      if $0.activeTool == nil { $0.activeTool = detectedTool }
    }
  }

  /// Mirror the surface's reported cwd into observable tab state so the status bar tracks it live
  /// (issue #49).
  private func updateCwd(_ cwd: String, forTab tabID: TerminalTab.ID, target: TerminalTarget.ID) {
    guard let tab = tabsByTarget[target]?[tabID], case .terminal(let s) = tab.content,
      s.cwd != cwd
    else { return }
    mutateTerminalState(tabID, target: target) { $0.cwd = cwd }
  }

  /// Mutate the `.terminal` payload of a tab in place and republish (the `@Published`-driving
  /// reassign). A no-op if the tab is missing or isn't a terminal — so the OSC callbacks (only ever
  /// wired for terminal tabs) stay correct even if a content tab id is ever passed.
  private func mutateTerminalState(
    _ tabID: TerminalTab.ID, target: TerminalTarget.ID, _ body: (inout TerminalState) -> Void
  ) {
    guard var tab = tabsByTarget[target]?[tabID], case .terminal(var s) = tab.content else {
      return
    }
    body(&s)
    tab.content = .terminal(s)
    tabsByTarget[target]?[tabID] = tab
  }

  /// The shell returned to its prompt (OSC 133 D): drop the finished command's title back to the default
  /// (issue #2) and clear any OSC 9;4 progress, so the indicator stops the moment the command exits.
  private func handleCommandFinished(
    forTab tabID: TerminalTab.ID, target: TerminalTarget.ID, exitCode: Int32? = nil
  ) {
    notifyAgentOfCommandFinish(tabID: tabID, target: target, exitCode: exitCode)
    guard let tab = tabsByTarget[target]?[tabID], case .terminal(let s) = tab.content,
      s.liveTitle != nil || s.progressActive != nil
    else { return }
    mutateTerminalState(tabID, target: target) {
      $0.liveTitle = nil
      $0.activeAgentBackend = nil
      $0.activeTool = nil
      $0.progressActive = nil
    }
  }

  /// Build the failed-command context from the surface and hand it to the inline agent (issue #49).
  /// Captures synchronously — we're in the runtime callback before the next prompt renders, so
  /// `readCommandRegion()` returns the just-finished command's output (the A4 race fix, Swift-side).
  /// Gated on the feature flag so the screen read never runs when the agent is off.
  private func notifyAgentOfCommandFinish(
    tabID: TerminalTab.ID, target: TerminalTarget.ID, exitCode: Int32?
  ) {
    guard agentManager.isEnabled,
      let tab = tabsByTarget[target]?[tabID], case .terminal(let s) = tab.content
    else { return }
    guard let exitCode else {
      agentManager.commandFinished(tab: tabID, target: target, failure: nil)
      return
    }
    let view = s.view
    let failure = FailedCommand(
      command: s.liveTitle,
      cwd: view.lastKnownCwd,
      exitCode: exitCode,
      shell: (ShellEnvironment.loginShell() as NSString).lastPathComponent,
      output: view.readCommandRegion() ?? "",
      isRunTab: view.isRunCommandSurface,
      isRemote: false)
    agentManager.commandFinished(tab: tabID, target: target, failure: failure)
  }

  /// Apply an OSC 9;4 progress report (issue #28 follow-up). `active` is false only for the REMOVE state
  /// (the program declared itself idle/done) and true for any live progress (SET / INDETERMINATE / PAUSE
  /// / ERROR). This is the sole driver of `isRunning` — the spinner follows the program's own signal.
  private func updateProgress(
    _ active: Bool, forTab tabID: TerminalTab.ID, target: TerminalTarget.ID
  ) {
    guard let tab = tabsByTarget[target]?[tabID], case .terminal(let s) = tab.content,
      s.progressActive != active
    else { return }
    mutateTerminalState(tabID, target: target) { $0.progressActive = active }
  }

  /// `NSHomeDirectory()` resolved once per process. It used to be `isDirectoryTitle`'s default
  /// argument, so it re-ran on every terminal title change, allocating through
  /// `NSHomeDirectoryForUser` → `-[NSURL path]` → `CFURLCopyFileSystemPath`. A process's home
  /// directory cannot change while it runs, so resolving it per title is waste.
  ///
  /// **Unmeasured.** WORKROOM-3P sampled the main thread here, which is how the call site was
  /// found, but one sample is not evidence this is hot — that is the whole point of
  /// `SentryConfig.appHangFingerprint`'s "the leaf is where the sample landed, not where the time
  /// went". This removes a per-title allocation; it does not explain 3P, and 3P stays open.
  static let cachedHomeDirectory = NSHomeDirectory()

  /// Whether `title` is just the working directory (the idle title the shell/prompt sets) rather than a
  /// running command — so the tab strip can ignore it (issue #2). Pure for testability.
  ///
  /// This MUST recognise every form a prompt emits for the cwd: a directory title that slips through is
  /// latched as a `liveTitle` and read as a running command (issue #28), but — being no real command — it
  /// never gets the `command_finished` that would clear it, so the sidebar spinner spins forever. The
  /// shipped zsh integration abbreviates deep paths (`%(4~|…/%3~|%~)` → "…/dir/dir/dir"), and bash's
  /// `PROMPT_DIRTRIM` truncates with ".../", so the full-path match alone isn't enough.
  static func isDirectoryTitle(_ title: String, cwd: String?, home: String = cachedHomeDirectory)
    -> Bool
  {
    guard let cwd, !cwd.isEmpty else { return false }
    var path = title
    if let colon = title.firstIndex(of: ":") {
      let prefix = title[..<colon]
      if prefix.contains("@"), !prefix.contains(" ") {
        path = String(title[title.index(after: colon)...])
      }
    }
    let tilde = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd

    // Full directory title (bash `\w`, zsh `%~` when the path is shallow enough to fit untruncated).
    if path == cwd || path == tilde { return true }

    // Truncated directory title: a shell abbreviates a deep path to an ellipsis marker plus a trailing
    // run of the path's own components (zsh "…/macapp/WorkroomApp", bash PROMPT_DIRTRIM ".../a/b"). It's
    // a directory title when, after the marker, it's a path-component suffix of the cwd (or its ~-form).
    for marker in ["…/", ".../"] where path.hasPrefix(marker) {
      let tail = path.dropFirst(marker.count)
      guard !tail.isEmpty else { return false }
      return cwd.hasSuffix("/" + tail) || tilde.hasSuffix("/" + tail)
    }
    return false
  }

  // MARK: Internals

  /// Whether `tab`'s pane can be halved along `orientation` without either side landing under the
  /// floor for that axis — `minPaneWidth` side-by-side, `minPaneHeight` stacked (D4).
  ///
  /// **Measures the laid-out PANE rect, for every content kind.** It used to prefer a terminal's own
  /// `GhosttySurfaceView.bounds` and fall back to `paneRects` only for content panes — which measured
  /// two different rectangles: a surface excludes the pane's chrome, a pane rect includes it. The gap
  /// was the chrome height (28pt for the status bar alone; 56pt once every pane also carries a title
  /// bar, issue #150), so a terminal and a diff pane of identical on-screen size disagreed about
  /// whether the same split fit. The floors are expressed in whole-pane points — `PaneTreeLayout`'s
  /// `canSplit` and the renderer's `lengths` clamp both work that way — so the pane rect is the
  /// measurement that agrees with what actually enforces them.
  ///
  /// The surface stays as the PRE-LAYOUT fallback: `paneRects` is empty until the renderer has laid
  /// the tree out once, and a live surface already knows its size by then.
  ///
  /// An unmeasured pane (no rect and no surface) still permits the split, and `PaneTreeLayout.canSplit`
  /// treats a zero rect the same way — the renderer's points-based clamp is the authority before first
  /// layout.
  private func fits(
    splitting tab: TerminalTab, orientation: SplitOrientation, for target: TerminalTarget
  ) -> Bool {
    // Group-aware once the renderer has measured the container (issue #126). With auto-even on,
    // adding a pane redistributes the WHOLE group instead of halving this one, so "can this pane be
    // halved" stops being the question — a pane dragged narrow would refuse ⌘D while the group has
    // ample room. Ask instead whether every pane of the tree we are about to store clears the
    // floors, using the same `evenedIfHonourable` step the mutation itself uses so the guard and the
    // commit can never disagree.
    if let space = paneSpace[target.id], space.width > 0, space.height > 0 {
      let base = split(containing: tab.id, for: target) ?? .leaf(tab.id)
      // The side the new leaf lands on mirrors the tree without changing any pane's size, so the
      // guard doesn't need the edge — only the axis and the resulting pane count.
      let prospective = base.inserting(
        UUID(), beside: tab.id, orientation: orientation, newLeafFirst: false, ratio: 0.5)
      let stored = PaneTreeLayout.evenedIfHonourable(
        prospective, in: space, enabled: autoEvenSplits())
      return PaneTreeLayout.fitsEveryPane(
        stored, in: space, notWorseThan: base, splitting: tab.id)
    }
    // Pre-layout fallback: the pane's own rect (or its surface), judged by the anchor-only rule.
    let rect =
      paneRects[target.id]?[tab.id]
      ?? tab.surface.map { CGRect(origin: .zero, size: $0.bounds.size) }
    guard let rect else { return true }
    return PaneTreeLayout.canSplit(rect, along: orientation)
  }

  /// Store `tree` as the target's group at `index` — replacing that group, or appending a NEW one
  /// when `index` is nil. A nil `tree`, or one that has fallen below two leaves, deletes the group
  /// instead. **Every other group is untouched**, which is the whole point of many groups: this is
  /// the single funnel every split mutation goes through, so "grouping these two leaves those alone"
  /// is enforced in one place rather than at each call site.
  ///
  /// Evens the tree first when this edit added or removed a pane and the container can honour
  /// equality (issue #126). The gate is INTENT, not a leaf-count delta: every caller already knows
  /// whether it is adding, removing, or merely rearranging, and a rearrange must keep the dividers
  /// the user dragged.
  private func setSplit(
    _ tree: TerminalPaneLayout?, groupAt index: Int?, for targetID: TerminalTarget.ID, evening: Bool
  ) {
    var groups = splitsByTarget[targetID] ?? []
    guard let tree, tree.tabIDs.count >= 2 else {
      if let index, groups.indices.contains(index) { groups.remove(at: index) }
      splitsByTarget[targetID] = groups.isEmpty ? nil : groups
      return
    }
    let stored =
      evening
      ? PaneTreeLayout.evenedIfHonourable(tree, in: paneSpace[targetID], enabled: autoEvenSplits())
      : tree
    // A nil index means "append a new group". A NON-nil index that no longer addresses anything means
    // a caller held one across a mutation — and appending there would silently seed a SECOND group
    // over leaves an existing one already owns, breaking disjointness quietly (first-group-wins in
    // `splitGroupIndices` plus `normalizedTabIDs`' `placed` guard would mask it into "a pane renders
    // in one place and brackets in another"). No caller can do this today; assert so a future one
    // fails loudly in debug rather than corrupting the model.
    assert(
      index == nil || groups.indices.contains(index!), "stale group index held across a mutation")
    if let index, groups.indices.contains(index) {
      groups[index] = stored
    } else {
      groups.append(stored)
    }
    splitsByTarget[targetID] = groups
  }

  /// Drop `tabID` from whatever group holds it, deleting the group when fewer than two leaves would
  /// remain. No-op when the tab is solo. The one removal path — close, detach, extract and the
  /// move-half of a drag all route through it, so "a leaving pane collapses its own group, and only
  /// its own" exists once.
  private func removeFromGroup(
    _ tabID: TerminalTab.ID, for targetID: TerminalTarget.ID, evening: Bool
  ) {
    guard let index = splitIndex(containing: tabID, for: targetID) else { return }
    setSplit(
      splitsByTarget[targetID]![index].removingLeaf(tabID), groupAt: index, for: targetID,
      evening: evening)
  }

  /// The tab to focus after `tabID` is closed: the most-recently-focused tab that is still open
  /// (issue #160 — closing lands you back where you were, matching what ⌃Tab calls "the last pane"),
  /// falling back to the on-screen neighbour that slides into the closed tab's slot for tabs recency
  /// has never seen (a restored session), else nil.
  ///
  /// When the closed tab was a split member, only the members that survive it are candidates —
  /// including the lone survivor of a two-pane split, which stops being a split at all. Focus drives
  /// what is on screen (`isSplitVisible`, `visibleTabIDs`), so landing on a most-recent tab from
  /// outside would sweep a pane the user was looking at a moment ago off screen.
  private func closeSuccessor(of tabID: TerminalTab.ID, for target: TerminalTarget) -> TerminalTab
    .ID?
  {
    let order = displayedTabIDs(for: target)
    let remaining = order.filter { $0 != tabID }
    guard !remaining.isEmpty else { return nil }
    let candidates = splitRemoving(tabID, for: target.id)?.tabIDs ?? remaining
    if let recent = recency.panes.ids.first(where: candidates.contains) { return recent }
    // Positional fallback, measured within the candidates (so a surviving split's neighbour is one of
    // its own members, not whatever sits after the run on screen).
    let slots = order.filter { $0 == tabID || candidates.contains($0) }
    guard let idx = slots.firstIndex(of: tabID) else { return candidates.first }
    let after = slots.filter { $0 != tabID }
    return after[min(idx, after.count - 1)]
  }

  /// `tabID`'s group with `tabID` removed, or nil when it wasn't grouped (or was its group's only
  /// leaf). Deliberately unfiltered on member count, unlike `removeFromGroup`, which drops a group
  /// that falls below two: `closeSuccessor` wants every survivor — the lone survivor of a two-pane
  /// group is exactly the pane that was on screen beside the one just closed.
  private func splitRemoving(_ tabID: TerminalTab.ID, for targetID: TerminalTarget.ID)
    -> TerminalPaneLayout?
  {
    guard let index = splitIndex(containing: tabID, for: targetID) else { return nil }
    return splitsByTarget[targetID]![index].removingLeaf(tabID)
  }

  private func insert(_ tab: TerminalTab, for target: TerminalTarget) {
    tabsByTarget[target.id, default: [:]][tab.id] = tab
    orderByTarget[target.id, default: []].append(tab.id)
  }

  private func insertID(
    _ id: TerminalTab.ID, after other: TerminalTab.ID, for target: TerminalTarget
  ) {
    var order = orderByTarget[target.id] ?? []
    order.removeAll { $0 == id }
    if let i = order.firstIndex(of: other) {
      order.insert(id, at: i + 1)
    } else {
      order.append(id)
    }
    orderByTarget[target.id] = order
  }

  private func makeTerminalTab(
    for target: TerminalTarget, cwd: String, command: String? = nil, title: String? = nil,
    sessionID: UUID? = nil
  ) -> TerminalTab {
    let count = (counts[target.id] ?? 0) + 1
    counts[target.id] = count
    let view = makeView(target, cwd, command)
    let assignedSessionID = assignedSessionID(persisted: sessionID, isRunCommand: command != nil)
    view.persistentSessionID = assignedSessionID
    view.sessionMetadata = [
      (SessionMetadataKey.project, projectPath(from: target.id) ?? target.path),
      (SessionMetadataKey.workroom, target.id),
      (SessionMetadataKey.title, title ?? "Terminal \(count)"),
    ]
    var tab = TerminalTab.terminal(view: view, defaultTitle: title ?? "Terminal \(count)")
    if case .terminal(var state) = tab.content {
      state.sessionID = assignedSessionID
      tab.content = .terminal(state)
    }

    let targetID = target.id
    let tabID = tab.id
    view.onActivity = { [weak self] activity in
      self?.activityHandler?(targetID, tabID, activity)
    }
    view.onTitleChange = { [weak self] title in
      self?.updateTitle(title, forTab: tabID, target: targetID)
    }
    view.onCwdChange = { [weak self] cwd in
      self?.updateCwd(cwd, forTab: tabID, target: targetID)
    }
    view.onCommandFinished = { [weak self] exitCode in
      // Exit code feeds the inline-agent manager (issue #49); the title-clear path (issue #2)
      // ignores it.
      self?.handleCommandFinished(forTab: tabID, target: targetID, exitCode: exitCode)
    }
    view.onProgressReport = { [weak self] active in
      self?.updateProgress(active, forTab: tabID, target: targetID)
    }
    // A pane became first responder (click / programmatic focus): make it the selection (issue #3),
    // and route up to the workroom selection so a click into a co-displayed split pane targets that
    // workroom (issue #23 follow-up).
    view.onFocused = { [weak self] in
      guard let self, let target = self.target(forID: targetID) else { return }
      self.focus(tabID, for: target)
      self.onSurfaceFocused?(targetID)
    }

    let projectPath = target.path
    view.onCmdClickFile = { [weak view] word in
      TerminalLinkOpener.handleCmdClickFile(word, cwd: view?.lastKnownCwd ?? projectPath)
    }
    view.resolveCmdHoverFile = { [weak view] word in
      TerminalLinkOpener.resolvesToFile(word, cwd: view?.lastKnownCwd ?? projectPath)
    }
    view.onOpenURL = { [weak view] url in
      TerminalLinkOpener.handleOpenURL(url, cwd: view?.lastKnownCwd ?? projectPath)
    }
    return tab
  }

  /// Reconstruct a minimal `TerminalTarget` from its id for the `onFocused` callback (which only
  /// carries ids). `focus` keys off the id alone, so a minimal target is sufficient.
  private func target(forID id: TerminalTarget.ID) -> TerminalTarget? {
    guard tabsByTarget[id] != nil else { return nil }
    return TerminalTarget(id: id, title: "", path: "", isMissing: false)
  }

  /// Tear down a tab's surface (clears callbacks before freeing, so no in-flight libghostty callback
  /// touches a dead view). A no-op for a content tab — it owns no surface, so there's nothing to free
  /// (and the refactor therefore frees *strictly fewer* surfaces than before — no new free races).
  private func teardown(_ tab: TerminalTab) { tab.surface?.tearDown() }

  func owner(of sessionID: UUID, in target: TerminalTarget) -> TerminalTab.ID? {
    (tabsByTarget[target.id] ?? [:]).first { _, tab in
      if case .terminal(let state) = tab.content { return state.sessionID == sessionID }
      return false
    }?.key
  }

  func replace(_ tab: TerminalTab, for target: TerminalTarget) {
    tabsByTarget[target.id]?[tab.id] = tab
  }

  func ownedSessionIDs(for target: TerminalTarget) -> Set<UUID> {
    Set(
      (tabsByTarget[target.id] ?? [:]).values.compactMap { tab in
        if case .terminal(let state) = tab.content { return state.sessionID }
        return nil
      })
  }

  /// Every session ID owned by an open tab across every target in this window.
  var allOwnedSessionIDs: Set<UUID> {
    Set(
      tabsByTarget.values.flatMap { $0.values }.compactMap { tab in
        if case .terminal(let state) = tab.content { return state.sessionID }
        return nil
      })
  }

  func materializeLivePersistentSessions(_ liveIDs: Set<UUID>) {
    for tabs in tabsByTarget.values {
      for tab in tabs.values {
        guard case .terminal(let state) = tab.content,
          let sessionID = state.sessionID,
          liveIDs.contains(sessionID)
        else { continue }
        state.view.ensureSurfaceCreated(initialSize: CGSize(width: 800, height: 480))
      }
    }
  }

  private func assignedSessionID(persisted: UUID?, isRunCommand: Bool) -> UUID? {
    let policy = TerminalPersistentSessionPolicy.usesPersistentSession(
      isAvailable: PersistentSessionService.shared.isAvailable,
      isRunCommand: isRunCommand)
    guard policy else { return nil }
    return persisted ?? UUID()
  }

  private func endPersistentSession(for tab: TerminalTab) async {
    guard case .terminal(let state) = tab.content, let sessionID = state.sessionID else { return }
    await PersistentSessionService.shared.endSession(sessionID: sessionID)
  }

  private func projectPath(from targetID: TerminalTarget.ID) -> String? {
    if targetID.hasPrefix("wr|") {
      let rest = targetID.dropFirst(3)
      if let sep = rest.lastIndex(of: "|") { return String(rest[..<sep]) }
    }
    if targetID.hasPrefix("root|") { return String(targetID.dropFirst(5)) }
    return nil
  }
}
