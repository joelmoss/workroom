import AppKit
import DesignSystem
import SwiftUI

/// Read-only, fully selectable code view backed by `NSTextView` — SwiftUI `Text` can only select
/// within a single view, so arbitrary multi-line selection needs AppKit. Renders the pre-built
/// syntax-highlighted `NSAttributedString`, paints the find model's match highlights (scrolling the
/// current into view), and shows a line-number gutter.
///
/// The gutter is a SEPARATE scroll view beside the text's scroll view, scroll-synced — *not* an
/// `NSRulerView` or a subview of the text view, either of which blanks the layer-backed text view's
/// glyph rendering under SwiftUI's hosting. The two clip views share one vertical offset, so the
/// numbers stay aligned with their lines.
struct CodeTextView: NSViewRepresentable {
  /// The themed, syntax-highlighted content (built by `FileHighlightMapper.nsAttributedString`).
  let attributed: NSAttributedString
  /// Bumped by the host whenever `attributed` is replaced (file load, highlight arrival, theme
  /// change), so the text storage is reset only then — not on every find keystroke.
  let version: Int
  let tokens: ThemeTokens
  @ObservedObject var find: FileFindModel
  /// Only the focused pane paints find highlights (the find model is shared across panes).
  let isFocused: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let coordinator = context.coordinator
    let container = NSView()

    // --- Text scroll view (a bare document view — anything added to it blanks the rendering). ---
    let textScroll = NSScrollView()
    textScroll.borderType = .noBorder
    textScroll.hasVerticalScroller = true
    textScroll.autohidesScrollers = true
    textScroll.drawsBackground = true
    textScroll.backgroundColor = NSColor(tokens.bg)

    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    storage.addLayoutManager(layoutManager)
    let textContainer = NSTextContainer(
      containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    textContainer.widthTracksTextView = true
    layoutManager.addTextContainer(textContainer)

    let textView = NSTextView(
      frame: NSRect(x: 0, y: 0, width: 600, height: 200), textContainer: textContainer)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.usesFontPanel = false
    textView.allowsUndo = false
    textView.drawsBackground = true
    textView.backgroundColor = NSColor(tokens.bg)
    textView.textColor = tokens.nsFg
    textView.textContainerInset = NSSize(width: 6, height: 8)
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textScroll.documentView = textView

    // --- Gutter scroll view (driven by the text view's scroll; never user-scrolled). ---
    let gutterScroll = NSScrollView()
    gutterScroll.borderType = .noBorder
    gutterScroll.hasVerticalScroller = false
    gutterScroll.hasHorizontalScroller = false
    gutterScroll.verticalScrollElasticity = .none
    gutterScroll.drawsBackground = true
    gutterScroll.backgroundColor = NSColor(tokens.bg)
    let gutterView = GutterView()
    gutterView.textView = textView
    gutterView.tokens = tokens
    gutterScroll.documentView = gutterView

    container.addSubview(gutterScroll)
    container.addSubview(textScroll)

    coordinator.textView = textView
    coordinator.textScroll = textScroll
    coordinator.gutterScroll = gutterScroll
    coordinator.gutterView = gutterView

    // Keep the gutter's vertical offset locked to the text's as it scrolls.
    textScroll.contentView.postsBoundsChangedNotifications = true
    coordinator.scrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: textScroll.contentView, queue: .main
    ) { [weak coordinator] _ in coordinator?.syncGutterScroll() }

    setText(textView, coordinator: coordinator)
    coordinator.layout(in: container)
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    let coordinator = context.coordinator
    guard let textView = coordinator.textView else { return }
    textView.backgroundColor = NSColor(tokens.bg)
    coordinator.textScroll?.backgroundColor = NSColor(tokens.bg)
    coordinator.gutterScroll?.backgroundColor = NSColor(tokens.bg)
    coordinator.gutterView?.tokens = tokens

    if coordinator.appliedVersion != version {
      setText(textView, coordinator: coordinator)
      coordinator.layout(in: container)
    }
    coordinator.applyFind(
      needle: (isFocused && find.isOpen) ? find.needle : "",
      current: find.current,
      highlight: NSColor(tokens.accent))
  }

  private func setText(_ textView: NSTextView, coordinator: Coordinator) {
    textView.textStorage?.setAttributedString(attributed)
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    coordinator.recomputeGutterWidth(lineCount: (attributed.string as NSString).numberOfLines)
    coordinator.appliedVersion = version
    // The storage swap dropped every find-match background; forget the stale paint state so the
    // `applyFind` that follows in `updateNSView` repaints instead of short-circuiting on an
    // unchanged needle (otherwise a theme toggle / async highlight arrival wipes the highlights).
    coordinator.resetFindState()
    coordinator.gutterView?.invalidateLineStarts()
    coordinator.gutterView?.needsDisplay = true
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    if let observer = coordinator.scrollObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Holds the live views + bookkeeping across SwiftUI updates.
  final class Coordinator {
    weak var textView: NSTextView?
    weak var textScroll: NSScrollView?
    weak var gutterScroll: NSScrollView?
    weak var gutterView: GutterView?
    var scrollObserver: NSObjectProtocol?
    var appliedVersion = -1
    private(set) var gutterWidth: CGFloat = 44
    private var highlightedRanges: [NSRange] = []
    private var lastNeedle = ""
    private var lastCurrent = -1

    func recomputeGutterWidth(lineCount: Int) {
      let digits = max(2, String(max(1, lineCount)).count)
      gutterWidth = ceil(CGFloat(digits) * 7.0) + 22
    }

    /// Position the gutter (fixed width, left) and the text scroll view (fills the rest), and size
    /// the gutter's document to the text's height so it scrolls 1:1.
    func layout(in container: NSView) {
      let bounds = container.bounds
      gutterScroll?.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
      gutterScroll?.autoresizingMask = [.height]
      textScroll?.frame = NSRect(
        x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
      textScroll?.autoresizingMask = [.width, .height]
      if let textView, let gutterView {
        gutterView.frame = NSRect(
          x: 0, y: 0, width: gutterWidth, height: max(bounds.height, textView.frame.height))
        gutterView.needsDisplay = true
      }
      syncGutterScroll()
    }

    func syncGutterScroll() {
      guard let textScroll, let gutterScroll else { return }
      let y = textScroll.contentView.bounds.origin.y
      gutterScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
      gutterScroll.reflectScrolledClipView(gutterScroll.contentView)
    }

    /// Forget the last painted find state. Called from `setText` after the text storage is replaced
    /// (its `.backgroundColor` runs are gone with it), so the next `applyFind` does a full repaint
    /// rather than short-circuiting on an unchanged needle.
    func resetFindState() {
      highlightedRanges = []
      lastNeedle = ""
      lastCurrent = -1
    }

    /// Paint every match's background (the current one stronger) and scroll the current into view.
    func applyFind(needle: String, current: Int, highlight: NSColor) {
      guard let textView, let storage = textView.textStorage else { return }
      if needle == lastNeedle && current == lastCurrent && !needle.isEmpty { return }
      lastNeedle = needle
      lastCurrent = current

      for range in highlightedRanges where NSMaxRange(range) <= storage.length {
        storage.removeAttribute(.backgroundColor, range: range)
      }
      highlightedRanges = []
      guard !needle.isEmpty else { return }

      let text = storage.string as NSString
      var searchStart = 0
      var matchIndex = 0
      var currentRange: NSRange?
      // Cap at the model's match cap so the painted set matches `FileFindModel.matches` exactly —
      // otherwise, on a file with more than `matchCap` hits, matches past the cap get painted but
      // are unreachable via next/prev (the model stops tracking them) and the "N/cap" count drifts.
      while searchStart < text.length, matchIndex < FileFind.matchCap {
        let found = text.range(
          of: needle, options: .caseInsensitive,
          range: NSRange(location: searchStart, length: text.length - searchStart))
        if found.location == NSNotFound { break }
        storage.addAttribute(
          .backgroundColor,
          value: highlight.withAlphaComponent(matchIndex == current ? 0.55 : 0.28),
          range: found)
        highlightedRanges.append(found)
        if matchIndex == current { currentRange = found }
        matchIndex += 1
        searchStart = found.location + max(found.length, 1)
      }
      if let currentRange { textView.scrollRangeToVisible(currentRange) }
    }
  }
}

/// Draws the 1-based line-number column. A normal `NSView` (document view of its own scroll view), so
/// its `draw` composites reliably; it shares the text view's vertical coordinates, so a number drawn
/// at a line fragment's y lines up with that line once the two scroll views are offset together.
final class GutterView: NSView {
  weak var textView: NSTextView?
  var tokens: ThemeTokens? {
    didSet {
      // Only `bg` + `fgMuted` are drawn here; repaint only when one of them actually changed, so the
      // per-find-keystroke `tokens =` reassignment in `updateNSView` isn't a full gutter redraw.
      if tokens?.bg != oldValue?.bg || tokens?.fgMuted != oldValue?.fgMuted { needsDisplay = true }
    }
  }

  /// Character index at which each line begins (element `i` = start of 0-based line `i`), built once
  /// per content change and reused across redraws so a deep-scrolled redraw doesn't rescan from
  /// byte 0. Invalidated by `invalidateLineStarts()` when the text is replaced.
  private var lineStarts: [Int]?

  private static let numberFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

  /// Drop the cached line-start index; the next `draw` rebuilds it from the (new) text.
  func invalidateLineStarts() { lineStarts = nil }

  override var isFlipped: Bool { true }
  // Scrolling over the gutter should scroll the code, not the (fixed) gutter.
  override func scrollWheel(with event: NSEvent) {
    textView?.enclosingScrollView?.scrollWheel(with: event)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard
      let textView,
      let layoutManager = textView.layoutManager,
      let container = textView.textContainer,
      let tokens
    else { return }

    NSColor(tokens.bg).setFill()
    dirtyRect.fill()
    NSColor(tokens.fgMuted).withAlphaComponent(0.15).setFill()
    NSRect(x: bounds.width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

    let text = textView.string as NSString
    let originY = textView.textContainerOrigin.y
    let attrs: [NSAttributedString.Key: Any] = [
      .font: Self.numberFont, .foregroundColor: NSColor(tokens.fgMuted),
    ]

    let containerRect = NSRect(
      x: 0, y: dirtyRect.minY - originY, width: 100_000, height: dirtyRect.height)
    let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: container)
    let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

    var lineNumber = lineIndex(of: charRange.location, in: lineStartOffsets(text)) + 1
    var index = charRange.location
    let end = NSMaxRange(charRange)
    while index < end {
      let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
      let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
      let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
      let label = "\(lineNumber)" as NSString
      let size = label.size(withAttributes: attrs)
      label.draw(
        at: NSPoint(
          x: bounds.width - size.width - 7,
          y: fragment.minY + originY + (fragment.height - size.height) / 2),
        withAttributes: attrs)
      lineNumber += 1
      let next = NSMaxRange(lineRange)
      if next <= index { break }
      index = next
    }
  }

  /// Line-start character indices for `text`, cached until `invalidateLineStarts()`. Scans the whole
  /// string once (O(n)) on a content change, so per-redraw line-number lookup is a binary search
  /// rather than the old O(scroll-position) rescan from byte 0.
  private func lineStartOffsets(_ text: NSString) -> [Int] {
    if let cached = lineStarts { return cached }
    var starts = [0]
    var i = 0
    while i < text.length {
      let r = text.range(
        of: "\n", options: [], range: NSRange(location: i, length: text.length - i))
      if r.location == NSNotFound { break }
      starts.append(r.location + 1)
      i = r.location + 1
    }
    lineStarts = starts
    return starts
  }

  /// 0-based index of the line containing character `location` — the largest `i` with
  /// `starts[i] <= location` (binary search; `starts` is sorted ascending).
  private func lineIndex(of location: Int, in starts: [Int]) -> Int {
    var lo = 0
    var hi = starts.count - 1
    var answer = 0
    while lo <= hi {
      let mid = (lo + hi) / 2
      if starts[mid] <= location {
        answer = mid
        lo = mid + 1
      } else {
        hi = mid - 1
      }
    }
    return answer
  }
}

extension NSString {
  /// Line count = newline count + 1 (non-empty); 1 for the empty string.
  fileprivate var numberOfLines: Int {
    guard length > 0 else { return 1 }
    var count = 1
    var i = 0
    while i < length {
      let r = range(of: "\n", options: [], range: NSRange(location: i, length: length - i))
      if r.location == NSNotFound { break }
      count += 1
      i = r.location + 1
    }
    return count
  }
}
