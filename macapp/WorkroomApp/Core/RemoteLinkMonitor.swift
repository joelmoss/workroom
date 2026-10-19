import AppKit
import Network
import WorkroomVCS
import os

/// When the Mac wakes or moves to another network, asks each boxd and exe.dev host whether its link
/// still answers, and reattaches the remote panes of those that don't. ssh notices a link that went
/// silent only when its keepalive gives up, which measured 57 s on the ssh fixture
/// (`SSHTransport.writeConfiguration`); the question takes at most 2 s and a fresh attach about one.
/// A host that answers keeps its links, so a pane whose ssh outlasted a short sleep doesn't blink.
@MainActor
final class RemoteLinkMonitor {
  static let shared = RemoteLinkMonitor()
  /// Posted on the main queue. Every pane waiting out its backoff attaches; a pane whose ssh still
  /// runs attaches only when its host is in `staleHostsKey`'s `Set<HostID>`.
  nonisolated static let linksStale = Notification.Name("RemoteLinkMonitor.linksStale")
  nonisolated static let staleHostsKey = "staleHosts"

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "PersistentSession")

  private let pathMonitor = NWPathMonitor()
  private var trigger = RemoteLinkTrigger()
  private var pending: DispatchWorkItem?
  /// The events since the last fire, for its log line: which wake, VPN or tethered phone it was.
  private var reasons: [String] = []
  private var wakeObserver: NSObjectProtocol?

  func start() {
    guard wakeObserver == nil else { return }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.act(on: self.trigger.woke(), reason: "wake")
      }
    }
    pathMonitor.pathUpdateHandler = { [weak self] path in
      let snapshot = RemoteLinkTrigger.Path(path)
      MainActor.assumeIsolated {
        guard let self else { return }
        let network =
          snapshot.satisfied
          ? "\(snapshot.interface ?? "no interface") via \(snapshot.gateways.sorted())" : "down"
        self.act(on: self.trigger.pathChanged(to: snapshot), reason: "network \(network)")
      }
    }
    pathMonitor.start(queue: .main)
  }

  /// One fire for a burst of events: a wake brings two or three path updates within a second, and a
  /// second fire would end an ssh that was still connecting.
  private func act(on action: RemoteLinkTrigger.Action, reason: String) {
    guard action != .none else { return }
    reasons.append(reason)
    pending?.cancel()
    pending = nil
    guard case .fire(let delay, let scope) = action else { return }
    let item = DispatchWorkItem { [weak self] in self?.fire(scope) }
    pending = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func fire(_ scope: RemoteLinkTrigger.Scope) {
    pending = nil
    trigger.fired()
    let why = reasons.joined(separator: ", then ")
    reasons = []
    let post = { (stale: Set<HostID>) in
      NotificationCenter.default.post(
        name: Self.linksStale, object: self, userInfo: [Self.staleHostsKey: stale])
    }
    guard scope == .all else {
      Self.logger.notice("remote links: \(why, privacy: .public); reattaching waiting panes")
      return post([])
    }
    // The answers first: a host that didn't answer has its link dropped, and a pane's attach then
    // reconnects it (`attachCommand`), which it would find still up, and lose, the other way round.
    Task {
      let stale = await RemoteHosts.shared.unansweringProviderHosts()
      Self.logger.notice(
        "remote links: \(why, privacy: .public); \(stale.count) host(s) didn't answer within 2 s, reattaching their panes and waiting ones"
      )
      post(stale)
    }
  }
}

/// When the Mac's network moved enough that a remote link may be dead (`RemoteLinkMonitor`).
///
/// A wake asks every host (`.all`), at the next path update (`settle`) or after `wakeWait` without
/// one. A path that comes up on another interface or gateway asks every host too. One that comes
/// back as it was reattaches only the panes waiting out their backoff, since a live link has most
/// likely outlasted the blip. A path that goes down holds any fire, which an attach with no network would
/// only back off from, and what the fire owed is kept for when it is back.
struct RemoteLinkTrigger {
  struct Path: Equatable {
    var satisfied: Bool
    /// The interface the system prefers, by name.
    var interface: String?
    var gateways: Set<String>
  }

  enum Scope: Equatable { case all, waiting }

  enum Action: Equatable {
    case none
    case hold
    case fire(after: TimeInterval, scope: Scope)
  }

  static let settle: TimeInterval = 0.5
  static let wakeWait: TimeInterval = 2

  private var lastUp: Path?
  private var down = false
  /// What the next fire must cover, kept across a hold until it fires.
  private var owed: Scope?

  mutating func woke() -> Action {
    owed = .all
    return down ? .hold : .fire(after: Self.wakeWait, scope: .all)
  }

  mutating func pathChanged(to path: Path) -> Action {
    guard path.satisfied else {
      down = true
      return .hold
    }
    defer {
      down = false
      lastUp = path
    }
    var scope = owed
    // The first answer is the network the links were made on.
    if let lastUp, lastUp.interface != path.interface || lastUp.gateways != path.gateways {
      scope = .all
    } else if down {
      scope = scope ?? .waiting
    }
    guard let scope else { return .none }
    owed = scope
    return .fire(after: Self.settle, scope: scope)
  }

  mutating func fired() { owed = nil }
}

extension RemoteLinkTrigger.Path {
  init(_ path: NWPath) {
    self.init(
      satisfied: path.status == .satisfied,
      interface: path.availableInterfaces.first?.name,
      gateways: Set(path.gateways.map { "\($0)" }))
  }
}
