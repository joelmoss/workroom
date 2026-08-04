import SwiftUI

/// The inspector's **History** section body (issue #59): a newest-first commit log for the selected
/// workroom, read via `VCSProviding` through the store-owned `HistoryModel`. Lives inside the
/// inspector's scroll view, so it renders a flat stack of rows (like `ChangesPanel`/`FilesPanel`)
/// rather than a `List`. Single-click a row opens the commit's `ChangesetDetailView` as a preview
/// content tab; a quick double-click persists it (the same gate the Changes panel uses).
///
/// **Invalidation — read this before adding a dependency to a row** (WORKROOM-2B, a ≥2000 ms App Hang
/// sampled inside `HistoryRow.body`):
///
/// ```
/// BEFORE                                     AFTER
/// TerminalSessions.updateTitle / pulse       TerminalSessions.updateTitle / pulse
///   │ @Published tabsByTarget/activityPulses   │
///   ▼                                          ▼
/// EVERY HistoryRow (@ObservedObject)         HistoryPanel.body — ONE pass
///   │                                          │ LazyVStack: ForEach builds REALIZED rows only
///   ▼                                          ▼
/// N × body: MD5 + 16×String(format:)         HistoryRow == (commit, pushScope,
///         + URL parse + AsyncImage                          isSelected, themeGeneration)
///   = 2000 ms                                  │ equal → body SKIPPED
///                                              ▼
///                                            selection/theme moved → affected rows rebuild
/// ```
///
/// So: the panel owns the `TerminalSessions` dependency and resolves the focused tab **once**
/// (`FocusedTabSelection`); rows receive plain values and observe nothing. Measured by
/// `HistoryRowInvalidationTests` — a pulse burst must rebuild zero rows, and a selection or content
/// change must still rebuild the affected ones.
struct HistoryPanel: View {
  @EnvironmentObject var store: AppStore
  /// Injected + `@ObservedObject` (mirrors `FilesPanel`), NOT read via `store.commitHistory`: the
  /// panel must subscribe to the model's own `@Published` state so its `.loading → .loaded` flip
  /// re-renders the pane. `AppStore` doesn't forward `commitHistory`'s `objectWillChange`, so a plain
  /// `store.commitHistory` read only refreshed when some *unrelated* store change happened to publish
  /// (a status refresh, a reselection, an app refocus) — leaving the loader stuck until then.
  @ObservedObject var model: HistoryModel
  /// Observed HERE, deliberately, and nowhere below: this is the one view that needs to know which
  /// content tab is focused, and `TerminalSessions` republishes per terminal title/activity write. One
  /// panel body pass per publish is affordable; N row bodies was not (see the diagram above).
  @ObservedObject var sessions: TerminalSessions
  private let theme = ThemeService.shared

  var body: some View {
    Group {
      if store.inspectorTargetID == nil {
        // No active workspace (nothing selected, or the selected workroom has no open tabs) — empty
        // out to match the detail pane's "No terminal" state rather than show a stale last workroom.
        placeholder("No open terminal", systemImage: "clock")
      } else {
        switch model.state {
        case .idle:
          // A workroom is selected (the outer guard handled the nil case), so `.idle` is only the
          // brief pre-focus state before the model loads — show the loader, never "Select a
          // workroom" (which would wrongly imply no selection).
          loadingIndicator
        case .loading where model.commits.isEmpty:
          loadingIndicator
        case .failed(let message):
          placeholder(message, systemImage: "exclamationmark.triangle")
        default:
          if model.commits.isEmpty {
            placeholder("No history", systemImage: "clock")
          } else {
            list
          }
        }
      }
    }
    // Fill the pane (hosted in fill mode) so the inner `ScrollView` has bounded height and scrolls
    // itself — SwiftUI owns the scrolling, which is what lets the divergence accordion animate
    // smoothly (see `list`).
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    // No container-level `accessibilityIdentifier` here: SwiftUI propagates a container id onto the
    // combined `HistoryRow` leaves, clobbering their own id. The rows carry "HistoryRow"; that the
    // pane is showing is asserted via `inspector.header.History` (the canonical section marker).
    // Point the model at the inspector's active target (nil once all its tabs close → History
    // clears), only while the History section is showing (its pane active and the section expanded).
    // Mirrors FilesPanel; `focus` no-ops when already on the path.
    .task(id: activationKey) {
      guard store.historySectionShown else { return }
      // `activate` (not `focus`): on re-entry with the same workroom it pulls fresh (and retries a
      // prior failure), so switching away and back after a terminal commit shows the new log — where
      // `focus` would no-op on the unchanged root. The store's eager `focus` on selection still fires
      // first; `activate`'s settled-state guard means this won't double that fresh load.
      model.activate(store.inspectorTarget.map { URL(fileURLWithPath: $0.path) })
    }
  }

  private var activationKey: String {
    "\(AppStore.targetIDString(for: store.inspectorTargetID) ?? "")"
      + "\u{1F}\(store.historySectionShown)"
  }

  /// The commit id of the focused changeset tab, or `nil`. Resolved once per panel body pass and handed
  /// to the rows as a value — the row-level `isSelected` this replaced is what made every row observe
  /// `AppStore` + `TerminalSessions` (see the type doc's invalidation diagram).
  private var selectedCommitID: String? {
    FocusedTabSelection.current(store: store, sessions: sessions)?.changesetCommitID
  }

  /// The changeset tab's title for a commit — its summary, or the short id when it has none.
  ///
  /// `static` so the `open:` closure below can be written with an explicit `[store]` capture list and
  /// provably capture nothing per-pass: `HistoryRow`'s hand-written `==` excludes that closure, and the
  /// exclusion is only sound while the closure is behaviour-constant.
  private static func title(_ commit: VCSCommit) -> String {
    commit.summary.isEmpty ? commit.shortID : commit.summary
  }

  /// The commit rows in a SwiftUI `ScrollView` (the History pane hosts its body in fill mode, so this
  /// owns the scrolling rather than the AppKit `NSScrollView`). SwiftUI owning the scroll is what
  /// makes the per-row divergence accordion animate smoothly — a growing row's height change and the
  /// resulting scroll layout are one SwiftUI transaction, not a fight with an AppKit resize.
  private var list: some View {
    let selected = selectedCommitID
    // Read HERE so the panel itself has an Observation dependency on the theme, and pass it down so the
    // rows' equality gate can see a theme change.
    //
    // Why this is not belt-and-braces: a row reads `theme.tokens` only inside ternaries
    // (`isSelected ? accent : …`, `hovering ? rowHover : .clear`), and Swift evaluates just the taken
    // branch — so an unselected, unhovered row reads NO token and therefore registers no observation.
    // It used to repaint anyway, by accident: applying a theme also re-themes live terminals, which
    // republished `TerminalSessions`, which every row observed. Removing that observation (the App Hang
    // fix) removed the accidental repaint with it, and the unpushed badge's warning tint would have
    // stayed stale until something else invalidated the row.
    let themeGeneration = theme.generation
    return ScrollView {
      // `LazyVStack`, so a 1000-commit page costs the ~8 rows on screen rather than all of them. Safe
      // here and NOT in `DiffViewer` (which documents rejecting it at `unifiedBody`): these rows are
      // single-line `lineLimit(1)` fixed-height, so the height estimate a lazy stack caches is right,
      // where a soft-wrapping diff row's is not. The divergence accordion still animates smoothly
      // because SwiftUI owns the scroll (the doc comment above this property explains why), and it only
      // ever grows a row that is already realized.
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(model.commits) { commit in
          if commit.isRoot {
            // jj's `root()` shares almost nothing with a real commit row — no author, time, refs,
            // push state, divergence or changeset to open — so it gets its own view rather than a
            // `HistoryRow` body threaded with suppressions.
            HistoryRootRow(commit: commit).equatable()
          } else {
            HistoryRow(
              commit: commit,
              // Page-level, so an unpushed row's tooltip can name the origin branch it was measured
              // against instead of saying "origin" generically.
              pushScope: model.pushScope,
              // Resolved once above, not per row: rows must not reach the stores for this.
              selectedCommitID: selected,
              themeGeneration: themeGeneration,
              // Open any commit's changeset — the row itself, or one of its divergent siblings.
              // Preview on a single click, persist on a quick double-click (siblings only ever
              // preview). `[store]` + `Self.title` on purpose: the capture list is what makes this
              // closure behaviour-constant, which is what lets `HistoryRow.==` exclude it.
              open: { [store] target, persist in
                if persist {
                  store.openChangesetPersistent(
                    commitID: target.commitID, title: Self.title(target))
                } else {
                  store.openChangesetPreview(commitID: target.commitID, title: Self.title(target))
                }
              }
            ).equatable()
          }
        }
        if !model.reachedEnd, model.atWindowCap {
          // Older history exists but the window is capped, so say so instead of leaving a "Load more"
          // that does nothing. Same shape as the other panes' cap notices (`FilesPanel`'s "+N more",
          // `ChangesPanel`'s "Showing first N of M").
          Text("Showing the newest \(model.windowCap) commits")
            .font(.footnote).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
            .accessibilityIdentifier("HistoryWindowCapNotice")
        } else if !model.reachedEnd {
          Button {
            model.loadMore()
          } label: {
            HStack(spacing: 6) {
              if case .loading = model.state {
                ProgressView().controlSize(.small)
              } else {
                Image(systemName: "arrow.down.circle")
              }
              Text("Load more").font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("HistoryLoadMore")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func placeholder(_ text: String, systemImage: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
      Text(text).font(.callout)
    }
    .foregroundStyle(.secondary)
    .padding(.vertical, 6).padding(.horizontal, 8)
  }

  private var loadingIndicator: some View {
    HStack(spacing: 6) {
      ProgressView().controlSize(.small)
      Text("Loading history…").font(.callout).foregroundStyle(.secondary)
    }
    .padding(.vertical, 6).padding(.horizontal, 8)
  }
}

/// The abbreviated relative-time formatter shared by BOTH History row types (the commit row and its
/// divergent siblings). One instance, not one per struct: `RelativeDateTimeFormatter` is not cheap to
/// construct, the two configurations were byte-identical, and neither row keeps formatter state.
private let historyRelativeFormatter: RelativeDateTimeFormatter = {
  let f = RelativeDateTimeFormatter()
  f.unitsStyle = .abbreviated
  return f
}()

/// One commit row: first line of the message, then a metadata line (short id · author · relative
/// time) with any bookmark/branch refs, and a `@` marker for the jj working copy.
///
/// Deliberately `internal`, not `private` (same reason `HistoryCommitCard` below is): the row's
/// invalidation behaviour is the regression net for the WORKROOM-2B App Hang, and
/// `HistoryRowInvalidationTests` reads `bodyPasses` to assert it. XCUITest can only see that rows
/// exist, not how many times they were rebuilt.
struct HistoryRow: View, Equatable {
  let commit: VCSCommit
  /// What this page's push states were compared against, for the unpushed badge's tooltip.
  let pushScope: VCSPushScope?
  /// The focused changeset tab's commit id, resolved ONCE by `HistoryPanel` and passed down as a plain
  /// value. This row observes nothing: it used to hold `@EnvironmentObject AppStore` +
  /// `@ObservedObject TerminalSessions` just to compute the comparison below, which is what made a
  /// terminal title/activity pulse rebuild every row in the pane (WORKROOM-2B).
  let selectedCommitID: String?
  /// `ThemeService.generation`, so a theme change makes this row's equality gate report "changed".
  /// Load-bearing: the row's token reads sit inside ternaries, so an unselected, unhovered row reads no
  /// token and registers no Observation dependency of its own (see `HistoryPanel.list`).
  let themeGeneration: Int
  /// Open a commit's changeset detail as a tab — the row's own commit or one of its divergent
  /// siblings. `persist` false previews (single click), true persists (quick double-click).
  let open: (_ commit: VCSCommit, _ persist: Bool) -> Void
  @State private var hovering = false
  /// Whether the rich hover card (mirroring the changeset detail's header) is showing. Revealed on a
  /// short hover dwell so it doesn't flash while the pointer scans down the list (see the `.task`).
  @State private var showCard = false
  /// Timestamp of the last plain click, for the manual double-click gate (mirrors `ChangesPanel`).
  @State private var lastClick: Date?
  /// Divergence expander: shows the change's other visible copies (`commit.divergentSiblings`).
  @State private var showDivergent = false
  private let theme = ThemeService.shared

  /// The equality gate behind `.equatable()` at the use site. Synthesis is impossible (the row stores
  /// four `@State`s, a `ThemeService` handle and a closure), so this lists what the body actually reads
  /// from its inputs: the commit, the page's push scope, and whether this row is the selected one.
  ///
  /// `open` is EXCLUDED. That is sound only because `HistoryPanel` builds it with an explicit `[store]`
  /// capture list over a `static` title helper, so two instances differing only in closure identity are
  /// behaviourally identical. If that closure ever captures per-pass state, this `==` must start
  /// comparing it — or go away. `@State` and `ThemeService`'s Observation invalidate the body directly,
  /// past this gate, so hover, the dwell popover, the accordion and theme repaints are unaffected.
  /// Compares the DERIVED `isSelected`, not the raw `selectedCommitID`: when selection moves from one
  /// row to another, only the two rows whose own selected-ness changed compare unequal — the rest of
  /// the realized page stays elided.
  static func == (lhs: HistoryRow, rhs: HistoryRow) -> Bool {
    lhs.commit == rhs.commit && lhs.pushScope == rhs.pushScope
      && lhs.isSelected == rhs.isSelected && lhs.themeGeneration == rhs.themeGeneration
  }

  #if DEBUG
    /// How many times ANY row's body has been evaluated this process — the measurement behind the
    /// WORKROOM-2B regression tests. A terminal title/activity publish must move this by ZERO, and a
    /// 200-commit page must move it by far less than 200. Debug-only: it exists for
    /// `HistoryRowInvalidationTests`, not for the shipping app.
    static var bodyPasses = 0
  #endif

  var body: some View {
    #if DEBUG
      Self.bodyPasses += 1
    #endif
    // Explicit `return` on purpose: it opts this body out of the `@ViewBuilder` transform so the
    // debug counter above can be a plain statement. The `VStack` closure is still builder-built.
    return VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 3) {
        // Line one — the commit summary — is the row's combined accessibility leaf (id `HistoryRow`),
        // so the row reads and selects as a unit behind one queryable identifier.
        HStack(spacing: 6) {
          if commit.isWorkingCopy {
            Text("@").font(.system(.body, design: .monospaced)).foregroundStyle(.tint)
              .help("Working copy")
          }
          Text(commit.summary.isEmpty ? "(no description)" : commit.summary)
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(
              isSelected ? theme.tokens.accent : (commit.summary.isEmpty ? .secondary : .primary))
          Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("HistoryRow")
        // The short id leads the spoken label so a UI test can name the COMMIT it means instead of
        // indexing by position. That distinction became load-bearing when this list went lazy: offscreen
        // rows leave the accessibility tree, so `element(boundBy: 2)` no longer reliably means "the
        // third commit" — and a test that quietly indexes a different row than it intends still passes.
        // An element carries only one identifier (`HistoryRow`, which the tests also count), so identity
        // rides in the label. VoiceOver gains the id too, which the row never announced before.
        .accessibilityLabel(
          "\(commit.shortID), \(commit.summary.isEmpty ? "(no description)" : commit.summary)")

        // Line two — author avatars, relative time, then any bookmark/branch refs right of the
        // timestamp, then the unpushed marker — with the "diverging" disclosure trailing on the SAME
        // line. Refs live here (not line one) so a long bookmark/branch never wraps: each is a single
        // truncating capsule, and the timestamp keeps layout priority so the refs give way first (the
        // unpushed chip is a fixed ~16pt, so it never gives way). The disclosure is a real button (its
        // own accessibility element), so it toggles the expander without triggering the row's
        // open-changeset tap.
        //
        // Authors are avatars ONLY here — the names would crowd the narrow sidebar row and push the
        // refs out. Each avatar tooltips its own name, the hover card and the changeset detail spell
        // the names out, and the timestamp carries them as its accessibility label for VoiceOver.
        HStack(spacing: 6) {
          let relative = historyRelativeFormatter.localizedString(
            for: commit.timestamp, relativeTo: Date())
          if !commit.authors.isEmpty {
            AvatarStack(
              subjects: commit.authors.map { AvatarSubject(author: $0, pixelSize: 48) }, size: 16)
          }
          let names = commit.authorNamesDisplay
          Text(relative)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .layoutPriority(1)
            .accessibilityLabel(names.isEmpty ? relative : "\(names), \(relative)")
          ForEach(commit.refs, id: \.self) { ref in
            Text(ref)
              .font(.caption2)
              .lineLimit(1)
              .truncationMode(.tail)
              .padding(.horizontal, 5).padding(.vertical, 1)
              .background(.quaternary, in: Capsule())
              .help("Bookmark / branch")
          }
          if commit.showsUnpushedBadge { unpushedBadge }
          Spacer(minLength: 6)
          if commit.isDivergent {
            divergingToggle
          }
        }
      }
      .padding(.vertical, 6).padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        // Square, full-width band (no corner radius): bleed past the section's 12pt inset so the
        // hover/selection highlight fills the inspector width edge-to-edge (mirrors `ChangedFileRow`).
        Rectangle()
          .fill(
            isSelected ? theme.tokens.rowSelection : (hovering ? theme.tokens.rowHover : .clear)
          )
          .padding(.horizontal, -12)
      )
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
      // Rich hover card in place of a plain text `.help` tooltip: the same header layout the changeset
      // detail uses (summary, id/author/date/refs line, then the description body), so a full commit
      // reads the same on hover as when opened. Anchored leading — the inspector sits at the window's
      // trailing edge, so the card opens inward over the detail area rather than off-screen.
      .popover(isPresented: $showCard, arrowEdge: .leading) {
        HistoryCommitCard(commit: commit, pushScope: pushScope)
      }
      // Dwell gate: reveal only after the pointer rests ~0.5s, and hide the instant it leaves. Flipping
      // `hovering` re-runs this task (SwiftUI cancels the prior one), so a quick pass over the row
      // cancels the pending reveal before it fires — no popover flicker while scanning the list.
      .task(id: hovering) {
        guard hovering else {
          showCard = false
          return
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        showCard = true
      }
      // Eager single-click preview, quick second click (< 0.35s) persists — the same manual
      // double-click gate the Changes panel uses (avoids SwiftUI's count:2 delay).
      .onTapGesture {
        let now = Date()
        if let last = lastClick, now.timeIntervalSince(last) < 0.35 {
          open(commit, true)
          lastClick = nil
        } else {
          open(commit, false)
          lastClick = now
        }
      }

      // The sibling list drops in below the row. Because the History pane hosts its body in fill
      // mode and scrolls itself (a SwiftUI `ScrollView`, not the AppKit `NSScrollView`), SwiftUI
      // owns this height change: the list animates in and the rows below flow down with it, natively
      // smooth — no `NSHostingController.intrinsicContentSize` → `NSScrollView` resize to fight.
      if showDivergent {
        divergentSiblingsList
          .transition(.opacity)
      }
    }
  }

  /// The "not on origin yet" marker: an arrow-up in a warning-tinted capsule, padded exactly like the
  /// ref chips beside it so line two reads as one row of chips. Same glyph and weight as the sidebar's
  /// "ahead" marker (`ProjectSidebar`), so "ahead of the remote" looks the same in both surfaces. Shown
  /// only for a definite `.unpushed` and never on jj's `@` — that rule lives in `showsUnpushedBadge`.
  private var unpushedBadge: some View {
    Image(systemName: "arrow.up")
      .font(.system(size: 9, weight: .semibold))
      .padding(.horizontal, 5).padding(.vertical, 1)
      .background(theme.tokens.warning.opacity(0.18), in: Capsule())
      .foregroundStyle(theme.tokens.warning)
      .help(VCSPushScope.unpushedHelp(pushScope))
      .accessibilityLabel("Not pushed")
      .accessibilityIdentifier("HistoryRowUnpushed")
  }

  /// The "diverging (N)" disclosure on the author/time line. jj shows only the copy that's an
  /// ancestor of `@`; this reveals the change's other visible copies — its divergent siblings.
  private var divergingToggle: some View {
    let count = commit.divergentSiblings.count
    let copies = count == 1 ? "copy" : "copies"
    return Button {
      withAnimation(.easeInOut(duration: 0.22)) { showDivergent.toggle() }
    } label: {
      HStack(spacing: 3) {
        Text("diverging")
        Text("(\(count))").foregroundStyle(.purple.opacity(0.6))
      }
      .font(.caption2)
      .padding(.horizontal, 5).padding(.vertical, 1)
      .background(Color.purple.opacity(showDivergent ? 0.22 : 0.12), in: Capsule())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.purple)
    .help(
      "This change is diverging — its change ID resolves to \(count + 1) visible commits. "
        + "Click to \(showDivergent ? "hide" : "show") the \(count) other \(copies)."
    )
    .accessibilityIdentifier("HistoryRowDiverges")
  }

  /// The expanded list of the change's divergent copies — one `DivergentSiblingRow` each. The siblings
  /// get the same passed-down selection value the parent row did; nothing here reaches a store.
  private var divergentSiblingsList: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(commit.divergentSiblings) { sibling in
        DivergentSiblingRow(
          sibling: sibling, selectedCommitID: selectedCommitID,
          themeGeneration: themeGeneration, open: open
        )
        .equatable()
      }
    }
    .padding(.top, 1).padding(.bottom, 5)
  }

  /// True when the focused content tab is this commit's changeset — so the row showing in the pane
  /// reads as selected. Now a comparison against a value the panel resolved, not a store read.
  fileprivate var isSelected: Bool { selectedCommitID == commit.commitID }
}

/// jj's virtual **root commit**, rendered the way `jj log` prints it: `◆ root() 00000000`.
///
/// Every jj history terminates in it (`::@` includes `root()`, so it's on the log page for parity with
/// `jj log`), but it is not a commit anyone authored: no author, no description, no changes, and an
/// epoch timestamp. Mapped through `HistoryRow` it therefore read as "(no description) · 56 yr ago"
/// behind a `?` avatar — a broken-looking commit rather than the end of the graph. So this row states
/// what it is and shows nothing it doesn't have.
///
/// **Inert on purpose**: no hover highlight and no tap. There is no changeset to open (root's diff is
/// empty by definition), so the row must not look or behave like it opens one.
private struct HistoryRootRow: View, Equatable {
  let commit: VCSCommit

  var body: some View {
    HStack(spacing: 6) {
      // jj's own glyph for the commit, in the same leading slot `HistoryRow` puts the `@` marker —
      // so the graph column lines up down the list.
      Text("◆")
        .font(.system(.body, design: .monospaced))
      Text("root()")
        .font(.system(.callout, design: .monospaced))
      Text(commit.shortID)
        .font(.system(.caption, design: .monospaced))
      Spacer(minLength: 0)
    }
    .foregroundStyle(.secondary)
    .padding(.vertical, 6).padding(.horizontal, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(
      "root() — the virtual empty commit every jj repo starts from. It has no author, description or "
        + "changes, so there is nothing to open."
    )
    .accessibilityElement(children: .combine)
    // A DIFFERENT identifier from `HistoryRow` on purpose: the row is not a commit row, and the UI
    // tests index `HistoryRow` positionally / count it against the unpushed badges.
    .accessibilityIdentifier("HistoryRootRow")
  }
}

/// The history row's hover card — a peek, not the whole commit: the summary, then the same
/// identity/refs/author/date line the changeset detail view heads with (`ChangesetDetailView.header`),
/// so those facts read identically on hover as when opened. The description is deliberately left out
/// along with the detail's diff `+N −M` stat and file list — the stat and files need a resolved
/// changeset (the card is built purely from the `VCSCommit` already in hand, no fetch), and an
/// unclamped body grew the card arbitrarily tall on a long commit message. All of it is one click
/// away in the detail view. Rendered inside a `.popover`.
///
/// Deliberately `internal`, not `private`: XCUITest can't drive `.onHover`, so the card's contents are
/// covered by a view-level test that constructs it directly (`HistoryCommitCardTests`).
struct HistoryCommitCard: View {
  let commit: VCSCommit
  /// What push state was measured against, for the unpushed marker's tooltip.
  var pushScope: VCSPushScope?
  private let theme = ThemeService.shared

  /// Whether the card states "Not pushed" — the same rule the row's chip uses. A named property rather
  /// than an inline condition because a unit-test process has no accessibility tree for a hosted
  /// SwiftUI view (macOS builds it only for a live AX client), so this is the only way to assert the
  /// card's wiring; `HistoryCommitCardTests` covers it, and the row's XCUITest covers the visual.
  var showsUnpushedMarker: Bool { commit.showsUnpushedBadge }

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(commit.summary.isEmpty ? "(no description)" : commit.summary)
        .font(.callout.weight(.semibold))
        .foregroundStyle(commit.summary.isEmpty ? .secondary : .primary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        // Identity, styled like the detail header: change-id (purple, jj only) + commit-id (blue),
        // monospaced.
        if let changeID = commit.changeID {
          Text(changeID)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.purple)
        }
        Text(commit.shortID)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.blue)
        // Bookmarks/branches, as the same gray capsules the rows use, left of the author — mirrors
        // `ChangesetDetailView.header`.
        ForEach(commit.refs, id: \.self) { ref in
          Text(ref)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .help("Bookmark / branch")
        }
        if !commit.authorNamesDisplay.isEmpty {
          Label {
            Text(commit.authorNamesDisplay)
          } icon: {
            AvatarStack(
              subjects: commit.authors.map { AvatarSubject(author: $0, pixelSize: 54) }, size: 18)
          }
        }
        Label(Self.dateFormatter.string(from: commit.timestamp), systemImage: "clock")
        if commit.parentIDs.count > 1 {
          Label("Merge", systemImage: "arrow.triangle.merge")
        }
        if showsUnpushedMarker {
          // Spelled out here rather than reusing the row's icon capsule: the card has room for words,
          // and it mirrors how the changeset detail header states the same fact.
          Label("Not pushed", systemImage: "arrow.up")
            .foregroundStyle(theme.tokens.warning)
            .help(VCSPushScope.unpushedHelp(pushScope))
            .accessibilityIdentifier("HistoryCardUnpushed")
        }
        Spacer(minLength: 0)
      }
      .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .frame(width: 420, alignment: .leading)
  }
}

/// One divergent-copy row inside the expander: jj's `id/N` label + summary + relative time, with the
/// SAME hover / selected highlight as a `HistoryRow` — a full-width band (content indented under the
/// parent). Selected when its changeset is the focused content tab; a single click opens it.
private struct DivergentSiblingRow: View, Equatable {
  let sibling: VCSCommit
  /// The focused changeset tab's commit id, passed down from the panel through the parent row — the
  /// sibling row observed the stores for this until WORKROOM-2B (see `HistoryPanel`'s type doc).
  let selectedCommitID: String?
  /// `ThemeService.generation` — same reason as `HistoryRow.themeGeneration`.
  let themeGeneration: Int
  /// Opens a commit's changeset detail (preview) — the parent row's `open`, siblings only preview.
  let open: (_ commit: VCSCommit, _ persist: Bool) -> Void
  @State private var hovering = false
  private let theme = ThemeService.shared

  var body: some View {
    HStack(spacing: 6) {
      Text(sibling.divergentLabel ?? sibling.shortID)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.purple)
      Text(sibling.summary.isEmpty ? "(no description)" : sibling.summary)
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(
          isSelected ? theme.tokens.accent : (sibling.summary.isEmpty ? .secondary : .primary))
      Spacer(minLength: 4)
      Text(historyRelativeFormatter.localizedString(for: sibling.timestamp, relativeTo: Date()))
        .font(.caption2).foregroundStyle(.secondary)
    }
    // Content indented under the parent row; the highlight band bleeds full-width (same -12 as the
    // parent row) so hover/selection reads edge-to-edge, exactly like a top-level history row.
    .padding(.vertical, 3)
    .padding(.leading, 22).padding(.trailing, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Rectangle()
        .fill(isSelected ? theme.tokens.rowSelection : (hovering ? theme.tokens.rowHover : .clear))
        .padding(.horizontal, -12)
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { open(sibling, false) }
    .help(sibling.summary.isEmpty ? "(no description)" : sibling.summary)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("HistoryDivergentSibling")
  }

  /// Selected when the focused content tab is this sibling's changeset (mirrors `HistoryRow`).
  private var isSelected: Bool { selectedCommitID == sibling.commitID }

  /// Same gate and same exclusion rationale as `HistoryRow.==` — `open` is the parent's
  /// behaviour-constant closure.
  static func == (lhs: DivergentSiblingRow, rhs: DivergentSiblingRow) -> Bool {
    lhs.sibling == rhs.sibling && lhs.isSelected == rhs.isSelected
      && lhs.themeGeneration == rhs.themeGeneration
  }
}
