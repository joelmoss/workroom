import AppKit
import SwiftUI

/// A scene's `.task` / `onAppear` can run before AppKit displays it. Wait for AppKit to finish a
/// window-update pass with this window visible before arming the optional usage processes.
struct UsagePollingAfterDisplay: NSViewRepresentable {
  let monitor: CodingAgentUsageMonitor

  func makeNSView(context: Context) -> NSView {
    DisplayProbe { monitor.startPollingAfterDisplay() }
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class DisplayProbe: NSView {
    private let onDisplay: () -> Void
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(onDisplay: @escaping () -> Void) {
      self.onDisplay = onDisplay
      super.init(frame: .zero)
      // A cached hidden-window layout need not draw this view again when it becomes visible.
      // The app's completed update pass also covers that path, without requiring another repaint.
      observer = NotificationCenter.default.addObserver(
        forName: NSApplication.didUpdateNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.windowDidUpdate() }
      }
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func windowDidUpdate() {
      guard let window, window.isVisible, !window.isMiniaturized, let observer else { return }
      NotificationCenter.default.removeObserver(observer)
      self.observer = nil
      DispatchQueue.main.async { [onDisplay] in onDisplay() }
    }
  }
}
