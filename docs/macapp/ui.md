# App menus, keyboard handling and layout

Paths beginning `Core/`, `Views/` and `Scripts/` are relative to `macapp/`.
For user-facing wording, follow [app copy](../app-copy.md).

- **Menu enable/disable must flow through `focusedSceneValue` + `@FocusedValue`**
  (see `App/FocusedValues.swift` and `App/Menus/WorkroomCommands.swift`); a `Commands` body does not re-evaluate when the shared
  `AppStore` mutates. ⌘1–9 are handled by an `NSEvent` local monitor in `AppDelegate`,
  not menu items, so they fire before the terminal swallows the keys.

- **⌥Tab / ⌃Tab (the quick switchers, issue #132) are monitor-only and deliberately NOT in
  `GhosttySurfaceView.isAppShortcut`.** That list is static, but whether the app owns Tab depends on
  runtime state: a workroom with one pane has nothing to switch to, so ⌃Tab is left to the terminal,
  where Ghostty's default `next_tab` binding consumes it (#555 keeps it that way). The
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
is resolved app-side in `Core/WorkroomManagement/BranchResolver.swift` (per project, async, with a per-call
timeout) — deliberately NOT added to the `workroom --json` contract, which the human CLI
never shows.

`WorkroomApp/Core/` — store, CLI wrapper, terminal sessions, models, theme.
`WorkroomApp/Views/` — hand-rolled sidebar | detail | inspector split (`SidebarColumn`, `InspectorColumn`; see `RootView.splitView`) inside a detail-only `NavigationSplitView` kept for window chrome, plus the terminal detail.
`Scripts/` — `run.sh` (local), `build-helper.sh` (embeds+signs the Go binary), `release.sh`
(build → notarize → staple → DMG → EdDSA-sign for Sparkle), `appcast.sh` (publishes the Sparkle
appcast to the fixed `appcast` release), `appcast-notes.sh` (re-renders a published item's
`<description>` from the current release body — see [auto-update](../contributing/releasing.md#auto-update-sparkle-appcast)), `make-icon.swift`
(regenerates the `AppIcon` PNGs in `Assets.xcassets` — run `swift Scripts/make-icon.swift`).

## App design tokens

The Mac app's spacing, radii, type roles and shared components live in the `DesignSystem`
package (`Packages/DesignSystem`), beside the theme colours (`ThemeTokens`). `DESIGN.md` is the
web brand and does not apply to the app.

| Token | Values (pt) |
| --- | --- |
| `Spacing` | `xxs` 2, `xs` 4, `s` 6, `m` 8, `l` 12, `xl` 16, `xxl` 20 (a sheet's padding), `xxxl` 24 |
| `Radius` | `xs` 5 (small hover wells), `s` 6 (rows, picker rows), `m` 8 (cards, fields), `l` 12 (toasts) |

`FontRole` names what text is for: `title` (a sheet's title, `.headline`), `body` (`.callout`),
`detail` (`.footnote`), `noticeTitle` and `noticeBody` (an inline notice), `headerGlyph` (a sheet
header's 30pt glyph) and `messageGlyph` (an empty pane's glyph, `.title2`).

A token replaces a literal only where the value is the same. A value the scale lacks stays a
literal: never round a view's metric to fit the scale. Many views still use literals; convert
them when you touch them.

Everything reads the theme from the environment; roots inject it. Views and the `DesignSystem`
components read `@Environment(\.themeTokens) private var tokens`, not `ThemeService.shared`, and
no component takes the theme as an argument. `DesignSystem` declares the key, with the system
palette (`ThemeTokens(preview: nil)`) as its default. Every SwiftUI root injects the live theme
with `themeTokensRoot()`: each scene's root view and every `NSHostingView` or
`NSHostingController` (the environment does not cross one). A `.sheet` or `.popover` takes no
root of its own: it inherits the theme from the view that presents it, and repaints on a switch
while open. A view needs no `.themeDidChange` observer to repaint either. `ThemeRepaintTests`
measures both. A tree a root is missing from draws the native palette and never sees a switch.
A hosted test that renders a themed view injects a root too, as production does.
`ThemeService.shared` stays for AppKit drawing, for picking a theme, and for `generation`, which
keys the syntax highlighting.

Shared components:

- `MessageState`: an empty or failed pane, centred. `InlineMessage`: the one-line version at the
  top of a list.
- `SheetHeader` and `WarningHeader`: a sheet's 30pt glyph beside its title column.
- `SheetFooter`: Cancel (Escape) then the sheet's primary button, which takes
  `sheetDefaultAction()` to answer Return.
- `Notice`: an inline warning panel. `WarningLabel`: a one-line warning. `WarningGlyph`: the
  warning triangle alone, for a row or field.
- `RowHighlight`: a source list's selected and hover fill. `pickerRowChrome`: a picker row's fill
  and ring.
