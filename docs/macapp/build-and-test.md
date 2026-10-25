# macOS app build and test reference

Paths such as `Core/`, `Scripts/`, `Resources/` and `Packages/` are relative to `macapp/`.
Commands run from the repository root. The Makefile owns available targets and flags; use
`make` or the [contributor command table](../../CONTRIBUTING.md#available-commands-make).

## Build and validation

Use `macapp/project.yml` for configuration. Make build targets regenerate the gitignored Xcode
project; direct Xcode builds need regeneration after adding, removing or renaming Swift sources.
Builds share this checkout's `macapp/DerivedData/` and its resolved packages.

`make app-test` prints the canonical result counts and failing tests using `Scripts/test-summary.sh`.
For a downloaded CI bundle, run `sh macapp/Scripts/test-summary.sh <bundle.xcresult>` with the
command sandbox disabled. A skipped test asserted nothing.

`make red-proof FILE=… PATTERN=… TEST=<Class>[/<method>]` breaks a line, runs the selected test and
restores the source however the run ends. Break the effect under test, not setup that would make
the test fail for unrelated reasons. Run with the command sandbox disabled.

Release artifacts are gated by `app-test-scripts`. `app-release` deliberately does not depend on
Debug-hosted `app-test`; the release/nightly workflows invoke app and package tests explicitly.
Read the Makefile's release-target comment before changing this relationship.

`make app-format` rewrites the Swift paths selected by the Makefile; `make app-lint` enforces strict
formatting. The Xcode pre-build formatting warnings are non-fatal and do not replace that gate.

### Several workrooms at once

Workrooms of this repo can build, unit-test and run their dev apps at the same time
(`docs/designs/parallel-workroom-testing.md`). Two mechanisms make that safe, and both matter when
you touch the Makefile or the test launch paths:

- **One Debug identity per workroom.** In a workroom (a linked git worktree) `make` builds `com.developwithstyle.workroom.dev.wr-<name>-<hash>`
  (`Scripts/dev-identity.sh` → `WORKROOM_DEV_ID_SUFFIX` → the Debug bundle id in `project.yml`); the
  project's own checkout keeps the plain id. Everything keyed by bundle id — preferences, the
  session helpers' sockets (so its own `workroomd`), the saved session, "already running" — is then
  the workroom's own. Every xcodebuild that builds the app must pass `$(APP_ID_FLAGS)`; Xcode-driven
  builds don't, and build the plain id.
- **One GUI session per Mac.** `make app-test` runs its tests holding `Scripts/gui-lock.py` shared,
  `make app-uitest` exclusively, and only the test step is locked (`build-for-testing`, then
  `test-without-building`). A waiting run says who it is waiting for;
  `python3 macapp/Scripts/gui-lock.py status` shows the holders. `WR_GUI_LOCK=off` is for runs inside a VM.

Within one workroom it is still one `make app-*` at a time: they share its DerivedData. And
`make app-run` stops only copies of its own identity (`Scripts/stop-dev-app.sh`) — never kill the
app by name, since every workroom's app, test host and XCUITest app is called "Workroom Dev".

## Packages and build troubleshooting

- **Local packages live in `macapp/Packages/`** (`WorkroomDomain`, `WorkroomVCS`, `WorkroomWire`,
  `WorkroomSystem`, `DaemonConnection`, `HostDrivers`, `DesignSystem`, `SyntaxHighlighting`), each in
  Swift 6 language mode with its own tests, run by `make app-package-test` rather than
  `make app-test`. A file that names a package's type imports that package itself; nothing
  re-exports one. A package depends on Foundation (AppKit and SwiftUI too, for `DesignSystem`), its
  own pins and lower packages, never on the app. `WorkroomWire` is the frozen session codec: see
  its `Package.swift` before changing it.

- **The Swift module is `Workroom`** (the target is `WorkroomApp`; `PRODUCT_MODULE_NAME` is pinned
  to `Workroom` in `project.yml`). Tests use `@testable import Workroom`. The pin matters because
  `PRODUCT_NAME` is **per-config**: `Workroom` for Release, `Workroom Dev` for Debug (see below) —
  without the pin the Debug module would become `Workroom_Dev` and break the import. A test
  target's `TEST_HOST` must point at the Debug product (`Workroom Dev.app/Contents/MacOS/Workroom
  Dev`); XcodeGen's auto-derived (target-name-based) host is wrong and fails with "Could not find
  test host".

- **Adding/removing/renaming a `.swift` file needs an `xcodegen generate`.** XcodeGen
  expands the source glob into explicit file refs in the (gitignored) `.xcodeproj`, so
  the change is invisible (or, for a deleted/renamed file, a hard "Build input file
  cannot be found" error) until the project is regenerated. The `make app-*` build
  targets now run `xcodegen generate` every time, so this is handled automatically —
  it only bites when building from Xcode directly (regenerate, or run `make app-generate`).

- **SourceKit "No such module" or "Cannot find type X in scope" means no `buildServer.json`.**
  Without it the indexer sees one file at a time, with no packages; run `make app-lsp` in that
  checkout. A clean `xcodebuild` stays authoritative either way.
