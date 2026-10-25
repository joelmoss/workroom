import AppKit
import QuartzCore
import SwiftUI

/// Shared feedback for explicit copy controls, including actions in contextual menus.
/// A separate, nonactivating panel stays visible outside clipped rows without taking focus.
@MainActor
final class CopyConfirmation {
  private static let shared = CopyConfirmation()

  private let panel: NSPanel
  private var dismissal: Task<Void, Never>?

  static func copy(_ text: String, relativeTo anchor: NSView? = nil) {
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(text, forType: .string) else { return }
    shared.show(relativeTo: anchor)
  }

  private init() {
    panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.hidesOnDeactivate = true
    panel.ignoresMouseEvents = true
    panel.animationBehavior = .none
    panel.level = .popUpMenu
    panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
    panel.setAccessibilityIdentifier("copy.confirmation")

    let background = NSVisualEffectView()
    background.material = .toolTip
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 5
    background.layer?.masksToBounds = true

    let label = NSTextField(labelWithString: "Copied!")
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .labelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
      label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
      label.topAnchor.constraint(equalTo: background.topAnchor, constant: 6),
      label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
    ])
    panel.contentView = background
    panel.setContentSize(background.fittingSize)
  }

  private func show(relativeTo anchor: NSView?) {
    dismissal?.cancel()
    let wasVisible = panel.isVisible
    let pointer = NSEvent.mouseLocation
    let parent = anchor?.window ?? NSApp.keyWindow
    panel.appearance = parent?.effectiveAppearance
    let size = panel.frame.size
    let rect: NSRect
    if let anchor, let window = anchor.window {
      rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    } else {
      rect = NSRect(origin: pointer, size: .zero)
    }
    let screen = parent?.screen ?? NSScreen.screens.first(where: { $0.frame.contains(pointer) })
    let origin = Self.origin(for: rect, size: size, within: screen?.visibleFrame)
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if !wasVisible {
      panel.alphaValue = 0
      panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - (reduceMotion ? 0 : 4)))
    }
    // Adding a child can order it in. Establish its initial frame and opacity first.
    if panel.parent !== parent {
      panel.parent?.removeChildWindow(panel)
      parent?.addChildWindow(panel, ordered: .above)
    }
    panel.orderFront(nil)
    animate(to: origin, opacity: 1, duration: 0.16, reduceMotion: reduceMotion)
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [
        .announcement: "Copied!", .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ])
    dismissal = Task {
      do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
      let exit = NSPoint(x: origin.x, y: origin.y - (reduceMotion ? 0 : 4))
      animate(to: exit, opacity: 0, duration: 0.125, reduceMotion: reduceMotion)
      do { try await Task.sleep(for: .milliseconds(125)) } catch { return }
      panel.orderOut(nil)
      panel.parent?.removeChildWindow(panel)
    }
  }

  static func origin(for anchor: NSRect, size: NSSize, within screen: NSRect?) -> NSPoint {
    var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 4)
    if let bounds = screen?.insetBy(dx: 8, dy: 8) {
      if origin.y + size.height > bounds.maxY { origin.y = anchor.minY - size.height - 4 }
      origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
      origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
    }
    return origin
  }

  private func animate(
    to origin: NSPoint, opacity: CGFloat, duration: TimeInterval, reduceMotion: Bool
  ) {
    if reduceMotion { panel.setFrameOrigin(origin) }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
      if !reduceMotion {
        panel.animator().setFrame(NSRect(origin: origin, size: panel.frame.size), display: true)
      }
      panel.animator().alphaValue = opacity
    }
  }
}

/// Both the inspector glyph and ordinary Copy buttons provide their own screen-space anchor.
struct CopyButton: View {
  let text: String
  var title: String? = nil
  let help: String
  @State private var anchor: NSView?

  var body: some View {
    Group {
      if let title {
        Button(title, action: copy)
      } else {
        InspectorHeaderButton(systemImage: "doc.on.doc", help: help, compact: true, action: copy)
      }
    }
    .background(CopyConfirmationAnchor(view: $anchor))
    .help(help)
  }

  private func copy() { CopyConfirmation.copy(text, relativeTo: anchor) }
}

struct CopyConfirmationAnchor: NSViewRepresentable {
  final class AnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  @Binding var view: NSView?

  func makeNSView(context: Context) -> AnchorView {
    let anchor = AnchorView()
    DispatchQueue.main.async { view = anchor }
    return anchor
  }

  func updateNSView(_ nsView: AnchorView, context: Context) {}
}
