import DesignSystem
import SwiftUI

/// The bar pinned above a followed folder's Files tree (#809): the trail from the repository's
/// root (or `~`, else `/`) down to the terminal's folder. A segment browses that folder in Files
/// alone. The last segment is the terminal's own folder and carries a terminal glyph; while Files
/// shows another folder it turns accent, and clicking it goes back.
///
/// Aligned by construction with the section header above it: the first segment's text starts at
/// the header title's inset (`SectionHeaderMetrics.horizontalPadding`), since the bar's leading
/// padding gives back exactly the segment's own hover inset, and the bar is the header's height.
struct FilesBreadcrumbBar: View {
  let breadcrumb: FilesBreadcrumb
  let onSelect: (Int) -> Void
  @Environment(\.themeTokens) private var tokens

  /// Each segment's horizontal inset inside its hover fill.
  static let segmentInset: CGFloat = 4
  /// More segments than this fold the middle ones into a menu, keeping the base, the folder above
  /// the terminal's, the terminal's own, and the folder Files shows.
  static let maxVisibleSegments = 4

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(layout.enumerated()), id: \.offset) { position, item in
        if position > 0 { separator }
        switch item {
        case .segment(let index):
          FilesBreadcrumbSegment(
            segment: breadcrumb.segments[index], index: index, role: role(of: index),
            onSelect: { onSelect(index) }
          )
          .layoutPriority(priority(of: index))
        case .overflow(let indices):
          overflowMenu(indices)
        }
      }
      Spacer(minLength: 0)
    }
    .lineLimit(1)
    .padding(.leading, SectionHeaderMetrics.horizontalPadding - Self.segmentInset)
    .padding(.trailing, SectionHeaderMetrics.horizontalPadding - Self.segmentInset)
    .frame(height: SectionHeaderMetrics.height)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) { tokens.border.frame(height: 1) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Folder path")
    .accessibilityIdentifier("files.breadcrumb")
  }

  private enum Item {
    case segment(Int)
    case overflow([Int])
  }

  /// Every segment, or past `maxVisibleSegments` the base, the folder Files shows and the last
  /// two, with each run of the others folded into a menu.
  private var layout: [Item] {
    let count = breadcrumb.segments.count
    guard count > Self.maxVisibleSegments else { return (0..<count).map(Item.segment) }
    let kept: Set<Int> = [0, breadcrumb.shownIndex, count - 2, count - 1]
    var items: [Item] = []
    var folded: [Int] = []
    for index in 0..<count {
      if kept.contains(index) {
        if !folded.isEmpty { items.append(.overflow(folded)) }
        folded = []
        items.append(.segment(index))
      } else {
        folded.append(index)
      }
    }
    return items
  }

  private func role(of index: Int) -> FilesBreadcrumbSegment.Role {
    if index == breadcrumb.leafIndex {
      return breadcrumb.isBrowsedAway ? .terminalBrowsedAway : .terminalShown
    }
    return index == breadcrumb.shownIndex ? .shown : .ancestor
  }

  /// The terminal's folder truncates last, then the base; the middle gives way first.
  private func priority(of index: Int) -> Double {
    if index == breadcrumb.leafIndex { return 3 }
    if index == breadcrumb.shownIndex { return 2 }
    return index == 0 ? 1 : 0
  }

  private var separator: some View {
    Image(systemName: "chevron.compact.right")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(.tertiary)
      .frame(width: 10)
      .accessibilityHidden(true)
  }

  private func overflowMenu(_ indices: [Int]) -> some View {
    Menu {
      ForEach(indices, id: \.self) { index in
        let segment = breadcrumb.segments[index]
        Button {
          onSelect(index)
        } label: {
          Label(segment.name, systemImage: index == breadcrumb.shownIndex ? "checkmark" : "folder")
        }
        .help(StatusBarCwdSegment.abbreviate(segment.path))
      }
    } label: {
      Text("…")
        .font(.system(size: 11))
        .foregroundStyle(tokens.fgMuted)
        .padding(.horizontal, Self.segmentInset)
    }
    .menuStyle(.button)
    .buttonStyle(FilesBreadcrumbButtonStyle())
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Show a folder in between")
    .accessibilityLabel("More folders")
    .accessibilityIdentifier("files.breadcrumb.overflow")
  }
}

/// One folder of the breadcrumb: a quiet text button with the header buttons' rounded hover fill.
struct FilesBreadcrumbSegment: View {
  enum Role {
    /// A folder above the one Files shows.
    case ancestor
    /// The folder Files shows, browsed to.
    case shown
    /// The terminal's folder, which Files shows.
    case terminalShown
    /// The terminal's folder while Files shows another: accent, and a click goes back.
    case terminalBrowsedAway
  }

  let segment: FilesBreadcrumb.Segment
  let index: Int
  let role: Role
  let onSelect: () -> Void
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 3) {
        if role == .terminalShown || role == .terminalBrowsedAway {
          Image(systemName: "terminal")
            .font(.system(size: 9, weight: .medium))
            .accessibilityHidden(true)
        }
        Text(segment.name)
          .font(.system(size: 11, weight: isShown ? .semibold : .regular))
          .truncationMode(.middle)
      }
      .foregroundStyle(color)
      .padding(.horizontal, FilesBreadcrumbBar.segmentInset)
    }
    .buttonStyle(FilesBreadcrumbButtonStyle())
    .help(help)
    .accessibilityLabel(segment.name)
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(isShown ? "" : "Shows this folder in Files")
    .accessibilityAddTraits(isShown ? .isSelected : [])
    .accessibilityIdentifier("files.breadcrumb.\(index)")
  }

  private var isShown: Bool { role == .shown || role == .terminalShown }

  private var color: Color {
    switch role {
    case .ancestor: return tokens.fgMuted
    case .shown, .terminalShown: return tokens.fg
    case .terminalBrowsedAway: return tokens.accent
    }
  }

  private var path: String { StatusBarCwdSegment.abbreviate(segment.path) }

  private var help: String {
    switch role {
    case .ancestor: return "Show \(path) in Files"
    case .shown: return "Files shows \(path)"
    case .terminalShown: return "The terminal's folder: \(path)"
    case .terminalBrowsedAway: return "Back to the terminal's folder: \(path)"
    }
  }

  private var accessibilityValue: String {
    switch role {
    case .ancestor: return "folder"
    case .shown: return "shown in Files"
    case .terminalShown: return "the terminal's folder, shown in Files"
    case .terminalBrowsedAway: return "the terminal's folder, not shown in Files"
    }
  }
}

/// A breadcrumb control's chrome: the rounded hover fill the inspector's header buttons use,
/// sized to the label rather than to a square.
struct FilesBreadcrumbButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Chrome(configuration: configuration)
  }

  private struct Chrome: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.themeTokens) private var tokens

    var body: some View {
      configuration.label
        .frame(height: 22)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(hovering || configuration.isPressed ? tokens.hover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
  }
}
