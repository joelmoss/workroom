---
name: building-macapp
description: Builds, tests, formats, and lints the macOS app under `macapp/` via its make targets. Use when editing Swift files in macapp/, adding or removing Swift files, or running the macapp build/test/format/lint gate. Covers `make app-generate` (xcodegen), `app-build`, `app-run`, `app-test`, `app-format`, `app-lint`, and which targets must run with the command sandbox disabled.
---

# Building the macOS app

How to build, run, format, lint, and test the macOS app under `macapp/` via its make targets.

## Steps
1. After adding or removing Swift files, run `make app-generate` first — it runs xcodegen to regenerate the Xcode project. New files are not in the build until you do this.
2. Build with `make app-build`. Launch the app with `make app-run`.
3. Format with `make app-format` — it rewrites files in place, so run it with the command sandbox DISABLED. Under the sandbox the in-place writes fail with `Operation not permitted`.
4. Lint with `make app-lint` (runs `swift-format --strict`).
5. Test with `make app-test` (xcodebuild build + run tests). Run it with the command sandbox DISABLED — xcodebuild writes to system temp (`/var/folders/.../T`), which is outside the sandbox allowlist and otherwise fails with `Operation not permitted`.

## Several workrooms at once
Other workrooms of this repo may be building and testing at the same time as you; that is supported.
- Each workroom's Debug build has its own bundle id (`make app-identity` prints it). Don't build the
  app with a bare `xcodebuild` in a workroom: it would take the project checkout's identity.
- `make app-test` runs alongside other workrooms' unit runs. `make app-uitest` needs this Mac's GUI
  session to itself, so it — and a unit run or `make app-run` that arrives meanwhile — waits,
  printing who holds it. That wait is expected; don't kill it, and don't set `WR_GUI_LOCK=off` to
  get past it (it is for runs inside a VM). `python3 macapp/Scripts/gui-lock.py status` shows who
  holds the session.
- In your own workroom run one `make app-*` target at a time; they share its DerivedData.
- Never stop the app with `pkill`/`killall` by name: every workroom's app is called "Workroom Dev".

## Pre-landing gate
Before landing macapp changes, run `make app-lint` then `make app-test` and confirm both pass.

## Order when touching Swift files
`make app-generate` (only if files were added/removed) -> `make app-format` -> `make app-build` -> `make app-lint` -> `make app-test`.
