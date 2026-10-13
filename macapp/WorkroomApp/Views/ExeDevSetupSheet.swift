import SwiftUI

/// Walks a user exe.dev has never seen through its three steps before their first exe.dev
/// workroom (`ExeDevSetup`): what each step is for, one action, and live status, so nothing waits
/// on the user without saying what it waits for. Create Workroom carries on with the create the
/// sheet interrupted once every step is ticked, or its check couldn't answer (exe.dev then decides).
struct ExeDevSetupSheet: View {
  let setup: ExeDevSetup
  let onCreate: () -> Void
  let onCancel: () -> Void

  @State private var email = ""
  @FocusState private var emailFocused: Bool
  private let theme = ThemeService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Set up exe.dev").font(.title2.bold())
        Text(
          "exe.dev runs each workroom on a VM of its own in the cloud. Three steps, once, and "
            + "Workroom checks each one for you."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.bottom, 20)

      VStack(alignment: .leading, spacing: 18) {
        step("Account", state: accountState) { accountContent }
        step("Plan", state: websiteState(setup.plan, unlocked: setup.isSignedIn)) {
          planContent
        }
        step("GitHub", state: websiteState(setup.gitHub, unlocked: setup.isSignedIn)) {
          gitHubContent
        }
      }

      Spacer(minLength: 20)

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("exeDevSetup.cancel")
        Button("Create Workroom", action: onCreate)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!setup.isReady)
          .accessibilityIdentifier("exeDevSetup.create")
      }
    }
    .padding(24)
    .frame(width: 520)
    .frame(minHeight: 460)
    .background(theme.tokens.panel)
    .onDisappear { setup.cancel() }
  }

  // MARK: Steps

  private enum StepState {
    case locked, current, waiting, done
  }

  private func step<Content: View>(
    _ title: String, state: StepState, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      indicator(state)
        .frame(width: 20, height: 20)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline)
          .foregroundStyle(state == .locked ? .secondary : .primary)
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(title) step")
  }

  @ViewBuilder private func indicator(_ state: StepState) -> some View {
    switch state {
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        .font(.system(size: 17))
        .accessibilityLabel("Done")
    case .waiting:
      ProgressView().controlSize(.small)
        .accessibilityLabel("Waiting")
    case .current:
      Image(systemName: "circle.fill").foregroundStyle(theme.tokens.accent)
        .font(.system(size: 9))
        .frame(width: 17, height: 17)
        .accessibilityLabel("To do")
    case .locked:
      Image(systemName: "circle").foregroundStyle(theme.tokens.fgDim)
        .font(.system(size: 9))
        .frame(width: 17, height: 17)
        .accessibilityLabel("Not yet")
    }
  }

  private var accountState: StepState {
    switch setup.account {
    case .done: .done
    case .checking, .sending, .awaitingVerification, .inTerminal: .waiting
    default: .current
    }
  }

  private func websiteState(_ step: ExeDevSetup.Step, unlocked: Bool) -> StepState {
    guard unlocked else { return .locked }
    switch step {
    case .done: return .done
    case .opening, .waiting: return .waiting
    case .needed: return .current
    }
  }

  // MARK: Account

  @ViewBuilder private var accountContent: some View {
    switch setup.account {
    case .checking:
      detail("Checking your exe.dev account…")
    case .needsKey:
      detail(
        "exe.dev signs you in with an SSH key, and this Mac doesn't have one yet. Workroom can "
          + "make one at ~/.ssh/id_ed25519, the key ssh uses by default. It has no passphrase, so "
          + "anyone who can use your Mac account can use it, and ssh offers it to every server.")
      Button("Create SSH Key") { Task { await setup.createKey() } }
        .accessibilityIdentifier("exeDevSetup.createKey")
    case .keyUnusable(let said):
      detail(
        "Workroom couldn't sign in with your SSH key (\(said)). If it has a passphrase, add it "
          + "to your ssh agent with `ssh-add`, then try again.")
      Button("Try Again") { Task { await setup.refresh() } }
    case .needsEmail(let error):
      detail(
        "Your SSH key is your exe.dev login. Enter your email to create an account, or the "
          + "email of the account you already have, and exe.dev sends you a link to confirm it.")
      HStack {
        TextField("Email", text: $email, prompt: Text("you@example.com"))
          .textFieldStyle(.roundedBorder)
          .textContentType(.emailAddress)
          .focused($emailFocused)
          .onSubmit(submitEmail)
          .accessibilityIdentifier("exeDevSetup.email")
        Button("Send Link", action: submitEmail)
          .disabled(!email.contains("@"))
          .accessibilityIdentifier("exeDevSetup.sendLink")
      }
      .onAppear { emailFocused = true }
      if let error { problem(error) }
      Button(error == nil ? "Sign Up in a Terminal Instead" : "Finish Signing Up in a Terminal") {
        setup.useTerminal()
      }
      .buttonStyle(.link)
      .accessibilityIdentifier("exeDevSetup.useTerminal")
    case .sending(let address):
      detail("Asking exe.dev to send a link to \(address)…")
    case .awaitingVerification(let address):
      detail(
        "Check your inbox at \(address) and click the link from exe.dev. Workroom carries on "
          + "by itself once you have.")
      Button("Use a Different Email") { setup.changeEmail() }
        .buttonStyle(.link)
    case .inTerminal:
      detail(
        "This is exe.dev's own sign-up. Enter your email when it asks, then click the link it "
          + "sends you. Workroom ticks this step once you're signed in.")
      SignUpTerminal(command: setup.signInCommand)
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: TerminalPanelMetrics.cornerRadius))
      Button("Use the Email Form") { setup.changeEmail() }
        .buttonStyle(.link)
    case .done(let address):
      detail("Signed in as \(address).")
    case .failed(let said):
      problem(said)
      Button("Try Again") { Task { await setup.refresh() } }
    }
  }

  private func submitEmail() {
    guard email.contains("@") else { return }
    Task { await setup.submit(email: email) }
  }

  // MARK: Plan and GitHub

  @ViewBuilder private var planContent: some View {
    if !setup.isSignedIn {
      detail("Choose a plan so exe.dev can run VMs for you.")
    } else {
      switch setup.plan {
      case .done:
        detail("Your plan is active.")
      case .needed, .opening:
        detail(
          "exe.dev runs VMs on a paid plan. Choose one on exe.dev, and Workroom carries on as "
            + "soon as it's active.")
        HStack {
          Button("Choose a Plan") { Task { await setup.choosePlan() } }
            .disabled(setup.plan == .opening)
            .accessibilityIdentifier("exeDevSetup.choosePlan")
          checkAgain
        }
        if let error = setup.planError { problem(error) }
      case .waiting:
        detail("Waiting for your plan on exe.dev. Finish choosing it in your browser.")
        HStack {
          Button("Open exe.dev Again") { Task { await setup.choosePlan() } }
          checkAgain
        }
        .buttonStyle(.link)
      }
    }
  }

  @ViewBuilder private var gitHubContent: some View {
    if !setup.isSignedIn {
      detail("Connect GitHub so your VMs can clone and push as you.")
    } else {
      switch setup.gitHub {
      case .done:
        detail("GitHub is connected.")
      case .needed, .opening:
        detail(
          "Lets your VMs clone and push as you, with no GitHub token on them. Connect your "
            + "GitHub account on exe.dev, and give its GitHub App access to your repositories.")
        HStack {
          Button("Connect GitHub") { Task { await setup.connectGitHub() } }
            .disabled(setup.gitHub == .opening)
            .accessibilityIdentifier("exeDevSetup.connectGitHub")
          checkAgain
        }
        if let error = setup.gitHubError { problem(error) }
      case .waiting:
        detail("Waiting for GitHub on exe.dev. Finish connecting it in your browser.")
        HStack {
          Button("Open exe.dev Again") { Task { await setup.connectGitHub() } }
          checkAgain
        }
        .buttonStyle(.link)
      }
    }
  }

  /// Reads every step from the account again: for a step done elsewhere, or a check that failed.
  private var checkAgain: some View {
    Button("Check Again") { Task { await setup.checkAgain() } }
      .disabled(setup.plan == .opening || setup.gitHub == .opening)
      .accessibilityIdentifier("exeDevSetup.checkAgain")
  }

  // MARK: Text

  private func detail(_ text: String) -> some View {
    Text(LocalizedStringKey(text))
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func problem(_ text: String) -> some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
      .font(.callout)
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A terminal of the sheet's own running `ssh exe.dev`, for a sign-up finished by hand. Not one of
/// `TerminalSessions`' tabs: it belongs to no workroom, and goes with the step.
private struct SignUpTerminal: View {
  @State private var surface: GhosttySurfaceView

  init(command: String) {
    _surface = State(
      initialValue: GhosttySurfaceView(workingDirectory: NSHomeDirectory(), command: command))
  }

  var body: some View {
    TerminalContainerView(view: surface)
      .onDisappear { surface.tearDown() }
      .accessibilityIdentifier("exeDevSetup.terminal")
  }
}
