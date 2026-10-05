import Foundation

/// A remote workroom's pane layout as its host keeps it (#255,
/// `docs/designs/oq8-cross-machine-reattach.md`): the workroom's `TargetSession`, with what belongs
/// to one Mac taken out, in a small versioned envelope.
///
/// What is taken out, and filled back in from this Mac's own `session.json` by `refilled(from:)`:
/// focus (two Macs do not share a cursor), popped-out pane frames (this Mac's screens), and the
/// revision and stale mark this Mac keeps. `targetID` holds this Mac's project path, so the host's
/// copy carries the workroom's own key instead and the reader puts its own `target.id` back.
///
/// **Untrusted on the way in.** Anything that can reach the host's agent can write a layout, so
/// one read back goes through `SessionFile.sanitized()`, the caps and checks `session.json` gets.
enum HostLayout {
  /// Bumped only for a change an older build cannot read. Adding a tab kind or an optional field
  /// is not one (`SessionSnapshot.swift`'s rule): an older build drops a kind it does not know and
  /// writes the rest back, the accepted trade (D5). A newer version is read-only to this build.
  static let schemaVersion = 1

  /// What a host's layout means to this Mac.
  enum Decoded: Equatable {
    /// Tabs to restore.
    case layout(TargetSession)
    /// The workroom's last tab was closed (D11): restore none, and do not seed over it.
    case empty
    /// Written by a newer build: restore nothing from it and never write over it.
    case newer
    /// Not a layout this build can read at all.
    case unreadable
  }

  private struct Envelope: Codable {
    let schemaVersion: Int
    let target: TargetSession
  }

  /// `target` as its host keeps it, under `key` (`TerminalTarget.sessionWorkroomKey`).
  static func encode(_ target: TargetSession, key: String) throws -> String {
    var shared = target
    shared.targetID = key
    shared.focusedKey = nil
    shared.hostRevision = nil
    shared.hostLayoutStale = nil
    shared.tabs = shared.tabs.map { tab in
      var tab = tab
      tab.detachedFrame = nil
      return tab
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(Envelope(schemaVersion: schemaVersion, target: shared))
    return String(decoding: data, as: UTF8.self)
  }

  /// The host's `blob` as this Mac's target `targetID`, sanitized.
  static func decode(_ blob: String, targetID: String) -> Decoded {
    let data = Data(blob.utf8)
    guard data.count <= SessionLimits.maxFileBytes else { return .unreadable }
    struct Version: Decodable { let schemaVersion: Int }
    guard let version = try? JSONDecoder().decode(Version.self, from: data) else {
      return .unreadable
    }
    if version.schemaVersion > schemaVersion { return .newer }
    guard version.schemaVersion == schemaVersion,
      var target = try? JSONDecoder().decode(Envelope.self, from: data).target
    else { return .unreadable }
    target.targetID = targetID
    target.focusedKey = nil
    target.hostRevision = nil
    target.hostLayoutStale = nil
    // Frames are this Mac's (`refilled` puts its own back); one from the host would open a window
    // wherever another client of the host said.
    target.tabs = target.tabs.map { tab in
      var tab = tab
      tab.detachedFrame = nil
      return tab
    }
    if target.tabs.isEmpty { return .empty }
    // Through the same checks a session.json gets: caps, duplicate keys, malformed tabs, splits.
    // Tabs that are all malformed are not a closed workroom (D11): nothing here is readable.
    let file = SessionFile(
      savedAt: Date(), windows: [WindowSession(windowKey: "host", targets: [target])])
    guard let sanitized = file.sanitized().file.windows.first?.targets.first,
      !sanitized.tabs.isEmpty
    else { return .unreadable }
    return .layout(sanitized)
  }

  /// What one tab shows, which is how this Mac finds its own focus and frames again in a layout
  /// whose keys another Mac minted (D12): keys are re-minted on every restore.
  static func identity(of tab: TabSession) -> String? {
    switch tab.kind {
    case TabSession.terminalKind: return tab.terminal?.sessionID.map { "terminal:\($0)" }
    case TabSession.diffKind:
      return tab.diff.map { "diff:\($0.source.kind):\($0.source.commit ?? ""):\($0.path)" }
    case TabSession.fileKind: return tab.file.map { "file:\($0.path)" }
    case TabSession.changesetKind: return tab.changeset.map { "changeset:\($0.commitID)" }
    default: return nil
    }
  }

  /// `layout` with this Mac's focus and popped-out frames from `local` put back, matched by what
  /// each tab shows; the first match wins.
  static func refilled(_ layout: TargetSession, from local: TargetSession?) -> TargetSession {
    guard let local else { return layout }
    var keyByIdentity: [String: String] = [:]
    for tab in layout.tabs {
      if let identity = identity(of: tab), keyByIdentity[identity] == nil {
        keyByIdentity[identity] = tab.key
      }
    }
    var result = layout
    if let focused = local.tabs.first(where: { $0.key == local.focusedKey }),
      let identity = identity(of: focused), let key = keyByIdentity[identity]
    {
      result.focusedKey = key
    }
    var frames: [String: String] = [:]
    for tab in local.tabs {
      if let frame = tab.detachedFrame, let identity = identity(of: tab),
        let key = keyByIdentity[identity], frames[key] == nil
      {
        frames[key] = frame
      }
    }
    result.tabs = result.tabs.map { tab in
      var tab = tab
      if let frame = frames[tab.key] { tab.detachedFrame = frame }
      return tab
    }
    return result
  }
}
