import AppKit
import Foundation
import GhosttyKit
import os

/// Receives libghostty's runtime callbacks (`action_cb`, clipboard, `close_surface_cb`) and routes
/// them into Workroom. Each surface registers its `GhosttySurfaceView` as the surface `userdata`, so
/// callbacks resolve back to the originating view via `ghostty_surface_userdata`.
///
/// Threading: `action_cb`, the clipboard callbacks, and `close_surface_cb` all fire synchronously
/// on the MAIN thread — either while libghostty is driven by `ghostty_app_tick`, or directly inside
/// one of our own `ghostty_surface_*` calls — so it's always safe to touch AppKit/
/// `GhosttySurfaceView` directly here. (`wakeup_cb`, which can fire off-thread, only schedules a
/// tick and lives on `GhosttyApp`.)
///
/// What is NOT uniformly safe is calling BACK into the engine from a handler. An action delivered
/// on a `ghostty_surface_*` stack can be holding the renderer mutex, which is not recursive, so an
/// engine read from that stack deadlocks the main thread. `GHOSTTY_ACTION_SELECTION_CHANGED` is the
/// known case (see its comment below); assume any new action may be one until checked against
/// ghostty's source, and defer engine reads with `DispatchQueue.main.async` when in doubt.
final class GhosttyRuntimeAdapter {
  static let shared = GhosttyRuntimeAdapter()

  private let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "GhosttyRuntime")

  /// Guards against an OSC 52 flood stacking alerts — see `confirmClipboard`. Main-thread only.
  private var isPresentingClipboardConfirmation = false

  // MARK: Action dispatch

  nonisolated func handleAction(
    app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s
  ) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_PWD:
      guard let view = surfaceView(from: target), let pwd = action.action.pwd.pwd else {
        return false
      }
      view.handlePwd(String(cString: pwd))
      return true

    case GHOSTTY_ACTION_SET_TITLE:
      // OSC 0/2 — the running command's name while a command is busy (via shell-integration
      // preexec), or the directory the shell sets at each prompt. The tab strip keeps the command
      // and ignores the directory titles (issue #2).
      guard let view = surfaceView(from: target), let title = action.action.set_title.title else {
        return false
      }
      view.handleTitleChange(String(cString: title))
      return true

    case GHOSTTY_ACTION_COMMAND_FINISHED:
      // The shell returned to the prompt (OSC 133 D). The payload carries the command's exit code
      // (`ghostty_action_command_finished_s`, -1 when the shell omitted a status). The tab strip
      // drops the finished command's title (issue #2); the inline agent reads the exit code (#49).
      guard let view = surfaceView(from: target) else { return false }
      view.handleCommandFinished(rawExitCode: action.action.command_finished.exit_code)
      return true

    case GHOSTTY_ACTION_PROGRESS_REPORT:
      // OSC 9;4 — a running program's own busy/idle signal (claude, dev servers, build tools emit it).
      // REMOVE means "idle/done"; every other state (SET/INDETERMINATE/PAUSE/ERROR) means "working".
      // The tab strip trusts this over the command title so a long-lived foreground program stops
      // spinning the sidebar the moment it's idle (issue #28 follow-up).
      guard let view = surfaceView(from: target) else { return false }
      let working = action.action.progress_report.state != GHOSTTY_PROGRESS_STATE_REMOVE
      view.handleProgressReport(working)
      return true

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      guard let view = surfaceView(from: target) else { return false }
      let note = action.action.desktop_notification
      let title = note.title.map { String(cString: $0) } ?? ""
      let body = note.body.map { String(cString: $0) }
      view.onActivity?(Self.terminalActivity(title: title, body: body))
      return true

    case GHOSTTY_ACTION_OPEN_URL:
      return handleOpenURL(target: target, openURL: action.action.open_url)

    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
      guard let view = surfaceView(from: target) else { return false }
      let link = action.action.mouse_over_link
      view.hasOSC8LinkUnderCursor = link.len > 0 && link.url != nil
      return true

    case GHOSTTY_ACTION_SCROLLBAR:
      // libghostty draws no scrollbar of its own — it reports the scroll geometry (rows) and lets the
      // host render one. We show a fading overlay indicator (plan: restore SwiftTerm's scrollbar).
      guard let view = surfaceView(from: target) else { return false }
      let bar = action.action.scrollbar
      view.updateScrollbar(total: bar.total, offset: bar.offset, len: bar.len)
      return true

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      // The surface's child process exited. The run terminal (issue #7) uses this to flip run-state
      // back to "Run" while keeping the pane open (`wait_after_command`). We RETURN FALSE so
      // libghostty's default still applies for ordinary tabs (which don't wire `onChildExited`) —
      // their behaviour is unchanged. Only run tabs observe it.
      guard let view = surfaceView(from: target) else { return false }
      view.handleChildExited(exitCode: action.action.child_exited.exit_code)
      return false

    case GHOSTTY_ACTION_START_SEARCH:
      // Scrollback find (⌘F). libghostty opens its search and asks the host to show the find UI; the
      // needle is non-empty when search starts from a selection (`search_selection`), else empty.
      guard let view = surfaceView(from: target) else { return false }
      let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
      view.applySearchEvent(.start(needle: needle))
      return true

    case GHOSTTY_ACTION_END_SEARCH:
      guard let view = surfaceView(from: target) else { return false }
      view.applySearchEvent(.end)
      return true

    case GHOSTTY_ACTION_SEARCH_TOTAL:
      // Total matches in the scrollback for the current needle — drives the bar's "/ N" count.
      guard let view = surfaceView(from: target) else { return false }
      view.applySearchEvent(.total(Int(action.action.search_total.total)))
      return true

    case GHOSTTY_ACTION_SEARCH_SELECTED:
      // Index of the currently-highlighted match — drives the bar's "n /" count.
      guard let view = surfaceView(from: target) else { return false }
      view.applySearchEvent(.selected(Int(action.action.search_selected.selected)))
      return true

    case GHOSTTY_ACTION_SELECTION_CHANGED:
      // The engine's selection changed. A bare tag — the action union carries no payload. Replaces
      // the selection half of the VoiceOver accessibility poll
      // (`GhosttySurfaceView.pollAccessibilityContent`), which still owns the screen-content half:
      // there is no content-changed action to hang that one on.
      //
      // UNLIKE every other case here, this one usually does NOT arrive via `ghostty_app_tick`: it
      // fires synchronously inside our own `ghostty_surface_mouse_pos`/`_mouse_button`/`_key`
      // calls, from inside `Surface.setSelection`. (Drag-autoscroll is the exception — there
      // `selection_scroll_tick` reaches `setSelection` via `handleMessage`, which IS tick-drained.)
      // What matters is the same on BOTH paths: `setSelection` is documented as requiring the
      // renderer mutex, so this handler always runs WITH THAT MUTEX HELD and must not touch the
      // engine on this stack — the mutex isn't recursive, so a read here deadlocks the main
      // thread. See `handleSelectionChanged()`, which defers.
      guard let view = surfaceView(from: target) else { return false }
      view.handleSelectionChanged()
      return true

    case GHOSTTY_ACTION_RING_BELL:
      // libghostty delegates the bell to the host — it does NOT produce audio/flash itself, so
      // without this the bell would be silent. Ring the system bell. We intentionally do not record
      // it as a notification (plan C1: the bell is a content-free, high-frequency signal).
      NSSound.beep()
      return true

    default:
      // Tab/split/window intents and everything else are intentionally not handled. Workroom owns
      // its own tab model (plan A5) and (as with SwiftTerm) leaves a tab in place when its shell
      // exits; returning false lets libghostty fall back to its default. (Child-exit IS handled —
      // see `GHOSTTY_ACTION_SHOW_CHILD_EXITED` above, which also returns false, but only after
      // telling the run tab.)
      //
      // Logged in Debug because this arm is the one place an action can go missing in SILENCE. A
      // libghostty upgrade that renumbers the action enum, renames a tag, or routes an effect
      // through a new one shows up here as nothing at all: no crash, no failing test, just a title
      // that stops updating or a spinner that never stops. Swift cannot exhaustively switch a C
      // enum, so there is no compile-time equivalent — a log line is the whole signal.
      logUnhandled(action.tag)
      return false
    }
  }

  /// Tags already logged, so a routinely-unhandled action (the tab/split/window intents fire
  /// constantly) reports once instead of flooding the log. Debug-only, and `handleAction` is
  /// documented above as main-thread-only, so a plain `Set` needs no synchronisation.
  #if DEBUG
    private var loggedUnhandledTags: Set<UInt32> = []
  #endif

  private func logUnhandled(_ tag: ghostty_action_tag_e) {
    #if DEBUG
      guard loggedUnhandledTags.insert(tag.rawValue).inserted else { return }
      logger.debug("unhandled libghostty action tag \(tag.rawValue, privacy: .public)")
    #endif
  }

  private func handleOpenURL(target: ghostty_target_s, openURL: ghostty_action_open_url_s) -> Bool {
    guard let view = surfaceView(from: target), let urlPtr = openURL.url, openURL.len > 0 else {
      return false
    }
    let urlString = urlPtr.withMemoryRebound(to: UInt8.self, capacity: Int(openURL.len)) { raw in
      String(bytes: UnsafeBufferPointer(start: raw, count: Int(openURL.len)), encoding: .utf8)
    }
    guard let urlString, let url = URL(string: urlString) else { return false }
    return view.onOpenURL?(url) ?? false
  }

  /// Resolve the `GhosttySurfaceView` that owns the firing surface, via its registered `userdata`.
  private func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
    guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else {
      return nil
    }
    guard let userdata = ghostty_surface_userdata(surface) else { return nil }
    return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
  }

  // MARK: Clipboard

  /// The one representation we serve. The engine asks for the exact MIME types it wants and always
  /// requests text-like data as the canonical `text/plain`, so anything else is a type we cannot
  /// produce from `NSPasteboard.string(forType:)`.
  private static let servedClipboardMIME = "text/plain"

  /// Copy (write) — ⌘C, OSC 52 and kitty clipboard writes. Writes the first text payload to the
  /// general pasteboard.
  ///
  /// `confirm` is the engine's own policy signal: it is `clipboard-write == .ask`
  /// (`Surface.clipboardWrite`), so it is false for the ⌘C copy binding and, today, for OSC 52 too
  /// — we generate our own ghostty config (`GhosttyApp.writeThemeConfig`) and never set
  /// `clipboard-write`, so it keeps ghostty's `allow` default. Honoured anyway rather than dropped:
  /// it is the engine telling us a write needs the user's consent, and ignoring that would silently
  /// downgrade the policy the moment the config gains the key.
  nonisolated func writeClipboard(
    userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    count: Int,
    confirm: Bool
  ) {
    guard let content, count > 0 else { return }
    var text: String?
    for i in 0..<count {
      let entry = content[i]
      // Only forward text payloads: a binary mime (image/*, etc.) would be garbled, and breaking on
      // the first non-null entry would skip a later text/plain one.
      let isText = entry.mime.map { String(cString: $0).hasPrefix("text/") } ?? true
      guard isText, let data = entry.data else { continue }
      // `len` is authoritative — the payload is binary-safe and NOT necessarily null-terminated, so
      // `String(cString:)` would read past the end or truncate at an embedded NUL.
      text = String(decoding: UnsafeRawBufferPointer(start: data, count: entry.len), as: UTF8.self)
      break
    }
    guard let text, !text.isEmpty else { return }
    guard confirm else { return Self.setPasteboard(text) }
    confirmClipboard(
      kind: .write, preview: text, requester: nil, over: surfaceView(fromUserdata: userdata)
    ) { allowed in
      guard allowed else { return }
      Self.setPasteboard(text)
    }
  }

  private static func setPasteboard(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
  }

  /// Paste (read) — ⌘V, OSC 52 and kitty clipboard reads.
  ///
  /// The return value reports only facts about the pasteboard, not policy: `STARTED` promises that
  /// exactly one of `ghostty_surface_complete_clipboard_request` / `..._deny_clipboard_request` will
  /// eventually be called with this `state`; `UNAVAILABLE` means there is nothing servable to hand
  /// over; `UNSUPPORTED` means we cannot serve this request at all. The core decides what each
  /// non-started answer does — a paste binding, for instance, falls through to its default.
  nonisolated func readClipboard(
    userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    mimeCount: Int,
    wantsAvailable: Bool
  ) -> ghostty_clipboard_read_result_e {
    guard let userdata else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    guard let surface = view.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    guard Self.requestsServedMIME(mimes, count: mimeCount) else {
      return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
    }
    // Distinguishing "no text on the pasteboard" from "here is an empty string" matters: the former
    // must leave a paste binding free to fall through, which is what the old `bool` return could not
    // express (it always handed back "" and claimed success).
    guard let text = NSPasteboard.general.string(forType: .string) else {
      return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
    }
    // `confirmed: false` submits it to the engine's own `clipboard-read` policy, which is what
    // routes an OSC 52 read into `confirmReadClipboard` below.
    Self.completeClipboardRequest(surface: surface, text: text, state: state, confirmed: false)
    return GHOSTTY_CLIPBOARD_READ_STARTED
  }

  /// Whether the engine asked for a representation we can actually produce. An empty list means the
  /// caller expressed no preference, which we read as "text is fine".
  private static func requestsServedMIME(
    _ mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int
  ) -> Bool {
    guard let mimes, count > 0 else { return true }
    for i in 0..<count where mimes[i].map({ String(cString: $0) }) == servedClipboardMIME {
      return true
    }
    return false
  }

  /// Hand the engine one `text/plain` representation. `available` is left empty: it is the listing
  /// of every MIME type on the pasteboard, requested via `read_clipboard`'s trailing bool, and we
  /// serve exactly one type — reporting the pasteboard's full type list would disclose more about
  /// the user's clipboard than the single representation they are being asked to approve.
  ///
  /// `remember` is always false. The engine offers a "remember this decision" session grant
  /// (`can_remember` on the confirmation), but a persistent allow for a terminal program that asked
  /// once is a bigger promise than this prompt currently explains, so every request is asked afresh.
  private static func completeClipboardRequest(
    surface: ghostty_surface_t, text: String, state: UnsafeMutableRawPointer?, confirmed: Bool
  ) {
    servedClipboardMIME.withCString { mime in
      text.withCString { data in
        var content = ghostty_clipboard_content_s(
          mime: mime, data: data, len: text.utf8.count)
        withUnsafePointer(to: &content) { contents in
          var complete = ghostty_clipboard_complete_s(
            contents: contents, contents_len: 1,
            available: nil, available_len: 0,
            confirmed: confirmed, remember: false)
          ghostty_surface_complete_clipboard_request(surface, &complete, state)
        }
      }
    }
  }

  /// The engine could not complete a clipboard request without the user's consent, and is asking us
  /// to obtain it. Reached from `apprt.embedded.Surface.completeClipboardRequest` whenever the core
  /// returns `error.UnsafePaste` or `error.UnauthorizedPaste`, i.e. for BOTH:
  ///
  /// - `GHOSTTY_CLIPBOARD_REQUEST_PASTE` — paste protection (`clipboard-paste-protection`, default
  ///   on) flagged the pasteboard's contents as unsafe. In practice that is a multi-line paste into
  ///   a program with no bracketed-paste mode (`cat`, a raw `ssh` prompt), or any paste containing
  ///   a bracketed-paste terminator.
  /// - the OSC 52 / kitty read + write requests, when `clipboard-read` is `ask` (ghostty's default,
  ///   and therefore ours) or `clipboard-write` is.
  ///
  /// This used to be an empty stub, which was not the permissive pass-through it read as: with
  /// nothing completing the request, BOTH of those cases were silently dropped — the unsafe paste
  /// never landed and the OSC 52 read never got a reply.
  ///
  /// Every pointer here is borrowed for the duration of the call — the confirmation struct, its
  /// contents, and the requesting program's name — so everything the deferred prompt needs is copied
  /// out first. `state` is the exception by design: it is the engine's heap-allocated request, which
  /// `completeClipboardRequest` deliberately does NOT free on this route precisely so it survives
  /// until we answer.
  nonisolated func confirmReadClipboard(
    userdata: UnsafeMutableRawPointer?,
    confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
  ) {
    guard let confirm, let kind = ClipboardConfirmationKind(request) else { return }
    let payload = confirm.pointee
    var text = ""
    if let contents = payload.contents, payload.contents_len > 0, let data = contents[0].data {
      text = String(
        decoding: UnsafeRawBufferPointer(start: data, count: contents[0].len), as: UTF8.self)
    }
    // Not every protocol carries a requesting program's name; the prompt falls back to "an
    // application" when it doesn't.
    let requester = payload.name.map { String(cString: $0) }
    let view = surfaceView(fromUserdata: userdata)
    confirmClipboard(kind: kind, preview: text, requester: requester, over: view) {
      [weak view] allowed in
      // A surface that went away mid-prompt (its tab was closed) can neither complete nor deny, so
      // the engine's request allocation leaks. Nothing in the C API answers a request without a
      // surface, and it is one allocation per abandoned prompt.
      guard let surface = view?.surface else { return }
      guard allowed else { return ghostty_surface_deny_clipboard_request(surface, state) }
      Self.completeClipboardRequest(surface: surface, text: text, state: state, confirmed: true)
    }
  }

  /// Ask the user to authorize a clipboard request, then resolve on the main thread.
  ///
  /// Always defers: the clipboard callbacks can fire inside one of our own `ghostty_surface_*`
  /// calls with the renderer mutex held (the same hazard `GHOSTTY_ACTION_SELECTION_CHANGED`
  /// documents above), so running a modal — and calling back into the engine from its completion —
  /// on this stack risks deadlocking the main thread.
  ///
  /// One prompt at a time. A hostile program can emit OSC 52 in a loop, and without this a single
  /// escape-sequence flood would stack an unbounded pile of alerts over the terminal; the surplus
  /// requests are denied rather than queued.
  private nonisolated func confirmClipboard(
    kind: ClipboardConfirmationKind,
    preview: String,
    requester: String?,
    over view: GhosttySurfaceView?,
    then resolve: @escaping (Bool) -> Void
  ) {
    let copy = Self.clipboardConfirmation(for: kind, preview: preview, requester: requester)
    DispatchQueue.main.async { [weak self] in
      guard let self, !isPresentingClipboardConfirmation else { return resolve(false) }
      isPresentingClipboardConfirmation = true
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = copy.title
      alert.informativeText = copy.message
      alert.addButton(withTitle: copy.allowButton)
      alert.addButton(withTitle: copy.denyButton)
      // Take Return OFF the allow button. This sheet drops in front of someone who is TYPING, so
      // leaving allow as the default action means their next Return authorizes the very clipboard
      // access they were meant to judge. Escape denies instead — AppKit only wires Escape up
      // automatically for a button titled "Cancel", so "Deny" has to ask for it.
      alert.buttons[0].keyEquivalent = ""
      alert.buttons[1].keyEquivalent = "\u{1b}"
      let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
        self?.isPresentingClipboardConfirmation = false
        resolve(response == .alertFirstButtonReturn)
      }
      // Sheet it over the surface's own window so it is obvious WHICH terminal asked. The quick
      // terminal is a plain titled `NSWindow` (`QuickTerminalWindow`), so it sheets like any other;
      // only a surface with no window at all falls back to an app-modal alert.
      if let window = view?.window {
        alert.beginSheetModal(for: window, completionHandler: done)
      } else {
        done(alert.runModal())
      }
    }
  }

  /// The clipboard callbacks pass the surface's `userdata` rather than a `ghostty_target_s`, so
  /// they can't use `surfaceView(from:)`. Call this SYNCHRONOUSLY on the callback — the pointer is
  /// only guaranteed to name a live view for the duration of the call, so anything deferred must
  /// capture the resolved (weak) view, never the raw pointer.
  private func surfaceView(fromUserdata userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
    guard let userdata else { return nil }
    return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
  }

  // MARK: Close

  nonisolated func closeSurface(userdata: UnsafeMutableRawPointer?, needsConfirm: Bool) {
    // Workroom owns its tab lifecycle (plan A5): a surface/shell exiting leaves the tab in place (as
    // SwiftTerm did) until the user closes it, so libghostty's close request is intentionally ignored.
  }

  // MARK: Clipboard confirmation copy (pure, unit-tested)

  /// What the user is being asked to allow. Mirrors `ghostty_clipboard_request_e`, but as our own
  /// type so the copy below stays pure Swift and testable — `WorkroomAppTests` links the app module,
  /// not the GhosttyKit C module.
  ///
  /// Deliberately named for the ACT, not the protocol: OSC 52 and the kitty clipboard protocol ask
  /// the same two questions of the user, and a prompt that named the escape sequence would be
  /// telling them the one thing they cannot act on.
  enum ClipboardConfirmationKind {
    /// Pasting content the engine flagged as unsafe to send to the running program.
    case paste
    /// A program wants to be handed the clipboard's contents.
    case read
    /// A program wants to replace the clipboard's contents.
    case write
    /// A program wants the listing of what representations the clipboard holds. Discloses less than
    /// a read, but still discloses.
    case list

    /// nil for a request kind we don't recognise, which `confirmClipboard` treats as a denial — a
    /// libghostty upgrade that adds a kind must not silently start auto-allowing it.
    init?(_ request: ghostty_clipboard_request_e) {
      switch request {
      case GHOSTTY_CLIPBOARD_REQUEST_PASTE: self = .paste
      case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ: self = .read
      case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
        self = .write
      case GHOSTTY_CLIPBOARD_REQUEST_LIST: self = .list
      default: return nil
      }
    }
  }

  /// Longest clipboard preview shown in a confirmation alert. A pasteboard can hold megabytes, and
  /// an `NSAlert` grown to that height is unreadable and unclickable — the point of the preview is
  /// to let the user recognise the content, not to display all of it.
  static let clipboardPreviewLimit = 200

  /// Wording for a clipboard confirmation. Pure + side-effect-free so it is testable without a live
  /// terminal (same rationale as `terminalActivity` below).
  ///
  /// `requester` is the program name the protocol supplied, when it supplied one — naming who asked
  /// is most of what makes this prompt answerable, so it leads the message whenever it is present.
  static func clipboardConfirmation(
    for kind: ClipboardConfirmationKind, preview: String, requester: String? = nil
  ) -> (title: String, message: String, allowButton: String, denyButton: String) {
    let shown = truncatedClipboardPreview(preview)
    let who = requester.map { "“\($0)”" } ?? "An application running in this terminal"
    switch kind {
    case .paste:
      return (
        "Paste this text?",
        """
        It looks like it could run commands — multi-line text pasted into a program that doesn't \
        frame pastes is executed as soon as it arrives.

        \(shown)
        """,
        "Paste", "Cancel"
      )
    case .read:
      return (
        "Allow this terminal to read the clipboard?",
        """
        \(who) asked for the clipboard's contents. It would receive:

        \(shown)
        """,
        "Allow", "Deny"
      )
    case .write:
      return (
        "Allow this terminal to change the clipboard?",
        """
        \(who) asked to replace the clipboard's contents with:

        \(shown)
        """,
        "Allow", "Deny"
      )
    case .list:
      return (
        "Allow this terminal to inspect the clipboard?",
        """
        \(who) asked what kinds of content the clipboard holds. That does not hand over the \
        contents themselves, but it does reveal what you last copied the shape of.
        """,
        "Allow", "Deny"
      )
    }
  }

  /// Clamp a preview to `clipboardPreviewLimit` characters, marking that it was cut. Counts
  /// Characters (grapheme clusters), so a multi-byte or emoji-heavy clipboard can't slip past the
  /// limit or be cut mid-character.
  static func truncatedClipboardPreview(_ text: String) -> String {
    guard text.count > clipboardPreviewLimit else { return text }
    return String(text.prefix(clipboardPreviewLimit)) + "…"
  }

  // MARK: Notification mapping (T2 — pure, unit-tested)

  /// Map a libghostty desktop-notification (title, optional body) to Workroom's `TerminalActivity`.
  /// Pure + side-effect-free so it's testable without a live terminal (replaces the deleted
  /// `OSCParserTests` coverage). The title is kept verbatim — including empty: the UI shows no
  /// placeholder for a titleless notification (it leads with the body instead). Empty body → nil.
  static func terminalActivity(title: String, body: String?) -> TerminalActivity {
    let resolvedBody = (body?.isEmpty ?? true) ? nil : body
    return .osc(title: title, body: resolvedBody)
  }
}
