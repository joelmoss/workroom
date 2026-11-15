import Foundation
import OSLog
import WorkroomDomain

/// A remote workroom whose setup script is still to run (#363): its create paused at the script,
/// unapproved, and the app quit or the pane went before it was answered. Its host's record says so
/// (`HostDescriptor.setupPending`), so after a relaunch its Details pane and sidebar row still do,
/// with Review Script…, Continue Without Script and Delete.
extension WorkroomLifecycle {
  /// Writes whether workroom `name`'s setup is pending onto its host's record: read afresh from
  /// config and written back whole, as a create's own records are. Best effort: a record that can't
  /// be read or written is logged, and nothing else stops.
  func recordSetupPending(
    _ pending: Bool, of name: String, in path: String, cli: any WorkroomCLIProtocol,
    from window: any LifecycleWindow
  ) async {
    do {
      let listed = try await cli.list(warnings: "none", project: path)
      guard
        var host = listed.projects.first(where: { $0.path == path })?
          .workrooms.first(where: { $0.name == name })?.host,
        host.isSetupPending != pending
      else { return }
      host.setupPending = pending ? true : nil
      try await cli.setHost(
        project: path, workroom: name, descriptor: try JSONEncoder().encode(host))
    } catch {
      Self.pendingSetupLogger.error(
        "recording \(name, privacy: .public)'s setup as \(pending ? "pending" : "done", privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return
    }
    await window.reload()
  }

  /// Whether `workroom`'s setup script is pending with no create left to answer it.
  func isSetupPending(_ workroom: Workroom, inProject path: String) -> Bool {
    workroom.host?.isSetupPending == true
      && creationRun(forTargetID: TargetID.workroom(project: path, name: workroom.name)) == nil
  }

  /// Review Script… on a workroom whose setup is pending: the host's copy, as it holds it now, in
  /// the setup script's approval sheet. It is shown even when this Mac has approved those bytes
  /// since, so Approve always answers what was read. A checkout with no script left clears the mark.
  func reviewPendingSetup(
    _ workroom: Workroom, in project: Project, from window: any LifecycleWindow
  ) async {
    let id = TargetID.workroom(project: project.path, name: workroom.name)
    guard isSetupPending(workroom, inProject: project.path), pendingSetupRuns[id] == nil else {
      return
    }
    let judge = Self.judge(.setup, in: project.path, cli: window.services.cli)
    let result = await runPendingSetupScript(
      workroom, in: project, judge: { text in Self.unapproved(try await judge(text)) },
      onStart: {}, onLine: { _ in }, from: window)
    switch result {
    case .notTrusted(let script):
      presentPendingSetupApproval(script, for: workroom, in: project, from: window)
    case .absent, .passed:
      await recordSetupPending(
        false, of: workroom.name, in: project.path, cli: window.services.cli, from: window)
    case .failed(let why):
      window.modals.errorMessage = why
      window.modals.errorTitle = "Can't review the setup script of ‘\(workroom.displayName)’"
    }
  }

  /// The setup script's approval sheet for a workroom whose setup is pending: the script to read,
  /// Continue Without Script… (confirmed), Not Now, and Approve. Each answers `script`, the bytes
  /// shown.
  func presentPendingSetupApproval(
    _ script: ScriptTrust, for workroom: Workroom, in project: Project,
    from window: any LifecycleWindow
  ) {
    let modals = window.modals
    // As a create's: never swap another script's sheet under the person reading it.
    if modals.errorMessage != nil, modals.errorApproval != nil { return }
    let name = workroom.name
    let path = project.path
    modals.errorMessage = Self.pendingSetupMessage(
      script, workroom: workroom.displayName, project: project)
    modals.errorTitle = "Approve the setup script?"
    modals.errorLog = script.visibleText
    modals.errorScriptName = script.name
    let confirmation = Self.pendingSetupSkipConfirmation(for: script)
    modals.errorAction = ErrorAction(
      label: "\(confirmation.button)…", destructive: false, confirmation: confirmation
    ) { [weak window] in
      Task {
        guard let window else { return }
        await self.skipPendingSetup(name, in: path, from: window)
      }
    }
    modals.errorCancel = ErrorAction(label: "Not Now") {}
    modals.errorApproval = ErrorAction(label: "Approve") { [weak window] in
      Task {
        guard let window else { return }
        await self.approvePendingSetup(name, in: path, shown: script, from: window)
      }
    }
  }

  /// Approve on a pending setup's sheet: `shown`, the bytes the sheet showed, is recorded as
  /// approved, and the setup script runs on the workroom's host, judged again, its output in the
  /// Details pane as it comes. A copy changed meanwhile asks again; one that ran, passing or
  /// failing, clears the mark, and one that never started (its host unreachable) keeps it. A
  /// failure is said with what the script printed. The workroom can't be deleted while it runs,
  /// as a create's can't (issue #116).
  func approvePendingSetup(
    _ name: String, in path: String, shown: ScriptTrust, from window: any LifecycleWindow
  ) async {
    let id = TargetID.workroom(project: path, name: name)
    guard pendingSetupRuns[id] == nil, let project = projectStore.project(at: path),
      let workroom = project.workrooms.first(where: { $0.name == name }),
      isSetupPending(workroom, inProject: path)
    else { return }
    let cli = window.services.cli
    // Held from here, so a second Approve finds it running.
    let log = ScriptLogSession(title: "Running \(shown.displayFile)", phase: "setup")
    pendingSetupRuns[id] = log
    creatingWorkrooms.insert(id)
    defer {
      pendingSetupRuns[id] = nil
      creatingWorkrooms.remove(id)
    }
    do {
      try await cli.trustScript(shown.name, text: shown.approvalBytes, project: path)
    } catch {
      window.present(error)
      window.modals.errorTitle = "Couldn't approve \(shown.displayFile)"
      return
    }
    let started = CreationWarningBox()
    let result = await runPendingSetupScript(
      workroom, in: project, judge: Self.judge(.setup, in: path, cli: cli),
      onStart: {}, onRan: { started.value = "ran" },
      onLine: { line in Self.onMain { log.append(line) } }, from: window)
    await Self.drainMainQueue()  // the script's last lines
    switch result {
    case .notTrusted(let script):
      log.finish()
      presentPendingSetupApproval(script, for: workroom, in: project, from: window)
    case .absent, .passed:
      log.finish()
      await recordSetupPending(false, of: name, in: path, cli: cli, from: window)
    case .failed(let why):
      log.finish(failure: why)
      if started.value != nil {
        await recordSetupPending(false, of: name, in: path, cli: cli, from: window)
      }
      let output = log.lines.map(\.text).joined(separator: "\n")
      // The message first: setting it clears the log.
      window.modals.errorMessage = why
      window.modals.errorTitle = "The setup script of ‘\(workroom.displayName)’ failed"
      window.modals.errorLog = output.isEmpty ? nil : output
    }
  }

  /// Continue Without Script on a pending setup: the mark goes, and nothing runs. Nothing is
  /// approved, so the next create asks again.
  func skipPendingSetup(_ name: String, in path: String, from window: any LifecycleWindow) async {
    guard pendingSetupRuns[TargetID.workroom(project: path, name: name)] == nil else { return }
    await recordSetupPending(false, of: name, in: path, cli: window.services.cli, from: window)
  }

  /// The setup script on `workroom`'s host, through the create's own runner
  /// (`RemoteCreateServices.script`), judged by `judge`. Its host is reached from its record.
  private func runPendingSetupScript(
    _ workroom: Workroom, in project: Project, judge: @escaping RemoteProvisioning.ScriptJudge,
    onStart: @escaping @Sendable () -> Void, onRan: @escaping @Sendable () -> Void = {},
    onLine: @escaping @Sendable (String) -> Void, from window: any LifecycleWindow
  ) async -> RemoteProvisioning.ScriptRun {
    let services = window.services.remoteCreate
    guard let descriptor = workroom.host, let id = descriptor.id else {
      return .failed("setup script failed: the workroom's host record is incomplete")
    }
    let host: RemoteCreateHost
    do {
      host = try services.existingHost(descriptor)
    } catch {
      return .failed("setup script failed: \(Self.errorText(error))")
    }
    let box = HostID.remote(id)
    var request = RemoteWorkrooms.ScriptRequest(
      script: .setup, workroom: workroom.name, path: workroom.path, host: box, key: host.key,
      driver: host.driver, daemonBinary: host.environment.daemonBinary(on: box),
      rootScript: URL(fileURLWithPath: project.path + "/scripts/workroom_setup"), judge: judge,
      onStart: onStart, onLine: onLine)
    request.onRan = onRan
    return await services.script(request)
  }

  /// `script`, judged unapproved whatever this Mac holds, so the sheet asks about it.
  nonisolated private static func unapproved(_ script: ScriptTrust) -> ScriptTrust {
    ScriptTrust(
      name: script.name, file: script.file, origin: script.origin, sha256: script.sha256,
      text: script.text, bytes: script.bytes, trusted: false, exempt: false)
  }

  /// Why a workroom's pending setup asks, and the ways on.
  nonisolated static func pendingSetupMessage(
    _ script: ScriptTrust, workroom: String, project: Project
  ) -> String {
    "‘\(workroom)’ in \(project.displayName) was made, but its setup script never ran. "
      + "\(script.displayFile) \(script.originLabel) is new, or changed since it was approved on "
      + "this Mac. Read it, then approve it to run it there, or carry on without running it."
  }

  /// Continue Without Script's confirmation on a pending setup.
  static func pendingSetupSkipConfirmation(
    for script: ScriptTrust
  ) -> ErrorAction.Confirmation {
    ErrorAction.Confirmation(
      title: "Carry on without running \(script.displayFile)?",
      message: "The workroom stays as it is, and nothing the script would have set up is done. "
        + "The script stays unapproved, so you'll be asked again next time.",
      button: "Continue Without Script")
  }

  private static let pendingSetupLogger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "WorkroomLifecycle")
}
