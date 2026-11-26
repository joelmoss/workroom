# Ownership

Part of the [contributor guide](../../CONTRIBUTING.md). Each row is an area one person can change,
build and test without the others: a context from [`CONTEXT.md`](../../CONTEXT.md) in the app, a
package, or a Rust crate or module. The gate column is the narrowest check that covers it.

Every row's owner is `joelmoss` today, because [`.github/CODEOWNERS`](../../.github/CODEOWNERS) has
one catch-all rule (`* @joelmoss`). Naming someone else on a row is the owner's call. So is copying
rows into `CODEOWNERS`, which would make GitHub request that person's review on every PR touching
the path.

## macOS app: contexts

Model and view stay in separate trees (`Core/` and `Views/`), one folder per context in each, so a
context is two folders. `DaemonConnection` and `Testing` have no views. The tests in
`macapp/WorkroomAppTests/` are one flat folder; run a context's classes with
`make app-test APP_TEST_FLAGS="-only-testing:WorkroomAppTests/<Class>"`.

| Path (under `macapp/WorkroomApp/`) | Context | Owner |
| --- | --- | --- |
| `Core/AppShell/`, `Views/AppShell/` | App shell: windows, `AppStore`, menus, settings, updates | `joelmoss` |
| `Core/WorkroomManagement/`, `Views/WorkroomManagement/` | Workroom management: projects, create and delete, scripts | `joelmoss` |
| `Core/VersionControl/`, `Views/VersionControl/` | Version control: history, changesets, diffs, status | `joelmoss` |
| `Core/Terminal/`, `Views/Terminal/` | Terminal: tabs, splits, panes, sessions, run commands | `joelmoss` |
| `Core/RemoteHosts/`, `Views/RemoteHosts/` | Remote hosts: drivers in the app, provisioning, setup sheets | `joelmoss` |
| `Core/CodingAgents/`, `Views/CodingAgents/` | Coding agents: Claude and Codex runs, usage, failure diagnosis | `joelmoss` |
| `Core/DaemonConnection/` | The app's side of the daemon (`workroom serve`) | `joelmoss` |
| `Core/Testing/` | The UI-test fixture | `joelmoss` |

## macOS app: local packages

Each package builds and tests alone with `swift test --package-path macapp/Packages/<Name>`;
`make app-package-test` runs them all.

| Path | What it holds | Owner |
| --- | --- | --- |
| `macapp/Packages/WorkroomDomain/` | Shared models, such as `HostDescriptor`, `HostKind`, `PaneLayout` | `joelmoss` |
| `macapp/Packages/WorkroomVCS/` | VCS protocols and models: `LocalVCSProviding`, `WorkroomStatus` | `joelmoss` |
| `macapp/Packages/WorkroomGit/` | The local git engine: `GitProvider`, over libgit2's C API | `joelmoss` |
| `macapp/Packages/WorkroomWire/` | The session wire format | `joelmoss` |
| `macapp/Packages/WorkroomSystem/` | Processes, shells, sockets and timeouts | `joelmoss` |
| `macapp/Packages/DaemonConnection/` | The client for the daemon (`workroom serve`) | `joelmoss` |
| `macapp/Packages/HostDrivers/` | Container, boxd, exe.dev and SSH drivers | `joelmoss` |
| `macapp/Packages/DevContainer/` | `devcontainer.json` reading and setup | `joelmoss` |
| `macapp/Packages/DesignSystem/` | `ThemeTokens` and shared UI | `joelmoss` |
| `macapp/Packages/SyntaxHighlighting/` | tree-sitter highlighting | `joelmoss` |
| `macapp/Packages/TerminalModel/` | `PaneState` and its rules, `TargetPanes`, `TerminalLaunch` | `joelmoss` |

## Rust: the CLI and the daemon

Gate: `make vcs-lint`, and `make vcs-test VCS_TEST_FLAGS="-p <crate>"` for one crate. A change to the
CLI also runs `make contract-test`, and a change to a command or flag `make docs-cli`.

| Path | What it holds | Owner |
| --- | --- | --- |
| `vcs/crates/workroomd/src/commands/` | The CLI's commands, its `--json` envelopes, config, channels and `update` | `joelmoss` |
| `vcs/crates/workroomd/` | The rest of the `workroom` binary: the daemon, its terminal sessions and services | `joelmoss` |
| `vcs/crates/workroomd/tests/docs_site.rs` | The `docs-site/` format check | `joelmoss` |
| `vcs/crates/wr-protocol/` | The wire envelope and per-service frames | `joelmoss` |
| `vcs/crates/wr-vcs-git/` | Daemon-side git reads | `joelmoss` |
| `vcs/crates/wr-vcs-model/` | VCS domain types served as JSON | `joelmoss` |
| `vcs/crates/wr-exec/` | Supervised child processes | `joelmoss` |
| `vcs/crates/ghostty-vt/` | libghostty-vt bindings for the shadow terminal | `joelmoss` |

## Shared paths

A change here can break more than one area, so it needs the gates of each area that reads it.

| Path | Read by | Owner |
| --- | --- | --- |
| `testdata/contracts/` | The CLI's `--json` goldens (the contract suite), decoded by the app's tests | `joelmoss` |
| `testdata/twins/`, `testdata/channel_cases.tsv` | The cross-language twin fixtures (Swift, Rust and shell tests) | `joelmoss` |
| `macapp/project.yml`, `macapp/Scripts/` | The app build and its packaging | `joelmoss` |
| `Makefile`, `mk/` | Every local gate | `joelmoss` |
| `.github/` | CI, release and nightly workflows | `joelmoss` |
| `docs-site/` | The user docs; read by Rust and app tests | `joelmoss` |
