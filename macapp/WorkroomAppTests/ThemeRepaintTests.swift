import AppKit
import Defaults
import DesignSystem
import SwiftUI
import XCTest

@testable import Workroom

/// A theme switch reaches every SwiftUI view through the one `themeTokensRoot()` above it, and
/// nothing else is needed: no second root inside a sheet or popover, and no `.themeDidChange` tick
/// to force a body pass. Each test hosts what it covers the way production does, under its real
/// host's root, switches family while it is on screen, and asserts it draws the new theme.
///
/// The five chrome views are checked by their pixels, not a counter: a sampled pixel only changes
/// when the view's body ran again AND read the new tokens, so it shows both at once without a seam
/// in the production view. `testAFrozenThemeShowsAsStale` is the negative control that keeps that
/// honest.
@MainActor
final class ThemeRepaintTests: XCTestCase {
  private var savedFamily: String!
  private var savedSettingsPane: SettingsPane!

  override func setUp() async throws {
    try await super.setUp()
    savedFamily = Defaults[.themeFamily]
    savedSettingsPane = Defaults[.settingsSelectedPane]
    ThemeService.shared.applyFamily(ThemeCatalog.defaultFamilyName)
    Probe.passes = [:]
    Probe.background = [:]
  }

  override func tearDown() async throws {
    ThemeService.shared.applyFamily(savedFamily)
    Defaults[.settingsSelectedPane] = savedSettingsPane
    try await super.tearDown()
  }

  // MARK: harness

  private func host<V: View>(_ hosting: NSHostingView<V>, size: NSSize) -> NSWindow {
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false  // ARC owns it; see PaneRenderingTests.host
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    return window
  }

  /// Switches to the family whose chrome differs most from the active one, so a stale view can't
  /// pass for a repainted one by drawing a near-identical colour. Returns the new tokens.
  @discardableResult
  private func switchToTheMostDifferentFamily() throws -> ThemeTokens {
    let before = ThemeService.shared.tokens
    let isDark = ThemeService.isCurrentAppearanceDark()
    let other = try XCTUnwrap(
      ThemeCatalog.families
        .filter { $0.name != Defaults[.themeFamily] }
        .max { lhs, rhs in
          Self.distance(before, Self.tokens(of: lhs, isDark: isDark))
            < Self.distance(before, Self.tokens(of: rhs, isDark: isDark))
        },
      "the catalog needs a second family to switch to")
    ThemeService.shared.applyFamily(other.name)
    let after = ThemeService.shared.tokens
    XCTAssertFalse(
      Self.near(before.nsPanel, after.nsPanel), "the two families must differ in panel colour")
    XCTAssertNotEqual(before.nsBg, after.nsBg, "the two families must differ in background")
    return after
  }

  private static func tokens(of family: ThemeFamily, isDark: Bool) -> ThemeTokens {
    ThemeTokens(
      preview: ThemeService.themePreview(
        named: ThemeCatalog.sanitizedThemeName(family.variant(isDark: isDark))))
  }

  private static func distance(_ lhs: ThemeTokens, _ rhs: ThemeTokens) -> CGFloat {
    distance(lhs.nsPanel, rhs.nsPanel) + distance(lhs.nsFg, rhs.nsFg)
  }

  private static func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
    guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else { return 0 }
    return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
      + abs(a.blueComponent - b.blueComponent)
  }

  /// Within 3/255 a channel: a rendered pixel goes through the window's colour space and back.
  private static func near(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
    guard let a = lhs?.usingColorSpace(.sRGB), let b = rhs?.usingColorSpace(.sRGB) else {
      return false
    }
    let tolerance: CGFloat = 3 / 255
    return abs(a.redComponent - b.redComponent) <= tolerance
      && abs(a.greenComponent - b.greenComponent) <= tolerance
      && abs(a.blueComponent - b.blueComponent) <= tolerance
  }

  /// The colour `view` draws in the 1pt square at `point`, as the window composites it.
  private func pixel(_ view: NSView, at point: NSPoint) -> NSColor? {
    view.layoutSubtreeIfNeeded()
    let rect = NSRect(origin: point, size: NSSize(width: 1, height: 1))
    guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
    view.cacheDisplay(in: rect, to: rep)
    return rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
  }

  /// A store whose terminals never spawn a shell or open a background session.
  private func makeStore() -> AppStore {
    let store = AppStore()
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .notBundled }, ownership: { _ in .notOwned })
    return store
  }

  /// Hosts one `make()`, switches theme, and asserts it comes to draw at `point` what a second
  /// `make()`, built after the switch, draws there.
  ///
  /// Compared with a fresh render rather than with the token's own value: a theme's colour goes
  /// through colour management on its way to the window (measured: a panel token of 0.851 red
  /// renders as 0.883), so only a render of the same view is a like-for-like reference.
  private func assertRepaints<V: View>(
    _ name: String, size: NSSize, at point: NSPoint, make: () -> V
  ) throws {
    let live = NSHostingView(rootView: make())
    let window = host(live, size: size)
    defer { window.close() }
    settle(live, seconds: 1)
    let before = try XCTUnwrap(pixel(live, at: point), "\(name) drew nothing to sample")

    try switchToTheMostDifferentFamily()
    let fresh = NSHostingView(rootView: make())
    let reference = host(fresh, size: size)
    defer { reference.close() }
    settle(fresh, seconds: 1)
    let expected = try XCTUnwrap(pixel(fresh, at: point), "a fresh \(name) drew nothing")
    XCTAssertFalse(
      Self.near(before, expected), "the two themes must draw \(name) differently at \(point)")

    settle(live, seconds: 5, until: { Self.near(pixel(live, at: point), expected) })
    let repainted = pixel(live, at: point)
    XCTAssertTrue(
      Self.near(repainted, expected),
      "\(name) kept the old theme after a switch: it draws \(String(describing: repainted)) "
        + "where a fresh one draws \(expected)")
  }

  // MARK: sheets and popovers

  private enum Slot { case sheet, popover }

  /// Reads the theme and nothing else.
  private struct Probe: View {
    static var passes: [Slot: Int] = [:]
    static var background: [Slot: NSColor] = [:]
    let slot: Slot
    @Environment(\.themeTokens) private var tokens

    var body: some View {
      Self.passes[slot, default: 0] += 1
      Self.background[slot] = tokens.nsBg
      return tokens.bg.frame(width: 120, height: 80)
    }
  }

  @Observable fileprivate final class Presented {
    var sheet = false
    var popover = false
  }

  /// Presents a probe with no root of its own, as the app's sheets and popovers would without
  /// their own `themeTokensRoot()`. Reads no theme itself.
  private struct Presenter: View {
    @Bindable var presented: Presented

    var body: some View {
      Color.clear.frame(width: 300, height: 200)
        .sheet(isPresented: $presented.sheet) { Probe(slot: .sheet) }
        .popover(isPresented: $presented.popover) { Probe(slot: .popover) }
    }
  }

  /// Presents `slot` from under a root, then switches theme while it is open, as a switch from the
  /// theme picker's popover, or the system's light/dark flip under an open sheet, does.
  private func assertPresentationRepaints(
    _ slot: Slot, present: (Presented, Bool) -> Void
  ) throws {
    let presented = Presented()
    let hosting = NSHostingView(rootView: Presenter(presented: presented).themeTokensRoot())
    let window = host(hosting, size: NSSize(width: 400, height: 300))
    defer {
      present(presented, false)
      settle(hosting, seconds: 0.6)
      window.close()
    }
    // Presented once the anchor is in a window: a popover asked for before that never attaches.
    settle(hosting, seconds: 0.3)
    present(presented, true)
    settle(hosting, seconds: 3, until: { Probe.passes[slot, default: 0] > 0 })
    let shown = try XCTUnwrap(Probe.background[slot], "the \(slot) never rendered")
    XCTAssertEqual(
      shown, ThemeService.shared.tokens.nsBg,
      "the \(slot) must inherit the root's theme, not the key's default (the system palette)")

    let after = try switchToTheMostDifferentFamily()
    let passes = Probe.passes[slot, default: 0]
    settle(hosting, seconds: 5, until: { Probe.background[slot] == after.nsBg })

    XCTAssertGreaterThan(
      Probe.passes[slot, default: 0], passes, "the switch must re-run the \(slot)'s body")
    XCTAssertEqual(
      Probe.background[slot], after.nsBg, "the \(slot) kept the old theme after a switch")
  }

  func testASheetUnderTheRootRepaintsOnASwitch() throws {
    try assertPresentationRepaints(.sheet) { $0.sheet = $1 }
  }

  func testAPopoverUnderTheRootRepaintsOnASwitch() throws {
    try assertPresentationRepaints(.popover) { $0.popover = $1 }
  }

  // MARK: the chrome that had a `.themeDidChange` tick

  /// The negative control: a tree given a fixed copy of the tokens, rather than the root, must read
  /// as stale here. Without it, the pixel tests below could pass by sampling something no theme
  /// switch changes.
  func testAFrozenThemeShowsAsStale() throws {
    let size = NSSize(width: 600, height: 30)
    let point = NSPoint(x: 300, y: 1)
    let frozen = NSHostingView(
      rootView: footer().environment(\.themeTokens, ThemeService.shared.tokens))
    let window = host(frozen, size: size)
    defer { window.close() }
    settle(frozen, seconds: 1)
    let before = try XCTUnwrap(pixel(frozen, at: point), "the fixture must draw the footer")

    try switchToTheMostDifferentFamily()
    let fresh = NSHostingView(rootView: footer().themeTokensRoot())
    let reference = host(fresh, size: size)
    defer { reference.close() }
    settle(fresh, seconds: 1)
    let expected = try XCTUnwrap(pixel(fresh, at: point))
    settle(frozen, seconds: 1)

    let drawn = pixel(frozen, at: point)
    XCTAssertFalse(Self.near(drawn, expected), "the sampler must tell the two themes apart")
    XCTAssertTrue(Self.near(drawn, before), "a frozen theme must keep drawing the old one")
  }

  /// The footer with the environment `RootWindow` gives it, minus the root.
  private func footer() -> some View {
    let store = makeStore()
    return WindowFooter()
      .environmentObject(store)
      .environmentObject(store.notifications)
      .environmentObject(CodingAgentUsageMonitor.shared)
      .environmentObject(ClaudeUsageBridge.shared)
  }

  /// Hosted as `RootView` hosts it (below `RootWindow`'s root). Sampled at its top edge, clear of
  /// its text: the panel fill.
  func testWindowFooterRepaintsOnASwitch() throws {
    try assertRepaints(
      "the window footer", size: NSSize(width: 600, height: 30), at: NSPoint(x: 300, y: 1)
    ) { footer().themeTokensRoot() }
  }

  /// Hosted as `RootView` hosts it (below `RootWindow`'s root). Sampled below its icons: the
  /// panel fill.
  func testActivityBarRepaintsOnASwitch() throws {
    try assertRepaints(
      "the activity bar", size: NSSize(width: ActivityBar.width, height: 400),
      at: NSPoint(x: 2, y: 300)
    ) {
      let store = makeStore()
      return ActivityBar()
        .themeTokensRoot()
        .environmentObject(store)
        .environmentObject(store.runCommand)
        .environmentObject(store.projectStore)
        .environmentObject(store.vcsStatus)
        .environmentObject(store.lifecycle)
        .environmentObject(store.notifications)
    }
  }

  /// Hosted as the `Settings` scene hosts it, on a pane that needs nothing beyond its environment.
  /// Sampled at the header strip's empty trailing end, clear of the sidebar and the pane's form:
  /// the panel fill.
  func testSettingsViewRepaintsOnASwitch() throws {
    Defaults[.settingsSelectedPane] = .appearance
    try assertRepaints(
      "the Settings window", size: NSSize(width: 700, height: 480), at: NSPoint(x: 690, y: 30)
    ) {
      SettingsView()
        .themeTokensRoot()
        .environmentObject(Updater())
        .environmentObject(CodingAgentUsageMonitor.shared)
        .environmentObject(ClaudeUsageBridge.shared)
    }
  }

  /// Hosted as `QuickTerminalController` hosts it, with the one tab the controller opens. Sampled
  /// inside the 8pt inset around the terminals: the panel fill.
  func testQuickTerminalContentRepaintsOnASwitch() throws {
    var opened: [TerminalPanes] = []
    defer { for sessions in opened { Task { await sessions.reapAll() } } }
    try assertRepaints(
      "the Quick Terminal", size: NSSize(width: 600, height: 400), at: NSPoint(x: 3, y: 200)
    ) {
      // A host each: a terminal's view can sit in one window only.
      let host = QuickTerminalHost(notifications: NotificationCenterStore())
      let sessions = host.terminals
      sessions.makeView = { _, cwd, command in
        GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
      }
      sessions.sessionService = PersistentSessionService(
        probe: { _ in .notBundled }, ownership: { _ in .notOwned })
      _ = sessions.addTab(for: QuickTerminalController.target())
      opened.append(sessions)
      return QuickTerminalContent(sessions: sessions).quickTerminalEnvironment(host: host)
    }
  }

  /// Hosted as `RightInspector` hosts it. It draws no fill of its own, so it is sampled on its
  /// bottom hairline (`border`).
  func testVCSToolbarRepaintsOnASwitch() throws {
    let size = NSSize(width: 320, height: VCSToolbarMetrics.height)
    let flipped = NSHostingView(rootView: EmptyView()).isFlipped
    try assertRepaints(
      "the VCS toolbar", size: size,
      at: NSPoint(x: size.width / 2, y: flipped ? size.height - 1 : 0)
    ) {
      let store = makeStore()
      return VCSToolbar(model: store.remoteState)
        .themeTokensRoot()
        .environmentObject(store)
        .environmentObject(store.vcsStatus)
    }
  }
}
