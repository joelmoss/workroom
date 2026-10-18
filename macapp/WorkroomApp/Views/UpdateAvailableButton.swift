import AppKit
import DesignSystem
import SwiftUI

/// The accent "Update" pill in the trailing title bar, shown when Sparkle has found a newer version in
/// the background (a gentle reminder — see `Updater`). Tapping it runs Sparkle's standard check, which
/// presents the already-found update's install prompt. Filled with the theme accent so it reads as a
/// call to action beside the plain icon buttons. It sits at the trailing end of one larger capsule
/// in a soft accent wash, whose leading part scrolls a note that an update keeps every terminal
/// running. Renders nothing when no update is pending.
struct UpdateAvailableButton: View {
  @EnvironmentObject private var updater: Updater
  @State private var hovering = false
  private let theme = ThemeService.shared

  /// A check already in flight elsewhere blocks a new one; a download blocks a redundant click on an
  /// already-shown Sparkle progress window (`canCheckForUpdates` alone doesn't catch this — Sparkle
  /// keeps it true while its own window is up).
  private var isBusy: Bool { updater.isDownloading || !updater.canCheckForUpdates }

  /// The pill's fill: the theme accent, darkened until white ink reads on it at 4.5:1. The accent's
  /// own black-or-white ink (`accentForeground`) wins by WCAG ratio but reads poorly on a mid blue:
  /// on #5293D6 black measures 6.5:1 to white's 3.2:1 and was still hard to read. So the pill always
  /// takes white ink and moves the fill instead. Hover darkens a little further, never costing
  /// contrast. Dimmed (a check in flight) mixes it toward the theme's title-bar colour, opaque, so it
  /// recedes into the bar the same way in every theme rather than showing whatever is behind it.
  static func fill(accent: NSColor, panel: NSColor, hovering: Bool, dimmed: Bool) -> NSColor {
    let base = ThemeTokens.legible(accent, on: .white, towards: .black, target: 4.5)
    if dimmed { return dim(base, panel: panel) }
    guard hovering else { return base }
    return base.blended(withFraction: 0.15, of: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
      ?? base
  }

  /// The pill's ink: white, dimmed toward the title bar with the fill.
  static func ink(panel: NSColor, dimmed: Bool) -> NSColor {
    let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    return dimmed ? dim(white, panel: panel) : white
  }

  private static func dim(_ color: NSColor, panel: NSColor) -> NSColor {
    color.blended(withFraction: 0.45, of: panel.usingColorSpace(.sRGB) ?? panel) ?? color
  }

  /// A check in flight elsewhere: the pill can't be clicked, so it dims. A download is busy too, but
  /// its spinner and "Updating…" are worth reading at full strength.
  private var isDimmed: Bool { !updater.isDownloading && !updater.canCheckForUpdates }

  var body: some View {
    if let version = updater.availableVersionString {
      HStack(spacing: 6) {
        UpdateReassurance()
        pill(version: version)
      }
      .background(Capsule().fill(theme.tokens.accentSoft))
    }
  }

  private func pill(version: String) -> some View {
    Button {
      updater.checkForUpdates()
    } label: {
      HStack(spacing: 4) {
        if updater.isDownloading {
          ProgressView().controlSize(.mini)
          Text("Updating…").fontWeight(.regular)
        } else {
          Image(systemName: "arrow.down.circle.fill")
          Text("Update")
        }
      }
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(Color(nsColor: Self.ink(panel: theme.tokens.nsPanel, dimmed: isDimmed)))
      .padding(.horizontal, 8)
      .frame(height: 20)
      .background(
        Capsule().fill(
          Color(
            nsColor: Self.fill(
              accent: theme.tokens.nsAccent, panel: theme.tokens.nsPanel,
              hovering: hovering && !isBusy, dimmed: isDimmed)))
      )
      .contentShape(Capsule())
    }
    // Override the title bar's shared ToolbarIconButtonStyle — this is a filled pill, not an icon.
    .buttonStyle(.plain)
    .disabled(isBusy)
    // Animate the hover change imperatively, NOT via a `.animation(value: hovering)` modifier wrapping
    // the label. The modifier would also interpolate any 1pt re-round of the label's pixel-snapped
    // origin on hover-in into a visible slide (the icon-button "jumps on hover" bug, issue #78);
    // `withAnimation` confines the easing to the fill change and leaves layout to snap.
    .onHover { isHovering in
      withAnimation(.easeOut(duration: 0.12)) { hovering = isHovering }
    }
    .help(
      updater.isDownloading
        ? "Updating…" : "Update to \(version) — click to install"
    )
    .accessibilityLabel("Update available")
    .accessibilityIdentifier("toolbar.update")
  }
}

/// The note inside the Update capsule that updating loses nothing: the local agent keeps every
/// session and hands them to the new build (`AgentHandOff`), so terminals and their programs carry
/// on. The pill's type size, scrolling slowly so the whole sentence fits a small slot. Under Reduce
/// Motion a short form stands still instead.
private struct UpdateReassurance: View {
  static let message = "Safe to update: your terminals and the programs in them keep running."
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let theme = ThemeService.shared

  var body: some View {
    Group {
      if reduceMotion {
        Text("Terminals keep running")
          .font(.system(size: MarqueeView.font.pointSize))
          .foregroundStyle(theme.tokens.fg)
          .lineLimit(1)
      } else {
        Marquee(text: Self.message, color: theme.tokens.nsFg)
      }
    }
    .padding(.leading, 8)
    .frame(width: 142, height: 20)
    .help(Self.message)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.message)
    .accessibilityIdentifier("toolbar.updateNote")
  }
}

private struct Marquee: NSViewRepresentable {
  var text: String
  var color: NSColor

  func makeNSView(context: Context) -> MarqueeView { MarqueeView(text: text, color: color) }

  func updateNSView(_ view: MarqueeView, context: Context) { view.color = color }
}

/// One line of text scrolling right to left forever, as layers the compositor animates
/// (`KeyWindowAnimationView`), because the update pill can sit in the title bar for days. Two copies
/// of the text a gap apart travel one text-and-gap width per loop, so the wrap is seamless, and the
/// edges fade. Text that fits stands still.
final class MarqueeView: KeyWindowAnimationView {
  /// Points a second: slow enough to read without chasing the words.
  static let speed: CGFloat = 55
  static let gap: CGFloat = 40
  static let fadeWidth: CGFloat = 8
  static let animationKey = "marquee"
  static let font = NSFont.systemFont(ofSize: 11)

  var color: NSColor {
    didSet { if color != oldValue { applyColor() } }
  }
  let textWidth: CGFloat
  private let content = CALayer()
  private let strip = CALayer()
  private let copies = [CATextLayer(), CATextLayer()]
  private let fade = CAGradientLayer()

  init(text: String, color: NSColor) {
    self.color = color
    textWidth = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width)
    super.init(frame: .zero)
    wantsLayer = true
    fade.startPoint = CGPoint(x: 0, y: 0.5)
    fade.endPoint = CGPoint(x: 1, y: 0.5)
    fade.colors = [NSColor.clear, .black, .black, .clear].map(\.cgColor)
    layer?.addSublayer(content)
    content.addSublayer(strip)
    for copy in copies {
      copy.string = text
      copy.font = Self.font
      copy.fontSize = Self.font.pointSize
      copy.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
      strip.addSublayer(copy)
    }
    applyColor()
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

  // Never the event target: the title bar behind it still drags the window.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// Whether the text scrolls: only when it overflows, and only in a key, visible window. Pure so a
  /// test can pin the gate without a real key window.
  nonisolated static func shouldScroll(showing: Bool, textWidth: CGFloat, width: CGFloat) -> Bool {
    showing && width > 0 && textWidth > width
  }

  override func layout() {
    super.layout()
    let overflows = textWidth > bounds.width
    let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
    let y = ((bounds.height - lineHeight) / 2).rounded()
    // The first copy starts clear of the leading fade, so a paused marquee shows the opening words.
    let start = overflows ? Self.fadeWidth : 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    content.frame = bounds
    content.mask = overflows ? fade : nil
    fade.frame = content.bounds
    let edge = Self.fadeWidth / max(bounds.width, 1)
    fade.locations = [0, edge, 1 - edge, 1].map { NSNumber(value: Double($0)) }
    strip.frame = CGRect(
      x: 0, y: 0, width: start + 2 * textWidth + Self.gap, height: bounds.height)
    for (index, copy) in copies.enumerated() {
      copy.frame = CGRect(
        x: start + CGFloat(index) * (textWidth + Self.gap), y: y, width: textWidth,
        height: lineHeight)
    }
    copies[1].isHidden = !overflows
    CATransaction.commit()
    syncAnimation()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    for copy in copies { copy.contentsScale = window?.backingScaleFactor ?? 2 }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColor()
  }

  /// A dynamic colour resolves against this view's appearance, not whatever is current.
  private func applyColor() {
    var resolved = color.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
    for copy in copies { copy.foregroundColor = resolved }
  }

  override func syncAnimation() {
    setScrolling(
      Self.shouldScroll(showing: windowIsShowing, textWidth: textWidth, width: bounds.width))
  }

  /// Add or remove the scroll. Idempotent: a scroll already in flight is left alone, so a
  /// notification or layout that changes nothing never jumps the text back to the start.
  func setScrolling(_ running: Bool) {
    if !running {
      strip.removeAnimation(forKey: Self.animationKey)
      return
    }
    guard strip.animation(forKey: Self.animationKey) == nil else { return }
    let travel = textWidth + Self.gap
    let scroll = CABasicAnimation(keyPath: "transform.translation.x")
    scroll.fromValue = 0
    scroll.toValue = -travel
    scroll.duration = travel / Self.speed
    scroll.repeatCount = .infinity
    scroll.timingFunction = CAMediaTimingFunction(name: .linear)
    strip.add(scroll, forKey: Self.animationKey)
  }

  /// Test seam: whether the scroll animation is currently attached.
  var isScrolling: Bool { strip.animation(forKey: Self.animationKey) != nil }
}
