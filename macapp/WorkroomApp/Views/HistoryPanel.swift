import SwiftUI

/// The inspector's **History** section body (issue #59): a newest-first commit log for the selected
/// workroom, read via `VCSProviding` through the store-owned `HistoryModel`. Lives inside the
/// inspector's scroll view, so it renders a flat `VStack` of rows (like `ChangesPanel`/`FilesPanel`)
/// rather than a `List`. Single-click a row opens the commit's `ChangesetDetailView` as a preview
/// content tab; a quick double-click persists it (the same gate the Changes panel uses).
struct HistoryPanel: View {
  @EnvironmentObject var store: AppStore
  /// Injected + `@ObservedObject` (mirrors `FilesPanel`), NOT read via `store.commitHistory`: the
  /// panel must subscribe to the model's own `@Published` state so its `.loading → .loaded` flip
  /// re-renders the pane. `AppStore` doesn't forward `commitHistory`'s `objectWillChange`, so a plain
  /// `store.commitHistory` read only refreshed when some *unrelated* store change happened to publish
  /// (a status refresh, a reselection, an app refocus) — leaving the loader stuck until then.
  @ObservedObject var model: HistoryModel
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
    // clears), only while History is the active section. Mirrors FilesPanel; `focus` no-ops when
    // already on the path.
    .task(id: activationKey) {
      guard store.activeInspectorSection == .history else { return }
      // `activate` (not `focus`): on re-entry with the same workroom it pulls fresh (and retries a
      // prior failure), so switching away and back after a terminal commit shows the new log — where
      // `focus` would no-op on the unchanged root. The store's eager `focus` on selection still fires
      // first; `activate`'s settled-state guard means this won't double that fresh load.
      model.activate(store.inspectorTarget.map { URL(fileURLWithPath: $0.path) })
    }
  }

  private var activationKey: String {
    "\(AppStore.targetIDString(for: store.inspectorTargetID) ?? "")"
      + "\u{1F}\(store.activeInspectorSection == .history)"
  }

  /// The changeset tab's title for a commit — its summary, or the short id when it has none.
  private func title(_ commit: VCSCommit) -> String {
    commit.summary.isEmpty ? commit.shortID : commit.summary
  }

  /// The commit rows in a SwiftUI `ScrollView` (the History pane hosts its body in fill mode, so this
  /// owns the scrolling rather than the AppKit `NSScrollView`). SwiftUI owning the scroll is what
  /// makes the per-row divergence accordion animate smoothly — a growing row's height change and the
  /// resulting scroll layout are one SwiftUI transaction, not a fight with an AppKit resize.
  private var list: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(model.commits) { commit in
          if commit.isRoot {
            // jj's `root()` shares almost nothing with a real commit row — no author, time, refs,
            // push state, divergence or changeset to open — so it gets its own view rather than a
            // `HistoryRow` body threaded with suppressions.
            HistoryRootRow(commit: commit)
          } else {
            HistoryRow(
              commit: commit,
              // Page-level, so an unpushed row's tooltip can name the origin branch it was measured
              // against instead of saying "origin" generically.
              pushScope: model.pushScope,
              // Open any commit's changeset — the row itself, or one of its divergent siblings.
              // Preview on a single click, persist on a quick double-click (siblings only ever
              // preview).
              open: { target, persist in
                if persist {
                  store.openChangesetPersistent(commitID: target.commitID, title: title(target))
                } else {
                  store.openChangesetPreview(commitID: target.commitID, title: title(target))
                }
              },
              sessions: store.terminals)
          }
        }
        if !model.reachedEnd {
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

/// One commit row: first line of the message, then a metadata line (short id · author · relative
/// time) with any bookmark/branch refs, and a `@` marker for the jj working copy.
private struct HistoryRow: View {
  let commit: VCSCommit
  /// What this page's push states were compared against, for the unpushed badge's tooltip.
  let pushScope: VCSPushScope?
  /// Open a commit's changeset detail as a tab — the row's own commit or one of its divergent
  /// siblings. `persist` false previews (single click), true persists (quick double-click).
  let open: (_ commit: VCSCommit, _ persist: Bool) -> Void
  @EnvironmentObject var store: AppStore
  /// Observed so the row's selected state tracks which changeset tab is focused — the tab strip
  /// lives in a separate observation tree from the inspector (mirrors `ChangesPanel.ChangedFileRow`).
  @ObservedObject var sessions: TerminalSessions
  @State private var hovering = false
  /// Whether the rich hover card (mirroring the changeset detail's header) is showing. Revealed on a
  /// short hover dwell so it doesn't flash while the pointer scans down the list (see the `.task`).
  @State private var showCard = false
  /// Timestamp of the last plain click, for the manual double-click gate (mirrors `ChangesPanel`).
  @State private var lastClick: Date?
  /// Divergence expander: shows the change's other visible copies (`commit.divergentSiblings`).
  @State private var showDivergent = false
  private let theme = ThemeService.shared

  private static let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
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
          let relative = Self.relative.localizedString(for: commit.timestamp, relativeTo: Date())
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

  /// The expanded list of the change's divergent copies — one `DivergentSiblingRow` each.
  private var divergentSiblingsList: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(commit.divergentSiblings) { sibling in
        DivergentSiblingRow(sibling: sibling, open: open, sessions: sessions)
      }
    }
    .padding(.top, 1).padding(.bottom, 5)
  }

  /// True when the selected target's focused content tab is this commit's changeset — so the row
  /// showing in the pane reads as selected. The History analogue of `ChangedFileRow.isSelected`.
  private var isSelected: Bool {
    guard let target = store.selectedTarget, let tab = sessions.focusedTab(for: target)
    else { return false }
    if case .changeset(let descriptor) = tab.content {
      return descriptor.commitID == commit.commitID
    }
    return false
  }
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
private struct HistoryRootRow: View {
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

/// The history row's hover card — the same header layout the changeset detail view uses
/// (`ChangesetDetailView.header`), so a commit reads identically on hover as when opened: the summary
/// as a headline, an identity/author/date/refs line, then the full description body. Built purely from
/// the `VCSCommit` already in hand — no changeset fetch — so it omits the detail's diff `+N −M` stat
/// and file list (those need the resolved changeset). Rendered inside a `.popover`.
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
        .font(.headline)
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
      if !commit.body.isEmpty {
        Text(commit.body)
          .font(.callout).foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .frame(width: 420, alignment: .leading)
  }
}

/// One divergent-copy row inside the expander: jj's `id/N` label + summary + relative time, with the
/// SAME hover / selected highlight as a `HistoryRow` — a full-width band (content indented under the
/// parent). Selected when its changeset is the focused content tab; a single click opens it.
private struct DivergentSiblingRow: View {
  let sibling: VCSCommit
  /// Opens a commit's changeset detail (preview) — the parent row's `open`, siblings only preview.
  let open: (_ commit: VCSCommit, _ persist: Bool) -> Void
  @EnvironmentObject var store: AppStore
  @ObservedObject var sessions: TerminalSessions
  @State private var hovering = false
  private let theme = ThemeService.shared

  private static let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()

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
      Text(Self.relative.localizedString(for: sibling.timestamp, relativeTo: Date()))
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
  private var isSelected: Bool {
    guard let target = store.selectedTarget, let tab = sessions.focusedTab(for: target)
    else { return false }
    if case .changeset(let descriptor) = tab.content {
      return descriptor.commitID == sibling.commitID
    }
    return false
  }
}
