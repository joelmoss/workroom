import AppKit
import DesignSystem
import SwiftUI
import WorkroomDomain

/// A sidebar section's heading, the Terminals' and the Projects': the inspector's section header
/// look (`SectionHeaderLabel`, `SectionHeaderMetrics`), a leading fold chevron and the bold title,
/// which fold the section, then its buttons, the last a "+" in the trailing column every sidebar "+"
/// shares. It is its pane's sticky header, on the band (`SidebarSectionHeadingBand`), spanning the
/// sidebar as the inspector's spans its pane.
struct SidebarSectionHeading<Trailing: View>: View {
  let title: String
  @Binding var isFolded: Bool
  let id: String
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 0) {
      Button {
        isFolded.toggle()
      } label: {
        SectionHeaderLabel(
          title: title, collapsed: isFolded,
          leadingPadding: SectionHeaderMetrics.sidebarLeadingPadding)
      }
      .buttonStyle(.plain)
      .help(isFolded ? "Show the \(title) section" : "Hide the \(title) section")
      .accessibilityHint(
        isFolded ? "Expand \(title.lowercased())" : "Collapse \(title.lowercased())"
      )
      .accessibilityIdentifier(id)

      HStack(spacing: Spacing.s) { trailing() }
        .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    }
    .padding(.horizontal, SidebarRowMetrics.listContentInset)
    .frame(height: SectionHeaderMetrics.height)
  }
}

/// A heading's background: the section header band, edge to edge.
struct SidebarSectionHeadingBand: View {
  var body: some View { Color.clear.sectionHeaderBand() }
}
