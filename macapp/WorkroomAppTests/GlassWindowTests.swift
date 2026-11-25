import AppKit
import Defaults
import SwiftUI
import XCTest

@testable import Workroom

/// The window half of Glass (#727), on real windows: under glass the window is non-opaque and its
/// own background is the window base, the theme `bg` at the Glass opacity (blurred by `WindowBlur`,
/// see `WindowBlurTests`), opaque restores the theme fill, the window still reports its own
/// visibility, and a terminal in a glass window pauses and resumes with it
/// (`GhosttySurfaceView.updateWindowVisibility`). Prior art: `SwitcherPanelTests`.
@MainActor
final class GlassWindowTests: XCTestCase {
  private var windows: [NSWindow] = []

  /// A blur that does nothing: no test here blurs a real window but the window server's occlusion
  /// test.
  override func setUp() async throws {
    try await super.setUp()
    WindowBlur.setRadius = { _, _ in }
  }

  override func tearDown() async throws {
    WindowBlur.setRadius = WindowBlur.system
    for window in windows { window.close() }
    windows = []
    try await super.tearDown()
  }

  private func makeWindow(
    _ rect: NSRect = NSRect(x: 200, y: 200, width: 320, height: 240),
    level: NSWindow.Level = .normal
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: rect, styleMask: [.titled, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(origin: .zero, size: rect.size))
    window.level = level
    windows.append(window)
    return window
  }

  /// `rootView` in a window of its own, on screen, closed in `tearDown`.
  private func host<Content: View>(_ rootView: Content) -> (NSWindow, NSHostingView<Content>) {
    let (window, view) = hostInWindow(
      rootView, size: NSSize(width: 320, height: 240), origin: NSPoint(x: 200, y: 200),
      styleMask: [.titled, .resizable, .fullSizeContentView])
    windows.append(window)
    return (window, view)
  }

  /// The window base per state (#725): the theme `bg` at 90% under glass, the one tint under every
  /// pixel; opaque, the theme panel, as before Glass.
  func testTheWindowBaseIsTheBackgroundAtTheOpacityUnderGlassAndThePanelOpaque() {
    let tokens = ThemeService.shared.tokens
    let window = makeWindow()

    WindowBackgroundThemer.apply(to: window, glass: .glass(opacity: 0.9))
    XCTAssertFalse(window.isOpaque)
    XCTAssertEqual(window.backgroundColor, tokens.nsBg.withAlphaComponent(0.9))
    XCTAssertEqual(
      window.backgroundColor, WindowBackgroundThemer.baseColor(.glass(opacity: 0.9), tokens: tokens)
    )

    WindowBackgroundThemer.apply(to: window, glass: .opaque)
    XCTAssertTrue(window.isOpaque)
    XCTAssertEqual(window.backgroundColor, ThemeFill.panel.nsColor())
    XCTAssertEqual(WindowBackgroundThemer.baseColor(.opaque, tokens: tokens), tokens.nsPanel)
  }

  /// A normal title bar turns transparent under glass, so the window base shows through it, and
  /// back when opaque; the main window's and the Quick Terminal's are left to their owners.
  func testAStandardTitlebarTurnsTransparentUnderGlassOnly() {
    let window = makeWindow()
    WindowBackgroundThemer.apply(to: window, glass: .glass(opacity: 0.9), titlebar: .standard)
    XCTAssertTrue(window.titlebarAppearsTransparent)
    WindowBackgroundThemer.apply(to: window, glass: .opaque, titlebar: .standard)
    XCTAssertFalse(window.titlebarAppearsTransparent)

    let hidden = makeWindow()
    hidden.titlebarAppearsTransparent = true
    WindowBackgroundThemer.apply(to: hidden, glass: .opaque, titlebar: .hidden)
    XCTAssertTrue(hidden.titlebarAppearsTransparent, "the Quick Terminal's stays as it set it")
  }

  /// The themer reads the appearance its root injects: a hosted tree under glass turns its window
  /// glass, and one that injects nothing (a window with no `GlassWindowRoot`, such as Settings)
  /// stays opaque.
  func testTheThemerAppliesTheEnvironmentsAppearance() {
    let (glassy, glassyView) = host(
      Color.clear.background(WindowBackgroundThemer())
        .environment(\.glassAppearance, .glass(opacity: 0.9)))
    let (plain, _) = host(Color.clear.background(WindowBackgroundThemer()))
    settle(glassyView, seconds: 3, until: { !glassy.isOpaque })
    XCTAssertFalse(glassy.isOpaque, "the glass tree turned its window glass within 3 s")
    XCTAssertTrue(plain.isOpaque)
  }

  /// An appearance change reaches the window base through the environment alone (#725): the
  /// representable's update recolours the window, with no `.themeDidChange` posted.
  func testAnAppearanceChangeRecoloursTheBaseWithNoThemeNotification() throws {
    func root(_ glass: GlassAppearance) -> AnyView {
      AnyView(
        Color.clear.background(WindowBackgroundThemer(titlebar: .standard))
          .environment(\.glassAppearance, glass))
    }
    let (window, hosting) = host(root(.glass(opacity: 0.9)))
    func alpha() -> CGFloat { window.backgroundColor.alphaComponent }
    settle(hosting, seconds: 3, until: { abs(alpha() - 0.9) < 0.001 })
    XCTAssertEqual(alpha(), 0.9, accuracy: 0.001, "the base at 90% within 3 s")

    hosting.rootView = root(.opaque)
    settle(hosting, seconds: 3, until: { window.isOpaque })
    XCTAssertTrue(window.isOpaque, "opaque within 3 s")
    XCTAssertEqual(alpha(), 1, accuracy: 0.001)
  }

  // MARK: Occlusion

  /// Waits up to 3 s for `window` to report itself `visible` (or not), and says whether it did.
  private func wait(for window: NSWindow, visible: Bool) -> Bool {
    settle(3, until: { window.occlusionState.contains(.visible) == visible })
    return window.occlusionState.contains(.visible) == visible
  }

  /// Why `occlusionSteps` shows its windows as the user would see them, the one place a unit test
  /// does (`showTestWindowVisibly`): the window server counts only opaque coverage as occluding.
  private static let seenBecause =
    "occlusion is counted only from opaque coverage, so this check needs real, opaque windows"

  /// Covers `window` with an opaque window above it and reports whether `window` saw each step:
  /// visible uncovered, not visible covered, visible again uncovered, not visible ordered out.
  private func occlusionSteps(of window: NSWindow) -> [Bool] {
    showTestWindowVisibly(window, because: Self.seenBecause)
    let shown = wait(for: window, visible: true)
    let cover = makeWindow(
      window.frame.insetBy(dx: -40, dy: -40),
      level: NSWindow.Level(rawValue: window.level.rawValue + 1))
    cover.backgroundColor = .black
    showTestWindowVisibly(cover, because: Self.seenBecause)
    let covered = wait(for: window, visible: false)
    cover.orderOut(nil)
    let uncovered = wait(for: window, visible: true)
    window.orderOut(nil)
    let hidden = wait(for: window, visible: false)
    return [shown, covered, uncovered, hidden]
  }

  /// The window server's half of #727, beside the deterministic test below: a glass window still
  /// reports its own occlusion state, which is what pauses terminal rendering. Run on an opaque
  /// window first as the control: if the test host never reports occlusion (a locked screen, no
  /// window server), that says so instead of blaming glass.
  func testAGlassWindowStillReportsItsVisibility() throws {
    let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 10)
    let control = makeWindow(level: level)
    let controlSteps = occlusionSteps(of: control)
    guard controlSteps == [true, true, true, true] else {
      throw XCTSkip("this host doesn't report occlusion for an opaque window: \(controlSteps)")
    }

    let glass = makeWindow(level: level)
    WindowBlur.setRadius = WindowBlur.system
    WindowBackgroundThemer.apply(to: glass, glass: .glass(opacity: 0.9))
    XCTAssertFalse(glass.isOpaque)
    XCTAssertEqual(
      occlusionSteps(of: glass), [true, true, true, true],
      "[shown, covered, uncovered, hidden]: a glass window must report each like an opaque one")
  }

  /// A window whose occlusion state the test sets, so the test does not hang on the window server
  /// reporting it, which a locked screen or a VM may never do. The surface reads `occlusionState` on
  /// AppKit's change notification, which the test posts.
  private final class OcclusionWindow: NSWindow {
    var reportsVisible = true
    override var occlusionState: NSWindow.OcclusionState { reportsVisible ? .visible : [] }
  }

  private func setVisible(_ visible: Bool, _ window: OcclusionWindow) {
    window.reportsVisible = visible
    NotificationCenter.default.post(
      name: NSWindow.didChangeOcclusionStateNotification, object: window)
  }

  /// Value: protects=a terminal in a glass window stops rendering when the window reports itself
  /// hidden and resumes when it reports itself visible (#727); fails_when=the surface stops
  /// following its window's occlusion state; seam=the window's `occlusionState` and AppKit's
  /// change notification; no_claim=that the window server reports occlusion for a non-opaque
  /// window, which depends on the host (`testAGlassWindowStillReportsItsVisibility`)
  func testATerminalInAGlassWindowPausesAndResumesWithTheWindowsVisibility() {
    let window = OcclusionWindow(
      contentRect: NSRect(x: 200, y: 200, width: 320, height: 240),
      styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    windows.append(window)
    let terminal = GhosttySurfaceView(
      workingDirectory: NSTemporaryDirectory(), spawnsSurface: false)
    window.contentView = terminal
    WindowBackgroundThemer.apply(to: window, glass: .glass(opacity: 0.9))
    XCTAssertFalse(window.isOpaque, "the window is glass")

    settle(3, until: { terminal.rendersVisible })
    XCTAssertTrue(terminal.rendersVisible, "rendering within 3 s in a visible glass window")
    setVisible(false, window)
    settle(3, until: { !terminal.rendersVisible })
    XCTAssertFalse(
      terminal.rendersVisible,
      "rendering paused within 3 s of the glass window reporting itself hidden")
    setVisible(true, window)
    settle(3, until: { terminal.rendersVisible })
    XCTAssertTrue(
      terminal.rendersVisible,
      "rendering resumed within 3 s of the glass window reporting itself visible")
  }

}
