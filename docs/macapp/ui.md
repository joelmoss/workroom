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
  trigger modifiers are shortcuts in the registry (Last-Used Workroom / Last-Used Pane, recorded as
  modifiers + Tab in Settings ▸ Keyboard Shortcuts, #148, ADR 0076) because a global-shortcut grabber
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
`Scripts/` — `run.sh` (local), `build-daemon.sh` (embeds+signs the one `workroom` binary), `release.sh`
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

A main-window surface paints its solid theme fill through `ThemeFill` (`.panel`, `.background`,
`.raised`), never a `panel`/`bg`/`surface` token directly: the window background
(`ThemeFill.panel.nsColor()`), the detail column, the activity bar, the footer, pane title bars,
pane cards, the sidebar card, the inspector split's headers and the creation pane. It is a
`ShapeStyle` that resolves against `\.themeTokens`, so it goes wherever a token did
(`.background(ThemeFill.panel)`, `Rectangle().fill(ThemeFill.background)`). It is the one place
Glass (#725) changes how those fills draw. Dialog overlays, sheets, onboarding and the Settings
window stay opaque, so they paint their tokens directly.

Glass is one slider (Settings → Appearance), 70–100% in 5% stops, with no separate toggle: 100%
(the default, which reads "Off") is opaque, and below it the window frosts at that opacity. It is
decided in one place, `GlassResolver.resolve(opacity:reduceTransparency:fullScreen:)`, which
quantizes the setting (`GlassResolver.quantize`: rounded to the whole percent, clamped to
`GlassResolver.opacityRange`) and returns a `GlassAppearance`, `.opaque` or `.glass(opacity:)`;
100%, Reduce transparency and full screen are all opaque. `GlassService.shared` keeps the app-wide
inputs live: the `glassOpacity` default, quantized, as the observable `opacity` (assigned only when
it changes, so a drag invalidates the window roots once per percent), and Reduce transparency. The
Settings readout shows that `opacity`. Every window
that hosts terminals (the main window, the Quick Terminal, each detached pane) has one
`GlassWindowRoot`, which resolves against that window's own full-screen state and injects the result as
`\.glassAppearance`, which `ThemeFill` reads; like `\.themeTokens`, a hosted tree forwards it
(`TitlebarAccessoryHost`). Under glass every pixel carries one tint. The window is non-opaque and
its own background is the window base, the theme `bg` at the slider's opacity
(`WindowBackgroundThemer.baseColor`), under the title bar and everything else; the window server
blurs what is behind it (`WindowBlur`, the private `CGSSetWindowBackgroundBlurRadius` resolved at
runtime, ADR 0080), a pure blur with no tint of its own. `WindowBackgroundThemer.apply` is
idempotent: it makes that call and re-cuts the shadow only when the window turns glass or opaque,
and an opacity change sets the background colour alone. A window the window server hasn't numbered
yet stays opaque until the next apply, so it turns glass with its blur. A detached pane's normal title bar turns
transparent under glass so the base shows through it; the Quick Terminal's is already. Nothing else
tints at the opacity: `.background` and `.ground` draw nothing, `.panel` is the panel wash
(`tokens.panelWash`, the foreground at `tokens.panelWashAlpha`, the alpha derived from
`tokens.panel` so the wash over the base is the panel colour in every theme; not a fixed 5.5%,
which drew dark-theme cards darker than the panel), `.raised` is unchanged, `.nestedRaised` (a raised wash inside a host
that already lays one) and `.textBackground` draw nothing, and a selected tab takes
`tokens.tabActive` because the base already is `bg` (`ThemeFill.tab(active:hovered:)`, shared by
the workroom tab bar and the terminal tab strip). A panel inside a panel uses `.ground`, so the wash
never doubles. AppKit views take `nsFill`, nil where the fill draws nothing, and turn their own
`drawsBackground` off on it. The terminals'
generated Ghostty config has `background-opacity = 0` under glass, whatever the opacity, so their
default background is the window base; cells with a background of their own, and the selection,
still draw it (`background-opacity-cells` stays off). Glass leaves `minimum-contrast` out of that config, since Ghostty
measures it against the default background premultiplied by its alpha (black at 0) and would turn a
light theme's dark text white; instead each of palette 0–15 and the foreground under 3:1 on the
theme's background is overridden with a legible colour (`GhosttyApp.glassContrastOverrides`, made
with `ThemeTokens.legible`, from the preview `ThemeService` already resolved for its tokens). Opaque
keeps `minimum-contrast = 3.0`. That is the one config every terminal draws, in every window: each
terminal lies on `ThemeFill.background` (`View.terminalBase`, in the pane leaf), which is clear in a
glass window and the opaque `tokens.bg` in a window that resolves opaque under glass (full screen),
so there the terminal shows the opaque theme background it would have drawn. With the whole app
opaque the config has no `background-opacity` and the terminal draws its own background over that
fill, as before Glass. A sheet that hosts a terminal (exe.dev sign-up) lays `tokens.bg` itself. Only the slider crossing
100% (or Reduce transparency) rewrites that config, through the theme's reload; an opacity change
within glass does not touch it, and only recolours each window's base, each percent of a slider
drag, from the observable `GlassService.opacity`, with no throttle. Add no behind-window blur view, and never write Ghostty's
`background-blur`.
The chrome (the docked sidebar, the inspector card, the activity bar, footers, the pane status
bar) draws through
`ChromeBackground`, the one place its Glass rules live: the window frame (title bar, gutters, the
docked sidebar, the activity bar and window footer, `.bar`) is one colour, the bare base under
glass; the cards (`.card`) are the panel wash over it; and
a floating card (`.floatingCard`, the edge-reveal sidebar) lays the base again under its wash, so the
terminals do not show through it. A workroom's tab strip and pane header have no background of
their own, Glass on or off: the pane card's raised fill is under them. No blur material, since a
material over the window blur stacks into near-opacity, and no Liquid Glass, whose clear style
paints a pale frost of its own.

The AppKit text views (`CodeTextView`, `LogTextView`, `MarkdownWebView`) read the appearance from
`context.environment.glassAppearance`; an opaque host (the script approval sheet, `ScriptCodeView`)
sets it to `.opaque`, so it never frosts. Under glass `CodeTextView`'s scroll views, text view and
gutter draw no fill, and neither does a SwiftUI wrapper behind them: the base under them already is
the theme background. The diff's added and removed line tints draw over it unchanged, and its
header strip is the panel wash. The Markdown page paints no background, and WebKit's under-page
colour is `ThemeFill.background`.

The pane views (everything under `Views/Terminal` but `TargetTerminalDetail`, the content panes, the
coding-agent views, the title bar's controls and the toasts) ask their window through
`@Environment(\.paneHost)`, a `PaneHost`, not `@EnvironmentObject AppStore`: the Quick Terminal's
and a detached pane's windows inject no store. Only main-window chrome may take the store from the
environment, and `DetachedPaneEnvironmentTests` lists those types. Every root that renders pane
views injects a host with `.paneHost(_:)`, as it injects the theme; reading it with none traps, as
a missing environment object does. Other views that
leave the store (the History and Changes panels, the toasts, the creation pane, the status bar) take
a value read model and an `Actions` struct, built by a small `<Name>Adapter` view beside them that
reads the store, so Observation stays where the view's reads were.
The sidebar's rows go further: each is an Equatable view of a value model behind a gated adapter, so a
change elsewhere in the store re-runs no row, and the selection, drag and run state are leaves that
read their own. The sidebar mounts only the view its switcher shows (`SidebarViewSwitcher`, ADR
0083), so the hidden view's rows never run; the switcher reads the selection, and each tab's
attention dot is a leaf of its own. The Open Tabs view's list is its rows' adapter: it rebuilds `openTabsLayout()` (its
rows as the Group by choice lays them out) on any change, and each project header, workroom and tab
row compares its whole value model (`OpenTabsProjectRowModel`, `OpenTabsWorkroomRowModel`,
`OpenTabsTabRowModel`, which holds the tab's `OpenTabsTabContext`), so only the rows whose model changed
re-run; a tab row's menu is a modifier of its own, so its reads stay out of the row. A `.contextMenu` closure is lazy (a re-rendering row does not build its menu), so the
workroom menu's adapter and store reads need no gate.

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
