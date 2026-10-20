import AppKit
import SwiftUI
import WorkroomDomain

/// The inspector's **Details** pane: the selected workroom itself rather than its repository. Where
/// it runs (this Mac, a container, a boxd or exe.dev machine) and its path there, then, for a
/// container workroom, its Ports list. A remote provider publishes its machines' ports itself, and a
/// workroom on this Mac reaches its ports directly, so neither shows one.
struct DetailsPanel: View {
  @EnvironmentObject var store: AppStore
  private let theme = ThemeService.shared

  var body: some View {
    Group {
      if let target = store.inspectorTarget {
        details(target)
      } else {
        inspectorMessage("Select a workroom to see where it runs.")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func details(_ target: TerminalTarget) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        // The provider's name links to the machine's page on its dashboard.
        let dashboard = target.machineName.flatMap { machine in
          target.hostPlace.flatMap { place in
            place.dashboardURL(machine: machine).map { (place.displayName, $0) }
          }
        }
        fact("Running on", target.hostKind ?? "This Mac", link: dashboard)
        if let machine = target.machineName { fact("Machine Name", machine, copyable: true) }
        fact(target.hostKind == nil ? "Path" : "Path on its host", target.path, copyable: true)
        if let note = target.remoteNote {
          Text(note).font(.caption2).foregroundStyle(.secondary)
        }
      }
      .padding(12)
      ports(target)
    }
  }

  /// Only where ports can be forwarded: a container workroom this app reaches. Nowhere else has
  /// anything to configure here.
  @ViewBuilder
  private func ports(_ target: TerminalTarget) -> some View {
    if case .container = target.hostPlace, let host = target.remoteHost {
      Divider()
      PortsSection(model: .model(for: .remote(host)))
    }
  }

  private func fact(
    _ title: String, _ value: String, copyable: Bool = false,
    link: (text: String, url: URL)? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 2) {
        factValue(value, copyable: copyable, link: link)
        if copyable {
          InspectorHeaderButton(
            systemImage: "doc.on.doc", help: "Copy \(title.lowercased())", compact: true
          ) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
          }
          // Its glyph on the value's first line.
          .padding(.top, -3)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func factValue(
    _ value: String, copyable: Bool, link: (text: String, url: URL)?
  ) -> some View {
    // Every value the same size. A name or path to copy into a terminal is code-like, so
    // monospaced; "Running on" is prose.
    Group {
      // A link ends the value ("Remote workroom on boxd"), with the external-link mark after it.
      if let link, value.hasSuffix(link.text) {
        HStack(spacing: 0) {
          Text(value.dropLast(link.text.count)).foregroundStyle(theme.tokens.fg)
          Link(destination: link.url) {
            HStack(spacing: 2) {
              Text(link.text)
              Image(systemName: "arrow.up.forward.square")
            }
          }
          .foregroundStyle(Color(nsColor: .linkColor))
          .help(link.url.absoluteString)
        }
      } else {
        Text(value)
          .foregroundStyle(theme.tokens.fg)
          .textSelection(.enabled)
          .lineLimit(3)
          .truncationMode(.middle)
      }
    }
    .font(.system(size: 11, design: copyable ? .monospaced : .default))
  }
}

/// The right sidebar's title, above every pane: the workroom the whole sidebar is about, and its
/// project. It follows the same target the panes do (`inspectorTarget`), so it never names a
/// workroom they aren't showing.
struct InspectorWorkroomHeader: View {
  @EnvironmentObject var store: AppStore
  private let theme = ThemeService.shared

  var body: some View {
    HStack(spacing: 6) {
      Group {
        if let sid = store.inspectorTargetID, let target = store.inspectorTarget {
          // `project / workroom`, as the pane title bar and the tab chips write it; a root is its
          // project's name alone.
          // Led by the glyph the sidebar and tab bar mark it with: a house for a root.
          let workroom = WorkroomSplitTitlePresentation.workroomName(sid: sid, target: target)
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: workroom == nil ? "house" : target.workroomGlyph)
              .foregroundStyle(theme.tokens.fgMuted)
            Text(store.project(forTargetID: target.id)?.displayName ?? target.title)
            if let workroom {
              Text("/").foregroundStyle(.tertiary)
              Text(workroom)
            }
          }
          .foregroundStyle(theme.tokens.fg)
          .lineLimit(1)
          .truncationMode(.tail)
        } else {
          Text("No open workroom").foregroundStyle(theme.tokens.fgMuted)
        }
      }
      .font(.callout)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("inspector.workroomHeader")
      Spacer(minLength: 0)
      if let sid = store.inspectorTargetID { actions(sid) }
    }
    .padding(.leading, 12)
    .padding(.trailing, 4)
    // The actions button's 26pt target plus this is the header's height, with or without it.
    .frame(minHeight: 26)
    .padding(.vertical, 6)
    // The sidebar's title, not one more section, so it stands out from their grey `surface` by
    // colour alone, at the same type size: the focused workroom card's accent fill, always, as the
    // project sidebar's selected row wears it too. It drops the accent with the window's focus, as
    // the card does.
    .background(WorkroomPaneCardBackground(highlighted: true))
  }

  /// The workroom's own actions, from the same items as its other menus (`WorkroomContextMenu`),
  /// in Apple's order: the destructive one last, apart. A root has only Move to New Window, as it
  /// is never labelled or deleted.
  private func actions(_ sid: SidebarID) -> some View {
    Menu {
      moveToNewWindowMenuItem(store: store, sid: sid)
      if let pair = store.workroomAndProject(for: sid) {
        Divider()
        workroomLabelMenuItems(store: store, workroom: pair.workroom, project: pair.project)
        Divider()
        deleteWorkroomMenuItem(store: store, workroom: pair.workroom, project: pair.project)
      }
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(.secondary)
    }
    // As the Pull Request header's menu: a SwiftUI-button trigger, so it takes the header buttons'
    // hover fill and click target (`InspectorMenuButtonStyle`).
    .menuStyle(.button)
    .buttonStyle(InspectorMenuButtonStyle())
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Workroom actions")
    .accessibilityLabel("Workroom actions")
    .accessibilityIdentifier("inspector.workroomActions")
  }
}

/// Ports forwarded from a container workroom's host to this Mac (issues #208, #254): the ones its
/// dev container declares, and any the user adds. Nothing is persisted across launches: the agent
/// closes every forwarded socket when the client detaches, so a list restored at launch would name
/// addresses that no longer answer; the declared ones are forwarded again instead.
private struct PortsSection: View {
  @ObservedObject var model: PortForwardingModel
  /// A new row's port field is showing, after `+`.
  @State private var adding = false
  @FocusState private var fieldFocused: Bool
  private let theme = ThemeService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("Ports").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        InspectorHeaderButton(
          systemImage: "plus", help: "Forward a port from this workroom's container"
        ) {
          adding = true
          fieldFocused = true
        }
        .accessibilityIdentifier("ports.add")
      }
      if !model.connected {
        // Said here rather than discovered from `+`: the controls are useless without an agent. A
        // forward kept across the lost connection reconnects when it is used (#380).
        Text(
          model.forwards.contains(where: \.reconnects)
            ? "Not connected. A forward reconnects when it is used."
            : "No agent is connected."
        )
        .font(.caption2).foregroundStyle(.secondary)
      }
      if let message = model.message {
        Text(message).font(.caption2).foregroundStyle(theme.tokens.failure).lineLimit(3)
      }
      ForEach(model.forwards) { forward in
        row(forward)
      }
      if adding { newRow }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    // Keyed by host: the section is the same view across workrooms, and each host's model is
    // watched from the first time it is shown.
    .task(id: model.host) { model.watch() }
  }

  /// The row `+` adds: a focused port field. Return forwards it, and the row goes once it is a
  /// forward; a refused port keeps it, with the model's message saying why. Escape, or leaving it
  /// empty, drops it.
  private var newRow: some View {
    // `.plain`, as every field embedded in a bar or panel here is; `.roundedBorder` is the
    // sheets' style.
    TextField("New port number…", text: $model.draft)
      .textFieldStyle(.plain)
      .font(.system(.caption, design: .monospaced))
      .focused($fieldFocused)
      .onSubmit {
        Task {
          await model.add()
          // `add` consumes the draft only when the forward was made.
          if model.draft.isEmpty { adding = false }
        }
      }
      .onExitCommand { cancelAdding() }
      .onChange(of: fieldFocused) { _, focused in
        if !focused, model.draft.trimmingCharacters(in: .whitespaces).isEmpty { cancelAdding() }
      }
      .onAppear { fieldFocused = true }
      .accessibilityIdentifier("ports.field")
  }

  private func cancelAdding() {
    adding = false
    model.draft = ""
  }

  @ViewBuilder
  private func row(_ forward: PortForwardingModel.Entry) -> some View {
    // `localhost`, as the user types it: a forward is only given its own number when nothing holds
    // it on `::1` either (`PortForward.init`), so the browser reaches this listener.
    let address = "localhost:\(forward.localPort)"
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 6) {
        // Mac first, arrow the way a connection goes: from the address here into the container.
        Text("\(address) → container \(String(forward.remotePort))")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(theme.tokens.fgMuted)
          .textSelection(.enabled)
        if let label = forward.label {
          Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        InspectorHeaderButton(systemImage: "doc.on.doc", help: "Copy \(address)", compact: true) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(address, forType: .string)
        }
        InspectorHeaderButton(
          systemImage: "xmark", help: "Stop forwarding port \(String(forward.remotePort))",
          destructive: true
        ) {
          model.remove(forward.id)
        }
      }
      if let failure = forward.failure {
        Text(failure).font(.caption2).foregroundStyle(theme.tokens.failure).lineLimit(3)
      }
    }
    .accessibilityIdentifier("ports.row.\(forward.remotePort)")
  }
}
