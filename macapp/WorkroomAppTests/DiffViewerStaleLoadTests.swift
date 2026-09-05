import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// REGRESSION for the `.task(id:)` stale-write class (TODOS: "`.task(id:)` cancellation is not
/// reliably delivered on an in-place value swap").
///
/// A content pane is REUSED when the user picks another file — `DiffViewer` keeps its view identity
/// and only `descriptor` changes — and `DiffViewer.load` had NO staleness guard at all, so a slow
/// diff for the file the pane USED to show could resolve after the pane was retargeted and paint
/// file A's diff, plus its stats and find index, into file B's slot. This test reproduces exactly
/// that: it fails with the guard removed and passes with it restored.
///
/// **What it does NOT pin, deliberately.** The guard is `!Task.isCancelled, activeFetchKey == key`,
/// and only the first half is falsifiable here: measured in this harness, SwiftUI DOES deliver
/// cancellation for an in-place id swap, so removing the `activeFetchKey` token alone still passes.
/// The token stays because `AvatarView` measured the opposite in the live app (TODOS "`.task(id:)`
/// cancellation is not reliably delivered on an in-place value swap"), and a hosted `NSHostingView`
/// is not the app's real view tree — the flag is the guard this test proves, the token is the belt.
///
/// The race is made deterministic (not timing-dependent) by injecting `resolveDiff` and holding A's
/// resolve open until B has already committed. `onCommit` is a PER-INSTANCE seam for the same reason
/// `AvatarView.onCommit` is: the XCTest host runs the real app alongside this hosted view, so a
/// shared static would also catch commits from unrelated `DiffViewer`s.
@MainActor
final class DiffViewerStaleLoadTests: XCTestCase {

  private static let pathA = "alpha.swift"
  private static let pathB = "bravo.swift"

  /// A one-shot gate a test opens by hand, so "A's fetch is still in flight" is a fact rather than a
  /// sleep. Polled rather than continuation-based: the waiter runs on the main actor, and polling via
  /// `Task.sleep` suspends it so the run loop `settle` pumps stays live.
  private final class Gate: @unchecked Sendable {
    private var isOpen = false
    func open() { isOpen = true }
    func wait() async {
      while !isOpen { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
  }

  /// Which paths the injected resolver has actually been asked for.
  private final class Requests: @unchecked Sendable {
    private var paths: Set<String> = []
    func record(_ path: String) { paths.insert(path) }
    func contains(_ path: String) -> Bool { paths.contains(path) }
  }

  /// Lets the test swap `descriptor` from outside the hosted tree at a FIXED view-tree position —
  /// reproducing a content pane being retargeted to another file, where the slot's `@State` (and so
  /// the in-flight `.task`) is NOT torn down and recreated.
  private final class DescriptorController: ObservableObject {
    @Published var descriptor: DiffDescriptor
    init(_ descriptor: DiffDescriptor) { self.descriptor = descriptor }
  }

  private struct HostWrapper: View {
    @ObservedObject var controller: DescriptorController
    let find = FileFindModel()
    let resolve: (DiffDescriptor, String, String?) async -> DiffResult
    let onCommit: (@MainActor (DiffViewer.LoadState) -> Void)?
    var body: some View {
      var view = DiffViewer(
        descriptor: controller.descriptor, directory: "/diff-stale-load", projectRoot: nil,
        find: find)
      view.resolveDiff = resolve
      view.onCommit = onCommit
      return view.frame(width: 700, height: 500)
    }
  }

  /// A one-hunk diff whose single added line names the file it came from, so a committed
  /// `LoadState` can be attributed to A or B without any content equality subtleties.
  private func diffText(marker: String) -> String {
    """
    @@ -1,1 +1,2 @@
     context
    +\(marker)
    """
  }

  private func marker(of state: DiffViewer.LoadState?) -> String? {
    guard case .loaded(let diff) = state else { return nil }
    return diff.hunks.first?.lines.first { $0.kind == .addition }?.text
  }

  private func descriptor(_ path: String) -> DiffDescriptor {
    DiffDescriptor(path: path, change: .modified, source: .gitWorktree, isPreview: false)
  }

  private func host(
    _ controller: DescriptorController,
    resolve: @escaping (DiffDescriptor, String, String?) async -> DiffResult,
    onCommit: @escaping @MainActor (DiffViewer.LoadState) -> Void
  ) -> (NSWindow, NSView) {
    let hosting = NSHostingView(
      rootView: HostWrapper(controller: controller, resolve: resolve, onCommit: onCommit))
    hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    // Programmatic `NSWindow`s default `isReleasedWhenClosed` to true, which over-releases on top of
    // ARC — same reasoning as `DiffViewerLazyRenderingTests.host`.
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    return (window, hosting)
  }

  func testStaleDiffNeverOverwritesANewerFileInTheSamePane() throws {
    let gateA = Gate()
    let requests = Requests()
    let controller = DescriptorController(descriptor(Self.pathA))
    var lastCommitted: DiffViewer.LoadState?

    let (window, view) = host(
      controller,
      resolve: { [diffText] descriptor, _, _ in
        requests.record(descriptor.path)
        // A is held open until this test releases it; B resolves immediately.
        if descriptor.path == Self.pathA { await gateA.wait() }
        return .diff(UnifiedDiff.parse(diffText(descriptor.path)))
      },
      onCommit: { lastCommitted = $0 })
    defer { window.close() }

    // Let A's `.task` start and actually reach the gated resolve, not merely get scheduled.
    settle(view, until: { requests.contains(Self.pathA) })
    XCTAssertTrue(
      requests.contains(Self.pathA),
      "the fixture must actually reach A's resolve before the pane is retargeted")

    // Same pane, different file — B's `.task` starts while A's is left running.
    controller.descriptor = descriptor(Self.pathB)
    settle(view, until: { marker(of: lastCommitted) == Self.pathB })
    XCTAssertEqual(
      marker(of: lastCommitted), Self.pathB,
      "B's own diff must land first, to set up the real race below")

    // NOW let A's held-open resolve land, well after B has already committed.
    gateA.open()
    settle(view, seconds: 0.5)

    XCTAssertEqual(
      marker(of: lastCommitted), Self.pathB,
      "A's late-arriving, stale diff must never overwrite B's already-committed one — with no "
        + "guard at all the pane shows the previous file's diff, stats and find index")
  }
}
