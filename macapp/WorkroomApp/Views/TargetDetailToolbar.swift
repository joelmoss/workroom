import AppKit
import Defaults
import SwiftUI

/// Icon metrics for the workroom pane header's action group (issue #139). One place, because "every
/// button and every icon the same size" is only enforceable if the numbers aren't scattered across
/// three files. The wells themselves are uniform already — every control here wears
/// `ToolbarIconButtonStyle`, so each gets the same 22pt square.
enum PaneToolbarIcon {
  /// Point size for every SF Symbol in the group — run/stop/restart, the chevron, the ✕. Set on the
  /// group so each glyph inherits it; matches the ambient size these buttons had in the window title
  /// bar, so moving them into the header didn't resize them.
  static let glyph: CGFloat = 13

  /// Side of the app-icon bitmap in "Open in…". **Deliberately larger than `glyph`.** A macOS app icon
  /// is drawn with transparent margin around its artwork (roughly a fifth of the canvas), so rendered at
  /// the symbols' point size it reads visibly smaller than they do. This is the size at which it *looks*
  /// like its neighbours, and looking equal is the only equal a user can see. Equal numbers here would be
  /// the wrong kind of consistency.
  ///
  /// **Headroom, since this is the number most likely to be retuned:**
  /// - **22pt** is the practical ceiling. `ToolbarIconButtonStyle`'s 22pt well is a `minWidth`/`minHeight`,
  ///   not a cap, so a label larger than that grows its own well — and the run buttons' wells stay 22pt,
  ///   so this button would become visibly taller than its neighbours.
  /// - **24pt** still fits `WorkroomPaneTitleBar`'s 28pt row with 2pt of clearance; 26pt leaves 1pt; past
  ///   28pt the row clips or has to grow.
  /// - `EditorCache` rasterizes the icon at 20pt nominal, so going much beyond that also wants that render
  ///   size raised to match.
  /// - For *exact optical parity* with the 13pt symbols the number is ~16-17pt (13 ÷ 0.8, the artwork's
  ///   usable fraction). 18pt sits just past parity, chosen by eye against a real editor icon.
  static let appIcon: CGFloat = 18

  /// The "Open in…" disclosure chevron. Deliberately **smaller** than `glyph`, and the one glyph here
  /// that isn't sized with the rest: it's not an action icon but a hint that the button beside it has a
  /// menu behind it. Sized up to match the group once, and at 13pt it competed with the very icons it
  /// annotates. `OpenInControl`'s -8pt well overlap is tuned against this size.
  static let disclosure: CGFloat = 8
}

/// The "Open in…" editor control for a workroom: a menu whose primary action reopens in the
/// last-picked editor. A plain `View` (not `ToolbarContent`) so it composes into its host bar as a
/// sibling of the other controls, sharing its `.borderless` button style. (Renders nothing when no
/// editors are installed.)
///
/// Hosted in the **workroom pane title bar** (`WorkroomPaneTitleBar`) since issue #139 — it used to
/// sit in the window title bar keyed on the *selected* target, which left a co-displayed split
/// member's path unreachable. Now each visible workroom carries its own.
struct OpenInControl: View {
  let path: String

  /// Bundle id of the last editor picked from the "Open in…" menu — the primary action reopens in it.
  @Default(.lastEditor) private var lastEditorID

  var body: some View {
    let editors = ExternalEditor.installed
    if !editors.isEmpty {
      let remembered = editors.first { $0.id == lastEditorID } ?? editors[0]
      // Two SEPARATE controls in one tight group: an icon Button that opens in the remembered editor
      // on a single click (also ⇧⌘O / the Go-menu item), and a chevron Menu to pick a different one.
      // Both inherit the bar's `ToolbarIconButtonStyle`, so each gets its own hover well. Negative
      // spacing pulls the two 22pt-min wells together so the small chevron sits snug against the icon
      // (each well only paints on its own hover, so the slight overlap never shows two at once).
      HStack(spacing: -8) {
        Button {
          remembered.open(path)
        } label: {
          // Sized DIRECTLY, not by overlaying a hidden SF Symbol. That trick — a `.hidden()`
          // `arrow.up.forward.app` with the real icon in an `.overlay`, wrapped in a `.frame` — silently
          // ignored the frame: an overlay takes the size of the view it is attached to, and a bare Image
          // is fixed-size, so the icon rendered at whatever the ambient FONT made the hidden symbol
          // (~13pt) and the frame merely centred it in a larger box. Every attempt to resize it did
          // nothing. `.resizable().scaledToFit()` then a `.frame` sizes the icon itself.
          // `PaneToolbarIcon.appIcon`, not `.glyph` — see there for why the bitmap needs a bigger box
          // than the symbols to read the same size as them.
          Image(nsImage: remembered.icon)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: PaneToolbarIcon.appIcon, height: PaneToolbarIcon.appIcon)
        }
        .help("Open in \(remembered.name) (⇧⌘O)")
        .accessibilityLabel("Open in \(remembered.name)")
        // A stable id beside the (editor-dependent) label, so a test can find this button without
        // knowing which editors the machine has installed — the reason it had no coverage before.
        .accessibilityIdentifier("openIn.primary")

        Menu {
          ForEach(editors) { editor in
            Button {
              lastEditorID = editor.id
              editor.open(path)
            } label: {
              Label {
                Text(editor.name)
              } icon: {
                Image(nsImage: editor.icon).renderingMode(.original)
              }
            }
          }
        } label: {
          Image(systemName: "chevron.down")
            .font(.system(size: PaneToolbarIcon.disclosure, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        // We draw the chevron ourselves, so hide the system disclosure indicator.
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open in… (choose editor)")
        .accessibilityLabel("Choose editor")
        .accessibilityIdentifier("openIn.menu")
      }
    }
  }
}

/// The run-command controls for one workroom (issue #7): a Run button that becomes Restart + Stop
/// while the command is running. Reads run-state straight off `AppStore` — `@EnvironmentObject`
/// re-evaluates on `@Published` changes, so the toggle flips live (OV-A). A plain `View` (not
/// `ToolbarContent`) so it composes into its host bar.
///
/// Hosted in the **workroom pane title bar** since issue #139, one per visible workroom, and it acts
/// on `target` rather than the selection — `store.runOrFocusRunCommand(for:)` is the per-target door
/// precisely so pressing Run on a co-displayed split member can't start the run in the *selected*
/// workroom instead.
///
/// Note on the same workroom open in two windows: each window has its own `runStates`, so window B
/// can show Run while A shows Stop. That is pre-existing and is resolved at *press* time, not render
/// time — `runOrFocusRunCommand(for:)`'s `.armed/.none` branch finds the owning window
/// (`WindowRegistry.runOwner`) and focuses its run terminal instead of forking a second server.
/// Rendering a distinct "focus the owner" button here would need cross-store observation the app
/// doesn't have, so it would go stale rather than help.
struct RunControls: View {
  let target: TerminalTarget
  /// The owning project's path — used to look up the configured command (`hasRunCommand`).
  let projectPath: String
  @EnvironmentObject var store: AppStore

  /// Gap between Restart and Stop. Tighter than the 6pt the header puts between its controls, because
  /// these two are one pair rather than two neighbours — the same reason "Open in…" tucks its chevron
  /// against its icon. Each well already carries 3pt of its own padding, so the glyphs sit 8pt apart.
  private static let pairSpacing: CGFloat = 2

  /// Width held constant across run states: two wells plus the pair's gap. Without this the group is 1
  /// button wide idle and 2 wide running, and that swing shifts everything to its right AND eats into the
  /// pane title bar's identity label — so the workroom's name would re-truncate the moment a run started
  /// (issue #139). Same reasoning as `WorkroomTabBar`'s opacity-toggled divider: keep the layout, change
  /// the paint. Derived from the style and the spacing rather than restating either, so retuning one
  /// can't leave a gap.
  static let reservedWidth: CGFloat = ToolbarIconButtonStyle.footprint * 2 + pairSpacing

  var body: some View {
    // No `canRunCommand` gate: the header's Run button is shown for any present target, even one whose
    // project has no run command configured (issue #139 follow-up). Pressing it then opens Project
    // Settings with the warning banner — `runOrFocusRunCommand(for:)` has done that since issue #127, it
    // was just unreachable by click while the button hid itself. A button that teaches you how to
    // configure a run command beats no button at all. (The sidebar's per-row button still hides: a list
    // of many workrooms each offering a settings shortcut would be noise.)
    if !target.isMissing {
      let running = store.isRunCommandRunning(for: target.id)
      // Stop deliberately TRAILS Restart (it used to lead), and the idle Run is trailing-aligned in the
      // reserved box, so Stop lands exactly where Run was: the primary toggle keeps its position under
      // the cursor across a press, and Restart appears in the space that was already reserved for it
      // rather than pushing anything sideways. The idle gap therefore sits on the group's LEADING edge,
      // reading as breathing room after the workroom's name.
      HStack(spacing: Self.pairSpacing) {
        if running {
          Button {
            store.restartRunCommand(for: target)
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .help("Restart the run command (⌥⌘R)")
          .accessibilityLabel("Restart")
          .accessibilityIdentifier("runCommand.restart")

          Button {
            store.stopRunCommand(for: target)
          } label: {
            Image(systemName: "stop.fill")
          }
          .help("Stop the run command (⇧⌘R) — again to force-quit")
          .accessibilityLabel("Stop")
          .accessibilityIdentifier("runCommand.stop")
        } else {
          // Not running (no run tab, or stopped-but-open). The per-target door starts it, re-runs a
          // stopped pane, or focuses an existing one (OV-B) — always in THIS workroom. With nothing
          // configured it opens Project Settings instead, so say so rather than promising a run that
          // won't happen.
          Button {
            store.runOrFocusRunCommand(for: target)
          } label: {
            Image(systemName: "play.fill")
          }
          .help(
            store.hasRunCommand(forProject: projectPath)
              ? "Run the project command (⌘R)"
              : "No run command configured — set one in Project Settings (⌘R)"
          )
          .accessibilityLabel("Run")
          .accessibilityIdentifier("runCommand.run")
        }
      }
      .frame(width: Self.reservedWidth, alignment: .trailing)
    }
  }
}
