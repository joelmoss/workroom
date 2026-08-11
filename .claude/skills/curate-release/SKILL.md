---
name: curate-release
description: Workroom's tag-driven release process — channel architecture (stable/pre vs the side-by-side Nightly build), keeping the channel-classification logic in lockstep across Go/Swift/shell, and curating GitHub release notes after a tag publishes.
---

Tag-driven (see README "Releases"). After a release publishes, **curate its GitHub release
notes** — replace GoReleaser's raw commit list with a succinct, themed summary in the style of
`v2.0.0-beta.1` (a headline, a one-line framing, and grouped bullets). The commit list is what
the git log is for.

**Release channels** (issue #91) ship as **two products**. The **main** product (`workroom` CLI +
"Workroom" app) tracks `stable` or `pre`, chosen at runtime (`workroom update --channel stable|pre`;
the app's Settings picker). **Nightly** is a **separate side-by-side install** — a `workroom-nightly`
binary (baked `-X main.channel=nightly`) and a distinct "Workroom Nightly" app (`Nightly` build
config in `project.yml`: bundle id `…workroom.nightly`, `AppIcon-Nightly`, `WorkroomReleaseChannel`
Info.plist marker). Channel is a runtime pref for stable/pre, a build identity for nightly, so
nothing can drift/collide (the main binary rejects `--channel nightly`).

Canonical tag→channel classification is `internal/channel` (Go), mirrored by
`macapp/WorkroomApp/Core/ReleaseChannel.swift` and `macapp/Scripts/channel-helper.sh` — **keep the
three in lockstep**. The updater selects per channel (stable = `/releases/latest` for byte-parity;
pre = `/releases` list, newest stable-or-prerelease; nightly = the fixed `nightly` release by tag),
orders nightlies by the monotonic commit-count and everything else by semver, and verifies against
`checksums.txt`. Nightly is a scheduled build (`.github/workflows/nightly.yml`, daily cron;
`CONFIGURATION=Nightly make app-release`) on a fixed `nightly` prerelease; all appcast-writing
workflows share a `concurrency: appcast-feed` group.
