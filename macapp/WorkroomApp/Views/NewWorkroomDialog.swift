import SwiftUI

/// New Workroom picker (issue #81). A searchable list of projects, raised by File ▸ New Workroom
/// (⌘N). Type to filter (partial, case-insensitive); ↑/↓ move the highlight; ⏎ or a click picks a
/// project and **immediately** creates + opens a new workroom in it via `AppStore.createWorkroom`.
///
/// Structurally this is `ThemePicker` (search field + scroll/highlight + `.onKeyPress`), with one
/// deliberate difference: ↑/↓ only MOVE the highlight here — they never create. Creating a workroom
/// per keystroke would be a disaster, so creation fires only on click or Return.
///
/// ⌥⏎ (or ⌥-click) creates the workroom as a **split** beside the current one instead of
/// replacing it (issue #163); raised by ⌥⌘N the whole dialog is already in split mode, so a plain
/// ⏎ splits — which is why the title and footer are derived from `PickerSplitIntent`, not fixed.
///
/// With the remote preview on (#309), picking a project doesn't create yet: the dialog then asks
/// where, This Mac or a local container, as the sidebar's New Workroom menu does, and the place
/// picked creates.
///
///   ┌─ "New Workroom [(split right)]" ─ Done ─┐
///   │ 🔍 [ filter…                       ] │  ← auto-focused; single-line, so ↑/↓/⏎ bubble up
///   │ ┌─────────────────────────────────┐ │
///   │ │ project-a            ~/code/a     │ │  ← highlighted row (⏎ / click creates)
///   │ │ project-b            ~/code/b     │ │
///   │ └─────────────────────────────────┘ │
///   │      ⏎ create · ⌥⏎ split            │  ← hint; reads "⏎ split" in split mode
///   └─────────────────────────────────────┘
struct NewWorkroomDialog: View {
  @ObservedObject var store: AppStore
  /// Closes the dialog (the presenter owns the presentation state). Replaces `@Environment(\.dismiss)`
  /// now that the dialog is shown as a `DialogOverlay`, not a `.sheet`.
  let onClose: () -> Void
  /// Whether this dialog was raised in split mode (⌥⌘N) — consumed once by the presenter, so a
  /// cancelled raise can't leak into the next one. In split mode a plain pick already splits.
  var splitIntent = false
  private let theme = ThemeService.shared

  @State private var query = ""
  /// Index into `filtered` of the keyboard-highlighted row (↑/↓ move it, ⏎ / click pick it).
  @State private var highlighted = 0
  @FocusState private var searchFocused: Bool
  /// The project picked while the remote preview is on (#309), whose workroom's place is asked next.
  @State private var placing: Project?
  /// Where that workroom lands beside, taken when its project was picked.
  @State private var placeAnchor: SidebarID?
  @FocusState private var placesFocused: Bool

  private var filtered: [Project] {
    ProjectPickerModel.filtered(store.projects, query: query)
  }

  /// Pick a project: dismiss first, then kick off the (async) create+open. `createWorkroom` mounts
  /// and selects the new workroom, so the detail pane opens it — no extra wiring here.
  private func pick(_ project: Project, split: Bool = false) {
    // Capture the anchor NOW, not at landing: the create is async and the user can select a
    // different workroom while a setup script runs.
    let anchor = (split || splitIntent) ? store.selectedTargetID : nil
    if RemoteWorkrooms.isEnabled {
      placing = project
      placeAnchor = anchor
      highlighted = WorkroomPlace.all.firstIndex { isUsable($0, in: project) } ?? 0
      return
    }
    onClose()
    Task { await store.createWorkroom(in: project, splitAnchor: anchor) }
  }

  /// Creates `project`'s workroom at `place`, unless it can't go there now.
  private func pick(_ place: WorkroomPlace, in project: Project, split: Bool = false) {
    guard isUsable(place, in: project) else { return }
    onClose()
    let anchor = placeAnchor ?? (split ? store.selectedTargetID : nil)
    Task {
      if let remote = place.remote {
        await store.createRemoteWorkroom(in: project, place: remote, splitAnchor: anchor)
      } else {
        await store.createWorkroom(in: project, splitAnchor: anchor)
      }
    }
  }

  /// Whether a workroom of `project` can be created at `place` now. The same rules as the sidebar's
  /// New Workroom menu.
  private func isUsable(_ place: WorkroomPlace, in project: Project) -> Bool {
    switch place {
    case .thisMac: !store.isBusyProject(project.path)
    case .container, .boxd:
      place.remote.flatMap(RemoteWorkrooms.unavailability(of:)) == nil
        && store.canCreateRemoteWorkroom(in: project)
    }
  }

  private var rowCount: Int { placing == nil ? filtered.count : WorkroomPlace.all.count }

  /// Where `project`'s workroom can go: the reason none can, said once, then each place, a
  /// container one saying why it can't be used.
  private func placesList(_ project: Project) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if let blocked = store.createBlockedReason(in: project) {
        Text(blocked.prefix(1).uppercased() + blocked.dropFirst())
          .font(.footnote)
          .foregroundStyle(theme.tokens.fgMuted)
          .padding(.horizontal, 8)
          .padding(.bottom, 6)
          .accessibilityIdentifier("newWorkroom.placesBlocked")
      }
      ForEach(Array(WorkroomPlace.all.enumerated()), id: \.element) { index, place in
        placeRow(place, in: project, isHighlighted: index == highlighted)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    // Nothing in here takes the keyboard, so the list itself does: ↑/↓/⏎ reach the handlers below.
    .focusable()
    .focusEffectDisabled()
    .focused($placesFocused)
    .onAppear { placesFocused = true }
  }

  private func placeRow(_ place: WorkroomPlace, in project: Project, isHighlighted: Bool)
    -> some View
  {
    let usable = isUsable(place, in: project)
    let reason = place.remote.flatMap(RemoteWorkrooms.unavailability(of:))
    return Button {
      pick(place, in: project, split: PickerSplitIntent.requestedFromCurrentModifiers())
    } label: {
      PickerRow(
        icon: place.icon, title: place.name, detail: reason ?? place.detail,
        help: reason.map { "\(place.name) can't be used: \($0)" } ?? place.detail,
        isHighlighted: isHighlighted, dimmed: !usable)
    }
    .buttonStyle(.plain)
    .disabled(!usable)
    .accessibilityIdentifier("newWorkroom.place.\(place.id)")
  }

  private func projectRow(_ project: Project, isHighlighted: Bool) -> some View {
    PickerRow(
      icon: "folder", title: project.displayName, detail: project.path, help: project.path,
      detailTruncation: .head, isHighlighted: isHighlighted
    )
    .contentShape(Rectangle())
    .onTapGesture { pick(project, split: PickerSplitIntent.requestedFromCurrentModifiers()) }
    .accessibilityIdentifier("newWorkroom.project.\(project.displayName)")
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        if let placing {
          Text("New Workroom in \(placing.displayName)").font(.headline)
        } else {
          Text(PickerSplitIntent.title(open: false, split: splitIntent)).font(.headline)
        }
        Spacer()
        if placing != nil {
          Button("Back") {
            placing = nil
            placeAnchor = nil
            highlighted = 0
            searchFocused = true
          }
          .accessibilityIdentifier("newWorkroom.back")
        }
        Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
      }
      .padding(12)
      Divider()

      if let placing {
        placesList(placing)
      } else {
        searchField
        projectList
      }

      PickerHintFooter(open: false, split: splitIntent)
    }
    .frame(width: 420, height: 460)
    .onAppear { searchFocused = true }
    // ↑/↓ move the highlight (no create); ⏎ picks the highlighted row. The single-line search
    // field doesn't consume the arrow keys, so they bubble here (same as ThemePicker). ⏎ is wired
    // ONLY here — never on the field's `.onSubmit` — so a pick can't double-fire into a double-create.
    .onKeyPress(.upArrow) {
      highlighted = ProjectPickerModel.move(highlight: highlighted, by: -1, count: rowCount)
      return .handled
    }
    .onKeyPress(.downArrow) {
      highlighted = ProjectPickerModel.move(highlight: highlighted, by: 1, count: rowCount)
      return .handled
    }
    // ⌥⏎ splits, plain ⏎ creates (issue #163). The `keys:` overload is what carries the modifiers;
    // the plain `.onKeyPress(.return)` closure has none. Still wired ONLY here, never on the
    // field's `.onSubmit` — a double-fire would be a double *create*.
    .onKeyPress(keys: [.return]) { press in
      let split = PickerSplitIntent.requested(press.modifiers)
      if let placing {
        if WorkroomPlace.all.indices.contains(highlighted) {
          pick(WorkroomPlace.all[highlighted], in: placing, split: split)
        }
      } else if let project = ProjectPickerModel.selection(
        filtered: filtered, highlight: highlighted)
      {
        pick(project, split: split)
      }
      return .handled
    }
    // Re-filtering can shrink the list below the old index, so reset the highlight to the top.
    .onChange(of: query) { _, _ in highlighted = 0 }
  }

  private var projectList: some View {
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
  /// The split intent of the CURRENT raise, taken from the store as the picker goes up.
  @State private var splitIntent = false

  func body(content: Content) -> some View {
    content
      // Raising New sets `activePicker = .new`, which replaces Open if it was showing (issue #94).
      .onChange(of: store.requestNewWorkroomPicker) { _, request in
        if request {
          // Consume the split intent as we raise, so it can never be read by a LATER plain raise
          // (⌥⌘N → Esc → the title bar's + button would otherwise still split).
          splitIntent = store.consumePickerSplitIntent()
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
            NewWorkroomDialog(
              store: store, onClose: { store.activePicker = nil }, splitIntent: splitIntent)
          }
        }
      }
  }
}

/// Where a new workroom can go (#309, #356): this Mac, a local container on one of the runtimes,
/// or a boxd machine.
enum WorkroomPlace: Hashable {
  case thisMac
  case container(RemoteWorkrooms.Runtime)
  case boxd

  static var all: [WorkroomPlace] {
    [.thisMac] + RemoteWorkrooms.Runtime.allCases.map { .container($0) } + [.boxd]
  }

  /// The remote place this is, or nil for this Mac.
  var remote: RemoteWorkrooms.Place? {
    switch self {
    case .thisMac: nil
    case .container(let runtime): .container(runtime)
    case .boxd: .boxd
    }
  }

  var name: String { remote?.displayName ?? "This Mac" }

  var id: String {
    switch self {
    case .thisMac: "thisMac"
    case .container(let runtime): runtime.rawValue
    case .boxd: RemoteWorkrooms.boxdDriver
    }
  }

  var icon: String {
    switch self {
    case .thisMac: "laptopcomputer"
    case .container: "network"
    case .boxd: "cloud"
    }
  }

  var detail: String {
    switch self {
    case .thisMac: "A workroom on this Mac"
    case .container(let runtime): "A workroom in \(runtime.containerPhrase) on this Mac"
    case .boxd: "A workroom on a boxd machine"
    }
  }
}

/// One picker row: a title, with a dimmed detail beneath — a project's full path, to disambiguate
/// same-named directories, or what a place is. Highlight + hover styling mirrors `ThemePicker`'s
/// `FamilyRow`.
private struct PickerRow: View {
  private let theme = ThemeService.shared
  let icon: String
  let title: String
  let detail: String
  let help: String
  var detailTruncation: Text.TruncationMode = .tail
  var isHighlighted = false
  /// A row that can't be picked now.
  var dimmed = false
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 12))
        .foregroundStyle(theme.tokens.fgDim)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(dimmed ? theme.tokens.fgMuted : theme.tokens.fg)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(detail)
          .font(.system(size: 10))
          .foregroundStyle(theme.tokens.fgMuted)
          .lineLimit(1)
          .truncationMode(detailTruncation)
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
    .contentShape(Rectangle())
    .help(help)
    .onHover { hovered = $0 }
  }
}
