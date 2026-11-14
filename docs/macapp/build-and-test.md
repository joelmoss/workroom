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
Read the release-target comment in `mk/app.mk` before changing this relationship.

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
- **UI tests in Tart guests.** `make app-uitest-vm` builds as `make app-uitest` does, then runs the
  tests in throwaway macOS guests cloned from `wr-uitest-base` (`Scripts/uitest-vm.sh`), so they
  leave the screen, pointer and keyboard alone and take no GUI lock. A Mac runs at most two macOS
  guests, so each guest holds one of two slots (`gui-lock.py vm-slot`, shared by every checkout,
  failing closed; `python3 macapp/Scripts/gui-lock.py vm-status` shows the holders). `VM_SHARDS=2`
  splits one run across both: its `-only-testing:` classes round-robin, or, with none, the whole
  suite by class. Results land in `macapp/DerivedData/Logs/TestVM/<run>/`, summarised with the usual
  `Tests:` line. Setup (tart, the base image) and measurements are in
  `docs/designs/parallel-workroom-testing.md`.

Within one workroom the build and test targets take turns, since they share its DerivedData: a second
one waits on the checkout lock and says who holds it. And
`make app-run` stops only copies of its own identity (`Scripts/stop-dev-app.sh`) — never kill the
app by name, since every workroom's app, test host and XCUITest app is called "Workroom Dev".

## Packages and build troubleshooting

- **Local packages live in `macapp/Packages/`** (`WorkroomDomain`, `WorkroomVCS`, `WorkroomGit`,
  `WorkroomWire`, `WorkroomSystem`, `DaemonConnection`, `HostDrivers`, `DevContainer`,
  `DesignSystem`, `SyntaxHighlighting`, `TerminalModel`), each in
  Swift 6 language mode with its own tests, run by `make app-package-test` rather than
  `make app-test`. A file that names a package's type imports that package itself; nothing
  re-exports one. A package depends on Foundation (AppKit and SwiftUI too, for `DesignSystem`), its
  own pins and lower packages, never on the app. `WorkroomWire` is the frozen session codec: see
  its `Package.swift` before changing it. Test fixtures that a package's tests and the app's
  hosted tests share live in a test-support library of that package, imported by tests only:
  `DaemonConnectionTestSupport` (`FakeDaemon`, `EchoServer`, `TCPClient`). It imports nothing of
  its own package, so the hosted test bundle never holds a second copy of the package's types.
  A fixture that needs its package's types can't go in such a library, so it is copied into the
  hosted test that uses it (as `ExeDevSetupTests` copies `StubExeDev`). Measured with a
  `HostDriversTestSupport` that imported `HostDrivers` (Xcode 27.2): a package the app links
  is linked into the app and the test bundle as one shared framework, but a test-support library
  is linked into WorkroomAppTests alone, so Xcode links it statically, and with it its
  same-package target dependency as that target's own object (`HostDrivers.o`). Its other
  packages' dependencies (`WorkroomSystem`) still came from the shared framework. The test bundle
  then held a second `HostDrivers`: 86 type descriptors of its own, eight classes the ObjC
  runtime reported as "implemented in both", task-locals (`ProvisioningProgress.$log`) the app
  never read, and a SIGSEGV when the framework's `ExeDevHostDriver.run` ran on an instance built
  by the test's copy. An `is`/`as?` on a value the app made still passed. To check a change to
  these libraries, `nm -U` the bundle
  (`Workroom Dev.app/Contents/PlugIns/WorkroomAppTests.xctest/Contents/MacOS/WorkroomAppTests`)
  must define no `$s<length><Module>…Mn` descriptor of a package the app links, and the test log
  must have no "is implemented in both" line.

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
