import AppKit
import SwiftUI
import WorkroomDomain
import XCTest

@testable import Workroom

/// The creation pane's place in the accessibility tree (#483), read from the real pane renderer
/// hosted off screen, the way `PaneRenderingTests` reads its view tree.
@MainActor
final class CreationPaneAccessibilityTests: XCTestCase {
  /// Value: protects=a running create's bare pane exposes its `CreationPane` container, holding the
  /// step rows, inside its own `workroom.pane` (what the UI tests and VoiceOver navigate by);
  /// fails_when=the bare pane's single child folds into the `workroom.pane` element and the
  /// `CreationPane` identifier is lost; no_claim=XCUITest's own snapshot of the tree, a split or a
  /// failure footer
  func testARunningCreatesPaneExposesItsChecklistContainerInsideItsPane() throws {
    let store = AppStore()
    let project = Project(path: "/private/var/tmp/wr-a11y-project", vcs: "git", workrooms: [])
    let run = CreationRun(project: project, kind: .local, splitAnchor: nil, previousSelection: nil)
    run.finish("fetch", as: .skipped(reason: "No remote to fetch from"))
    run.begin("worktree")
    store.register(run)
    let sid = SidebarID.creation(project: project.path, id: run.id)

    // SwiftUI builds its accessibility nodes only for an assistive client; this attribute, which
    // VoiceOver sets on an app, asks for them in process.
    Self.setEnhancedUserInterface(true)
    defer { Self.setEnhancedUserInterface(false) }
    let root = WorkroomSplitView(
      store: store, layout: .leaf(sid), resolve: { store.target(for: $0) }, focusedID: sid,
      externalDrag: .constant(nil), localize: { _ in nil }, dropTarget: { _ in nil },
      onFocus: { _ in }, onSetRatio: { _, _ in }, onClose: { _ in }, onMove: { _, _, _, _ in }
    )
    .environmentObject(store)
    .environmentObject(store.terminals.codingAgentManager)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false  // ARC owns it; see PaneRenderingTests.host
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    var pane: AnyObject?
    let deadline = Date().addingTimeInterval(3)
    while pane == nil, Date() < deadline {
      hosting.layoutSubtreeIfNeeded()
      pane = Self.first("workroom.pane", under: hosting)
      if pane == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }
    let workroomPane = try XCTUnwrap(pane, "the pane renders")
    let checklist = try XCTUnwrap(
      Self.first("CreationPane", under: workroomPane),
      "the checklist is its own container inside the pane, not folded into it")
    XCTAssertNotNil(Self.first("CreationPane.step.worktree", under: checklist), "with its rows")
  }

  private static func setEnhancedUserInterface(_ on: Bool) {
    AXUIElementSetAttributeValue(
      AXUIElementCreateApplication(getpid()), "AXEnhancedUserInterface" as CFString,
      on as CFBoolean)
  }

  /// The first element at or under `node`, depth first, whose identifier is `identifier`. SwiftUI's
  /// nodes answer the NSAccessibility methods without declaring the protocol, hence `AnyObject`.
  private static func first(_ identifier: String, under node: AnyObject) -> AnyObject? {
    if node.accessibilityIdentifier?() == identifier { return node }
    for child in node.accessibilityChildren?() ?? [] {
      if let hit = first(identifier, under: child as AnyObject) { return hit }
    }
    return nil
  }
}
