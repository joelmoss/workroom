import SwiftUI

/// New Workroom picker (issue #81). A searchable list of projects, raised by File ▸ New Workroom
/// (⌘N). Type to filter (partial, case-insensitive); ↑/↓ move the highlight; ⏎ or a click picks a
/// project and **immediately** creates + opens a new workroom in it via `AppStore.createWorkroom`.
///
/// Structurally this is `ThemePicker` (search field + scroll/highlight + `.onKeyPress`), with one
/// deliberate difference: ↑/↓ only MOVE the highlight here — they never create. Creating a workroom
/// per keystroke would be a disaster, so creation fires only on click or Return.
///
///   ┌─ "New Workroom" ───────────── Done ─┐
///   │ 🔍 [ filter…                       ] │  ← auto-focused; single-line, so ↑/↓/⏎ bubble up
///   │ ┌─────────────────────────────────┐ │
///   │ │ project-a            ~/code/a     │ │  ← highlighted row (⏎ / click creates)
///   │ │ project-b            ~/code/b     │ │
///   │ └─────────────────────────────────┘ │
///   └─────────────────────────────────────┘
struct NewWorkroomDialog: View {
  @ObservedObject var store: AppStore
  /// Closes the dialog (the presenter owns the presentation state). Replaces `@Environment(\.dismiss)`
  /// now that the dialog is shown as a `DialogOverlay`, not a `.sheet`.
  let onClose: () -> Void
  private let theme = ThemeService.shared

  @State private var query = ""
  /// Index into `filtered` of the keyboard-highlighted row (↑/↓ move it, ⏎ / click pick it).
  @State private var highlighted = 0
  @FocusState private var searchFocused: Bool

  private var filtered: [Project] {
    ProjectPickerModel.filtered(store.projects, query: query)
  }

  /// Pick a project: dismiss first, then kick off the (async) create+open. `createWorkroom` mounts
  /// and selects the new workroom, so the detail pane opens it — no extra wiring here.
  private func pick(_ project: Project) {
    onClose()
    Task { await store.createWorkroom(in: project) }
  }

  private func projectRow(_ project: Project, isHighlighted: Bool) -> some View {
    ProjectRow(project: project, isHighlighted: isHighlighted)
      .contentShape(Rectangle())
      .onTapGesture { pick(project) }
      .accessibilityIdentifier("newWorkroom.project.\(project.displayName)")
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("New Workroom").font(.headline)
        Spacer()
        Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
      }
      .padding(12)
      Divider()

      searchField

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            if filtered.isEmpty {
              Text("No projects match “\(query)”")
                .font(.footnote)
                .foregroundStyle(theme.tokens.fgMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
              ForEach(Array(filtered.enumerated()), id: \.element.id) { index, project in
                projectRow(project, isHighlighted: index == highlighted)
                  .id(project.id)
              }
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
        }
        .onChange(of: highlighted) { _, new in
          if filtered.indices.contains(new) {
            withAnimation(.easeInOut(duration: 0.1)) { proxy.scrollTo(filtered[new].id) }
          }
        }
      }
    }
    .frame(width: 420, height: 460)
    .onAppear { searchFocused = true }
    // ↑/↓ move the highlight (no create); ⏎ picks the highlighted project. The single-line search
    // field doesn't consume the arrow keys, so they bubble here (same as ThemePicker). ⏎ is wired
    // ONLY here — never on the field's `.onSubmit` — so a pick can't double-fire into a double-create.
    .onKeyPress(.upArrow) {
      highlighted = ProjectPickerModel.move(highlight: highlighted, by: -1, count: filtered.count)
      return .handled
    }
    .onKeyPress(.downArrow) {
      highlighted = ProjectPickerModel.move(highlight: highlighted, by: 1, count: filtered.count)
      return .handled
    }
    .onKeyPress(.return) {
      if let project = ProjectPickerModel.selection(filtered: filtered, highlight: highlighted) {
        pick(project)
      }
      return .handled
    }
    // Re-filtering can shrink the list below the old index, so reset the highlight to the top.
    .onChange(of: query) { _, _ in highlighted = 0 }
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(theme.tokens.fgDim)
      TextField("Filter projects", text: $query)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("newWorkroom.filter")
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

/// Presents `NewWorkroomDialog` from `store.requestNewWorkroomPicker` (set by the File ▸ New Workroom
/// command, ⌘N). Factored into a `ViewModifier` so RootView's large `body` stays within the Swift
/// type-checker's budget — the same reason `EdgeRevealSidebars` is a modifier. Owns the `isPresented`
/// state so RootView doesn't have to.
struct NewWorkroomPresenter: ViewModifier {
  @ObservedObject var store: AppStore

  func body(content: Content) -> some View {
    content
      // Raising New sets `activePicker = .new`, which replaces Open if it was showing (issue #94).
      .onChange(of: store.requestNewWorkroomPicker) { _, request in
        if request {
          store.activePicker = .new
          store.requestNewWorkroomPicker = false
          // Warm the shell-environment probe while the dialog is open. `create` awaits the same
          // single-flighted refresh, so by the time a project is picked the shell has usually
          // already reported — spending the latency the user was spending anyway. Purely an
          // optimization: if they pick fast, `create` just waits on this very task.
          Task.detached(priority: .userInitiated) { await ShellEnvironment.refresh() }
        }
      }
      // A dismissable overlay (not a `.sheet`) so a click outside the dialog closes it.
      .overlay {
        if store.activePicker == .new {
          DialogOverlay(onDismiss: { store.activePicker = nil }) {
            NewWorkroomDialog(store: store, onClose: { store.activePicker = nil })
          }
        }
      }
  }
}

/// One project row: the project's display name, with its full path dimmed beneath to disambiguate
/// same-named directories. Highlight + hover styling mirrors `ThemePicker`'s `FamilyRow`.
private struct ProjectRow: View {
  private let theme = ThemeService.shared
  let project: Project
  var isHighlighted = false
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "folder")
        .font(.system(size: 12))
        .foregroundStyle(theme.tokens.fgDim)
      VStack(alignment: .leading, spacing: 1) {
        Text(project.displayName)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(theme.tokens.fg)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(project.path)
          .font(.system(size: 10))
          .foregroundStyle(theme.tokens.fgMuted)
          .lineLimit(1)
          .truncationMode(.head)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isHighlighted ? theme.tokens.surface : (hovered ? theme.tokens.hover : .clear))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(isHighlighted ? theme.tokens.fgDim : .clear, lineWidth: 1.5)
    )
    .help(project.path)
    .onHover { hovered = $0 }
  }
}
