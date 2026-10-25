# App menus, keyboard handling and layout

Paths beginning `Core/`, `Views/` and `Scripts/` are relative to `macapp/`.
For user-facing wording, follow [app copy](../app-copy.md).

- **Menu enable/disable must flow through `focusedSceneValue` + `@FocusedValue`**
  (see `WorkroomApp.swift`); a `Commands` body does not re-evaluate when the shared
  `AppStore` mutates. ⌘1–9 are handled by an `NSEvent` local monitor in `AppDelegate`,
  not menu items, so they fire before the terminal swallows the keys.

- **⌥Tab / ⌃Tab (the quick switchers, issue #132) are monitor-only and deliberately NOT in
  `GhosttySurfaceView.isAppShortcut`.** That list is static, but whether the app owns Tab depends on
  runtime state: a workroom with one pane has nothing to switch to, so ⌃Tab must reach the TUI. The
  monitor branch consumes the event only when a switch actually happened, exactly as ⌥⌘digit and
  ⌥⌘arrows already do — same reasoning as the unreserved ⌃⌘arrows. `AppShortcutReservationTests` pins
  Tab as never-reserved so a later "defence in depth" edit can't take `<C-Tab>` from every TUI. Both
  trigger modifiers are `Defaults` keys (`switcher*Modifier`) because a global-hotkey grabber
  (AltTab, HyperSwitch, Contexts all bind ⌥Tab) intercepts upstream of `NSApp.sendEvent`, where no
  local monitor can see the key and no API can detect the conflict.
  The Go menu's **Last-Used Workroom / Last-Used Pane** items carry the same key equivalents purely so
  macOS renders and teaches them (and so the feature is mouse-reachable) — the monitor still owns the
  keystroke, since it runs ahead of menu dispatch and consumes the event whenever it switched. Their
  enablement is therefore load-bearing, not cosmetic: a disabled item drops its key equivalent, which is
  what stops the menu eating a Tab the monitor deliberately passed through. Their action resolves the
  store from the **key window** (`QuickSwitcher.stepFromKeyWindow`), not from the `Commands` body's
  focused store, which outlives an aux window becoming key.

- **An Escape sent by computer-use automation doesn't reach the app.** Don't file an Escape bug
  from it. #451 reported that Escape left Project Settings and the exe.dev setup sheet open; Escape
  on a real keyboard closed both, and so did XCUITest's `typeKey(.escape, …)`. Check Escape with a
  real keyboard or a UI test.

## Layout

**VCS info that only the GUI needs** (e.g. the sidebar root row's current branch)
is resolved app-side in `Core/BranchResolver.swift` (per project, async, with a per-call
timeout) — deliberately NOT added to the `workroom --json` contract, which the human CLI
never shows.

`WorkroomApp/Core/` — store, CLI wrapper, terminal sessions, models, theme.
`WorkroomApp/Views/` — hand-rolled sidebar | detail | inspector split (`SidebarColumn`, `InspectorColumn`; see `RootView.splitView`) inside a detail-only `NavigationSplitView` kept for window chrome, plus the terminal detail.
`Scripts/` — `run.sh` (local), `build-helper.sh` (embeds+signs the Go binary), `release.sh`
(build → notarize → staple → DMG → EdDSA-sign for Sparkle), `appcast.sh` (publishes the Sparkle
appcast to the fixed `appcast` release), `appcast-notes.sh` (re-renders a published item's
`<description>` from the current release body — see [auto-update](../../CONTRIBUTING.md#auto-update-sparkle-appcast)), `make-icon.swift`
(regenerates the `AppIcon` PNGs in `Assets.xcassets` — run `swift Scripts/make-icon.swift`).
