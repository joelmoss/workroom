import AppKit
import DesignSystem
import SwiftUI

/// A growing log as one `NSTextView`, selectable across its lines. SwiftUI `Text` selects within one
/// view only, and one `Text` holding the whole log lays it all out again for each new line (over half
/// a second a line at 1,000 lines). Here a new line is appended, so it costs only itself and a
/// selection survives it. It follows new lines only while scrolled to its end (D10).
@MainActor final class LogTextController: NSObject, ObservableObject {
  let scrollView = NSScrollView()
  let textView = NSTextView(usingTextLayoutManager: false)
  /// Whether it is at its end, so new lines scroll it.
  @Published private(set) var following = true
  /// How tall its lines are with its padding, for a log drawn no taller than that (D9).
  @Published private(set) var contentHeight: CGFloat = 0

  private var attributes: [NSAttributedString.Key: Any]
  private var shownLines = 0
  private var visibleHeight: CGFloat = 0

  init(padding: CGFloat) {
    let size = NSFont.preferredFont(forTextStyle: .footnote).pointSize
    attributes = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)]
    super.init()

    textView.isEditable = false
    textView.isSelectable = true
    textView.textContainerInset = NSSize(width: padding, height: padding)
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]

    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.documentView = textView

    let clip = scrollView.contentView
    clip.postsBoundsChangedNotifications = true
    clip.postsFrameChangedNotifications = true
    textView.postsFrameChangedNotifications = true
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(clipChanged), name: NSView.boundsDidChangeNotification, object: clip
    )
    center.addObserver(
      self, selector: #selector(clipChanged), name: NSView.frameDidChangeNotification, object: clip)
    center.addObserver(
      self, selector: #selector(contentChanged), name: NSView.frameDidChangeNotification,
      object: textView)
  }

  /// `lines` only ever grows, so what is already shown stays, selection included.
  func show(_ lines: ArraySlice<String>) {
    guard lines.count > shownLines, let storage = textView.textStorage else { return }
    let added = lines.dropFirst(shownLines).joined(separator: "\n")
    let text = shownLines == 0 ? added : "\n" + added
    storage.append(NSAttributedString(string: text, attributes: attributes))
    shownLines = lines.count
    if let container = textView.textContainer {
      textView.layoutManager?.ensureLayout(for: container)
    }
  }

  func setColors(text: NSColor, background: NSColor) {
    attributes[.foregroundColor] = text
    textView.textColor = text
    textView.backgroundColor = background
    scrollView.backgroundColor = background
  }

  func scrollToEnd() {
    let clip = scrollView.contentView
    clip.scroll(to: NSPoint(x: 0, y: max(0, textView.frame.height - clip.bounds.height)))
    scrollView.reflectScrolledClipView(clip)
    following = true
  }

  /// New lines, or a width that wraps them differently.
  @objc private func contentChanged() {
    let height = textView.frame.height
    // Deferred: this runs inside SwiftUI's layout when the pane is resized.
    DispatchQueue.main.async { [weak self] in self?.contentHeight = height }
    if following { scrollToEnd() }
  }

  /// The user's scroll, a jump or a new frame. New lines move only the content's end, so they don't
  /// land here. A log that was following keeps its end in view as its frame changes.
  @objc private func clipChanged() {
    let clip = scrollView.contentView
    let resized = clip.bounds.height != visibleHeight
    visibleHeight = clip.bounds.height
    if resized, following {
      scrollToEnd()
    } else {
      following = CreationPanePresentation.isAtBottom(
        offset: clip.bounds.origin.y, visible: clip.bounds.height, content: textView.frame.height)
    }
  }
}

/// Hosts a `LogTextController`'s scroll view, in the theme's colours.
struct LogTextView: NSViewRepresentable {
  let controller: LogTextController
  let tokens: ThemeTokens

  func makeNSView(context: Context) -> NSScrollView { controller.scrollView }

  func updateNSView(_ view: NSScrollView, context: Context) {
    controller.setColors(text: tokens.nsFg, background: NSColor(tokens.surface))
  }
}
