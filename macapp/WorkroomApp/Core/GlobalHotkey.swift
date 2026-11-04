import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey registered through Carbon's `RegisterEventHotKey`. Unlike an
/// `NSEvent` global monitor it fires regardless of which app is frontmost, consumes the key, and
/// needs no Accessibility permission — the standard backing for a show/hide-the-app shortcut
/// (issue #13). Hold the instance for as long as the hotkey should stay live; `deinit` unregisters.
final class GlobalHotkey {
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private let handler: () -> Void
  /// This hotkey's id, unique among our registered hotkeys (⌘§ = 1, ⌥§ = 2). Each instance
  /// installs its own app-target handler that sees *every* hot-key-pressed event, so the trampoline
  /// must filter by the fired id (`matches`) — otherwise the first-installed handler returns `noErr`
  /// and swallows every press, firing the wrong action when more than one hotkey is live.
  private let hotKeyID: Int

  /// 'WRKR' — disambiguates our hot-key id from any other component's. `internal` (not `private`)
  /// so `@testable` tests can build a matching `EventHotKeyID` for `matches`.
  static let signature = OSType(0x5752_4B52)

  /// True when `fired` is one of ours (matching signature) and carries `id`. The dispatch rule the
  /// trampoline applies; pure so it has direct unit coverage (the Carbon registration can't be
  /// unit-tested).
  static func matches(_ fired: EventHotKeyID, id: Int) -> Bool {
    fired.signature == signature && fired.id == UInt32(id)
  }

  /// Register `carbonModifiers + keyCode` under hotkey `id`. `keyCode` is a virtual key code (e.g.
  /// `kVK_ISO_Section`) and `carbonModifiers` a Carbon modifier mask (e.g. `cmdKey`); `id` must be
  /// unique among our live hotkeys. Returns nil if registration fails (e.g. the combo is already
  /// claimed by another app), leaving the app otherwise unaffected.
  init?(keyCode: Int, carbonModifiers: Int, id: Int, handler: @escaping () -> Void) {
    self.handler = handler
    self.hotKeyID = id

    // Carbon hot-key events arrive on the main run loop; the C trampoline can't capture context, so
    // we route through `userData` back to this instance, then filter by the fired hotkey id so only
    // the owning instance acts (the rest pass the event on with `eventNotHandledErr`).
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
    let trampoline: EventHandlerUPP = { _, event, userData in
      guard let userData, let event else { return OSStatus(eventNotHandledErr) }
      let instance = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
      var fired = EventHotKeyID()
      let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &fired)
      guard status == noErr, GlobalHotkey.matches(fired, id: instance.hotKeyID) else {
        return OSStatus(eventNotHandledErr)
      }
      instance.handler()
      return noErr
    }
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    guard
      InstallEventHandler(
        GetApplicationEventTarget(), trampoline, 1, &spec, selfPtr, &eventHandlerRef) == noErr
    else { return nil }

    let hotKeyId = EventHotKeyID(signature: Self.signature, id: UInt32(id))
    guard
      RegisterEventHotKey(
        UInt32(keyCode), UInt32(carbonModifiers), hotKeyId, GetApplicationEventTarget(), 0,
        &hotKeyRef) == noErr
    else {
      RemoveEventHandler(eventHandlerRef)
      eventHandlerRef = nil
      return nil
    }
  }

  deinit {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
  }

  /// ⌘ + § (the section key — `kVK_ISO_Section`, layout-independent). Keeps the Carbon key/modifier
  /// constants contained here so callers don't import Carbon. (Issue #13.)
  static func commandSection(handler: @escaping () -> Void) -> GlobalHotkey? {
    GlobalHotkey(keyCode: kVK_ISO_Section, carbonModifiers: cmdKey, id: 1, handler: handler)
  }

  /// The quick terminal's shortcut (issue #39), ⌥§ unless Settings records another. A distinct id
  /// from `commandSection` so both hotkeys coexist (see `matches`).
  static func quickTerminal(
    _ shortcut: GlobalShortcut, handler: @escaping () -> Void
  ) -> GlobalHotkey? {
    GlobalHotkey(
      keyCode: shortcut.keyCode, carbonModifiers: shortcut.carbonModifiers, id: 2,
      handler: handler)
  }

  /// Whether `shortcut` can be registered now: false when another app, or another of ours, holds
  /// it. Registers it for a moment under an id nothing else uses, then lets it go.
  static func isAvailable(_ shortcut: GlobalShortcut) -> Bool {
    GlobalHotkey(
      keyCode: shortcut.keyCode, carbonModifiers: shortcut.carbonModifiers, id: 3, handler: {})
      != nil
  }
}
