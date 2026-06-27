import AppKit
import Foundation
import GhosttyKit
import os

/// Receives libghostty's runtime callbacks (`action_cb`, clipboard, `close_surface_cb`) and routes
/// them into Workroom. Each surface registers its `GhosttySurfaceView` as the surface `userdata`, so
/// callbacks resolve back to the originating view via `ghostty_surface_userdata`.
///
/// Threading: `action_cb`, the clipboard callbacks, and `close_surface_cb` all fire synchronously
/// while libghostty is being driven by `ghostty_app_tick`, which `GhosttyApp` only ever runs on the
/// main thread — so it's safe to touch AppKit/`GhosttySurfaceView` directly here. (`wakeup_cb`, which
/// can fire off-thread, only schedules a tick and lives on `GhosttyApp`.)
final class GhosttyRuntimeAdapter {
  static let shared = GhosttyRuntimeAdapter()

  private let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "GhosttyRuntime")

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
      // The shell returned to the prompt (OSC 133 D) — clear the tab's command title back to the
      // default (issue #2).
      guard let view = surfaceView(from: target) else { return false }
      view.onCommandFinished?()
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

    case GHOSTTY_ACTION_RING_BELL:
      // libghostty delegates the bell to the host — it does NOT produce audio/flash itself, so
      // without this the bell would be silent. Ring the system bell. We intentionally do not record
      // it as a notification (plan C1: the bell is a content-free, high-frequency signal).
      NSSound.beep()
      return true

    default:
      // Tab/split/window intents, child-exit, and everything else are intentionally not handled.
      // Workroom owns its own tab model (plan A5) and (as with SwiftTerm) leaves a tab in place when
      // its shell exits; returning false lets libghostty fall back to its default.
      return false
    }
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

  /// Copy (write) — ⌘C and OSC 52 writes. Writes the first text payload to the general pasteboard.
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
      // Only forward text payloads: a binary mime (image/*, etc.) would be garbled by
      // String(cString:), and breaking on the first non-null entry would skip a later text/plain one.
      let isText = entry.mime.map { String(cString: $0).hasPrefix("text/") } ?? true
      guard isText, let data = entry.data else { continue }
      text = String(cString: data)
      break
    }
    guard let text, !text.isEmpty else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
  }

  /// Paste (read) — ⌘V and OSC 52 reads. Completes the request with the pasteboard's text.
  nonisolated func readClipboard(
    userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?
  ) -> Bool {
    guard let userdata else { return false }
    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    guard let surface = view.surface else { return false }
    let text = NSPasteboard.general.string(forType: .string) ?? ""
    text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
    return true
  }

  nonisolated func confirmReadClipboard(
    userdata: UnsafeMutableRawPointer?,
    content: UnsafePointer<CChar>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
  ) {
    // OSC 52 read confirmation flow is not surfaced to the user in Workroom; nothing to confirm.
  }

  // MARK: Close

  nonisolated func closeSurface(userdata: UnsafeMutableRawPointer?, needsConfirm: Bool) {
    // Workroom owns its tab lifecycle (plan A5): a surface/shell exiting leaves the tab in place (as
    // SwiftTerm did) until the user closes it, so libghostty's close request is intentionally ignored.
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
