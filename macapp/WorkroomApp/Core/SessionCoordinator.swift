import AppKit
import Foundation
import OSLog

/// Decides *when* the saved session is written (issue #46). `SessionStore` owns the file;
/// `AppStore+Session` owns what one window contributes; this owns coalescing, the restore gate, and
/// the quit freeze.
///
/// There is exactly one writer, and it rebuilds the whole document from every live window. That
/// replaces `AppStore.persistsSidebarPrefs` arbitration *for the session only*: that gate exists
/// because a single `Defaults` key cannot hold N windows — this file can. `persistsSidebarPrefs`
/// still governs the Defaults keys it always did.
@MainActor
final class SessionCoordinator {
  static let shared = SessionCoordinator(store: .forCurrentEnvironment())

  /// Coalescing window. Long enough that a burst of layout edits costs one write.
  static let defaultDebounce: TimeInterval = 1
  /// **The ceiling is not an optimisation — it is what makes saving work at all.**
  ///
  /// The dirty sources publish faster than 1 Hz whenever a terminal is doing anything:
  /// `TerminalSessions.pulsePaneActivity` bumps a `@Published` dict per activity report, and every
  /// live-title/cwd/progress update reassigns `tabsByTarget` (`TerminalTab` is a value type). A plain
  /// cancel-and-replace debounce therefore has its deadline pushed out forever while output streams,
  /// and **never fires** — so splitting a pane beside a running dev server would never be saved.
  ///
  /// Recording when the session FIRST went dirty and forcing a write once this much time has passed
  /// bounds the loss regardless of how chatty the terminals are.
  static let defaultCeiling: TimeInterval = 5

  private let store: SessionStore
  private let debounce: TimeInterval
  private let ceiling: TimeInterval
  private let capture: () -> [WindowSession]
  private let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "session")

  private var pending: DispatchWorkItem?
  /// When the current dirty streak began — the ceiling is measured from here, not from the last edit.
  private var dirtySince: Date?
  /// The last document written, compared with `==` rather than a hash: Swift seeds `hashValue` per
  /// process, and a collision would silently suppress a write the user needs.
  private var lastWritten: [WindowSession]?
  /// Depth rather than a flag so nested suspensions (several windows restoring) cannot resume early.
  private var suspensions = 0
  private var dirtyWhileSuspended = false
  /// Set once the app is genuinely terminating. Windows close one by one during a quit, and the
  /// document is rebuilt from the LIVE windows — without this, the last window closing would
  /// overwrite a good session with an empty one after the flush already wrote it.
  private var isFrozen = false

  init(
    store: SessionStore = SessionStore(),
    debounce: TimeInterval = SessionCoordinator.defaultDebounce,
    ceiling: TimeInterval = SessionCoordinator.defaultCeiling,
    capture: (() -> [WindowSession])? = nil
  ) {
    self.store = store
    self.debounce = debounce
    self.ceiling = ceiling
    self.capture = capture ?? { WindowRegistry.shared.captureSessionWindows() }
  }

  /// Exposed so a caller can tell "no session" from "a session this build must not touch".
  var writesDisabled: Bool { store.writesDisabled }

  // MARK: Restore gate

  /// True while a restore is in flight, so nothing writes a half-restored document.
  var isSuspended: Bool { suspensions > 0 }

  /// Stop writing until the matching `resumeSaves()`.
  ///
  /// **This is the gate that stops the launch window deleting the others.** Restoring window 1
  /// mutates `TerminalSessions` and `AppStore`, which marks the session dirty. If that write landed
  /// before the sibling windows had opened and registered, the document would be rebuilt from the one
  /// live window and overwrite the file — silently discarding windows 2 and 3 on the very launch that
  /// was meant to bring them back.
  func suspendSaves() {
    suspensions += 1
    pending?.cancel()
    pending = nil
  }

  func resumeSaves() {
    guard suspensions > 0 else { return }
    suspensions -= 1
    guard suspensions == 0, dirtyWhileSuspended else { return }
    dirtyWhileSuspended = false
    markDirty()
  }

  // MARK: Dirty tracking

  /// The session changed. Safe to call at any rate — this is called from publishers that fire many
  /// times a second.
  func markDirty() {
    guard !isFrozen, !store.writesDisabled else { return }
    guard !isSuspended else {
      dirtyWhileSuspended = true
      return
    }

    let now = Date()
    let start = dirtySince ?? now
    dirtySince = start

    // Past the ceiling, write now rather than pushing the deadline out again.
    if now.timeIntervalSince(start) >= ceiling {
      writeIfChanged()
      return
    }

    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.writeIfChanged() }
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
  }

  /// Capture and persist immediately if anything actually changed. Also the ceiling's landing point.
  func writeIfChanged() {
    pending?.cancel()
    pending = nil
    dirtySince = nil
    guard !isFrozen, !store.writesDisabled, !isSuspended else { return }

    let windows = capture()
    guard windows != lastWritten else { return }
    lastWritten = windows
    store.write(makeFile(windows))
  }

  // MARK: Quit

  /// Capture and write **synchronously**, then stop writing for the rest of the process.
  ///
  /// Called past the quit confirmation — never above it. A cancelled ⌘Q must leave saving fully
  /// working, so this cannot run anywhere a user can still say "no".
  func flushAndFreeze() {
    guard !isFrozen else { return }
    pending?.cancel()
    pending = nil
    dirtySince = nil
    // Suspended means a restore never finished; the live windows are not the user's session, so
    // writing them now would replace a good file with a partial one.
    if !store.writesDisabled && !isSuspended {
      let windows = capture()
      lastWritten = windows
      store.writeSynchronously(makeFile(windows))
    }
    isFrozen = true
  }

  // MARK: Read

  func read() -> SessionStore.ReadOutcome { store.read() }

  private func makeFile(_ windows: [WindowSession]) -> SessionFile {
    SessionFile(
      savedAt: Date(),
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      windows: windows)
  }
}

extension WindowRegistry {
  /// Every live window's contribution to the saved session, in a stable order so an unchanged layout
  /// produces an unchanged document (and therefore no write).
  func captureSessionWindows() -> [WindowSession] {
    allStores
      .sorted { $0.windowNumber < $1.windowNumber }
      .map { $0.captureWindowSession() }
  }
}
