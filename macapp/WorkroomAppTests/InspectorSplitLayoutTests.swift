import AppKit
import XCTest

@testable import Workroom

/// Headless tests for `InspectorSplitContainerController`'s drag-capture logic — the part of the
/// raw-`NSSplitView` glue that isn't Apple's. The split view's actual frame distribution is verified
/// by manual QA + the policy tests (`InspectorPanePolicyTests`); here we check that a *user* divider
/// drag is reported back (for per-workroom persistence) while programmatic / window-resize layout is
/// not. No window or live layout needed.
@MainActor
final class InspectorSplitLayoutTests: XCTestCase {
  private func makeContainer(heights: [CGFloat]) -> InspectorSplitContainerController {
    let container = InspectorSplitContainerController()
    let panes = (0..<InspectorSectionKind.allCases.count).map { _ in InspectorPaneViewController() }
    container.install(panes: panes)
    for (index, pane) in panes.enumerated() {
      pane.view.frame = CGRect(x: 0, y: 0, width: 300, height: heights[index])
    }
    return container
  }

  private func resizeNotification(
    _ container: InspectorSplitContainerController, dividerIndex: Int?
  )
    -> Notification
  {
    Notification(
      name: NSSplitView.didResizeSubviewsNotification, object: container.splitView,
      userInfo: dividerIndex.map { ["NSSplitViewDividerIndex": $0] })
  }

  func testInstallCreatesOnePanePerSection() {
    let container = makeContainer(heights: [200, 200, 200])
    XCTAssertEqual(container.panes.count, InspectorSectionKind.allCases.count)
    XCTAssertEqual(container.splitView.arrangedSubviews.count, InspectorSectionKind.allCases.count)
  }

  func testUserDividerDragReportsPaneWeights() {
    let container = makeContainer(heights: [300, 100, 200])
    container.isLikelyUserDrag = { true }
    var reported: [Double]?
    container.onWeightsChanged = { reported = $0 }
    container.splitViewDidResizeSubviews(resizeNotification(container, dividerIndex: 0))
    XCTAssertEqual(reported, [300, 100, 200], "a divider drag reports the current pane heights")
  }

  func testProgrammaticResizeDoesNotReport() {
    let container = makeContainer(heights: [300, 100, 200])
    container.isLikelyUserDrag = { true }  // even with a "drag", no divider index → ignored
    var reported: [Double]?
    container.onWeightsChanged = { reported = $0 }
    // No divider index → not a user drag (programmatic setPosition / window resize): ignored.
    container.splitViewDidResizeSubviews(resizeNotification(container, dividerIndex: nil))
    XCTAssertNil(reported)
  }

  func testResizeWithoutMouseDownDoesNotReport() {
    let container = makeContainer(heights: [300, 100, 200])
    container.isLikelyUserDrag = { false }  // animation / programmatic: no mouse button held
    var reported: [Double]?
    container.onWeightsChanged = { reported = $0 }
    container.splitViewDidResizeSubviews(resizeNotification(container, dividerIndex: 0))
    XCTAssertNil(reported, "a resize with no mouse button down is not a user drag")
  }

  func testCollapsedPaneKeepsItsWeightOnDrag() {
    let container = makeContainer(heights: [300, 34, 200])
    container.update(workroomKey: "k", collapsed: [false, true, false], weights: [1, 5, 1])
    container.isLikelyUserDrag = { true }
    var reported: [Double]?
    container.onWeightsChanged = { reported = $0 }
    container.splitViewDidResizeSubviews(resizeNotification(container, dividerIndex: 0))
    // Pane 1 is collapsed, so its remembered weight (5) is preserved rather than overwritten with
    // its header height; the expanded panes report their live heights.
    XCTAssertEqual(reported, [300, 5, 200])
  }

  // MARK: Persisted-layout migration (issue #24; Notifications removed, 4 → 3, issue #118)

  func testReconcileDiscardsStalePreNotificationRemovalLayout() {
    // A count-4 layout saved while the inspector still had a Notifications section is discarded to
    // the all-expanded / equal-weight default rather than mis-mapped onto the new 3-section ordering.
    let stale = InspectorPaneState(collapsed: [true, false, true, false], weights: [2, 1, 3, 1])
    let result = AppStore.reconcileInspectorState(stale, sectionCount: 3)
    XCTAssertEqual(result.collapsed, [false, false, false])
    XCTAssertEqual(result.weights, [1, 1, 1])
  }

  func testReconcileDiscardsStalePreFilesLayout() {
    // A count-2 layout saved before the Files section existed is likewise discarded to the default.
    let stale = InspectorPaneState(collapsed: [true, false], weights: [2, 1])
    let result = AppStore.reconcileInspectorState(stale, sectionCount: 3)
    XCTAssertEqual(result.collapsed, [false, false, false])
    XCTAssertEqual(result.weights, [1, 1, 1])
  }

  func testReconcileKeepsMatchingCountLayout() {
    let saved = InspectorPaneState(collapsed: [true, false, false], weights: [1, 2, 1])
    let result = AppStore.reconcileInspectorState(saved, sectionCount: 3)
    XCTAssertEqual(result.collapsed, [true, false, false])
    XCTAssertEqual(result.weights, [1, 2, 1])
  }
}
