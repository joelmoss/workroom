# Repository Guidelines

## Project Structure & Module Organization

Workroom combines a native macOS app with a bundled, standalone Go CLI.

- `cmd/` contains Cobra commands; `internal/` owns workspace lifecycle, VCS, configuration, and scripts. Go tests sit beside sources; shared fixtures live in `testdata/`.
- `macapp/WorkroomApp/Core/` contains app services and models; `Views/` contains SwiftUI interfaces. Assets and bundled resources live under `macapp/WorkroomApp/`.
- `macapp/WorkroomAppTests/` and `WorkroomAppUITests/` contain app tests.
- `vcs/` is the Rust workspace for native JJ integration and session helpers, with Swift bindings under `vcs/swift/`.
- `website/` contains the website; `docs/` contains supporting documentation.

## Build, Test, and Development Commands

Run commands from the repository root; `make` lists available targets.

- `make cli-build`, `make cli-test`: build the CLI and run `go test ./...`.
- `make cli-lint`: run golangci-lint v2 and check gofmt/goimports formatting.
- `make app-build`: build Rust dependencies, generate the Xcode project, and build Debug.
- `make app-run`: rebuild and relaunch Workroom Dev; stops its persisted session helpers.
- `make app-test`: run app unit/integration tests.
- `make app-uitest`: run XCUITest in a logged-in GUI session.
- `make app-test-scripts`: check packaging/helper shell scripts.
- `make app-format`, `make app-lint`: format Swift and enforce strict linting.

Use `macapp/project.yml` for project configuration; do not edit generated `.xcodeproj` files.

## Coding Style & Naming Conventions

Use gofmt/goimports for Go. Swift uses two-space indentation and a 100-column limit from `macapp/.swift-format`; name types in UpperCamelCase and members in lowerCamelCase. Follow adjacent Rust conventions and rustfmt. Keep changes focused and preserve established abstractions.

## Testing Guidelines

Go uses `testing` with `*_test.go` files and `Test…` functions. Swift uses XCTest/XCUITest with `*Tests.swift` files and `test…` methods. Run relevant tests and linters before submitting; cover changed behavior and regressions. Use temporary repositories for VCS tests, especially JJ snapshot operations. Declare app preference keys with `suite: .app` to preserve test isolation.

## Commit & Pull Request Guidelines

Use concise, descriptive commits. History commonly uses `fix(macapp): …`, `refactor(macapp): …`, and `docs(…): …`; plain imperative subjects also occur. PRs should explain behavior changes, link issues (`Fixes #177`), report validation and skipped checks, and include screenshots for visible UI changes.

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

Maintain instructions in `AGENTS.md` files; `CLAUDE.md` files are symlinks to them. These rules apply to every coding agent. Use relevant skills when available through your agent's supported mechanism; do not assume a particular tool or slash command exists.

Repository skills live in `.agents/skills/`; `.claude/skills` links to that directory. Edit skills only in the shared location.
