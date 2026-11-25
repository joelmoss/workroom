import AppKit
import Defaults
import GhosttyKit
import ObjectiveC
import SwiftUI
import XCTest

@testable import Workroom

/// Glass beyond the main window (#731), on real windows: the Quick Terminal and a detached pane's
/// window go glass and back with the setting, each on the window base (the theme `bg` at the
/// Glass opacity), and each window resolves its own full screen live. Every terminal draws the one
/// app config (`background-opacity = 0` under glass); what lies behind it (`View.terminalBase`) is
/// clear in a glass window and the opaque theme background in one that resolves opaque. Surfaces
/// are non-spawning (no PTY or renderer in the test host), so the config is checked on the
/// engine. Prior art: `GlassWindowTests`, `QuickTerminalControllerTests`, `ThemeFillTests`.
@MainActor
final class GlassOtherWindowsTests: XCTestCase {
  private var savedGlass: Double!
  private var windows: [NSWindow] = []

  override func setUp() async throws {
    try await super.setUp()
    savedGlass = Defaults[.glassOpacity]
    if GlassService.shared.reduceTransparency {
      throw XCTSkip("this host has Reduce transparency on, which always resolves opaque")
    }
    setGlass(true)
  }

  override func tearDown() async throws {
    for window in windows { window.close() }
    windows = []
    Defaults[.glassOpacity] = savedGlass
    GlassService.shared.refresh()
    try await super.tearDown()
  }

  /// Glass on at 90%, or off (100%).
  private func setGlass(_ on: Bool) { setGlassOpacity(on ? 0.9 : 1) }

  private func setGlassOpacity(_ opacity: Double) {
    Defaults[.glassOpacity] = opacity
    // Synchronous, rather than waiting for the settings observation to hop over.
    GlassService.shared.refresh()
  }

  /// Waits up to 3 s for `condition`, laying out `window` (and `others`) as it goes: that runs
  /// their Glass roots' updates now, rather than on a display cycle an inactive test host may skip.
  private func wait(_ window: NSWindow, _ others: NSWindow..., until condition: () -> Bool) {
    guard let view = window.contentView else { return }
    settle(view, seconds: 3) {
      for other in others { other.contentView?.layoutSubtreeIfNeeded() }
      return condition()
    }
  }

  /// What `window` draws at its centre, as its views composite it (the window's own background
  /// is not part of it). `ThemeFillTests.pixel`'s technique.
  private func pixel(_ window: NSWindow) -> NSColor? {
    guard let view = window.contentView else { return nil }
    view.layoutSubtreeIfNeeded()
    let rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
    view.cacheDisplay(in: rect, to: rep)
    return rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
  }

  /// What `fill` renders as in a plain window, through the same capture as `pixel`.
  private func renderedReference(_ fill: Color) -> NSColor {
    let (window, _) = hostInWindow(fill, size: NSSize(width: 40, height: 40))
    defer { window.close() }
    return pixel(window) ?? .clear
  }

  private static func near(_ lhs: NSColor?, _ rhs: NSColor) -> Bool {
    guard let a = lhs?.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else {
      return false
    }
    return abs(a.redComponent - b.redComponent) < 0.02
      && abs(a.greenComponent - b.greenComponent) < 0.02
      && abs(a.blueComponent - b.blueComponent) < 0.02
  }

  /// A terminal's backing as the pane leaf lays it, over black so "draws nothing" is visible.
  private func terminalBacking() -> some View {
    Color.clear.terminalBase().background(Color.black)
  }

  private func behindWindowBlurs(in window: NSWindow) -> Int {
    func walk(_ view: NSView) -> Int {
      ((view as? NSVisualEffectView)?.blendingMode == .behindWindow ? 1 : 0)
        + view.subviews.map(walk).reduce(0, +)
    }
    return (window.contentView?.superview ?? window.contentView).map(walk) ?? 0
  }

  private func surface() -> GhosttySurfaceView {
    GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), spawnsSurface: false)
  }

  // MARK: The Quick Terminal

  func testTheQuickTerminalFollowsGlassLive() throws {
    let controller = QuickTerminalController()
    controller.makeSurface = {
      GhosttySurfaceView(workingDirectory: $0, command: $1, spawnsSurface: false)
    }
    // No real background helper; its first health check already answered, so the summon is now.
    let service = PersistentSessionService(
      probe: { _ in .notBundled }, ownership: { _ in .notOwned })
    _ = service.backend
    controller.sessionServiceOverride = service
    controller.hidesWhenUnfocused = { false }
    defer { controller.close() }
    controller.toggle()
    let window = try XCTUnwrap(controller.currentWindow)
    let terminal = try XCTUnwrap(controller.currentSurface)

    XCTAssertFalse(window.isOpaque, "glass as soon as the controller installs its content")
    XCTAssertEqual(behindWindowBlurs(in: window), 0, "the window server blurs; no view does")
    XCTAssertEqual(
      window.backgroundColor, ThemeService.shared.tokens.nsBg.withAlphaComponent(0.9),
      "the window base")
    // Its hosted tree mounts the terminal in the window.
    wait(window) { terminal.window === window }
    XCTAssertTrue(terminal.window === window, "within 3 s of opening")

    setGlass(false)
    wait(window) { window.isOpaque }
    XCTAssertTrue(window.isOpaque, "opaque within 3 s of turning Glass off, on the open window")
    XCTAssertEqual(window.backgroundColor, ThemeFill.panel.nsColor(), "the theme fill when opaque")
    XCTAssertEqual(behindWindowBlurs(in: window), 0)
  }

  // MARK: Occlusion

  /// The windows `fakeOcclusion` reports hidden.
  private nonisolated(unsafe) static var hiddenWindows: Set<ObjectIdentifier> = []

  /// Makes `window`, which its controller built, report the occlusion state the returned setter
  /// gives it, and posts AppKit's change notification as the setter runs. The controller's window
  /// can't be `GlassWindowTests`' `OcclusionWindow`, so its own class (`QuickTerminalWindow`,
  /// `DetachedPaneWindow`, neither of which overrides `occlusionState`) gets an `occlusionState`
  /// that reads `hiddenWindows`, restored to `NSWindow`'s in a teardown block. (A runtime subclass
  /// would be tidier, but AppKit's dynamic properties assert on one.) The test then doesn't hang on
  /// the window server reporting occlusion, which a locked screen or a VM may never do.
  private func fakeOcclusion(of window: NSWindow) throws -> (Bool) -> Void {
    let windowClass: AnyClass = type(of: window)
    let selector = #selector(getter: NSWindow.occlusionState)
    let original = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, selector))
    let types = method_getTypeEncoding(original)
    let getter: @convention(block) (NSWindow) -> UInt = { window in
      Self.hiddenWindows.contains(ObjectIdentifier(window))
        ? 0 : NSWindow.OcclusionState.visible.rawValue
    }
    class_replaceMethod(windowClass, selector, imp_implementationWithBlock(getter), types)
    addTeardownBlock { @MainActor in
      class_replaceMethod(windowClass, selector, method_getImplementation(original), types)
      Self.hiddenWindows = []
    }
    return { visible in
      if visible {
        Self.hiddenWindows.remove(ObjectIdentifier(window))
      } else {
        Self.hiddenWindows.insert(ObjectIdentifier(window))
      }
      NotificationCenter.default.post(
        name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }
  }

  /// Waits up to 3 s for `terminal` to render (or not), and says whether it did.
  private func waitRenders(_ terminal: GhosttySurfaceView, _ renders: Bool) -> Bool {
    settle(3, until: { terminal.rendersVisible == renders })
    return terminal.rendersVisible == renders
  }

  /// Value: protects=a glass Quick Terminal's terminal stops rendering while the Quick Terminal is
  /// hidden and resumes when it is shown again (#731); fails_when=the terminal stops following
  /// its own window's occlusion state under glass; seam=the window's `occlusionState`, set by the
  /// test, and AppKit's change notification; no_claim=that the window server reports occlusion for
  /// a non-opaque window (`GlassWindowTests.testAGlassWindowStillReportsItsVisibility`)
  func testAGlassQuickTerminalPausesWhileHiddenAndResumesWhenShown() throws {
    let controller = QuickTerminalController()
    controller.makeSurface = {
      GhosttySurfaceView(workingDirectory: $0, command: $1, spawnsSurface: false)
    }
    let service = PersistentSessionService(
      probe: { _ in .notBundled }, ownership: { _ in .notOwned })
    _ = service.backend
    controller.sessionServiceOverride = service
    controller.hidesWhenUnfocused = { false }
    defer { controller.close() }
    controller.toggle()
    let window = try XCTUnwrap(controller.currentWindow)
    let terminal = try XCTUnwrap(controller.currentSurface)
    XCTAssertFalse(window.isOpaque, "the Quick Terminal is glass")
    let setVisible = try fakeOcclusion(of: window)
    wait(window) { terminal.window === window }
    XCTAssertTrue(waitRenders(terminal, true), "rendering within 3 s of the summon")

    controller.hide()
    settle(3, until: { !window.isVisible })
    XCTAssertFalse(window.isVisible, "ordered out within 3 s")
    setVisible(false)
    XCTAssertTrue(waitRenders(terminal, false), "paused within 3 s of hiding")

    controller.show()
    settle(3, until: { window.isVisible })
    XCTAssertTrue(window.isVisible, "shown again within 3 s")
    setVisible(true)
    XCTAssertTrue(waitRenders(terminal, true), "resumed within 3 s of showing again")
  }

  /// Value: protects=a glass detached pane's terminal stops rendering while its window is ordered
  /// out and resumes when it is shown again (#731); fails_when=the terminal stops following its
  /// own window's occlusion state under glass; seam=the window's `occlusionState`, set by the test,
  /// and AppKit's change notification; no_claim=that the window server reports occlusion for a
  /// non-opaque window
  func testAGlassDetachedPanePausesWhileHiddenAndResumesWhenShown() throws {
    let terminal = surface()
    let detached = DetachedPaneWindows()
    let tabID = UUID()
    detached.open(
      tabID: tabID, title: "pane", project: "p", workroom: nil, origin: nil,
      onCloseTab: {}, onDock: {}, content: { SurfaceHost(surface: terminal).terminalBase() })
    defer { detached.close(tabID: tabID) }
    let window = try XCTUnwrap(detached.window(for: tabID))
    XCTAssertFalse(window.isOpaque, "the detached pane's window is glass")
    let setVisible = try fakeOcclusion(of: window)
    wait(window) { terminal.window === window }
    XCTAssertTrue(terminal.window === window, "the terminal mounted within 3 s")
    XCTAssertTrue(waitRenders(terminal, true), "rendering within 3 s of opening")

    window.orderOut(nil)
    setVisible(false)
    XCTAssertTrue(waitRenders(terminal, false), "paused within 3 s of ordering out")

    showTestWindow(window)
    setVisible(true)
    XCTAssertTrue(waitRenders(terminal, true), "resumed within 3 s of showing again")
  }

  // MARK: Detached panes

  func testADetachedPanesWindowFollowsGlassLive() throws {
    let detached = DetachedPaneWindows()
    let tabID = UUID()
    detached.open(
      tabID: tabID, title: "pane", project: "p", workroom: nil, origin: nil,
      onCloseTab: {}, onDock: {}, content: { Color.clear.frame(width: 200, height: 120) })
    defer { detached.close(tabID: tabID) }
    let window = try XCTUnwrap(detached.window(for: tabID))

    XCTAssertFalse(window.isOpaque, "glass as soon as the controller installs its content")
    XCTAssertEqual(behindWindowBlurs(in: window), 0, "the window server blurs; no view does")
    XCTAssertEqual(
      window.backgroundColor, ThemeService.shared.tokens.nsBg.withAlphaComponent(0.9),
      "the window base")

    setGlass(false)
    wait(window) { window.isOpaque }
    XCTAssertTrue(window.isOpaque, "opaque within 3 s of turning Glass off")
    XCTAssertEqual(window.backgroundColor, ThemeFill.panel.nsColor(), "the theme fill when opaque")
  }

  // MARK: Full screen, per window

  /// A window that says it is in native full screen when told to, so the test needn't take the
  /// screen over: the root reads `styleMask` on AppKit's enter and exit notifications.
  private final class FullScreenWindow: NSWindow {
    var fakesFullScreen = false
    override var styleMask: NSWindow.StyleMask {
      get { fakesFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
      set { super.styleMask = newValue }
    }
  }

  /// The fill behind a terminal follows its own window: the opaque theme background in a
  /// full-screen window, clear in the other, still frosted one, and clear again on leaving full
  /// screen, while every terminal keeps the one app config, which draws no default background.
  func testEachWindowGoesOpaqueInFullScreenAndFrostsAgainOnLeavingIt() throws {
    let ghostty = GhosttyApp.shared
    ghostty.reloadConfig(force: true, dark: ThemeService.isCurrentAppearanceDark())
    let config = try XCTUnwrap(ghostty.config)
    let tokens = ThemeService.shared.tokens
    func makeWindow() -> FullScreenWindow {
      let window = FullScreenWindow(
        contentRect: NSRect(x: 200, y: 200, width: 320, height: 240),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: terminalBacking().modifier(GlassWindowRoot(titlebar: .standard))
          .themeTokensRoot())
      showTestWindow(window)
      // Mount the hosted tree now, rather than on a display cycle an inactive test host may skip.
      window.contentView?.layoutSubtreeIfNeeded()
      windows.append(window)
      return window
    }
    let full = makeWindow()
    let other = makeWindow()
    wait(full, other) { !full.isOpaque && !other.isOpaque }
    XCTAssertFalse(full.isOpaque, "both windows frosted within 3 s of opening")
    XCTAssertFalse(other.isOpaque, "both windows frosted within 3 s of opening")
    XCTAssertTrue(Self.near(pixel(full), .black), "under glass the terminal lies on nothing")

    full.fakesFullScreen = true
    NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: full)
    // The theme background as this display renders it: a capture's colours come back through the
    // display's profile, so in dark mode it is not the raw token (0.146 for a 0.110 grey here).
    let opaqueBg = renderedReference(Color(nsColor: tokens.nsBg))
    wait(full) { full.isOpaque && Self.near(pixel(full), opaqueBg) }
    XCTAssertTrue(full.isOpaque, "a full-screen window went opaque within 3 s")
    XCTAssertEqual(full.backgroundColor, ThemeFill.panel.nsColor())
    XCTAssertTrue(
      Self.near(pixel(full), opaqueBg),
      "its terminals lie on the opaque theme background, drew \(String(describing: pixel(full)))")
    XCTAssertEqual(
      other.backgroundColor, tokens.nsBg.withAlphaComponent(0.9), "the other window keeps the base")
    XCTAssertFalse(other.isOpaque, "while the other window stays frosted")
    XCTAssertTrue(Self.near(pixel(other), .black), "and its terminals on nothing")
    XCTAssertEqual(ghostty.config, config, "one config: full screen reloads nothing")
    XCTAssertEqual(backgroundOpacity(config), 0, accuracy: 0.001)

    full.fakesFullScreen = false
    NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: full)
    wait(full) { !full.isOpaque && Self.near(pixel(full), .black) }
    XCTAssertFalse(full.isOpaque, "leaving full screen frosted it again within 3 s")
    XCTAssertTrue(Self.near(pixel(full), .black))
  }

  // MARK: The one config

  private func backgroundOpacity(_ config: ghostty_config_t) -> Double {
    var value = 0.0
    let key = "background-opacity"
    XCTAssertTrue(ghostty_config_get(config, &value, key, UInt(key.utf8.count)))
    return value
  }

  private struct SurfaceHost: NSViewRepresentable {
    let surface: GhosttySurfaceView
    func makeNSView(context: Context) -> GhosttySurfaceView { surface }
    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {}
  }

  private func hostTerminal(_ terminal: GhosttySurfaceView) -> NSWindow {
    let (window, _) = hostInWindow(
      SurfaceHost(surface: terminal).terminalBase()
        .modifier(GlassWindowRoot(titlebar: .standard)).themeTokensRoot(),
      size: NSSize(width: 320, height: 240), origin: NSPoint(x: 200, y: 200),
      styleMask: [.titled, .resizable])
    window.contentView?.layoutSubtreeIfNeeded()
    windows.append(window)
    return window
  }

  /// Turning Glass on in Settings while terminals already exist, and back off, switches the one
  /// app config through the real path (the settings, `GlassService.shared`, the theme's config
  /// reload, and the window's Glass root), which libghostty pushes to every live terminal.
  func testALiveToggleSwitchesTheOneConfigBothWays() throws {
    setGlass(false)
    let ghostty = GhosttyApp.shared
    let terminal = surface()
    let window = hostTerminal(terminal)
    wait(window) { window.isOpaque && terminal.window === window }
    XCTAssertTrue(window.isOpaque, "Glass off: the window starts opaque")

    setGlass(true)
    wait(window) { !window.isOpaque }
    XCTAssertFalse(window.isOpaque, "the open window frosted within 3 s of turning Glass on")
    XCTAssertEqual(backgroundOpacity(try XCTUnwrap(ghostty.config)), 0, accuracy: 0.001)

    setGlass(false)
    wait(window) { window.isOpaque }
    XCTAssertTrue(window.isOpaque, "opaque again within 3 s of turning Glass off")
    XCTAssertEqual(backgroundOpacity(try XCTUnwrap(ghostty.config)), 1, accuracy: 0.001)
  }

  /// Moving the Glass slider within glass, through the real path, recolours an open window's base
  /// and leaves the terminals alone: the app config stays the one loaded. Taking it to 100% turns
  /// the window opaque.
  func testAnOpacityChangeRecoloursTheBaseAndLeavesTheTerminalsConfig() {
    let ghostty = GhosttyApp.shared
    let window = hostTerminal(surface())
    let tokens = ThemeService.shared.tokens
    wait(window) { !window.isOpaque }
    XCTAssertFalse(window.isOpaque, "frosted within 3 s of opening")
    let config = ghostty.config

    for opacity in [0.85, 0.7, 0.95] {
      setGlassOpacity(opacity)
      wait(window) { window.backgroundColor == tokens.nsBg.withAlphaComponent(opacity) }
      XCTAssertEqual(
        window.backgroundColor, tokens.nsBg.withAlphaComponent(opacity),
        "the base at \(opacity) within 3 s")
    }
    XCTAssertEqual(ghostty.config, config, "an opacity change within glass reloads no config")

    setGlassOpacity(1)
    wait(window) { window.isOpaque }
    XCTAssertTrue(window.isOpaque, "100% is opaque: Glass off")
    XCTAssertNotEqual(ghostty.config, config, "crossing 100% reloads the terminals' config")
  }
}
