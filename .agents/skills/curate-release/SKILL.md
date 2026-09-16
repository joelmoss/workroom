---
name: curate-release
description: Workroom's tag-driven release process — channel architecture (stable/pre vs the side-by-side Nightly build), keeping the channel-classification logic in lockstep across Go/Swift/shell, and curating GitHub release notes after a tag publishes.
---

Tag-driven (see README "Releases"). After a release publishes, **curate its GitHub release
notes** — replace GoReleaser's raw commit list with a succinct, themed summary in the style of
`v2.0.0-beta.1` (a headline, a one-line framing, and grouped bullets). The commit list is what
the git log is for.

**Never hard-wrap paragraph or bullet text at a fixed column.** Write each paragraph and each
bullet as one unbroken line, however long. The in-app "What's New" viewer renders a literal `\n`
as a line break instead of reflowing it, so a source line wrapped at ~90 cols shows up as a
sentence broken mid-clause. Markdown block structure (headers, blank lines between paragraphs,
`-` bullets, blockquotes) is unaffected — only the wrapping *within* a block must go.

**Release channels** (issue #91) ship as **two products**. The **main** product (`workroom` CLI +
"Workroom" app) tracks `stable` or `pre`, chosen at runtime (`workroom update --channel stable|pre`;
the app's Settings picker). **Nightly** is a **separate side-by-side install** — a `workroom-nightly`
binary (baked `-X main.channel=nightly`) and a distinct "Workroom Nightly" app (`Nightly` build
config in `project.yml`: bundle id `…workroom.nightly`, `AppIcon-Nightly`, `WorkroomReleaseChannel`
Info.plist marker). Channel is a runtime pref for stable/pre, a build identity for nightly, so
nothing can drift/collide (the main binary rejects `--channel nightly`).

**Branching.** `master` is always the next minor; patch releases come off a lazily-cut
`release/X.Y` branch (`git branch release/2.0 v2.0.0`), fixes **cherry-picked** from master, never
merged back — release-branch tags must stay unreachable from master or the nightly's `git describe`
base goes wrong. `release.yml` has no branch filter, so a tag on a release branch just works. CI
covers `release/**`. Full runbook: CONTRIBUTING "Patch releases", including the one open caveat
(patching an *old* minor makes it GitHub's "Latest" by creation date and misleads the stable
updater).

Canonical tag→channel classification is `internal/channel` (Go), mirrored by
`macapp/WorkroomApp/Core/ReleaseChannel.swift` and `macapp/Scripts/channel-helper.sh` — **keep the
three in lockstep**. **Two Sparkle feeds**, both assets on the fixed `appcast` release: `appcast.xml` (stable + pre)
and `appcast-nightly.xml` (one rolling item). Nightly needs its own because Sparkle offers every
UNTAGGED item to every client whatever `allowedChannels` says — on the shared feed a Nightly
install was offered the main DMG the moment a stable build number outran the newest nightly item,
then failed Sparkle's code-signing check ("improperly signed"). `SUFeedURL` is templated on
`$(WORKROOM_APPCAST)`, overridden by the `Nightly` config; `Scripts/test-invariants_test.sh` pins
it. Do NOT collapse the feeds back together.

The updater selects per channel (stable = `/releases/latest` for byte-parity;
pre = `/releases` list, newest stable-or-prerelease; nightly = the fixed `nightly` release by tag),
orders nightlies by the monotonic commit-count and everything else by semver, and verifies against
`checksums.txt`. Nightly's version base is next-**minor** off the latest tag reachable from master
(a stable `v2.0.0` → `2.1.0-nightly.N`), so it can never sort below a `v2.0.1` cut on a release
branch. Nightly is a scheduled build (`.github/workflows/nightly.yml`, daily cron;
`CONFIGURATION=Nightly make app-release`) on a fixed `nightly` prerelease; all appcast-writing
workflows share a `concurrency: appcast-feed` group.
