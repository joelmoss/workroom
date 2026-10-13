import AppKit
import Foundation
import HostDrivers

/// Gets a user boxd has never seen ready for their first boxd workroom, in the app. Three steps,
/// each checked from boxd itself, so one already done is ticked and an account with all three never
/// sees `BoxdSetupSheet`:
///
/// - **Install.** boxd's own installer, which puts `boxd` in `~/.local/bin`.
/// - **Account.** boxd's sign-in, which opens the browser and waits there.
/// - **GitHub.** boxd's git integration, the GitHub sign-in `git` and `gh` use on the machines.
///
/// A step a click starts finishes when its command does, so nothing here polls. Checking the account
/// never starts boxd's own sign-in (`BoxdHostDriver.account()`).
@MainActor
@Observable
final class BoxdSetup: RemoteSetup {
  enum InstallStep: Equatable {
    case needed
    case installing
    case failed(String)
    case done
  }

  enum AccountStep: Equatable {
    /// Waits on Install.
    case locked
    case checking
    /// Nobody is signed in, with why when there's more to say.
    case signedOut(String?)
    /// boxd's sign-in is open in the browser.
    case signingIn
    case signedIn(name: String?, org: String?)
    /// boxd couldn't be asked: the create goes ahead and boxd's own error decides.
    case unknown(String)
    case failed(String)
  }

  enum GitHubStep: Equatable {
    /// Waits on the account.
    case locked
    case checking
    case needed
    case connecting
    case done
    case unknown(String)
    case failed(String)
  }

  /// What the setup asks of boxd, so a test can stand in for it.
  struct Actions {
    var isInstalled: @MainActor () -> Bool
    var install: @MainActor () throws -> any RunningCommand
    var account: @MainActor () async -> BoxdHostDriver.AccountState
    var gitHub: @MainActor () async -> BoxdHostDriver.GitHubState
    var signIn: @MainActor () throws -> any RunningCommand
    var connectGitHub: @MainActor () throws -> any RunningCommand

    /// boxd itself, found where `RemoteHosts` finds it for a create.
    static var live: Actions {
      let driver: @MainActor @Sendable () -> BoxdHostDriver = {
        BoxdHostDriver(
          configuration: .init(
            cli: URL(
              fileURLWithPath: RemoteHosts.boxdExecutable() ?? RemoteHosts.boxdCandidates[0])),
          directory: RemoteHosts.directory)
      }
      return Actions(
        isInstalled: { RemoteHosts.boxdExecutable() != nil },
        install: {
          try BoxdHostDriver.install(home: FileManager.default.homeDirectoryForCurrentUser)
        },
        account: { await driver().account() },
        gitHub: { await driver().gitHub() },
        signIn: { try driver().signIn() },
        connectGitHub: { try driver().connectGitHub() })
    }
  }

  private(set) var install: InstallStep = .needed
  private(set) var account: AccountStep = .locked
  private(set) var gitHub: GitHubStep = .locked
  /// The page boxd opened for the step running now, to open again if the user closed it.
  private(set) var link: URL?

  /// GitHub is checked only once the account is signed in or couldn't be asked, so it stands for
  /// the account too.
  var isReady: Bool {
    guard install == .done else { return false }
    switch gitHub {
    case .done, .unknown: return true
    default: return false
    }
  }

  /// Set once boxd is seen ready (a check that couldn't answer counts), so later creates this
  /// launch skip the checks. A step undone since fails the create with boxd's own error.
  static var confirmedThisLaunch = false

  private let actions: Actions
  private let open: (URL) -> Void
  /// The command a click started and still running: the installer, sign-in or GitHub.
  private var running: (any RunningCommand)?
  /// The sheet is gone: a check or a command that ends late must change nothing.
  private var isCancelled = false

  init(actions: Actions = .live, open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
    self.actions = actions
    self.open = open
  }

  /// Nil when boxd is ready for a create, checked once a launch; otherwise the setup to show,
  /// already read from boxd.
  static func needed(actions: Actions = .live) async -> BoxdSetup? {
    guard !confirmedThisLaunch else { return nil }
    let setup = BoxdSetup(actions: actions)
    await setup.refresh()
    return setup.isReady ? nil : setup
  }

  /// Checks every step from boxd.
  func refresh() async {
    guard actions.isInstalled() else {
      install = .needed
      account = .locked
      gitHub = .locked
      return
    }
    install = .done
    account = .checking
    let state = await actions.account()
    guard !isCancelled else { return }
    switch state {
    case .signedIn(let signedIn):
      account = .signedIn(name: signedIn.displayName, org: signedIn.activeOrgName)
    case .signedOut(let why):
      account = .signedOut(why)
    case .unknown(let why):
      account = .unknown(why)
    }
    await refreshGitHub()
    if isReady { Self.confirmedThisLaunch = true }
  }

  /// GitHub can be checked once boxd answers for an account, or couldn't be asked at all.
  private func refreshGitHub() async {
    switch account {
    case .signedIn, .unknown: break
    default:
      gitHub = .locked
      return
    }
    gitHub = .checking
    let state = await actions.gitHub()
    guard !isCancelled else { return }
    switch state {
    case .connected: gitHub = .done
    case .notConnected: gitHub = .needed
    case .unknown(let why): gitHub = .unknown(why)
    }
  }

  func installBoxd() async {
    install = .installing
    guard let status = await run(actions.install, failed: { self.install = .failed($0) }) else {
      return
    }
    if status.code == 0, actions.isInstalled() {
      await refresh()
    } else {
      install = .failed(status.said ?? "boxd's installer stopped (exit \(status.code)).")
    }
  }

  func signIn() async {
    account = .signingIn
    guard let status = await run(actions.signIn, failed: { self.account = .failed($0) }) else {
      return
    }
    await refresh()
    if case .signedOut = account, status.code != 0 {
      account = .signedOut(status.said ?? "boxd's sign-in didn't finish.")
    }
  }

  func connectGitHub() async {
    gitHub = .connecting
    guard let status = await run(actions.connectGitHub, failed: { self.gitHub = .failed($0) })
    else { return }
    await refreshGitHub()
    if gitHub == .needed, status.code != 0 {
      gitHub = .failed(status.said ?? "Connecting GitHub didn't finish.")
    }
    if isReady { Self.confirmedThisLaunch = true }
  }

  /// Check Again: every step from boxd, for one done elsewhere or a check that failed.
  func checkAgain() async {
    await refresh()
  }

  /// Opens the page the running step opened, again.
  func openLinkAgain() {
    if let link { open(link) }
  }

  /// Stops the step running now, for a user who closed boxd's page instead of finishing there. Its
  /// step then reads from boxd again.
  func stop() {
    running?.cancel()
  }

  /// Stops the command a click started: the sheet is gone.
  func cancel() {
    isCancelled = true
    running?.cancel()
    running = nil
  }

  /// Runs `start`'s command to its end, showing the page it opens; nil when it couldn't start, with
  /// `failed` told why, or the sheet closed meanwhile.
  private func run(
    _ start: @MainActor () throws -> any RunningCommand, failed: (String) -> Void
  ) async -> (code: Int32, said: String?)? {
    running?.cancel()
    link = nil
    let command: any RunningCommand
    do { command = try start() } catch {
      failed(error.localizedDescription)
      return nil
    }
    running = command
    let watching = Task { [weak self] in
      // The page's address comes on the command's output a moment after it starts.
      for _ in 0..<40 where !Task.isCancelled {
        if let link = command.link {
          self?.link = link
          return
        }
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
    let code = await command.wait()
    watching.cancel()
    guard !isCancelled, running === command else { return nil }
    running = nil
    link = nil
    return (code, command.lastLine)
  }
}

/// A command a setup step started: it may wait in the browser until the user finishes there.
protocol RunningCommand: AnyObject, Sendable {
  /// The first web address it printed, such as the page it opened.
  var link: URL? { get }
  /// Its last line of output, for a failure to say.
  var lastLine: String? { get }
  /// Its exit status, once it ends.
  func wait() async -> Int32
  func cancel()
}

extension BoxdHostDriver.ClickedCommand: RunningCommand {}
