import XCTest

@testable import Workroom

/// Coverage for the hover-preview occlusion claim (`beginPreview`/`endPreview`, eng review D4/1A,
/// outside-voice Codex #1/#2/#13): `reconcileOcclusion` stays the sole writer of surface occlusion,
/// a claim is scoped per-target so two windows can't collide, and a claim's clear is guarded by session
/// token so two sequential hover sessions of the same tab can't clobber each other.
@MainActor
final class TerminalSessionsPreviewOcclusionTests: XCTestCase {
  private let targetA = TerminalTarget(id: "wr|/p|a", title: "a", path: "/tmp", isMissing: false)
  private let targetB = TerminalTarget(id: "wr|/p|b", title: "b", path: "/tmp", isMissing: false)

  private func makeSessions() -> TerminalSessions {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    return sessions
  }

  /// Regression guard for `reconcileOcclusion`'s existing 8+ call sites: with no preview claim active,
  /// the union added for previews must be a no-op — background tabs stay occluded, the focused tab
  /// stays visible, exactly as before this feature existed.
  func testReconcileOcclusionUnaffectedWithNoActiveClaim() {
    let s = makeSessions()
    let first = s.addTab(for: targetA)
    let second = s.addTab(for: targetA)  // focuses `second`, backgrounds `first`

    XCTAssertEqual(first.surface?.isPaneVisibleForTesting, false)
    XCTAssertEqual(second.surface?.isPaneVisibleForTesting, true)
  }

  /// `beginPreview` un-occludes a background tab without disturbing the focused tab's own visibility.
  func testBeginPreviewUnoccludesBackgroundTab() {
    let s = makeSessions()
    let focused = s.addTab(for: targetA)
    let background = s.addTab(for: targetA)
    s.focus(focused.id, for: targetA)  // re-focus the first tab, backgrounding the second

    XCTAssertEqual(background.surface?.isPaneVisibleForTesting, false)
    s.beginPreview(background.id, session: 1, for: targetA)
    XCTAssertEqual(
      background.surface?.isPaneVisibleForTesting, true, "preview claim un-occludes it")
    XCTAssertEqual(focused.surface?.isPaneVisibleForTesting, true, "focused tab unaffected")
  }

  /// `endPreview` re-occludes the tab once the claim is cleared.
  func testEndPreviewReoccludesTab() {
    let s = makeSessions()
    let focused = s.addTab(for: targetA)
    let background = s.addTab(for: targetA)
    s.focus(focused.id, for: targetA)

    s.beginPreview(background.id, session: 1, for: targetA)
    XCTAssertEqual(background.surface?.isPaneVisibleForTesting, true)
    s.endPreview(background.id, session: 1, for: targetA)
    XCTAssertEqual(background.surface?.isPaneVisibleForTesting, false)
  }

  /// The bug this feature's occlusion fix exists to prevent: an unrelated `reconcileOcclusion` call
  /// (any focus/split/close/move/reap elsewhere) must still respect an active preview claim, not just
  /// the direct `beginPreview`/`endPreview` calls.
  func testUnrelatedReconcileRespectsActiveClaim() {
    let s = makeSessions()
    let focused = s.addTab(for: targetA)
    let background = s.addTab(for: targetA)
    s.focus(focused.id, for: targetA)
    s.beginPreview(background.id, session: 1, for: targetA)

    // Something unrelated triggers a reconcile pass for the same target (e.g. addTab, close, split).
    s.reconcileOcclusion(for: targetA)

    XCTAssertEqual(
      background.surface?.isPaneVisibleForTesting, true,
      "an unrelated reconcile pass must not silently drop the active preview claim")
  }

  /// Eng review D4/1A: a claim in one target must never leak into another target's visibility set.
  func testClaimDoesNotLeakAcrossTargets() {
    let s = makeSessions()
    let aFocused = s.addTab(for: targetA)
    let aBackground = s.addTab(for: targetA)
    s.focus(aFocused.id, for: targetA)
    s.beginPreview(aBackground.id, session: 1, for: targetA)

    let bFocused = s.addTab(for: targetB)
    let bBackground = s.addTab(for: targetB)
    s.focus(bFocused.id, for: targetB)

    // targetB's own reconcile must not be affected by targetA's claim.
    XCTAssertEqual(bBackground.surface?.isPaneVisibleForTesting, false)
    XCTAssertEqual(bFocused.surface?.isPaneVisibleForTesting, true)
    // targetA's claim is still intact too.
    XCTAssertEqual(aBackground.surface?.isPaneVisibleForTesting, true)
  }

  /// Outside-voice Codex #13: two sequential hover sessions of the SAME tab must not let an old
  /// session's teardown clear a newer session's still-active claim.
  func testOldSessionCannotClearNewerSessionsClaim() {
    let s = makeSessions()
    let focused = s.addTab(for: targetA)
    let background = s.addTab(for: targetA)
    s.focus(focused.id, for: targetA)

    // Session 1 starts, then session 2 supersedes it (re-hover fast).
    s.beginPreview(background.id, session: 1, for: targetA)
    s.beginPreview(background.id, session: 2, for: targetA)

    // Session 1's (stale) teardown fires — must be a no-op, since session 2 is now the current claim.
    s.endPreview(background.id, session: 1, for: targetA)
    XCTAssertEqual(
      background.surface?.isPaneVisibleForTesting, true,
      "an old session's endPreview must not clear a newer session's active claim")

    // Session 2's own teardown DOES clear it.
    s.endPreview(background.id, session: 2, for: targetA)
    XCTAssertEqual(background.surface?.isPaneVisibleForTesting, false)
  }
}
