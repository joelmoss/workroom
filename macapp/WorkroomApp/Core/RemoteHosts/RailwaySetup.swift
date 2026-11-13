import Foundation
import HostDrivers

/// Gets a user ready for Railway workrooms (ADR 0073, #627), in the setup sheet:
///
/// - **Account.** Login with Railway in the browser: the user ticks the workspaces to share on
///   Railway's consent page, and Workroom keeps the sign-in. No token to paste.
/// - **Workspace.** The workspaces they granted (`me { workspaces }`), one of which holds the
///   `Workroom` project (ADR 0071). When the workspace of the project already recorded isn't among
///   them, the sheet says so and offers to sign in again. Trial and Free are refused with the
///   reason: Railway destroys their idle sandboxes after 5 minutes, and that can't be turned off.
///
/// Signing out is allowed, after `signOutWarning`.
@MainActor
@Observable
final class RailwaySetup: RemoteSetup {
  enum Account: Equatable {
    case checking
    /// Not signed in, with why when a sign-in ended or failed.
    case signedOut(String?)
    /// The browser is open on Railway's consent page.
    case signingIn
    case signedIn
    /// Railway couldn't be asked (the network, Railway's servers): its words.
    case failed(String)
  }

  /// What signing out says first: Railway workrooms aren't touched by it.
  static let signOutWarning =
    "Your Railway workrooms' sandboxes keep running, and Railway keeps billing for them, until "
    + "you delete them. Workroom can't reach them until you sign in again. To stop paying, delete "
    + "the workrooms first, or their sandboxes on Railway's dashboard."

  private(set) var account: Account = .checking
  /// The workspaces the user granted, in Railway's order.
  private(set) var workspaces: [RailwayWorkspace] = []
  /// Each workspace's Trial, where Railway answered (whether a member may read a workspace's
  /// billing isn't documented, so a check that fails is left out, and doesn't refuse).
  private(set) var trialing: [String: Bool] = [:]
  /// The workspace the `Workroom` project goes in.
  private(set) var selectedWorkspaceID: String?
  /// The workspace holding the project already recorded, which the sign-in must reach.
  let neededWorkspaceID: String?

  private let railway: RailwayAccount
  /// The sign-in waiting on the browser, which closing the sheet stops.
  private var signingIn: Task<Result<Void, Error>, Never>?
  private var isCancelled = false

  init(account: RailwayAccount, neededWorkspaceID: String?) {
    railway = account
    self.neededWorkspaceID = neededWorkspaceID
  }

  /// The project's workspace isn't among those granted.
  var neededWorkspaceMissing: Bool {
    guard account == .signedIn, let neededWorkspaceID else { return false }
    return !workspaces.contains { $0.id == neededWorkspaceID }
  }

  var selectedWorkspace: RailwayWorkspace? {
    workspaces.first { $0.id == selectedWorkspaceID }
  }

  /// Why the selected workspace is refused, or nil.
  var selectedRefusal: RailwayPlanRefusal? {
    selectedWorkspace.flatMap { refusal(of: $0) }
  }

  func refusal(of workspace: RailwayWorkspace) -> RailwayPlanRefusal? {
    workspace.refusal(trialing: trialing[workspace.id])
  }

  var isReady: Bool {
    account == .signedIn && selectedWorkspace != nil && selectedRefusal == nil
      && !neededWorkspaceMissing
  }

  /// Reads the account: the kept sign-in, and its workspaces.
  func refresh() async {
    account = .checking
    guard await railway.session.isSignedIn else {
      account = .signedOut(nil)
      return
    }
    await loadWorkspaces()
  }

  /// Login with Railway in the browser. Run again, it replaces the sign-in, so the user can
  /// change which workspaces they share.
  func signIn() async {
    signingIn?.cancel()
    account = .signingIn
    let railway = self.railway
    let task = Task<Result<Void, Error>, Never> {
      do {
        try await railway.signInWithBrowser()
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    signingIn = task
    let result = await task.value
    // Superseded by another sign-in, or the sheet closed.
    guard signingIn == task, !isCancelled else { return }
    signingIn = nil
    switch result {
    case .success: await loadWorkspaces()
    case .failure(let error as RailwayOAuthError):
      account = .signedOut(error.localizedDescription)
    case .failure(is CancellationError): account = .signedOut(nil)
    case .failure(let error): account = .signedOut(error.localizedDescription)
    }
  }

  /// Forgets the sign-in, once the user has read `signOutWarning`.
  func signOut() async {
    signingIn?.cancel()
    do {
      try await railway.session.signOut()
      workspaces = []
      trialing = [:]
      selectedWorkspaceID = nil
      account = .signedOut(nil)
    } catch {
      account = .failed(error.localizedDescription)
    }
  }

  /// Picks the workspace the `Workroom` project goes in.
  func select(_ id: String) async {
    guard workspaces.contains(where: { $0.id == id }) else { return }
    selectedWorkspaceID = id
  }

  /// The sheet is gone: a sign-in still waiting on the browser stops listening.
  func cancel() {
    isCancelled = true
    signingIn?.cancel()
    signingIn = nil
  }

  private func loadWorkspaces() async {
    let api = railway.api
    do {
      let granted = try await api.grantedWorkspaces()
      var trials: [String: Bool] = [:]
      await withTaskGroup(of: (String, Bool?).self) { group in
        for workspace in granted {
          group.addTask { (workspace.id, try? await api.isTrialing(workspaceID: workspace.id)) }
        }
        for await (id, trialing) in group {
          if let trialing { trials[id] = trialing }
        }
      }
      guard !isCancelled else { return }
      workspaces = granted
      trialing = trials
      account = .signedIn
      selectedWorkspaceID = defaultSelection()
    } catch RailwaySessionError.signedOut {
      clear()
      account = .signedOut("Your Railway sign-in has ended. Sign in again to carry on.")
    } catch {
      account = .failed(error.localizedDescription)
    }
  }

  private func clear() {
    workspaces = []
    trialing = [:]
    selectedWorkspaceID = nil
  }

  /// The project's workspace, else the one already picked, else the first allowed, else the first.
  private func defaultSelection() -> String? {
    let ids = workspaces.map(\.id)
    if let neededWorkspaceID, ids.contains(neededWorkspaceID) { return neededWorkspaceID }
    if let selectedWorkspaceID, ids.contains(selectedWorkspaceID) { return selectedWorkspaceID }
    return (workspaces.first { refusal(of: $0) == nil } ?? workspaces.first)?.id
  }
}
