import HostDrivers
import SwiftUI

/// Login with Railway, the workspace and the project for this Mac's hosts (`RailwaySetup`, #627,
/// #629): sign in with the browser, pick one of the workspaces the user shared (and see why a
/// Trial or Free one can't hold hosts), then one of its projects or a new `Workroom` one, where Use
/// This Project makes this Mac's environment. Opened from Settings, it closes with Done; before a
/// create, Create Workroom carries on once the setup is ready.
struct RailwaySetupSheet: View {
  let setup: RailwaySetup
  var onCreate: (() -> Void)?
  let onCancel: () -> Void

  @State private var confirmingSignOut = false

  var body: some View {
    RemoteSetupSheet(
      title: "Set up Railway",
      intro: "[Railway](https://railway.com) runs each workroom in a sandbox of its own, in your "
        + "Railway account, on the Hobby or Pro plan. Sign in once with your browser: there's no "
        + "token to copy, and your own `railway` CLI is left as it is.",
      setup: setup, identifier: "railwaySetup", onCreate: onCreate, onCancel: onCancel
    ) {
      SetupStep(title: "Account", state: accountState) { accountContent }
      SetupStep(title: "Workspace", state: workspaceState) { workspaceContent }
      SetupStep(title: "Project", state: projectState) { projectContent }
    }
    .task { await setup.refresh() }
    .confirmationDialog(
      "Sign out of Railway?", isPresented: $confirmingSignOut, titleVisibility: .visible
    ) {
      Button("Sign Out", role: .destructive) { Task { await setup.signOut() } }
        .accessibilityIdentifier("railwaySetup.confirmSignOut")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(RailwaySetup.signOutWarning)
    }
  }

  // MARK: Account

  private var accountState: SetupStepState {
    switch setup.account {
    case .signedIn: .done
    case .checking, .signingIn: .waiting
    case .signedOut, .failed: .current
    }
  }

  @ViewBuilder private var accountContent: some View {
    switch setup.account {
    case .checking:
      SetupDetail("Checking your Railway sign-in…")
    case .signedOut(let problem):
      SetupDetail(
        "Your browser opens Railway's page. Tick the workspaces Workroom may use, then approve.")
      if let problem {
        SetupProblem(problem).accessibilityIdentifier("railwaySetup.accountProblem")
      }
      signInButton("Sign In with Railway", identifier: "railwaySetup.signIn")
    case .signingIn:
      SetupDetail(
        "Finish signing in on Railway's page in your browser. Workroom carries on by itself once "
          + "you approve.")
      HStack(spacing: 12) {
        signInButton("Open Railway Again", identifier: "railwaySetup.signInRestart")
        Button("Stop Signing In") { Task { await setup.stopSigningIn() } }
          .help("Stop waiting for Railway's page, keeping any sign-in Workroom already has.")
          .accessibilityIdentifier("railwaySetup.stopSigningIn")
      }
      .buttonStyle(.link)
    case .signedIn:
      SetupDetail("Signed in to Railway.")
        .accessibilityIdentifier("railwaySetup.signedIn")
      if let problem = setup.signInProblem {
        SetupProblem(problem).accessibilityIdentifier("railwaySetup.signInProblem")
      }
      Button("Sign Out…") { confirmingSignOut = true }
        .help("Forget Workroom's Railway sign-in. Your Railway sandboxes keep running.")
        .accessibilityIdentifier("railwaySetup.signOut")
    case .failed(let said):
      SetupProblem(said)
      Button("Try Again") { Task { await setup.refresh() } }
        .help("Ask Railway again.")
        .accessibilityIdentifier("railwaySetup.retry")
    }
  }

  private func signInButton(_ title: String, identifier: String) -> some View {
    Button(title) { Task { await setup.signIn() } }
      .help("Open Railway's sign-in page in your browser.")
      .accessibilityIdentifier(identifier)
  }

  // MARK: Workspace

  private var workspaceState: SetupStepState {
    guard setup.account == .signedIn else { return .locked }
    return setup.workspaceReady ? .done : .current
  }

  @ViewBuilder private var workspaceContent: some View {
    if setup.account != .signedIn {
      SetupDetail("Once you're signed in, pick the workspace Workroom keeps its hosts in.")
    } else if setup.neededWorkspaceMissing {
      SetupProblem(
        "The workspace with your Workroom project isn't one you shared with Workroom. Sign in "
          + "again, and tick it on Railway's page."
      )
      .accessibilityIdentifier("railwaySetup.workspaceMissing")
      signInButton("Sign In Again", identifier: "railwaySetup.signInAgain")
    } else if setup.workspaces.isEmpty {
      SetupProblem(
        "You didn't share a workspace with Workroom. Sign in again, and tick one on Railway's page."
      )
      .accessibilityIdentifier("railwaySetup.noWorkspaces")
      signInButton("Sign In Again", identifier: "railwaySetup.signInAgain")
    } else {
      SetupDetail("The workspace Workroom keeps its hosts in. These are the workspaces you shared.")
      Picker(
        "Workspace",
        selection: Binding(
          get: { setup.selectedWorkspaceID ?? "" },
          set: { id in Task { await setup.select(id) } })
      ) {
        ForEach(setup.workspaces) { workspace in
          Text("\(workspace.name) (\(planName(workspace)))").tag(workspace.id)
        }
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      .help("The workspace Workroom's Railway project goes in.")
      .accessibilityIdentifier("railwaySetup.workspace")
      if let refusal = setup.selectedRefusal {
        SetupProblem(refusal.reason).accessibilityIdentifier("railwaySetup.planRefused")
      }
      signInButton("Share Other Workspaces…", identifier: "railwaySetup.signInAgain")
        .buttonStyle(.link)
    }
  }

  // MARK: Project

  private var projectState: SetupStepState {
    guard setup.workspaceReady else { return .locked }
    if setup.placing || (setup.projects == nil && setup.projectsProblem == nil) { return .waiting }
    return setup.isPlaced ? .done : .current
  }

  @ViewBuilder private var projectContent: some View {
    if !setup.workspaceReady {
      SetupDetail("Then pick the project in that workspace this Mac's hosts go in.")
    } else if let problem = setup.projectsProblem {
      SetupProblem(problem).accessibilityIdentifier("railwaySetup.projectsProblem")
      Button("Try Again") { Task { await setup.loadProjects() } }
        .help("Read the workspace's projects again.")
        .accessibilityIdentifier("railwaySetup.projectsRetry")
    } else if let projects = setup.projects {
      SetupDetail(
        "This Mac gets an environment of its own in the project, so another Mac's cleanup never "
          + "touches its hosts. A project of their own keeps them apart from your apps.")
      Picker(
        "Project",
        selection: Binding(
          get: { setup.projectPick ?? .workroom },
          set: { setup.selectProject($0) })
      ) {
        ForEach(projects) { project in
          Text(project.name).tag(RailwayProjectPick.existing(project.id))
        }
        if setup.offersNewWorkroomProject {
          Text("New project named \(RailwayPlacement.projectName)")
            .tag(RailwayProjectPick.workroom)
        }
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      .disabled(setup.placing)
      .help("The project this Mac's Railway hosts go in.")
      .accessibilityIdentifier("railwaySetup.project")
      if let problem = setup.placementProblem {
        SetupProblem(problem).accessibilityIdentifier("railwaySetup.placementProblem")
      }
      if setup.isPlaced {
        SetupDetail("This Mac's hosts go in this project.")
          .accessibilityIdentifier("railwaySetup.placed")
      } else {
        Button(setup.placing ? "Setting Up…" : "Use This Project") {
          Task { await setup.place() }
        }
        .disabled(setup.placing || setup.projectPick == nil)
        .help(
          "Make this Mac's environment in the project, creating the project first if it's new."
        )
        .accessibilityIdentifier("railwaySetup.useProject")
      }
    } else {
      SetupDetail("Reading the workspace's projects…")
    }
  }

  private func planName(_ workspace: RailwayWorkspace) -> String {
    setup.trialing[workspace.id] == true ? "Trial" : workspace.plan.displayName
  }
}
