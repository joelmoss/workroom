import AppKit
import SwiftUI

/// One rail card's data — a **value type**, resolved once when the rail opens.
///
/// INVARIANT (prior learning `macapp-row-observes-sessions-invalidation-storm`): no rail view may hold
/// an `AppStore` or `TerminalSessions`. `TerminalSessions` republishes on every title/activity pulse,
/// so a card observing it to decide "am I the cursor" would re-render at OSC frequency — the
/// WORKROOM-2B hang. Everything a card draws is snapshotted here instead.
struct SwitcherCard: Identifiable, Equatable {
  let id: String
  /// The primary line. Already prefix-stripped by `WorkroomLabel.railTitles` where applicable.
  let title: String
  /// The stable identity zone of the subtitle — never empty, never churns.
  let stableSubtitle: String
  /// The live tail (a command line, a diffstat). Truncates before `stableSubtitle` does.
  let liveSubtitle: String?
  let glyph: String
  let badge: Int
  let isRunning: Bool
  /// Set once the snapshot layer lands (T12); until then every card draws its glyph well.
  let snapshot: CGImage?

  var subtitle: String {
    guard let liveSubtitle, !liveSubtitle.isEmpty else { return stableSubtitle }
    return "\(stableSubtitle) · \(liveSubtitle)"
  }
}

extension SwitcherCard {
  /// Snapshot a controller item into a card. Reads the stores ONCE, here, and never again — which is
  /// also why this is `@MainActor` while `SwitcherCard` itself is not: the reads happen on the main
  /// actor at reveal, and what the views then hold is inert.
  @MainActor
  init(item: QuickSwitcherController.Item) {
    switch item {
    case .workroom(let slot):
      let label = slot.store?.label(for: slot.sid)
      id = "wr:\(slot.target.id)"
      title = label?.distinguishing ?? slot.target.title
      stableSubtitle = label?.branch ?? label?.project ?? ""
      liveSubtitle = nil  // the live command tail arrives with the snapshot layer (T12)
      glyph = "cube"
      badge = slot.store?.notifications.count(target: slot.target.id) ?? 0
      isRunning = slot.store?.isRunCommandRunning(for: slot.target.id) ?? false
      snapshot = nil
    case .pane(let tab):
      id = "pane:\(tab.id)"
      title = tab.title
      stableSubtitle = Self.kindLabel(tab.content)
      liveSubtitle = nil
      glyph = Self.glyph(for: tab.content)
      badge = 0
      isRunning = tab.isRunning
      snapshot = nil
    }
  }

  /// The tab-strip / sidebar glyph vocabulary, so a pane reads the same everywhere. Exhaustive on
  /// purpose: a fifth `TabContent` kind must be a compile error, not a silent fallback to "terminal".
  static func glyph(for content: TabContent) -> String {
    switch content {
    case .terminal: "terminal"
    case .diff: "plusminus"
    case .file: "doc"
    case .changeset: "clock"
    }
  }

  /// The subtitle's stable zone for a pane: what kind of thing this is. Present even when there is no
  /// live text, which is the point — identity must not disappear (D13).
  static func kindLabel(_ content: TabContent) -> String {
    switch content {
    case .terminal: "Terminal"
    case .diff: "Diff"
    case .file: "File"
    case .changeset: "Commit"
    }
  }
}

/// The rail's observable state. One object, mutated by `SwitcherPanelController` — the cards
/// themselves observe nothing.
@MainActor
final class SwitcherRailModel: ObservableObject {
  @Published var cards: [SwitcherCard] = []
  @Published var cursor = 0
  @Published var width: CGFloat = 600
  /// Bumped on a theme change so the tokens are re-read.
  @Published var themeVersion = 0

  var onHover: ((Int) -> Void)?
  var onCommit: ((Int) -> Void)?

  func update(cards: [SwitcherCard], cursor: Int, width: CGFloat) {
    self.cards = cards
    self.cursor = cursor
    self.width = width
  }
}

/// The rail: **one** row of label-led cards, centred in a floating translucent panel.
///
/// Label-led, not thumbnail-led: drawn at the originally-planned 220×140 a terminal thumbnail is a
/// near-blank rectangle (output hugs the top-left), so the loudest element carried the least
/// information while the name — the thing you actually decide on — was the smallest. Inverted here.
struct SwitcherRailView: View {
  @ObservedObject var model: SwitcherRailModel
  private let theme = ThemeService.shared

  /// Re-resolved per render. `model.themeVersion` is read in `body` so a theme change actually
  /// repaints — this is a static view inside a panel that is only ever ordered in and out, so nothing
  /// else would invalidate it.
  private var palette: SwitcherRailLayout.Palette { SwitcherRailLayout.palette(for: theme.tokens) }

  /// No `accessibilityReduceMotion` here on purpose: nothing in the rail animates. The cursor ring and
  /// the scroll offset both snap (a 0.32s spring per step would still be travelling toward card 2 when
  /// the commit lands on card 4), and the panel itself carries `animationBehavior = .none`.

  private var cardWidth: CGFloat {
    SwitcherRailLayout.cardWidth(count: model.cards.count, available: model.width)
  }

  private var scrolls: Bool {
    SwitcherRailLayout.scrolls(count: model.cards.count, available: model.width)
  }

  var body: some View {
    row
      .id(model.themeVersion)  // see `palette` — the only thing that invalidates this view
      // The app's own floating-translucent recipe (the inspector reveal uses it). No full-screen dim:
      // a 250ms gesture must not flash the whole screen, so separation comes from material + hairline
      // + shadow instead.
      .sidebarCard(cornerRadius: 16, margin: 0, vibrant: !palette.needsOpaqueFill, elevated: true)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("switcher.rail")
  }

  @ViewBuilder private var row: some View {
    if scrolls {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          cards
        }
        // Without the `contentShape` the cards under the fade ramp stop taking hover and clicks — a
        // verified idiom, not a precaution.
        .mask(fadeRamp)
        .contentShape(.interaction, Rectangle())
        .onChange(of: model.cursor) { _, index in
          // Snapped, never animated: release is detected by a 30ms poll and a fast user taps Tab 3–4×
          // in 200ms, so a spring per step would still be travelling toward card 2 when the commit
          // lands on card 4.
          proxy.scrollTo(model.cards[safe: index]?.id, anchor: .center)
        }
      }
    } else {
      cards
    }
  }

  private var cards: some View {
    HStack(spacing: SwitcherRailLayout.cardSpacing) {
      ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
        SwitcherCardView(
          card: card, isCursor: index == model.cursor, width: cardWidth, palette: palette
        )
        .onHover { inside in if inside { model.onHover?(index) } }
        .onTapGesture { model.onCommit?(index) }
      }
    }
    .padding(SwitcherRailLayout.railPadding)
  }

  /// Edge fade signalling more cards off-screen.
  private var fadeRamp: LinearGradient {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0),
        .init(color: .black, location: 0.04),
        .init(color: .black, location: 0.96),
        .init(color: .clear, location: 1),
      ], startPoint: .leading, endPoint: .trailing)
  }
}

/// One card: a fixed thumbnail well, then a label column that absorbs every point of width loss.
private struct SwitcherCardView: View {
  let card: SwitcherCard
  let isCursor: Bool
  let width: CGFloat
  let palette: SwitcherRailLayout.Palette
  private let theme = ThemeService.shared

  var body: some View {
    // No trailing `Spacer` here. A `Spacer(minLength: 0)` is a *flexible* child, so SwiftUI splits the
    // card's spare width between it and the label column — which truncated "uitest-room-2" at a card
    // width that fits it twice over. `maxWidth: .infinity` on the labels claims that space instead.
    HStack(spacing: 10) {
      well
      labels
    }
    .padding(.horizontal, 10)
    .frame(width: width, height: SwitcherRailLayout.cardHeight)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(isCursor ? theme.tokens.accentSoft : theme.tokens.panel)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(isCursor ? palette.ring : theme.tokens.border, lineWidth: 1)
    )
    .contentShape(Rectangle())
    .help(tooltip)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier("switcher.card.\(card.title)")
  }

  /// The well: the pane capture aspect-**fit** (never cropped — a crop-zoom can make two different
  /// panes look identical), or the pane-kind glyph when there is no snapshot, which is the normal
  /// first-run case since capture only happens while a pane is visible.
  private var well: some View {
    RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(card.snapshot == nil ? theme.tokens.accentSoft : theme.tokens.surface)
      .frame(width: SwitcherRailLayout.wellSize.width, height: SwitcherRailLayout.wellSize.height)
      .overlay {
        if let snapshot = card.snapshot {
          Image(decorative: snapshot, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
        } else {
          Image(systemName: card.glyph)
            .font(.system(size: 20))
            .foregroundStyle(palette.ring)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private var labels: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 5) {
        // Middle truncation, never tail: generated workroom names share a prefix and differ at the
        // END, which is exactly what tail truncation deletes (D12).
        Text(card.title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(palette.name)
          .lineLimit(1)
          .truncationMode(.middle)
        // Badge and running dot sit in the LABEL row, not over the thumbnail — which also removes the
        // contrast problem of an accent pill over arbitrary screenshot pixels.
        if card.badge > 0 { UnreadBadge(count: card.badge) }
        if card.isRunning {
          Circle().fill(palette.dot).frame(width: 6, height: 6)
            .help("Running")
            .accessibilityLabel("running")
        }
      }
      Text(card.subtitle)
        .font(.system(size: 11))
        .foregroundStyle(palette.subtitle)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var tooltip: String {
    card.badge > 0
      ? "\(card.title)\n\(card.subtitle)\n\(card.badge) unread" : "\(card.title)\n\(card.subtitle)"
  }

  /// No state may live only in a tooltip here — a tooltip needs ~1s of hover and this whole gesture
  /// lasts a few hundred ms, so the badge count and running state are spelled out for assistive tech.
  private var accessibilityLabel: String {
    var parts = [card.title, card.subtitle]
    if card.badge > 0 { parts.append("\(card.badge) unread") }
    if card.isRunning { parts.append("running") }
    return parts.joined(separator: ", ")
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
