import AppKit
import Defaults
import Foundation

/// A host's terminal-tab close: whether a close needs the confirm, the confirm itself, and the
/// teardown. Built from the host's own `TerminalPanes` and `RunCommandController` and nothing else,
/// so any window that hosts panes can own one; `AppStore` owns one as `closeFlow`.
@MainActor
final class TabCloseFlow {
  private let terminals: TerminalPanes
  private let runCommand: RunCommandController

  init(terminals: TerminalPanes, runCommand: RunCommandController) {
    self.terminals = terminals
    self.runCommand = runCommand
  }

  /// Set while a close-confirm alert is queued/showing, so a double fire (a fast second ⌘W, or
  /// toolbar/menu/context "Close all" pressed twice before the deferred alert appears) can't stack
  /// modals over a now-stale victim list. Per flow, so per host.
  private(set) var isPresentingCloseConfirm = false

  /// Test seam: pin whether a close prompts, per flow, instead of writing the shared
  /// `confirmOnCloseTerminal` setting. `nil` (production) reads the real setting.
  ///
  /// Close-behaviour tests need the confirm **off** (an AppKit modal isn't unit-testable), but the
  /// obvious way to get that — writing the `Defaults` key — is not test-local: `-parallel-testing`
  /// gives each worker its own host process and they all share ONE UserDefaults domain, so one class
  /// flipping the key lands inside another class's body and turns its close into a modal. That was a
  /// roughly 1-in-4 red suite whose victim moved between runs. This override is per flow, so it
  /// cannot leak across workers; `ConfirmOnCloseTerminalTests` still asserts on the real key, and is
  /// now its only writer.
  var confirmOnCloseOverride: Bool?

  /// Test seam: shows the confirm in place of the sheet (or the app-modal fallback), and hands back
  /// the `resolve` the sheet's completion would get. A test host has no window, so without it the
  /// confirm is a blocking `runModal()`. `nil` in production.
  var presentConfirmForTesting:
    ((NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?

  /// Close a terminal tab, confirming first when `confirmOnCloseTerminal` is on (the default). The
  /// tab-strip ✕ and the ⌘W command both route through here, so the confirmation — and its "Don't
  /// ask me again" suppression — lives in one place (`confirmCloseThen`). Closing a terminal kills
  /// its shell and anything running in it with no undo, so the alert mirrors the quit confirmation.
  func requestClose(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    // `tab(_:for:)`, not `tabs(for:)`: the latter is the DISPLAYED list, which since issue #172
    // excludes detached panes — so looking a tab up through it would silently no-op the close button
    // on a popped-out window.
    guard let tab = terminals.tab(tabID, for: target) else { return }
    guard closeNeedsConfirm([tab]) else {
      performClose([tabID], for: target)
      return
    }
    confirmCloseThen(count: 1, title: tab.title) { [weak self] in
      self?.performClose([tabID], for: target)
    }
  }

  /// Close every tab in `target` (the tab strip's "Close all" / File ▸ "Close All Tabs"), confirming
  /// once if any has a live process. No-op when the target has no tabs.
  func requestCloseAll(for target: TerminalTarget) {
    // `allTabs`, not `tabs`: "every tab" includes a pane that is currently in its own window.
    let victims = terminals.allTabs(for: target).map(\.id)
    guard !victims.isEmpty else { return }
    requestClose(victims, for: target, keep: nil)
  }

  /// Close every tab in `target` except `keepID` ("Close others"), confirming once if any victim has
  /// a live process. No-op when there's nothing else to close.
  func requestCloseOthers(keeping keepID: TerminalTab.ID, for target: TerminalTarget) {
    let victims = terminals.allTabs(for: target).map(\.id).filter { $0 != keepID }
    guard !victims.isEmpty else { return }
    requestClose(victims, for: target, keep: keepID)
  }

  /// Shared bulk-close core: confirm once (if needed), then `select` the kept tab so focus lands
  /// there, then tear the victims down. Selecting `keep` *before* closing means none of the victims
  /// is focused when it closes, so a victim's `closeTab` never fights the kept-tab selection — and a
  /// later async run-tab close (Ctrl-C + wait) can't steal focus back either (the run tab isn't
  /// focused). `keep == nil` for "Close all" (target ends empty).
  private func requestClose(
    _ victims: [TerminalTab.ID], for target: TerminalTarget, keep: TerminalTab.ID?
  ) {
    // `allTabs`: the confirm list must be able to see a detached victim, or a live process could be
    // killed without `closeNeedsConfirm` ever considering it.
    let tabs = terminals.allTabs(for: target).filter { victims.contains($0.id) }
    let proceed: () -> Void = { [weak self] in
      guard let self else { return }
      if let keep { self.terminals.select(keep, for: target) }
      self.performClose(victims, for: target)
    }
    if closeNeedsConfirm(tabs) {
      confirmCloseThen(count: victims.count, title: nil, then: proceed)
    } else {
      proceed()
    }
  }

  /// Whether closing `tabs` needs the confirm modal: the setting is on, we're not in a UI-test
  /// fixture (those close synchronously so teardown never blocks on an alert — the launch-arg
  /// override can't reliably reach a Defaults Bool), and at least one tab still has a live process
  /// to lose. A content/diff tab has no surface and an exited run tab has nothing running, so a
  /// `?? true` ("has exited") batch of only those never prompts (issue #7).
  private func closeNeedsConfirm(_ tabs: [TerminalTab]) -> Bool {
    #if DEBUG
      if AppEnvironment.current.isFixture { return false }
    #endif
    return Self.resolveConfirmOnClose(override: confirmOnCloseOverride)
      && tabs.contains { !(terminals.surface(of: $0.id)?.processHasExited ?? true) }
  }

  /// The override-or-setting half of `closeNeedsConfirm`, lifted out as a pure static so it can be
  /// pinned without a flow.
  ///
  /// It needs its own test because the seam above hid the setting: once every close-behaviour class
  /// injects `confirmOnCloseOverride`, NO test reaches the `Defaults` side any more, and changing
  /// this to `?? false` would leave the whole unit suite green while the shipped "Confirm before
  /// closing a terminal" checkbox silently stopped working. Pinning it here rather than through a
  /// flow is deliberate: `ConfirmOnCloseTerminalTests` is the only writer of the shared key, and
  /// keeping it that way is what makes the parallel workers safe (see the override's doc above).
  /// `nonisolated` because it touches no actor state — just its argument and a `Defaults` read — so
  /// the test above doesn't have to hop onto the main actor to ask what the setting resolves to.
  nonisolated static func resolveConfirmOnClose(override: Bool?) -> Bool {
    override ?? Defaults[.confirmOnCloseTerminal]
  }

  /// Tear down a set of tabs for a target. Each live run command is stopped gracefully (Ctrl-C +
  /// wait) before its surface is freed, so the dev server exits cleanly rather than being orphaned
  /// by the bare hangup (issue #7); non-run / exited / content tabs close immediately. UI-test
  /// fixture mode closes synchronously (teardown must not block). `closeTab` itself tears down each
  /// surface and closes any detached window, so this never orphans a window or leaks a PTY. Skips
  /// the confirm: a caller that reaches it directly has already confirmed (`closeWorkroom`).
  func performClose(_ tabIDs: [TerminalTab.ID], for target: TerminalTarget) {
    for id in tabIDs {
      #if DEBUG
        if AppEnvironment.current.isFixture {
          terminals.closeTab(id, for: target)
          continue
        }
      #endif
      runCommand.closingRunTab(id, for: target.id) { [weak self] in
        self?.terminals.closeTab(id, for: target)
      }
    }
  }

  /// Confirm closing `count` tab(s), then run `proceed` on confirm. Owns the modal: a window-modal
  /// sheet attached to the key window, the "Don't ask me again" suppression (writes the same
  /// `confirmOnCloseTerminal` key the Settings checkbox and File-menu toggle bind to), and
  /// singular/plural copy. Says "tab(s)", not "terminal", because diff/content tabs close through
  /// here too. Callers decide *whether* a confirm is needed (`closeNeedsConfirm`) — it can't be
  /// inferred from `count`. Guarded against reentrant double fire.
  ///
  /// A *sheet* (not a free-floating `runModal()` alert) is what makes the confirming Return reliable:
  /// the sheet is hosted by a window that's already key, so its default "Close" button owns Return
  /// with no race. The old app-modal alert had to *become* key after `runModal()` spun up, which lost
  /// the keystroke whenever the triggering event (the ⌘W key-equivalent / the ✕'s mouse tracking) was
  /// still draining; deferring the alert one runloop tick narrowed that window but couldn't close it,
  /// so Return was still dropped intermittently (issues #54, #100). We still defer one tick so the
  /// triggering event unwinds before the sheet drops, then fall back to an app-modal alert only when
  /// there's no window to host the sheet.
  private func confirmCloseThen(count: Int, title: String?, then proceed: @escaping () -> Void) {
    guard !isPresentingCloseConfirm else { return }
    isPresentingCloseConfirm = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let alert = NSAlert()
      alert.messageText =
        count == 1 ? "Close ‘\(title ?? "this tab")’?" : "Close \(count) tabs?"
      alert.informativeText =
        count == 1
        ? "Closing this tab stops any process running in it."
        : "Closing these tabs stops any processes running in them."
      alert.addButton(withTitle: "Close")
      alert.addButton(withTitle: "Cancel")
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = "Don't ask me again"
      // Shared resolution for both the sheet and the no-window fallback: clear the reentrancy guard,
      // honour "Don't ask me again", and proceed only on the default Close button.
      let resolve: (NSApplication.ModalResponse) -> Void = { [weak self] response in
        guard let self else { return }
        self.isPresentingCloseConfirm = false
        if alert.suppressionButton?.state == .on {
          Defaults[.confirmOnCloseTerminal] = false
        }
        if response == .alertFirstButtonReturn { proceed() }
      }
      if let presentConfirmForTesting {
        presentConfirmForTesting(alert, resolve)
      } else if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        alert.beginSheetModal(for: window, completionHandler: resolve)
      } else {
        resolve(alert.runModal())
      }
    }
  }
}
