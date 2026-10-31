# macapp performance facts

Measured facts about what the app's dependencies already do, so a "skip the work when nothing
changed" guard is proposed only where nothing below it skips the work already. Each was checked by
a probe, not by reading the app's own code; #503 proposed three such guards and two turned out to
exist already.

## Observation skips an equal whole-value set

On Swift 6.2 and later (CI, nightly and release build with Xcode 27.1), the `@Observable` macro's
setter is:

    set {
      guard shouldNotifyObservers(_x, newValue) else { _x = newValue; return }
      withMutation(keyPath: \.x) { _x = newValue }
    }

For an `Equatable` value, assigning a value equal to the stored one stores it and notifies no one.
The `_modify` accessor has no such check: an in-place mutation of the stored property (for example
`observable.dict[key] = value` on the `@Observable` class itself) always notifies, even when the
value is unchanged. Probe (scratch file, `withObservationTracking`): equal array assignment fired 0
observers, equal dictionary assignment 0, equal dictionary subscript write 1.

What follows from it in this app:

- `AppStore.projects` and `AppStore.workroomStatuses` are computed get/set proxies to
  `ProjectStore`'s stored properties, so even `store.workroomStatuses[sid] = s` is a whole-value
  set and gets the dedupe. An identical project list (`projects = fresh` on reload) already
  notifies no one.
- A field that changes on every write defeats the dedupe for the whole value. `WorkroomStatus`'s
  clocks (`lastChecked` and the rest) compare by presence through `PresenceEquatable` for this
  reason (#503). A view that needs a clock's time to redraw would not refresh under that rule.

## libghostty skips an unchanged size and scale

At the pinned engine (`GHOSTTY_SHA` in `vcs/scripts/build-ghostty-vt.sh`), `ghostty_surface_set_size` lands in
the embedded runtime's `updateSize`, which returns when width and height match the last call
(`src/apprt/embedded.zig:1024-1029`: "Runtimes sometimes generate superfluous resize events even if
the size did not actually change (SwiftUI)"). The core checks again
(`Surface.zig` `sizeCallback`, `self.size.screen.equals`). `ghostty_surface_set_content_scale` ends
in `contentScaleCallback`, which returns once the rounded DPI is unchanged. A Swift-side
comparison before these calls (`GhosttySurfaceView.updateMetalLayerSize`) saves only two FFI calls.

## A title event is cheap, and an agent retitles every frame

Ghostty raises `GHOSTTY_ACTION_SET_TITLE` for every OSC 0/2 it receives, with no dedupe
(`Surface.zig`, `.set_title`). A coding agent's spinner changes the title on every frame
("✳ Working", then "✻ Working"; see the fixtures in `TerminalSessionsTests.swift`), so an
"unchanged title" early-out in `TerminalSessions.updateTitle` never fires for an agent. The
foreground-process read (`ghostty_surface_foreground_pid`, then `proc_name`) is skipped for a title
equal to the one shown; a changed title is stored in its own observable (`LiveTitle`), so a repaint
re-renders only the views that show it and does not republish the tab map.

The work per title event is small. Measured 2026-10-18 on an Apple-silicon Mac, 100,000 calls each:

| Call | Cost per call |
|---|---|
| `proc_name` | 0.3 to 0.5 µs |
| `NSImage(named:)`, image exists | about 0.05 µs |
| `NSImage(named:)`, no such image | about 55 µs (AppKit does not cache a miss) |

`ToolLogoRegistry` calls `NSImage(named:)` only for a `registry.json` entry, and every entry has its
`ToolLogo-<id>` asset, so production never misses. A registry entry added without its asset makes
every title event for that tool pay the miss.

## Reading the engine's source

`vcs/scripts/build-ghostty-vt.sh` keeps the pinned engine's source at
`~/.cache/workroom/ghostty-vt/src-<GHOSTTY_SHA>` (`WR_GHOSTTY_VT_CACHE` moves the root), cloned
on the script's first run, unless `WR_GHOSTTY_SRC` or a `vcs/vendor/ghostty` checkout supplies it. GhosttyKit is built from the same upstream sha, so this source answers what a
`ghostty_surface_*` call does (`src/apprt/embedded.zig` for the C API, `src/Surface.zig` for the
core).
