import AppKit
import Defaults
import GhosttyKit

/// One terminal surface: an `NSView` that hosts a `ghostty_surface_t` (Metal-rendered by libghostty
/// given our `nsview`), drives a local PTY, and bridges macOS keyboard/IME/mouse into libghostty.
/// This is the libghostty replacement for SwiftTerm's `LocalProcessTerminalView`.
///
/// Ported from Muxy's `GhosttyTerminalNSView` (MIT) as inspiration, trimmed to Workroom's existing
/// feature set: no splits UI, search, progress, dynamic titles, or remote streaming. (File/image
/// drops are handled host-side — see the drag-and-drop extension below.)
///
/// Lifecycle (plan A1): the surface is created when the view enters a window and freed in
/// `tearDown()`/`deinit`; callbacks are nil'd and the C-string config pointers freed on teardown so
/// no in-flight libghostty callback can touch a dead view.
final class GhosttySurfaceView: NSView {
  /// The live surface, or nil before creation / after teardown. `nonisolated(unsafe)` because the
  /// runtime callbacks (via `ghostty_surface_userdata`) read it; all writes happen on the main thread.
  nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

  private let workingDirectory: String

  /// When non-nil/non-empty, the surface launches this command instead of a login shell, and keeps
  /// the pane open after it exits (`wait_after_command`). Used by the "run command" feature (issue
  /// #7); nil for every ordinary terminal. The host passes a shell-wrapped string (`$SHELL -lic …`).
  private let runCommand: String?

  /// Test seam (view-layer unit tests): when `false`, `createSurface()` is a no-op, so the view still
  /// mounts as a real `NSView` in the window — letting `PaneRenderingTests` assert on the AppKit
  /// hierarchy (which panes are window-mounted, and at what size) — but without spawning libghostty's
  /// Metal renderer + a login shell, which is unsafe to tear down in the headless CI test host. Always
  /// `true` in the app: a real terminal spawns its surface exactly as before.
  private let spawnsSurface: Bool

  // Callbacks set by the host (TerminalSessions / TerminalContainerView). Value-type captures only.
  var onActivity: ((TerminalActivity) -> Void)?
  var onOpenURL: ((URL) -> Bool)?
  var onCmdClickFile: ((String) -> Void)?
  var resolveCmdHoverFile: ((String) -> Bool)?
  /// The surface's latest title (OSC 0/2, via shell integration): the running command while busy,
  /// the working directory when idle. Forwarded to the tab strip (issue #2).
  var onTitleChange: ((String) -> Void)?
  /// The shell returned to its prompt (OSC 133 D / `GHOSTTY_ACTION_COMMAND_FINISHED`) — the tab
  /// strip uses this to drop the finished command's title back to the default (issue #2).
  var onCommandFinished: (() -> Void)?
  /// OSC 9;4 progress (`GHOSTTY_ACTION_PROGRESS_REPORT`): `true` while the running program reports it's
  /// working, `false` when idle/done (the REMOVE state). The host drives the sidebar/underline spinner
  /// solely from this (issue #28 follow-up). The adapter calls `handleProgressReport(_:)`, which forwards
  /// here and arms a safety timer; this closure just relays the value to the host.
  var onProgressReport: ((Bool) -> Void)?
  /// The surface's child process exited (`GHOSTTY_ACTION_SHOW_CHILD_EXITED`). The run terminal uses
  /// this to flip run-state back to "Run" while the pane stays open (`wait_after_command`). Only run
  /// tabs wire this; ordinary tabs leave it nil so a shell `exit` is a no-op here (issue #7).
  /// Value-type capture only.
  var onChildExited: ((UInt32) -> Void)?
  /// Close this surface's tab. Fired from `keyDown` when the run command's process has exited and the
  /// pane is sitting at libghostty's "Process exited. Press any key to close" prompt
  /// (`wait_after_command`) — libghostty shows that prompt but emits no close action in this
  /// embedding, so we close it ourselves on the next key. Only run tabs wire this (the host closes
  /// them without a confirm, since the process is gone); ordinary tabs leave it nil and keep
  /// forwarding keys / staying in place after the shell exits (issue #7).
  var onCloseRequested: (() -> Void)?
  /// This pane became first responder (mouse click or programmatic focus) — the host makes it the
  /// selection (issue #3, splits). `becomeFirstResponder` is the single chokepoint for every focus
  /// path, so one hook covers them all. Value-type captures only.
  var onFocused: (() -> Void)?

  /// Set from `GHOSTTY_ACTION_MOUSE_OVER_LINK` (an OSC 8 / detected URL is under the pointer).
  var hasOSC8LinkUnderCursor = false
  /// Latest shell cwd from `GHOSTTY_ACTION_PWD` (the cwd source for ⌘-click path resolution — CMT-1,
  /// since libghostty exposes no PTY child PID for `proc_pidinfo`). Nil until shell integration reports.
  private(set) var lastKnownCwd: String?

  // Occlusion (plan A4): a surface renders only when its pane is active AND its window is visible.
  private var isPaneVisible = true
  private var isWindowVisible = true
  nonisolated(unsafe) private var occlusionObserver: NSObjectProtocol?

  // IME / marked-text state.
  private var markedText = ""
  private var imeMarkedRange = NSRange(location: NSNotFound, length: 0)
  private var imeSelectedRange = NSRange(location: 0, length: 0)

  // keyDown ↔ NSTextInputClient handshake.
  private var keyTextAccumulator: [String] = []
  private var currentKeyEvent: NSEvent?
  private var commandSelectorCalled = false

  // Surface-config C strings must outlive `ghostty_surface_new`; freed on teardown.
  private var surfaceCStrings: [UnsafeMutablePointer<CChar>] = []
  // Backing buffer for the surface config's `env_vars` array; held for the surface's lifetime
  // alongside `surfaceCStrings` and freed on teardown.
  private var envVarsBuffer: UnsafeMutablePointer<ghostty_env_var_s>?
  private var pendingSurfaceCreation = false
  private var isShowingHandCursor = false
  /// Set in mouseDown when a ⌘-click opened a file (no terminal press was sent); makes the matching
  /// mouseUp a no-op so it doesn't send an unbalanced RELEASE or run copy-on-select.
  private var suppressNextMouseUp = false
  private var trackingAreaRef: NSTrackingArea?

  // Overlay scrollbar (restores SwiftTerm's scrollbar). libghostty draws none and exposes no scroll
  // position to poll — it only pushes geometry via `GHOSTTY_ACTION_SCROLLBAR` — so we keep the last
  // metrics, render a thin pass-through thumb on the right edge, and fade it out when idle.
  private let scrollbarWidth: CGFloat = 7
  private let scrollbarThumb = ScrollbarThumbView()
  private var scrollbarMetrics: (total: UInt64, offset: UInt64, len: UInt64)?
  private var scrollbarFadeWork: DispatchWorkItem?

  // OSC 9;4 progress safety timer (issue #28 follow-up): a program that reports it's working but never
  // sends REMOVE — or a long-idle TUI — would otherwise pin the busy indicator on forever. It's a
  // "declared busy but went silent" backstop, not a fixed time-since-last-report cutoff: while the
  // program keeps repainting (title frames — see `handleTitleChange`) the timer is refreshed, so a long
  // task doesn't stop spinning mid-run (issue #38). OSC 9;4 is edge-triggered — Claude emits it once at
  // the start (and once at finish), Codex never — but both animate their title ~1–10×/s the whole time
  // they work, so the title is the liveness heartbeat the progress signal itself lacks.
  private var progressTimeoutTimer: Timer?
  private var progressActive = false
  private static let progressTimeout: TimeInterval = 30

  init(workingDirectory: String, command: String? = nil, spawnsSurface: Bool = true) {
    self.workingDirectory = workingDirectory
    self.runCommand = command
    self.spawnsSurface = spawnsSurface
    super.init(frame: .zero)
    wantsLayer = true
    setupTrackingArea()
    setupScrollbar()
    setupDragAndDrop()
    setAccessibilityRole(.textArea)
    // Stable id so UI tests can count on-screen panes (a surface only appears in the a11y tree while
    // it's actually mounted in a window — exactly the "is this pane rendering?" signal we need).
    setAccessibilityIdentifier("terminal.surface")
    let dir = URL(fileURLWithPath: workingDirectory).lastPathComponent
    setAccessibilityLabel(dir.isEmpty ? "Terminal" : "Terminal — \(dir)")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // MARK: Surface lifecycle (A1)

  private func createSurface() {
    // Test seam: mount the view without a live libghostty surface (see `spawnsSurface`).
    guard spawnsSurface else { return }
    guard surface == nil, let app = GhosttyApp.shared.app else { return }
    guard let backingSize = backingPixelSize() else {
      pendingSurfaceCreation = true
      return
    }
    pendingSurfaceCreation = false

    var config = ghostty_surface_config_new()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
    config.userdata = Unmanaged.passUnretained(self).toOpaque()
    config.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
    config.context = GHOSTTY_SURFACE_CONTEXT_TAB  // Workroom: one surface per tab (no splits yet)

    // Spawn a login shell in the target directory. No explicit `command` → libghostty launches the
    // user's default shell as a login shell (matches Workroom's prior `startProcess(... -l)`).
    freeSurfaceCStrings()
    guard let cwd = strdup(workingDirectory) else { return }
    surfaceCStrings.append(cwd)
    config.working_directory = UnsafePointer(cwd)

    // Inject `TERMINFO` into the shell's environment so it can resolve the bundled `xterm-ghostty`
    // entry (libghostty sets `TERM` but not `TERMINFO`, and macOS has no system entry — without this
    // line editing such as Backspace breaks). Process-level `setenv` doesn't reach the child, so we
    // go through the surface config's env-var array, which libghostty applies to the spawned shell.
    if let terminfo = GhosttyApp.shared.terminfoDirectory,
      let key = strdup("TERMINFO"), let value = strdup(terminfo)
    {
      surfaceCStrings.append(key)
      surfaceCStrings.append(value)
      let buffer = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: 1)
      buffer[0] = ghostty_env_var_s(key: UnsafePointer(key), value: UnsafePointer(value))
      envVarsBuffer = buffer
      config.env_vars = buffer
      config.env_var_count = 1
    }

    // Run-command surface (issue #7): launch a specific command instead of the login shell and KEEP
    // the pane open after it exits (`wait_after_command`) so its output stays visible. The pointer
    // joins `surfaceCStrings`, freed on teardown like `working_directory` / the env vars above.
    if let runCommand, !runCommand.isEmpty, let cmd = strdup(runCommand) {
      surfaceCStrings.append(cmd)
      config.command = UnsafePointer(cmd)
      config.wait_after_command = true
    }

    surface = ghostty_surface_new(app, &config)
    guard let surface else {
      freeSurfaceCStrings()
      return
    }

    let scale = Double(window?.backingScaleFactor ?? 2.0)
    ghostty_surface_set_content_scale(surface, scale, scale)
    ghostty_surface_set_size(surface, backingSize.width, backingSize.height)
    applyColorScheme(isDark: Self.isCurrentAppearanceDark())
    if let screen = window?.screen ?? NSScreen.main,
      let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    {
      ghostty_surface_set_display_id(surface, displayID)
    }
    applyOcclusionState()
    // Keep the overlay scrollbar above the surface's Metal content.
    addSubview(scrollbarThumb, positioned: .above, relativeTo: nil)
  }

  private func destroySurface() {
    if let surface { ghostty_surface_free(surface) }
    surface = nil
    freeSurfaceCStrings()
  }

  /// Explicit teardown on close/delete (plan A1). Clears callbacks first so a late libghostty
  /// callback resolving this view via `userdata` can't invoke a dangling closure, then frees.
  func tearDown() {
    setHandCursor(false)
    onActivity = nil
    onOpenURL = nil
    onCmdClickFile = nil
    resolveCmdHoverFile = nil
    onFocused = nil
    onChildExited = nil
    onCloseRequested = nil
    progressActive = false
    progressTimeoutTimer?.invalidate()
    progressTimeoutTimer = nil
    if let occlusionObserver {
      NotificationCenter.default.removeObserver(occlusionObserver)
      self.occlusionObserver = nil
    }
    destroySurface()
    removeFromSuperview()
  }

  deinit {
    progressTimeoutTimer?.invalidate()
    if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    if let surface { ghostty_surface_free(surface) }
    freeSurfaceCStrings()
  }

  private func freeSurfaceCStrings() {
    for ptr in surfaceCStrings { free(ptr) }
    surfaceCStrings.removeAll()
    envVarsBuffer?.deallocate()
    envVarsBuffer = nil
  }

  // MARK: Geometry / render sizing

  private func backingPixelSize() -> (width: UInt32, height: UInt32)? {
    let size = convertToBacking(bounds).size
    let w = Int(floor(size.width))
    let h = Int(floor(size.height))
    guard w > 0, h > 0 else { return nil }
    return (UInt32(w), UInt32(h))
  }

  private func updateMetalLayerSize() {
    guard let surface, let window else { return }
    layer?.contentsScale = window.backingScaleFactor
    let scale = Double(window.backingScaleFactor)
    ghostty_surface_set_content_scale(surface, scale, scale)
    if let screen = window.screen,
      let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    {
      ghostty_surface_set_display_id(surface, displayID)
    }
    if let backingSize = backingPixelSize() {
      ghostty_surface_set_size(surface, backingSize.width, backingSize.height)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let occlusionObserver {
      NotificationCenter.default.removeObserver(occlusionObserver)
      self.occlusionObserver = nil
    }
    guard let window else {
      // Detached from any window → stop rendering. `updateWindowVisibility` defaults to "visible"
      // when window is nil, so set it explicitly here rather than leaving the last (stale) value.
      isWindowVisible = false
      applyOcclusionState()
      return
    }
    if surface == nil { createSurface() }
    occlusionObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
    ) { [weak self] _ in self?.updateWindowVisibility() }
    updateWindowVisibility()
    updateMetalLayerSize()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if pendingSurfaceCreation { createSurface() }
    updateMetalLayerSize()
    layoutScrollbar()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateMetalLayerSize()
  }

  override func layout() {
    super.layout()
    // Retry a surface creation that was deferred because bounds were zero at window-attach time
    // (setFrameSize isn't guaranteed to fire for every path that establishes the final size).
    if surface == nil, pendingSurfaceCreation { createSurface() }
  }

  // MARK: Occlusion (A4)

  /// Called by the host when this pane becomes the active tab (true) or is hidden (false).
  func setVisible(_ visible: Bool) {
    guard isPaneVisible != visible else { return }
    isPaneVisible = visible
    applyOcclusionState()
  }

  private func updateWindowVisibility() {
    let visible = window?.occlusionState.contains(.visible) ?? true
    guard isWindowVisible != visible else { return }
    isWindowVisible = visible
    applyOcclusionState()
  }

  private func applyOcclusionState() {
    guard let surface else { return }
    ghostty_surface_set_occlusion(surface, isPaneVisible && isWindowVisible)
  }

  // MARK: Focus

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    let ok = super.becomeFirstResponder()
    if ok {
      setSurfaceFocused(true)
      onFocused?()
    }
    return ok
  }

  override func resignFirstResponder() -> Bool {
    let ok = super.resignFirstResponder()
    if ok { setSurfaceFocused(false) }
    return ok
  }

  private func setSurfaceFocused(_ focused: Bool) {
    guard let surface else { return }
    ghostty_surface_set_focus(surface, focused)
  }

  // MARK: Theming

  func applyColorScheme(isDark: Bool) {
    guard let surface else { return }
    ghostty_surface_set_color_scheme(
      surface, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
  }

  /// Apply a rebuilt app config (e.g. after a light/dark system-colors change — IT7).
  func updateConfig(_ config: ghostty_config_t) {
    guard let surface else { return }
    ghostty_surface_update_config(surface, config)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColorScheme(isDark: Self.isCurrentAppearanceDark())
    updateScrollbarColor()
  }

  // MARK: Overlay scrollbar

  private func setupScrollbar() {
    scrollbarThumb.wantsLayer = true
    scrollbarThumb.layer?.cornerRadius = scrollbarWidth / 2
    scrollbarThumb.alphaValue = 0
    scrollbarThumb.isHidden = true
    updateScrollbarColor()
    addSubview(scrollbarThumb)
  }

  /// Called by `GhosttyRuntimeAdapter` on `GHOSTTY_ACTION_SCROLLBAR`. All values are in rows;
  /// `offset` is the viewport top's distance from the top of the scrollback (live == `total - len`).
  func updateScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
    scrollbarMetrics = (total, offset, len)
    layoutScrollbar()
    // Only surface the indicator while scrolled back through history — not on every line of live
    // output (which would flash it constantly during a build).
    if Self.scrollbarShouldFlash(total: total, offset: offset, len: len) { flashScrollbar() }
  }

  private func layoutScrollbar() {
    guard let m = scrollbarMetrics,
      let rect = Self.scrollbarThumbRect(
        total: m.total, offset: m.offset, len: m.len, bounds: bounds,
        width: scrollbarWidth, inset: Self.scrollbarInset, minThumb: Self.scrollbarMinThumb)
    else {
      scrollbarThumb.isHidden = true
      return
    }
    scrollbarThumb.isHidden = false
    scrollbarThumb.frame = rect
  }

  static let scrollbarInset: CGFloat = 2
  static let scrollbarMinThumb: CGFloat = 28

  /// Pure geometry for the overlay thumb (extracted so it's unit-testable). Returns nil when there's
  /// nothing to scroll (`total <= len`). Bottom-left origin: live (`offset == total - len`) sits at
  /// the bottom; fully scrolled up (`offset == 0`) sits at the top. `position` 0 = top, 1 = live.
  static func scrollbarThumbRect(
    total: UInt64, offset: UInt64, len: UInt64, bounds: CGRect,
    width: CGFloat, inset: CGFloat, minThumb: CGFloat
  ) -> CGRect? {
    guard total > len else { return nil }
    let trackHeight = max(0, bounds.height - inset * 2)
    let thumbHeight = max(minThumb, trackHeight * CGFloat(len) / CGFloat(total))
    let maxOffset = total - len
    let position = maxOffset > 0 ? CGFloat(offset) / CGFloat(maxOffset) : 1
    let y = inset + (trackHeight - thumbHeight) * (1 - position)
    return CGRect(x: bounds.width - width - inset, y: y, width: width, height: thumbHeight)
  }

  /// Flash the indicator only while scrolled back, not at the live bottom (so live output doesn't
  /// flash it constantly). Extracted as a pure predicate for tests.
  static func scrollbarShouldFlash(total: UInt64, offset: UInt64, len: UInt64) -> Bool {
    total > len && offset < total - len
  }

  private func flashScrollbar() {
    scrollbarFadeWork?.cancel()
    scrollbarThumb.alphaValue = 1
    let work = DispatchWorkItem { [weak self] in
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.4
        self?.scrollbarThumb.animator().alphaValue = 0
      }
    }
    scrollbarFadeWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
  }

  private func updateScrollbarColor() {
    let dark = Self.isCurrentAppearanceDark()
    scrollbarThumb.layer?.backgroundColor =
      (dark ? NSColor(white: 1, alpha: 0.35) : NSColor(white: 0, alpha: 0.35)).cgColor
  }

  private static func isCurrentAppearanceDark() -> Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  // MARK: PWD (CMT-1)

  /// Called by `GhosttyRuntimeAdapter` on `GHOSTTY_ACTION_PWD`.
  func handlePwd(_ pwd: String) { lastKnownCwd = pwd }

  // MARK: Progress (OSC 9;4)

  /// Called by `GhosttyRuntimeAdapter` on `GHOSTTY_ACTION_PROGRESS_REPORT`. Forwards the busy state to
  /// the host and arms a safety timer: a "working" report (re)starts the countdown; an idle report
  /// cancels it. The countdown is also refreshed by title activity while busy (`handleTitleChange`), so
  /// it only elapses when a program that declared itself working goes fully silent — synthesising an
  /// idle state so it can't pin the spinner on (issue #28) without cutting off a long task that signals
  /// progress only once at the start (issue #38).
  func handleProgressReport(_ active: Bool) {
    progressActive = active
    if active {
      armProgressTimeout()
    } else {
      progressTimeoutTimer?.invalidate()
      progressTimeoutTimer = nil
    }
    onProgressReport?(active)
  }

  /// Called by `GhosttyRuntimeAdapter` on `GHOSTTY_ACTION_SET_TITLE` (OSC 0/2). Forwards to the host
  /// and, while the program has declared itself busy via OSC 9;4, treats the title repaint as a liveness
  /// heartbeat that refreshes the safety timer. Agents repaint an animated title the whole time they
  /// work but emit OSC 9;4 only at the edges, so this keeps the spinner alive across a long task while
  /// still letting a genuinely silent program time out (issue #38). The title NEVER starts the busy
  /// state on its own — it only extends one already set by OSC 9;4 (issue #28).
  func handleTitleChange(_ title: String) {
    onTitleChange?(title)
    if progressActive { armProgressTimeout() }
  }

  /// Called by `GhosttyRuntimeAdapter` on `GHOSTTY_ACTION_SHOW_CHILD_EXITED` — the surface's child
  /// process exited. Forwards to the host; only run tabs act on it (issue #7).
  func handleChildExited(exitCode: UInt32) {
    onChildExited?(exitCode)
  }

  /// Whether the surface's child process has already exited (`wait_after_command` keeps such a pane
  /// open). Lets the host skip the "stops any running process" close confirmation — there's nothing
  /// left running to lose (issue #7). False before the surface exists.
  var processHasExited: Bool {
    surface.map { ghostty_surface_process_exited($0) } ?? false
  }

  /// Send Ctrl-C to the running program — a graceful SIGINT to the foreground process group. Drives
  /// a synthetic ⌃C key event through the normal `keyDown` path (→ `ghostty_surface_key`), exactly as
  /// a real keypress does, which delivers immediately. NOT `ghostty_surface_text` (bracketed paste
  /// would make the 0x03 a literal byte) and NOT `ghostty_surface_write_buffer` (it enqueues and only
  /// flushes on the next surface event, so a Stop click with no follow-up input wouldn't fire). Backs
  /// the run command's Stop (issue #7). No-op until the surface exists. keyCode 8 = ANSI "C".
  ///
  /// Skips when the child has already exited: there's nothing to interrupt, and routing a synthetic key
  /// through `keyDown` then would trip the "press any key to close" guard and close the run tab instead
  /// — e.g. a Stop pressed in the gap between the process exiting and `markRunExited` firing (review #6).
  func sendInterrupt() {
    guard surface != nil, !processHasExited,
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .control,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
        context: nil, characters: "\u{03}", charactersIgnoringModifiers: "c", isARepeat: false,
        keyCode: 8)
    else { return }
    keyDown(with: event)
  }

  private func armProgressTimeout() {
    progressTimeoutTimer?.invalidate()
    progressTimeoutTimer = Timer.scheduledTimer(
      withTimeInterval: Self.progressTimeout, repeats: false
    ) { [weak self] _ in
      self?.progressTimeoutTimer = nil
      self?.progressActive = false
      self?.onProgressReport?(false)
    }
  }

  // MARK: Selection

  func readSelectionText() -> String? {
    guard let surface, ghostty_surface_has_selection(surface) else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    return Self.extractString(from: text)
  }

  private static func extractString(from text: ghostty_text_s) -> String? {
    guard let ptr = text.text, text.text_len > 0 else { return nil }
    let len = Int(text.text_len)
    return ptr.withMemoryRebound(to: UInt8.self, capacity: len) { raw in
      String(bytes: UnsafeBufferPointer(start: raw, count: len), encoding: .utf8)
    }
  }

  // MARK: Keyboard

  override func keyDown(with event: NSEvent) {
    guard let surface else {
      super.keyDown(with: event)
      return
    }
    // "Process exited. Press any key to close" (run command at its `wait_after_command` prompt):
    // libghostty shows the prompt but never emits a close action here, so close the tab ourselves on
    // the next key. Only run tabs wire `onCloseRequested`; ordinary tabs fall through and forward
    // keys as usual (a finished login shell just keeps its pane) (issue #7).
    if let onCloseRequested, processHasExited {
      onCloseRequested()
      return
    }
    let action: ghostty_input_action_e =
      event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let optionAsAlt = translatedOptionAsAlt(for: event)

    // control-only (no ⌘/⌥), not composing: send the control keystroke directly.
    if flags.contains(.control), !flags.contains(.command), !flags.contains(.option),
      !hasMarkedText()
    {
      var keyEvent = buildKeyEvent(from: event, action: action)
      let text = Self.filterSpecialCharacters(event.characters ?? "")
      if text.isEmpty {
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
      } else {
        text.withCString {
          keyEvent.text = $0
          _ = ghostty_surface_key(surface, keyEvent)
        }
      }
      return
    }

    // ⌘-modified: app shortcuts are handled by the menu / ⌘1-9 monitor (A3); everything else goes
    // to the terminal with no text payload.
    if flags.contains(.command) {
      if isAppShortcut(event) { return }
      var keyEvent = buildKeyEvent(from: event, action: action)
      keyEvent.text = nil
      _ = ghostty_surface_key(surface, keyEvent)
      return
    }

    // Normal path: drive the input context (IME) and capture any produced text.
    let hadMarkedText = hasMarkedText()
    currentKeyEvent = event
    keyTextAccumulator = []
    commandSelectorCalled = false
    let interpretEvent = optionAsAlt ? eventStrippingOption(event) : event
    interpretKeyEvents([interpretEvent])
    currentKeyEvent = nil
    syncPreedit(clearIfNeeded: hadMarkedText)
    let commandWasCalled = commandSelectorCalled

    if !keyTextAccumulator.isEmpty {
      for text in keyTextAccumulator {
        var keyEvent = buildKeyEvent(from: event, action: action)
        keyEvent.consumed_mods =
          commandWasCalled
          ? GHOSTTY_MODS_NONE : consumedModsFromFlags(flags, consumeOption: !optionAsAlt)
        text.withCString {
          keyEvent.text = $0
          _ = ghostty_surface_key(surface, keyEvent)
        }
      }
    } else {
      var keyEvent = buildKeyEvent(from: event, action: action)
      keyEvent.consumed_mods =
        commandWasCalled
        ? GHOSTTY_MODS_NONE : consumedModsFromFlags(flags, consumeOption: !optionAsAlt)
      keyEvent.composing = hasMarkedText() || hadMarkedText
      // Derive text from `event.characters`, dropping AppKit sentinels (see `filterSpecialCharacters`):
      // function keys / arrows resolve to "" here and fall through to the keycode-only branch, which
      // libghostty encodes correctly. DEL (U+7F, the Backspace key) is intentionally KEPT and sent as
      // text — libghostty 1.2.3's *keycode* encoding for backspace is broken (it emits a space for the
      // backspace keycode), but forwarding the literal 0x7f byte as text delivers the correct erase.
      // (Confirmed by raw-PTY byte probing; matches Muxy's filter. Revisit if we move off 1.2.3.)
      let text = Self.filterSpecialCharacters(event.characters ?? "")
      if !text.isEmpty, !keyEvent.composing {
        text.withCString {
          keyEvent.text = $0
          _ = ghostty_surface_key(surface, keyEvent)
        }
      } else {
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
      }
    }
  }

  override func keyUp(with event: NSEvent) {
    guard let surface else { return }
    var keyEvent = buildKeyEvent(from: event, action: GHOSTTY_ACTION_RELEASE)
    keyEvent.text = nil
    _ = ghostty_surface_key(surface, keyEvent)
  }

  override func flagsChanged(with event: NSEvent) {
    guard let surface else { return }
    // During IME composition we don't forward bare modifier changes (they'd disrupt the input
    // context), but still refresh the ⌘-hover cursor so releasing ⌘ mid-composition clears it.
    guard !hasMarkedText() else {
      updateCmdHoverCursor(modifierFlags: event.modifierFlags)
      return
    }
    let action: ghostty_input_action_e =
      isFlagPress(event) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    var keyEvent = buildKeyEvent(from: event, action: action)
    keyEvent.text = nil
    _ = ghostty_surface_key(surface, keyEvent)
    updateCmdHoverCursor(modifierFlags: event.modifierFlags)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown, let surface else { return false }
    guard window?.firstResponder === self || window?.firstResponder === inputContext else {
      return false
    }
    if isAppShortcut(event) { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
      return false
    }
    var keyEvent = buildKeyEvent(
      from: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    keyEvent.text = nil
    return ghostty_surface_key(surface, keyEvent)
  }

  override func doCommand(by selector: Selector) { commandSelectorCalled = true }

  override func insertText(_ insertString: Any) {
    insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
  }

  /// Workroom's app-owned shortcuts that must NOT reach the terminal (plan A3 — minimal allowlist:
  /// only where Ghostty's behavior would diverge from Workroom's). ⌘1-9 are also caught by the
  /// AppDelegate monitor; included here defensively. ⌘C/⌘V/etc. fall through to libghostty.
  private func isAppShortcut(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    // The arrow-key tab-navigation menu shortcuts, matched by keyCode (charactersIgnoringModifiers
    // returns a function-key sentinel, not a letter, so the char checks below can't see them):
    // ⌥⌘←/→ = prev/next terminal tab; ⇧⌥⌘←/→ = prev/next workroom tab (issue #29). Reserved like the
    // Run keys so the menu key-equivalent wins over a TUI in an enhanced keyboard mode (Claude/Codex).
    // ⌃⌘arrows (split-pane focus, issue #3) is monitor-only with no menu item, so it's deliberately
    // NOT reserved — it passes through to the terminal at a split's edge, exactly as it did on ⌥⌘arrows.
    if event.keyCode == 123 || event.keyCode == 124 {  // ← / →
      if flags == [.command, .option] || flags == [.command, .option, .shift] { return true }
    }
    guard let chars = event.charactersIgnoringModifiers, let ch = chars.first else { return false }
    let key = Character(ch.lowercased())
    // Menu commands that pair Command with Shift or Option fail the command-only guard below, so
    // reserve them explicitly. Without this they reach the terminal, and a TUI in an enhanced
    // keyboard mode (Claude/Codex) consumes the keystroke so the menu key-equivalent never fires.
    // ⇧⌘D = Split Down; ⇧⌘N = Next Notification; ⇧⌘R = Stop run; ⌥⌘N = Notifications toggle;
    // ⌥⌘R = Restart run (issue #7).
    if flags == [.command, .shift] { return key == "d" || key == "n" || key == "r" }
    if flags == [.command, .option] { return key == "n" || key == "r" }
    guard flags == .command else { return false }
    if ("1"..."9").contains(ch) { return true }  // focus tab N
    // ⌘T/⌘W/⌘O/⌘D are real menu commands; ⌘Q/⌘H/⌘M/⌘, are system standards; ⌘[ / ⌘] are Back/Forward
    // navigation (issue #26); ⌘R is Run (issue #7) — all reserved so the menu key-equivalent fires
    // instead of the terminal. Plain ⌘N has no Workroom command, so it passes through to the terminal.
    return ["t", "w", "o", "d", "q", "h", "m", ",", "[", "]", "r"].contains(key)
  }

  private func buildKeyEvent(from event: NSEvent, action: ghostty_input_action_e)
    -> ghostty_input_key_s
  {
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = action
    keyEvent.keycode = UInt32(event.keyCode)  // native macOS virtual keycode; libghostty maps it
    keyEvent.mods = modsFromEvent(event)
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.composing = false
    keyEvent.text = nil
    keyEvent.unshifted_codepoint =
      event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
    return keyEvent
  }

  private func consumedModsFromFlags(
    _ flags: NSEvent.ModifierFlags, consumeOption: Bool = true
  ) -> ghostty_input_mods_e {
    var mods = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if consumeOption, flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    return ghostty_input_mods_e(rawValue: mods)
  }

  private enum RightModifierMask {
    static let shift: UInt = 0x04, control: UInt = 0x2000, option: UInt = 0x40, command: UInt = 0x10
  }

  private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
    var mods = GHOSTTY_MODS_NONE.rawValue
    let flags = event.modifierFlags
    let raw = flags.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    if raw & RightModifierMask.shift != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if raw & RightModifierMask.control != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if raw & RightModifierMask.option != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if raw & RightModifierMask.command != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
    return ghostty_input_mods_e(rawValue: mods)
  }

  /// True when the option key should be treated as a text-composition modifier (macOS-style) rather
  /// than Alt — libghostty tells us via its key-translation mods.
  private func translatedOptionAsAlt(for event: NSEvent) -> Bool {
    guard let surface, event.modifierFlags.contains(.option) else { return false }
    let translated = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
    return translated.rawValue & GHOSTTY_MODS_ALT.rawValue == 0
  }

  private func eventStrippingOption(_ event: NSEvent) -> NSEvent {
    let stripped = event.modifierFlags.subtracting(.option)
    return NSEvent.keyEvent(
      with: event.type, location: event.locationInWindow, modifierFlags: stripped,
      timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
      characters: event.charactersIgnoringModifiers ?? "",
      charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
      isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
  }

  private func isFlagPress(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags
    switch event.keyCode {
    case 56, 60: return flags.contains(.shift)
    case 58, 61: return flags.contains(.option)
    case 59, 62: return flags.contains(.control)
    case 55, 54: return flags.contains(.command)
    case 57: return flags.contains(.capsLock)
    default: return false
    }
  }

  /// Decide whether a key's `event.characters` is real insertable text or an AppKit sentinel we must
  /// NOT forward as text. macOS reports non-text keys via the function-key private-use range
  /// (U+F700–U+F8FF: arrows, F-keys, Home/End, Page Up/Down, forward-delete) and C0 control chars
  /// via codepoints < 0x20; for those we send the key by keycode only and let libghostty encode the
  /// escape sequence (so arrows navigate instead of inserting a glyph). DEL (U+007F — the
  /// Backspace/Delete key) IS kept and forwarded as text so the shell receives the erase byte.
  /// Mirrors Ghostty's own macOS surface: first scalar decides; pass or drop the whole string.
  /// `static` so it's unit-testable as a pure function (it uses no instance state).
  static func filterSpecialCharacters(_ s: String) -> String {
    guard let scalar = s.unicodeScalars.first else { return "" }
    let value = scalar.value
    if value < 0x20 || (0xF700...0xF8FF).contains(value) { return "" }
    return s
  }

  private func syncPreedit(clearIfNeeded: Bool = true) {
    guard let surface else { return }
    if hasMarkedText(), !markedText.isEmpty {
      let text = markedText
      text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
    } else if clearIfNeeded {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }

  // MARK: Mouse

  private func mousePoint(from event: NSEvent) -> CGPoint {
    let local = convert(event.locationInWindow, from: nil)
    return CGPoint(x: local.x, y: bounds.height - local.y)  // libghostty uses a top-left origin
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    guard let surface else { return }
    let pt = mousePoint(from: event)
    ghostty_surface_mouse_pos(surface, pt.x, pt.y, modsFromEvent(event))
    // ⌘-click a (non-OSC8) word that RESOLVES TO A REAL FILE → open in the configured editor and
    // consume the gesture (suppress the matching mouseUp). Any other ⌘-click falls through to a
    // normal terminal press, so plain-text ⌘-clicks aren't swallowed and the press/release balance.
    if event.modifierFlags.contains(.command), !hasOSC8LinkUnderCursor,
      let word = readWordUnderMouse(), resolveCmdHoverFile?(word) == true
    {
      onCmdClickFile?(word)
      suppressNextMouseUp = true
      return
    }
    suppressNextMouseUp = false
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
  }

  override func mouseUp(with event: NSEvent) {
    guard let surface else { return }
    if suppressNextMouseUp {
      // The matching mouseDown opened a file: no PRESS was sent and the selection was left intact,
      // so skip the RELEASE and copy-on-select (which would otherwise clobber the pasteboard).
      suppressNextMouseUp = false
      return
    }
    let pt = mousePoint(from: event)
    ghostty_surface_mouse_pos(surface, pt.x, pt.y, modsFromEvent(event))
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    autoCopySelectionIfEnabled()
  }

  override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
  override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

  override func mouseMoved(with event: NSEvent) {
    guard let surface else { return }
    let pt = mousePoint(from: event)
    ghostty_surface_mouse_pos(surface, pt.x, pt.y, modsFromEvent(event))
    updateCmdHoverCursor(modifierFlags: event.modifierFlags)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    setHandCursor(false)
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let surface else { return }
    let pt = mousePoint(from: event)
    ghostty_surface_mouse_pos(surface, pt.x, pt.y, modsFromEvent(event))
    let consumed = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    if !consumed {
      presentContextMenu(with: event)
      // popUpContextMenu runs a modal tracking loop that swallows the physical rightMouseUp, so
      // libghostty would never receive the RELEASE for the press above — balance it explicitly.
      // Re-read `self.surface` rather than reusing the captured pointer: a context-menu command can
      // free the surface during the modal (Close Terminal), and the balancing RELEASE on a freed
      // surface is a use-after-free crash. (Those commands are also deferred — see presentContextMenu —
      // so teardown happens after this event fully returns.)
      if let surface = self.surface {
        _ = ghostty_surface_mouse_button(
          surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
      }
    }
  }

  override func rightMouseUp(with event: NSEvent) {
    guard let surface else {
      super.rightMouseUp(with: event)
      return
    }
    let pt = mousePoint(from: event)
    ghostty_surface_mouse_pos(surface, pt.x, pt.y, modsFromEvent(event))
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
  }

  override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    var mods: ghostty_input_scroll_mods_t = 0
    if event.hasPreciseScrollingDeltas { mods |= 1 }
    ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods)
  }

  /// The word under the pointer (for ⌘-click path resolution), via libghostty's quicklook word.
  private func readWordUnderMouse() -> String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_quicklook_word(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    let trimmed = Self.extractString(from: text)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty ?? true) ? nil : trimmed
  }

  /// Copy-on-select: on mouse-up, copy the current selection to the pasteboard if enabled (the
  /// xterm/iTerm2 convention). Gated by the `copyOnSelect` setting.
  private func autoCopySelectionIfEnabled() {
    guard Defaults[.copyOnSelect], let selection = readSelectionText(), !selection.isEmpty else {
      return
    }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(selection, forType: .string)
  }

  // MARK: ⌘-hover cursor

  private func updateCmdHoverCursor(modifierFlags: NSEvent.ModifierFlags) {
    guard modifierFlags.contains(.command) else {
      setHandCursor(false)
      return
    }
    if hasOSC8LinkUnderCursor {
      setHandCursor(true)
      return
    }
    if let word = readWordUnderMouse(), resolveCmdHoverFile?(word) == true {
      setHandCursor(true)
    } else {
      setHandCursor(false)
    }
  }

  private func setHandCursor(_ on: Bool) {
    guard on != isShowingHandCursor else { return }
    isShowingHandCursor = on
    if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
  }

  // MARK: Context menu

  private func presentContextMenu(with event: NSEvent) {
    // Right-click focuses this pane so the split/close commands below act on the one clicked.
    window?.makeFirstResponder(self)

    let menu = NSMenu(title: "Terminal")
    let paste = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
    paste.target = self
    paste.isEnabled = NSPasteboard.general.string(forType: .string).map { !$0.isEmpty } ?? false
    menu.addItem(paste)
    menu.addItem(.separator())
    menu.addItem(contextItem("New Terminal", #selector(contextNewTerminal), "t", .command))
    menu.addItem(contextItem("Split Right", #selector(contextSplitRight), "d", .command))
    menu.addItem(contextItem("Split Left", #selector(contextSplitLeft)))
    menu.addItem(contextItem("Split Down", #selector(contextSplitDown), "d", [.command, .shift]))
    menu.addItem(contextItem("Split Up", #selector(contextSplitUp)))
    menu.addItem(.separator())
    menu.addItem(contextItem("Close Terminal", #selector(contextCloseTerminal), "w", .command))
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  /// Build a context-menu item targeting this view; the optional key/modifiers are shown as a hint.
  private func contextItem(
    _ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = []
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = mods
    item.target = self
    return item
  }

  // Context-menu commands act on the app's focused pane — which the right-click just made this one.
  // Deferred to the next runloop so they run AFTER the menu modal and the `rightMouseDown` handler
  // unwind: closing a pane frees its surface, and doing that mid-event (while `rightMouseDown` still
  // holds a surface pointer for its balancing RELEASE) is a use-after-free crash.
  @objc private func contextNewTerminal() {
    DispatchQueue.main.async { AppStore.shared.newTerminalInSelectedTarget() }
  }
  @objc private func contextCloseTerminal() {
    DispatchQueue.main.async { AppStore.shared.closeCurrentTerminalTab() }
  }
  @objc private func contextSplitRight() {
    DispatchQueue.main.async { AppStore.shared.splitFocusedRight() }
  }
  @objc private func contextSplitLeft() {
    DispatchQueue.main.async { AppStore.shared.splitFocusedLeft() }
  }
  @objc private func contextSplitDown() {
    DispatchQueue.main.async { AppStore.shared.splitFocusedDown() }
  }
  @objc private func contextSplitUp() {
    DispatchQueue.main.async { AppStore.shared.splitFocusedUp() }
  }

  @objc func paste(_ sender: Any?) {
    window?.makeFirstResponder(self)
    guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
    insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
  }

  // MARK: Tracking area

  private func setupTrackingArea() {
    if let existing = trackingAreaRef { removeTrackingArea(existing) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    trackingAreaRef = area
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    setupTrackingArea()
  }
}

// MARK: - Drag-and-drop (files / images → a path at the cursor)

extension GhosttySurfaceView {
  /// Accept file and image drops. A terminal can't render an image, so a drop inserts a
  /// shell-quoted path at the cursor: a dropped file's own path, or — for raw image data with no
  /// file backing (a browser image, a Preview selection, a screenshot) — a temp PNG we write.
  /// (Issue #21.)
  func setupDragAndDrop() {
    registerForDraggedTypes([.fileURL, .png, .tiff])
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    dropOperation(for: sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    dropOperation(for: sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = droppedPaths(from: sender.draggingPasteboard)
    guard !paths.isEmpty else { return false }
    // Route input here so what the user types after the path lands in this terminal.
    window?.makeFirstResponder(self)
    // Trailing space separates the path(s) from whatever is typed next.
    let text = paths.map(Self.shellQuoted).joined(separator: " ") + " "
    insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    return true
  }

  /// `.copy` when the drag carries something we can turn into a path, else none (declines it).
  private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
    canAcceptDrop(sender.draggingPasteboard) ? .copy : []
  }

  private func canAcceptDrop(_ pasteboard: NSPasteboard) -> Bool {
    if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    {
      return true
    }
    return pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
  }

  /// The absolute path(s) a drop resolves to: dropped files keep their own paths; raw image data is
  /// written to a temp PNG. File URLs win when both are present (a Finder image drag carries both).
  private func droppedPaths(from pasteboard: NSPasteboard) -> [String] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
      !urls.isEmpty
    {
      return urls.map(\.path)
    }
    if let path = Self.saveDroppedImage(pasteboard) { return [path] }
    return []
  }

  /// Persist raw dropped image data to a temp PNG and return its path. TIFF (the common in-memory
  /// drag form) is transcoded to PNG so the on-disk file matches its `.png` extension.
  private static func saveDroppedImage(_ pasteboard: NSPasteboard) -> String? {
    let pngData: Data?
    if let png = pasteboard.data(forType: .png) {
      pngData = png
    } else if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
      pngData = rep.representation(using: .png, properties: [:])
    } else {
      pngData = nil
    }
    guard let data = pngData else { return nil }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkroomDroppedImages", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("image-\(UUID().uuidString).png")
    do {
      try data.write(to: url)
    } catch {
      return nil
    }
    return url.path
  }

  /// POSIX single-quote a path so spaces and shell metacharacters are taken literally by the shell
  /// that receives the inserted text.
  private static func shellQuoted(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

// MARK: - NSTextInputClient (IME / marked text)

extension GhosttySurfaceView: NSTextInputClient {
  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    unmarkText()
    guard !text.isEmpty else { return }
    if currentKeyEvent != nil {
      keyTextAccumulator.append(text)
    } else if let surface {
      text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    markedText = text
    imeMarkedRange =
      text.isEmpty
      ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: text.utf16.count)
    imeSelectedRange = clampedMarkedRange(selectedRange)
    if currentKeyEvent == nil { syncPreedit() }
  }

  func unmarkText() {
    guard hasMarkedText() else { return }
    markedText = ""
    imeMarkedRange = NSRange(location: NSNotFound, length: 0)
    imeSelectedRange = NSRange(location: 0, length: 0)
    syncPreedit()
  }

  func selectedRange() -> NSRange { imeSelectedRange }
  func markedRange() -> NSRange { imeMarkedRange }
  func hasMarkedText() -> Bool { imeMarkedRange.location != NSNotFound }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    guard hasMarkedText() else {
      actualRange?.pointee = NSRange(location: 0, length: 0)
      return range.location == 0 && range.length == 0 ? NSAttributedString(string: "") : nil
    }
    guard let safe = intersection(range, with: imeMarkedRange) else { return nil }
    actualRange?.pointee = safe
    return NSAttributedString(string: (markedText as NSString).substring(with: safe))
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface else { return .zero }
    var x = 0.0
    var y = 0.0
    var w = 0.0
    var h = 0.0
    ghostty_surface_ime_point(surface, &x, &y, &w, &h)
    let viewPt = NSPoint(x: x, y: bounds.height - y)
    let screenPt = window?.convertPoint(toScreen: convert(viewPt, to: nil)) ?? viewPt
    return NSRect(x: screenPt.x, y: screenPt.y - h, width: w, height: h)
  }

  private func clampedMarkedRange(_ range: NSRange) -> NSRange {
    guard range.location != NSNotFound else { return NSRange(location: 0, length: 0) }
    let length = markedText.utf16.count
    let location = min(range.location, length)
    return NSRange(location: location, length: min(range.length, length - location))
  }

  private func intersection(_ a: NSRange, with b: NSRange) -> NSRange? {
    guard a.location != NSNotFound, b.location != NSNotFound else { return nil }
    let start = max(a.location, b.location)
    let end = min(a.location + a.length, b.location + b.length)
    guard start <= end else { return nil }
    return NSRange(location: start, length: end - start)
  }
}

/// The overlay scrollbar thumb. Hit-testing returns nil so the indicator never intercepts mouse
/// events — clicks, drags, and selection pass straight through to the terminal beneath it.
private final class ScrollbarThumbView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
