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
  /// Writes each live pane's scrollback into the store (issue #144). Separate from `capture` because
  /// it runs ONLY at quit: reading every pane's history is far too heavy for a coalesced save.
  private let captureScrollback: (SessionStore) -> Void
  private let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "session")

  private var pending: DispatchWorkItem?
  /// When the current dirty streak began — the ceiling is measured from here, not from the last edit.
  private var dirtySince: Date?
  /// The last document written, compared with `==` rather than a hash: Swift seeds `hashValue` per
  /// process, and a collision would silently suppress a write the user needs.
  private var lastWritten: [WindowSession]?
  /// What the last **successful** write persisted, or nil when nothing has landed yet. Exposed so a
  /// test can assert that a failed write is not latched as written.
  var lastWrittenWindows: [WindowSession]? { lastWritten }
  /// Depth rather than a flag so nested suspensions (several windows restoring) cannot resume early.
  private var suspensions = 0
  private var dirtyWhileSuspended = false
  /// Set once the app is genuinely terminating. Windows close one by one during a quit, and the
  /// document is rebuilt from the LIVE windows — without this, the last window closing would
  /// overwrite a good session with an empty one after the flush already wrote it.
  private(set) var isFrozen = false

  init(
    store: SessionStore = SessionStore(),
    debounce: TimeInterval = SessionCoordinator.defaultDebounce,
    ceiling: TimeInterval = SessionCoordinator.defaultCeiling,
    capture: (() -> [WindowSession])? = nil,
    captureScrollback: ((SessionStore) -> Void)? = nil
  ) {
    self.store = store
    self.debounce = debounce
    self.ceiling = ceiling
    self.capture = capture ?? { WindowRegistry.shared.captureSessionWindows() }
    self.captureScrollback =
      captureScrollback ?? { store in
        for appStore in WindowRegistry.shared.allStores { appStore.captureScrollback(into: store) }
      }
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

    // Past the ceiling, write on the next turn rather than pushing the deadline out again.
    //
    // Scheduled at zero delay rather than called inline, because the loudest dirty source is
    // `terminals.objectWillChange`, which fires BEFORE the mutation lands: capturing inline would
    // snapshot the state the change was about to replace. Zero delay keeps the ceiling's guarantee
    // (this run loop turn) while letting the mutation complete first.
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.writeIfChanged() }
    }
    pending = work
    let delay = now.timeIntervalSince(start) >= ceiling ? 0 : debounce
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
    // `lastWritten` is the gate that drops an unchanged save, so a write that FAILED must not be
    // remembered as written: after a disk-full or permissions blip, every later attempt at the same
    // state would be suppressed and the user's layout would silently stop being saved until they
    // changed something else. Clearing it on failure makes the next dirty mark retry.
    store.write(makeFile(windows)) { [weak self] didWrite in
      guard let self, !didWrite, self.lastWritten == windows else { return }
      self.lastWritten = nil
    }
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
      // Scrollback is captured HERE and nowhere else (issue #144): quitting is the one moment worth
      // reading every pane's history for. Prune afterwards, unconditionally, so a pane that captured
      // nothing this time loses its old sidecar rather than restoring yesterday's output.
      captureScrollback(store)
      store.pruneScrollback(keeping: Self.tabKeys(in: windows))
    }
    isFrozen = true
  }

  /// Stop writing for the rest of the run **without** writing anything.
  ///
  /// The abandoned-restore path. If a window claimed a saved session and never restored it — a `list`
  /// that threw, a scene SwiftUI declined to create — then the live windows are NOT the user's
  /// session, and resuming saves would rebuild the document from those empty windows and overwrite a
  /// perfectly good file. Freezing instead preserves it, so the next launch can still restore.
  ///
  /// This costs the current run's layout changes, which is the right trade: the file on disk is real
  /// work the user did, and what would replace it is the wreckage of a failed launch.
  func freezeWithoutWriting() {
    guard !isFrozen else { return }
    pending?.cancel()
    pending = nil
    dirtySince = nil
    isFrozen = true
    logger.notice("session restore did not complete — writes frozen to preserve the saved session")
  }

  // MARK: Read

  func read() -> SessionStore.ReadOutcome { store.read() }

  /// A restored pane's saved text, for replay (issue #144).
  func scrollback(forTabKey key: String) -> String? { store.readScrollback(forTabKey: key) }

  /// Every tab key in the document, which is exactly the set of sidecars worth keeping.
  private static func tabKeys(in windows: [WindowSession]) -> Set<String> {
    Set(windows.flatMap { $0.targets.flatMap { $0.tabs.map(\.key) } })
  }

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
