import AppKit
import DesignSystem
import SwiftUI

/// The bar at the top of the sidebar that picks the one view it shows (ADR 0083): the Open Tabs view, a
/// terminal glyph, then the Projects view, by name, each underlined in the accent while shown, with
/// an accent dot while the other is shown and something in it waits on the user. The trailing "+"
/// acts on the view shown: in Open it opens anything (`SidebarOpenAddMenu`), in Projects it adds a
/// project. A terminal's tab let go on the Open tab becomes a standalone terminal (#660), and a
/// terminal drag resting on the hidden view's tab shows that view (`TerminalDragSession`).
///
/// It reads only the selection and the drag's wait; each tab's dot is a leaf of its own, so
/// a mark changing re-runs the dot alone, and nothing here re-runs a row.
struct SidebarViewSwitcher: View {
  let store: AppStore
  @Environment(\.themeTokens) private var tokens
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var underline

  /// The bar's height, its hairline included.
  static let height: CGFloat = 30
  /// The visible gap between the tabs' labels.
  static let tabGap: CGFloat = 16
  /// How far each tab's hit area reaches past its label on either side, inside the gap.
  static let tabPadding: CGFloat = 4

  var body: some View {
    let selected = store.sidebarView
    HStack(spacing: 0) {
      HStack(spacing: Self.tabGap - 2 * Self.tabPadding) {
        ForEach(SidebarView.allCases, id: \.self) { view in
          SidebarViewTab(
            view: view, store: store, selected: view == selected,
            springing: store.sidebarSpringTarget == view, underline: underline)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Sidebar views")
      Spacer(minLength: 0)
      addButton(for: selected)
        .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    }
    // The Open tab's glyph sits over the rows' glyph column, the "+" in their trailing column.
    .padding(
      .leading,
      SidebarRowMetrics.listContentInset + ProjectSidebar.rowInsets.leading - Self.tabPadding
    )
    .padding(.trailing, SidebarRowMetrics.listContentInset)
    .frame(height: Self.height)
    .background(alignment: .bottom) {
      // Under the tabs, so the selected tab's underline sits on it.
      tokens.border.frame(height: 0.5).allowsHitTesting(false)
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selected)
  }

  @ViewBuilder private func addButton(for view: SidebarView) -> some View {
    switch view {
    case .open:
      SidebarOpenAddMenu(store: store)
    case .projects:
      // Through the store's request flag, so the sheet (re-homed to RootView, issue #23 OV1)
      // presents as File ▸ New Project…'s does.
      SidebarIconButton(
        systemImage: "plus", help: "Add Project…", label: "Add Project", id: "sidebar.add"
      ) {
        store.modals.requestAddProject = true
      }
    }
  }
}

/// One of the switcher's tabs: the Open Tabs view's terminal glyph or the Projects view's name, primary
/// and semibold over the accent underline while shown, secondary and medium while not.
private struct SidebarViewTab: View {
  let view: SidebarView
  let store: AppStore
  let selected: Bool
  /// A terminal drag rests on it, and the sidebar shows its view when the wait is up.
  let springing: Bool
  let underline: Namespace.ID
  @Environment(\.themeTokens) private var tokens
  @State private var hovering = false

  var body: some View {
    let button = Button {
      store.selectSidebarView(view)
    } label: {
      // The label alone sets the tab's size: the dot rides beside it in an overlay, so neither a
      // dot coming and going nor a selection moves either tab.
      label
        .foregroundStyle(selected || hovering || springing ? Color.primary : Color.secondary)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
          if selected {
            Rectangle()
              .fill(tokens.accent)
              .frame(height: 2)
              .matchedGeometryEffect(id: "underline", in: underline)
          }
        }
        .background {
          // The drag's wait, as a hovered control's well.
          RoundedRectangle(cornerRadius: Radius.xs)
            .fill(tokens.hover.opacity(springing ? 1 : 0))
            .padding(.horizontal, -Spacing.xs)
            .padding(.vertical, Spacing.s)
        }
        .overlay(alignment: .trailing) {
          if !selected {
            SidebarViewAttentionDot(view: view, store: store)
              .alignmentGuide(.trailing) { $0[.leading] - Spacing.xs }
          }
        }
        .padding(.horizontal, SidebarViewSwitcher.tabPadding)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        // The tab's place, for a drag's wait on it.
        .background(SidebarViewTabMarker(store: store, view: view))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(view.help)
    .accessibilityLabel(view.title)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityHint(selected ? "" : "Shows the \(view.title) view")
    .accessibilityIdentifier(view.identifier)
    if view == .open {
      // A terminal's tab let go on it becomes a standalone terminal (#660), as on the Open
      // section's old heading.
      button.paneDropZone(.standalone, store: store)
    } else {
      button
    }
  }

  @ViewBuilder private var label: some View {
    // One weight whether selected or not: a heavier glyph draws wider and re-rounds, so it would
    // shift by a fraction as the selection moves. The colour and the underline say which is shown.
    let weight: Font.Weight = .medium
    // Glyphs alone, each as wide as the rows' glyph column (the Open tab's sits over it).
    Image(systemName: view == .open ? "terminal" : "square.grid.2x2")
      .font(.system(size: 12, weight: weight))
      .frame(width: SidebarRowMetrics.caretWidth)
  }
}

/// A hidden view's tab's dot: something in it waits on the user (`sidebarViewNeedsAttention`). A
/// leaf, holding the notifications so an unread change re-runs it alone.
private struct SidebarViewAttentionDot: View {
  let view: SidebarView
  let store: AppStore
  @EnvironmentObject private var notifications: NotificationCenterStore
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    if store.sidebarViewNeedsAttention(view) {
      Circle()
        .fill(tokens.accent)
        .frame(width: 6, height: 6)
        .help("Something in \(view.title) needs you")
        .accessibilityLabel("needs attention")
        .accessibilityIdentifier("\(view.identifier).attention")
    }
  }
}

/// Registers a switcher tab's view with its window's store, which says where the tab is on screen
/// to a terminal drag (`AppStore.sidebarViewTabRects`).
struct SidebarViewTabMarker: NSViewRepresentable {
  /// A weak hold on a tab's view, so a sidebar that has gone drops out.
  final class Box {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
  }

  let store: AppStore
  let view: SidebarView

  func makeNSView(context: Context) -> NSView {
    let marker = PassThroughView()
    store.sidebarViewTabViews[view] = Box(marker)
    return marker
  }

  /// The docked sidebar and the edge-reveal panel each draw a switcher: the one last drawn holds
  /// the tab, and only a marker in the window counts (`sidebarViewTabRects`).
  func updateNSView(_ marker: NSView, context: Context) {
    if store.sidebarViewTabViews[view]?.view !== marker {
      store.sidebarViewTabViews[view] = Box(marker)
    }
  }

  /// Takes no clicks: the tab under it keeps them.
  private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

/// Keeps a sidebar view's `List` on overlay scrollers, as the system's legacy scroller (a mouse
/// with "Show scroll bars: Always") would narrow its rows but not the switcher, and their "+"
/// columns would part. Placed behind the List; it finds the List's scroll view as the one under it.
struct SidebarOverlayScrollers: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { ProbeView() }
  func updateNSView(_ view: NSView, context: Context) { view.needsLayout = true }

  private final class ProbeView: NSView {
    private var observing = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil, !observing else { return }
      observing = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(styleChanged(_:)),
        name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    /// A scroll view resets its style when the system preference changes.
    @objc private func styleChanged(_ notification: Notification) {
      DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    override func layout() {
      super.layout()
      apply()
    }

    /// The scroll views near this one in the hierarchy whose frame holds this view's middle.
    private func apply() {
      guard window != nil else { return }
      let middle = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
      var ancestor: NSView? = superview
      for _ in 0..<6 {
        guard let current = ancestor else { return }
        if visit(current, middle: middle) { return }
        ancestor = current.superview
      }
    }

    private func visit(_ view: NSView, middle: CGPoint) -> Bool {
      if let scroll = view as? NSScrollView, scroll.documentView is NSTableView,
        scroll.convert(scroll.bounds, to: nil).contains(middle)
      {
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        return true
      }
      return view.subviews.contains { visit($0, middle: middle) }
    }
  }
}
