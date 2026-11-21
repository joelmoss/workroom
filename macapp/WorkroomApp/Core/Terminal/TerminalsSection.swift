import Defaults
import Foundation
import OSLog
import WorkroomDomain

/// The app's Terminals section: the terminals with no project, in the order the sidebar lists them
/// above the projects (ADR 0077). App-wide, as `ProjectStore` is (ADR 0068): every window's sidebar
/// draws the same rows, while each window keeps its own tabs.
///
/// It answers "does this target exist, and what is it?" for every id in the section, which the
/// window store's resolvers (`AppStore.sidebarID(for:)`, `target(for:)`, `liveSelection(_:)`) ask
/// before they ask the projects. That is how selection, the title bar, splits, saved-window restore,
/// history and the launch sweep pick these targets up.
///
/// Persisted to its own file beside `session.json` (`TerminalsSectionFile`), not in it, because that
/// file holds per-window layouts and this section is the app's.
@MainActor
@Observable
final class TerminalsSection {
  /// Production's instance, over the file beside `session.json`. Tests build their own, in memory
  /// unless they pass a file, through `AppStore`'s init.
  static let shared = TerminalsSection(file: .forCurrentEnvironment())

  /// One row of the section: a standalone terminal, or a terminal group with what the user set on
  /// it. The stored form carries a `kind`, so an older build drops an entry it doesn't know rather
  /// than the whole file.
  enum Entry: Hashable, Sendable {
    case standalone(UUID)
    case group(TerminalGroup)

    var targetID: TargetID {
      switch self {
      case .standalone(let id): return .standalone(id)
      case .group(let group): return .terminalGroup(group.id)
      }
    }

    var sidebarID: SidebarID {
      switch self {
      case .standalone(let id): return .standalone(id)
      case .group(let group): return .terminalGroup(group.id)
      }
    }
  }

  /// The section's rows the user made, top to bottom. The Quick Terminal's group is not one of
  /// them: it is `quickTerminal`, always listed first (`rows`).
  private(set) var entries: [Entry]
  /// The built-in group, the Quick Terminal's (ADR 0077): listed first, and never deleted, moved or
  /// renamed. Only its starting folder and fold change, and are kept in the file.
  private(set) var quickTerminal = TerminalGroup.quickTerminal
  /// Every row the sidebar lists, top to bottom: the Quick Terminal's group, then `entries`.
  var rows: [Entry] { [.group(quickTerminal)] + entries }
  /// Whether the sidebar shows the section folded, as a project folds. Kept in the file.
  var isFolded: Bool {
    didSet { if isFolded != oldValue { save() } }
  }

  @ObservationIgnored private let file: TerminalsSectionFile?
  /// The windows (and, from #661, the Quick Terminal host) that hold these targets' tabs, weakly
  /// (ADR 0068), so a name or a count can be asked across all of them.
  @ObservationIgnored private var holders = WeakList<any TerminalsSectionHolder>()
  /// The last of the regroups queued so far (`enqueueRegroup`): forming, dissolving and deleting
  /// groups run one at a time, each seeing the section the one before left.
  @ObservationIgnored var regroupTail: Task<Void, Never>?
  /// The Quick Terminal's panel, which answers for the built-in group even while it holds none of
  /// its terminals: its row's click slides it in.
  @ObservationIgnored weak var quickTerminalHolder: (any TerminalsSectionHolder)?

  /// Loads `file` synchronously, so the section is known before anything resolves a saved id: the
  /// launch's restore and its orphaned-session sweep both run after this. No file keeps the section
  /// in memory only.
  init(file: TerminalsSectionFile? = nil) {
    self.file = file
    let document = file?.read()
    let stored = document?.entries.compactMap(\.entry) ?? []
    self.entries = stored.filter { $0.targetID != .quickTerminal }
    self.isFolded = document?.folded ?? false
    // Only what can change of it is read back: its id, name and place are fixed.
    for case .group(let group) in stored where group.isBuiltIn {
      quickTerminal.startingFolder = group.startingFolder
      quickTerminal.isFolded = group.isFolded
    }
  }

  // MARK: Holders

  func register(_ holder: any TerminalsSectionHolder) {
    holders.insert(holder)
    holdersDidChange()
  }

  func unregister(_ holder: any TerminalsSectionHolder) {
    holders.remove(holder)
    holdersDidChange()
  }

  /// Bumped a tick after a holder comes or goes, so a row that read every holder's terminals reads
  /// them again (`observedHolders`). Late because a holder registers from its init, and a window's
  /// store is built inside SwiftUI's evaluation, where writing an observed property of this shared
  /// owner hangs the launch.
  private(set) var holderGeneration = 0

  private func holdersDidChange() {
    DispatchQueue.main.async { [weak self] in self?.holderGeneration &+= 1 }
  }

  /// Every window (and, from #661, the Quick Terminal host) holding these targets' tabs now.
  var allHolders: [any TerminalsSectionHolder] { holders.elements }
  /// The same, read so that a holder coming later re-runs the reader: what a sidebar row shows of
  /// every window's terminals reads this.
  var observedHolders: [any TerminalsSectionHolder] {
    _ = holderGeneration
    return holders.elements
  }
  /// The Quick Terminal's panel, read as `observedHolders` is, so its sidebar row lists terminals
  /// that came after the sidebar was first drawn.
  var observedQuickTerminalHolder: (any TerminalsSectionHolder)? {
    _ = holderGeneration
    return quickTerminalHolder
  }
  /// The holder other than `asker` that has `id`'s terminal, if any: the window (or panel) a
  /// standalone terminal is in, which is one at a time.
  func holder(of id: TargetID, other asker: AnyObject) -> (any TerminalsSectionHolder)? {
    holders.elements.first { $0 !== asker && $0.holdsTerminals(forTargetID: id) }
  }

  /// Drops the rows nothing restored, and returns them. A standalone terminal is exactly one live
  /// terminal, so a row no holder has (a crash that lost its window's layout) has nothing to show;
  /// nor has an unnamed group none of whose terminals came back. An unnamed group with one terminal
  /// back is settled as any such group is: that terminal becomes standalone in its place (#659). A
  /// named group is kept empty, so it stays. Run once, at launch, after the saved windows are
  /// restored. Does nothing while no window has registered, which would read every row as empty.
  @discardableResult
  func pruneUnheld() -> [TargetID] {
    guard !holders.elements.isEmpty else { return [] }
    var unheld: [TargetID] = []
    for entry in entries {
      let id = entry.targetID
      switch entry {
      case .standalone:
        if !holders.elements.contains(where: { $0.holdsTerminals(forTargetID: id) }) {
          unheld.append(id)
        }
      case .group(let group) where !group.isKept:
        switch terminalNames(of: id).count {
        case 0: unheld.append(id)
        case 1: settleUnnamedGroup(id)
        default: break
        }
      case .group: break
      }
    }
    for id in unheld { remove(id) }
    return unheld
  }

  // MARK: Rows

  /// Changes the rows in place and saves them once: how the groups' own edits (`+Groups`) write.
  /// The Quick Terminal's group is no entry, so no change here can drop or move it.
  func updateEntries(_ change: (inout [Entry]) -> Void) {
    let before = entries
    change(&entries)
    entries.removeAll { $0.targetID == .quickTerminal }
    if entries != before { save() }
  }

  /// Changes the Quick Terminal's group's starting folder or fold, and saves it. Its id and name
  /// stay what they are.
  func updateQuickTerminal(_ change: (inout TerminalGroup) -> Void) {
    var group = quickTerminal
    change(&group)
    group.name = TerminalGroup.quickTerminal.name
    guard
      group.startingFolder != quickTerminal.startingFolder
        || group.isFolded != quickTerminal.isFolded
    else { return }
    quickTerminal.startingFolder = group.startingFolder
    quickTerminal.isFolded = group.isFolded
    save()
  }

  /// Where in `entries` a row listed just below `anchor` goes: after it, at the top when it is the
  /// Quick Terminal's group, else nil (the end).
  func index(after anchor: TargetID?) -> Int? {
    guard let anchor else { return nil }
    if anchor == .quickTerminal { return 0 }
    return entries.firstIndex { $0.targetID == anchor }.map { $0 + 1 }
  }

  /// Adds a standalone terminal's row, just below `anchor` when that is a row of this section,
  /// else at the end, and returns its target. `id` is fixed only by the UI-test fixture.
  @discardableResult
  func addStandalone(after anchor: TargetID? = nil, id: UUID = UUID()) -> TargetID {
    let entry = Entry.standalone(id)
    if let index = index(after: anchor) {
      entries.insert(entry, at: index)
    } else {
      entries.append(entry)
    }
    save()
    return entry.targetID
  }

  /// Puts `entry` in row `id`'s place: a standalone terminal becoming a group, or a group
  /// dissolving into a standalone terminal (#659). Does nothing when `id` isn't listed.
  func replace(_ id: TargetID, with entry: Entry) {
    updateEntries { entries in
      guard let index = entries.firstIndex(where: { $0.targetID == id }) else { return }
      entries[index] = entry
    }
  }

  /// Drops `id`'s row, if it has one.
  func remove(_ id: TargetID) {
    let before = entries.count
    entries.removeAll { $0.targetID == id }
    if entries.count != before { save() }
  }

  /// Whether `id` names a row of this section, the Quick Terminal's group included.
  func contains(_ id: TargetID) -> Bool {
    id == .quickTerminal || entries.contains { $0.targetID == id }
  }

  /// `id`'s row while it is listed, else nil.
  func sidebarID(for id: TargetID) -> SidebarID? {
    contains(id) ? id.sidebarID : nil
  }

  // MARK: Targets

  /// The live target `sid` opens, or nil when it is not a row of this section.
  ///
  /// A standalone terminal is titled by its terminal's name and starts in "New terminals open in";
  /// a group is titled and started as `TerminalGroup` says. Neither is ever unavailable: they need
  /// nothing but this Mac.
  func target(for sid: SidebarID) -> TerminalTarget? {
    guard let id = sid.targetID, let entry = rows.first(where: { $0.targetID == id }) else {
      return nil
    }
    switch entry {
    case .standalone:
      return TerminalTarget(
        id: id, title: terminalNames(of: id).first ?? Self.untitled,
        path: Self.newTerminalDirectory(), unavailability: nil)
    case .group(let group):
      return TerminalTarget(
        id: id, title: group.title(terminalNames: terminalNames(of: id)),
        path: group.workingDirectory, unavailability: nil)
    }
  }

  /// What a standalone terminal is called before its terminal has a name to give it.
  static let untitled = "Terminal"

  /// The names of `id`'s terminals across every holder, in holder order.
  func terminalNames(of id: TargetID) -> [String] {
    holders.elements.flatMap { $0.terminalNames(forTargetID: id) }
  }

  /// Where a new terminal with no project starts: "New terminals open in", or the home folder when
  /// that is unset or no longer a folder.
  static func newTerminalDirectory() -> String {
    QuickTerminalController.workingDirectory(for: Defaults[.newTerminalDirectory])
  }

  /// Carries the Quick Terminal's "Opens in" folder into "New terminals open in", once. The old key
  /// stays where it is, so an older build the user goes back to still finds it.
  nonisolated static func migrateNewTerminalDirectory(_ suite: UserDefaults) {
    let migrated = "newTerminalDirectory.migrated"
    guard !suite.bool(forKey: migrated) else { return }
    defer { suite.set(true, forKey: migrated) }
    // Empty is unset: `Defaults` registers "" as the default in the process-wide registration
    // domain, which every suite reads through.
    guard suite.string(forKey: "newTerminalDirectory")?.isEmpty ?? true,
      let old = suite.string(forKey: "quickTerminalDirectory"), !old.isEmpty
    else { return }
    suite.set(old, forKey: "newTerminalDirectory")
  }

  // MARK: Saving

  /// The Quick Terminal's group is written first, and only once something of it is set, so a file
  /// that never changed it reads as it did before it was built in.
  private func save() {
    let builtIn = quickTerminal.startingFolder != nil || quickTerminal.isFolded
    file?.write(builtIn ? rows : entries, folded: isFolded)
  }

  /// Waits for the last write to land: the quit path, and tests reading the file back.
  func flush() {
    file?.flush()
  }
}

/// A window, or the Quick Terminal host, that holds tabs of the section's targets.
@MainActor
protocol TerminalsSectionHolder: AnyObject {
  /// The names of this holder's terminals in `targetID`, in tab order; empty when it holds none.
  func terminalNames(forTargetID targetID: TargetID) -> [String]
  /// Makes each of this holder's terminals in `group` a standalone terminal of its own, listed
  /// after `anchor` in turn, and returns the last row it listed (`anchor` when none): a group's
  /// delete, asked of every holder. A terminal that can't be moved stays in the group.
  func releaseTerminals(of group: TargetID, after anchor: TargetID) async -> TargetID
  /// Whether this holder has a terminal in `targetID`, one popped out into a window of its own
  /// included.
  func holdsTerminals(forTargetID targetID: TargetID) -> Bool
  /// Brings this holder forward and shows `targetID`'s terminal in it.
  func revealTerminals(forTargetID targetID: TargetID)
  /// Brings this holder forward and focuses its terminal `tabID` in `targetID`: a waiting mark's
  /// click, or the Quick Terminal's terminal row, in a window that doesn't hold it.
  func revealTerminal(_ tabID: TerminalTab.ID, inTarget targetID: TargetID)
  /// Its panes: what a row in any window shows of the terminals it holds (program status, command
  /// results).
  var terminals: TerminalPanes { get }
  /// The first half of moving this holder's terminals in `targetID` to `newID` in place: retags
  /// their sessions as `newID`'s, so a quit in between reattaches them there. False, with nothing
  /// left retagged, when one can't be; `newID` is `targetID` to undo it.
  func retagTerminals(forTargetID targetID: TargetID, as newID: TargetID) async -> Bool
  /// The second half: hands this holder's terminals in `from` over to `newID`, keeping their
  /// shells, and puts `newID` wherever `from` was in this holder (selection, title-bar order,
  /// side-by-side splits, history). Runs after the section lists `newID`, and may no longer list
  /// `from`, which is why it is passed whole.
  func rehomeTerminals(from: TerminalTarget, to newID: TargetID)
}

extension TerminalsSectionHolder {
  /// A holder that can't move its terminals in place refuses: whatever is being regrouped stays.
  func retagTerminals(forTargetID targetID: TargetID, as newID: TargetID) async -> Bool {
    !holdsTerminals(forTargetID: targetID)
  }

  func rehomeTerminals(from: TerminalTarget, to newID: TargetID) {}
}

// MARK: - The file

/// The section's file, `terminals.json`, beside `session.json`. Versioned and lossy on the rules
/// `SavedLayout` follows: additive changes (a new entry kind, an optional field) never bump
/// `schemaVersion`, an entry this build can't read is dropped alone, and a file from a newer
/// schema is read but never written over.
final class TerminalsSectionFile: @unchecked Sendable {
  struct Document: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    @Lossy var entries: [StoredEntry]
    /// Written only when true, so an unfolded section's file is just its entries.
    var folded: Bool?

    init(
      schemaVersion: Int = Document.currentSchemaVersion, entries: [StoredEntry],
      folded: Bool? = nil
    ) {
      self.schemaVersion = schemaVersion
      self.entries = entries
      self.folded = folded
    }
  }

  /// One entry as stored: its kind and id, and a group's name, starting folder and fold, each
  /// written only when set. The field names are the contract.
  struct StoredEntry: Codable, Sendable, Equatable {
    static let standaloneKind = "standalone"
    static let groupKind = "group"
    var kind: String
    var id: UUID
    var name: String?
    var folder: String?
    var folded: Bool?

    init(_ entry: TerminalsSection.Entry) {
      switch entry {
      case .standalone(let id):
        kind = Self.standaloneKind
        self.id = id
      case .group(let group):
        kind = Self.groupKind
        id = group.id
        name = group.name
        folder = group.startingFolder
        folded = group.isFolded ? true : nil
      }
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      kind = try container.decode(String.self, forKey: .kind)
      id = try container.decode(UUID.self, forKey: .id)
      // A field of the wrong type is read as unset, so one bad value never drops the group.
      name = try? container.decodeIfPresent(String.self, forKey: .name)
      folder = try? container.decodeIfPresent(String.self, forKey: .folder)
      folded = try? container.decodeIfPresent(Bool.self, forKey: .folded)
      // A kind no build of this one's knows is dropped by `@Lossy`, not kept as something else.
      guard entry != nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .kind, in: container, debugDescription: "unknown entry kind \(kind)")
      }
    }

    var entry: TerminalsSection.Entry? {
      switch kind {
      case Self.standaloneKind: return .standalone(id)
      case Self.groupKind:
        return .group(
          TerminalGroup(
            id: id, name: TerminalPanes.cleanedName(name), startingFolder: folder,
            isFolded: folded ?? false))
      default: return nil
      }
    }
  }

  let url: URL
  let isDisabled: Bool
  private var writesDisabled = false
  private let fileManager: FileManager
  private let logger = Logger(subsystem: "com.developwithstyle.workroom", category: "terminals")
  private let queue = DispatchQueue(
    label: "com.developwithstyle.workroom.terminals", qos: .utility)

  init(url: URL, fileManager: FileManager = .default, isDisabled: Bool = false) {
    self.url = url
    self.fileManager = fileManager
    self.isDisabled = isDisabled
  }

  /// The file beside `sessionURL`.
  static func beside(sessionURL: URL) -> URL {
    sessionURL.deletingLastPathComponent().appendingPathComponent("terminals.json")
  }

  /// Production's file beside the real `session.json`; under unit tests a disabled one, and in
  /// fixture mode the file beside the session file a UI test names, else a disabled one, the same
  /// isolation `SavedLayoutStore.forCurrentEnvironment` applies.
  static func forCurrentEnvironment() -> TerminalsSectionFile {
    let session = SavedLayoutStore.forCurrentEnvironment()
    return TerminalsSectionFile(
      url: beside(sessionURL: session.url), isDisabled: session.isDisabled)
  }

  /// The document the file holds, or nil when there is none this build can use.
  func read() -> Document? {
    guard !isDisabled, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
    guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
      logger.error("terminals file could not be decoded")
      return nil
    }
    if document.schemaVersion > Document.currentSchemaVersion {
      // Read what this build understands, and never write over what it doesn't.
      writesDisabled = true
    }
    return document
  }

  func write(_ entries: [TerminalsSection.Entry], folded: Bool = false) {
    guard !isDisabled, !writesDisabled else { return }
    let document = Document(entries: entries.map(StoredEntry.init), folded: folded ? true : nil)
    queue.async { [weak self] in self?.persist(document) }
  }

  func flush() {
    queue.sync {}
  }

  private func persist(_ document: Document) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      let data = try encoder.encode(document)
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    } catch {
      logger.error("terminals file could not be written: \(error.localizedDescription)")
    }
  }
}
