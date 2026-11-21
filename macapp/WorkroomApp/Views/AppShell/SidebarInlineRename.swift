import SwiftUI
import WorkroomDomain

/// Which Terminals-section row of one window is asked to show its inline name field, by Rename…
/// on something other than the row: its title-bar tab (#652). A row asks to be told while it is
/// drawn, so a row that isn't (a folded section, a row scrolled out of the List) leaves the
/// caller to show the rename sheet instead.
@MainActor
@Observable
final class SidebarInlineRename {
  /// The row asked to begin, until it does.
  private(set) var pending: SidebarID?
  /// How many times each row is drawn now: a row's view can appear again before the old one goes.
  @ObservationIgnored private var drawn: [SidebarID: Int] = [:]

  func rowAppeared(_ sid: SidebarID) { drawn[sid, default: 0] += 1 }

  func rowDisappeared(_ sid: SidebarID) {
    let count = (drawn[sid] ?? 1) - 1
    drawn[sid] = count > 0 ? count : nil
    if count <= 0, pending == sid { pending = nil }
  }

  func isDrawn(_ sid: SidebarID) -> Bool { drawn[sid] != nil }

  /// Asks `sid`'s row to begin renaming. False, asking nothing, when the row isn't drawn.
  func begin(_ sid: SidebarID) -> Bool {
    guard isDrawn(sid) else { return false }
    pending = sid
    return true
  }

  /// The row `sid` takes the ask: true once, when it was asked.
  func claim(_ sid: SidebarID) -> Bool {
    guard pending == sid else { return false }
    pending = nil
    return true
  }
}

extension View {
  /// Lets `renames` ask this row, `sid`'s, to begin renaming, which calls `begin`.
  func sidebarInlineRename(
    _ sid: SidebarID, in renames: SidebarInlineRename, begin: @escaping () -> Void
  ) -> some View {
    modifier(SidebarInlineRenameTrigger(sid: sid, renames: renames, begin: begin))
  }
}

private struct SidebarInlineRenameTrigger: ViewModifier {
  let sid: SidebarID
  let renames: SidebarInlineRename
  let begin: () -> Void

  func body(content: Content) -> some View {
    content
      .onAppear { renames.rowAppeared(sid) }
      .onDisappear { renames.rowDisappeared(sid) }
      .onChange(of: renames.pending == sid, initial: true) { _, asked in
        if asked, renames.claim(sid) { begin() }
      }
  }
}

/// A sidebar row's name, edited in place by Rename…: Return or clicking away keeps the draft,
/// Escape drops it. Shared by the terminal group's row and the terminals' rows, so they rename
/// alike. An empty name is the caller's to read (it gives the default back).
struct SidebarInlineNameField: View {
  let placeholder: String
  @Binding var draft: String
  let help: String
  let id: String
  var font: Font = .callout
  let commit: () -> Void
  let cancel: () -> Void

  /// Whether the field has had the keys yet: only losing them after that commits the name.
  @State private var hadFocus = false
  /// Committed or cancelled, so losing the keys as the field goes commits nothing more.
  @State private var done = false
  @FocusState private var focused: Bool

  var body: some View {
    TextField(placeholder, text: $draft)
      .textFieldStyle(.plain)
      .font(font)
      .focused($focused)
      .onSubmit { finish(commit) }
      .onExitCommand { finish(cancel) }
      .onAppear { DispatchQueue.main.async { focused = true } }
      .onChange(of: focused) { _, isFocused in
        if isFocused {
          hadFocus = true
        } else if hadFocus {
          finish(commit)
        }
      }
      .help(help)
      .accessibilityIdentifier(id)
  }

  private func finish(_ action: () -> Void) {
    guard !done else { return }
    done = true
    action()
  }
}
