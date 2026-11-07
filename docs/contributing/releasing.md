# Deployment & Releases

Part of the [contributor guide](../../CONTRIBUTING.md). After a release publishes, use the
curate-release skill when your agent has it.

There is no server to deploy — Workroom is a desktop app plus a CLI distributed through **GitHub
Releases**. "Deployment" here means cutting a release: GitHub Actions builds and publishes both
components automatically when you push a version tag.

## Continuous integration

For a background watcher that reports check transitions and failures promptly, see
[PR watching](../agents/pr-watching.md), including the separate review checks before merge.

`.github/workflows/ci.yml` runs on every push to `master` or a `release/**` maintenance branch,
and every PR against either. It calls one workflow per language, each holding that language's jobs:
`ci-actions.yml` (`workflows`), `ci-go.yml` (`cli`), `ci-rust.yml` (`rust`,
`daemon-terminal-state`, `daemon-linux`), `ci-app.yml` (`app-packages`, `app`, `app-scripts`) and
`ci-docs.yml` (`docs-deploy`, master pushes only). Each check is named `<call> / <job>`, such as
`app / app`.

A push runs every job, and skips the `changes` job. On a PR, `changes` reads the diff and skips
the jobs it does not need, so a Go-only change runs no macOS job. The rules are in
`scripts/ci/changed_areas.py`: each path runs the jobs whose tests or build read it, a path no rule
names runs every job, and a skipped job still reports, as skipped. When a test starts reading a
file outside its own tree, add that path to the rules. Those rules are also the source of truth for
the local pre-gate: `test_changed_areas.py` fails when `.gstack/pregate.json` has no lane for a
tree they send to a job. `test_tool_pins.py` fails when the Zig, cargo-zigbuild or Rust pins
disagree between `mk/vcs.mk`, the composite actions and the workflows. The build steps the three workflows share (Xcode, Go and Homebrew; Zig, the rustup
targets and cargo-zigbuild; the signing certificate) are composite actions under
`.github/actions/`.

- **`workflows` job** (`ubuntu-latest`): `make actions-lint`, `make app-scripts-lint`, the
  `scripts/ci/` tests and `daemon-name_test.sh`. Never skipped.
- **`cli` job** (`ubuntu-latest`): sets up Go from `go.mod`, runs `golangci-lint` (subsumes `go vet`
  / `gofmt`), `go build`, and `go test ./...`.
- **`rust` job** (`ubuntu-latest`): `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo doc` with
  `RUSTDOCFLAGS="-D warnings"`, and `cargo test` for the whole `vcs/` Rust workspace, on a pinned
  toolchain. `make vcs-lint` runs the same format, lint and doc checks locally, plus the
  `daemon-terminal-state` job's clippy pass and a `terminal-state` doc check CI does not run.
- **`app-packages` job** (`xcode-27`): sets up Xcode 27.1 and runs `make app-package-test`, the local
  Swift packages' own `swift test` suites, beside `app` rather than ahead of its build.
- **`app` job** (`xcode-27`): sets up Xcode 27.1 + Go, `brew install xcodegen`, runs `make app-lint`
  (swift-format `--strict`), restores the sources' mtimes to their landing times (`macapp/Scripts/restore-mtime.py`,
  so the cached build dir rebuilds only what changed since the checkout it was built from), then
  `make app-test` with **ad-hoc signing** flags (hosted runners have no signing cert), e.g.:

  ```
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=
  ```

  It also runs the few Rust tests that only mean something on macOS: `workroomd`'s `pty::tests`
  and its stale-socket relay tests. macOS sets a new socket's close-on-exec flag in a second call,
  and those tests cover what a child spawned in between inherits. Everything else in Rust stays on
  the `rust` job.

## Cutting a release

Releases are **tag-driven**. Push a `v*` tag and `.github/workflows/release.yml` does the rest:

```bash
git tag v1.4.0
git push origin v1.4.0
```

A clean `vX.Y.Z` tag publishes as a normal ("Latest") release; a tag with a prerelease component
(e.g. `v2.0.0-beta.1`, `v1.4.0-rc1`) is auto-marked as a GitHub **pre-release** so it never becomes
"Latest" (GoReleaser `prerelease: auto`).

You can test the CLI build locally with [GoReleaser](https://goreleaser.com/) before tagging
(produces binaries in `dist/` without publishing):

```bash
goreleaser build --snapshot --clean
```

**After a release publishes, curate its GitHub release notes** — replace GoReleaser's raw commit
list with a succinct, themed summary (a headline, a one-line framing, and grouped bullets). Editing
the release notes also triggers `appcast-notes.yml`, which re-renders the Sparkle update dialog's
notes from your curated body.

## Patch releases

`master` is always the **next minor**. Patches to an already-released line ship from a maintenance
branch, so shipping `v2.0.1` never means holding back what's landed on master.

Branch **lazily** — only when the first patch is actually needed, never eagerly at each minor:

```bash
git branch release/2.0 v2.0.0
git push -u origin release/2.0
```

Land the fix on `master` first, then carry it over and tag:

```bash
git checkout release/2.0
git cherry-pick -x <sha>          # -x records the source commit in the message
git push
# CI runs on the branch; once green:
git tag v2.0.1 && git push origin v2.0.1
```

`release.yml` triggers on `push: tags: v*` with no branch filter, so a tag on a release branch cuts
a real release exactly like one on master — nothing to configure.

**Cherry-pick, never merge back.** Merging `release/2.0` into `master` would make `v2.0.1`
reachable from master, and the nightly's `git describe` would then compute its base off a patch tag
that has nothing to do with master's line. Fixes flow master → release branch, one way.

**One caveat if you ever patch an *old* minor** (tagging `v2.0.1` after `v2.1.0` has shipped):
GitHub's `/releases/latest` picks the most recent non-prerelease by **creation date**, not semver,
so `v2.0.1` would become "Latest" and the stable updater — which reads `/releases/latest` for
byte-parity with the download page — would offer 2.1 users a downgrade. If that becomes a real
workflow, the stable updater needs to move to the `pre` channel's list-and-max-semver path.
Patching only the newest released line (the normal case) is unaffected.

## Release channels

Channels are delivered as **two products**, not one switchable install:

- **Main product** — one install (the `workroom` CLI and the "Workroom" app) that tracks **stable**
  or **pre**, chosen at runtime (`workroom update --channel stable|pre`, or the app's *Settings ▸
  About ▸ Release channel*). Mutually exclusive; no side-by-side.
- **Nightly product** — a **separate download** (the `workroom-nightly` CLI and a distinct "Workroom
  Nightly" app: own bundle id `…workroom.nightly`, name, violet icon) pinned to nightly, running
  **alongside** the main install (and the Debug "Workroom Dev" build). Channel here is a *build
  identity*, not a runtime preference, so nothing can drift or collide.

| Channel | Source | Appcast tagging | Delivered as |
| --- | --- | --- | --- |
| `stable` | clean `vX.Y.Z` tags (master, or a `release/X.Y` branch) | untagged (Sparkle default — everyone) | main app / `workroom` |
| `pre` | `vX.Y.Z-beta.N` / `-rc` / `-alpha` tags | `<sparkle:channel>pre</sparkle:channel>` | main app / `workroom` |
| `nightly` | daily build off `master` | `<sparkle:channel>nightly</sparkle:channel>` | Workroom Nightly / `workroom-nightly` |

`stable` and `pre` fall out of the normal tag-driven release above. **Nightly** is a scheduled
build — `.github/workflows/nightly.yml` runs on a daily cron (and `workflow_dispatch`), building the
`Nightly` configuration ("Workroom Nightly" app) and baking `-X main.channel=nightly` into the CLI
archives. It's hosted on a single fixed **`nightly`** prerelease whose assets and appcast item are
clobbered in place each run (no per-day tags accumulate). Its version is
`<base>-nightly.<commit-count>`, where `<base>` is derived from the latest tag reachable from
master — a prerelease tag targets its own release (`v2.0.0-rc.1` → `2.0.0`), a stable tag bumps the
**minor** (`v2.0.0` → `2.1.0`) because master is the next minor and patches ship from a
`release/X.Y` branch. The commit count is the monotonic key the CLI and Sparkle order nightlies
by. A no-new-commits guard skips a run when nothing changed, and the release title (the version) is
stamped only after assets + appcast publish succeed, so a partial run retries.

Two appcast feeds: `appcast.xml` carries stable + pre for the main app (whose `allowedChannels` is
the picked stable/pre floor), and `appcast-nightly.xml` carries the single rolling nightly item.
They are separate because Sparkle offers every *untagged* item to every client whatever
`allowedChannels` says, so one shared feed offered the nightly app the main DMG — see
[Auto-update](#auto-update-sparkle-appcast) for the failure it caused. Sparkle's bundle-id check
still backstops a cross-product install, but it is a backstop, not the channel filter.

The canonical tag → channel classification lives in **`internal/channel`** (Go), mirrored by
`macapp/WorkroomApp/Core/AppShell/ReleaseChannel.swift` and `macapp/Scripts/channel-helper.sh` — keep the
three in sync. All appcast-writing workflows (`release`, `nightly`, `appcast-notes`) share a
`concurrency: appcast-feed` group so they can't
clobber each other's `appcast.xml` edits.

## Required CI secrets

The CLI release needs only the default `GITHUB_TOKEN`. The macOS app release (the `macapp` job) needs
Apple signing/notarization credentials (plus optional Sparkle/Sentry):

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PWD` | Password for the `.p12` |
| `KEYCHAIN_PASSWORD` | Password for the temporary build keychain |
| `NOTARY_KEY` | Base64-encoded App Store Connect API key (`.p8`) |
| `NOTARY_KEY_ID` | App Store Connect API key ID |
| `NOTARY_ISSUER_ID` | App Store Connect issuer ID |
| `SPARKLE_PRIVATE_KEY` | _(optional)_ EdDSA key to sign the DMG for the appcast |
| `SENTRY_AUTH_TOKEN` / `SENTRY_ORG` / `SENTRY_PROJECT` | _(optional)_ dSYM upload to Sentry |

> If the notarization job fails with a `403` / "agreement missing or expired", that's an Apple
> account gate — accept the latest agreement at developer.apple.com, then `gh run rerun <id> --failed`.

## Release artifacts

Each release publishes both components:

| Artifact | Pattern | Example |
| --- | --- | --- |
| CLI archive (macOS/Linux) | `workroom_<version>_<os>_<arch>.tar.gz` | `workroom_1.4.0_darwin_arm64.tar.gz` |
| CLI archive (Windows) | `workroom_<version>_windows_<arch>.zip` | `workroom_1.4.0_windows_amd64.zip` |
| macOS app installer | `workroom-macos-app_<version>.dmg` | `workroom-macos-app_1.4.0.dmg` |
| Nightly CLI archive | `workroom_nightly_<os>_<arch>.<ext>` | `workroom_nightly_linux_amd64.tar.gz` |
| Nightly app installer | `workroom-macos-app_nightly.dmg` | (clobbered on the fixed `nightly` release) |
| Sparkle feed (main app) | `appcast.xml` | published to a fixed `appcast` release |
| Sparkle feed (Nightly app) | `appcast-nightly.xml` | same `appcast` release, single rolling item |

Nightly asset names are **version-independent** (the fixed `nightly` release clobbers them each
run, so download URLs stay stable). `workroom update` on the stable/pre channels resolves the exact
asset URL from the GitHub API rather than constructing it, so those don't share the name-lockstep
constraint below; the constructed path is still used by `install.sh` and the nightly channel.

GoReleaser builds the CLI for `darwin`/`linux`/`windows` × `amd64`/`arm64` with
`CGO_ENABLED=0` and `-s -w -X main.version=<tag>`. The archive name (`workroom_<version>_…`) is what
`install.sh` and `internal/updater/updater.go` download, so the GoReleaser `name_template` and those
two paths must stay in lockstep — a rename in one without the others breaks `curl | sh` and
`workroom update`.

## The macOS app release pipeline

The `macapp` job runs `make app-release` (`macapp/Scripts/release.sh`) on `xcode-27` with Xcode 27.1:

1. `xcodegen generate`, then `xcodebuild archive` with `MARKETING_VERSION` from the tag and
   `CURRENT_PROJECT_VERSION` from the commit count (a monotonic build number for Sparkle).
2. `exportArchive` with Developer ID signing (re-signs nested helpers, including the embedded Go CLI).
3. _(optional)_ upload dSYMs to Sentry.
4. Verify signatures, then **notarize** the app (`xcrun notarytool submit --wait`), **staple** the
   ticket, and run a Gatekeeper assessment (`spctl`).
5. Build the DMG (`create-dmg`, signed), notarize + staple the DMG too.
6. _(optional)_ EdDSA-sign the DMG for Sparkle and write `appcast-fields.env`.
7. Upload the DMG to the release as `workroom-macos-app_<version>.dmg`.

## Auto-update (Sparkle appcast)

Existing app installs update themselves via [Sparkle](https://sparkle-project.org). After the DMG is
published, `macapp/Scripts/appcast.sh` merges a new `<item>` (version, build number, minimum system
version, download URL, EdDSA signature, release notes) into `appcast.xml` and uploads it to a fixed
`appcast` GitHub release that serves as the feed. When you later curate the GitHub release notes,
`.github/workflows/appcast-notes.yml` re-renders that item's `<description>` so the in-app update
dialog shows the polished notes instead of raw commits.

**Channels.** `appcast.xml` carries stable and pre: `appcast.sh` tags each item with
`<sparkle:channel>pre</sparkle:channel>` (stable items stay untagged), and the **main app** reads
`Updater.allowedChannels(for:)` = the picked stable/pre floor (from *Settings ▸ About ▸ Release
channel*). Sparkle only offers items whose channel is allowed, and the untagged/default channel is
always allowed, which gives the nested stable ⊂ pre model for free. Pre/GA items are appended and
idempotent on `(channel, build)`.

**Workroom Nightly reads a separate feed**, `appcast-nightly.xml` — a single rolling item, rewritten
whole each run so its enclosure signature never goes stale. It gets its own feed precisely *because*
the untagged/default channel is always allowed: on the shared feed, `allowedChannels = {nightly}`
did not stop Sparkle offering a Nightly install the main Workroom DMG, and it happened as soon as a
stable build number outran the newest nightly item — v2.0.0 (build 769) against nightly 767 on
2026-09-10. Sparkle then refused the download at the code-signing check, because the two apps carry
different bundle identifiers by design, and every Nightly user saw *"The update is improperly signed
and could not be validated."* That check is a backstop, not a channel filter; separate feeds are
what actually keeps the two products apart. The feed URL is per-configuration:
`project.yml` templates `SUFeedURL` on `$(WORKROOM_APPCAST)`, which the `Nightly` config overrides.
`Scripts/test-invariants_test.sh` pins all three halves.

The nightly item is *also* still written into `appcast.xml`, so installs predating the split can
reach a build that knows the new URL; drop that dual write once none remain. The app's channel is
separate from the CLI's `workroom update` channel — the app is Sparkle-managed, the standalone CLI
self-updates.

**Upgrade migration (main app).** New installs default to `stable`. But since the app has only ever
shipped betas, an existing user upgrading into the channel-aware build would otherwise be defaulted
to `stable` and stop receiving betas until GA. So on first launch, if the channel preference is unset
*and* the running build is a prerelease, `Updater` opts the user into `pre` — preserving their
existing beta update stream. A legacy `nightly` selection (the first-pass picker briefly offered it)
is coerced to `stable`, since nightly is now the separate Workroom Nightly product. Fresh/stable
installs are untouched; the nightly build skips migration entirely (its channel is fixed).
