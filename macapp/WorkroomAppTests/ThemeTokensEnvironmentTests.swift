import AppKit
import Defaults
import DesignSystem
import SwiftUI
import XCTest

@testable import Workroom

/// A change with nothing to do with the theme, for a root to re-run on.
@Observable private final class Unrelated {
  var count = 0
}

/// The theme reaches SwiftUI through `\.themeTokens`, injected by `themeTokensRoot()` at every root.
/// Two properties hold that up, and a view cannot show either on its own:
///
/// 1. **A switch reaches a reader.** The root's modifier reads the `@Observable` `ThemeService`, so
///    it re-injects on a switch, and a view that reads the environment repaints with the new tokens.
///    A root that injected a snapshot instead would leave its whole tree on the old theme.
/// 2. **Nothing else does.** A root body re-runs for every unrelated change (`RootView` re-renders
///    on most store publishes), and the inspector's hosting controllers get a new root view on every
///    inspector update. If either counted as a new theme, every view reading it would rebuild each
///    time, past the rows' equality gates: the invalidation storm ADR 0018 keeps out of hot rows.
@MainActor
final class ThemeTokensEnvironmentTests: XCTestCase {
  private var savedFamily: String!

  override func setUp() {
    savedFamily = Defaults[.themeFamily]
    Probe.bodyPasses = 0
    Probe.lastBackground = nil
    Root.bodyPasses = 0
  }

  override func tearDown() {
    ThemeService.shared.applyFamily(savedFamily)
  }

  /// Reads the theme and nothing else, and has no inputs, so only an environment change rebuilds it.
  private struct Probe: View {
    static var bodyPasses = 0
    static var lastBackground: NSColor?
    @Environment(\.themeTokens) private var tokens

    var body: some View {
      Self.bodyPasses += 1
      Self.lastBackground = tokens.nsBg
      return tokens.bg.frame(width: 10, height: 10)
    }
  }

  /// A root that re-runs on `model.count`, as `RootView` does on store changes.
  private struct Root: View {
    static var bodyPasses = 0
    let model: Unrelated

    var body: some View {
      Self.bodyPasses += 1
      return VStack {
        Text("\(model.count)")
        Probe()
      }
      .themeTokensRoot()
    }
  }

  private func host<V: View>(_ hosting: NSHostingView<V>) -> NSWindow {
    hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFront(nil)
    return window
  }

  /// SwiftUI can rebuild a view once on the first update after it is created, whatever its inputs
  /// (measured here: one extra pass on the first update, then none over twenty more). So the
  /// baseline is taken after one update, and what is asserted is that the updates after it
  /// rebuild nothing.
  private func passesAfterWarmUp(_ view: NSView, update: () -> Void) -> Int {
    settle(view, seconds: 0.6)
    update()
    settle(view, seconds: 0.2)
    return Probe.bodyPasses
  }

  func testASwitchReachesAReaderUnderTheRoot() throws {
    ThemeService.shared.applyFamily("Workroom")
    let hosting = NSHostingView(rootView: Root(model: Unrelated()))
    let window = host(hosting)
    defer { window.close() }
    settle(hosting, seconds: 2, until: { Probe.bodyPasses > 0 })
    let before = try XCTUnwrap(Probe.lastBackground)

    let other = try XCTUnwrap(
      ThemeCatalog.families.first { $0.name != "Workroom" }?.name,
      "fixture needs a second family to switch to")
    ThemeService.shared.applyFamily(other)
    let after = ThemeService.shared.tokens.nsBg
    XCTAssertNotEqual(before, after, "the fixture's two families must differ in background")
    settle(hosting, seconds: 5, until: { Probe.lastBackground == after })

    XCTAssertEqual(
      Probe.lastBackground, after, "the reader kept the old theme's background after a switch")
  }

  func testAnUnrelatedRootUpdateRebuildsNoReader() {
    let model = Unrelated()
    let hosting = NSHostingView(rootView: Root(model: model))
    let window = host(hosting)
    defer { window.close() }
    let passes = passesAfterWarmUp(hosting) { model.count += 1 }
    let rootPasses = Root.bodyPasses
    XCTAssertGreaterThan(passes, 0, "the fixture must render the probe")

    for _ in 0..<20 {
      model.count += 1
      settle(hosting, seconds: 0.05)
    }

    XCTAssertGreaterThan(Root.bodyPasses, rootPasses, "the unrelated change must re-run the root")
    XCTAssertEqual(
      Probe.bodyPasses, passes,
      "re-running the root rebuilt a view that reads only the theme, with the theme unchanged")
  }

  /// `InspectorPaneViewController.setContent` and `TitlebarAccessoryHost` assign a fresh rooted
  /// `AnyView` on every update of the view that owns them.
  func testReassigningAHostedRootRebuildsNoReader() {
    let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    let window = host(hosting)
    defer { window.close() }
    func assign(_ label: Int) {
      hosting.rootView = AnyView(
        AnyView(
          VStack {
            Probe()
            Text("\(label)")
          }
        ).themeTokensRoot())
    }
    assign(0)
    let passes = passesAfterWarmUp(hosting) { assign(1) }
    XCTAssertGreaterThan(passes, 0, "the fixture must render the probe")

    for label in 2..<22 {
      assign(label)
      settle(hosting, seconds: 0.05)
    }

    XCTAssertEqual(
      Probe.bodyPasses, passes,
      "re-assigning the hosted root rebuilt a view that reads only the theme, with it unchanged")
  }
}
