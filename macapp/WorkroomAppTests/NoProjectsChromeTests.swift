import AppKit
import SwiftUI
import WorkroomDomain
import XCTest

@testable import Workroom

/// The window chrome with no projects: the controls for what needs one (the sidebar, the pickers,
/// the inspector) are gone, read from the real views hosted off screen, the way
/// `CreationPaneAccessibilityTests` reads the creation pane.
@MainActor
final class NoProjectsChromeTests: XCTestCase {
  private static let projectControls = [
    "toolbar.toggleSidebar", "OpenWorkroom", "NewWorkroom", "activitySection.changes",
    "activitySection.files",
  ]

  /// Value: protects=with no projects the title bar's sidebar, Open and New Workroom buttons and the
  /// activity bar's Changes and Files icons are hidden, and come back with a project;
  /// fails_when=any of them shows with no projects, or stays hidden with one; no_claim=the View
  /// menu (`ViewMenuShortcutsUITests`) and the sidebar shortcuts (`SharedPrefDefaultsTests`)
  func testTheProjectControlsShowOnlyWithAProject() throws {
    let store = AppStore()
    store.projects = []
    let empty = identifiers(rendering: store)
    XCTAssertTrue(
      empty.contains("activityBar.settings"), "the chrome rendered, and the rail keeps Settings")
    for id in Self.projectControls {
      XCTAssertFalse(empty.contains(id), "\(id) shows with no projects")
    }

    store.projects = [
      Project(path: "/private/var/tmp/wr-chrome-project", vcs: "git", workrooms: [])
    ]
    let withProject = identifiers(rendering: store)
    for id in Self.projectControls {
      XCTAssertTrue(withProject.contains(id), "\(id) is missing with a project")
    }
  }

  /// Every accessibility identifier in the leading title bar, the workroom tab bar and the activity
  /// bar, hosted together off screen for `store`.
  private func identifiers(rendering store: AppStore) -> Set<String> {
    let root = HStack(spacing: 0) {
      LeadingTitlebarBar()
      WorkroomTabBar(
        tabs: [], selectedID: nil, onSelect: { _ in }, chipPaneDrag: .constant(nil),
        localize: { _ in nil }, dropTarget: { _ in nil })
      ActivityBar()
    }
    .environmentObject(store)
    .environmentObject(store.notifications)
    .environmentObject(store.terminals)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false  // ARC owns it; see PaneRenderingTests.host
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.close() }

    // SwiftUI builds its accessibility nodes only for an assistive client; this attribute, which
    // VoiceOver sets on an app, asks for them in process.
    Self.setEnhancedUserInterface(true)
    defer { Self.setEnhancedUserInterface(false) }
    var found = Set<String>()
    let deadline = Date().addingTimeInterval(3)
    while !found.contains("activityBar.settings"), Date() < deadline {
      hosting.layoutSubtreeIfNeeded()
      found = Self.identifiers(under: hosting)
      if !found.contains("activityBar.settings") {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      }
    }
    return found
  }

  private static func setEnhancedUserInterface(_ on: Bool) {
    AXUIElementSetAttributeValue(
      AXUIElementCreateApplication(getpid()), "AXEnhancedUserInterface" as CFString,
      on as CFBoolean)
  }

  /// Every identifier at or under `node`. SwiftUI's nodes answer the NSAccessibility methods without
  /// declaring the protocol, hence `AnyObject`.
  private static func identifiers(under node: AnyObject) -> Set<String> {
    var found = Set<String>()
    if let id = node.accessibilityIdentifier?(), !id.isEmpty { found.insert(id) }
    for child in node.accessibilityChildren?() ?? [] {
      found.formUnion(identifiers(under: child as AnyObject))
    }
    return found
  }
}
