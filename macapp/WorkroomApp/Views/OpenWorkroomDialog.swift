import SwiftUI

/// Open Workroom picker (issue #94). A searchable list of existing roots + workrooms, raised by
/// File ▸ Open workroom… (⌘O). Type to filter (partial, case-insensitive); ↑/↓ move the highlight;
/// ⏎ or a click opens the target via `AppStore.openExisting` — switching to and focusing it (and
/// just refocusing if it's already the current selection).
///
/// Rows are **grouped by project**: a small, non-selectable project-name header, then a slightly
/// indented list of that project's root and its workrooms (alphabetical). The leading glyphs match
/// the left sidebar — `house` for a root, `cube` for a workroom.
///
/// Structurally this mirrors `NewWorkroomDialog` (search field + scroll/highlight + `.onKeyPress`),
/// with two deliberate differences from the New picker:
///  - The row list is built **once on appear** (a snapshot) and the filter runs over the cached
///    array — so the per-row `isMissing` filesystem check doesn't repeat on every keystroke.
///  - Missing-directory targets are excluded entirely (the sidebar remains the place to reach one).
///
/// Keyboard highlight indexes into the flat `filtered` list (headers aren't rows, so ↑/↓ skips
/// them); `grouped` only regroups those same rows for display.
///
/// ⌥⏎ (or ⌥-click) opens the target as a **split** beside the current workroom instead of
/// replacing it (issue #163); raised by ⌥⌘O the whole dialog is already in split mode, so a plain
/// ⏎ splits — which is why the title and footer are derived from `PickerSplitIntent`, not fixed.
///
///   ┌─ "Open Workroom [(split right)]" Done ─┐
///   │ 🔍 [ filter…                       ] │  ← auto-focused; single-line, so ↑/↓/⏎ bubble up
///   │ PROJECT-A                            │  ← header (not selectable)
///   │   🏠 project-a                       │  ← root (⏎ / click opens)
///   │   📦 fix-auth                        │  ← workroom (alphabetical)
///   │        ⏎ open · ⌥⏎ split             │  ← hint; reads "⏎ split" in split mode
///   └─────────────────────────────────────┘
struct OpenWorkroomDialog: View {
  @ObservedObject var store: AppStore
  /// Closes the dialog (the presenter owns the presentation state). Replaces `@Environment(\.dismiss)`
  /// now that the dialog is shown as a `DialogOverlay`, not a `.sheet`.
  let onClose: () -> Void
  /// Whether this dialog was raised in split mode (⌥⌘O) — consumed once by the presenter, so a
  /// cancelled raise can't leak into the next one. In split mode a plain pick already splits.
  var splitIntent = false
  private let theme = ThemeService.shared

  @State private var query = ""
  /// Index into `filtered` of the keyboard-highlighted row (↑/↓ move it, ⏎ / click open it).
  @State private var highlighted = 0
  /// The openable rows, snapshotted on appear (see the type doc: avoids re-statting the filesystem
  /// per keystroke). The picker is transient, so a workroom created while it's open won't appear —
  /// acceptable for a quick switcher.
  @State private var targets: [OpenTarget] = []
  @FocusState private var searchFocused: Bool

  /// Flat list the keyboard highlight indexes into (root-then-alphabetical, across all projects).
  private var filtered: [OpenTarget] {
    OpenPickerModel.filtered(targets, query: query)
  }

  /// The same rows, regrouped into per-project sections for display.
  private var groups: [OpenTargetGroup] {
    OpenPickerModel.grouped(filtered)
  }

  /// The id of the currently-highlighted flat row (for marking the displayed row + scroll-to).
  private var highlightedID: SidebarID? {
    filtered.indices.contains(highlighted) ? filtered[highlighted].id : nil
  }

  /// Open a target: dismiss first, then switch/focus it. `openExisting` selects + focuses the
  /// target (and brings the app forward), so the detail pane shows it — no extra wiring here.
  private func pick(_ target: OpenTarget, split: Bool = false) {
    onClose()
    if split || splitIntent {
      store.openExistingAsSplit(target.sid)
    } else {
      store.openExisting(target.sid)
    }
  }

  private func targetRow(_ target: OpenTarget) -> some View {
    OpenTargetRow(target: target, isHighlighted: target.id == highlightedID)
      .contentShape(Rectangle())
      .onTapGesture { pick(target, split: PickerSplitIntent.requestedFromCurrentModifiers()) }
      // Keyed on the immutable real name (not the label-derived `title`) so it stays a stable
      // UI-test handle even when a display label changes what's shown (issue #41).
      .accessibilityIdentifier("openWorkroom.target.\(target.name)")
      .id(target.id)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(PickerSplitIntent.title(open: true, split: splitIntent)).font(.headline)
        Spacer()
        Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
      }
      .padding(12)
      Divider()

      searchField

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            if filtered.isEmpty {
              Text(emptyMessage)
                .font(.footnote)
                .foregroundStyle(theme.tokens.fgMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
              ForEach(groups) { group in
                Text(group.projectName)
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundStyle(theme.tokens.fgMuted)
                  .textCase(.uppercase)
                  .padding(.horizontal, 8)
                  .padding(.top, 8)
                  .padding(.bottom, 2)
                ForEach(group.rows) { target in
                  targetRow(target)
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
        }
        .onChange(of: highlighted) { _, _ in
          if let id = highlightedID {
            withAnimation(.easeInOut(duration: 0.1)) { proxy.scrollTo(id) }
          }
        }
      }

      PickerHintFooter(open: true, split: splitIntent)
    }
    .frame(width: 420, height: 460)
    .onAppear {
      targets = OpenPickerModel.targets(from: store.projects)
      searchFocused = true
    }
    // ↑/↓ move the highlight; ⏎ opens the highlighted target. The single-line search field doesn't
    // consume the arrow keys, so they bubble here (same as NewWorkroomDialog / ThemePicker).
    .onKeyPress(.upArrow) {
      highlighted = OpenPickerModel.move(highlight: highlighted, by: -1, count: filtered.count)
      return .handled
    }
    .onKeyPress(.downArrow) {
      highlighted = OpenPickerModel.move(highlight: highlighted, by: 1, count: filtered.count)
      return .handled
    }
    // ⌥⏎ splits, plain ⏎ opens (issue #163). The `keys:` overload is what carries the modifiers;
    // the plain `.onKeyPress(.return)` closure has none. Still wired ONLY here, never on the
    // field's `.onSubmit` — a double-fire would open twice.
    .onKeyPress(keys: [.return]) { press in
      if let target = OpenPickerModel.selection(filtered: filtered, highlight: highlighted) {
        pick(target, split: PickerSplitIntent.requested(press.modifiers))
      }
      return .handled
    }
    // Re-filtering can shrink the list below the old index, so reset the highlight to the top.
    .onChange(of: query) { _, _ in highlighted = 0 }
  }

  /// Distinguishes "no projects/workrooms exist at all" from "the filter matched nothing".
  private var emptyMessage: String {
    targets.isEmpty
      ? "No workrooms to open" : "No workrooms match “\(query)”"
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(theme.tokens.fgDim)
      TextField("Filter workrooms", text: $query)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("openWorkroom.filter")
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain).foregroundStyle(theme.tokens.fgDim)
        .help("Clear filter")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(theme.tokens.surface)
        .overlay(
          RoundedRectangle(cornerRadius: 8).strokeBorder(theme.tokens.border, lineWidth: 0.5))
    )
    .padding(10)
  }
}

/// Presents `OpenWorkroomDialog` from `store.requestOpenWorkroomPicker` (set by the File ▸ Open
/// workroom… command, ⌘O). A `ViewModifier` so RootView's large `body` stays within the Swift
/// type-checker's budget — the same reason `NewWorkroomPresenter` is a modifier.
struct OpenWorkroomPresenter: ViewModifier {
  @ObservedObject var store: AppStore
  /// The split intent of the CURRENT raise, taken from the store as the picker goes up.
  @State private var splitIntent = false

  func body(content: Content) -> some View {
    content
      // Raising Open sets `activePicker = .open`, which replaces New if it was showing (issue #94).
      .onChange(of: store.requestOpenWorkroomPicker) { _, request in
        if request {
          // Consume the split intent as we raise, so it can never be read by a LATER plain raise
          // (⌥⌘O → Esc → the title bar's open button would otherwise still split).
          splitIntent = store.consumePickerSplitIntent()
          store.activePicker = .open
          store.requestOpenWorkroomPicker = false
        }
      }
      // A dismissable overlay (not a `.sheet`) so a click outside the dialog closes it.
      .overlay {
        if store.activePicker == .open {
          DialogOverlay(onDismiss: { store.activePicker = nil }) {
            OpenWorkroomDialog(
              store: store, onClose: { store.activePicker = nil }, splitIntent: splitIntent)
          }
        }
      }
  }
}

/// One openable row, indented under its project header: the leading glyph matches the left sidebar —
/// `house` for a root, `cube` for a workroom — then the title. Highlight + hover styling mirrors
/// `NewWorkroomDialog`'s `ProjectRow`.
private struct OpenTargetRow: View {
  private let theme = ThemeService.shared
  let target: OpenTarget
  var isHighlighted = false
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 8) {
      // Same SF Symbols the sidebar uses for root / workroom rows (ProjectSidebar.leadingSlot).
      Image(systemName: target.isRoot ? "house" : "cube")
        .font(.system(size: 11))
        .foregroundStyle(theme.tokens.fgDim)
        .frame(width: 14, alignment: .center)
      Text(target.title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(theme.tokens.fg)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    // Slight indent so rows sit beneath their project header.
    .padding(.leading, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isHighlighted ? theme.tokens.surface : (hovered ? theme.tokens.hover : .clear))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(isHighlighted ? theme.tokens.fgDim : .clear, lineWidth: 1.5)
    )
    .help(target.path)
    .onHover { hovered = $0 }
  }
}
