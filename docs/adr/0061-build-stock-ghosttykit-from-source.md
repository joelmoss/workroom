# Build stock GhosttyKit from source, with no patches, for arm64 only

Decided 2026-10-30 (owner). Supersedes ADR 0001's choice not to build the xcframework. The app still links the raw C API and rolls its own surface view.

The app and the daemon both build from upstream Ghostty at one commit, `GHOSTTY_SHA` in [`vcs/scripts/build-ghostty-vt.sh`](../../vcs/scripts/build-ghostty-vt.sh). Its `--kit` mode builds `GhosttyKit.xcframework` into the same cache as `libghostty-vt`, and `project.yml`'s `preGenCommand` links the result into the local `macapp/GhosttyKit` package, because SwiftPM needs a binary target at resolve time, before any build phase runs.

We left `libghostty-spm` because a fix we needed depended on its release schedule: the CVDisplayLink wake deadlock was fixed upstream, but the package's patch stack no longer applied to that engine and its releases stayed on the old one. The costs ADR 0001 named turned out small once the patch stack went: Zig was already in CI for the daemon, the app uses only the stock C API, and a bump regenerates only what upstream changed.

We carry no patches. A fix goes in by taking an upstream commit that contains it, not by patching our build. That gives up, on purpose:

- `0014` and `0015`, so a TUI or a shell prompt can blink during a window resize.
- `0010` and `0019`, small scroll and cursor fixes, until the problems show up in real use.
- ghostty-org/ghostty#14444, the fix for the pane-close freeze (#547), until it merges upstream.

We also dropped Intel, which halves the archive to 143 MB. Every Mac build is arm64, and the appcast marks each item `<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>`, so an Intel install stays on its last version instead of downloading an app it cannot launch. That element needs Sparkle 2.9, the floor since 2026-06-24. The Linux daemons still build for both architectures (ADRs 0012, 0030).

Source: [`vcs/scripts/build-ghostty-vt.sh`](../../vcs/scripts/build-ghostty-vt.sh), [`macapp/project.yml`](../../macapp/project.yml), [`macapp/QA-libghostty.md`](../../macapp/QA-libghostty.md) §N, Lakr233/libghostty-spm#92.
