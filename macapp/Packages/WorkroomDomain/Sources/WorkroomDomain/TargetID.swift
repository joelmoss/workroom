import Foundation

/// Identifies a place a terminal can open: what its tabs, splits and sessions are keyed by. A
/// sibling of `SidebarID`, not the same type, because the two sets differ: a project row is never
/// a terminal target, and a create's pane is keyed by its run alone, where its sidebar row also
/// names the project.
public enum TargetID: Hashable, Sendable {
  case root(project: String)
  case workroom(project: String, name: String)
  /// A create's pane before its workroom has a name (#483).
  case creation(UUID)
  /// A standalone terminal: one terminal with a row and a workroom tab of its own, belonging to no
  /// project and no terminal group (ADR 0077). Its entry lives in the app's Terminals section.
  case standalone(UUID)
  /// A terminal group: a set of terminals a window selects and uses as it does a workroom, with no
  /// project, branch or worktree behind it (ADR 0077). Its entry lives in the app's Terminals
  /// section, which says whether it is named or built in; the id says only which group it is.
  case terminalGroup(UUID)

  /// The string a target is stored and tagged under: `session.json`, the host layout's local copy,
  /// `Defaults`, a session's workroom tag and a banner's `userInfo`. A stored contract: these bytes
  /// never change.
  public var encoded: String {
    switch self {
    case .root(let project): return "root|\(project)"
    case .workroom(let project, let name): return "wr|\(project)|\(name)"
    case .creation(let id): return "creation:\(id.uuidString)"
    case .standalone(let id): return "standalone:\(id.uuidString)"
    case .terminalGroup(let id): return "group:\(id.uuidString)"
    }
  }

  /// The target `encoded` names, or nil for a string no build has written. A workroom's name never
  /// holds a `|` (the CLI draws it from `[a-zA-Z0-9_-]`), but a project path can, so it splits at
  /// the last one.
  public init?(encoded: String) {
    if encoded.hasPrefix("root|") {
      self = .root(project: String(encoded.dropFirst(5)))
    } else if encoded.hasPrefix("wr|") {
      let rest = encoded.dropFirst(3)
      guard let sep = rest.lastIndex(of: "|") else { return nil }
      self = .workroom(project: String(rest[..<sep]), name: String(rest[rest.index(after: sep)...]))
    } else if encoded.hasPrefix("creation:"),
      let id = UUID(uuidString: String(encoded.dropFirst(9)))
    {
      self = .creation(id)
    } else if encoded.hasPrefix("standalone:"),
      let id = UUID(uuidString: String(encoded.dropFirst(11)))
    {
      self = .standalone(id)
    } else if encoded.hasPrefix("group:"), let id = UUID(uuidString: String(encoded.dropFirst(6))) {
      self = .terminalGroup(id)
    } else {
      return nil
    }
  }

  /// The project a root or workroom belongs to. Nil for a create's pane, whose id names only its
  /// run, a standalone terminal and a terminal group (the Quick Terminal's included), which belong
  /// to none.
  public var projectPath: String? {
    switch self {
    case .root(let project), .workroom(let project, _): return project
    case .creation, .standalone, .terminalGroup: return nil
    }
  }

  /// The sidebar row of a root or workroom, whether or not that row is still listed. Nil for a
  /// create's pane, whose id does not name the project its row needs. A standalone terminal's and a
  /// terminal group's rows are in the Terminals section, the Quick Terminal's first.
  public var sidebarID: SidebarID? {
    switch self {
    case .root(let project): return .root(project: project)
    case .workroom(let project, let name): return .workroom(project: project, name: name)
    case .standalone(let id): return .standalone(id)
    case .terminalGroup(let id): return .terminalGroup(id)
    case .creation: return nil
    }
  }

  /// The Quick Terminal's group, the built-in one (ADR 0077): a terminal group like any other, with
  /// a fixed, well-known id. These bytes never change: they are its sessions' tag and its row's id.
  public static let quickTerminal = TargetID.terminalGroup(quickTerminalGroupID)
  public static let quickTerminalGroupID = UUID(uuidString: "51C10A7E-0D4F-4E6A-9B2C-000000000001")!

  /// The tag an older build's Quick Terminal gave its sessions, before it was a group. No target
  /// parses from it; it is kept only so the launch sweep can end those sessions.
  public static let legacyQuickTerminalTag = "workroom.quickTerminal"
}

/// Ordered and printed as `encoded`, so sorted lists written to disk, the order of run toasts and
/// every interpolation into a log line or key read exactly as they did when the id was that string.
extension TargetID: Comparable, CustomStringConvertible {
  public static func < (lhs: TargetID, rhs: TargetID) -> Bool { lhs.encoded < rhs.encoded }
  public var description: String { encoded }
}

extension SidebarID {
  /// The terminal target this row opens. Nil for a project row, which opens none.
  public var targetID: TargetID? {
    switch self {
    case .root(let project): return .root(project: project)
    case .workroom(let project, let name): return .workroom(project: project, name: name)
    case .creation(_, let id): return .creation(id)
    case .standalone(let id): return .standalone(id)
    case .terminalGroup(let id): return .terminalGroup(id)
    case .project: return nil
    }
  }
}
