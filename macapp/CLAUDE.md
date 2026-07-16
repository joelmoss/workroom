# macapp/CLAUDE.md

The Workroom macOS app: a SwiftUI (macOS 15+) front-end that bundles the `workroom`
Go binary and drives it over the CLI's `--json` contract. See README.md for full
architecture, signing, and notarization detail — this file is the quick reference.

## Dev tasks (Makefile)

Every dev task runs through the **repo-root `Makefile`**, namespaced `app-*` (run from the repo
root, not `macapp/`):

```bash
make app-run        # canonical local loop: xcodegen → xcodebuild (Debug) → relaunch
make app-build      # xcodegen → xcodebuild (Debug)
make app-test       # xcodebuild test (WorkroomAppTests)
make app-generate   # force-regenerate the (gitignored) .xcodeproj from project.yml
make app-vcs        # build the Rust VCS core → WrVcs SwiftPM package (auto-run before app builds)
make app-format     # swift-format, rewrite sources in place
make app-lint       # swift-format --strict (non-zero on any violation — the hard gate)
make app-release    # Release build → notarize → staple → DMG installer (Scripts/release.sh)
make app-icon       # regenerate AppIcon PNGs (Scripts/make-icon.swift)
make app-clean      # remove DerivedData + .xcodeproj
```

Builds reuse `macapp/DerivedData/` so the Swift packages (incl. the GhosttyKit xcframework)
aren't re-resolved/re-downloaded every build. (`cli-*` targets cover the Go CLI — see the root
CLAUDE.md.)

## VCS core (Rust jj + SwiftGitX git)

Workroom reads VCS data through **two backends behind one Swift layer** (the app is growing into a
VCS-first IDE — issue #59 is the first brick):

- **jj → Rust `jj-lib` via UniFFI.** The `vcs/` Rust workspace (jj-only) builds a static xcframework
  + generated Swift into the local SwiftPM package `vcs/swift/WrVcs` — the app does `import WrVcs`.
- **git → SwiftGitX (libgit2), pure Swift.** git has a mature native Swift path; jj has none — so
  only jj needs the Rust/UniFFI bridge. (An all-Rust core with gix was tried and dropped: gix bought
  no real unification and libgit2 is the more complete git engine.)

**Read surface & routing.** `Core/VCSProviding.swift` is the one Swift protocol; `VCS.provider(for:)`
routes by repo kind. `RustJJProvider` maps `WrVcs.*` → app-native models, `GitProvider` wraps
SwiftGitX. `WorkroomStatusResolver` and `BranchResolver` read through this layer — **the jj CLI
parsers are gone** (log/changeset/currentRef/workingStatus are all native jj-lib).

**The one mutating read: `RustJJProvider.workingStatus`.** jj's working copy is itself a commit, so
on-disk edits don't exist to jj-lib until snapshotted — a working-copy status read therefore *must*
snapshot `@` first: it takes the working-copy lock and rewrites `@` (modeled on jayjay's
`refresh_working_copy`). Everything else (log/changeset/currentRef) is a read-only `load_at_head`
with no lock. Because it mutates, **only test snapshot changes on throwaway repos** (corruption
risk). Line counts still come from one `jj diff --stat` CLI call in `resolveJJ` — the native read
omits the delta on purpose (a line count would materialize every file). Cargo coverage:
`vcs/crates/wr-vcs-core/tests/working_status.rs`; Swift coverage: `WorkroomStatusIntegrationTests.testJJ*`.

`make app-vcs` (→ `vcs/scripts/build-apple.sh`) builds the Rust artifacts and **runs automatically
before `app-build`/`app-test`/`app-generate`** (a Makefile prerequisite). Requirements:

- **`protoc`** on PATH (`brew install protobuf`) — a build-time dep of jj-lib.
- arm64 by default; **`make app-release` builds universal** (`VCS_APPLE_FLAGS=--universal`), which
  needs **rustup `stable` ≥ 1.93** + `rustup target add x86_64-apple-darwin aarch64-apple-darwin`
  (Homebrew's rust can't cross-compile; the script preflights this and errors clearly).

The xcframework + generated Swift are **gitignored and regenerated**; only `Package.swift` + a
`shim.c` are tracked. Packaging note: the xcframework is **library-only** (no headers) and the FFI
Clang module (`wr_vcs_uniffiFFI`) is a separate SPM C target — a headers-bearing static xcframework
copies its `module.modulemap` into the shared `Debug/include/` and collides with GhosttyKit's
("Multiple commands produce include/module.modulemap").

## Formatting & linting

Swift is formatted/linted with **swift-format** (bundled with the Xcode toolchain — run via
`xcrun swift-format`, no install). Config `macapp/.swift-format` (2-space, 100 cols) covers
`WorkroomApp/` + `WorkroomAppTests/` only (not the `Scripts/*.swift` tools). Use `make app-format`
/ `make app-lint`. Every Xcode/`xcodebuild` build also runs a `swift-format lint` pre-build phase
that surfaces violations as **warnings** (non-fatal — `make app-lint` is the hard gate). Run
`make app-format` before committing.

## Gotchas

- **The Swift module is `Workroom`** (the target is `WorkroomApp`; `PRODUCT_MODULE_NAME` is pinned
  to `Workroom` in `project.yml`). Tests use `@testable import Workroom`. The pin matters because
  `PRODUCT_NAME` is **per-config**: `Workroom` for Release, `Workroom Dev` for Debug (see below) —
  without the pin the Debug module would become `Workroom_Dev` and break the import. A test
  target's `TEST_HOST` must point at the Debug product (`Workroom Dev.app/Contents/MacOS/Workroom
  Dev`); XcodeGen's auto-derived (target-name-based) host is wrong and fails with "Could not find
  test host".
- **Debug builds run side by side with the release build.** The Debug config has a distinct
  identity — bundle id `com.developwithstyle.workroom.dev`, product/display name `Workroom Dev`,
  and the amber `AppIcon-Dev` icon set — so a local build doesn't fight the installed release
  `Workroom` for activation, the key window, preferences (separate UserDefaults domain via the
  bundle id), or the system-wide ⌘§ hotkey. The Debug build deliberately **doesn't register ⌘§**
  and **doesn't run Sparkle scheduled checks** (`#if DEBUG` in `WorkroomApp.swift` / `Updater.swift`)
  so it can't grab the global hotkey or try to "update" itself to the release DMG. Both builds
  still share the CLI config at `~/.config/workroom/config.json` (the bundled CLI has no
  config-path override), so they show the same projects/workrooms. `make app-run` only kills the
  `Workroom Dev` instance, never your release build. The two app icons (`make app-icon` renders
  both) are identical except for the tile gradient.
- **Adding/removing/renaming a `.swift` file needs an `xcodegen generate`.** XcodeGen
  expands the source glob into explicit file refs in the (gitignored) `.xcodeproj`, so
  the change is invisible (or, for a deleted/renamed file, a hard "Build input file
  cannot be found" error) until the project is regenerated. The `make app-*` build
  targets now run `xcodegen generate` every time, so this is handled automatically —
  it only bites when building from Xcode directly (regenerate, or run `make app-generate`).
- **SourceKit "Cannot find type X in scope" is usually noise.** The single-file indexer
  doesn't see sibling files; a clean `xcodebuild` is authoritative.
- **The terminal is libghostty** (`libghostty-spm`'s `GhosttyKit` xcframework, pinned
  `exactVersion: 1.2.3` in project.yml). The embedding C API is not yet stable, so pin EXACT —
  don't float it. The terminal surface (`Core/GhosttySurfaceView.swift`) + runtime
  (`GhosttyApp`/`GhosttyRuntimeAdapter`) are ours; the bundled `Resources/ghostty` (terminfo +
  shell-integration) must ship for the engine to start. Pre-GA, the plan is to move to a
  self-built xcframework from a pinned Ghostty fork.
- **Menu enable/disable must flow through `focusedSceneValue` + `@FocusedValue`**
  (see `WorkroomApp.swift`); a `Commands` body does not re-evaluate when the shared
  `AppStore` mutates. ⌘1–9 are handled by an `NSEvent` local monitor in `AppDelegate`,
  not menu items, so they fire before the terminal swallows the keys.

## Layout

**VCS info that only the GUI needs** (e.g. the sidebar root row's current branch/bookmark)
is resolved app-side in `Core/BranchResolver.swift` (per project, async, with a per-call
timeout) — deliberately NOT added to the `workroom --json` contract, which the human CLI
never shows.

`WorkroomApp/Core/` — store, CLI wrapper, terminal sessions, models, theme.
`WorkroomApp/Views/` — `NavigationSplitView` tree sidebar + terminal detail.
`Scripts/` — `run.sh` (local), `build-helper.sh` (embeds+signs the Go binary), `release.sh`
(build → notarize → staple → DMG → EdDSA-sign for Sparkle), `appcast.sh` (publishes the Sparkle
appcast to the fixed `appcast` release), `appcast-notes.sh` (re-renders a published item's
`<description>` from the current release body — see "Auto-update" below), `make-icon.swift`
(regenerates the `AppIcon` PNGs in `Assets.xcassets` — run `swift Scripts/make-icon.swift`).

## Auto-update (Sparkle)

`Core/Updater.swift` wraps Sparkle's `SPUStandardUpdaterController` (the "Check for Updates…"
menu item + the Settings toggle bind to it). The `SU*` keys in `project.yml` (`SUFeedURL`,
`SUPublicEDKey`, `SUEnableAutomaticChecks`) configure it. **Versioning is tag-driven** —
`CFBundleShortVersionString`/`CFBundleVersion` resolve from `$(MARKETING_VERSION)`/
`$(CURRENT_PROJECT_VERSION)`, which `release.sh` injects from the git tag (build number =
commit count, so it only ever increases — Sparkle compares it). The appcast feed is an asset
on the fixed `appcast` GitHub release. See `README.md` ("Auto-update") for the one-time keypair
setup and the `SPARKLE_PRIVATE_KEY` secret.

**Release channels (issue #91) — two build identities.** The **main** app (`Release` config)
switches `stable`⟷`pre` at runtime via the *Settings ▸ General ▸ Release channel* picker
(`ReleaseChannel.pickerCases` = stable/pre only). **Workroom Nightly** is a separate side-by-side
product — the `Nightly` build config in `project.yml` (bundle id `…workroom.nightly`, name, violet
`AppIcon-Nightly`, `WORKROOM_RELEASE_CHANNEL=nightly` → the `WorkroomReleaseChannel` Info.plist
marker read by `ReleaseChannel.current`/`isNightlyBuild`), extending the Debug/"Workroom Dev"
per-config identity pattern to a third identity.

`Updater.allowedChannels(for:)` returns `{nightly}` on the nightly build and the picked stable/pre
floor otherwise; one appcast feed carries all channels (`Scripts/appcast.sh` tags items via the
shared `Scripts/channel-helper.sh`; stable stays untagged = Sparkle default), and Sparkle's
bundle-id check stops either identity installing the other's DMG. Nightly is a single **rolling**
item; appcast idempotency keys on `(channel, build)`. `build-helper.sh` bakes both
`-X main.version=$(MARKETING_VERSION)` and `-X main.channel=$(WORKROOM_RELEASE_CHANNEL)` into the
bundled CLI, and `CommandLineInstaller` symlinks it as `workroom` (main) or `workroom-nightly`
(nightly build) so both coexist in PATH. `Updater.migrateReleaseChannelIfNeeded` opts an upgrading
beta user into `pre` and coerces a legacy `.nightly` selection to `.stable` (main build only).

**Release-notes in the update dialog.** Sparkle's dialog renders the appcast item's
`<description>`. `appcast.sh` (run during the release) embeds the GitHub release body as that
description — but at release time the body is still goreleaser's raw commit list, since the
curated notes are written afterwards. So a second path keeps them in sync: the
`.github/workflows/appcast-notes.yml` workflow fires on every `release: edited` event and runs
`Scripts/appcast-notes.sh`, which re-renders the matching item's `<description>` from the
release's *current* body. Curating a release's notes therefore auto-refreshes what the update
dialog shows; no rebuild needed. To fix an already-published feed by hand, run it directly:
`TAG=vX.Y.Z REPO=owner/repo GH_TOKEN=$(gh auth token) macapp/Scripts/appcast-notes.sh`.
