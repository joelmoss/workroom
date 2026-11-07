import AppKit
import Combine
import DaemonConnection
import Defaults
import HostDrivers
import TerminalModel
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import WorkroomWire
import os

/// The terminal split's concrete instantiation (issue #3): leaves are tab ids. Keeps terminal call
/// sites reading unchanged after the generic refactor (issue #23 needs `PaneLayout<SidebarID>`).
typealias TerminalPaneLayout = PaneLayout<TerminalTab.ID>

/// One tab in a target's strip. A tab is exactly one PANE: historically always a terminal surface,
/// and since issue #66 it can instead host non-terminal content (a file diff today; more kinds
/// later), so `content` is a `TabContent` union. With splits (issue #3) a tab is still exactly one
/// pane — a "split" composes several tabs into one on-screen layout (see `PaneLayout`), it does not
/// nest panes inside a tab. The split tree, focus, ⌘1–9, reorder, and close-successor all key on the
/// tab's `id`, so a content tab is a first-class peer of a terminal tab with no special casing — a
/// split can mix a terminal pane and a diff pane. Terminal-only state lives INSIDE the `.terminal`
/// payload, so a content tab carries none of it. `TerminalTab` stays a value type on purpose: a
/// live-title/progress/preview update mutates a copy and reassigns its record in the app's
/// `TerminalTabs`, which is what its observers see (a reference type would not). It holds no
/// view: a terminal tab's surface is kept beside its record, in `TerminalTabs`, and the window
/// holding it frees it in `teardown(_:)` (a no-op for content tabs — they have no surface).
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

  /// What the tab strip displays: a terminal's live/idle title, or a content tab's own title (a
  /// diff's filename). A view reads it through `TabTitleReader`, in a leaf, as a terminal's title
  /// changes many times a second.
  var title: String { content.title }

  /// The full repo-relative path of the file this tab shows (issue #136) — what the pane footer
  /// names, and the chip's tooltip. Nil for a terminal (its footer shows the cwd instead) and for a
  /// changeset (its in-pane `DiffViewer` header already carries the path).
  ///
  /// Deliberately adjacent to `title`: both read `d.path`/`f.path`, but `title` keeps only the
  /// `lastPathComponent`. That divergence IS issue #136 — two `user.rb` chips from different
  /// directories were indistinguishable — so the two answers stay in one screenful.
  var filePath: String? { content.filePath }

  /// A terminal tab's state; nil for a content tab.
  var terminal: TerminalState? {
    if case .terminal(let state) = content { return state }
    return nil
  }

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

  /// The one mark this tab's slot shows (#358). Always `.none` for content tabs.
  var indicator: PaneIndicator { terminal?.indicator ?? .none }

  /// What the program in this terminal last reported (#358), for tooltips and VoiceOver.
  var programStatus: ProgramStatusRollup? { terminal?.programStatus }

  /// Whether a command is actively *working* in this terminal (issue #28) — drives the chip underline
  /// and the sidebar spinner: OSC 9;4 progress, like Ghostty/Muxy, or a reporting program's own
  /// `working` (#358). Always false for content tabs.
  var isRunning: Bool {
    if case .running = indicator { return true }
    return false
  }

  /// Whether the program working in this terminal reported an error while still running (OSC 9;4
  /// ERROR): the busy indicators turn the failure colour rather than stopping.
  var isProgressFailed: Bool { indicator == .running(failed: true) }

  /// A program in this terminal is waiting on the user (#358).
  var needsAttention: Bool { indicator == .blocked }

  /// The curated CLI/TUI tool recognized as currently running in this terminal's foreground (issue
  /// #141) — a broader, data-driven sibling of `activeCodingAgentBackend`, latched/cleared identically.
  /// Always nil for content tabs.
  var recognizedTool: RecognizedTool? { terminal?.activeTool }

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

  /// A terminal's live/idle title, or a content tab's own (a diff's filename): `TerminalTab.title`.
  var title: String {
    switch self {
    case .terminal(let s): return s.liveTitle ?? s.defaultTitle
    case .diff(let d): return (d.path as NSString).lastPathComponent
    case .file(let f): return (f.path as NSString).lastPathComponent
    case .changeset(let c): return c.title
    }
  }

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
  /// `TerminalPanes.setContent`.
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
// projection living in `SavedLayout.swift` would compile fine while silently never persisting
// the new kind. The switch below is exhaustive on purpose — no `default` arm.
//
// The on-disk types stay separate from the runtime ones (no descriptor gains `Codable`) so the file
// format is never hostage to an internal field rename — see `SavedLayout.swift`.

extension TabSession {
  /// A tab as it will be written to disk, or `nil` when it must not be persisted.
  ///
  /// A tab whose command runs in its own process (an Investigate tab) returns nil: its process dies
  /// with the app. A run tab is kept (#522): its run session outlives the app, and restoring it
  /// reattaches to the run rather than starting it, so it is marked `run` and saved with its
  /// session. Identified by the tab's own launch (`TerminalLaunch.isSaved`), not by
  /// `RunCommandController.runStates`, so a tab whose run bookkeeping has already moved on is still
  /// saved as what it is.
  init?(key: String, tab: TerminalTab) {
    switch tab.content {
    case .terminal(let state):
      guard state.launch.isSaved else { return nil }
      self.init(
        key: key, kind: Self.terminalKind,
        // The LAST REPORTED cwd, which is the whole value of restoring a terminal: the shell's
        // latest report, written to the tab as the surface hears it (`updateCwd`).
        terminal: TerminalPayload(
          defaultTitle: state.defaultTitle, cwd: state.cwd,
          sessionID: state.sessionID?.uuidString,
          run: state.launch.isRunSession ? true : nil))
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
  /// only `TerminalPanes` can build it) and for anything unrecognised.
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

/// A terminal's live title, observed on its own. A spinner repaints the title ten times a second,
/// and republishing the whole tab map for each one re-ran every view that reads any terminal
/// state: 24% of a core on the main thread for one pane (Dev build, 2026-10-23). A view that
/// shows the title reads it through here and is the only thing that re-renders when it changes.
/// Not actor-isolated, as the struct holding it is not; it is read and written on the main thread
/// like the rest of `TerminalState`.
@Observable
final class LiveTitle {
  var text: String?
}

/// The state a terminal tab owns: what it was launched as, and the live title, cwd and progress its
/// surface reports. Kept in the `.terminal` payload so a content tab carries none of it. The surface
/// itself is not here (`SurfaceRegistry`): each fact a reader needs is stored here once, written
/// as the surface learns it, so no reader asks the view.
struct TerminalState {
  /// Daemon session this pane attaches to (separate from `tab.id`, which remints on restore). Set
  /// when the tab is made and when it is pointed at another session (`TerminalSessionAttachment`).
  /// The one copy: the surface's attach reads it (`PaneSessionAttachment.sessionID`).
  var sessionID: UUID?
  /// What the pane's process is (a shell, a command in its own process, or a run session), as its
  /// surface was told when the tab was made. Never changes.
  let launch: TerminalLaunch
  /// The directory the surface was made to start in, before any shell report: what the pane's
  /// branch is read from until `cwd` arrives.
  let launchDirectory: String
  /// Shown until the surface reports a title — and again whenever it reports an empty one.
  let defaultTitle: String
  /// The surface's latest non-empty title (OSC 0/2 via shell integration): the running command while
  /// busy, the working directory when idle. Nil until the first report (issue #2). Kept on an
  /// observable of its own (`titleCell`), so a program repainting its title re-renders the views
  /// showing that title and nothing else; see `LiveTitle`.
  var liveTitle: String? {
    get { titleCell.text }
    nonmutating set { titleCell.text = newValue }
  }
  let titleCell = LiveTitle()
  /// The agent identified from the PTY foreground process (or conservatively from shell title as a
  /// fallback for multiplexed sessions). Providers repaint OSC titles while they run, so this is
  /// deliberately latched until `command_finished` instead of being derived from `liveTitle`.
  var activeCodingAgentBackend: CodingAgentBackend?
  /// The running Claude's profile as workroomd reported it, read once when the agent starts in a
  /// daemon-backed pane and cleared with `activeCodingAgentBackend` (#480). Nil until read, and never
  /// read for a remote or fallback pane.
  var claudeProfile: PaneClaudeProfile?
  /// Reject recovery metadata if the command ended while the helper query was in flight.
  var commandFinishGeneration = 0
  /// The curated CLI/TUI tool recognized as currently running in this terminal's foreground (issue
  /// #141) — a broader, data-driven sibling of `activeCodingAgentBackend`, latched/cleared identically.
  var activeTool: RecognizedTool?
  /// The shell's latest reported cwd (`GHOSTTY_ACTION_PWD` via shell integration), written here by
  /// `updateCwd` in the same call that records it on the surface (`handlePwd` raises `.cwdChanged`
  /// synchronously), so the status bar shows the live directory (issue #49) and a saved layout
  /// keeps it. Nil until the shell first reports.
  var cwd: String?
  /// A remote pane's working directory ON ITS HOST (#239), from the host daemon's session list:
  /// libghostty drops an OSC 7 report whose host is not this Mac, so `cwd` never hears from a remote
  /// shell. Kept apart from `cwd` because this path names nothing on this Mac. The status bar shows
  /// and copies it, and nothing else reads it: not ⌘-click, not a new split, not the snapshot.
  var hostCwd: String?
  /// The git branch of this pane's own folder, for a pane whose target is no workroom (the Quick
  /// Terminal's): its panes can each be in a different repository, and no workroom cache knows
  /// them. Nil elsewhere, outside a repository and on a detached HEAD.
  var liveBranch: String?
  /// OSC 9;4 progress — the *only* signal that drives `isRunning`, matching how Ghostty and Muxy work
  /// (neither ties "busy" to the title). `true` while the running program reports it's working,
  /// `false`/`nil` when it's idle, done, or never reported any. Reset at `command_finished`; the
  /// surface also clears it via a 15s safety timer (issue #28 follow-up).
  var progressActive: Bool?
  /// The last progress report was ERROR. Only meaningful while `progressActive` is true.
  var progressFailed = false
  /// What the program in this terminal reports over OSC 7501 (#358), from the host's daemon. Nil
  /// when it reports nothing: no record left and no reporting run.
  var programStatus: ProgramStatusRollup?

  init(
    defaultTitle: String, launch: TerminalLaunch, launchDirectory: String, sessionID: UUID? = nil
  ) {
    self.defaultTitle = defaultTitle
    self.launch = launch
    self.launchDirectory = launchDirectory
    self.sessionID = sessionID
  }

  /// Precedence, one mark per slot: blocked > error > running > done > idle. A reporting program
  /// decides; otherwise OSC 9;4 does, and a `done` or `error` left from an earlier run only adds
  /// its mark, so it never hides the next command's progress. A failed shell command (#473) ranks
  /// below anything running: `claude` started after failing tests shows working, not failed.
  var indicator: PaneIndicator {
    let commandFailed = programStatus?.error?.exitCode != nil
    guard let status = programStatus, status.reporting else {
      let survivingError = programStatus?.error != nil
      if progressActive == true {
        return .running(failed: progressFailed || (survivingError && !commandFailed))
      }
      if survivingError { return .error }
      return programStatus?.done != nil ? .done : .none
    }
    if !status.blocked.isEmpty { return .blocked }
    if status.error != nil, !commandFailed { return .error }
    if status.working { return .running(failed: false) }
    if progressActive == true { return .running(failed: progressFailed) }
    if commandFailed { return .error }
    return status.done != nil ? .done : .none
  }
}

/// The mark a terminal's indicator slots show (#358).
enum PaneIndicator: Equatable {
  case none
  case running(failed: Bool)
  case done
  /// Failed and stopped: a program's own `error` report.
  case error
  /// Waiting on the user.
  case blocked
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
/// A+B). The rules are `PaneSplitGroups`', which `AppStore+WorkroomSplit` uses one level up too.
///
/// The shared tab strip lists every tab; each group's members render as a contiguous bracketed run,
/// ordered by its split tree (`displayedTabIDs`). The whole layout — tabs, order, splits, focus — is
/// captured to disk and rehydrated by `restore(_:for:)` (issue #46); ordinary workroom shells reattach
/// via `sessionID`.
///
/// ```
///   STRIP:  A  [ B │ C ]  D  [ E │ F ]    focused == C  →  CONTENT renders B│C.
///              └ bracket ┘     └ bracket ┘    focused == A  →  CONTENT renders just A; both groups persist.
/// ```
///
/// The tabs themselves are app-wide (`TerminalTabs`, ADR 0069): a window holds, per target, only
/// the layout of the tabs it shows (`TargetPanes`), so two windows can show one workroom with
/// tabs, splits and focus of their own (#444 Q12), and a move between windows hands over a layout,
/// never a tab. Everything this window reads of a tab it reads through its own layout, so it never
/// sees another window's.
///
/// Observed through Observation, per target and per tab: a view reads a target's layout through
/// its `TargetPanes` and each tab through its own record, so a change to one workroom's tabs
/// re-runs only the views that read that workroom, in this window or any other (plan step 3.5).
/// What views may observe here is the target dictionary, which changes only when a target is added
/// or removed, `activityPulses` and `detachedTabIDs`. Everything else is bookkeeping, measurement
/// or wiring, and is `@ObservationIgnored`, as it was never published.
@MainActor
@Observable
final class TerminalPanes {
  // The log category keeps the type's old name, so a log filter written for it still matches.
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "TerminalSessions")

  /// Each target's layout here: strip order, split groups, focus and "Terminal N" counter
  /// (`TargetPanes`, over a `PaneState`), over the ids of the tabs this window holds for it. The
  /// split groups are disjoint (a tab belongs to at most one) and each always ≥2 leaves — a lone
  /// tab is "no split" — and **their array order carries no meaning**: a group is addressed by
  /// membership, and the strip places each group's run at its earliest member's slot
  /// (`normalizedTabIDs`), so appending a rebuilt group is always safe. The rules are
  /// `PaneSplitGroups`', shared with the workroom split.
  ///
  /// The dictionary itself changes only when a target is added (its first tab, or the first
  /// terminal number it hands out) or removed (`reap`). A target whose tabs all closed or moved
  /// away keeps its entry, emptied, so `ensureTab` does not read it as never opened. Every change
  /// inside an entry sends `paneWillChange` first (`TargetPanes`), and so does every write here.
  private var targets: [TerminalTarget.ID: TargetPanes<TerminalTab.ID>] {
    get { panesByTarget }
    set {
      paneWillChange.send()
      panesByTarget = newValue
    }
  }
  private var panesByTarget: [TerminalTarget.ID: TargetPanes<TerminalTab.ID>] = [:]

  /// The app's tabs: their records and surfaces, by id. This window reaches a tab there only while
  /// its layout holds it (`record(_:in:)`, `surface(of:)`). Every window shares `.shared`, which is
  /// what lets a tab move between them by id.
  @ObservationIgnored private let tabRegistry = TerminalTabs.shared
  /// This window's name in `tabRegistry`: what each tab it holds is held by.
  @ObservationIgnored private let holder = UUID()

  /// Sent synchronously BEFORE every change to the panes: a tab's record or a target's arrangement
  /// (each `TargetPanes` is wired to it in `openPanes`), a target added or removed, an activity
  /// pulse, a pane detached or docked. The saved layout's dirty mark hangs off it, and so does
  /// the window list's coding-agent count. It fires before the change lands, so a subscriber
  /// that wants the new state schedules its read rather than taking it inline.
  let paneWillChange = PassthroughSubject<Void, Never>()

  /// Bumped when a *visible but non-focused* pane reports activity (D3): the renderer flashes that
  /// pane's border instead of badging it (you can see it, so no banner/badge — just a glance cue).
  /// Keyed by tab id; the value is an opaque counter the leaf view watches for changes.
  ///
  /// Observed window-wide, as `detachedTabIDs` below is: a pulse re-runs every leaf in the window,
  /// not only its target's. Both change on discrete events (a bell or notification from a pane you
  /// can see but are not in; a pop-out or dock), never with a program's output. Neither is layout,
  /// so neither goes into `TargetPanes`, which step 3.9 cuts down to a layout over tab ids. Each is
  /// a whole-value set over its storage, so a write that changes nothing notifies no view, and
  /// sends no `paneWillChange` either.
  private(set) var activityPulses: [TerminalTab.ID: Int] {
    get { pulseCounts }
    set {
      guard newValue != pulseCounts else { return }
      paneWillChange.send()
      pulseCounts = newValue
    }
  }
  private var pulseCounts: [TerminalTab.ID: Int] = [:]
  /// The tabs currently living in their own window (issue #172). Membership only — the windows
  /// themselves are owned by `AppStore`'s `DetachedPaneWindows`, and the two are kept in step by
  /// `detachPane`/`dockPane` firing `.paneDetached`/`.paneDocked`. The invariant every reader may
  /// rely on: **a tab in here has exactly one live detached window, and vice versa.**
  ///
  /// A detached tab is deliberately absent from its target's split groups (detaching runs the same
  /// removal `extractFromSplit` does), so the split/divider/auto-even machinery needs no awareness
  /// of it.
  private(set) var detachedTabIDs: Set<TerminalTab.ID> {
    get { detachedIDs }
    set {
      guard newValue != detachedIDs else { return }
      paneWillChange.send()
      detachedIDs = newValue
    }
  }
  private var detachedIDs: Set<TerminalTab.ID> = []
  /// The pane rects the renderer last laid out, per target — the only measurement a CONTENT pane
  /// (diff / file / changeset) has, since it owns no `GhosttySurfaceView` whose bounds could be
  /// read. Fed by `PaneTreeView` through a preference (so it is written after layout, never during
  /// body evaluation) and consumed only by `fits`.
  ///
  /// Deliberately **not** observed: it is written from a layout callback on every resize, and
  /// publishing from there would both churn the view graph and risk "Publishing changes from within
  /// view updates". Nothing renders from it — it is a measurement cache, not model state.
  @ObservationIgnored var paneRects: [TerminalTarget.ID: [TerminalTab.ID: CGRect]] = [:]

  /// The rect `PaneTreeView` lays a target's whole split out in — the container those `paneRects`
  /// tile. Same feed, same posture (written after layout, never observed), but a different
  /// question: the per-pane rects answer "can THIS pane be halved", while auto-even (issue #126)
  /// has to ask "can the GROUP hold another pane" and "would evening actually render evenly here".
  /// Neither is derivable from the pane rects alone once a divider has been dragged.
  ///
  /// Absent (no layout pass yet) means unmeasured, which every reader treats as permissive — the
  /// same posture `PaneTreeLayout.canSplit` takes for a zero rect.
  @ObservationIgnored var paneSpace: [TerminalTarget.ID: CGRect] = [:]

  /// Issue #126's auto-even pref, read live so the Settings toggle applies to the very next split
  /// without a relaunch. Injected rather than read inline so tests can drive both states: a parallel
  /// test worker shares (and wipes) the `Defaults` domain cross-process, which is why
  /// `AppStoreCreateWorkroomTests` stopped arming auto-run through `Defaults[.runCommands]`.
  @ObservationIgnored var autoEvenSplits: () -> Bool = { Defaults[.autoResizeSplitsEvenly] }
  /// The app-wide most-recently-focused pane order (issue #132), written by `setFocused` and read by
  /// `closeSuccessor`. Injectable like `makeView` so a test never mutates the singleton's order.
  @ObservationIgnored var recency: SwitcherRecency = .shared
  /// What these sessions tell their owner, `AppStore`, through `onEvent`. One synchronous channel:
  /// each event is a plain call at the moment it happens, in the order things happen, never deferred
  /// through a `Task`, queue or `AsyncStream`. So an event raised inside a sessions method (`focus`,
  /// `select`, `closeTab`, `detachPane`, …) is handled before that method returns, which
  /// `AppStore.withHistorySuppressed` and `select` depend on (eng review D8). `.remoteCloseFailed`
  /// happens later: the remote close's own task raises it once the host has answered. `AppStore`
  /// switches over every case, so a new case cannot go unhandled.
  enum Event: Equatable {
    /// A terminal's notification-worthy activity (OSC), for the notification spine.
    case activity(TerminalTarget.ID, TerminalTab.ID, TerminalActivity)
    /// Fired whenever the focused tab of a target actually changes, so
    /// navigation history (issue #26) can record the new location. `tabID` is nil when the target's
    /// focus was cleared (a `reap` passes `notify: false`, so that case never reaches here).
    case focusChanged(TerminalTarget.ID, TerminalTab.ID?)
    /// Fired when a tab's recorded **location** changes underneath a focus that
    /// did not move, so navigation history can record it. `.focusChanged` cannot cover this: retargeting
    /// the shared preview tab in place mutates `content` and leaves the target's focus alone, so
    /// every Changes/Files click after the first recorded nothing at all — the whole bug.
    ///
    /// "Location", not "content identity": one of the two fire sites is `setChangesetSelectedPath`, and a
    /// changeset's selected file is deliberately NOT part of content identity (`sameChangeset` excludes
    /// it, which is why the preview can be retargeted across files without becoming a different tab). It
    /// is still its own back/forward step, so it belongs here.
    ///
    /// Fired from exactly the two sites that mutate content identity (`openContentPreview`'s retarget
    /// branch and `setChangesetSelectedPath`) and nowhere else. The other opener branches all end in
    /// `setFocused` on a tab that was not focused, so `.focusChanged` already records them; firing here
    /// too would redefine this seam as "an open happened", which is not what it means.
    case tabContentChanged(TerminalTarget.ID, TerminalTab.ID)
    /// The tabs just removed by a `closeTab` or `reap`, so navigation history
    /// can prune their now-dead entries (issue #26 — honest back/forward enablement).
    case tabsRemoved(TerminalTarget.ID, [TerminalTab.ID])
    /// A surface in this target became first responder (a click into its
    /// terminal), or a tab in it was *deliberately* selected (`select` — a chip tap / ⌘1–9). Routes focus
    /// up to the *workroom* selection in a workroom split (issue #23 follow-up), so ⌘T/Run/notifications
    /// target that pane's workroom — and so a tab clicked in a co-displayed but non-focused member
    /// actually takes keyboard focus (selecting it alone leaves `surfaceActive` false, so the surface
    /// never grabs first responder).
    case surfaceFocused(TerminalTarget.ID)
    /// A pane just became detached and needs a window opened for it at the
    /// given SCREEN point (issue #172). Firing it is the second
    /// half of the one coordinated transition `detachPane` performs; nothing else may open that window.
    case paneDetached(TerminalTarget.ID, TerminalTab.ID, at: CGPoint)
    /// The mirror of `.paneDetached`: this tab is docked again, so its window must go. Also fired by
    /// `closeTab`/`reap` by way of `undetach`, so a detached window can never outlive its tab.
    case paneDocked(TerminalTab.ID)
    /// Something tried to focus a detached pane. Its window is the honest answer, so `AppStore` raises
    /// it (see `setFocused`, which refuses the focus write itself).
    case paneRaiseRequested(TerminalTab.ID)
    /// The terminal's own right-click "Move to New Window" / "Move Back to Main Window" (#444):
    /// detach this pane, or dock it when it is already in its own window.
    case paneWindowToggleRequested(TerminalTarget.ID, TerminalTab.ID)
    /// A restored pane was detached when the session was saved, so its window must be rebuilt at the
    /// saved frame. Separate from `.paneDetached` because restore is not a gesture: there is no cursor
    /// to place the window at, and the frame is authoritative.
    case paneRestoredDetached(TerminalTarget.ID, TerminalTab.ID, frame: NSRect)
    /// A closed remote pane's session could not be ended on its host, so it
    /// is still running there (#283). Given the target's id and title.
    case remoteCloseFailed(TerminalTarget.ID, title: String)
    /// The user is now looking at this terminal: its surface became first responder in the key
    /// window, by any route (#358). Its notifications are read.
    case terminalSeen(TerminalTarget.ID, TerminalTab.ID)
    /// A run tab came back from a saved session (#522): its run may still be going, and its state
    /// arrives with the session's program status.
    case runTabRestored(TerminalTarget.ID, TerminalTab.ID)
    /// A run tab's supervisor wrote a new state (#522): `running <pid>`, `stopped`, `exited <code>`.
    case runStatus(TerminalTarget.ID, TerminalTab.ID, String)
    /// A run tab's session is not on its daemon any more (#522): the host's snapshot did not name
    /// it, or the daemon said it ended.
    case runSessionGone(TerminalTarget.ID, TerminalTab.ID)
    /// A tab's own process exited (its surface's `.childExited`). For a run tab that ends the run,
    /// for an Investigate tab its session (#146); `AppStore` ignores any other tab's. Raised by the
    /// sessions that hold the tab now, so a tab moved to another window (#444) reports there. Given
    /// the whole target the tab was made or adopted for, since the run's handling needs it and a
    /// workroom being deleted is no longer in the project list to be looked up by its id.
    case childExited(TerminalTarget, TerminalTab.ID, exitCode: UInt32)
    /// A key at a run-command tab's "Process exited. Press any key to close" prompt (issue #7): close
    /// it, without a confirm. The run command's goes through its graceful stop first.
    case closeRequested(TerminalTarget, TerminalTab.ID)
    /// The number of panes this target shows across `axis` (nil: both ways) changed, by a split
    /// edit or by focus moving between a split and a solo tab, and the operation that did it has
    /// finished. A workroom split it sits in re-evens to match.
    case paneCountChanged(TerminalTarget.ID, along: SplitOrientation?)
  }

  /// The panes each target showed across each axis (`shownSlots`) at its last `reconcileOcclusion`.
  /// `announcePaneCountChange` compares it with what the target shows now and announces only the
  /// axes that changed, whatever changed them: a split, a close, or a tab switch between a split and
  /// a solo tab, so the workroom split keeps the visible terminals the same size. A restart that
  /// puts the same pane back, or a rearrange that keeps every row, announces nothing.
  @ObservationIgnored
  private var announcedShownSlots: [TerminalTarget.ID: [SplitOrientation: Int]] = [:]

  /// Set while `respawnRunTab` closes a run tab and puts its replacement back, so the close's own
  /// `reconcileOcclusion` doesn't announce a pane the respawn is about to restore.
  @ObservationIgnored private var holdingPaneCountChanges = false

  /// The project's run command for a target, for a run tab rebuilt from a saved session (#522). Set
  /// by `AppStore`, which owns the run configs.
  @ObservationIgnored var runCommandForTarget: (TerminalTarget) -> String? = { _ in nil }

  /// Set once by `AppStore`. A closure, not a store reference, so sessions stay ignorant of
  /// `AppStore`.
  @ObservationIgnored var onEvent: ((Event) -> Void)?

  /// Factory seam (plan T1): how a surface view is created for a target at a working directory.
  /// Overridable in tests so the lifecycle can be exercised without a real window/shell. The cwd
  /// argument lets a ⌘D split inherit the focused pane's directory.
  @ObservationIgnored
  var makeView: (TerminalTarget, String, String?) -> GhosttySurfaceView = { _, cwd, command in
    GhosttySurfaceView(workingDirectory: cwd, command: command)
  }

  /// The inline terminal agent (issue #49). Owned here so the per-tab callbacks can feed it; injected
  /// into the environment (see `WorkroomApp`) so the pane banner observes it. Opt-in, default off.
  let codingAgentManager: TerminalCodingAgentManager

  /// Where panes' persistent sessions are registered and ended. Settable for tests; the pane
  /// collaborators that ask it read this one.
  @ObservationIgnored var sessionService: PersistentSessionService = .shared

  // The pane collaborators. Each owns the reads and memos it starts, keyed by tab or target, and
  // reaches the tabs only through `tabAccess`, so a new one cannot leave a dictionary here for
  // `reap` or a hand-off to forget; every way a tab leaves this window drops its share in
  // `forgetPerTabWork`. Lazy because `tabAccess` captures `self`.

  /// The titles, agents, tools, Claude profiles, cwds, branches, host cwds and progress the
  /// surfaces report (issue #2).
  @ObservationIgnored private lazy var liveState = PaneLiveState(
    access: tabAccess, codingAgentManager: codingAgentManager,
    sessionService: { [weak self] in self?.sessionService ?? .shared })
  /// Program status on the tabs (#358).
  @ObservationIgnored private lazy var programStatusBinding = ProgramStatusBinding(
    access: tabAccess, sessionService: { [weak self] in self?.sessionService ?? .shared })
  /// ⌘-click in a remote pane (#254, C7).
  @ObservationIgnored
  private lazy var remoteLinks = RemotePaneLinks(access: tabAccess) { [weak self] file, target in
    _ = self?.openFilePreview(file, for: target)
  }

  /// What the collaborators may do with this window's tabs. Every write goes through
  /// `mutateTerminalState`, so through `TargetPanes`, and every event through `onEvent`.
  private var tabAccess: TerminalTabAccess {
    TerminalTabAccess(
      state: { [weak self] tabID, targetID in self?.terminalState(tabID, in: targetID) },
      mutate: { [weak self] tabID, targetID, body in
        self?.mutateTerminalState(tabID, target: targetID, body)
      },
      terminals: { [weak self] in self?.terminalStates() ?? [] },
      surface: { [weak self] tabID in self?.surface(of: tabID) },
      raise: { [weak self] event in self?.onEvent?(event) })
  }

  /// How a foreground command not in the curated `ToolLogoRegistry` gets tallied (issue #141
  /// follow-up); see `PaneLiveState.recordUnrecognizedTool`. Settable for tests.
  var recordUnrecognizedTool: (String) -> Void {
    get { liveState.recordUnrecognizedTool }
    set { liveState.recordUnrecognizedTool = newValue }
  }
  /// Where a remote pane's host-side working directory is asked for (#239). Settable for tests.
  var hostConnections: HostConnectionManager {
    get { liveState.hostConnections }
    set { liveState.hostConnections = newValue }
  }
  /// True for the Quick Terminal's sessions: its panes can each be in a different repository and no
  /// workroom knows their branch, so each reads its own (`TerminalState.liveBranch`).
  var readsPaneBranches: Bool {
    get { liveState.readsPaneBranches }
    set { liveState.readsPaneBranches = newValue }
  }
  /// How a pane's live branch is read (`TerminalState.liveBranch`). Settable for tests.
  var resolveBranch: @Sendable (String) async -> String? {
    get { liveState.resolveBranch }
    set { liveState.resolveBranch = newValue }
  }
  /// Where pane indicators read program status from. Tests swap in their own.
  var programStatus: ProgramStatusMonitor {
    get { programStatusBinding.monitor }
    set { programStatusBinding.monitor = newValue }
  }
  /// How a remote pane reaches its host's files (`RemotePaneLinks.remoteFiles`). Swapped by tests.
  var remoteFiles: (RepositoryLocation) async throws -> FileProviding {
    get { remoteLinks.remoteFiles }
    set { remoteLinks.remoteFiles = newValue }
  }

  /// False for the Quick Terminal's sessions: none of its panes moves to a window of its own, by
  /// menu, title-bar button or dragging out.
  @ObservationIgnored var allowsDetach = true
  /// The Quick Terminal's: the open workrooms its pane can move into, for the terminal's
  /// right-click menu. Nil elsewhere, so a pane that moved on loses the item when it is rewired.
  @ObservationIgnored
  var moveToWorkroomChoices: ((TerminalTab.ID, TerminalTarget) -> [PaneWorkroomGroup])?
  /// The Quick Terminal's: a pane dragged out of its window and let go, by its tab or its title bar,
  /// in place of `detachPane` (`QuickTerminalPaneDrag.end`).
  @ObservationIgnored var dropOutsideWindow: ((TerminalTab.ID, TerminalTarget) -> Void)?

  init() {
    // Under the UI-test agent fixture, drive a stub backend (no network) with the feature + auto on
    // so the XCUITest sees the banner; otherwise the normal opt-in, default-off real runner.
    #if DEBUG
      if UITestFixture.codingAgentStub {
        codingAgentManager = TerminalCodingAgentManager(
          runner: StubCodingAgentRunner(envelope: UITestFixture.codingAgentStubEnvelope),
          featureEnabled: { true }, autoDiagnoseEnabled: { true })
        return
      }
    #endif
    codingAgentManager = TerminalCodingAgentManager()
    // The OS-appearance observer that used to live here now belongs to `ThemeService` — one owner
    // for the whole app rather than one per window (WORKROOM-3R).
  }

  // A window that goes takes the tabs it holds with it, as its store did when it owned them: each
  // surface is freed as its record goes, without a teardown, as before. A tab on its way to another
  // window is held by none, so it waits for the window adopting it. The holder is never reused, so
  // a late release cannot take another window's tabs.
  deinit {
    let tabs = tabRegistry
    let holder = holder
    if Thread.isMainThread {
      MainActor.assumeIsolated { tabs.removeAll(heldBy: holder) }
    } else {
      Task { @MainActor in tabs.removeAll(heldBy: holder) }
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
    targets[targetID]?.state.displayedOrder(hiding: detachedTabIDs) ?? []
  }

  /// Every tab a target owns, in strip order, **detached panes included** — the answer to "act on
  /// all of this target's tabs", as opposed to `tabs(for:)`'s "what the strip shows".
  ///
  /// Anything that CLOSES, REAPS or refreshes model state must use this: a detached pane is still a
  /// live tab with a live process, and `tabs(for:)` hides it. That distinction is what four bulk-close
  /// paths got wrong when `tabs(for:)` was narrowed (issue #172).
  func allTabs(for target: TerminalTarget) -> [TerminalTab] {
    tabRegistry.records(normalizedTabIDs(forTargetID: target.id))
  }

  /// Strip order with EACH group's members normalised into one contiguous run, **detached panes
  /// included**. This is the raw ordering; `displayedTabIDs` is this minus the detached ones, and
  /// `sessionCapture` reads this directly so a detached pane is persisted in its old strip position.
  ///
  /// The loose order, with every group's members replaced by that group's tree order as a contiguous
  /// block at its earliest member's slot (`PaneSplitGroups.normalized`, which the workroom tab bar's
  /// order uses too). So each bracket is always one run and strip order always matches pane order
  /// (rearranging panes IS strip reorder).
  func normalizedTabIDs(forTargetID targetID: TerminalTarget.ID) -> [TerminalTab.ID] {
    targets[targetID]?.state.normalizedOrder ?? []
  }

  /// A target's tab records in its loose order, empty when it has none: the tabs its layout here
  /// holds, detached panes included.
  private func heldTabs(_ targetID: TerminalTarget.ID) -> [TerminalTab] {
    tabRegistry.records(targets[targetID]?.state.order ?? [])
  }

  /// `tabID`'s record while `targetID`'s layout here holds it. A view reading it re-renders on that
  /// target's layout and that tab's record, never on another tab's.
  private func record(_ tabID: TerminalTab.ID, in targetID: TerminalTarget.ID) -> TerminalTab? {
    guard targets[targetID]?.holds(tabID) == true else { return nil }
    return tabRegistry.record(tabID)
  }

  /// Store `tab`'s record, a new tab's or a held one's: the panes are about to change, so the
  /// signal goes first, as for any other pane write.
  private func store(_ tab: TerminalTab) {
    paneWillChange.send()
    tabRegistry.set(tab, by: holder)
  }

  /// Store `tab`'s new record while `targetID` holds it; nothing for a tab it does not.
  private func update(_ tab: TerminalTab, in targetID: TerminalTarget.ID) {
    guard targets[targetID]?.holds(tab.id) == true else { return }
    store(tab)
  }

  /// Drop `tabID` from the app altogether, record and surface (a close or a reap).
  private func discard(_ tabID: TerminalTab.ID) {
    paneWillChange.send()
    tabRegistry.remove(tabID)
  }

  // MARK: Session capture (issue #46)

  /// Everything one target contributes to a saved session, addressed by id.
  ///
  /// One accessor because the pane state behind it is private and should stay that way — capture
  /// reads through the public queries, and this is the single exception it needs (the counter,
  /// which nothing else exposes).
  struct SessionCapture {
    /// Tabs in DISPLAYED order. Safe to persist as the strip order: display normalisation is a fixed
    /// point, so feeding it back in reproduces the same layout.
    let tabs: [TerminalTab]
    /// Every split group, in no meaningful order (see `targets`).
    let splits: [TerminalPaneLayout]
    let focused: TerminalTab.ID?
    /// The "Terminal N" counter, so the next ⌘T after a restore continues the numbering.
    let counter: Int
  }

  func sessionCapture(forTargetID targetID: TerminalTarget.ID) -> SessionCapture? {
    guard let held = heldLayout(targetID) else { return nil }
    return SessionCapture(
      tabs: held.tabs, splits: held.layout.splits.groups, focused: held.layout.focused,
      counter: held.layout.counter ?? held.tabs.count)
  }

  /// `targetID`'s layout here over the tabs it holds, and those tabs, in strip order with detached
  /// panes included; nil when it holds none. What a saved session captures and what a move to
  /// another window takes, so the two can never disagree.
  ///
  /// `normalizedOrder`, NOT the displayed order: a detached pane (issue #172) must be captured in
  /// its old strip position or it is lost. This matters before quit as well as at quit — the app
  /// writes the session on `willResignActive`, so a filtered capture would drop a detached pane
  /// from merely ⌘-tabbing away.
  private func heldLayout(
    _ targetID: TerminalTarget.ID
  ) -> (tabs: [TerminalTab], layout: PaneState<TerminalTab.ID>)? {
    guard let state = targets[targetID]?.state else { return nil }
    let tabs = tabRegistry.records(state.normalizedOrder)
    guard !tabs.isEmpty else { return nil }
    let layout = PaneState(
      order: tabs.map(\.id), splits: state.splits, focused: state.focused,
      counter: state.counter ?? tabs.count)
    return (tabs, layout)
  }

  func tabs(for target: TerminalTarget) -> [TerminalTab] {
    tabRegistry.records(displayedTabIDs(for: target))
  }

  /// Number of live tabs for a target id (issue #30 — lets `AppStore` prune the sidebar's
  /// terminal-subtree expand flag when a close drops a target below the 2-tab disclosure threshold).
  func tabCount(forTargetID id: TerminalTarget.ID) -> Int { heldTabs(id).count }

  /// Whether any target owns the tab `id`. Tab ids are unique across windows, so `WindowRegistry`
  /// uses this to route an OS-notification click to the window that owns the tab (issue #70).
  func containsTab(_ id: TerminalTab.ID) -> Bool {
    targets.values.contains { $0.holds(id) }
  }

  /// The target that owns the tab `id` here, or nil.
  func targetID(ofTab id: TerminalTab.ID) -> TerminalTarget.ID? {
    targets.first { $0.value.holds(id) }?.key
  }

  /// Every tab this window holds, target by target.
  private var heldTabs: [TerminalTab] {
    targets.values.flatMap { tabRegistry.records($0.state.order) }
  }

  /// Includes hidden targets, background tabs, and panes popped into their own windows.
  var activeCodingAgentBackends: Set<CodingAgentBackend> {
    Set(heldTabs.compactMap(\.terminal?.activeCodingAgentBackend))
  }

  /// The set of target ids that currently own at least one terminal — the "active" targets backing
  /// the Workrooms View tab bar (issue #23). Filtered on **non-empty** because `closeTab` leaves an
  /// emptied target's entry in place while `reap` removes it entirely; both must read as inactive.
  /// It reads only whether each target has tabs (`TargetPanes.hasTabs`), so a view that reads it,
  /// in this window or another (⌥Tab's enablement counts every window's), re-renders as targets
  /// come and go or gain or lose their terminals, and on nothing else.
  var activeTargetIDs: Set<TerminalTarget.ID> {
    Set(targets.compactMap { $0.value.hasTabs ? $0.key : nil })
  }

  /// Whether any terminal in this target is mid-command (has a live command title, issue #2) — drives
  /// the sidebar's running spinner.
  func isRunning(forTargetID id: TerminalTarget.ID) -> Bool {
    heldTabs(id).contains { $0.isRunning }
  }

  /// Whether any terminal in this target is working with a reported error (OSC 9;4 ERROR).
  func isProgressFailed(forTargetID id: TerminalTarget.ID) -> Bool {
    heldTabs(id).contains { $0.isProgressFailed }
  }

  /// Whether a program in any terminal of this target waits on the user (#358).
  func needsAttention(forTargetID id: TerminalTarget.ID) -> Bool {
    blockedTerminalCount(forTargetID: id) > 0
  }

  /// How many terminals of this target wait on the user.
  func blockedTerminalCount(forTargetID id: TerminalTarget.ID) -> Int {
    heldTabs(id).count { $0.needsAttention }
  }

  /// Whether a waiting terminal of this target is on a host whose link is down (#358).
  func isWaitingStale(forTargetID id: TerminalTarget.ID) -> Bool {
    heldTabs(id).contains {
      $0.needsAttention && $0.programStatus?.stale == true
    }
  }

  /// Whether any terminal of this target reported an error that stopped it (#358).
  func hasProgramError(forTargetID id: TerminalTarget.ID) -> Bool {
    heldTabs(id).contains { $0.indicator == .error }
  }

  /// This target's waiting terminals, the one waiting longest first (ties keep strip order).
  func blockedTabs(forTargetID id: TerminalTarget.ID) -> [(tab: TerminalTab.ID, since: Date)] {
    heldTabs(id).compactMap { tab -> (TerminalTab.ID, Date)? in
      guard tab.needsAttention, let state = tab.terminal else { return nil }
      return (tab.id, state.programStatus?.blockedSince ?? .distantFuture)
    }
    .enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element)
  }

  /// The **visible** group: the one containing the focused tab, or nil when the focused tab is solo.
  /// Every "is a split on screen" read keys off this — a group whose members are all unfocused
  /// persists but isn't displayed (select a member and it reappears).
  func split(for target: TerminalTarget) -> TerminalPaneLayout? {
    targets[target.id]?.state.visibleGroup
  }

  /// Every split group this target owns, visible or not (empty when nothing is grouped).
  func splits(for target: TerminalTarget) -> [TerminalPaneLayout] {
    splitGroups(target.id).groups
  }

  /// The group `tabID` belongs to, or nil when it isn't grouped. Groups are disjoint, so this is the
  /// one authority on "which group is this tab in" — as opposed to `split(for:)`, which answers the
  /// narrower "which group is on screen".
  func split(containing tabID: TerminalTab.ID, for target: TerminalTarget) -> TerminalPaneLayout? {
    splitGroups(target.id).group(containing: tabID)
  }

  /// `member → group index` for every grouped tab, so the strip can bracket each group's run
  /// (`PaneSplitGroups.groupIndices`, as the workroom tab bar's). Build it ONCE per render pass and
  /// thread it down — it walks every leaf of every group, and the strip consults it per chip.
  func splitGroupIndices(for target: TerminalTarget) -> [TerminalTab.ID: Int] {
    splitGroups(target.id).groupIndices
  }

  /// Look up a tab by id (the pane renderer resolves leaves → surfaces through this).
  func tab(_ id: TerminalTab.ID, for target: TerminalTarget) -> TerminalTab? {
    record(id, in: target.id)
  }

  /// The surface view for a tab, located by target + tab id without a `TerminalTarget` value. Lets
  /// the run-command graceful-stop paths (issue #7) reach a live process by id alone — e.g. on quit,
  /// where `AppStore` iterates `runStates` keyed by `TerminalTarget.ID`.
  func view(
    forTab tabID: TerminalTab.ID, inTarget targetID: TerminalTarget.ID
  ) -> GhosttySurfaceView? {
    guard targets[targetID]?.holds(tabID) == true else { return nil }
    return surface(of: tabID)
  }

  /// The surface of terminal tab `tabID`, or nil for a content tab or a tab this window does not
  /// hold. The single accessor every surface-specific path (occlusion, theme reload, teardown,
  /// run-state) funnels through, so a content tab transparently does *fewer* surface operations —
  /// never more. Not observed: a surface comes and goes with its tab's record, which is.
  func surface(of tabID: TerminalTab.ID) -> GhosttySurfaceView? {
    tabRegistry.surface(of: tabID, heldBy: holder)
  }

  /// What is known of `tabID`'s run while this window holds it, nil when nothing is yet. It stays
  /// with the tab when the tab moves to another window, and goes when the tab closes.
  func run(of tabID: TerminalTab.ID) -> RunCommands.TabRun? {
    tabRegistry.run(of: tabID, heldBy: holder)
  }

  /// `run(of:)`, made on first use; nil for a tab this window does not hold.
  func makeRun(of tabID: TerminalTab.ID) -> RunCommands.TabRun? {
    tabRegistry.makeRun(of: tabID, heldBy: holder)
  }

  /// The Investigate tabs (#146) this window holds, detached panes included.
  var investigateTabIDs: [TerminalTab.ID] { tabRegistry.investigateTabs(heldBy: holder) }

  /// The focused tab (selection), falling back to the first tab in strip order.
  func focusedTab(for target: TerminalTarget) -> TerminalTab? {
    if let id = targets[target.id]?.state.focused, let match = record(id, in: target.id) {
      return match
    }
    return displayedTabIDs(for: target).first.flatMap { tabRegistry.record($0) }
  }

  /// The focused tab's surface: nil when it is a content tab, or the target has no tab here.
  func focusedSurface(for target: TerminalTarget) -> GhosttySurfaceView? {
    surface(focusedTab(for: target))
  }

  /// `tab`'s surface, for a tab read a moment ago: nil for none, a content tab, or a tab this
  /// window no longer holds.
  func surface(_ tab: TerminalTab?) -> GhosttySurfaceView? {
    tab.flatMap { surface(of: $0.id) }
  }

  /// Alias kept so existing call sites/tests read naturally. "The active tab" is the focused pane.
  func activeTab(for target: TerminalTarget) -> TerminalTab? { focusedTab(for: target) }

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
    let detached = detachedTabIDs.filter { record($0, in: target.id) != nil }
    if let split = split(for: target) { return split.tabIDs + detached }
    if let focused = focusedTab(for: target) { return [focused.id] + detached }
    return Array(detached)
  }

  // MARK: Lifecycle

  /// Create the target's first terminal the first time its pane appears. Once opened, an emptied tab
  /// set is left as-is (the user closed them on purpose).
  func ensureTab(for target: TerminalTarget) {
    if targets[target.id] == nil { addTab(for: target) }
  }

  // MARK: Session restore (issue #46)

  /// What a restore produced: how many tabs of any kind came back.
  struct RestoreResult: Equatable {
    var count: Int

    static let nothing = RestoreResult(count: 0)
  }

  /// Re-materialise a target's panes from a saved session.
  ///
  /// The only path that sets a target's tabs and order wholesale, so it lives here beside the
  /// mutation primitives rather than in `AppStore`. Three deliberate properties:
  ///
  /// - **Tabs get FRESH ids.** A `TerminalTab.ID` is unique across *windows* at runtime and OS
  ///   notification clicks are routed by it (`WindowRegistry.ownerOf(tabID:)`), so reviving persisted
  ///   ids would put a duplicate-id hazard one bug away for no benefit. The persisted keys are a join
  ///   key valid only within one snapshot; order, split and focus are rewired through them here.
  /// - **Focus is set with `notify: false`** (the escape `reap` uses): a restore is not a navigation,
  ///   and firing `.focusChanged` would seed back/forward with a place the user never went.
  /// - **No-op when the target already has tabs**, so a restore can never race or duplicate a live
  ///   session.
  ///
  /// Terminals come back in their remembered directory and reattach to their session if it is
  /// still alive; otherwise they are a fresh login shell. Nothing spawns here:
  /// constructing a surface is inert until it enters a window.
  @discardableResult
  func restore(
    _ session: TargetSession, for target: TerminalTarget
  ) -> RestoreResult {
    guard heldTabs(target.id).isEmpty else {
      // Its saved panes, and the sessions they would reattach to, are dropped here.
      let saved = session.sessionIDs.map(\.uuidString).sorted().joined(separator: ", ")
      Self.logger.error(
        "restore skipped \(target.id, privacy: .public): it already has tabs; saved sessions not reattached: [\(saved, privacy: .public)]"
      )
      return .nothing
    }

    var idsByKey: [String: TerminalTab.ID] = [:]
    var order: [TerminalTab.ID] = []
    // The terminals are stored as they are made; the content tabs join them below.
    var contentTabs: [TerminalTab] = []
    var restoredDetached: [(TerminalTab.ID, NSRect)] = []
    var restoredRun: TerminalTab.ID?

    for saved in session.tabs {
      let tab: TerminalTab
      if saved.kind == TabSession.terminalKind, let payload = saved.terminal,
        payload.run == true
      {
        // A run tab (#522), one per target, reattached to its run session. Its command is passed
        // only so the session is a run session: a restored attach never creates one, so this can
        // never start the command, whatever the file says (`workroomd attach`, D2).
        guard restoredRun == nil, let sessionID = payload.sessionID.flatMap(UUID.init(uuidString:))
        else { continue }
        tab = makeRunTab(
          for: target, command: runCommandForTarget(target) ?? "", cwd: target.path,
          runSession: true, sessionID: sessionID)
        restoredRun = tab.id
      } else if saved.kind == TabSession.terminalKind, let payload = saved.terminal {
        // `command:` is deliberately never passed, so even a hand-edited file cannot start a
        // process on launch. A remote pane's path is on its host, which this Mac can't check: its
        // own path, always.
        let cwd =
          target.remoteHost == nil
          ? Self.restoredCwd(payload.cwd, fallback: target.path) : target.path
        tab = makeTerminalTab(
          for: target,
          cwd: cwd,
          title: payload.defaultTitle,
          sessionID: payload.sessionID.flatMap(UUID.init(uuidString:)))
      } else if let content = saved.restoredContent {
        tab = TerminalTab(
          content: content, diffViewModeOverride: saved.restoredDiffViewMode,
          markdownPreviewOverride: saved.restoredMarkdownPreview)
        contentTabs.append(tab)
      } else {
        continue
      }
      idsByKey[saved.key] = tab.id
      order.append(tab.id)
      // A pane that was in its own window comes back in one (issue #172). Recorded here and reported
      // to `AppStore` below, once the target's tabs are actually populated — the window's content
      // resolves the tab by id, so it must exist before the window opens.
      if let frame = saved.detachedFrame.map(NSRectFromString), frame.width > 0, frame.height > 0 {
        restoredDetached.append((tab.id, frame))
      }
    }

    guard !order.isEmpty else { return .nothing }

    let panes = openPanes(target.id)
    for tab in contentTabs { store(tab) }
    panes.updateState { $0.order = order }
    // Detached tabs resolve to NOTHING here, so a saved group naming one comes back without it.
    // The split groups' invariant is that a detached tab is never a member (`targets`): rendering
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
    setSplits(PaneSplitGroups(restoredSplits), for: target.id)
    // Mark detached panes BEFORE choosing focus. `setFocused`'s own guard refuses to focus a detached
    // tab (focusing one makes `contentLayout` render it back in THIS window and re-homes the
    // libghostty view out of its own window, which then goes blank) — but that guard reads
    // `detachedTabIDs`, so with the insert below it, it could not fire during a restore. The ordinary
    // flow that reached it: detach your only pane, quit, relaunch — `closeSuccessor` returns nil for a
    // sole tab, so nothing was persisted as focused and the `?? order.first` fallback landed on the
    // detached pane (`order` deliberately includes detached tabs, issue #172). The fallback skips them
    // for the same reason. Windows still open afterwards, once the target's tabs are populated.
    for (tabID, _) in restoredDetached { detachedTabIDs.insert(tabID) }
    setFocused(
      session.focusedKey.flatMap { idsByKey[$0] }.flatMap {
        detachedTabIDs.contains($0) ? nil : $0
      } ?? order.first { !detachedTabIDs.contains($0) }, for: target.id, notify: false)
    // `makeTerminalTab` bumps the counter per terminal it builds, so take whichever is higher: the
    // saved value keeps "Terminal 7" from becoming "Terminal 3" again after closes.
    targets[target.id]?.updateState { $0.raiseCounter(to: session.terminalCounter ?? 0) }
    // Open the windows AFTER the tabs are set: `.paneDetached` builds a window whose content
    // looks the tab up by id. Restoring is not a user gesture, so this skips `detachPane` — the split
    // was already captured without these tabs, and membership was recorded above.
    for (tabID, frame) in restoredDetached {
      onEvent?(.paneRestoredDetached(target.id, tabID, frame: frame))
    }
    if let restoredRun { onEvent?(.runTabRestored(target.id, restoredRun)) }
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

  /// Wait for a pane's branch read in flight. For tests.
  func liveBranchRead(forTab tabID: TerminalTab.ID) async {
    await liveState.branchRead(forTab: tabID)
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
  //   Inv A         ─▶ setFocused (a brand-new tab) ─▶ .focusChanged ─▶ AppStore records
  //   Inv B         ─▶ content mutates, focus does NOT ─▶ .tabContentChanged ─▶ AppStore records
  //   Inv C         ─▶ focus may EARLY-RETURN (already focused) ─▶ .tabContentChanged too, so a
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
      // Re-selecting content that is ALREADY the focused tab moves nothing, so `.focusChanged` stays
      // quiet — yet after a replay landed in a tab the history cursor doesn't name, the cursor and the
      // screen disagree, and staying quiet leaves the forward stack pointing at a future that is no
      // longer on screen. Report it and let `record`'s dedup decide: same place ⇒ free no-op, different
      // place ⇒ the entry the user actually re-selected, which truncates forward.
      onEvent?(.tabContentChanged(target.id, existing))
      return existing
    }
    if let previewID = previewTabID(in: target.id), var tab = record(previewID, in: target.id) {
      tab.content = desc.makeTabContent()
      update(tab, in: target.id)
      focus(previewID, for: target)
      // The content moved but the focus did not, so `.focusChanged` will not fire — this is the one
      // opener branch navigation history cannot otherwise see (issue #26 follow-up).
      onEvent?(.tabContentChanged(target.id, previewID))
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
      // Same reconciliation as the preview dedup branch.
      onEvent?(.tabContentChanged(target.id, existing))
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
    heldTabs(target).first { descriptor.matches($0.content) }?.id
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
    guard var tab = record(tabID, in: target.id) else { return }
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
    update(tab, in: target.id)
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
  /// toggle. Reassigns the tab value so the sessions publish and the pane's `DiffViewer`
  /// re-renders. No-op for a missing or non-diff tab.
  func setDiffViewMode(
    _ mode: DiffViewMode, forTab tabID: TerminalTab.ID, in target: TerminalTarget
  ) {
    guard var tab = record(tabID, in: target.id), case .diff = tab.content else { return }
    tab.diffViewModeOverride = mode
    update(tab, in: target.id)
  }

  /// Set the selected file within a changeset tab (the History detail's file list). Reassigns the
  /// tab value so the sessions publish and `ChangesetDetailView` re-renders the diff for
  /// the new file — without a reload (its `.task` keys on the commit id, unchanged). No-op for a
  /// missing / non-changeset tab, or when already selected.
  func setChangesetSelectedPath(
    _ path: String?, forTab tabID: TerminalTab.ID, in target: TerminalTarget
  ) {
    guard var tab = record(tabID, in: target.id), case .changeset(var desc) = tab.content,
      desc.selectedPath != path
    else { return }
    desc.selectedPath = path
    tab.content = .changeset(desc)
    update(tab, in: target.id)
    // A selection change inside a commit is its own location, and it moves no focus — so, like the
    // preview retarget, only this seam can tell navigation history about it.
    onEvent?(.tabContentChanged(target.id, tabID))
  }

  /// Refresh an open diff tab's change kind in place, leaving everything else about the tab alone.
  ///
  /// `DiffDescriptor.change` is captured when the tab opens but is not inert — `DiffViewer` paints it as
  /// the header letter and the tab strip disables "Open file in…" for a `.deleted` source — so it has to
  /// follow the working copy while the tab sits open. Called by `AppStore.refreshOpenDiffChangeKinds`
  /// off the status sweep.
  ///
  /// Deliberately NOT routed through `setContent`, and deliberately silent on `.tabContentChanged`: that
  /// callback records a back/forward entry, and a sweep noticing a file went from modified to deleted is
  /// not somewhere the user navigated. Returns whether anything changed; the no-op case publishes
  /// nothing, so a 15s sweep can't invalidate every strip row for free.
  @discardableResult
  func refreshDiffChangeKind(
    _ change: ChangedFile.Change, forTab tabID: TerminalTab.ID, in targetID: TerminalTarget.ID
  ) -> Bool {
    guard var tab = record(tabID, in: targetID), case .diff(var desc) = tab.content,
      desc.change != change
    else { return false }
    desc.change = change
    tab.content = .diff(desc)
    update(tab, in: targetID)
    return true
  }

  /// Set a file tab's Markdown source/preview override, from the tab toolbar's Source/Preview switch.
  /// Reassigns the tab value so the sessions publish and the pane's `PlainFileViewer`
  /// re-renders. No-op for a missing or non-file tab.
  func setMarkdownPreview(
    _ preview: Bool, forTab tabID: TerminalTab.ID, in target: TerminalTarget
  ) {
    guard var tab = record(tabID, in: target.id), case .file = tab.content else { return }
    tab.markdownPreviewOverride = preview
    update(tab, in: target.id)
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
    guard var tab = record(tabID, in: target.id) else { return }
    let wasPreview = tab.isPreview
    guard case .terminal = tab.content else {
      tab.content = payload.makeTabContent(isPreview: wasPreview)
      update(tab, in: target.id)
      onEvent?(.tabContentChanged(target.id, tabID))
      return
    }
    assertionFailure("replay must never overwrite a terminal tab's content")
  }

  /// The id of the target's single preview content tab, if one exists (the ≤1-preview invariant).

  private func previewTabID(in target: TerminalTarget.ID) -> TerminalTab.ID? {
    heldTabs(target).first(where: \.isPreview)?.id
  }

  /// Open the dedicated "run command" terminal (issue #7): a solo tab that launches `command` in
  /// `cwd`, titled "Run" until the program reports its own title, focused like any new tab — through
  /// `setFocused`, so focus observers fire (it is NOT a direct dict write; see the focus-chokepoint
  /// note on `setFocused`). The caller (`AppStore`) owns the run-state and hears the tab's exit as
  /// `.childExited`; this just creates and shows the tab. Also the mechanism behind an interactive Investigate
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
  ///   any state ────── close tab (⌘W/✕) / reap ─▶ removed (state cleared via .tabsRemoved)
  /// ```
  /// A backgrounded run tab is never the active tab, so it never mounts — and a libghostty surface
  /// spawns its process only on window-mount. We give the off-window `ensureSurfaceCreated` a sane
  /// initial size so the command starts with reasonable COLUMNS/LINES; it re-sizes on first real mount.
  static let backgroundRunInitialSize = CGSize(width: 800, height: 480)

  /// `runSession`: `command` is the project's run command, run by the daemon as a run session
  /// (#522). Otherwise it runs in the tab's own process, as an Investigate tab's agent does.
  @discardableResult
  func addRunTab(
    for target: TerminalTarget, command: String, cwd: String, focus: Bool = true,
    runSession: Bool = false
  ) -> TerminalTab {
    let tab = makeRunTab(for: target, command: command, cwd: cwd, runSession: runSession)
    insert(tab, for: target)
    if focus {
      setFocused(tab.id, for: target.id)
    } else {
      // Issue #67 (run in the background): not focusing means the pane never mounts, so spawn the
      // surface off-window now — otherwise the command would never start and the toast would lie.
      surface(of: tab.id)?.ensureSurfaceCreated(initialSize: Self.backgroundRunInitialSize)
    }
    reconcileOcclusion(for: target)
    return tab
  }

  /// A run tab attached to a run session that is already going (#522): one another Mac started on
  /// the workroom's host (D7). Attached as a restored pane, so a session that has gone meanwhile is
  /// never started again.
  @discardableResult
  func addRestoredRunTab(
    for target: TerminalTarget, command: String, sessionID: UUID, focus: Bool
  ) -> TerminalTab {
    let tab = makeRunTab(
      for: target, command: command, cwd: target.path, runSession: true, sessionID: sessionID)
    insert(tab, for: target)
    if focus {
      setFocused(tab.id, for: target.id)
    } else {
      surface(of: tab.id)?.ensureSurfaceCreated(initialSize: Self.backgroundRunInitialSize)
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
  /// `addRunTab`. Returns the new tab so the caller records its run-state, as `addRunTab` does.
  @discardableResult
  func respawnRunTab(
    replacing oldID: TerminalTab.ID, for target: TerminalTarget, command: String, cwd: String,
    focus: Bool = true, runSession: Bool = false
  ) -> TerminalTab {
    // Capture the old tab's place BEFORE closing it collapses its group / drops it from the order.
    let priorSplit = split(containing: oldID, for: target)
    let orderIndex = targets[target.id]?.state.order.firstIndex(of: oldID)

    // The close collapses the group and the restore below rebuilds it, so the workroom shows the
    // same panes afterwards: hold the close's announcement and let the final reconcile judge.
    holdingPaneCountChanges = true
    closeTab(oldID, for: target)  // frees the port (SIGHUP); collapses the group — restored below
    holdingPaneCountChanges = false

    let tab = makeRunTab(for: target, command: command, cwd: cwd, runSession: runSession)
    let panes = openPanes(target.id)
    panes.updateState {
      if let orderIndex {
        $0.order.insert(tab.id, at: min(orderIndex, $0.order.count))
      } else {
        $0.order.append(tab.id)
      }
    }
    // Re-derive the group from the pre-close tree with the new tab in the old leaf's slot — exact for
    // any depth (a 3-pane split keeps both siblings), unlike re-inserting beside a guessed neighbour.
    // The close already collapsed that group, so find what is left of it through a surviving member;
    // a two-pane group is gone entirely and the rebuilt tree re-enters as a new group. Not evened:
    // the panes are the ones that were there.
    if let priorSplit {
      setSplits(
        splitGroups(target.id).storing(
          priorSplit.replacingLeaf(oldID, with: tab.id),
          overGroupOf: priorSplit.tabIDs.first { $0 != oldID }),
        for: target.id)
    }
    if focus {
      setFocused(tab.id, for: target.id)
    } else {
      // Background restart (issue #67): keep it unfocused, but spawn off-window so the respawned
      // command actually runs (the new tab won't mount until the user opens it).
      surface(of: tab.id)?.ensureSurfaceCreated(initialSize: Self.backgroundRunInitialSize)
    }
    reconcileOcclusion(for: target)
    return tab
  }

  /// Build a run tab (issue #7) without placing it: the surface launches `command` in `cwd`, titled
  /// "Run" until the program reports its own title. "Process exited. Press any key to close"
  /// (wait_after_command) → close this tab on the keypress, without the confirm (the process has
  /// already exited). Only run-command surfaces raise `.closeRequested`. Shared by `addRunTab` (append + focus) and
  /// `respawnRunTab` (in-place restart, issue #40).
  private func makeRunTab(
    for target: TerminalTarget, command: String, cwd: String, runSession: Bool,
    sessionID: UUID? = nil
  ) -> TerminalTab {
    makeTerminalTab(
      for: target, cwd: cwd, command: command, title: "Run", sessionID: sessionID,
      runSession: runSession)
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
    store(newTab)

    // Grow the focused pane's own group beside it, on the requested side, or seed a NEW group from
    // the focused solo tab, leaving every other group exactly as it was. Always an add, so it always
    // evens along the split's axis (issue #126) — every caller of this function is a split command.
    setSplits(
      splitGroups(target.id).inserting(
        newTab.id, beside: focused.id, edge: edge, policy: splitPolicy(for: target.id)),
      for: target.id)
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
    // A remote pane's directory is the host's answer (`hostCwd`): its local surface sees no OSC 7.
    let anchorState = anchor.terminal
    var cwd = anchorState?.cwd ?? target.path
    if target.remoteHost != nil {
      cwd = anchorState?.hostCwd ?? target.path
    }
    return makeTerminalTab(for: target, cwd: cwd)
  }

  /// Split a *specific* tab — the tab toolbar's "Split right" and the chip context menu's split items
  /// (issue #72) — as opposed to `splitFocusedPane`, which always acts on the focused pane. Uses
  /// `select`, not `focus` (review D2), so a deliberate right-click/toolbar action also promotes this
  /// workroom to the focused member of a workroom split (#23); then splits the now-focused anchor (a
  /// diff anchor splits into a second diff pane, a terminal into a new shell — see `newPaneTab`).
  func splitTab(_ tabID: TerminalTab.ID, on edge: PaneEdge, for target: TerminalTarget) {
    guard let tab = record(tabID, in: target.id) else { return }
    // Check the fit BEFORE `select`, not after. `splitFocusedPane` refuses silently when the pane is
    // too small to halve, and `select` has already moved the focused tab and promoted this workroom
    // to the focused split member by then — so a refused split still visibly changed the selection,
    // with nothing to explain why. The anchor `splitFocusedPane` would evaluate is this same tab.
    guard fits(splitting: tab, orientation: edge.orientation, for: target) else { return }
    select(tabID, for: target)
    splitFocusedPane(for: target, edge: edge)
  }

  /// A strip drag of the visible solo tab leaves its usual focus successor behind. Pane-title
  /// drags still treat a drop onto themselves as a no-op, as do split members over their own pane.
  func tabStripSplitDestination(
    moving movedID: TerminalTab.ID, over destID: TerminalTab.ID, for target: TerminalTarget
  ) -> TerminalTab.ID? {
    guard movedID == destID else { return destID }
    guard split(containing: movedID, for: target) == nil else { return nil }
    return closeSuccessor(of: movedID, for: target)
  }

  func dropTabFromStrip(
    _ movedID: TerminalTab.ID, ontoEdge edge: PaneEdge, of destID: TerminalTab.ID,
    for target: TerminalTarget
  ) {
    guard
      let destination = tabStripSplitDestination(
        moving: movedID, over: destID, for: target)
    else { return }
    // The current pane supplies the measured size when the successor is hidden.
    if movedID == destID {
      guard let moved = tab(movedID, for: target),
        fits(splitting: moved, orientation: edge.orientation, for: target)
      else { return }
    }
    moveTabIntoSplit(movedID, ontoEdge: edge, of: destination, for: target)
  }

  /// Drag-and-drop (issue #3): place `movedID` on `edge` of `destID`'s pane. One op covers both
  /// dragging a tab from the strip into a pane AND rearranging an existing pane, since panes are tabs.
  /// Two solo tabs dropped together seed a NEW group; every other group survives untouched.
  /// No-op if either tab is missing or `movedID == destID`.
  func moveTabIntoSplit(
    _ movedID: TerminalTab.ID, ontoEdge edge: PaneEdge, of destID: TerminalTab.ID,
    for target: TerminalTarget
  ) {
    guard movedID != destID, record(movedID, in: target.id) != nil,
      let dest = record(destID, in: target.id)
    else { return }
    // Same floor ⌘D obeys. Without this the two paths disagree by the whole floor: ⌘D refuses to
    // halve a pane under `minPaneWidth`, while dragging a chip onto that same pane's edge split it
    // anyway. Rearranging *within* an existing split is exempt — the pane count doesn't change, so
    // nothing new has to fit; only a drop that adds a member to this pane is measured. An addition
    // is a move ACROSS groups (or in from solo); two members of one group swapping places leaves the
    // pane count — and so the pane sizes — unchanged.
    let groups = splitGroups(target.id)
    if groups.addsMember(movedID, beside: destID),
      !fits(splitting: dest, orientation: edge.orientation, for: target)
    {
      return
    }

    // Detach first, insert second. A genuine move evens the group left behind and the one joined; a
    // rearrange within one group is evened once, after the insert (`PaneSplitGroups.inserting`).
    setSplits(
      groups.inserting(movedID, beside: destID, edge: edge, policy: splitPolicy(for: target.id)),
      for: target.id)
    insertID(movedID, after: destID, for: target)  // display normalises the contiguous run
    setFocused(movedID, for: target.id)
    reconcileOcclusion(for: target)
  }

  /// Move a pane into its own window (issue #172). One coordinated transition: the model half here,
  /// the window half through `.paneDetached`, so the two can never be observed apart.
  ///
  /// The model half MIRRORS `extractFromSplit` (it does not call it) — a detached tab must not remain
  /// a split member, or the layout would still try to render it. It is a mirror rather than a reuse
  /// because `extractFromSplit` focuses the tab it pulls out, which is the one thing detaching must
  /// NOT do: the focus has to go to a survivor. The successor is therefore computed BEFORE the
  /// mutation, the same ordering `closeTab` uses, because `closeSuccessor` reads the on-screen order.
  ///
  /// A preview tab is pinned on the way out: `previewTabID` scans every tab, detached ones
  /// included, so the next Changes/Files click would otherwise replace this pane's content in place
  /// and the popped-out window would silently become a different file.
  func detachPane(_ tabID: TerminalTab.ID, for target: TerminalTarget, at screenPoint: CGPoint) {
    guard allowsDetach, let tab = record(tabID, in: target.id), !detachedTabIDs.contains(tabID)
    else { return }
    let wasFocused = targets[target.id]?.state.focused == tabID
    let successor = closeSuccessor(of: tabID, for: target)
    if tab.isPreview { persist(tabID, for: target) }
    removeFromGroup(tabID, for: target.id)
    detachedTabIDs.insert(tabID)
    if wasFocused { setFocused(successor, for: target.id) }
    reconcileOcclusion(for: target)
    onEvent?(.paneDetached(target.id, tabID, at: screenPoint))
  }

  /// Drop a tab's activity pulse and its collaborators' work: its in-flight host cwd, Claude
  /// profile and branch reads, and a finish it watched. Every way a tab leaves this window (close,
  /// reap, hand-off) does.
  private func forgetPerTabWork(_ tabID: TerminalTab.ID) {
    activityPulses[tabID] = nil
    liveState.forget(tabID)
    programStatusBinding.forget(tabID)
  }

  // MARK: A pane dragged out of its window, by its tab or its title bar

  /// Show what letting go here would do: the ghost of the window it would become, or for the
  /// Quick Terminal's (no window of their own), the workroom it would join.
  func showDragOutside(_ tab: TerminalTab) {
    if allowsDetach {
      DetachedPaneDragPreview.shared.show(
        title: tab.title, glyph: tab.content.glyph, at: NSEvent.mouseLocation)
    } else {
      QuickTerminalPaneDrag.update(title: tab.title, glyph: tab.content.glyph)
    }
  }

  /// The drag came back inside, or ended.
  func hideDragOutside() {
    if allowsDetach {
      DetachedPaneDragPreview.shared.hide()
    } else {
      QuickTerminalPaneDrag.cancel()
    }
  }

  /// Let go outside the window: its own window, or the workroom under the pointer.
  func dropOutside(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    if allowsDetach {
      detachPane(tabID, for: target, at: NSEvent.mouseLocation)
    } else {
      dropOutsideWindow?(tabID, target)
    }
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
    onEvent?(.paneDocked(tabID))
    return true
  }

  // MARK: Hand-over between windows (#444)

  /// One target's layout, lifted out of a window for another window to adopt. Only the layout
  /// travels: the tabs it names stay in the app's `TerminalTabs`, with their ids, records and
  /// surfaces, so processes, scrollback and notifications carry straight across and no per-tab
  /// field can be dropped on the way. Nothing reattaches: a reattach repaints only the newest few
  /// MiB of history and re-mints tab ids, and a run tab has no session to reattach to.
  ///
  /// Between the hand-off and the adopt the tabs are held by no window (`TabRecords.release`).
  struct TargetHandOff {
    let target: TerminalTarget
    /// The target's layout in the window it left: every tab id in strip order, detached panes
    /// included, its splits, focus and "Terminal N" counter.
    let layout: PaneState<TerminalTab.ID>
    /// The tabs in their own windows, each with its window's frame. Window-level, not per tab: the
    /// detached windows are the window's (`DetachedPaneWindows`), so the one it left closes them and
    /// this one opens its own at the same frames (`AppStore` fills the frames in).
    var detached: [TerminalTab.ID: NSRect]
    /// Each tab's coding-agent banner and last failure, from the manager of the window it left.
    /// Window-level too: the manager is each window's environment object, observed by its views as
    /// a whole, so holding every window's banners in one would re-render every window on each.
    let agent: [TerminalTab.ID: (banner: CodingAgentBannerState?, failure: FailedCommand?)]

    /// The tabs, in strip order, detached panes included.
    var tabIDs: [TerminalTab.ID] { layout.normalizedOrder }
  }

  /// Lift `target`'s tabs out of this window WITHOUT ending a session or freeing a surface: the one
  /// removal that leaves the tabs alive, for another window to `adopt`. Fires `.tabsRemoved`, so this
  /// window tidies up as it does for a close (history, split membership, selection). Detached
  /// membership goes silently: `AppStore` closes those windows itself and the destination reopens
  /// them, which `.paneDocked` would race.
  func handOff(_ target: TerminalTarget) -> TargetHandOff? {
    guard let held = heldLayout(target.id) else { return nil }
    let ids = held.layout.order
    let handOff = TargetHandOff(
      target: target, layout: held.layout,
      detached: Dictionary(
        uniqueKeysWithValues: ids.filter(detachedTabIDs.contains).map { ($0, NSRect.zero) }),
      agent: Dictionary(uniqueKeysWithValues: ids.map { ($0, codingAgentManager.handOff($0)) }))
    detachedTabIDs.subtract(ids)
    for id in ids { forgetPerTabWork(id) }
    // Emptied, not forgotten, as a close of every tab leaves it: `ensureTab` must not read the
    // workroom as never opened and start a fresh terminal behind the move.
    targets[target.id]?.empty()
    paneRects[target.id] = nil
    paneSpace[target.id] = nil
    // Released once the layout no longer names them; a tab in transit takes no store (`TabRecords`).
    tabRegistry.release(ids, by: holder)
    onEvent?(.tabsRemoved(target.id, ids))
    return handOff
  }

  /// Lift one live tab out of `target`, for `destination` in another window to `adopt`: a Quick
  /// Terminal pane moving into a workroom. As `handOff`, nothing ends and nothing is freed; the
  /// tab leaves as a close would (its split, focus, `.tabsRemoved`), so its last tab leaving empties
  /// the target. Its session's metadata names `destination` from now on, for a reattach.
  func handOffTab(
    _ tabID: TerminalTab.ID, from target: TerminalTarget, to destination: TerminalTarget
  ) -> TargetHandOff? {
    guard let tab = record(tabID, in: target.id), !detachedTabIDs.contains(tabID) else {
      return nil
    }
    let wasFocused = targets[target.id]?.state.focused == tabID
    let successor = closeSuccessor(of: tabID, for: target)
    if tab.isPreview { persist(tabID, for: target) }
    let view = surface(of: tabID)
    let handOff = TargetHandOff(
      target: destination, layout: PaneState(order: [tabID], focused: tabID, counter: 0),
      detached: [:], agent: [tabID: codingAgentManager.handOff(tabID)])
    if let view {
      let title = view.attachment.metadata.first { $0.key == SessionMetadataKey.title }?.value
      view.attachment.metadata = destination.sessionMetadata(title: title ?? tab.title)
    }
    remove(tabID, from: target.id)
    forgetPerTabWork(tabID)
    // As in `handOff`.
    tabRegistry.release([tabID], by: holder)
    if wasFocused { setFocused(successor, for: target.id) }
    reconcileOcclusion(for: target)
    onEvent?(.tabsRemoved(target.id, [tabID]))
    return handOff
  }

  /// Take in the tabs another window handed off. Into a target this window shows no tabs for,
  /// everything comes as it was: order, splits, focus, numbering, detached panes. Into one it
  /// already shows, they join after its own tabs, its own layout stays, and the moved splits go.
  func adopt(_ handOff: TargetHandOff) {
    let target = handOff.target
    let ids = handOff.tabIDs
    // One layout at a time: the window that handed these off let them go, so nobody else may hold
    // them. One that does would show the same tab, and drive the same surface, in two windows.
    guard tabRegistry.claim(ids, by: holder) else {
      assertionFailure("adopted tabs another window still holds")
      Self.logger.error(
        "adopt refused for \(target.id, privacy: .public): another window holds them")
      return
    }
    let merging = !heldTabs(target.id).isEmpty
    // A target keeps at most one preview: with this window's own, a moved one stays open, pinned.
    let ownPreview = merging && previewTabID(in: target.id) != nil
    openPanes(target.id).updateState { $0.order.append(contentsOf: ids) }
    for id in ids {
      guard let state = tabRegistry.record(id)?.terminal, let view = surface(of: id) else {
        continue
      }
      wire(view, tab: id, target: target)
      if state.sessionID != nil { programStatusBinding.follow(target.hostID) }
    }
    if ownPreview {
      for id in ids where tabRegistry.record(id)?.isPreview == true { persist(id, for: target) }
    }
    detachedTabIDs.formUnion(handOff.detached.keys)
    for (id, agent) in handOff.agent {
      codingAgentManager.adopt(id, banner: agent.banner, failure: agent.failure)
    }
    if !merging {
      setSplits(handOff.layout.splits, for: target.id)
    }
    openPanes(target.id).updateState { $0.raiseCounter(to: handOff.layout.counter ?? 0) }
    let focus =
      handOff.layout.focused.flatMap { detachedTabIDs.contains($0) ? nil : $0 }
      ?? ids.first { !detachedTabIDs.contains($0) }
    if let focus { setFocused(focus, for: target.id, notify: false) }
    for id in ids { refreshProgramStatus(tab: id, target: target.id) }
    for (id, frame) in handOff.detached {
      onEvent?(.paneRestoredDetached(target.id, id, frame: frame))
    }
    reconcileOcclusion(for: target)
  }

  /// Pull a tab out of its group so it's a solo terminal again (drag a chip clear of the group). The
  /// group dissolves if only one member would remain. No-op if the tab isn't in a group.
  func extractFromSplit(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard split(containing: tabID, for: target) != nil else { return }
    // A removal: the survivors keep ratios budgeted for the pane that just left, so even them.
    removeFromGroup(tabID, for: target.id)
    setFocused(tabID, for: target.id)  // show the extracted tab on its own
    reconcileOcclusion(for: target)
  }

  /// Focus a tab (and, if it's a split member, show the split). Single entry point: chip tap, ⌘1–9,
  /// notification routing, neighbour-after-close. `select` is an alias kept for existing call sites.
  func focus(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard let panes = targets[target.id], record(tabID, in: target.id) != nil else { return }
    guard panes.state.focused != tabID else { return }
    setFocused(tabID, for: target.id)
    reconcileOcclusion(for: target)
  }

  /// A *deliberate* tab selection (chip tap, ⌘1–9, next/prev) — `focus` plus a request for the owning
  /// workroom to become the focused split member (via `.surfaceFocused`). Selecting a tab in a
  /// co-displayed but non-focused workroom must move keyboard focus there, mirroring a click into that
  /// pane's body — without this the chip highlights but the terminal never focuses (the renderer keeps
  /// `surfaceActive` false until the workroom is the selected member). Fired *before* `focus` so the
  /// promotion lands even when the tab is already this target's focused tab (where `focus` early-returns)
  /// and so the focus-change history records against the now-correct workroom. A no-op outside a split
  /// or when this target is already the focused member (the store-side guard handles both).
  func select(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    onEvent?(.surfaceFocused(target.id))
    focus(tabID, for: target)
  }

  /// The single write-point for a target's focused tab (issue #26). Centralising the seven former
  /// direct writes means every focus change — `addTab`, splits, drag-into-split, `focus`, and the
  /// close-successor — fires `.focusChanged` so navigation history can record the new location.
  /// `notify: false` is used by `reap` (the target is being torn down; nothing is focused afterward,
  /// and its history entries are skipped at replay instead) and by `restore` (materialising saved
  /// panes is not a navigation). No-op when unchanged.
  ///
  /// Also the recency write-point (issue #132): quick-switcher MRU order and the close-successor
  /// (issue #160) are the same question — "where was the user last" — so both read one list, written
  /// here rather than from the `.focusChanged` observer, which would leave this file's own
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
    // its target's tabs), as a detached tab does. Letting the write through makes `contentLayout`
    // render `.leaf(detached)` back in this window, and `TerminalContainerView.mount` then re-homes
    // the libghostty view out of the detached window — which goes blank. At least six paths reach
    // here: the surface's own `mouseDown` → `.focused` → `select`, `ActivateOnPress` on a content
    // pane, navigation history back/forward, notification routing via `ownerOf(tabID:)`, ⌃Tab's pane
    // switcher, and Files/Changes re-focusing an existing preview tab. Guarding the write-point
    // covers all of them at once; raising the pane's own window is the useful thing to do instead.
    if let tabID, detachedTabIDs.contains(tabID) {
      onEvent?(.paneRaiseRequested(tabID))
      return
    }
    guard let panes = targets[targetID], panes.state.focused != tabID else { return }
    panes.updateState { $0.focused = tabID }
    guard notify else { return }
    recency.recordPane(tabID)
    onEvent?(.focusChanged(targetID, tabID))
  }

  /// Move focus to the adjacent pane in `direction` within the visible split (⌃⌘arrows, issue #3),
  /// wrapping to the far side at the split's edge.
  /// Returns whether focus actually moved, so the key monitor only swallows the event when it acts.
  @discardableResult
  func focusAdjacentPane(_ direction: PaneDirection, for target: TerminalTarget) -> Bool {
    guard let split = split(for: target), let focused = targets[target.id]?.state.focused,
      let next = PaneTreeLayout.adjacentPane(to: focused, direction: direction, in: split)
    else { return false }
    focus(next, for: target)
    return true
  }

  /// Reorder (drag-and-drop in the tab bar): move the dragged tab to `index` in the loose strip order,
  /// clamped to bounds. Display normalisation keeps the split's run contiguous regardless.
  func moveTab(_ draggedID: TerminalTab.ID, toIndex index: Int, for target: TerminalTarget) {
    guard let panes = targets[target.id], panes.state.order.contains(draggedID) else { return }
    panes.updateState { $0.move(draggedID, toIndex: index) }
  }

  /// Set the divider ratio of one split node (the view clamps to the points-based minimum first).
  /// Addressed by the node's own id, so it finds the right group without the caller knowing which.
  func setRatio(_ ratio: CGFloat, forSplit splitID: UUID, for target: TerminalTarget) {
    guard let panes = targets[target.id],
      let set = panes.state.splits.settingRatio(ratio, forSplit: splitID)
    else { return }
    panes.updateState { $0.splits = set }
  }

  /// Close a tab. If it's a split member the split collapses to the surviving sibling subtree (and
  /// dissolves when only one member would remain). Closing the last tab leaves the target with none.
  func closeTab(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard let tab = record(tabID, in: target.id) else { return }
    let wasFocused = targets[target.id]?.state.focused == tabID

    // Compute the focus successor BEFORE mutating, using the on-screen order.
    let successor = closeSuccessor(of: tabID, for: target)

    // Close the detached window first, so it can never outlive the tab it hosts (issue #172).
    undetach(tabID)
    let remote = isRemoteSession(tab)
    // Counted on the service, which outlives this window: a quit right after the window closes
    // still waits for the kill (#297).
    let service = sessionService
    service.closeKillStarted(remote: remote)
    // The task keeps the torn-down surface alive until the session's end is answered, as the tab
    // value it captured did when the tab held its view, so a pane closed from inside one of its own
    // callbacks is never freed under that callback's stack.
    let view = surface(of: tabID)
    Task {
      let ended = await self.endPersistentSession(for: tab)
      withExtendedLifetime(view) {}
      service.closeKillEnded(remote: remote)
      if remote && !ended { self.onEvent?(.remoteCloseFailed(target.id, title: target.title)) }
    }
    teardown(tab)
    // A lone remaining member is not a group any more; two or more get evened, since their dividers
    // still budget space for the pane that just closed (issue #126).
    remove(tabID, from: target.id)
    discard(tabID)
    forgetPerTabWork(tabID)

    if wasFocused { setFocused(successor, for: target.id) }
    recency.forgetPanes([tabID])  // after the successor is picked, before anyone else looks
    reconcileOcclusion(for: target)
    codingAgentManager.tabClosed(tabID)
    onEvent?(.tabsRemoved(target.id, [tabID]))
  }

  /// Terminate and forget every terminal for a target (on delete / when its directory disappears).
  ///
  /// Awaits every persisted session's kill before returning — the caller relies on this to delete
  /// the workroom's directory only after any daemon-held shell has actually exited (issue #7).
  func reap(_ id: TerminalTarget.ID) async {
    let removedIDs = heldTabs(id).map(\.id)
    for removed in removedIDs { undetach(removed) }  // no detached window outlives its tab (#172)
    for tab in heldTabs(id) {
      // Not a remote session: a remote target is reaped as its workroom is deleted, whose teardown
      // destroys the host and the sessions with it. Asking the host first could only hold the
      // delete up, for as long as a request on a link that died while the Mac slept (#283). Its
      // registration goes, so the pane's session is not held for the life of the app. A teardown
      // that fails leaves the host, and these sessions, running; a later delete takes them down.
      if let sessionID = tab.terminal?.sessionID, sessionService.isRemote(sessionID) {
        sessionService.forgetRemoteSession(sessionID)
      } else {
        await endPersistentSession(for: tab)
      }
      teardown(tab)
      forgetPerTabWork(tab.id)
    }
    await sessionService.endSessions(matchingWorkroom: id.encoded)
    // Tabs, order, splits, focus and numbering go at once, without a focus change to report, and
    // the surfaces with them: every tab the target holds now, as its layout goes.
    for held in heldTabs(id) { discard(held.id) }
    targets[id] = nil
    announcedShownSlots[id] = nil
    recency.forgetPanes(removedIDs)
    for removed in removedIDs {
      codingAgentManager.tabClosed(removed)
    }
    if !removedIDs.isEmpty { onEvent?(.tabsRemoved(id, removedIDs)) }
  }

  func reapAll() async {
    for id in Array(targets.keys) { await reap(id) }
  }

  /// Re-theme every live terminal — visible and hidden, solo and split alike — to the active theme
  /// for the current appearance. The per-window terminal step of `ThemeService.applyActiveTheme()`,
  /// which runs it once per registered sink.
  ///
  /// The **app-global** half of the re-theme (rebuild the ghostty config, push the color scheme) is
  /// deliberately NOT here: this is called inside a loop over every window's sessions, so doing it
  /// here meant N windows = N config writes + N parses of the same file on the main thread, each of
  /// which compiles the config's regexes. That amplification showed up as a 2s+ AppHang on an OS
  /// appearance flip (WORKROOM-3R). It now runs once, in `applyActiveTheme`.
  func applyThemeToAll(isDark: Bool) {
    let config = GhosttyApp.shared.config
    for tab in heldTabs {
      // Content tabs have no surface to re-theme.
      guard let surface = surface(of: tab.id) else { continue }
      if let config { surface.updateConfig(config) }
      surface.applyColorScheme(isDark: isDark)
    }
  }

  // MARK: Occlusion (A4 / issue #3)

  /// One reconciliation pass: exactly the on-screen tabs render; every other surface for the target is
  /// paused (its shell keeps running — `setVisible(false)` toggles GPU occlusion, not the PTY). Called
  /// from every state change that can alter what's on screen (focus / split / close / move / reap),
  /// once focus has settled — which is why a pane joining or leaving a split is announced from here.
  func reconcileOcclusion(for target: TerminalTarget) {
    defer { announcePaneCountChange(for: target) }
    let visible = Set(visibleTabIDs(for: target))
    for tabID in targets[target.id]?.state.order ?? [] {
      // Only terminal tabs own a GPU surface to occlude; a content tab (diff) pauses itself by
      // unmounting from the window when it leaves the screen, so there's nothing to toggle here.
      surface(of: tabID)?.setVisible(visible.contains(tabID))
    }
  }

  /// Flash a visible non-focused pane's border to acknowledge activity without a banner/badge (D3).
  /// Driven from `PaneNotifier.handleActivity`.
  func pulsePaneActivity(_ tabID: TerminalTab.ID) {
    activityPulses[tabID, default: 0] += 1
  }

  // MARK: Terminal state (the collaborators' access)

  /// `tabID`'s terminal state while `targetID` holds it; nil for a content tab or a tab not held.
  private func terminalState(
    _ tabID: TerminalTab.ID, in targetID: TerminalTarget.ID
  ) -> TerminalState? {
    record(tabID, in: targetID)?.terminal
  }

  /// Every terminal tab this window holds, with its state, target by target.
  private func terminalStates() -> [(
    target: TerminalTarget.ID, tab: TerminalTab.ID, state: TerminalState
  )] {
    targets.flatMap { targetID, panes in
      tabRegistry.records(panes.state.order).compactMap { tab in
        tab.terminal.map { (targetID, tab.id, $0) }
      }
    }
  }

  /// Mutate the `.terminal` payload of a tab in place and republish (the reassign is what
  /// publishes). A no-op if the tab is missing, isn't a terminal or `target` does not hold it here —
  /// so the OSC callbacks (only ever wired for terminal tabs) stay correct even if a content tab id
  /// is ever passed, and a late answer for a pane that moved on lands nowhere.
  private func mutateTerminalState(
    _ tabID: TerminalTab.ID, target: TerminalTarget.ID, _ body: (inout TerminalState) -> Void
  ) {
    guard var tab = record(tabID, in: target), case .terminal(var s) = tab.content else {
      return
    }
    body(&s)
    tab.content = .terminal(s)
    store(tab)
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
    // floors, evened as the mutation itself evens it, so the guard and the commit can never
    // disagree. The new pane is a placeholder id on the trailing side: the side it lands on mirrors
    // the tree without changing any pane's size, so the guard doesn't need the edge — only the axis
    // and the resulting pane count.
    if let admitted = splitGroups(target.id).admits(
      UUID(), beside: tab.id, edge: orientation == .horizontal ? .right : .bottom,
      policy: splitPolicy(for: target.id))
    {
      return admitted
    }
    // Pre-layout fallback: the pane's own rect (or its surface), judged by the anchor-only rule.
    let rect =
      paneRects[target.id]?[tab.id]
      ?? surface(of: tab.id).map { CGRect(origin: .zero, size: $0.bounds.size) }
    guard let rect else { return true }
    return PaneTreeLayout.canSplit(rect, along: orientation)
  }

  /// `targetID`'s panes, made (empty) when it has none yet. The one place an entry is added, and
  /// where each is wired to send `paneWillChange` before its every change.
  private func openPanes(_ targetID: TerminalTarget.ID) -> TargetPanes<TerminalTab.ID> {
    if let panes = targets[targetID] { return panes }
    let panes = TargetPanes<TerminalTab.ID> { [weak self] in self?.paneWillChange.send() }
    targets[targetID] = panes
    return panes
  }

  /// The target's split groups, empty when it has none.
  private func splitGroups(_ targetID: TerminalTarget.ID) -> PaneSplitGroups<TerminalTab.ID> {
    targets[targetID]?.state.splits ?? PaneSplitGroups()
  }

  /// Store `groups` as the target's split groups. The single funnel every split mutation goes
  /// through; the edits themselves are `PaneSplitGroups`', which leave every group but the one they
  /// touch exactly as it was — the whole point of many groups — and never hand out an index, so
  /// none can be held across a mutation.
  private func setSplits(
    _ groups: PaneSplitGroups<TerminalTab.ID>, for targetID: TerminalTarget.ID
  ) {
    targets[targetID]?.updateState { $0.splits = groups }
  }

  /// How this target's split evens (issue #126): when the setting is on and the measured container
  /// can honour equality, every pane weighing one. The gate is INTENT, not a leaf-count delta: each
  /// mutation knows whether it is adding, removing, or rearranging, and picks the edit that evens
  /// accordingly; the axis limits the even to one direction (`PaneSplitGroups`).
  private func splitPolicy(for targetID: TerminalTarget.ID) -> PaneSplitPolicy<TerminalTab.ID> {
    PaneSplitPolicy(space: paneSpace[targetID], autoEven: autoEvenSplits())
  }

  /// Tell `AppStore` which axes `target`'s shown panes changed along since its last reconcile.
  /// Called from `reconcileOcclusion`, which every split edit and focus change runs last, after
  /// focus has settled. The first reconcile of a target only records what it shows, so a restored
  /// layout keeps its saved workroom dividers. No-op while a respawn holds it, or when the target
  /// shows as many panes each way as before.
  private func announcePaneCountChange(for target: TerminalTarget) {
    guard !holdingPaneCountChanges else { return }
    let after = shownSlots(target.id)
    guard let before = announcedShownSlots.updateValue(after, forKey: target.id) else { return }
    let changed = SplitOrientation.allCases.filter { before[$0] != after[$0] }
    guard !changed.isEmpty else { return }
    onEvent?(.paneCountChanged(target.id, along: changed.count == 1 ? changed[0] : nil))
  }

  /// How many panes `targetID` shows across each axis: its widest row and tallest column
  /// (`maxSlots`) of the group holding the focused tab, or one each way for a solo tab.
  private func shownSlots(_ targetID: TerminalTarget.ID) -> [SplitOrientation: Int] {
    (targets[targetID]?.state ?? PaneState()).shownSlots
  }

  /// Drop `tabID` from whatever group holds it, deleting the group when fewer than two leaves would
  /// remain, and evening the survivors along the axis it left. No-op when the tab is solo. The one
  /// removal path — close, detach, extract and hand-off all route through it (close and hand-off by
  /// way of `remove`), so "a leaving pane collapses its own group, and only its own" exists once
  /// (`PaneState.ungroup`).
  private func removeFromGroup(_ tabID: TerminalTab.ID, for targetID: TerminalTarget.ID) {
    guard let panes = targets[targetID], panes.state.splits.group(containing: tabID) != nil
    else { return }
    let policy = splitPolicy(for: targetID)
    panes.updateState { $0.ungroup(tabID, policy: policy) }
  }

  /// Drop `tabID` from `targetID`'s layout here: its strip slot and its group. The tab itself is
  /// the caller's: a close discards it, a hand-off lets another window take it. Focus is the
  /// caller's too, picked beforehand (`closeSuccessor` reads the order this changes).
  private func remove(_ tabID: TerminalTab.ID, from targetID: TerminalTarget.ID) {
    guard let panes = targets[targetID] else { return }
    let policy = splitPolicy(for: targetID)
    panes.updateState { $0.remove(tabID, policy: policy) }
  }

  /// The tab to focus after `tabID` is closed: the most-recently-focused tab that is still open
  /// (issue #160 — closing lands you back where you were, matching what ⌃Tab calls "the last pane"),
  /// falling back to the on-screen neighbour that slides into the closed tab's slot for tabs recency
  /// has never seen (a restored session), else nil.
  ///
  /// When the closed tab was a split member, only the members that survive it are candidates —
  /// including the lone survivor of a two-pane split, which stops being a split at all. Focus drives
  /// what is on screen (`split(for:)`, `visibleTabIDs`), so landing on a most-recent tab from
  /// outside would sweep a pane the user was looking at a moment ago off screen.
  private func closeSuccessor(of tabID: TerminalTab.ID, for target: TerminalTarget) -> TerminalTab
    .ID?
  {
    (targets[target.id]?.state ?? PaneState()).closeSuccessor(
      of: tabID, hiding: detachedTabIDs, recency: recency.panes.ids)
  }

  private func insert(_ tab: TerminalTab, for target: TerminalTarget) {
    let panes = openPanes(target.id)
    store(tab)
    panes.updateState { $0.order.append(tab.id) }
    liveState.refreshBranch(forTab: tab.id, target: target.id)
  }

  private func insertID(
    _ id: TerminalTab.ID, after other: TerminalTab.ID, for target: TerminalTarget
  ) {
    openPanes(target.id).updateState { $0.place(id, after: other) }
  }

  /// `runSession`: `command` is the project's run command, run by the daemon as a run session
  /// (#522); otherwise a `command` runs in this pane's own process (an Investigate tab).
  private func makeTerminalTab(
    for target: TerminalTarget, cwd: String, command: String? = nil, title: String? = nil,
    sessionID: UUID? = nil, runSession: Bool = false
  ) -> TerminalTab {
    let count = openPanes(target.id).updateState { $0.numberNextTerminal() }
    // A remote workroom's path is a path on its host; this Mac's process starts in the home
    // directory, and the session starts in the path on the far side (`registerRemote`).
    let view = makeView(
      target, target.remoteHost == nil ? cwd : NSHomeDirectory(), command)
    view.isRunSession = runSession
    let inProcess = command != nil && !runSession
    let assignedSessionID =
      target.remoteHost != nil && !inProcess
      ? sessionID ?? UUID()
      : assignedSessionID(persisted: sessionID, inProcessCommand: inProcess)
    // The workroom a session is tagged with is how its daemon's list finds it again: `target.id`
    // for a workroom on this Mac, whose daemon no other Mac reads, and the workroom's own id for a
    // remote one, since `target.id` holds this Mac's project path and another Mac's differs (#255).
    let metadata = target.sessionMetadata(title: title ?? "Terminal \(count)")
    if let host = target.remoteHost, let assignedSessionID {
      // `cwd` is a path on the host here: the target's, or a split's anchor pane's.
      registerRemote(
        assignedSessionID, on: host, workingDirectory: cwd, metadata: metadata,
        runCommand: runSession ? command : nil)
    }
    // The surface attaches through the service this window registers and ends its sessions with,
    // whichever factory made it.
    view.attachment.service = sessionService
    // `sessionID` non-nil means this pane is being rebuilt from a restore payload, so its id names
    // a session that may no longer exist. A fresh pane's id was minted a line ago.
    view.attachment.isRestored = sessionID != nil
    view.attachment.metadata = metadata
    // The tab's facts are what the surface was just told, read back once: its launch and start
    // directory never change. Its session is the tab's alone, which the surface reads below.
    var state = TerminalState(
      defaultTitle: title ?? "Terminal \(count)",
      launch: TerminalLaunch(
        isRunSession: view.isRunSession, runsCommand: view.isRunCommandSurface),
      launchDirectory: view.workingDirectory, sessionID: assignedSessionID)
    if let assignedSessionID {
      programStatusBinding.follow(target.hostID)
      state.programStatus = programStatus.rollup(for: assignedSessionID)
    }
    let tab = TerminalTab(content: .terminal(state))
    // By the tab's id, not through this window's layout: a tab in transit to another window keeps
    // its session, and the tab's id never changes, so this is set once.
    let tabID = tab.id
    view.attachment.tabSessionID = { [tabRegistry] in
      tabRegistry.record(tabID)?.terminal?.sessionID
    }
    // Stored, and so this window's, from the moment it is made: every caller puts it in the
    // target's layout in the same call.
    tabRegistry.register(view, for: tab.id)
    store(tab)
    wire(view, tab: tab.id, target: target)
    return tab
  }

  /// Point `view`'s events and queries at this window's sessions. They name the sessions that own
  /// its tab, so this runs once when a tab is made and again when another window hands the tab over
  /// (issue #444): a moved surface left wired to the window it came from would report its title,
  /// focus and exits to that window, or to nothing once it closes.
  private func wire(_ view: GhosttySurfaceView, tab tabID: TerminalTab.ID, target: TerminalTarget) {
    view.onEvent = { [weak self] event in self?.handle(event, tab: tabID, target: target) }
    // Off hides the right-click menu's "Move to New Window" where panes can't move.
    view.offersWindowToggle = allowsDetach
    view.moveToWorkroomChoices = moveToWorkroomChoices.map { choices in { choices(tabID, target) } }
    if target.remoteHost != nil {
      remoteLinks.wire(view, tab: tabID, target: target)
      return
    }
    let projectPath = target.path
    view.resolveCmdHoverFile = { [weak view] word in
      TerminalLinkOpener.resolvesToFile(word, cwd: view?.lastKnownCwd ?? projectPath)
    }
    view.onOpenURL = { [weak view] url in
      TerminalLinkOpener.handleOpenURL(url, cwd: view?.lastKnownCwd ?? projectPath)
    }
  }

  /// One surface event from tab `tabID`'s surface, handled inline as it is raised (ADR 0021).
  private func handle(_ event: SurfaceEvent, tab tabID: TerminalTab.ID, target: TerminalTarget) {
    let targetID = target.id
    switch event {
    case .activity(let activity):
      onEvent?(.activity(targetID, tabID, activity))
    case .titleChanged(let title):
      liveState.titleChanged(title, tab: tabID, target: targetID)
    case .cwdChanged(let cwd):
      liveState.cwdChanged(cwd, tab: tabID, target: targetID)
    case .commandFinished(let exitCode):
      // Exit code feeds the inline-agent manager (issue #49); the title-clear path (issue #2)
      // ignores it.
      liveState.commandFinished(tab: tabID, target: targetID, exitCode: exitCode)
    case .progressReport(let active, let failed):
      liveState.progressReported(active, failed: failed, tab: tabID, target: targetID)
    // A pane became first responder (click / programmatic focus): make it the selection (issue #3),
    // and route up to the workroom selection so a click into a co-displayed split pane targets that
    // workroom (issue #23 follow-up).
    case .focused:
      guard targets[targetID] != nil else { return }
      focus(tabID, for: target)
      onEvent?(.surfaceFocused(targetID))
    case .effectiveFocusChanged(let focused):
      programStatusBinding.focusChanged(focused, tab: tabID, target: targetID)
    case .windowToggleRequested:
      guard allowsDetach else { return }
      onEvent?(.paneWindowToggleRequested(targetID, tabID))
    case .childExited(let exitCode):
      onEvent?(.childExited(target, tabID, exitCode: exitCode))
    case .closeRequested:
      onEvent?(.closeRequested(target, tabID))
    case .cmdClickFile(let word, let cwd):
      if target.remoteHost != nil {
        remoteLinks.open(word, tab: tabID, target: target)
      } else {
        TerminalLinkOpener.handleCmdClickFile(word, cwd: cwd ?? target.path)
      }
    }
  }

  // MARK: Program status (#358)

  // The binding is `ProgramStatusBinding`'s; these are the calls `AppStore`, the alerts and the
  // views make of it.

  /// Tells `AppStore` what each run tab's session on `change.host` now says (#522).
  func applyRunStatus(_ change: ProgramStatusMonitor.Change) {
    programStatusBinding.applyRunStatus(change)
  }

  /// What the monitor already knows about a run tab that has just appeared (a restore, after its
  /// host's snapshot may have come): its state, or that it is gone once the host has answered.
  func reportRunStatus(tab tabID: TerminalTab.ID, target: TerminalTarget) {
    programStatusBinding.reportRunStatus(tab: tabID, target: target)
  }

  /// A tab pointed at another session (Detached sessions > Active tab) shows that session's
  /// status at once, not the old one's until the new session next changes.
  func refreshProgramStatus(tab tabID: TerminalTab.ID, target targetID: TerminalTarget.ID) {
    programStatusBinding.refreshProgramStatus(tab: tabID, target: targetID)
  }

  /// `tabID`'s own name ("Terminal 2"), never the title its program set: a program renames its
  /// tab freely (Claude Code to its task), so this is the name that always reads as a terminal.
  func defaultTitle(ofTab tabID: TerminalTab.ID, inTarget targetID: TerminalTarget.ID) -> String? {
    terminalState(tabID, in: targetID)?.defaultTitle
  }

  /// The program-status session `tabID` attaches to, if it is a daemon-backed terminal.
  func sessionID(forTab tabID: TerminalTab.ID, inTarget targetID: TerminalTarget.ID) -> UUID? {
    terminalState(tabID, in: targetID)?.sessionID
  }

  /// Every tab attached to `session`, and whether the user is looking at it now.
  func attachments(of session: UUID) -> [(
    target: TerminalTarget.ID, tab: TerminalTab.ID, focused: Bool
  )] {
    programStatusBinding.attachments(of: session)
  }

  /// Clear status (the tab's and the sidebar row's context menu): the escape hatch for a program
  /// that left a stale request behind.
  func clearProgramStatus(tab tabID: TerminalTab.ID, target targetID: TerminalTarget.ID) {
    programStatusBinding.clearProgramStatus(tab: tabID, target: targetID)
  }

  /// The UI-test fixture's seam (`UITestFixture.seedProgramStatus`): a fixture pane has no session
  /// (`TerminalPersistentSessionPolicy`), so give it one and seed its records straight into the
  /// monitor, which then reaches the tab as a real status event would.
  func seedProgramStatusForFixture(
    tab tabID: TerminalTab.ID, target targetID: TerminalTarget.ID, host: HostID = .local,
    records: [ProgramStatusRecord], stale: Bool = false
  ) {
    programStatusBinding.seedForFixture(
      tab: tabID, target: targetID, host: host, records: records, stale: stale)
  }

  // MARK: Remote pane links (#254, C7)

  /// The first of `word`'s candidates that is a file on `target`'s host, or nil
  /// (`RemotePaneLinks.remoteFile`).
  func remoteFile(_ word: String, cwd: String?, target: TerminalTarget) async
    -> TerminalLinkOpener.PathCandidate?
  {
    await remoteLinks.remoteFile(word, cwd: cwd, target: target)
  }

  /// Tear down a tab's surface (clears callbacks before freeing, so no in-flight libghostty callback
  /// touches a dead view). A no-op for a content tab — it owns no surface, so there's nothing to free
  /// (and the refactor therefore frees *strictly fewer* surfaces than before — no new free races).
  private func teardown(_ tab: TerminalTab) { surface(of: tab.id)?.tearDown() }

  func owner(of sessionID: UUID, in target: TerminalTarget) -> TerminalTab.ID? {
    heldTabs(target.id).first { $0.terminal?.sessionID == sessionID }?.id
  }

  func replace(_ tab: TerminalTab, for target: TerminalTarget) {
    update(tab, in: target.id)
  }

  func ownedSessionIDs(for target: TerminalTarget) -> Set<UUID> {
    Set(heldTabs(target.id).compactMap(\.terminal?.sessionID))
  }

  /// Every session ID owned by an open tab across every target in this window.
  var allOwnedSessionIDs: Set<UUID> { Set(heldTabs.compactMap(\.terminal?.sessionID)) }

  /// `reattaches` says whether a target's panes may reattach to this Mac's live sessions now, asked
  /// once the sessions are listed: only a local target that opens here. A missing directory's pane
  /// would reattach out of sight, and a remote workroom's pane is not a session on this Mac — one
  /// that was local last launch would reattach its old shell hidden under a remote row (#253).
  func materializeLivePersistentSessions(
    reattaches: (TerminalTarget.ID) -> Bool,
    load: () async -> [SessionDescriptor]
  ) async {
    var generations: [TerminalTab.ID: (sessionID: UUID?, generation: Int)] = [:]
    for tab in heldTabs {
      if let state = tab.terminal {
        generations[tab.id] = (state.sessionID, state.commandFinishGeneration)
      }
    }
    let live = await load()
    // Which tabs to visit is fixed here: a tab that arrives during the waits below is not one
    // this launch's sessions were listed for.
    let snapshot = targets.mapValues(\.state.order)
    for (target, tabIDs) in snapshot where reattaches(target) {
      for tabID in tabIDs {
        // Earlier panes suspend while attaching. The snapshot can now describe a command that
        // finished or a pane that moved; hydrate only its current model state.
        guard reattaches(target), let tab = record(tabID, in: target),
          let state = tab.terminal, let sessionID = state.sessionID,
          let descriptor = live.first(where: { $0.identifier.uuid == sessionID })
        else { continue }
        // The local PTY belongs to the attach helper, so foreground-process recognition cannot
        // see the agent after a restart. Recover it from the helper's live command metadata;
        // screen repaint alone need not replay the shell's original command title.
        if state.activeCodingAgentBackend == nil,
          generations[tab.id]?.sessionID == sessionID,
          generations[tab.id]?.generation == state.commandFinishGeneration,
          let command = descriptor.value(forMetadataKey: "command"),
          let backend = CodingAgentProcessRecognition.backend(forProcessName: command)
        {
          mutateTerminalState(tab.id, target: target) {
            $0.activeCodingAgentBackend = backend
            if $0.liveTitle == nil { $0.liveTitle = command }
            // The same list carries the Claude profile (#480), so no second request is needed.
            if backend == .claude {
              $0.claudeProfile = PaneLiveState.claudeProfile(from: descriptor)
            }
          }
        }
        guard let view = surface(of: tab.id), view.surface == nil else { continue }
        // A yield alone may immediately re-enter the main actor without an AppKit update. Give
        // display/input a frame between hidden engines; visible panes mount eagerly as usual.
        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        // Closing, moving or reassigning a pane during the new suspension must not recreate it.
        guard reattaches(target), record(tab.id, in: target)?.terminal?.sessionID == sessionID,
          surface(of: tab.id) === view
        else { continue }
        view.ensureSurfaceCreated(initialSize: CGSize(width: 800, height: 480))
      }
    }
  }

  /// A remote pane always has a session: without one the pane would be a plain shell on this Mac
  /// that reads as the remote workroom's. With no driver to reach the host, the session is still
  /// registered against one that holds no host, so the pane says why rather than opening that
  /// shell (`PersistentSessionService.attachCommand`). A boxd, exe.dev or SSH host whose panes open
  /// here always has its driver: the reload adopts its key before its panes mount, and
  /// `existingDriver` makes the driver. Only a container whose runtime isn't on this Mac, or a
  /// record naming no driver this build knows, has none.
  private func registerRemote(
    _ session: UUID, on host: UUID, workingDirectory: String,
    metadata: [(key: String, value: String)], runCommand: String? = nil
  ) {
    let driver =
      RemoteHosts.shared.registry.existingDriver(holding: host) ?? HostDriverRegistry.unreachable
    sessionService.registerRemoteSession(
      session, on: .remote(host), via: driver, workingDirectory: workingDirectory,
      metadata: metadata, runCommand: runCommand)
  }

  private func assignedSessionID(persisted: UUID?, inProcessCommand: Bool) -> UUID? {
    let policy = TerminalPersistentSessionPolicy.usesPersistentSession(
      isAvailable: sessionService.isAvailable,
      inProcessCommand: inProcessCommand,
      hasExistingSession: persisted != nil)
    guard policy else { return nil }
    return persisted ?? UUID()
  }

  /// Whether the tab's session is registered as remote (#283).
  private func isRemoteSession(_ tab: TerminalTab) -> Bool {
    guard let sessionID = tab.terminal?.sessionID else { return false }
    return sessionService.isRemote(sessionID)
  }

  /// End `target`'s background sessions while its tabs stay open, and return them: the Quick
  /// Terminal's at quit, since its shells are not kept and a quit must not free surfaces
  /// (`AppDelegate.applicationWillTerminate`). Counted as close kills, so the quit waits for them.
  @discardableResult
  func endSessionsAtQuit(for target: TerminalTarget) -> [UUID] {
    let service = sessionService
    let ended = allTabs(for: target).compactMap(\.terminal?.sessionID)
    for id in ended {
      service.closeKillStarted(remote: false)
      Task {
        _ = await service.endSession(sessionID: id)
        service.closeKillEnded(remote: false)
      }
    }
    return ended
  }

  @discardableResult
  private func endPersistentSession(for tab: TerminalTab) async -> Bool {
    guard let sessionID = tab.terminal?.sessionID else { return true }
    return await sessionService.endSession(sessionID: sessionID)
  }
}
