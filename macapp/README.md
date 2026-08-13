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
make app-test-scripts # shell-script tests (build-helper architectures, channel classification)
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

The helper is built **once per architecture in `ARCHS` and `lipo`'d**, so a universal app
carries a universal CLI. That is asserted, not assumed: `release.sh` refuses to notarize a
bundle containing any thin Mach-O, and `Scripts/build-helper_test.sh` covers the arch
matrix. It shipped wrong once — `ARCHS` is a space-separated list, was matched as a single
token, and every release up to `v2.0.0-beta.23` embedded an arm64-only CLI inside a fat app,
which broke every workroom operation on Intel while passing codesign and notarization.

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

The update dialog renders each item's `<description>`, which holds the GitHub release notes.
Because those notes are curated *after* the release publishes (the release ships with goreleaser's
raw commit list), the `appcast-notes` workflow re-renders the matching item's `<description>` from
the release's current body on every `release: edited` event — so editing a release's notes
refreshes the in-app changelog automatically. Fix a published feed by hand with
`TAG=vX.Y.Z REPO=owner/repo GH_TOKEN=$(gh auth token) Scripts/appcast-notes.sh`.

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
- `Core/SessionSnapshot.swift` / `SessionStore.swift` / `SessionCoordinator.swift` — the saved
  session (issue #46): open panels, split layouts, selection and window frames, restored on the next
  launch. Stored as
  `~/Library/Application Support/Workroom/<bundle id>/session.json` — scoped by bundle id so
  Workroom, Workroom Dev and Workroom Nightly never restore each other's windows. Deleting that file
  is always safe: the app then launches as it would on a fresh install. Ordinary workroom shells
  reattach via `workroom-session` when background sessions are on (the default). A pane whose
  session is gone still opens a fresh shell in its remembered directory. Run tabs are
  deliberately never restored.
- `Core/AgentSessionIndex.swift` / `AgentResumeCoordinator.swift` — the offer to reopen an agent
  conversation in a restored pane (issue #145). Because libghostty exposes no child pid, the app
  cannot know what a pane was running; it instead reads each agent's own store (`~/.claude/projects`,
  `~/.codex/sessions`) and matches on the working directory those files **record**, never on a
  reconstructed directory name. Nothing spawns at launch: clicking *Resume Claude…* types the
  agent's own picker command into that pane, once, and only while the pane is still pristine. The
  scan is bounded (files, bytes, wall clock) and is never awaited by the restore, because issue
  #46's watchdog freezes session writes if a restore is still outstanding 15 seconds in.

## Things to verify on first build (marked `TODO` in code)

1. **libghostty pin**: `libghostty-spm`'s `GhosttyKit` xcframework, pinned EXACT because the
   embedding C API is not yet stable. `project.yml` is the single source of truth for the package
   version and the ghostty engine it's built from — don't restate them here. ✓ the app builds + links.
2. **Terminal teardown** (`TerminalSessions` → `GhosttySurfaceView.tearDown`): ✓ frees the
   surface via `ghostty_surface_free` (callbacks cleared first). Still worth a runtime check:
   switch/delete workrooms repeatedly and confirm no orphaned shells in `ps`.
3. **Signing/notarization**: ✓ configured (Developer ID for Release, team B898J443L9;
   helpers signed by `Scripts/build-helper.sh` and `Scripts/embed-session-helper.sh`). Run `Scripts/release.sh` to build + notarize
   + staple + package the DMG installer (after the one-time `notarytool store-credentials`
   above). See "Signing & distribution".
4. **Process-group kill** (`WorkroomCLI.run`): the MVP uses `terminate()` + non-interactive
   git env; a full group-kill of git/jj grandchildren would need a `posix_spawn` launch.
