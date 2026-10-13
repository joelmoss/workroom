import SwiftUI

/// Walks a user boxd has never seen through its three steps before their first boxd workroom
/// (`BoxdSetup`): what each step is for, one action, and live status. Create Workroom carries on
/// with the create the sheet interrupted once every step is ticked, or its check couldn't answer
/// (boxd then decides).
struct BoxdSetupSheet: View {
  let setup: BoxdSetup
  let onCreate: () -> Void
  let onCancel: () -> Void

  var body: some View {
    RemoteSetupSheet(
      title: "Set up boxd",
      intro: "[boxd](https://boxd.sh) is a cloud service that runs each workroom on a machine of "
        + "its own. After signing up, payment is required. Three steps, once, and Workroom checks "
        + "each one for you.",
      setup: setup, identifier: "boxdSetup", onCreate: onCreate, onCancel: onCancel
    ) {
      SetupStep(title: "Install", state: installState) { installContent }
      SetupStep(title: "Account", state: accountState) { accountContent }
      SetupStep(title: "GitHub", state: gitHubState) { gitHubContent }
    }
  }

  // MARK: Steps

  private var installState: SetupStepState {
    switch setup.install {
    case .done: .done
    case .installing: .waiting
    case .needed, .failed: .current
    }
  }

  private var accountState: SetupStepState {
    switch setup.account {
    case .locked: .locked
    case .checking, .signingIn: .waiting
    case .signedIn: .done
    case .signedOut, .unknown, .failed, .needsUpdate: .current
    }
  }

  private var gitHubState: SetupStepState {
    switch setup.gitHub {
    case .locked: .locked
    case .checking, .connecting: .waiting
    case .done: .done
    case .needed, .unknown, .failed: .current
    }
  }

  // MARK: Install

  @ViewBuilder private var installContent: some View {
    switch setup.install {
    case .done:
      SetupDetail("boxd is installed.")
    case .needed:
      SetupDetail(
        "Workroom runs boxd's own installer, which puts the `boxd` command in ~/.local/bin. It "
          + "needs no admin password and changes nothing else.")
      Button("Install boxd") { Task { await setup.installBoxd() } }
        .accessibilityIdentifier("boxdSetup.install")
    case .installing:
      SetupDetail("Installing boxd…")
    case .failed(let said):
      SetupProblem(said)
      Button("Try Again") { Task { await setup.installBoxd() } }
    }
  }

  // MARK: Account

  @ViewBuilder private var accountContent: some View {
    switch setup.account {
    case .locked:
      SetupDetail("Sign in to boxd, or create an account, once it's installed.")
    case .checking:
      SetupDetail("Checking your boxd account…")
    case .signedOut(let why):
      SetupDetail(
        "Sign in to boxd in your browser, or create an account there. Workroom carries on by "
          + "itself once you have.")
      if let why { SetupProblem(why) }
      Button("Sign In") { Task { await setup.signIn() } }
        .accessibilityIdentifier("boxdSetup.signIn")
    case .signingIn:
      SetupDetail("Finish signing in to boxd in your browser.")
      waitingLinks(page: "Open the Sign-In Page Again")
    case .signedIn(let name, let org):
      SetupDetail(signedIn(name: name, org: org))
    case .unknown(let why):
      SetupProblem(
        "Workroom couldn't check your boxd account: \(why). Create Workroom will still try.")
      HStack {
        Button("Sign In") { Task { await setup.signIn() } }
        Button("Check Again") { Task { await setup.checkAgain() } }
      }
    case .failed(let said):
      SetupProblem(said)
      Button("Try Again") { Task { await setup.signIn() } }
    case .needsUpdate:
      SetupProblem(
        "You're signed in to boxd, but Workroom can't read boxd's sign-in: boxd has changed how it "
          + "keeps it. Update Workroom to carry on.")
    }
  }

  private func signedIn(name: String?, org: String?) -> String {
    let who = name.map { "Signed in as \($0)" } ?? "Signed in"
    return org.map { "\(who), in \($0)." } ?? "\(who)."
  }

  // MARK: GitHub

  @ViewBuilder private var gitHubContent: some View {
    switch setup.gitHub {
    case .locked:
      SetupDetail("Connect GitHub so your machines can clone and push as you.")
    case .checking:
      SetupDetail("Checking GitHub on boxd…")
    case .needed:
      SetupDetail(
        "Lets your machines clone and push as you, through boxd's git integration. Connect your "
          + "GitHub account in your browser.")
      Button("Connect GitHub") { Task { await setup.connectGitHub() } }
        .accessibilityIdentifier("boxdSetup.connectGitHub")
    case .connecting:
      SetupDetail("Finish connecting GitHub in your browser.")
      waitingLinks(page: "Open GitHub Again")
    case .done:
      SetupDetail("GitHub is connected.")
    case .unknown(let why):
      SetupProblem(
        "Workroom couldn't check GitHub on boxd: \(why). Create Workroom will still try.")
      Button("Check Again") { Task { await setup.checkAgain() } }
    case .failed(let said):
      SetupProblem(said)
      Button("Try Again") { Task { await setup.connectGitHub() } }
    }
  }

  /// For a step waiting in the browser: its page again, or stop waiting.
  private func waitingLinks(page: String) -> some View {
    HStack {
      if setup.link != nil {
        Button(page) { setup.openLinkAgain() }
      }
      Button("Stop") { setup.stop() }
    }
    .buttonStyle(.link)
  }
}
