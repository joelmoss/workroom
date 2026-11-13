import Foundation
import HostDrivers
import XCTest

@testable import Workroom

/// The Railway setup sheet's model (`RailwaySetup`, #627), with Railway stubbed at HTTP
/// (`RailwayStub`, the one the UI test fixture uses too) and a stand-in browser that approves on
/// Railway's consent page. The OAuth and refresh rules themselves are HostDrivers'
/// `RailwaySessionTests`.
@MainActor
final class RailwaySetupTests: XCTestCase {
  private let personal = RailwayWorkspace(id: "ws-personal", name: "Personal", plan: .hobby)
  private let team = RailwayWorkspace(id: "ws-team", name: "Codaset", plan: .pro)
  private let free = RailwayWorkspace(id: "ws-free", name: "Side projects", plan: .free)

  private func setup(
    _ stub: RailwayStub, store: RailwayStub.MemoryStore = .init(), needed: String? = nil
  ) -> RailwaySetup {
    RailwaySetup(account: stub.account(store: store), neededWorkspaceID: needed)
  }

  /// Value: protects=a user Workroom has never signed in sees Sign in, and signing in through the
  /// browser lists the workspaces they granted, keeping the sign-in; fails_when=the sheet asks
  /// for a token, or lists nothing; seam=RailwaySetup over Railway stubbed at HTTP
  func testSigningInListsTheGrantedWorkspaces() async throws {
    let stub = RailwayStub(workspaces: [personal, team])
    let store = RailwayStub.MemoryStore()
    let setup = setup(stub, store: store)

    await setup.refresh()
    XCTAssertEqual(setup.account, .signedOut(nil))
    XCTAssertFalse(setup.isReady)

    await setup.signIn()

    XCTAssertEqual(setup.account, .signedIn)
    XCTAssertEqual(setup.workspaces, [personal, team])
    XCTAssertEqual(setup.selectedWorkspaceID, "ws-personal")
    XCTAssertTrue(setup.isReady)
    XCTAssertEqual(try store.read(), RailwayStub.refreshToken)
  }

  /// Value: protects=a sign-in kept from before needs no browser: the sheet opens signed in with
  /// the workspaces; seam=RailwaySetup
  func testAKeptSignInOpensSignedIn() async throws {
    let stub = RailwayStub(workspaces: [personal])
    let setup = setup(stub, store: .init(RailwayStub.refreshToken))

    await setup.refresh()

    XCTAssertEqual(setup.account, .signedIn)
    XCTAssertEqual(setup.workspaces, [personal])
    XCTAssertEqual(stub.browserOpens, 0)
  }

  /// Value: protects=when the workspace holding the `Workroom` project isn't among those granted,
  /// the sheet says so and isn't ready, and signing in again (to tick it) fixes it;
  /// fails_when=it silently picks another workspace; seam=RailwaySetup
  func testAnUngrantedWorkspaceIsSaidAndSigningInAgainFixesIt() async throws {
    let stub = RailwayStub(workspaces: [personal])
    let setup = setup(stub, store: .init(RailwayStub.refreshToken), needed: "ws-team")

    await setup.refresh()

    XCTAssertTrue(setup.neededWorkspaceMissing)
    XCTAssertFalse(setup.isReady)

    stub.workspaces = [personal, team]
    await setup.signIn()

    XCTAssertFalse(setup.neededWorkspaceMissing)
    XCTAssertEqual(setup.selectedWorkspaceID, "ws-team")
    XCTAssertTrue(setup.isReady)
  }

  /// Value: protects=Trial and Free workspaces are refused with the reason, a paid one isn't, and
  /// a trial check Railway won't answer doesn't refuse; fails_when=a Free workspace is ready, or a
  /// billing permission error locks everyone out; seam=RailwaySetup
  func testTrialAndFreeWorkspacesAreRefusedWithTheReason() async throws {
    let trial = RailwayWorkspace(id: "ws-trial", name: "New", plan: .hobby)
    let stub = RailwayStub(workspaces: [free, trial, team])
    stub.trialing = ["ws-trial": true, "ws-free": false]
    stub.trialUnreadable = ["ws-team"]
    let setup = setup(stub, store: .init(RailwayStub.refreshToken))

    await setup.refresh()

    XCTAssertEqual(setup.selectedWorkspaceID, "ws-team", "the first allowed workspace is picked")
    XCTAssertNil(setup.selectedRefusal)
    XCTAssertTrue(setup.isReady)

    await setup.select("ws-free")
    XCTAssertEqual(setup.selectedRefusal, .free)
    XCTAssertFalse(setup.isReady)

    await setup.select("ws-trial")
    XCTAssertEqual(setup.selectedRefusal, .trial)
    XCTAssertFalse(setup.isReady)
  }

  /// Value: protects=a sign-in Railway no longer accepts (a rotated refresh token used again, a
  /// revoked app) shows signed out with the reason and a Sign in; seam=RailwaySetup
  func testARefusedSignInShowsSignedOutWithTheReason() async throws {
    let stub = RailwayStub(workspaces: [personal])
    stub.refreshRefused = true
    let store = RailwayStub.MemoryStore("rt-rotated")
    let setup = setup(stub, store: store)

    await setup.refresh()

    XCTAssertEqual(
      setup.account, .signedOut("Your Railway sign-in has ended. Sign in again to carry on."))
    XCTAssertNil(try store.read())
  }

  /// Value: protects=signing out forgets the sign-in, after a warning that sandboxes keep running
  /// and billing; seam=RailwaySetup
  func testSigningOutForgetsTheSignIn() async throws {
    let stub = RailwayStub(workspaces: [personal])
    let store = RailwayStub.MemoryStore(RailwayStub.refreshToken)
    let setup = setup(stub, store: store)
    await setup.refresh()

    await setup.signOut()

    XCTAssertEqual(setup.account, .signedOut(nil))
    XCTAssertTrue(setup.workspaces.isEmpty)
    XCTAssertNil(try store.read())
    XCTAssertTrue(RailwaySetup.signOutWarning.contains("keep running"))
    XCTAssertTrue(RailwaySetup.signOutWarning.contains("bill"))
  }

  /// Value: protects=declining on Railway's page says so and stays signed out; seam=RailwaySetup
  func testDecliningOnRailwaysPageSaysSo() async {
    let stub = RailwayStub(workspaces: [personal])
    stub.declines = true
    let setup = setup(stub)

    await setup.signIn()

    XCTAssertEqual(setup.account, .signedOut("Sign-in was cancelled on Railway's page."))
  }

  /// Value: protects=signing in again to share other workspaces, then declining, keeps the
  /// sign-in already held: still signed in, workspaces listed, with why; fails_when=the sheet
  /// shows a signed-in user as signed out; seam=RailwaySetup
  func testDecliningASecondSignInKeepsTheFirst() async throws {
    let stub = RailwayStub(workspaces: [personal])
    let setup = setup(stub, store: .init(RailwayStub.refreshToken))
    await setup.refresh()
    stub.declines = true

    await setup.signIn()

    XCTAssertEqual(setup.account, .signedIn)
    XCTAssertEqual(setup.workspaces, [personal])
    XCTAssertEqual(setup.signInProblem, "Sign-in was cancelled on Railway's page.")
    XCTAssertTrue(setup.isReady)
  }

  /// Value: protects=a sign-in waiting on the browser can be stopped, back to where it was;
  /// seam=RailwaySetup.stopSigningIn
  func testStoppingASignInGoesBack() async throws {
    let stub = RailwayStub(workspaces: [personal])
    stub.browserWaits = true
    let setup = setup(stub)
    await setup.refresh()

    let signingIn = Task { await setup.signIn() }
    try await Task.sleep(for: .milliseconds(100))
    await setup.stopSigningIn()
    await signingIn.value

    XCTAssertEqual(setup.account, .signedOut(nil))
  }

  /// Value: protects=closing the sheet mid sign-in stops the redirect listener and changes
  /// nothing after; seam=RailwaySetup.cancel
  func testClosingTheSheetEndsASignIn() async throws {
    let stub = RailwayStub(workspaces: [personal])
    stub.browserWaits = true
    let setup = setup(stub)

    let signingIn = Task { await setup.signIn() }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(setup.account, .signingIn)
    setup.cancel()
    await signingIn.value

    XCTAssertNotEqual(setup.account, .signedIn)
    XCTAssertTrue(stub.tokenExchanges == 0)
  }
}
