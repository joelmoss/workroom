# Nightly is a separate product with its own appcast feed

Workroom Nightly is a side-by-side product (own bundle id, name, icon and CLI, `workroom-nightly`), not a runtime channel of the main app, and it reads its own Sparkle feed, `appcast-nightly.xml`, a single rolling item. Sparkle offers every untagged item to every client whatever `allowedChannels` says, so on a shared feed a stable build outran a nightly one and every Nightly user got "The update is improperly signed and could not be validated" (2026-09-10). Sparkle's bundle-id check is a backstop, not a channel filter. The nightly item is still also written to `appcast.xml` as a transitional dual write, removed once no such installs remain.

Source: [`CONTRIBUTING.md`](../../CONTRIBUTING.md) ("Release channels", "Auto-update"), [`macapp/project.yml`](../../macapp/project.yml) (`WORKROOM_APPCAST`), [`macapp/Scripts/test-invariants_test.sh`](../../macapp/Scripts/test-invariants_test.sh).
