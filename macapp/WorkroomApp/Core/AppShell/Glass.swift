import AppKit
import Defaults
import SwiftUI

/// How a window draws (#725): opaque, as it always has, or frosted, with the window base tinted at
/// `opacity` over one behind-window blur. Only `GlassResolver` makes one; every consumer reads it.
enum GlassAppearance: Equatable, Sendable {
  case opaque
  case glass(opacity: Double)

  /// The Glass opacity: the alpha of the window base (`WindowBackgroundThemer.baseColor`), which
  /// the floating card lays under itself too. 1 when opaque.
  var opacity: Double {
    switch self {
    case .opaque: 1
    case .glass(let opacity): opacity
    }
  }

  var isGlass: Bool { self != .opaque }
}

/// The one place the Glass rules live. Pure: the three inputs in, the appearance out. No consumer
/// re-derives any of this.
enum GlassResolver {
  /// The Glass setting's range. 100% is opaque, which is Glass off; below 70% terminal text stops
  /// holding up over a busy desktop.
  static let opacityRange = 0.70...1.0

  /// The Glass setting as it applies: rounded to the whole percent, so a slider stop a float step
  /// off (0.7 + 6 × 0.05) is exactly its value, and clamped to `opacityRange`. The one place either
  /// happens.
  static func quantize(_ opacity: Double) -> Double {
    let percent = (opacity * 100).rounded() / 100
    return min(max(percent, opacityRange.lowerBound), opacityRange.upperBound)
  }

  /// - Parameters:
  ///   - opacity: the Glass setting, quantized here (`quantize`). 100% is opaque.
  ///   - reduceTransparency: the system accessibility setting, which always wins.
  ///   - fullScreen: whether the window is in native full screen, where nothing is behind it.
  static func resolve(opacity: Double, reduceTransparency: Bool, fullScreen: Bool)
    -> GlassAppearance
  {
    let opacity = quantize(opacity)
    guard opacity < opacityRange.upperBound, !reduceTransparency, !fullScreen else {
      return .opaque
    }
    return .glass(opacity: opacity)
  }
}

/// Holds Glass's app-wide inputs (the setting and Reduce transparency) and keeps them live, so
/// SwiftUI roots that read `appearance(fullScreen:)` re-resolve when any of them changes. A
/// window's full-screen state is its own, so it is passed in rather than held here.
///
/// The terminals share one generated Ghostty config, which under glass draws no default
/// background (`background-opacity = 0`, so the window base shows), whatever the opacity. It
/// follows `terminalAppearance`, resolved without full screen, and is rewritten (by the theme's
/// reload) only when that turns glass or opaque. An opacity change within glass reaches only the
/// windows' own background colour (`WindowBackgroundThemer`).
@MainActor @Observable
final class GlassService {
  static let shared = GlassService()

  /// The Glass setting, quantized (`GlassResolver.quantize`): 100% is off. Observable, and
  /// assigned only when the quantized value changes, so a slider drag re-resolves every window
  /// root once per percent, not once per pixel.
  private(set) var opacity: Double
  private(set) var reduceTransparency: Bool

  /// Whether `terminalAppearance` was glass at the last refresh, so a refresh knows it turned.
  @ObservationIgnored private var terminalIsGlass: Bool
  @ObservationIgnored private let readReduceTransparency: () -> Bool
  @ObservationIgnored private var settingsObservation: Defaults.Observation?
  // Never removed: the app's instance lives as long as the process, and a test's holds only a weak
  // reference, so a leftover observer does nothing.
  @ObservationIgnored private var accessibilityObserver: NSObjectProtocol?

  /// - Parameters:
  ///   - readReduceTransparency: the system setting; a seam so tests needn't touch System Settings.
  ///   - accessibilityCenter: where the system announces an accessibility display change.
  init(
    readReduceTransparency: @escaping () -> Bool = {
      NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    },
    accessibilityCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
  ) {
    self.readReduceTransparency = readReduceTransparency
    let opacity = GlassResolver.quantize(Defaults[.glassOpacity])
    let reduceTransparency = readReduceTransparency()
    self.opacity = opacity
    self.reduceTransparency = reduceTransparency
    terminalIsGlass =
      GlassResolver.resolve(
        opacity: opacity, reduceTransparency: reduceTransparency, fullScreen: false
      ).isGlass
    settingsObservation = Defaults.observe(keys: .glassOpacity, options: []) { [weak self] in
      Task { @MainActor in self?.refresh() }
    }
    accessibilityObserver = accessibilityCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { _ = self?.refresh() }
    }
  }

  /// The appearance for a window in (or out of) native full screen.
  func appearance(fullScreen: Bool) -> GlassAppearance {
    GlassResolver.resolve(
      opacity: opacity, reduceTransparency: reduceTransparency, fullScreen: fullScreen)
  }

  /// What the shared Ghostty config draws terminals at.
  var terminalAppearance: GlassAppearance { appearance(fullScreen: false) }

  /// Re-read every input. Called when the setting or Reduce transparency changes.
  ///
  /// The window background follows at once: SwiftUI roots read the observable `opacity`, so a
  /// slider drag recolours each window as it crosses a percent. The terminals' config follows only
  /// Glass turning on or off (the setting crossing 100%, or Reduce transparency): on the app's
  /// instance that re-runs the theme, which rewrites the generated config (reading
  /// `terminalAppearance`), reloads it into every live surface and posts `.themeDidChange`.
  ///
  /// - Returns: whether `terminalAppearance` turned glass or opaque.
  @discardableResult func refresh() -> Bool {
    let newOpacity = GlassResolver.quantize(Defaults[.glassOpacity])
    let newReduce = readReduceTransparency()
    // Assigned only on change, so an unrelated notification invalidates no SwiftUI root.
    if opacity != newOpacity { opacity = newOpacity }
    if reduceTransparency != newReduce { reduceTransparency = newReduce }
    let isGlass = terminalAppearance.isGlass
    guard isGlass != terminalIsGlass else { return false }
    terminalIsGlass = isGlass
    if self === Self.shared { ThemeService.shared.applyActiveTheme(force: true) }
    return true
  }
}

// MARK: The SwiftUI environment

private struct GlassAppearanceKey: EnvironmentKey {
  static let defaultValue = GlassAppearance.opaque
}

extension EnvironmentValues {
  /// The resolved Glass appearance of the window this view is in. Opaque unless the window's
  /// `GlassWindowRoot` injects otherwise. Like `\.themeTokens`, it does not cross an
  /// `NSHostingView`: a hosted tree inside such a window forwards it (`hostedRoot(glass:)`).
  var glassAppearance: GlassAppearance {
    get { self[GlassAppearanceKey.self] }
    set { self[GlassAppearanceKey.self] = newValue }
  }
}

extension View {
  /// This view as the root of a hosted tree inside a window that resolves `glass`: the window's
  /// Glass appearance forwarded and the live theme injected, neither of which crosses an
  /// `NSHostingController`, type-erased for a host whose content changes.
  func hostedRoot(glass: GlassAppearance) -> AnyView {
    AnyView(environment(\.glassAppearance, glass).themeTokensRoot())
  }
}

// MARK: A window's root

/// A window's Glass root (#727): resolves the window's appearance from the app-wide inputs and its
/// own full-screen state, injects it into `\.glassAppearance` for everything in the window, and
/// applies it to the window itself through `WindowBackgroundThemer` (which also paints the theme
/// background and, for the main window, takes the title bar over). Its own modifier so a Glass change
/// re-runs this small body, not the window's.
///
/// Every window that hosts terminals has one: the main window (`RootView`), the Quick Terminal
/// (`QuickTerminalContent`) and each detached pane (`DetachedPaneWindows.open`), so each resolves its
/// own full screen (#731). The window's one `WindowBackgroundThemer` is this one.
struct GlassWindowRoot: ViewModifier {
  /// `WindowBackgroundThemer.titlebar`: only the main window's title bar is its content.
  var titlebar = TitlebarStyle.content
  @State private var isFullScreen = false

  func body(content: Content) -> some View {
    content
      .background(WindowBackgroundThemer(titlebar: titlebar, isFullScreen: $isFullScreen))
      .environment(\.glassAppearance, GlassService.shared.appearance(fullScreen: isFullScreen))
  }
}
