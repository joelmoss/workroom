import AppKit

/// ⌘D (star the highlighted theme) and ⌘F (the favourites filter) inside a theme list. Both keys
/// belong to other commands everywhere else (Split Right, Find), so they aren't `ShortcutAction`s:
/// the app's key monitor (`AppDelegate`) offers them here first, and a theme list takes them only
/// while its window is the key window. The ⌘⇧K picker is a popover, which leaves the window it hangs
/// from key, so its list also takes them from that window while it's open.
@MainActor
final class ThemeListKeys {
  static let shared = ThemeListKeys()

  enum Command: Equatable {
    case toggleFavourite
    case toggleFilter

    /// ⌘D or ⌘F and nothing else, by the character typed, as the shortcut registry matches.
    init?(_ chord: KeyChord) {
      guard chord.modifiers == .command else { return nil }
      switch chord.character {
      case "d": self = .toggleFavourite
      case "f": self = .toggleFilter
      default: return nil
      }
    }
  }

  private struct Entry {
    let id: UUID
    weak var window: NSWindow?
    let perform: (Command) -> Void
  }

  private var entries: [Entry] = []

  /// Hands `window`'s theme list the keys while it's up. Unregister when the list goes.
  func register(window: NSWindow, perform: @escaping (Command) -> Void) -> UUID {
    let id = UUID()
    entries.append(Entry(id: id, window: window, perform: perform))
    return id
  }

  func unregister(_ id: UUID) {
    entries.removeAll { $0.id == id }
  }

  /// Performs `command` on the theme list in `window`, or the popover hanging from it, and says
  /// whether there was one. The newest list wins.
  func handle(_ command: Command, in window: NSWindow?) -> Bool {
    entries.removeAll { $0.window == nil }
    guard let window,
      let entry = entries.last(where: { $0.window === window || $0.window?.parent === window })
    else { return false }
    entry.perform(command)
    return true
  }
}
