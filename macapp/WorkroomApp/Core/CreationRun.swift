import Combine
import Foundation
import HostDrivers
import WorkroomDomain

/// What kind of workroom a create makes, which decides its step plan and where it goes.
enum CreationKind: Equatable {
  case local
  case container(RemoteWorkrooms.Runtime)
  case boxd
  case exeDev

  init(_ place: RemoteWorkrooms.Place) {
    switch place {
    case .container(let runtime): self = .container(runtime)
    case .boxd: self = .boxd
    case .exeDev: self = .exeDev
    }
  }

  /// Where the workroom goes, as the pane's subtitle and the provisional sidebar row say it.
  var destination: String {
    switch self {
    case .local: "This Mac"
    case .container(let runtime): RemoteWorkrooms.Place.container(runtime).displayName
    case .boxd: RemoteWorkrooms.Place.boxd.displayName
    case .exeDev: RemoteWorkrooms.Place.exeDev.displayName
    }
  }

  /// The steps a create of this kind runs, in order (spec section 3), all pending. A remote step's
  /// id is its `ProvisioningProgress.Step`'s, which is how a driver's report finds its row.
  var plan: [CreationStep] {
    typealias Step = ProvisioningProgress.Step
    let remote: [(Step, String)]
    switch self {
    case .local:
      return [
        CreationStep(id: "fetch", title: "Fetch base branch"),
        CreationStep(id: "worktree", title: "Create worktree"),
        CreationStep(id: "script", title: "Run setup script"),
      ]
    case .container:
      remote = [
        (.repository, "Check repository"), (.image, "Pull host image"),
        (.machine, "Start container"), (.connect, "Connect"), (.clone, "Clone repository"),
        (.checkout, "Check out branch"),
      ]
    case .boxd:
      remote = [
        (.repository, "Check repository"), (.account, "Check boxd account"),
        (.machine, "Create machine"), (.setup, "Set up machine"), (.connect, "Connect"),
        (.clone, "Clone repository"), (.checkout, "Check out branch"),
      ]
    case .exeDev:
      remote = [
        (.repository, "Check repository"), (.account, "Check exe.dev account"),
        (.machine, "Create VM"), (.boot, "Wait for boot"), (.setup, "Set up machine"),
        (.connect, "Connect"), (.clone, "Clone repository"), (.checkout, "Check out branch"),
      ]
    }
    return remote.map { CreationStep(id: $0.0.rawValue, title: $0.1) }
  }
}

/// One row of a create's checklist.
struct CreationStep: Identifiable, Equatable {
  enum State: Equatable {
    case pending
    case running
    /// Waiting on the user: the provider setup sheet is up (design D8). Its timer is paused.
    case waitingForUser
    case done
    case warning(String)
    case failed
    case skipped(reason: String?)

    /// Whether the step counts as complete in the step circle: done, warning or skipped.
    var isComplete: Bool {
      switch self {
      case .done, .warning, .skipped: true
      case .pending, .running, .waitingForUser, .failed: false
      }
    }
  }

  let id: String
  let title: String
  var state: State = .pending
  var startedAt: Date?
  var endedAt: Date?
  /// Its output, ANSI-stripped, as `ScriptLogSession` keeps a script's.
  var log: [String] = []

  /// How long a finished step took, or nil while it hasn't finished or never ran.
  var duration: TimeInterval? {
    guard let startedAt, let endedAt else { return nil }
    return endedAt.timeIntervalSince(startedAt)
  }
}

/// How a create ended, or that it hasn't.
enum CreationOutcome: Equatable {
  case running
  /// Done: the finished checklist holds for a moment (`AppStore.creationSuccessHold`), then goes.
  case succeeded
  /// Cancel on the provider setup sheet: the run goes at once.
  case cancelled
  /// A local create that failed before its worktree existed.
  case failedBeforeWorkroom(message: String)
  /// A local create whose workroom exists but whose setup script failed.
  case setupScriptFailed(message: String)
  /// A remote create that failed; `leftBehind` when its machine could not be taken down.
  case remoteFailed(message: String, leftBehind: Bool)
}

/// One create's progress (#483): the plan of steps it shows from the first frame, each step's state,
/// timing and log, the workroom's name once it has one, and how it ended. Fed by the CLI's step
/// events for a local create and by `ProvisioningProgress` for a remote one. Lives in
/// `ProjectStore.creationRuns`, so every window shows the same checklist.
@MainActor
final class CreationRun: ObservableObject, Identifiable {
  let id: UUID
  let project: Project
  let kind: CreationKind
  /// The pane the create was opened beside, if it was opened as a split.
  let splitAnchor: SidebarID?
  /// What was selected before the create took the selection, for Close to go back to.
  let previousSelection: SidebarID?
  /// When the run started, which orders two unnamed runs in the sidebar.
  let startedAt: Date
  @Published private(set) var steps: [CreationStep]
  @Published private(set) var name: String?
  @Published private(set) var outcome: CreationOutcome = .running
  /// How far a container's host image pull has got, 0 to 1, while it pulls.
  @Published var pullFraction: Double?
  private let now: () -> Date

  init(
    id: UUID = UUID(), project: Project, kind: CreationKind, splitAnchor: SidebarID?,
    previousSelection: SidebarID?, now: @escaping () -> Date = Date.init
  ) {
    self.id = id
    self.project = project
    self.kind = kind
    self.splitAnchor = splitAnchor
    self.previousSelection = previousSelection
    self.now = now
    self.startedAt = now()
    self.steps = kind.plan
  }

  var isRunning: Bool { outcome == .running }

  /// The step running now, or waiting on the user.
  var runningStep: CreationStep? {
    steps.first { $0.state == .running || $0.state == .waitingForUser }
  }

  /// The step circle's reading: complete steps over all of them, and the step it is on.
  var progress: (fraction: Double, label: String) {
    let complete = steps.filter(\.state.isComplete).count
    let current = runningStep ?? steps.first { $0.state == .failed }
    return (Double(complete) / Double(max(steps.count, 1)), current?.title ?? "")
  }

  func setName(_ name: String) { self.name = name }

  /// `stepID` starts: the step running now ends done, and pending steps before it are skipped. A
  /// step already running keeps running; one waiting on the user starts again from zero.
  func begin(_ stepID: String) {
    guard let index = steps.firstIndex(where: { $0.id == stepID }),
      steps[index].state != .running
    else { return }
    if steps[index].state != .waitingForUser, let running = runningIndex, running != index {
      end(running, as: .done)
    }
    skipPending(before: index)
    steps[index].state = .running
    steps[index].startedAt = now()
    steps[index].endedAt = nil
  }

  /// `stepID` ends as `state` (done, warning, skipped or failed), as the CLI's event says.
  func finish(_ stepID: String, as state: CreationStep.State) {
    guard let index = steps.firstIndex(where: { $0.id == stepID }) else { return }
    skipPending(before: index)
    end(index, as: state)
  }

  func warn(_ stepID: String, _ text: String) { finish(stepID, as: .warning(text)) }

  /// `stepID` waits on the user (the provider setup sheet), its timer paused until `begin` again.
  func waitForUser(_ stepID: String) {
    begin(stepID)
    guard let index = steps.firstIndex(where: { $0.id == stepID }) else { return }
    steps[index].state = .waitingForUser
  }

  /// A line of output. One with no step, or a step outside the plan, goes to the running step, or to
  /// the first if none is.
  func append(_ line: String, to stepID: String?) {
    let index =
      steps.firstIndex { $0.id == stepID } ?? runningIndex ?? steps.indices.first
    guard let index else { return }
    steps[index].log.append(ScriptLogSession.stripANSI(line))
  }

  /// The create failed: the running step fails (or, when no step has, the first one not yet run), and
  /// every step still pending is skipped.
  func fail(_ outcome: CreationOutcome) {
    if let running = runningIndex {
      end(running, as: .failed)
    } else if !steps.contains(where: { $0.state == .failed }),
      let first = steps.firstIndex(where: { $0.state == .pending })
    {
      end(first, as: .failed)
    }
    skipPending(before: steps.endIndex)
    self.outcome = outcome
  }

  /// The create finished: the running step ends done and every step still pending is skipped.
  func succeed() {
    if let running = runningIndex { end(running, as: .done) }
    skipPending(before: steps.endIndex)
    outcome = .succeeded
  }

  /// Cancel on the provider setup sheet.
  func cancel() { outcome = .cancelled }

  /// A local create's CLI event (`create --json`): a step changing state, or a log line.
  func apply(_ event: StreamEvent) {
    switch event.type {
    case "step":
      guard let id = event.id else { return }
      switch event.state {
      case "running": begin(id)
      case "done": finish(id, as: .done)
      case "warning": finish(id, as: .warning(event.detail ?? ""))
      case "skipped": finish(id, as: .skipped(reason: event.detail))
      case "failed": finish(id, as: .failed)
      default: break
      }
    case "log":
      if let text = event.text { append(text, to: event.step) }
    default: break
    }
  }

  private var runningIndex: Int? {
    steps.firstIndex { $0.state == .running || $0.state == .waitingForUser }
  }

  private func end(_ index: Int, as state: CreationStep.State) {
    steps[index].state = state
    steps[index].endedAt = steps[index].startedAt == nil ? nil : now()
  }

  private func skipPending(before index: Int) {
    for i in steps.indices[..<index] where steps[i].state == .pending {
      steps[i].state = .skipped(reason: nil)
    }
  }
}
