import AppKit
import Foundation
import HostDrivers

/// Gets a user exe.dev has never seen ready for their first exe.dev workroom, in the app: no exe.dev
/// CLI exists, only `ssh exe.dev`, and its sign-up is a terminal conversation. Three steps, each
/// checked from the account itself, so one already done is ticked and an account with all three
/// never sees `ExeDevSetupSheet`:
///
/// - **Account.** exe.dev's login is the user's ssh key. A Mac with no key gets one made
///   (`~/.ssh/id_ed25519`); exe.dev's host key is trusted once it matches the published
///   fingerprint; then the user's email starts exe.dev's sign-up, which waits for its link.
/// - **Plan.** A new account can't make VMs until it picks a plan on the website.
/// - **GitHub.** exe.dev's GitHub connection, for the repository integration a create adds.
///
/// The website steps open a one-time link signed in to this account (`magicLink`), and every step
/// that waits on the user is checked every 3 s until it's done.
@MainActor
@Observable
final class ExeDevSetup {
  enum AccountStep: Equatable {
    case checking
    /// No ssh key at all: offer to make one.
    case needsKey
    /// A key that ssh couldn't use, e.g. one with a passphrase outside the agent: ssh's words.
    case keyUnusable(String)
    /// exe.dev doesn't know the key: ask for an email, with what exe.dev said to the last one.
    case needsEmail(error: String?)
    case sending(String)
    case awaitingVerification(String)
    /// The user is signing up in a terminal in the sheet, by hand: for a sign-up whose words
    /// Workroom didn't expect, or a user who would rather.
    case inTerminal
    case done(String)
    case failed(String)
  }

  enum Step: Equatable {
    case needed
    case opening
    case waiting
    case done
  }

  private(set) var account: AccountStep = .checking
  private(set) var plan: Step = .needed
  private(set) var gitHub: Step = .needed
  /// A website step that couldn't be checked or opened, said under it.
  private(set) var planError: String?
  private(set) var gitHubError: String?

  var isSignedIn: Bool {
    if case .done = account { return true }
    return false
  }

  var isReady: Bool { isSignedIn && plan == .done && gitHub == .done }

  /// Set once an account is seen ready, so later creates this launch skip the three checks. A
  /// step undone since (a plan cancelled, GitHub disconnected) fails the create with exe.dev's own
  /// error, as before.
  static var confirmedThisLaunch = false

  private let driver: ExeDevHostDriver
  private var signUp: ExeDevHostDriver.SignUp?
  private var polling: Task<Void, Never>?
  /// Which poll is current, so one replaced mid-check doesn't clear its successor.
  private var pollID = UUID()
  /// The sheet is gone: a check or a link that answers late must change nothing.
  private var isCancelled = false
  /// How the website steps are opened, for a test to catch.
  private let open: (URL) -> Void

  init(driver: ExeDevHostDriver, open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
    self.driver = driver
    self.open = open
  }

  /// Nil when exe.dev is ready for a create, checked once a launch; otherwise the setup to show,
  /// already read from the account.
  static func needed(driver: ExeDevHostDriver) async -> ExeDevSetup? {
    guard !confirmedThisLaunch else { return nil }
    let setup = ExeDevSetup(driver: driver)
    await setup.refresh()
    return setup.isReady ? nil : setup
  }

  /// Checks every step from the account.
  func refresh() async {
    account = .checking
    var state = await driver.account()
    if state == .unknownHostKey {
      do {
        try await driver.trustGatewayKey()
        state = await driver.account()
      } catch {
        account = .failed(error.localizedDescription)
        return
      }
    }
    switch state {
    case .signedIn(let email):
      account = .done(email)
      await refreshWebsiteSteps()
    case .needsSignUp: account = .needsEmail(error: nil)
    case .noUsableKey(let said):
      account = await driver.mayCreateDefaultKey() ? .needsKey : .keyUnusable(said)
    case .unknownHostKey: account = .failed("ssh still doesn't trust exe.dev's host key.")
    case .failed(let said): account = .failed(said)
    }
    if isReady { Self.confirmedThisLaunch = true }
  }

  /// A check that fails says so under its step, rather than reading as a step not done.
  private func refreshWebsiteSteps() async {
    planError = nil
    gitHubError = nil
    do { plan = try await driver.planAllowsVMs() ? .done : .needed } catch {
      plan = .needed
      planError = "Workroom couldn't check your plan: \(error.localizedDescription)"
    }
    do { gitHub = try await driver.gitHubConnected() ? .done : .needed } catch {
      gitHub = .needed
      gitHubError = "Workroom couldn't check GitHub: \(error.localizedDescription)"
    }
  }

  /// Check Again: the steps read from the account once more, keeping a step the user is still
  /// finishing on the website waiting (and watched) rather than asking them to start it again.
  func checkAgain() async {
    guard isSignedIn else {
      await refresh()
      return
    }
    let planWaiting = plan == .waiting
    let gitHubWaiting = gitHub == .waiting
    await refreshWebsiteSteps()
    if planWaiting, plan == .needed, planError == nil { plan = .waiting }
    if gitHubWaiting, gitHub == .needed, gitHubError == nil { gitHub = .waiting }
    if isWaiting { poll() }
    if isReady { Self.confirmedThisLaunch = true }
  }

  func createKey() async {
    account = .checking
    do {
      try await driver.createDefaultKey()
      await refresh()
    } catch {
      account = .failed(error.localizedDescription)
    }
  }

  /// Starts exe.dev's sign-up with `email`; the step finishes when its link is clicked.
  func submit(email: String) async {
    let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !email.isEmpty else { return }
    endSignUp()
    account = .sending(email)
    do {
      let session = try driver.signUp()
      signUp = session
      let outcome = await session.submit(email)
      // Cancelled, or another email sent meanwhile: this session's answer is no longer wanted.
      guard !isCancelled, signUp === session else {
        session.end()
        return
      }
      switch outcome {
      case .sent:
        account = .awaitingVerification(email)
        watchForEnd(of: session, email: email)
        poll()
      case .said(let words):
        endSignUp()
        account = .needsEmail(error: words)
      }
    } catch {
      account = .needsEmail(error: error.localizedDescription)
    }
  }

  /// Notices a sign-up whose connection ended before its link was clicked (the Mac slept, the
  /// network changed): exe.dev drops it, so the step goes back to the email field and says so.
  private func watchForEnd(of session: ExeDevHostDriver.SignUp, email: String) {
    Task { [weak self] in
      await session.waitForEnd()
      guard let self, self.signUp === session else { return }
      let state = await self.driver.account()
      guard self.signUp === session, self.account == .awaitingVerification(email) else { return }
      self.signUp = nil
      if case .signedIn(let address) = state {
        self.account = .done(address)
        await self.refreshWebsiteSteps()
      } else {
        self.account = .needsEmail(
          error: "The connection to exe.dev ended before the link was clicked. Send it again.")
      }
    }
  }

  /// `ssh exe.dev` for the sheet's terminal.
  var signInCommand: String { driver.signInCommand }

  /// Switches to signing up in the sheet's terminal; the step finishes when the account answers.
  func useTerminal() {
    endSignUp()
    account = .inTerminal
    poll()
  }

  /// Back to the email field, dropping the sign-up waiting on the last one.
  func changeEmail() {
    endSignUp()
    account = .needsEmail(error: nil)
  }

  func choosePlan() async {
    planError = nil
    plan = .opening
    do {
      let link = try await driver.magicLink(to: "/billing/update")
      guard !isCancelled else { return }
      open(link)
      plan = .waiting
      poll()
    } catch {
      plan = .needed
      planError = error.localizedDescription
    }
  }

  func connectGitHub() async {
    gitHubError = nil
    gitHub = .opening
    do {
      let link = try await driver.magicLink(to: "/integrations#github")
      guard !isCancelled else { return }
      open(link)
      gitHub = .waiting
      poll()
    } catch {
      gitHub = .needed
      gitHubError = error.localizedDescription
    }
  }

  /// Stops every check and the sign-up session: the sheet is gone.
  func cancel() {
    isCancelled = true
    polling?.cancel()
    polling = nil
    endSignUp()
  }

  private func endSignUp() {
    signUp?.end()
    signUp = nil
  }

  private var isWaiting: Bool {
    if case .awaitingVerification = account { return true }
    if account == .inTerminal { return true }
    return plan == .waiting || gitHub == .waiting
  }

  /// Checks each waiting step, 3 s after the user acts and backing off to every 30 s, until none
  /// is: a sheet left open while the user is away mustn't keep opening ssh connections to exe.dev.
  private func poll() {
    guard !isCancelled else { return }
    polling?.cancel()
    let id = UUID()
    pollID = id
    polling = Task { [weak self] in
      var delay = Duration.seconds(3)
      while let self, self.isWaiting, !Task.isCancelled {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { break }
        await self.checkWaitingSteps()
        delay = min(delay * 2, .seconds(30))
      }
      if self?.pollID == id { self?.polling = nil }
    }
  }

  private var isSigningUp: Bool {
    if case .awaitingVerification = account { return true }
    return account == .inTerminal
  }

  private func checkWaitingSteps() async {
    if isSigningUp, case .signedIn(let email) = await driver.account() {
      endSignUp()
      account = .done(email)
      await refreshWebsiteSteps()
    }
    if plan == .waiting, (try? await driver.planAllowsVMs()) == true { plan = .done }
    if gitHub == .waiting, (try? await driver.gitHubConnected()) == true { gitHub = .done }
    if isReady { Self.confirmedThisLaunch = true }
  }
}
