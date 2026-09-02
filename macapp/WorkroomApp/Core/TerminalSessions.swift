import AppKit
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
/// Split model (issue #3) is **single-layout**: per target there is at most ONE `PaneLayout` split (a
/// tree of ≥2 tab ids) plus solo tabs. The content area shows the split when the focused tab belongs to
/// it, otherwise the focused solo tab. The shared tab strip lists every tab; the split's members render
/// as a contiguous bracketed run, ordered by the split tree (`displayedTabIDs`). The whole layout —
/// tabs, order, split, focus — is captured to disk and rehydrated by `restore(_:for:)` (issue #46);
/// ordinary workroom shells reattach via `sessionID` when background sessions are on.
///
/// ```
///   STRIP:  A  [ B │ C ]  D        focused == C, C ∈ split  →  CONTENT renders the split.
///              └ bracket ┘         focused == A (solo)      →  CONTENT renders just A; split hidden.
/// ```
@MainActor
final class TerminalSessions: ObservableObject {
  /// Every tab for a target, by id — the single source of truth for surfaces/titles.
  @Published private var tabsByTarget: [TerminalTarget.ID: [TerminalTab.ID: TerminalTab]] = [:]
  /// The strip order (loose). The displayed order normalises this so the split's members are a
  /// contiguous run in split-tree order — see `displayedTabIDs`.
  @Published private var orderByTarget: [TerminalTarget.ID: [TerminalTab.ID]] = [:]
  /// The one split layout per target, if any (always ≥2 leaves; a lone tab is "no split").
  @Published private var splitByTarget: [TerminalTarget.ID: TerminalPaneLayout] = [:]
  /// The focused/selected tab per target. Selection = this tab (+ its split, if it's a member).
  @Published private var focusedTabByTarget: [TerminalTarget.ID: TerminalTab.ID] = [:]
  /// Bumped when a *visible but non-focused* pane reports activity (D3): the renderer flashes that
  /// pane's border instead of badging it (you can see it, so no banner/badge — just a glance cue).
  /// Keyed by tab id; the value is an opaque counter the leaf view watches for changes.
  @Published private(set) var activityPulses: [TerminalTab.ID: Int] = [:]
  /// Per-target running counter so tab titles ("Terminal 1", "2", …) stay stable across closes.
  private var counts: [TerminalTarget.ID: Int] = [:]
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
  /// Width and height need different floors because a pane's chrome is horizontal: the tab strip's own
  /// furniture is what sets the width floor, and it is wider than people guess. Measured on a real
  /// window: the *widest* toolbar a pane can show is a diff tab's (~145pt — the unified/side-by-side
  /// switch, Open File, split right, split down, close all), plus the pinned "+" (~28pt), the 8pt
  /// gutter, the 4pt leading inset, one ~100pt chip and the strip's 4pt trailing inset = ~293pt. Below
  /// that a pane cannot render the strip it must show, never mind its content — at the old 120pt floor
  /// a terminal tab left ~12pt for chips and a diff tab's toolbar alone overflowed the pane. The floor
  /// has to hold for whatever tab the pane switches to, so it is sized for the widest one.
  ///
  /// 300pt is also about 41 terminal columns, which is the first width where a terminal is honestly
  /// usable rather than merely non-degenerate.
  static let minPaneWidth: CGFloat = 300
  /// Smallest usable pane HEIGHT (points) — unchanged at 120, which is the tab strip plus roughly seven
  /// rows. Height has no equivalent of the strip's horizontal furniture, so it needs no larger floor.
  static let minPaneHeight: CGFloat = 120
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

  /// Tab ids in strip order: the loose order, with the split's members replaced by the split tree's
  /// order as a contiguous block at the earliest member's slot. So the bracket is always one run and
  /// strip order always matches pane order (rearranging panes IS strip reorder).
  func displayedTabIDs(for target: TerminalTarget) -> [TerminalTab.ID] {
    displayedTabIDs(forTargetID: target.id)
  }

  /// The id-addressed core of `displayedTabIDs(for:)`. Session capture (issue #46) walks
  /// `activeTargetIDs` and has no `TerminalTarget` value in hand, and only the id was ever used.
  func displayedTabIDs(forTargetID targetID: TerminalTarget.ID) -> [TerminalTab.ID] {
    let order = orderByTarget[targetID] ?? []
    guard let split = splitByTarget[targetID] else { return order }
    let members = split.tabIDs
    let memberSet = Set(members)
    guard let anchor = order.firstIndex(where: { memberSet.contains($0) }) else { return order }
    var result: [TerminalTab.ID] = []
    for (i, id) in order.enumerated() {
      if i == anchor { result.append(contentsOf: members) }
      if !memberSet.contains(id) { result.append(id) }
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
    let split: TerminalPaneLayout?
    let focused: TerminalTab.ID?
    /// The "Terminal N" counter, so the next ⌘T after a restore continues the numbering.
    let counter: Int
  }

  func sessionCapture(forTargetID targetID: TerminalTarget.ID) -> SessionCapture? {
    let dict = tabsByTarget[targetID] ?? [:]
    guard !dict.isEmpty else { return nil }
    let ordered = displayedTabIDs(forTargetID: targetID).compactMap { dict[$0] }
    guard !ordered.isEmpty else { return nil }
    return SessionCapture(
      tabs: ordered, split: splitByTarget[targetID], focused: focusedTabByTarget[targetID],
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

  /// The target's split layout, if a split currently exists.
  func split(for target: TerminalTarget) -> TerminalPaneLayout? { splitByTarget[target.id] }

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
  func isSplitVisible(for target: TerminalTarget) -> Bool {
    guard let split = splitByTarget[target.id], let focused = focusedTabByTarget[target.id] else {
      return false
    }
    return split.contains(focused)
  }

  /// The tab ids currently on screen: the split's members when the split is visible, else the focused
  /// solo tab. Drives occlusion.
  func visibleTabIDs(for target: TerminalTarget) -> [TerminalTab.ID] {
    if isSplitVisible(for: target), let split = splitByTarget[target.id] { return split.tabIDs }
    if let focused = focusedTab(for: target) { return [focused.id] }
    return []
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
    }

    guard !order.isEmpty else { return .nothing }

    tabsByTarget[target.id] = tabs
    orderByTarget[target.id] = order
    splitByTarget[target.id] = session.split.flatMap { saved in
      saved.materialize { idsByKey[$0] }
    }
    setFocused(
      session.focusedKey.flatMap { idsByKey[$0] } ?? order.first, for: target.id, notify: false)
    // `makeTerminalTab` bumps the counter per terminal it builds, so take whichever is higher: the
    // saved value keeps "Terminal 7" from becoming "Terminal 3" again after closes.
    counts[target.id] = max(session.terminalCounter ?? 0, counts[target.id] ?? 0)
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
    // Capture the old tab's place BEFORE closing it collapses the split / drops it from the order.
    let priorSplit = splitByTarget[target.id]
    let wasInSplit = priorSplit?.contains(oldID) ?? false
    let orderIndex = orderByTarget[target.id]?.firstIndex(of: oldID)

    closeTab(oldID, for: target)  // frees the port (SIGHUP); collapses the split — restored below

    let tab = makeRunTab(for: target, command: command, cwd: cwd)
    tabsByTarget[target.id, default: [:]][tab.id] = tab
    if let orderIndex {
      var order = orderByTarget[target.id] ?? []
      order.insert(tab.id, at: min(orderIndex, order.count))
      orderByTarget[target.id] = order
    } else {
      orderByTarget[target.id, default: []].append(tab.id)
    }
    // Re-derive the split from the pre-close tree with the new tab in the old leaf's slot — exact for
    // any depth (a 3-pane split keeps both siblings), unlike re-inserting beside a guessed neighbour.
    if wasInSplit, let priorSplit {
      splitByTarget[target.id] = priorSplit.replacingLeaf(oldID, with: tab.id)
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
  /// is solo, any existing split is dissolved first — at most one split exists at a time.
  func splitFocusedPane(for target: TerminalTarget, edge: PaneEdge) {
    guard let focused = focusedTab(for: target) else { return }
    guard fits(splitting: focused.surface, orientation: edge.orientation) else { return }

    let newTab = newPaneTab(splitting: focused, for: target)
    tabsByTarget[target.id, default: [:]][newTab.id] = newTab

    if let existing = splitByTarget[target.id], existing.contains(focused.id) {
      // Grow the existing split beside the focused leaf, on the requested side.
      splitByTarget[target.id] = existing.inserting(
        newTab.id, beside: focused.id, orientation: edge.orientation,
        newLeafFirst: edge.placesDroppedFirst, ratio: 0.5)
    } else {
      // Start a fresh split from the focused solo tab; dissolve any other split.
      let new = PaneLayout.leaf(newTab.id)
      let anchor = PaneLayout.leaf(focused.id)
      splitByTarget[target.id] = .split(
        id: UUID(), orientation: edge.orientation, ratio: 0.5,
        first: edge.placesDroppedFirst ? new : anchor,
        second: edge.placesDroppedFirst ? anchor : new)
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
    guard fits(splitting: tab.surface, orientation: edge.orientation) else { return }
    select(tabID, for: target)
    splitFocusedPane(for: target, edge: edge)
  }

  /// Drag-and-drop (issue #3): place `movedID` on `edge` of `destID`'s pane. One op covers both
  /// dragging a tab from the strip into a pane AND rearranging an existing pane, since panes are tabs.
  /// Maintains the single-split invariant (starting a split from two solo tabs dissolves any other).
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
    let addsAMember = !(splitByTarget[target.id]?.contains(movedID) ?? false)
    if addsAMember, !fits(splitting: dest.surface, orientation: edge.orientation) { return }

    // Base = the current split with `movedID` removed if it was in it; else the existing split when it
    // holds `destID`; else just the destination leaf (a fresh split, dissolving any unrelated one).
    let base: TerminalPaneLayout
    if let split = splitByTarget[target.id], split.contains(movedID) {
      base = split.removingLeaf(movedID) ?? .leaf(destID)
    } else if let split = splitByTarget[target.id], split.contains(destID) {
      base = split
    } else {
      base = .leaf(destID)
    }

    if base.contains(destID) {
      splitByTarget[target.id] = base.inserting(
        movedID, beside: destID, orientation: edge.orientation,
        newLeafFirst: edge.placesDroppedFirst, ratio: 0.5)
    } else {
      let dropped = PaneLayout.leaf(movedID)
      let anchor = PaneLayout.leaf(destID)
      splitByTarget[target.id] = .split(
        id: UUID(), orientation: edge.orientation, ratio: 0.5,
        first: edge.placesDroppedFirst ? dropped : anchor,
        second: edge.placesDroppedFirst ? anchor : dropped)
    }
    insertID(movedID, after: destID, for: target)  // display normalises the contiguous run
    setFocused(movedID, for: target.id)
    reconcileOcclusion(for: target)
  }

  /// Pull a tab out of the split so it's a solo terminal again (drag a chip clear of the group). The
  /// split dissolves if only one member would remain. No-op if the tab isn't in a split.
  func extractFromSplit(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard let split = splitByTarget[target.id], split.contains(tabID) else { return }
    if let collapsed = split.removingLeaf(tabID), collapsed.tabIDs.count >= 2 {
      splitByTarget[target.id] = collapsed
    } else {
      splitByTarget[target.id] = nil
    }
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
  /// `notify: false` is used only by `reap` (the target is being torn down; nothing is focused
  /// afterward, and its history entries are skipped at replay instead). No-op when unchanged.
  private func setFocused(
    _ tabID: TerminalTab.ID?, for targetID: TerminalTarget.ID, notify: Bool = true
  ) {
    guard focusedTabByTarget[targetID] != tabID else { return }
    focusedTabByTarget[targetID] = tabID
    if notify { onFocusChange?(targetID, tabID) }
  }

  /// Move focus to the adjacent pane in `direction` within the visible split (⌃⌘arrows, issue #3).
  /// Returns whether focus actually moved, so the key monitor only swallows the event when it acts.
  @discardableResult
  func focusAdjacentPane(_ direction: PaneDirection, for target: TerminalTarget) -> Bool {
    guard isSplitVisible(for: target), let split = splitByTarget[target.id],
      let focused = focusedTabByTarget[target.id],
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
  func setRatio(_ ratio: CGFloat, forSplit splitID: UUID, for target: TerminalTarget) {
    guard let split = splitByTarget[target.id] else { return }
    splitByTarget[target.id] = split.settingRatio(ratio, forSplit: splitID)
  }

  /// Rebalance the target's split so every pane renders the same size (issue #83 "Resize Splits
  /// Evenly"). No-op when the target has no split.
  func equalizeSplit(for target: TerminalTarget) {
    guard let split = splitByTarget[target.id] else { return }
    splitByTarget[target.id] = split.equalized()
  }

  /// Close a tab. If it's a split member the split collapses to the surviving sibling subtree (and
  /// dissolves when only one member would remain). Closing the last tab leaves the target with none.
  func closeTab(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard let tab = tabsByTarget[target.id]?[tabID] else { return }
    let wasFocused = focusedTabByTarget[target.id] == tabID

    // Compute the focus successor BEFORE mutating, using the on-screen order.
    let successor = closeSuccessor(of: tabID, for: target)

    pendingCloseKills.append(Task { await self.endPersistentSession(for: tab) })
    teardown(tab)
    tabsByTarget[target.id]?[tabID] = nil
    orderByTarget[target.id]?.removeAll { $0 == tabID }
    activityPulses[tabID] = nil

    if let split = splitByTarget[target.id], split.contains(tabID) {
      if let collapsed = split.removingLeaf(tabID), collapsed.tabIDs.count >= 2 {
        splitByTarget[target.id] = collapsed
      } else {
        splitByTarget[target.id] = nil  // dropped to a lone tab — no split anymore
      }
    }

    if wasFocused { setFocused(successor, for: target.id) }
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
    for tab in (tabsByTarget[id] ?? [:]).values {
      await endPersistentSession(for: tab)
      teardown(tab)
      activityPulses[tab.id] = nil
    }
    await PersistentSessionService.shared.endSessions(matchingWorkroom: id)
    tabsByTarget[id] = nil
    orderByTarget[id] = nil
    splitByTarget[id] = nil
    setFocused(nil, for: id, notify: false)
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

  /// Whether `title` is just the working directory (the idle title the shell/prompt sets) rather than a
  /// running command — so the tab strip can ignore it (issue #2). Pure for testability.
  ///
  /// This MUST recognise every form a prompt emits for the cwd: a directory title that slips through is
  /// latched as a `liveTitle` and read as a running command (issue #28), but — being no real command — it
  /// never gets the `command_finished` that would clear it, so the sidebar spinner spins forever. The
  /// shipped zsh integration abbreviates deep paths (`%(4~|…/%3~|%~)` → "…/dir/dir/dir"), and bash's
  /// `PROMPT_DIRTRIM` truncates with ".../", so the full-path match alone isn't enough.
  static func isDirectoryTitle(_ title: String, cwd: String?, home: String = NSHomeDirectory())
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

  /// Whether splitting `view` in `orientation` would leave both halves ≥ the floor for the axis being
  /// divided — `minPaneWidth` for a side-by-side split, `minPaneHeight` for a stacked one (D4). When the
  /// pane has no laid-out size yet (e.g. in tests, or before first layout) the guard can't evaluate, so
  /// it permits the split and lets the renderer's clamp handle sizing.
  private func fits(splitting surface: GhosttySurfaceView?, orientation: SplitOrientation) -> Bool {
    // A content pane (e.g. a diff) has no surface bounds to evaluate — permit the split and let the
    // renderer's points-based clamp size it, the same as a not-yet-laid-out terminal pane.
    guard let surface else { return true }
    let available = orientation == .horizontal ? surface.bounds.width : surface.bounds.height
    guard available > 0 else { return true }
    return (available - Self.dividerThickness) / 2 >= PaneTreeLayout.minPane(along: orientation)
  }

  /// The tab to focus after `tabID` is closed: the on-screen neighbour that slides into its slot, else
  /// the new last on-screen tab, else nil.
  private func closeSuccessor(of tabID: TerminalTab.ID, for target: TerminalTarget) -> TerminalTab
    .ID?
  {
    let order = displayedTabIDs(for: target)
    guard let idx = order.firstIndex(of: tabID) else { return order.first { $0 != tabID } }
    let remaining = order.filter { $0 != tabID }
    guard !remaining.isEmpty else { return nil }
    return remaining[min(idx, remaining.count - 1)]
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
