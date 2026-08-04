import AppKit
import SwiftUI

/// One rail card's data — a **value type**, resolved once when the rail opens.
///
/// INVARIANT (prior learning `macapp-row-observes-sessions-invalidation-storm`): no rail view may hold
/// an `AppStore` or `TerminalSessions`. `TerminalSessions` republishes on every title/activity pulse,
/// so a card observing it to decide "am I the cursor" would re-render at OSC frequency — the
/// WORKROOM-2B hang. Everything a card draws is snapshotted here instead.
struct SwitcherCard: Identifiable, Equatable {
  /// What the well draws. The two switchers have genuinely different identity problems, so they get
  /// genuinely different wells: workrooms differ from each other by *which workroom they are*, panes
  /// inside one workroom differ by *what kind of thing they are*.
  enum Well: Equatable {
    /// ⌥Tab: a stable colour + monogram you learn, the way you learn an app icon.
    case mark(SwitcherMark)
    /// ⌃Tab: a small graphic drawn from the pane's own data, so the shape says the kind.
    case miniature(PaneMiniature)
  }

  let id: String
  /// The primary line. Workroom titles are finalised by `cards(for:)` through
  /// `WorkroomLabel.railTitles`, which keeps the `project / workroom` form when the rail spans more than
  /// one project — otherwise two workrooms both named `main` render identically.
  var title: String
  /// The stable identity zone of the subtitle — never empty, never churns.
  let stableSubtitle: String
  /// The live tail (a command line, a diffstat). Truncates before `stableSubtitle` does.
  let liveSubtitle: String?
  var well: Well
  let badge: Int
  let isRunning: Bool
  /// The mark's tile colour, resolved once when the cards are built. Resolving it in `body` instead ran
  /// `SwitcherMark.tileColor`'s saturation-ladder × brightness-step search — NSColor allocations and a
  /// contrast ratio per candidate — on every re-render of every card.
  var tile: NSColor?

  var subtitle: String {
    guard let liveSubtitle, !liveSubtitle.isEmpty else { return stableSubtitle }
    return "\(stableSubtitle) · \(liveSubtitle)"
  }
}

extension SwitcherCard {
  /// Build the rail's cards: hues rotated so no two visible marks share a colour, titles resolved
  /// against the whole set (D12), and each tile colour computed once, here, rather than per render.
  @MainActor
  static func cards(for items: [QuickSwitcherController.Item]) -> [SwitcherCard] {
    var cards = items.map(SwitcherCard.init(item:))
    let tokens = ThemeService.shared.tokens
    // Only workroom cards carry marks; pane miniatures are unaffected.
    let markIndices = cards.indices.filter {
      if case .mark = cards[$0].well { true } else { false }
    }
    let hues = markIndices.map { index -> Int in
      guard case .mark(let mark) = cards[index].well else { return 0 }
      return mark.hue
    }
    for (position, index) in zip(SwitcherMark.disambiguate(hues), markIndices) {
      guard case .mark(let mark) = cards[index].well else { continue }
      cards[index].well = .mark(SwitcherMark(monogram: mark.monogram, hue: position))
      cards[index].tile = SwitcherMark.tileColor(hue: position, tokens: tokens)
    }
    // D12: drop the project prefix only when EVERY workroom on the rail shares it. Applied over the
    // whole set, which is the only place the set is in hand — per-card `.distinguishing` always dropped
    // it, so two workrooms named `main` in different projects rendered identically.
    let labels = items.compactMap { item -> WorkroomLabel? in
      guard case .workroom(let slot) = item else { return nil }
      return slot.store?.label(for: slot.sid)
    }
    if labels.count == markIndices.count {
      for (title, index) in zip(WorkroomLabel.railTitles(labels), markIndices) {
        cards[index].title = title
      }
    }
    return cards
  }

  /// Snapshot a controller item into a card. Reads the stores ONCE, here, and never again — which is
  /// also why this is `@MainActor` while `SwitcherCard` itself is not: the reads happen on the main
  /// actor at reveal, and what the views then hold is inert.
  @MainActor
  init(item: QuickSwitcherController.Item) {
    switch item {
    case .workroom(let slot):
      let label = slot.store?.label(for: slot.sid)
      // The window token is part of the id because `TerminalTarget.id` is project+name and carries no
      // window — and the same workroom open in two windows is deliberately two slots. Without it the
      // `ForEach` got duplicate ids (undefined rows, a runtime warning, and an ambiguous `scrollTo`).
      let window = slot.store.map { "\($0.windowToken.key):" } ?? ""
      id = "wr:\(window)\(slot.target.id)"
      let displayed = label?.distinguishing ?? slot.target.title
      title = displayed
      // The monogram follows the DISPLAYED name so it matches what you read; the colour follows the
      // target id, which a relabel doesn't change — so relabelling re-letters the mark without moving
      // the hue you actually recognise.
      well = .mark(SwitcherMark(displayName: displayed, stableKey: slot.target.id))
      stableSubtitle = label?.branch ?? label?.project ?? ""
      liveSubtitle = slot.store.flatMap { Self.vcsTail(for: slot.sid, in: $0) }
      badge = slot.store?.notifications.count(target: slot.target.id) ?? 0
      isRunning = slot.store?.isRunCommandRunning(for: slot.target.id) ?? false
    case .pane(let tab):
      id = "pane:\(tab.id)"
      title = tab.title
      let miniature = PaneMiniature(content: tab.content, isRunning: tab.isRunning)
      well = .miniature(miniature)
      stableSubtitle = miniature.label
      liveSubtitle = nil
      badge = 0
      isRunning = tab.isRunning
    }
  }

  /// A workroom's VCS state as the subtitle's live tail: line counts when known, otherwise the coarse
  /// state. Conflicts win — they are the one state you want to notice from a switcher.
  @MainActor
  static func vcsTail(for sid: SidebarID, in store: AppStore) -> String? {
    guard let status = store.workroomStatuses[sid] else { return nil }
    if status.conflicted { return "conflicts" }
    if let added = status.insertions, let removed = status.deletions, added + removed > 0 {
      return "+\(added) −\(removed)"
    }
    if status.dirty == true { return "modified" }
    if status.dirty == false { return "clean" }
    return nil
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
/// Label-led, and screenshot-free. Window captures were built and removed: at any size that fits a
/// switcher rail an aspect-fit terminal capture is a grey smudge, and it is neither stable nor
/// distinctive — it changes every time and every terminal looks like every other terminal. What
/// replaced it differs per switcher, because the two have different identity problems: a workroom is
/// distinguished by *which workroom it is* (so it gets a learnable mark), a pane inside one workroom by
/// *what kind of thing it is* (so it gets a drawn miniature of its type).
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
      // The system's Liquid Glass — the same surface ⌘Tab sits on — rather than the app's
      // `sidebarCard` recipe, whose `.withinWindow` material has nothing to sample inside a transparent
      // floating panel. No full-screen dim: a 250ms gesture must not flash the whole screen, so the
      // separation is the material itself.
      .background {
        ZStack {
          RailGlassBackground(cornerRadius: Self.cornerRadius)
          // D14's last resort: a theme whose foreground cannot clear the text floor against a
          // translucent surface gets an opaque one instead. Legibility outranks the material — and
          // without this the glass would keep washing text that already failed its contrast check.
          if palette.needsOpaqueFill { theme.tokens.panel }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
      .background { shadowCaster }
      // The halo the rail's drop shadow lands in. The window is `shadowMargin` bigger than the slab on
      // every side for exactly this — a drawn shadow is clipped at the window's edge, and the window
      // itself casts none (see `SwitcherRailLayout.shadowMargin`).
      .padding(SwitcherRailLayout.shadowMargin)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("switcher.rail")
  }

  /// Matches the system switcher's generous curvature; also handed to the glass view, which rounds the
  /// material itself rather than relying on a clip.
  static let cornerRadius: CGFloat = 20

  /// The rail's drop shadow: the shape's shadow with **the shape itself punched out**, mounted behind the
  /// glass and after the clip.
  ///
  /// Every part of that is load-bearing, and each was measured rather than reasoned:
  ///
  /// - **The window can't cast it.** A borderless, non-opaque `NSPanel` produces no system shadow at all —
  ///   `hasShadow = true` with `invalidateShadow()` darkened nothing at 6/14/26/44pt out on any side, with
  ///   glass content and with a solid opaque fill alike.
  /// - **A clip applies to a view's background**, so a shadow mounted alongside the glass was clipped away
  ///   entirely. Hence a second `.background`, after `.clipShape`.
  /// - **A layer shadow on the representable never rendered**, `shadowPath` and all. A SwiftUI shape's
  ///   shadow does.
  /// - **The hole is what keeps the glass alive.** A shadow needs an opaque caster, and an opaque layer
  ///   anywhere beneath a glass view destroys the material completely: sampled across the rail's interior,
  ///   glass normally tracks its backdrop (correlation +0.81), and with an opaque fill behind it the
  ///   correlation and the variation both fall to exactly zero — a flat slab. So the caster keeps only its
  ///   spill: `destinationOut` removes its own footprint, and the mask's rectangle is expanded by
  ///   `shadowMargin` because a mask hides whatever falls outside it, which would otherwise take the
  ///   spill with it.
  private var shadowCaster: some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    return
      shape
      .fill(Color.black)
      .shadow(color: .black.opacity(0.32), radius: 14, y: 5)
      .compositingGroup()
      .mask {
        Rectangle()
          .padding(-SwitcherRailLayout.shadowMargin)
          .overlay { shape.blendMode(.destinationOut) }
          .compositingGroup()
      }
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
        // A theme change re-`id`s the row, which resets the ScrollView — and the cursor didn't move, so
        // the handler above can't put it back. Without this the highlighted card is simply gone from
        // view on a scrolling rail.
        .onChange(of: model.themeVersion) { _, _ in
          proxy.scrollTo(model.cards[safe: model.cursor]?.id, anchor: .center)
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

/// One card: the well above its label, the way ⌘Tab and the Dock stack an icon over its name.
///
/// Stacked rather than side-by-side because that is what buys horizontal room: a side-by-side card pays
/// for the well's width *and* a label column beside it, while a stacked card gives the full width to the
/// label — so the card shrank 200pt → 120pt and roughly twice as many fit before the row scrolls.
private struct SwitcherCardView: View {
  let card: SwitcherCard
  let isCursor: Bool
  let width: CGFloat
  let palette: SwitcherRailLayout.Palette
  private let theme = ThemeService.shared

  /// The cursor fill and ring share it, and it sits inside the rail's own 20pt so the two curves nest
  /// rather than fight.
  static let cursorRadius: CGFloat = 14

  var body: some View {
    VStack(spacing: 7) {
      well
      labels
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 10)
    .frame(width: width, height: SwitcherRailLayout.cardHeight)
    .background(
      RoundedRectangle(cornerRadius: Self.cursorRadius, style: .continuous)
        .fill(isCursor ? theme.tokens.accentSoft : Color.clear)
    )
    .overlay(
      // Only the cursor is outlined. On glass, giving every card its own border produced a row of
      // competing boxes and buried the one signal that matters — which card you are about to commit to.
      //
      // A hairline at a generous radius, not a 1.5pt box: the ring's job is to say *which* card, and the
      // `accentSoft` fill already says that. Thinning and rounding it softens the edge without touching
      // its colour, which is what D14's 3:1 floor is measured on — dropping the stroke's opacity instead
      // would look identical and quietly fail that floor.
      RoundedRectangle(cornerRadius: Self.cursorRadius, style: .continuous)
        .strokeBorder(isCursor ? palette.ring : .clear, lineWidth: 1)
    )
    .contentShape(Rectangle())
    .help(tooltip)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier("switcher.card.\(card.title)")
  }

  /// The well, with its badge and running pip riding on its corners.
  ///
  /// Screenshots were tried and removed: at any size that fits a switcher rail an aspect-fit window
  /// capture is a grey smudge, and it is neither stable nor distinctive — it changes every time and every
  /// terminal looks like every other terminal. So each switcher draws what distinguishes its own items.
  private var well: some View {
    ZStack(alignment: .topTrailing) {
      switch card.well {
      case .mark(let mark): MarkWell(mark: mark, tile: card.tile)
      case .miniature(let miniature): MiniatureWell(miniature: miniature, palette: palette)
      }
      // Badge on the icon's corner, the Dock/⌘Tab idiom — and in a stacked card it costs no width at
      // all, where in the label row it competed with the name for the same points.
      if card.badge > 0 {
        UnreadBadge(count: card.badge)
          .offset(x: 7, y: -6)
      } else if card.isRunning {
        Circle()
          .fill(palette.dot)
          .frame(width: 7, height: 7)
          .overlay(Circle().strokeBorder(theme.tokens.panel, lineWidth: 1.5))
          .offset(x: 3, y: -3)
          .help("Running")
          .accessibilityLabel("running")
      }
    }
  }

  private var labels: some View {
    VStack(spacing: 1) {
      // Middle truncation, never tail: generated workroom names share a prefix and differ at the END,
      // which is exactly what tail truncation deletes (D12).
      Text(card.title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(palette.name)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(card.subtitle)
        .font(.system(size: 10))
        .foregroundStyle(palette.subtitle)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
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

/// A workroom's identity mark: a solid theme-derived tile with its monogram.
///
/// Solid rather than a tinted wash on purpose — the tile is the thing you are meant to recognise from
/// the corner of your eye, and a 10%-opacity wash of six different hues all reads as "grey-ish". The
/// colour comes from `SwitcherMark.tileColor`, which keeps the theme's hue angle but imposes its own
/// saturation and brightness; the monogram takes whichever of black/white is legible on the result.
private struct MarkWell: View {
  let mark: SwitcherMark
  /// Resolved by `SwitcherCard.cards(for:)`, once per reveal. `tileColor` is a search — a saturation
  /// ladder × brightness steps, each rung allocating an NSColor and measuring a contrast ratio — so
  /// running it from `body` re-ran it on every render of every card.
  let tile: NSColor?
  private let theme = ThemeService.shared

  var body: some View {
    let tile = tile ?? SwitcherMark.tileColor(hue: mark.hue, tokens: theme.tokens)
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(Color(nsColor: tile))
      .frame(width: SwitcherRailLayout.wellSize.width, height: SwitcherRailLayout.wellSize.height)
      .overlay {
        Text(mark.monogram)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(Color(nsColor: SwitcherMark.ink(on: tile)))
      }
  }
}

/// A pane's type miniature, drawn from its own data.
private struct MiniatureWell: View {
  let miniature: PaneMiniature
  let palette: SwitcherRailLayout.Palette
  private let theme = ThemeService.shared

  var body: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(theme.tokens.surface)
      .frame(width: SwitcherRailLayout.wellSize.width, height: SwitcherRailLayout.wellSize.height)
      .overlay { shape }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  @ViewBuilder private var shape: some View {
    switch miniature {
    case .terminal(let running): terminal(running: running)
    case .diff(let change): diff(change)
    case .file: file
    case .changeset: changeset
    }
  }

  /// A prompt chevron, with a filled pip while something is running — the one pane state you care about
  /// mid-switch is "is this the one that's still working".
  private func terminal(running: Bool) -> some View {
    HStack(spacing: 3) {
      Image(systemName: "chevron.right")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(palette.name)
      if running {
        Circle().fill(palette.dot).frame(width: 5, height: 5)
      } else {
        RoundedRectangle(cornerRadius: 1).fill(palette.subtitle).frame(width: 8, height: 2)
      }
    }
  }

  /// Stacked add/remove bars. Composition follows the change *kind*, not magnitude: per-file line counts
  /// don't exist on `ChangedFile`, so an added file reads all-add, a deletion all-remove, a modification
  /// split, and a conflict takes the conflict token outright.
  private func diff(_ change: ChangedFile.Change) -> some View {
    VStack(spacing: 2) {
      ForEach(Array(bars(for: change).enumerated()), id: \.offset) { _, bar in
        RoundedRectangle(cornerRadius: 1)
          .fill(bar.color)
          .frame(width: bar.width, height: 4)
      }
    }
  }

  private func bars(for change: ChangedFile.Change) -> [(color: Color, width: CGFloat)] {
    let add = palette.diffAdd
    let remove = palette.diffRemove
    switch change {
    case .added, .untracked:
      return [(add, 26), (add, 20), (add, 14)]
    case .deleted:
      return [(remove, 26), (remove, 20), (remove, 14)]
    case .modified, .other:
      return [(add, 26), (remove, 18), (add, 12)]
    case .renamed:
      return [(palette.subtitle, 26), (add, 18), (remove, 12)]
    case .conflicted:
      return [(Color(nsColor: theme.tokens.nsFg), 24), (remove, 24), (add, 24)]
    }
  }

  /// Abstract text lines — a page, with no pretence of showing the real content.
  private var file: some View {
    VStack(alignment: .leading, spacing: 3) {
      ForEach([24, 18, 22, 13], id: \.self) { width in
        RoundedRectangle(cornerRadius: 1)
          .fill(palette.subtitle)
          .frame(width: CGFloat(width), height: 2.5)
      }
    }
  }

  /// A chain of commit dots.
  private var changeset: some View {
    HStack(spacing: 0) {
      ForEach(0..<3, id: \.self) { index in
        Circle()
          .fill(index == 0 ? palette.name : palette.subtitle)
          .frame(width: 6, height: 6)
        if index < 2 {
          Rectangle().fill(palette.subtitle).frame(width: 6, height: 1.5)
        }
      }
    }
  }
}
