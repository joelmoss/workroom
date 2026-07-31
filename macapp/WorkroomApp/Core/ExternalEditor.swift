import AppKit
import Defaults

/// An installed app that can open a workroom directory, offered in the detail toolbar's
/// "Open in…" menu. Only the supported editors that are actually installed appear.
struct ExternalEditor: Identifiable {
  let id: String  // bundle identifier
  let name: String
  let appURL: URL

  /// Supported editors (bundle id + display name), in menu order.
  private static let supported: [(id: String, name: String)] = [
    ("com.microsoft.VSCode", "Visual Studio Code"),
    ("dev.zed.Zed", "Zed"),
    ("com.apple.dt.Xcode", "Xcode"),
  ]

  /// The supported editors currently installed, resolved to their app bundle URLs. **Cached** — see
  /// `EditorCache`: this is read straight from `OpenInControl.body`, which since issue #139 renders
  /// once per visible workroom pane, so the uncached version's three LaunchServices lookups per
  /// evaluation would run per pane on every pane rebuild (including every frame of a split-divider
  /// drag). The cache drops on app launch/terminate, so installing an editor still shows up live.
  static var installed: [ExternalEditor] {
    EditorCache.shared.editors {
      supported.compactMap { editor in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.id) else {
          return nil
        }
        return ExternalEditor(id: editor.id, name: editor.name, appURL: url)
      }
    }
  }

  /// The editor the primary "Open in" action uses: the one last picked (`Defaults[.lastEditor]`), else
  /// the first installed. nil when none are installed. Single source for the toolbar's open button, the
  /// ⌘O command, and the Go-menu item, so they always target the same editor.
  static var remembered: ExternalEditor? {
    let installed = installed
    return installed.first { $0.id == Defaults[.lastEditor] } ?? installed.first
  }

  /// The editor configured for opening *file paths* (Settings → "Open file paths in",
  /// `Defaults[.filePathEditor]`), or nil when unset — i.e. the file's default app. Names the
  /// Changes-panel "Open file in…" action (issue #93). Unlike `remembered`, this never falls back to
  /// the first installed editor: an unset/uninstalled choice deliberately reads as "default app".
  static var forFilePaths: ExternalEditor? {
    let id = Defaults[.filePathEditor]
    return id.isEmpty ? nil : installed.first { $0.id == id }
  }

  /// The app's Finder icon, sized for inline display beside its name in the
  /// "Open in…" button and menu. **Cached**, for the same reason `installed` is.
  ///
  /// Drawing into a fresh image rather than assigning `.size` on the returned one is load-bearing:
  /// `NSWorkspace.icon(forFile:)` may hand back an image from its own cache, so resizing it in place
  /// mutates shared state and every other caller silently gets a 20×20 icon.
  var icon: NSImage {
    EditorCache.shared.icon(for: id) {
      let source = NSWorkspace.shared.icon(forFile: appURL.path)
      return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
        source.draw(in: rect)
        return true
      }
    }
  }

  /// Open `path` (a workroom directory) in this editor.
  func open(_ path: String) {
    NSWorkspace.shared.open(
      [URL(fileURLWithPath: path)],
      withApplicationAt: appURL,
      configuration: NSWorkspace.OpenConfiguration()
    )
  }
}

/// Memoizes the LaunchServices work behind `ExternalEditor.installed` / `.icon`, which are read from
/// SwiftUI view bodies — since issue #139 once per visible workroom pane, on every pane rebuild.
/// Uncached, one `OpenInControl` evaluation cost three `urlForApplication` lookups plus an
/// `icon(forFile:)`; a three-member split re-rendering per frame of a divider drag made that
/// hundreds of LaunchServices round-trips a second.
///
/// Invalidated when any app launches or quits, so installing (or deleting) an editor is picked up
/// without relaunching Workroom. Main-thread-confined in practice: every reader is a view body or a
/// menu builder, and the observers deliver on `.main`.
private final class EditorCache {
  static let shared = EditorCache()

  private var cachedEditors: [ExternalEditor]?
  private var cachedIcons: [String: NSImage] = [:]

  private init() {
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
    ] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.cachedEditors = nil
        self?.cachedIcons.removeAll()
      }
    }
  }

  func editors(_ resolve: () -> [ExternalEditor]) -> [ExternalEditor] {
    if let cachedEditors { return cachedEditors }
    let resolved = resolve()
    cachedEditors = resolved
    return resolved
  }

  func icon(for id: String, _ render: () -> NSImage) -> NSImage {
    if let cached = cachedIcons[id] { return cached }
    let rendered = render()
    cachedIcons[id] = rendered
    return rendered
  }
}
