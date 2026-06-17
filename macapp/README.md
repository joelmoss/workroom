# Workroom — macOS app

A native SwiftUI app that manages projects and their workrooms and opens a built-in
terminal (libghostty) in each. It integrates the `workroom` Go CLI by **bundling the
binary** and shelling out over its `--json` contract — no cgo, no duplicated logic.

> Status: **builds clean.** `xcodegen generate` + `xcodebuild` compiles the app and links
> the libghostty xcframework with zero warnings in our sources, embeds + (ad-hoc) signs the Go helper,
> and the helper speaks the `--json` contract. Runtime behaviour (terminals, mutations,
> shell reaping) still wants hands-on QA in Xcode. The CLI contract is unit-tested in
> the parent Go module.

## Prerequisites

- Xcode 15+ (macOS 14+ deployment target)
- Go (to build the embedded helper) — must be on `PATH`, or edit `Scripts/build-helper.sh`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

> **Runtime (not build):** the inspector's pull-request / CI section shells out to the GitHub CLI.
> It needs **`gh` ≥ 2.57.0** on `PATH` and an authenticated active account — the auth probe uses
> `gh auth status --active`, and `--active` landed in gh 2.57.0 (issue #50).

## Build & run

```bash
cd macapp
xcodegen generate          # writes WorkroomApp.xcodeproj (gitignored) from project.yml
open WorkroomApp.xcodeproj  # then ⌘R in Xcode
```

Or use the repo-root Makefile — the single entry point for every dev task, with the app
namespaced under `app-*` (run from the **repo root**):

```bash
make app-run        # xcodegen (if needed) → xcodebuild (Debug) → relaunch the app
make app-build      # build only
make app-test       # run WorkroomAppTests
make app-format     # swift-format, rewrite sources in place
make app-lint       # swift-format --strict
make app-generate   # force-regenerate the .xcodeproj
make app-release    # notarized Release build + DMG installer (see below)
```

> **Adding a source file?** Run `make app-generate` first. XcodeGen expands the `WorkroomApp/`
> source glob into explicit file references in the (gitignored) `.xcodeproj`, so a newly added
> `.swift` file stays invisible to Xcode and `xcodebuild` until the project is regenerated.
> (`make app-run`/`make app-build` only regenerate when the `.xcodeproj` is missing, so
> regenerate by hand after adding files.)

Xcode resolves the libghostty-spm Swift Package, and the `Build & embed workroom helper`
script phase (`Scripts/build-helper.sh`) compiles the Go CLI into
`Workroom.app/Contents/Resources/workroom` and signs it. (Resources, not
`Contents/MacOS`: a helper named `workroom` there would collide with the `Workroom`
app executable on the case-insensitive filesystem.)

## Signing & distribution

The project is configured for team **B898J443L9**:
- **Debug** (`⌘R`): automatic signing with your *Apple Development* cert.
- **Release**: manual signing with *Developer ID Application*, hardened runtime, secure
  timestamp. `Scripts/build-helper.sh` signs the embedded helper the same way before the
  app's final signature.

To produce a notarized, stapled `Workroom.dmg` installer (the app inside is notarized +
stapled too), first install `create-dmg` and store notary credentials once (app-specific
password from appleid.apple.com — not your Apple ID password):

```bash
brew install create-dmg
xcrun notarytool store-credentials "workroom-notary" \
    --apple-id "you@example.com" --team-id B898J443L9 --password "abcd-efgh-ijkl-mnop"
```

Then:

```bash
make app-release   # Release build → notarize → staple → drag-to-Applications DMG (Scripts/release.sh)
```

CI authenticates notarytool with an App Store Connect API key instead of the keychain
profile — set `NOTARY_KEY_PATH` (a `.p8`), `NOTARY_KEY_ID`, and `NOTARY_ISSUER_ID` and the
script uses those automatically.

Prefer not to use XcodeGen? Create a SwiftUI macOS App target manually, add the
libghostty-spm package, add the `WorkroomApp/` sources, and add `Scripts/build-helper.sh`
as a Run Script phase **after Compile Sources**.

## Auto-update (Sparkle)

The app self-updates via [Sparkle](https://sparkle-project.org): it polls an *appcast* feed and
installs newer, EdDSA-signed DMGs. Wiring lives in `Core/Updater.swift` (the "Check for
Updates…" menu item and the Settings toggle); the `SU*` keys in `project.yml` set the feed URL,
the public key, and automatic checks (on by default). The update artifact is the same notarized
DMG we ship, signed with an Ed25519 key whose **public** half is embedded as `SUPublicEDKey`.

The appcast is hosted as `appcast.xml` on a fixed **`appcast`** GitHub release
(`…/releases/download/appcast/appcast.xml`); each `v*` release appends an item to it via
`Scripts/appcast.sh`. Versioning is tag-driven: `release.sh` sets `CFBundleShortVersionString`
from the tag and `CFBundleVersion` to the commit count (monotonic, so Sparkle always sees a newer
release as an upgrade).

**One-time setup:**

```bash
# Generate the EdDSA keypair (stores the private key in your login Keychain, prints the public).
DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys      # after a build resolves Sparkle
# → paste the printed public key into project.yml's SUPublicEDKey, then regenerate: make app-generate

# Export the private key and add it as the GitHub Actions secret SPARKLE_PRIVATE_KEY:
…/bin/generate_keys -x sparkle_private_key.txt   # add file contents as the secret, then delete it
```

Until `SUPublicEDKey` is filled in and `SPARKLE_PRIVATE_KEY` is set, the app still builds and
ships — `release.sh` just skips appcast signing (no auto-update yet). The first Sparkle-enabled
release is a baseline; auto-update kicks in for the release after it. **Never delete the
`appcast` release** — old installs poll its URL forever.

## Architecture

- `WorkroomApp.swift` — `@main`; sets `PATH` at launch so the helper/terminals find git/jj.
- `Core/WorkroomCLI.swift` — `Process` wrapper over the bundled binary: locates it in the
  bundle, overlays `PATH` onto the inherited env, drains stdout/stderr concurrently,
  enforces per-command timeouts, and decodes the JSON envelope (`ok` / `error.kind`).
- `Core/AppStore.swift` — `@MainActor` store; loads via `list --json` (config-only first,
  then `--warnings=fast`), and mutates via `add-project` / `create` / `delete`.
- `Core/TerminalSessions.swift` — caches one live terminal **per workroom** for the app
  session so switching doesn't kill running shells (decision D2).
- `Views/` — `NavigationSplitView`: projects sidebar · workroom list · terminal detail,
  with empty/error states, a destructive delete confirmation, and a detail toolbar.
- `Core/Models.swift` — `Codable` mirrors of the `--json` contract (lenient decoding).

## Things to verify on first build (marked `TODO` in code)

1. **libghostty pin** (`project.yml`): `libghostty-spm`'s `GhosttyKit` xcframework pinned to
   `exactVersion: 1.2.3`. The embedding C API is not yet stable, so pin EXACT — don't float it.
   Pre-GA: move to a self-built xcframework from a pinned Ghostty fork. ✓ the app builds + links.
2. **Terminal teardown** (`TerminalSessions` → `GhosttySurfaceView.tearDown`): ✓ frees the
   surface via `ghostty_surface_free` (callbacks cleared first). Still worth a runtime check:
   switch/delete workrooms repeatedly and confirm no orphaned shells in `ps`.
3. **Signing/notarization**: ✓ configured (Developer ID for Release, team B898J443L9;
   helper signed by `Scripts/build-helper.sh`). Run `Scripts/release.sh` to build + notarize
   + staple + package the DMG installer (after the one-time `notarytool store-credentials`
   above). See "Signing & distribution".
4. **Process-group kill** (`WorkroomCLI.run`): the MVP uses `terminate()` + non-interactive
   git env; a full group-kill of git/jj grandchildren would need a `posix_spawn` launch.
