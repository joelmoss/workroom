# Link raw GhosttyKit, pin it exactly, and do not build the xcframework ourselves

The app links libghostty's raw C API (the `GhosttyKit` product) and rolls its own terminal surface view instead of using the higher-level `GhosttyTerminal` wrapper. The embedding API is not yet stable, so the package version is pinned exactly. On 2026-09-03 we decided against owning the xcframework build: it would mean a patch stack, Zig in CI, universal builds and regenerated terminfo for every bump, and an exact pin already leaves no passive supply-chain exposure. The check sits on the bump gate instead (diff the patches, confirm the sha resolves to a tag). The package version is not the ghostty version, so read the comment in `project.yml` before bumping.

Source: [`macapp/project.yml`](../../macapp/project.yml) (the `libghostty` package comment and its `exactVersion`), [`macapp/AGENTS.md`](../../macapp/AGENTS.md) ("The terminal is libghostty").
