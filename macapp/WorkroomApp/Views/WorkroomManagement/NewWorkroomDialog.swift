import DesignSystem
import SwiftUI
import WorkroomDomain
import WorkroomSystem

/// New Workroom picker (issue #81). A searchable list of projects, raised by File ▸ New Workroom
/// (⌘N). Type to filter (partial, case-insensitive); ↑/↓ move the highlight; ⏎ or a click picks a
/// project, and the dialog then asks where its new workroom goes (see below).
///
/// Structurally this is `ThemePicker` (search field + scroll/highlight + `.onKeyPress`), with one
/// deliberate difference: ↑/↓ only MOVE the highlight here — they never create. Creating a workroom
/// per keystroke would be a disaster, so creation fires only on click or Return.
///
/// ⌥⏎ (or ⌥-click) creates the workroom as a **split** beside the current one instead of
/// replacing it (issue #163); raised by ⌥⌘N the whole dialog is already in split mode, so a plain
/// ⏎ splits — which is why the title and footer are derived from `PickerSplitIntent`, not fixed.
///
/// Picking a project doesn't create yet (#309): the dialog asks where, This Mac, a local container
/// or boxd, as the sidebar's New Workroom menu does, and the place picked creates and opens it.
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
  @Environment(\.themeTokens) private var tokens

  /// `configure` opens straight on one create's host options (the sidebar's "boxd ▸ Configure…"),
  /// set before the first frame so the projects never show on the way there.
  init(
    store: AppStore, onClose: @escaping () -> Void, splitIntent: Bool = false,
    configure: ConfigureRequest? = nil
  ) {
    self.store = store
    self.onClose = onClose
    self.splitIntent = splitIntent
    _step = State(
      initialValue: configure.map { .configure($0.project, $0.place) } ?? .projects)
    _placeAnchor = State(initialValue: configure?.splitAnchor)
  }

  /// Where the dialog is: choosing a project, then where its workroom goes (#309), then, for boxd
  /// or exe.dev, its host options (#575).
  enum Step: Equatable {
    case projects
    case places(Project)
    case configure(Project, HostKind)

    /// The step Back goes to; nil on the projects, which have no Back.
    var back: Step? {
      switch self {
      case .projects: nil
      case .places: .projects
      case .configure(let project, _): .places(project)
      }
    }

    /// Whether ↑/↓/←/⏎ drive the dialog's list. In host options they are its fields' and Create
    /// Workroom's.
    var takesListKeys: Bool {
      if case .configure = self { return false }
      return true
    }
  }

  @State private var query = ""
  /// Index into `filtered` of the keyboard-highlighted row (↑/↓ move it, ⏎ / click pick it).
  @State private var highlighted = 0
  @FocusState private var searchFocused: Bool
  @State private var step: Step
  /// Where the picked project's workroom lands beside, taken when it was picked.
  @State private var placeAnchor: SidebarID?
  @FocusState private var placesFocused: Bool

  private var filtered: [Project] {
    ProjectPickerModel.filtered(store.projectStore.projects, query: query)
  }

  /// Pick a project: dismiss first, then kick off the (async) create+open. `createWorkroom` mounts
  /// and selects the new workroom, so the detail pane opens it — no extra wiring here.
  private func pick(_ project: Project, split: Bool = false) {
    // Capture the anchor NOW, not at landing: the create is async and the user can select a
    // different workroom while a setup script runs.
    let anchor = (split || splitIntent) ? store.selectedTargetID : nil
    step = .places(project)
    placeAnchor = anchor
    highlighted = WorkroomPlace.all.firstIndex { isUsable($0, in: project) } ?? 0
  }

  /// Creates `project`'s workroom at `place`, unless it can't go there now.
  private func pick(_ place: WorkroomPlace, in project: Project, split: Bool = false) {
    guard isUsable(place, in: project) else { return }
    onClose()
    let anchor = placeAnchor ?? (split ? store.selectedTargetID : nil)
    Task {
      if let remote = place.remote {
        await store.lifecycle.createRemoteWorkroom(
          in: project, place: remote, splitAnchor: anchor, from: store)
      } else {
        await store.lifecycle.createWorkroom(in: project, splitAnchor: anchor, from: store)
      }
    }
  }

  /// Whether a workroom of `project` can be created at `place` now. The same rules as the sidebar's
  /// New Workroom menu.
  private func isUsable(_ place: WorkroomPlace, in project: Project) -> Bool {
    switch place {
    case .thisMac: store.lifecycle.createBlockedReason(in: project) == nil
    case .remote(let remote):
      RemoteWorkrooms.unavailability(of: remote) == nil
        && store.lifecycle.canCreateRemoteWorkroom(in: project)
    }
  }

  private var rowCount: Int {
    if case .projects = step { return filtered.count }
    return WorkroomPlace.all.count
  }

  /// One step back (the back button, or ← on the places): from a place's host options to the
  /// places, highlighting that place; from the places to the projects.
  private func goBack() {
    guard let back = step.back else { return }
    let left = step
    step = back
    if case .configure(_, let place) = left {
      highlighted = WorkroomPlace.all.firstIndex(of: .remote(place)) ?? 0
      placesFocused = true
    } else {
      placeAnchor = nil
      highlighted = 0
      searchFocused = true
    }
  }

  private var title: String {
    switch step {
    case .projects: PickerSplitIntent.title(open: false, split: splitIntent)
    case .places(let project): "New Workroom in \(project.displayName)"
    case .configure(let project, let place):
      "New \(place.displayName) Workroom in \(project.displayName)"
    }
  }

  /// Where `project`'s workroom can go: the reason none can, said once, then each place, a
  /// container one saying why it can't be used.
  private func placesList(_ project: Project) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if let blocked = store.lifecycle.createBlockedReason(in: project) {
        Text(blocked.prefix(1).uppercased() + blocked.dropFirst())
          .font(.footnote)
          .foregroundStyle(tokens.fgMuted)
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
    return HStack(spacing: 6) {
      Button {
        pick(place, in: project, split: PickerSplitIntent.requestedFromCurrentModifiers())
      } label: {
        PickerRow(
          icon: place.icon, title: place.name, detail: reason ?? place.detail,
          help: reason.map { "\(place.name) can't be used: \($0)" } ?? place.detail,
          isHighlighted: isHighlighted, dimmed: !usable)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("newWorkroom.place.\(place.id)")
      if place.remote?.takesHostOptions == true {
        Button {
          openOptions(place, in: project, split: PickerSplitIntent.requestedFromCurrentModifiers())
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(ToolbarIconButtonStyle())
        .help("Configure")
        .accessibilityLabel("Configure")
        .accessibilityIdentifier("newWorkroom.options.\(place.id)")
      }
    }
    .disabled(!usable)
  }

  /// A boxd or exe.dev place's Configure (#575): the create waits on its host options, the next
  /// step. A split asked for here is taken now, as a pick takes it.
  private func openOptions(_ place: WorkroomPlace, in project: Project, split: Bool = false) {
    guard let remote = place.remote, remote.takesHostOptions, isUsable(place, in: project)
    else { return }
    if split, placeAnchor == nil { placeAnchor = store.selectedTargetID }
    step = .configure(project, remote)
  }

  /// Creates `project`'s workroom at `place` with the options chosen in its step.
  private func create(in project: Project, at place: HostKind, options: HostOptions?) {
    onClose()
    let anchor = placeAnchor
    Task {
      await store.lifecycle.createRemoteWorkroom(
        in: project, place: place, splitAnchor: anchor, hostOptions: options, from: store)
    }
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
        if step.back != nil {
          Button(action: goBack) {
            Image(systemName: "chevron.left")
          }
          .buttonStyle(ToolbarIconButtonStyle())
          // ← moves a field's caret in host options, so only the button goes back there.
          .help(step.takesListKeys ? "Back (←)" : "Back")
          .accessibilityLabel("Back")
          .accessibilityIdentifier("newWorkroom.back")
        }
        Text(title).font(.headline).lineLimit(1)
        Spacer()
        Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
      }
      .padding(12)
      Divider()

      switch step {
      case .projects:
        searchField
        projectList
      case .places(let project):
        placesList(project)
      case .configure(let project, let place):
        HostOptionsStep(store: store, project: project, provider: place) { options in
          create(in: project, at: place, options: options)
        }
        .id(place)
      }

      if step.takesListKeys { PickerHintFooter(open: false, split: splitIntent) }
    }
    .frame(width: 420, height: 460)
    .onAppear { if step == .projects { searchFocused = true } }
    // ↑/↓ move the highlight (no create); ⏎ picks the highlighted row. The single-line search
    // field doesn't consume the arrow keys, so they bubble here (same as ThemePicker). ⏎ is wired
    // ONLY here — never on the field's `.onSubmit` — so a pick can't double-fire into a double-create.
    // In host options every key passes (`Step.takesListKeys`).
    .onKeyPress(.upArrow) {
      guard step.takesListKeys else { return .ignored }
      highlighted = ProjectPickerModel.move(highlight: highlighted, by: -1, count: rowCount)
      return .handled
    }
    .onKeyPress(.downArrow) {
      guard step.takesListKeys else { return .ignored }
      highlighted = ProjectPickerModel.move(highlight: highlighted, by: 1, count: rowCount)
      return .handled
    }
    // ← steps back from the places. On the projects it stays the filter field's caret key.
    .onKeyPress(.leftArrow) {
      guard case .places = step else { return .ignored }
      goBack()
      return .handled
    }
    // ⌥⏎ splits, plain ⏎ creates (issue #163). The `keys:` overload is what carries the modifiers;
    // the plain `.onKeyPress(.return)` closure has none. Still wired ONLY here, never on the
    // field's `.onSubmit` — a double-fire would be a double *create*.
    .onKeyPress(keys: [.return]) { press in
      let split = PickerSplitIntent.requested(press.modifiers)
      switch step {
      case .configure:
        return .ignored
      case .places(let project):
        if WorkroomPlace.all.indices.contains(highlighted) {
          let place = WorkroomPlace.all[highlighted]
          // ⌘⏎ opens a boxd or exe.dev place's Configure… (#575); elsewhere it creates, as before.
          if press.modifiers.contains(.command), place.remote?.takesHostOptions == true {
            openOptions(place, in: project, split: split)
          } else {
            pick(place, in: project, split: split)
          }
        }
      case .projects:
        if let project = ProjectPickerModel.selection(filtered: filtered, highlight: highlighted) {
          pick(project, split: split)
        }
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
              .foregroundStyle(tokens.fgMuted)
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
      Image(systemName: "magnifyingglass").foregroundStyle(tokens.fgDim)
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
        .buttonStyle(.plain).foregroundStyle(tokens.fgDim)
        .help("Clear filter")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: Radius.m)
        .fill(tokens.surface)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.m).strokeBorder(tokens.border, lineWidth: 0.5))
    )
    .padding(10)
  }
}

/// Presents `NewWorkroomDialog` from `store.modals.requestNewWorkroomPicker` (set by the File ▸ New Workroom
/// command, ⌘N). Factored into a `ViewModifier` so RootView's large `body` stays within the Swift
/// type-checker's budget — the same reason `EdgeRevealSidebars` is a modifier. Owns the `isPresented`
/// state so RootView doesn't have to.
struct NewWorkroomPresenter: ViewModifier {
  @ObservedObject var store: AppStore
  /// The split intent of the CURRENT raise, taken from the store as the picker goes up.
  @State private var splitIntent = false
  /// The create whose host options the CURRENT raise opens on, taken from the store as it goes up.
  @State private var configure: ConfigureRequest?

  func body(content: Content) -> some View {
    content
      // The sidebar's "boxd ▸ Configure…" (#575): the dialog, opened on that create's host options.
      .onChange(of: store.modals.requestNewWorkroomConfigure?.id) { _, id in
        guard id != nil, let request = store.modals.requestNewWorkroomConfigure else { return }
        store.modals.requestNewWorkroomConfigure = nil
        splitIntent = false
        configure = request
        store.modals.activePicker = .new
      }
      // Raising New sets `activePicker = .new`, which replaces Open if it was showing (issue #94).
      .onChange(of: store.modals.requestNewWorkroomPicker) { _, request in
        if request {
          // Consume the split intent as we raise, so it can never be read by a LATER plain raise
          // (⌥⌘N → Esc → the title bar's + button would otherwise still split).
          splitIntent = store.consumePickerSplitIntent()
          configure = nil
          store.modals.activePicker = .new
          store.modals.requestNewWorkroomPicker = false
          // Warm the shell-environment probe while the dialog is open. `create` awaits the same
          // single-flighted refresh, so by the time a project is picked the shell has usually
          // already reported — spending the latency the user was spending anyway. Purely an
          // optimization: if they pick fast, `create` just waits on this very task.
          Task.detached(priority: .userInitiated) { await ShellEnvironment.refresh() }
        }
      }
      // A dismissable overlay (not a `.sheet`) so a click outside the dialog closes it.
      .overlay {
        if store.modals.activePicker == .new {
          DialogOverlay(onDismiss: { store.modals.activePicker = nil }) {
            NewWorkroomDialog(
              store: store, onClose: { store.modals.activePicker = nil }, splitIntent: splitIntent,
              configure: configure)
          }
        }
      }
  }
}

/// Where a new workroom can go (#309, #356): this Mac, a local container on one of the runtimes,
/// or a boxd machine.
enum WorkroomPlace: Hashable {
  case thisMac
  case remote(HostKind)

  static var all: [WorkroomPlace] {
    [.thisMac] + HostKind.all.map { .remote($0) }
  }

  /// The kind of host this is, or nil for this Mac.
  var remote: HostKind? {
    if case .remote(let kind) = self { return kind }
    return nil
  }

  var name: String { CreationRun.destination(of: remote) }

  /// The descriptor's `driver` for a host, which accessibility identifiers name.
  var id: String { remote?.driver ?? "thisMac" }

  var icon: String {
    switch self {
    case .thisMac: "laptopcomputer"
    case .remote(let place): place.icon
    }
  }

  var detail: String {
    switch self {
    case .thisMac: "A workroom on this Mac"
    case .remote(.container(let runtime)): "A workroom in \(runtime.containerPhrase) on this Mac"
    case .remote(.boxd): "A workroom on a boxd machine"
    case .remote(.exeDev): "A workroom on an exe.dev VM"
    case .remote(.ssh): "A folder on a Linux server you already have"
    }
  }
}

/// One picker row: a title, with a dimmed detail beneath — a project's full path, to disambiguate
/// same-named directories, or what a place is. Highlight + hover styling mirrors `ThemePicker`'s
/// `FamilyRow`.
private struct PickerRow: View {
  @Environment(\.themeTokens) private var tokens
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
        .foregroundStyle(tokens.fgDim)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(dimmed ? tokens.fgMuted : tokens.fg)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(detail)
          .font(.system(size: 10))
          .foregroundStyle(tokens.fgMuted)
          .lineLimit(1)
          .truncationMode(detailTruncation)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .pickerRowChrome(highlighted: isHighlighted, hovered: hovered)
    .contentShape(Rectangle())
    .help(help)
    .onHover { hovered = $0 }
  }
}
