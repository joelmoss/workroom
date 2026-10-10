# Repository Guidelines

## Project Structure & Module Organization

Workroom combines a native macOS app with a bundled, standalone Go CLI.

- `cmd/` contains Cobra commands; `internal/` owns workspace lifecycle, VCS, configuration, and scripts. Go tests sit beside sources; shared fixtures live in `testdata/`.
- `macapp/WorkroomApp/Core/` contains app services and models; `Views/` contains SwiftUI interfaces. Assets and bundled resources live under `macapp/WorkroomApp/`.
- `macapp/WorkroomAppTests/` and `WorkroomAppUITests/` contain app tests.
- `vcs/` is the Rust workspace for the `wr-agent` daemon (terminal sessions, VCS and File services) and its git read crates.
- `docs/` contains supporting documentation.

## Build, Test, and Development Commands

Run commands from the repository root; `make` lists available targets.

- `make cli-build`, `make cli-test`: build the CLI and run `go test ./...`.
- `make cli-lint`: run golangci-lint v2 and check gofmt/goimports formatting.
- `make actions-lint`: lint `.github/workflows` with actionlint, shellcheck included.
- `make app-build`: build Rust dependencies, generate the Xcode project, and build Debug.
- `make app-run`: rebuild and relaunch this checkout's Workroom Dev; stops its persisted session helpers.
- `make app-test`: run app unit/integration tests; safe alongside other workrooms' runs.
- `make app-uitest`: run XCUITest in a logged-in GUI session; it takes that session exclusively, so runs from several workrooms queue.
- `make app-test-scripts`: check packaging/helper shell scripts.
- `make app-format`, `make app-lint`: format Swift and enforce strict linting.

Use `macapp/project.yml` for project configuration; do not edit generated `.xcodeproj` files.

## Coding Style & Naming Conventions

Use gofmt/goimports for Go. Swift uses two-space indentation and a 100-column limit from `macapp/.swift-format`; name types in UpperCamelCase and members in lowerCamelCase. Follow adjacent Rust conventions and rustfmt. Keep changes focused and preserve established abstractions.

## Testing Guidelines

Go uses `testing` with `*_test.go` files and `Test…` functions. Swift uses XCTest/XCUITest with `*Tests.swift` files and `test…` methods. Run relevant tests and linters before submitting; cover changed behavior and regressions. Use temporary repositories for VCS tests. Declare app preference keys with `suite: .app` to preserve test isolation.

## Commit & Pull Request Guidelines

Use concise, descriptive commits. History commonly uses `fix(macapp): …`, `refactor(macapp): …`, and `docs(…): …`; plain imperative subjects also occur. PRs should explain behavior changes, link issues (`Fixes #177`), report validation and skipped checks, and include screenshots for visible UI changes.

## Reviews & Reported Bugs

A finding from a review, a reviewer bot or an agent is not a bug until it is checked against how the app is actually used, or could plausibly be used. Before fixing or filing it, answer three questions:

- **What triggers it?** Name the real sequence: what the user does, what the environment does, and what timing it needs.
- **How likely is that?** It needs a realistic path in ordinary use, or a failure that does happen (an outage, a quit mid-operation, a corrupt config). A race that needs a click inside one actor hop, or input the code never produces, does not qualify.
- **What does it cost when it happens?** Lost or corrupted data, a paid resource left running, a broken or misleading UI, or nothing that persists.

Fix it only when it is likely enough to happen, or costly enough when it does. Otherwise reply on the thread with that reasoning and close it. File an issue only when a future change could make it reachable. Comment wording, test-timing hypotheticals and style suggestions never justify another review round.

## Architecture & Configuration

Preserve the CLI `--json` contract; breaking changes require a `schema_version` bump in `cmd/json.go`. Read `CONTRIBUTING.md` and [repository notes](docs/repository-notes.md) for architecture and operations. For app work, also follow [macapp/AGENTS.md](macapp/AGENTS.md). Never use personal workrooms as destructive test fixtures.

## Agent skills

### Issue tracker

Issues live as GitHub issues in `joelmoss/workroom`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), used as-is. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (root `CONTEXT.md` + `docs/adr/`, created lazily). See `docs/agents/domain.md`.

## Shared Agent Instructions

Maintain instructions in `AGENTS.md` files; do not add `CLAUDE.md` files — Claude Code reads `AGENTS.md` natively, and a `CLAUDE.md` would stop it doing so. These rules apply to every coding agent. Use relevant skills when available through your agent's supported mechanism; do not assume a particular tool or slash command exists.

Repository skills live in `.agents/skills/`; `.claude/skills` links to that directory. Edit skills only in the shared location.
