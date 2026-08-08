import Foundation

/// The on-disk shape of a saved session — the open panels, split layouts, and windows restored on
/// the next launch (issue #46). Written by `SessionStore` to
/// `Application Support/Workroom/<bundle id>/session.json`.
///
/// **Every type here is a hand-written mirror.** No runtime type (`PaneLayout`, `TerminalTab`,
/// `SidebarID`, the content descriptors) gains `Codable`, so the file format is never hostage to an
/// internal field rename — the same stored-data-contract rule `RunConfig` carries in
/// `DefaultsKeys.swift`. The field names below ARE the contract; renaming one silently invalidates
/// every user's saved session.
///
/// # Versioning rule — read before bumping `schemaVersion`
///
/// **Additive changes NEVER bump `schemaVersion`.** Adding a tab kind, or adding an optional field,
/// is additive. Only a breaking reshape bumps.
///
/// This is what makes the lossy decoding below load-bearing rather than decorative: a Nightly build
/// writes a fifth tab kind, the user rolls back to stable, and stable drops that one tab while
/// restoring everything else. Bump the version for an additive kind and the whole file is discarded
/// before the lossy path ever runs — deleting every user's session for no reason.
///
/// The same split the app already draws between versioning a key (`inspector.layout.v2`) and
/// reconciling a shape (`AppStore.reconcileInspectorState`): version to discard, reconcile to keep.
///
/// A **newer** `schemaVersion` is read-only: restore nothing AND write nothing for that run, or an
/// older build silently destroys a newer one's session on its next save. Three build identities ship
/// side by side (Workroom, Workroom Dev, Workroom Nightly), so that rollback is a real path.
///
/// # What is deliberately absent
///
/// - **The PTY and child processes.** A restored terminal is a fresh login shell in the remembered
///   directory; the process it was running is gone. (Its *text* does come back — scrollback lives in
///   sidecar files beside this document, never inside it. See `SessionStore` and issue #144.)
/// - **Run tabs.** Restoring one would resurrect a dev server with no `AppStore.RunState` behind it —
///   an untracked process orphaned on its port, the failure `WindowRegistry.runOwner(for:excluding:)`
///   and issue #7 exist to prevent. `Defaults[.runCommands]` already survives, and `RunConfig.autoRun`
///   is the deliberate opt-in.
/// - **`liveTitle` / `progressActive` / activity pulses.** Display state about a process that no
///   longer exists. Excluding them is also what keeps the save digest stable: a terminal animating
///   its title produces a byte-identical snapshot, so it costs a comparison and no disk write.
/// - **Navigation history.** Its entries key on tab ids, which restore re-mints by design.

// MARK: - Limits

/// Bounds on what a session file may ask the app to allocate at launch. These are a real ceiling,
/// not decoration: restore materialises every target's tab models eagerly (the sidebar's terminal
/// subtree renders from them), so a hostile or corrupt file could otherwise allocate tens of
/// thousands of views before the first frame. Anything dropped is logged — silent truncation reads
/// as full coverage.
enum SessionLimits {
  static let maxWindows = 8
  static let maxTargetsPerWindow = 20
  static let maxTabsPerTarget = 20
  /// Split trees are user-built by repeated ⌘D; a dozen levels is far past any real layout, and the
  /// cap is what stops a hand-edited file recursing `materialize` into the stack.
  static let maxSplitDepth = 12
  /// Refused before decoding — array caps bound element *counts*, not the size of one giant string.
  static let maxFileBytes = 512 * 1024
  /// Clamps paths, titles, and commit ids individually.
  static let maxStringLength = 4096
  /// Per-pane scrollback kept in a sidecar file (issue #144). The value is overwhelmingly at the
  /// recent end, and a cap keeps the quit path bounded no matter how much a pane logged.
  static let maxScrollbackBytes = 256 * 1024
  /// A sidecar larger than this on disk is corrupt by definition — twice the cap, so a legitimate
  /// file can never trip it.
  static let maxScrollbackFileBytes = 512 * 1024
}

// MARK: - Lossy array decoding

/// An array that drops the elements it cannot decode instead of failing the whole document.
///
/// This is the single most valuable primitive in the schema: it turns "a newer build wrote a tab kind
/// this build has never heard of" from *your entire session is gone* into *one tab is missing*. It
/// only pays because additive changes do not bump `schemaVersion` (see the file header) — otherwise
/// the envelope check discards the file before any element is examined.
@propertyWrapper
struct Lossy<Element: Codable & Sendable>: Codable, Sendable {
  var wrappedValue: [Element]

  init(wrappedValue: [Element]) { self.wrappedValue = wrappedValue }

  /// Consumes exactly one element of any shape. Decoding a *failed* element does not advance an
  /// `UnkeyedDecodingContainer`, so a permissive type has to consume it or the loop never progresses.
  private struct AnyElement: Decodable {
    init(from decoder: Decoder) throws { _ = decoder }
  }

  init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var decoded: [Element] = []
    while !container.isAtEnd {
      let indexBefore = container.currentIndex
      do {
        decoded.append(try container.decode(Element.self))
      } catch {
        _ = try? container.decode(AnyElement.self)
      }
      // Belt and braces: if neither the decode nor the skip advanced the cursor, stop rather than
      // spin forever on a container shape we did not anticipate.
      if container.currentIndex == indexBefore { break }
    }
    wrappedValue = decoded
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    for element in wrappedValue { try container.encode(element) }
  }
}

extension Lossy: Equatable where Element: Equatable {}
extension Lossy: Hashable where Element: Hashable {}

extension KeyedDecodingContainer {
  /// Makes an absent lossy array decode to empty rather than throwing, so a field added in a later
  /// version is readable by a build that predates it.
  func decode<T>(_ type: Lossy<T>.Type, forKey key: Key) throws -> Lossy<T> {
    try decodeIfPresent(type, forKey: key) ?? Lossy(wrappedValue: [])
  }
}

// MARK: - Layout tree

/// The Codable mirror of `PaneLayout`, generic over its leaf address (a tab key, or a target-id
/// string for the workroom split). Hand-written with an explicit `kind` discriminator so the on-disk
/// format is a contract THIS file owns, not whatever Swift synthesises for an indirect enum with
/// associated values.
///
/// `PaneLayout`'s per-split `UUID` is deliberately NOT persisted: it addresses a divider during a
/// drag and nothing refers to it across a launch. `materialize` mints a fresh one.
indirect enum LayoutNode<Leaf: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
  case leaf(Leaf)
  case split(orientation: String, ratio: Double, first: LayoutNode, second: LayoutNode)

  static var horizontal: String { "horizontal" }
  static var vertical: String { "vertical" }

  private enum CodingKeys: String, CodingKey {
    case kind, leaf, orientation, ratio, first, second
  }
  private enum Kind: String, Codable {
    case leaf, split
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .leaf:
      self = .leaf(try container.decode(Leaf.self, forKey: .leaf))
    case .split:
      self = .split(
        orientation: try container.decode(String.self, forKey: .orientation),
        ratio: try container.decode(Double.self, forKey: .ratio),
        first: try container.decode(LayoutNode.self, forKey: .first),
        second: try container.decode(LayoutNode.self, forKey: .second))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .leaf(let leaf):
      try container.encode(Kind.leaf, forKey: .kind)
      try container.encode(leaf, forKey: .leaf)
    case .split(let orientation, let ratio, let first, let second):
      try container.encode(Kind.split, forKey: .kind)
      try container.encode(orientation, forKey: .orientation)
      try container.encode(ratio, forKey: .ratio)
      try container.encode(first, forKey: .first)
      try container.encode(second, forKey: .second)
    }
  }

  /// Every leaf address in reading order — the counterpart of `PaneLayout.tabIDs`, used to validate
  /// a decoded tree against the tabs that actually survived.
  var leaves: [Leaf] {
    switch self {
    case .leaf(let leaf): return [leaf]
    case .split(_, _, let first, let second): return first.leaves + second.leaves
    }
  }

  /// Depth of the deepest split, so a hand-edited tree can be rejected before `materialize` walks it.
  var depth: Int {
    switch self {
    case .leaf: return 1
    case .split(_, _, let first, let second): return 1 + max(first.depth, second.depth)
    }
  }
}

extension LayoutNode {
  /// Runtime tree → snapshot tree. `address` maps a runtime leaf to its persisted key; a leaf that
  /// maps to nil is dropped and its parent collapses to the surviving sibling — the same collapse
  /// rule as `PaneLayout.removingLeaf`.
  ///
  /// Returns nil when fewer than two leaves survive, mirroring `materialize`: a lone leaf is not a
  /// split, and writing one would put a shape in the file that the live model cannot hold. Excluding
  /// a run tab from a two-pane split is exactly this case.
  static func capture<L: Hashable>(
    _ layout: PaneLayout<L>, address: (L) -> Leaf?
  ) -> LayoutNode? {
    guard let tree = captureNode(layout, address: address) else { return nil }
    guard case .split = tree else { return nil }
    return tree
  }

  private static func captureNode<L: Hashable>(
    _ layout: PaneLayout<L>, address: (L) -> Leaf?
  ) -> LayoutNode? {
    switch layout {
    case .leaf(let id):
      return address(id).map { .leaf($0) }
    case .split(_, let orientation, let ratio, let first, let second):
      let capturedFirst = captureNode(first, address: address)
      let capturedSecond = captureNode(second, address: address)
      switch (capturedFirst, capturedSecond) {
      case (let first?, let second?):
        return .split(
          orientation: orientation == .horizontal ? horizontal : vertical,
          ratio: Double(ratio), first: first, second: second)
      // A split with one surviving child is not a split — it IS that child (`PaneLayout`'s
      // "a lone leaf is not a split" invariant, enforced at the boundary rather than left to callers).
      case (let only?, nil), (nil, let only?):
        return only
      case (nil, nil):
        return nil
      }
    }
  }

  /// Snapshot tree → runtime tree. `resolve` maps a persisted key to a live leaf; unresolvable leaves
  /// collapse into their sibling. Returns nil when fewer than two leaves survive, so a caller can
  /// never be handed a one-leaf "split".
  func materialize<L: Hashable>(_ resolve: (Leaf) -> L?) -> PaneLayout<L>? {
    guard let tree = materializeNode(resolve, depth: 0) else { return nil }
    guard case .split = tree else { return nil }
    return tree
  }

  private func materializeNode<L: Hashable>(
    _ resolve: (Leaf) -> L?, depth: Int
  ) -> PaneLayout<L>? {
    guard depth < SessionLimits.maxSplitDepth else { return nil }
    switch self {
    case .leaf(let key):
      return resolve(key).map { .leaf($0) }
    case .split(let orientation, let ratio, let first, let second):
      guard let resolvedOrientation = Self.orientation(from: orientation) else { return nil }
      let resolvedFirst = first.materializeNode(resolve, depth: depth + 1)
      let resolvedSecond = second.materializeNode(resolve, depth: depth + 1)
      switch (resolvedFirst, resolvedSecond) {
      case (let first?, let second?):
        return .split(
          id: UUID(), orientation: resolvedOrientation,
          ratio: PaneRatio.sanitize(CGFloat(ratio)), first: first, second: second)
      case (let only?, nil), (nil, let only?):
        return only
      case (nil, nil):
        return nil
      }
    }
  }

  /// An unrecognised orientation rejects the split (its tabs survive as solo panes) rather than
  /// guessing a layout the user never chose.
  private static func orientation(from raw: String) -> SplitOrientation? {
    switch raw {
    case horizontal: return .horizontal
    case vertical: return .vertical
    default: return nil
    }
  }
}

// MARK: - Tab payloads

/// A restored terminal: a fresh login shell in the remembered directory, titled as it was.
struct TerminalPayload: Codable, Hashable, Sendable {
  /// The stable "Terminal N" title, never the live OSC title — that describes a dead process.
  var defaultTitle: String
  /// The LAST REPORTED working directory, which is the whole value of restoring a terminal (not the
  /// directory the tab was originally opened at). Falls back to the target path when it no longer
  /// exists, since libghostty cannot spawn into a missing directory.
  var cwd: String?
}

/// `DiffSource` on disk. Split into a kind plus an optional commit id so a new case is an additive
/// change (unknown kind ⇒ that one tab drops) rather than a reshape.
struct DiffSourcePayload: Codable, Hashable, Sendable {
  var kind: String
  var commit: String?

  static let gitWorktree = "gitWorktree"
  static let jjWorkingCopy = "jjWorkingCopy"
  static let jjParent = "jjParent"
  static let commitKind = "commit"

  /// Exhaustive on purpose — a fifth `DiffSource` case must be a compile error here, not a tab that
  /// silently stops persisting.
  init(_ source: DiffSource) {
    switch source {
    case .gitWorktree: self.init(kind: Self.gitWorktree, commit: nil)
    case .jjWorkingCopy: self.init(kind: Self.jjWorkingCopy, commit: nil)
    case .jjParent: self.init(kind: Self.jjParent, commit: nil)
    case .commit(let id): self.init(kind: Self.commitKind, commit: id)
    }
  }

  init(kind: String, commit: String?) {
    self.kind = kind
    self.commit = commit
  }

  var source: DiffSource? {
    switch kind {
    case Self.gitWorktree: return .gitWorktree
    case Self.jjWorkingCopy: return .jjWorkingCopy
    case Self.jjParent: return .jjParent
    case Self.commitKind: return commit.map { .commit($0) }
    default: return nil
    }
  }
}

struct DiffPayload: Codable, Hashable, Sendable {
  var path: String
  /// `ChangedFile.Change.rawValue`. Re-resolved by the status sweep after restore
  /// (`AppStore.refreshOpenDiffChangeKinds`), so a stale value self-heals.
  var change: String
  var source: DiffSourcePayload
  var isPreview: Bool
  /// `DiffViewMode.rawValue` — the per-tab unified/side-by-side override, nil to follow the global.
  var viewMode: String?
}

struct FilePayload: Codable, Hashable, Sendable {
  var path: String
  var isPreview: Bool
  /// The per-tab Markdown source/preview override, nil for the default (rendered).
  var markdownPreview: Bool?
}

struct ChangesetPayload: Codable, Hashable, Sendable {
  var commitID: String
  var title: String
  var isPreview: Bool
  /// The selected file within the commit.
  var selectedPath: String?
}

/// One pane. Flat with optional payloads rather than an enum-with-associated-values on purpose: an
/// unknown `kind`, or a kind missing its required payload, drops THAT tab and keeps its siblings,
/// where a synthesised enum decoder would throw and take the whole target with it.
struct TabSession: Codable, Hashable, Sendable {
  /// Unique within its `TargetSession`, and the address the split tree and `focusedKey` point at.
  ///
  /// This is a join key valid only inside one snapshot — **never a cross-launch identity**. Restore
  /// mints fresh `TerminalTab.ID`s, because a tab id is unique across *windows* at runtime and
  /// notification routing (`WindowRegistry.ownerOf(tabID:)`) depends on that.
  ///
  /// Tabs are keyed rather than index-addressed because lossy decoding drops elements: with indices,
  /// dropping tab 2 of 5 would silently re-point every later split leaf at the wrong pane. Do not
  /// "simplify" this back to indices.
  var key: String
  var kind: String
  var terminal: TerminalPayload?
  var diff: DiffPayload?
  var file: FilePayload?
  var changeset: ChangesetPayload?

  static let terminalKind = "terminal"
  static let diffKind = "diff"
  static let fileKind = "file"
  static let changesetKind = "changeset"

  /// Whether this tab carries the payload its kind requires. An unknown kind, or a `.diff` with no
  /// diff payload, is dropped at materialise.
  var isWellFormed: Bool {
    switch kind {
    case Self.terminalKind: return terminal != nil
    case Self.diffKind: return diff != nil
    case Self.fileKind: return file != nil
    case Self.changesetKind: return changeset != nil
    default: return false
    }
  }
}

// MARK: - Target, window, file

/// One terminal target's panes: its tabs in strip order, its split, and what was focused.
struct TargetSession: Codable, Hashable, Sendable {
  /// `TerminalTarget.ID` — "wr|<project>|<name>" or "root|<project>". The same encoding
  /// `Defaults[.sidebarSelection]` and `workroomTabOrder` already use, resolved back through
  /// `AppStore.sidebarID(forTargetID:in:)`, which drops ids that no longer exist.
  var targetID: String
  /// Strip order. The array IS the order — no second field to fall out of sync with it.
  @Lossy var tabs: [TabSession]
  /// Leaves are `TabSession.key`. Nil when the target has no split.
  var split: LayoutNode<String>?
  var focusedKey: String?
  /// `TerminalSessions.counts` — so the next ⌘T after restoring "Terminal 3" is "Terminal 4".
  var terminalCounter: Int?

  init(
    targetID: String, tabs: [TabSession], split: LayoutNode<String>? = nil,
    focusedKey: String? = nil, terminalCounter: Int? = nil
  ) {
    self.targetID = targetID
    self.tabs = tabs
    self.split = split
    self.focusedKey = focusedKey
    self.terminalCounter = terminalCounter
  }
}

/// One window's whole restorable state.
struct WindowSession: Codable, Hashable, Sendable {
  /// Cross-launch window identity — the `WindowSeed.id` a window claims and then keeps. Windows have
  /// no such identity natively: `WindowSeed.launch` mints a fresh UUID on every access.
  var windowKey: String
  /// `NSStringFromRect`. Authoritative over `Defaults[.mainWindowFrame]`, which only ever held one
  /// window's frame and is now the cold-start fallback. Clamped to a visible screen on restore.
  var frame: String?
  /// Whether this was the key window, so the user lands where they left off.
  var isKey: Bool
  /// `TerminalTarget.ID` of the selected workroom. Authoritative over `Defaults[.sidebarSelection]`,
  /// which is the single-slot cold-start fallback for a first launch with no session.
  var selectedTargetID: String?
  @Lossy var targets: [TargetSession]
  /// `AppStore.workroomSplits` — leaves are `TerminalTarget.ID` strings. Several disjoint groups can
  /// coexist; each needs two or more live leaves to survive.
  @Lossy var workroomSplits: [LayoutNode<String>]
  /// `AppStore.expandedTerminalTargets` — which sidebar terminal subtrees are open.
  var expandedTargets: [String]?

  init(
    windowKey: String, frame: String? = nil, isKey: Bool = false,
    selectedTargetID: String? = nil, targets: [TargetSession] = [],
    workroomSplits: [LayoutNode<String>] = [], expandedTargets: [String]? = nil
  ) {
    self.windowKey = windowKey
    self.frame = frame
    self.isKey = isKey
    self.selectedTargetID = selectedTargetID
    self.targets = targets
    self.workroomSplits = workroomSplits
    self.expandedTargets = expandedTargets
  }
}

/// The document `session.json` holds.
struct SessionFile: Codable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var savedAt: Date
  /// Diagnostics only — never branched on. Read it in a bug report, not in code.
  var appVersion: String?
  @Lossy var windows: [WindowSession]

  init(
    schemaVersion: Int = SessionFile.currentSchemaVersion, savedAt: Date,
    appVersion: String? = nil, windows: [WindowSession]
  ) {
    self.schemaVersion = schemaVersion
    self.savedAt = savedAt
    self.appVersion = appVersion
    self.windows = windows
  }

  /// How a decoded file relates to what this build can do.
  enum Compatibility: Equatable {
    /// Readable and writable.
    case current
    /// Written by a newer build: restore nothing AND write nothing, or this build's next save
    /// destroys a session it could not understand.
    case newer
    /// Written by an older schema with no migration — discard.
    case unreadable
  }

  var compatibility: Compatibility {
    if schemaVersion == Self.currentSchemaVersion { return .current }
    return schemaVersion > Self.currentSchemaVersion ? .newer : .unreadable
  }
}

// MARK: - Structural validation

/// What `sanitized()` threw away, so the caller can log it. Caps and validation that drop work
/// silently read as full coverage — this is what stops that.
struct SessionSanitizeReport: Equatable {
  var droppedWindows = 0
  var droppedTargets = 0
  var droppedTabs = 0
  var droppedSplits = 0

  var isEmpty: Bool {
    droppedWindows == 0 && droppedTargets == 0 && droppedTabs == 0 && droppedSplits == 0
  }

  var summary: String {
    "windows: \(droppedWindows), targets: \(droppedTargets), tabs: \(droppedTabs), "
      + "splits: \(droppedSplits)"
  }
}

extension SessionFile {
  /// Enforce every structural invariant restore depends on, and report what that cost.
  ///
  /// Array caps bound element *counts*; they do nothing about a hostile or corrupt *shape*. The real
  /// hazard is duplicate keys: restore builds dictionaries from `windowKey` / `targetID` / tab `key`,
  /// so a duplicate would silently redirect a split leaf or the focus to the wrong pane — a
  /// wrong-content bug with no crash to point at. First occurrence wins; the rest are dropped.
  ///
  /// Pure and `nonisolated`, so it is unit-testable without an `AppStore`, a window, or a file —
  /// the shape `AppStore.reconcileInspectorState` established.
  func sanitized() -> (file: SessionFile, report: SessionSanitizeReport) {
    var report = SessionSanitizeReport()
    var seenWindowKeys = Set<String>()
    var windows: [WindowSession] = []

    for window in self.windows {
      guard windows.count < SessionLimits.maxWindows else {
        report.droppedWindows += 1
        continue
      }
      guard seenWindowKeys.insert(window.windowKey).inserted else {
        report.droppedWindows += 1
        continue
      }
      windows.append(window.sanitized(into: &report))
    }

    var sanitized = self
    sanitized.windows = windows
    return (sanitized, report)
  }
}

extension WindowSession {
  fileprivate func sanitized(into report: inout SessionSanitizeReport) -> WindowSession {
    var seenTargetIDs = Set<String>()
    var targets: [TargetSession] = []

    for target in self.targets {
      guard targets.count < SessionLimits.maxTargetsPerWindow else {
        report.droppedTargets += 1
        continue
      }
      guard seenTargetIDs.insert(target.targetID).inserted else {
        report.droppedTargets += 1
        continue
      }
      guard let sanitized = target.sanitized(into: &report) else {
        report.droppedTargets += 1
        continue
      }
      targets.append(sanitized)
    }

    // A workroom-split group needs two or more distinct leaves to be a group at all, and a tree
    // deeper than the cap is rejected whole rather than walked.
    var splits: [LayoutNode<String>] = []
    for split in workroomSplits {
      let leaves = split.leaves
      guard split.depth <= SessionLimits.maxSplitDepth, leaves.count >= 2,
        Set(leaves).count == leaves.count
      else {
        report.droppedSplits += 1
        continue
      }
      splits.append(split)
    }

    var window = self
    window.targets = targets
    window.workroomSplits = splits
    window.frame = frame.map { String($0.prefix(SessionLimits.maxStringLength)) }
    window.selectedTargetID = selectedTargetID.map {
      String($0.prefix(SessionLimits.maxStringLength))
    }
    window.expandedTargets = expandedTargets.map { expanded in
      Array(Set(expanded)).sorted().map { String($0.prefix(SessionLimits.maxStringLength)) }
    }
    return window
  }
}

extension TargetSession {
  /// Nil when nothing usable survives — never an empty target, which would make
  /// `TerminalSessions.ensureTab`'s "has this target been seeded?" check lie.
  fileprivate func sanitized(into report: inout SessionSanitizeReport) -> TargetSession? {
    var seenKeys = Set<String>()
    var tabs: [TabSession] = []
    var sawPreview = false

    for tab in self.tabs {
      guard tabs.count < SessionLimits.maxTabsPerTarget else {
        report.droppedTabs += 1
        continue
      }
      guard tab.isWellFormed, seenKeys.insert(tab.key).inserted else {
        report.droppedTabs += 1
        continue
      }
      var tab = tab.clamped()
      // At most one preview tab per target (`TerminalSessions.previewTabID`). A hand-edited file
      // with two would give the target two italic chips and an ambiguous retarget slot; keep the
      // first and persist the rest.
      if tab.isPreview {
        if sawPreview {
          tab.clearPreview()
        } else {
          sawPreview = true
        }
      }
      tabs.append(tab)
    }

    guard !tabs.isEmpty else { return nil }

    let liveKeys = Set(tabs.map(\.key))
    var split = self.split
    if let candidate = split {
      let leaves = candidate.leaves
      let resolvable = leaves.filter { liveKeys.contains($0) }
      if candidate.depth > SessionLimits.maxSplitDepth || Set(leaves).count != leaves.count
        || resolvable.count < 2
      {
        // The split does not survive, but its tabs do — they simply render as solo panes.
        report.droppedSplits += 1
        split = nil
      }
    }

    var target = self
    target.tabs = tabs
    target.split = split
    target.focusedKey = focusedKey.flatMap { liveKeys.contains($0) ? $0 : nil }
    target.targetID = String(targetID.prefix(SessionLimits.maxStringLength))
    return target
  }
}

extension TabSession {
  /// A preview flag is not identity, so clearing it keeps the tab rather than dropping it.
  fileprivate var isPreview: Bool {
    diff?.isPreview ?? file?.isPreview ?? changeset?.isPreview ?? false
  }

  fileprivate mutating func clearPreview() {
    diff?.isPreview = false
    file?.isPreview = false
    changeset?.isPreview = false
  }

  /// Clamp every free-form string. One giant path in an otherwise sane file is exactly what the
  /// element caps cannot catch.
  fileprivate func clamped() -> TabSession {
    func clamp(_ value: String) -> String { String(value.prefix(SessionLimits.maxStringLength)) }
    func clamp(_ value: String?) -> String? { value.map(clamp) }

    var tab = self
    tab.key = clamp(key)
    tab.kind = clamp(kind)
    if var terminal = tab.terminal {
      terminal.defaultTitle = clamp(terminal.defaultTitle)
      terminal.cwd = clamp(terminal.cwd)
      tab.terminal = terminal
    }
    if var diff = tab.diff {
      diff.path = clamp(diff.path)
      diff.source.commit = clamp(diff.source.commit)
      tab.diff = diff
    }
    if var file = tab.file {
      file.path = clamp(file.path)
      tab.file = file
    }
    if var changeset = tab.changeset {
      changeset.commitID = clamp(changeset.commitID)
      changeset.title = clamp(changeset.title)
      changeset.selectedPath = clamp(changeset.selectedPath)
      tab.changeset = changeset
    }
    return tab
  }
}
