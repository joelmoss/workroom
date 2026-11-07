import Foundation

/// Identifies a place a terminal can open: what its tabs, splits and sessions are keyed by. A
/// sibling of `SidebarID`, not the same type, because the two sets differ: a project row is never
/// a terminal target, the Quick Terminal is one with no sidebar row, and a create's pane is keyed
/// by its run alone, where its sidebar row also names the project.
public enum TargetID: Hashable, Sendable {
  case root(project: String)
  case workroom(project: String, name: String)
  /// A create's pane before its workroom has a name (#483).
  case creation(UUID)
  /// The Quick Terminal's one target, which belongs to no project.
  case quickTerminal

  /// The string a target is stored and tagged under: `session.json`, the host layout's local copy,
  /// `Defaults`, a session's workroom tag and a banner's `userInfo`. A stored contract: these bytes
  /// never change.
  public var encoded: String {
    switch self {
    case .root(let project): return "root|\(project)"
    case .workroom(let project, let name): return "wr|\(project)|\(name)"
    case .creation(let id): return "creation:\(id.uuidString)"
    case .quickTerminal: return "workroom.quickTerminal"
    }
  }

  /// The target `encoded` names, or nil for a string no build has written. A workroom's name never
  /// holds a `|` (the CLI draws it from `[a-zA-Z0-9_-]`), but a project path can, so it splits at
  /// the last one.
  public init?(encoded: String) {
    if encoded == "workroom.quickTerminal" {
      self = .quickTerminal
    } else if encoded.hasPrefix("root|") {
      self = .root(project: String(encoded.dropFirst(5)))
    } else if encoded.hasPrefix("wr|") {
      let rest = encoded.dropFirst(3)
      guard let sep = rest.lastIndex(of: "|") else { return nil }
      self = .workroom(project: String(rest[..<sep]), name: String(rest[rest.index(after: sep)...]))
    } else if encoded.hasPrefix("creation:"),
      let id = UUID(uuidString: String(encoded.dropFirst(9)))
    {
      self = .creation(id)
    } else {
      return nil
    }
  }

  /// The project a root or workroom belongs to. Nil for a create's pane, whose id names only its
  /// run, and the Quick Terminal.
  public var projectPath: String? {
    switch self {
    case .root(let project), .workroom(let project, _): return project
    case .creation, .quickTerminal: return nil
    }
  }

  /// The sidebar row of a root or workroom, whether or not that row is still listed. Nil for a
  /// create's pane, whose id does not name the project its row needs, and the Quick Terminal.
  public var sidebarID: SidebarID? {
    switch self {
    case .root(let project): return .root(project: project)
    case .workroom(let project, let name): return .workroom(project: project, name: name)
    case .creation, .quickTerminal: return nil
    }
  }
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
    case .project: return nil
    }
  }
}
