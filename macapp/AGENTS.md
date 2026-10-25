# macOS app guidelines

Use the repo-root instructions too. For user-facing wording, follow [app copy](../docs/app-copy.md);
for interface changes, follow native macOS interaction conventions.

## Build and test

- Run development commands from the repository root through `make`. Edit `macapp/project.yml`
  rather than generated Xcode projects. The Makefile owns the command inventory.
- For Swift changes: `make app-generate` after adding/removing files, then `make app-format`,
  `make app-build`, `make app-lint` and `make app-test`. Use the building-macapp skill when available.
- `make app-test` does not run local package tests; use `make app-package-test` for package changes.
  For test infrastructure or benchmark helpers, start with `make app-test-preflight`; the full
  packaging/helper gate is `make app-test-scripts`.
- Read app/UI test verdicts from the canonical `Tests:` summary and its `FAIL` lines, including
  skipped counts. Use `Scripts/test-summary.sh` for downloaded bundles; do not query xcresult by hand.
- Run builds, formatting and tests with the command sandbox disabled when they need Xcode/system
  temporary paths. See the [build reference](../docs/macapp/build-and-test.md) for red-proof,
  package boundaries, test-host/module problems and SourceKit setup.

## Isolation

- One `make app-*` at a time in this workroom: builds share its DerivedData. Other workrooms can
  run independently under their own Debug identities.
- Preserve `APP_ID_FLAGS` on every app build. Use `make app-identity` to identify this workroom's
  app. Stop only that identity through `Scripts/stop-dev-app.sh`; never kill apps by name.
- Unit tests normally hold the shared GUI lock; UI tests and focus-dependent benchmarks hold it
  exclusively. Inspect `python3 macapp/Scripts/gui-lock.py status` when waiting. Keep
  `WR_GUI_LOCK=off` for VMs, rather than bypassing another workroom's run.
- Every app preference key declares `suite: .app`. Hosted tests must use the isolated app suite.
  See the [runtime reference](../docs/macapp/runtime.md) for identity and preference mechanics.

## Session and VCS changes

For terminal-session and repository-routing changes:

- Read and quote the source supporting each load-bearing premise before building on it. When an
  unchanged classifier behaves differently, inspect the inputs both paths feed it.
- Give each fix a negative control. Name the neighbouring property it could damage (locks,
  parser state, cancellation or caller error handling) and test that property too.
- For any change under `Core/Session/`, to `VCSProviding`/`VCSWriting` routing, or under
  `vcs/crates/workroomd`, dispatch an independent adversarial reviewer. Give it the diff, intent
  and evidence gate. Re-reading your own code does not replace that pass.

The [review history](../docs/macapp/session-review-history.md) records the failures behind these
rules. Before an action on a remote host (connect, execute, script or delete), read
[host states](../docs/remote-host-states.md). A remote workroom path is not a path on this Mac.

## Find the relevant detail

Before changing or reviewing an area, read its reference:

| Area | Reference |
| --- | --- |
| VCS routing, libgit2 reads, PTYs, backend ownership, hand-off or daemon packaging | [VCS and sessions](../docs/macapp/vcs-and-sessions.md) |
| Workroom creation, provider drivers, host credentials or remote config | [Creation and remote hosts](../docs/macapp/remote-hosts.md) |
| App identity, preferences, Ghostty entry point, engine pin or child environment | [Runtime](../docs/macapp/runtime.md) |
| Menus, shortcuts, quick switchers, layout or Escape automation | [UI conventions](../docs/macapp/ui.md) |
| Skipping unchanged work, or assuming what a `ghostty_surface_*` call does | [Performance facts](../docs/macapp-perf-facts.md) |
| Release channels, versioning, Sparkle feeds or update notes | [Release process](../CONTRIBUTING.md#deployment--releases); use the curate-release skill when available |
