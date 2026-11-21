import AppKit
import Darwin

/// Glass's one blur (#727): a pure blur of whatever is behind a window, with no material tint of
/// its own, so the theme tint at the slider's opacity is the only colour on top (ADR 0080).
///
/// It is the private CoreGraphics window-blur call Ghostty, iTerm2 and Alacritty use,
/// `CGSSetWindowBackgroundBlurRadius` on the main connection and the window's number. It is resolved
/// at runtime, so a macOS without it gives a clear, unblurred glass window, never a broken one.
@MainActor enum WindowBlur {
  /// The radius every glass window blurs at. Blur strength is fixed (#725).
  static let glassRadius = 20

  /// Sets the blur radius of the window with this window-server number.
  typealias SetRadius = (_ windowNumber: Int, _ radius: Int) -> Void

  /// This Mac's call, or nil when either CoreGraphics symbol is missing. `RTLD_DEFAULT` is `-2` on
  /// Darwin; Swift doesn't import the macro.
  static let system: SetRadius? = {
    let lookup = { dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) }
    guard let connection = lookup("CGSMainConnectionID"),
      let set = lookup("CGSSetWindowBackgroundBlurRadius")
    else { return nil }
    typealias MainConnection = @convention(c) () -> Int32
    typealias SetBlurRadius = @convention(c) (Int32, UInt32, Int32) -> Int32
    let mainConnection = unsafeBitCast(connection, to: MainConnection.self)
    let setBlurRadius = unsafeBitCast(set, to: SetBlurRadius.self)
    return { windowNumber, radius in
      _ = setBlurRadius(mainConnection(), UInt32(truncatingIfNeeded: windowNumber), Int32(radius))
    }
  }()

  /// The call `setBlurRadius` makes: `system`, unless a test swaps in a recorder (or nil, for a Mac
  /// without the call) and puts `system` back after.
  static var setRadius = system

  /// Blur what is behind `window` at `radius`; 0 clears it. Returns whether the window server was
  /// asked: not when the call is missing, nor for a window it hasn't numbered yet.
  @discardableResult static func setBlurRadius(_ radius: Int, of window: NSWindow) -> Bool {
    guard let setRadius, window.windowNumber > 0 else { return false }
    setRadius(window.windowNumber, radius)
    return true
  }
}
