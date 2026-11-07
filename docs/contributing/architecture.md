# Architecture Overview

Part of the [contributor guide](../../CONTRIBUTING.md). Who owns each area is in
[Ownership](ownership.md).

The product is the **macOS app** (`macapp/`). For workroom management (create/delete/list) it's a
SwiftUI client over **one shared engine** — the Go CLI, which it bundles and drives over a stable
`--json` contract (no cgo, no duplicated lifecycle logic). The same engine is usable standalone as
the CLI addon. VCS **reading** (history, diffs, working-copy status) is done natively in the app
through a structured core — git via SwiftGitX (libgit2) — not by scraping CLI output.

```
┌──────────────────────────────┐        ┌──────────────────────────────┐
│  macOS app (Swift / SwiftUI)  │        │   You, in a terminal          │
│  macapp/                      │        │                               │
└───────────────┬──────────────┘        └───────────────┬──────────────┘
                │  spawns bundled binary                 │  runs installed binary
                │  `workroom … --json`                   │  `workroom …`
                ▼                                         ▼
        ┌────────────────────────────────────────────────────────┐
        │                  The workroom Go engine                 │
        │  cmd/  (Cobra commands)                                 │
        │  internal/workroom/  (create / delete / list orchestr.) │
        │  internal/vcs/  ──►  Git worktrees                       │
        │  internal/config/  ──►  ~/.config/workroom/config.json   │
        │  internal/script/  ──►  setup / teardown hooks           │
        └────────────────────────────────────────────────────────┘
```

## Repository layout

```
workroom/
├── main.go                  # Entry point; injects version via ldflags, calls cmd.Execute()
├── cmd/                     # Cobra command definitions
│   ├── root.go              # Root command, global flags, Service construction
│   ├── create.go            # `workroom create` (alias c)
│   ├── list.go              # `workroom list` (aliases ls, l)
│   ├── delete.go            # `workroom delete` (alias d)
│   ├── base.go              # `workroom base set|clear` (the branch new workrooms start from)
│   ├── update.go            # `workroom update` (alias u) — CLI self-update
│   ├── version.go           # `workroom version`
│   ├── add_project.go       # Hidden; --json only; used by the app to register a project (Service.AddProject)
│   ├── delete_project.go    # Hidden; --json only; used by the app to drop a project (Service.DeleteProject)
│   ├── claim.go             # Hidden; `claim-provisioned`; used by a Dev build of the app to move its remote entries into its own config
│   ├── include_archive.go   # Hidden; `include-archive --output`; used by the app to tar a root's included files (.worktreeinclude) for a remote workroom
│   ├── json.go              # --json success/error envelope writers
│   ├── payload.go           # One typed struct per --json payload and NDJSON event; nested fields in key order, as the goldens
│   ├── jsonlog.go           # NDJSON streaming of setup/teardown output (stderr)
│   └── helpers.go           # cwd / --project resolution
├── internal/
│   ├── config/              # JSON config CRUD (atomic writes + advisory lock)
│   ├── namegen/             # Adjective-noun name generation (120 × 210)
│   ├── vcs/                 # VCS interface + Git impl + CommandExecutor (testable); Included lists a root's .worktreeinclude matches
│   ├── workroom/            # Core orchestration, prints nothing: Service.{CreateNamed,Delete,InteractiveDelete,Listing,ListData,AddProject,DeleteProject}; IncludedFiles, CopyIncluded, ArchiveIncluded
│   ├── script/              # Setup/teardown script runner (env vars + live streaming)
│   ├── ui/                  # Colored output, tables, log panels, interactive prompts (huh)
│   ├── updater/             # `workroom update`: GitHub release check + binary swap
│   └── errs/                # Shared error sentinels + machine codes + exit codes
├── macapp/                  # ★ The macOS app (SwiftUI) — the product; see macapp/AGENTS.md & macapp/README.md
├── vcs/                     # Rust workspace: the workroomd daemon + git read crates
├── scripts/workroom_setup   # This repo's own example setup hook
├── testdata/fixtures/       # Setup/teardown scripts used by Go tests
├── testdata/contracts/      # Golden --json envelopes, checked by cmd's Go tests and decoded by the app's tests
├── .github/workflows/       # CI + release + appcast automation
├── .goreleaser.yml          # CLI cross-platform build/release config
├── .golangci.yml            # Linter config
├── install.sh / install.ps1 # Standalone CLI installers
├── Makefile                 # Dev tasks: app-* (macOS app), cli-* (Go engine) and vcs-lint (Rust)
└── mk/                      # The Makefile's targets, one file per area (cli, docs, actions, vcs, app)
```

## The macOS app architecture

The app (`macapp/`, see [`macapp/AGENTS.md`](../../macapp/AGENTS.md)) is a value-based, **multi-window**
SwiftUI app. The core loop:

1. **Sidebar selection** (project / root / workroom) sets `AppStore.selectedTargetID`.
2. **Opening a target** creates a libghostty terminal surface (`GhosttySurfaceView`), keeps its tab
   in the app's `TerminalTabs` and the window's layout of it in `TerminalPanes` keyed by target, and
   renders it in the detail pane. One live terminal per
   target persists for the session.
3. **Terminal I/O** surfaces libghostty/OSC callbacks app-wide — title (OSC 0/2), command-finished
   (OSC 133), busy/progress (OSC 9;4), and notifications (OSC) drive tab/sidebar animation, badges,
   the inspector, and desktop banners. Program status (OSC 7501) is the exception: `workroomd` keeps
   it and the app subscribes to it per host ([docs/program-status.md](../program-status.md),
   [ADR 0050](../adr/0050-program-status-service.md)).
4. **VCS reading** (History, changeset/diffs, working-copy status, the sidebar's branch)
   goes through a `VCSProviding` layer: SwiftGitX (libgit2) for local Git, and `workroomd` for
   daemon-routed projects — both mapped to app-native models, no CLI text parsing.
5. **Mutations** (create/delete workroom, add/remove project) call the bundled Go CLI via
   `WorkroomCLI` (a `Process` wrapper that locates `Workroom.app/Contents/Resources/workroom`,
   overlays `PATH`, drains stdout/stderr concurrently, streams NDJSON logs, and decodes the JSON
   envelope), then update the store on success.
6. **State** splits into app-wide owners — `ProjectStore` (the one project list), `VCSStatusService`
   (branch and VCS/CI status, and the sweep), `RunCommands` (run config) and `WorkroomLifecycle`
   (the create and delete flows, what is in flight, and what they do to every window) — and a
   per-window `AppStore` (selection, terminals, splits), so multiple windows share projects but keep
   independent layouts. `WindowRegistry` tracks open windows.
7. **Preferences** live in `DefaultsKeys` (via the `Defaults` library); **auto-update** is Sparkle
   (`Updater`); **themes** load from bundled CSS theme families.

Key dependencies: **libghostty** (terminal), **SwiftGitX**
(VCS reading), **Sparkle** (update), **Sentry** (crash reporting), **Defaults** (preferences), and
the **tree-sitter** C runtime + grammars (syntax highlighting). The app is **non-sandboxed** with the
**hardened runtime** enabled (it spawns `git`/`workroom` and opens arbitrary directories), and
registers a global `⌘§` hotkey via Carbon. The embedded Go helper is built and signed during the
Xcode build by `macapp/Scripts/build-helper.sh` and placed under `Contents/Resources/` (not
`Contents/MacOS/`, to avoid a case-insensitive collision with `Workroom`).

## The Go CLI engine

This is the shared workroom-management engine the app drives (and the standalone CLI addon).
Everything routes through `cmd.Execute()` (called from `main.go`). The root command sets up the
persistent flags (`--verbose`, `--pretend`, `--json`) and `SilenceUsage`/`SilenceErrors` so Workroom
renders its own error format. Each subcommand builds a `workroom.Service` via `newService()`:

```go
// internal/workroom/workroom.go
type Service struct {
    Config          *config.Config
    VCS             vcs.VCS
    Pretend         bool
    PromptFn        PromptFunc   // interactive multi-select (huh)
    ConfirmFn       ConfirmFunc  // interactive yes/no (huh)
    Status          func(status, msg string)                       // progress steps; --verbose prints them
    ScriptOutput    func(title string) (io.Writer, func(ok bool))  // the human teardown log panel
    ScriptLogWriter io.Writer                                      // --json: NDJSON script output on stderr
    // ... plus test-injection hooks and --json wiring (OnReady)
}
```

`internal/workroom` prints nothing. Its methods return results, and `cmd/` renders them: the
`--json` envelope, or the human output (tables, log panels, success lines). Prompts reach the
user through the `PromptFn`/`ConfirmFn` hooks. In `--json` mode, `newService()` makes the interactive prompt/confirm hooks return
errors rather than block. This is how the same `Service` serves both the interactive terminal and
the GUI.

`Service` methods (`CreateNamed`, `Delete`, `InteractiveDelete`, `Listing`, `ListData`,
`AddProject`, `DeleteProject`) hold the orchestration logic and delegate VCS work to the `vcs.VCS`
interface, persistence to `config.Config`, and hook execution to `script.Run`. The human commands
wrap them in `cmd/`: `createWorkroom` in `cmd/create.go` adds the setup log panel, the success line
and the `$EDITOR` prompt; `cmd/list.go` renders `Listing`; `runDeleteHuman` in `cmd/delete.go`
renders each `DeleteResult`.

## How a workroom is created (lifecycle)

`Service.CreateNamed` (both paths; the human `workroom create` wraps it in `createWorkroom`):

1. **Guard:** reject if the cwd is already a workroom (presence of a `.Workroom` marker).
2. **Detect VCS:** `vcs.Detect(dir)` looks for `.git` and returns the `Git` impl, or `ErrUnsupportedVCS`
   (a `.jj`-only directory is unsupported; a colocated `.jj` + `.git` repo is plain Git).
3. **Generate a unique name:** try `namegen.Generate()` up to 5 times; on persistent collision,
   append a random 2-digit suffix (up to 10 more tries).
4. **Collision checks:** ensure the VCS workspace and the target directory don't already exist.
5. **Create the workspace:** `mkdir -p ~/workrooms`, then `git fetch --prune <remote>`, then
   `git worktree add --no-track -b workroom/<name> <path> <start>`. The base is the project's
   `base_branch`, else the global `base_branch` (`workroom base set [--global]`). `vcs.SplitBase`
   reads it as `<remote>/<branch>` when the part before the first `/` is a remote, else a branch on
   `origin`. The start is `refs/remotes/<remote>/<branch>` then `refs/heads/<branch>`, and an
   unresolvable base fails with `BaseBranchNotFound`. A global base that the fetched remote and the
   local branches both lack falls back to `refs/remotes/origin/HEAD` with a warning, fetching origin
   only if it was not the remote already fetched. A base that could not be fetched never falls back. Without a base, the remote is `origin`,
   `git remote set-head origin --auto` runs after the fetch, and the start is
   `refs/remotes/origin/HEAD`.
   A failed fetch keeps the last fetched refs and returns a warning in `CreateResult.Warning`, and so
   does a base that origin lacks when the local branch is used instead.
   With no usable start, the command has no start point and no `--no-track`, so git uses `HEAD`, or
   makes an orphan branch in a repository with no commits.
   `Git.Create` reports this as two steps through `vcs.Progress` (`Service.OnStep`, and each
   `$ git …` line and its output to `ScriptLogWriter`), which `create --json` streams as `step` and
   `log` events for the app's creation checklist. `fetch` owns the start point: it ends `skipped`
   with no remote, `warning` with the warning above, and `failed` when the base is found nowhere;
   `worktree` covers `git worktree add`.
   Between the two, `vcs.Progress.BeforeWorktree` hands the start point to the **trust check**
   (#363, ADR 0054): `Service.SetupScriptAt` reads the base commit's `scripts/workroom_setup` with
   `git cat-file --filters` (else the root's copy) and `gate` lets it through when its SHA-256 is the
   project's `trusted_scripts` entry, or the root's copy is gitignored. Otherwise `ApproveScriptFn`
   (a terminal's y/n) is asked, and without one the create ends with `ScriptNotTrusted` (exit 3)
   before anything exists. A create stopped there by a question (`ScriptNotTrusted`, or
   `LocalWorkLeftOut` from `--start ask`) is a `vcs.QuestionError`, and its `--json` envelope reports
   `start_commit`, the commit its start point resolved to. The app answers by running `create` again
   with the hidden `--start-commit <sha>` (`Service.StartCommit`, ADR 0059): that create fetches
   nothing, emits no `fetch` step and starts from the pinned commit, or fails with
   `StartCommitUnusable` (exit 3) when the commit is no longer on the start point's ref.
6. **Persist:** `config.AddWorkroom(...)` records `{path}` under the project, keyed by project path,
   with the VCS type.
7. **Signal readiness:** fire `OnReady` (the `created` event: the app gives the creation pane it
   opened on the click the workroom's name, and keeps showing its checklist) before the potentially
   slow setup script runs.
8. **Run setup:** if `scripts/workroom_setup` exists in the new workroom, else in the root project,
   `script.Run("setup", …)` executes it inside the new workroom with the
   [environment variables](../../docs-site/pages/reference/environment-variables.md), streaming combined
   stdout/stderr live, as the `script` step (`skipped` when there is no script). The file is hashed
   and gated again first, where it is, so bytes that changed since step 5 never run.

Creation is **not transactional**: if setup fails, the workspace and config entry already exist, so
the returned `CreateResult` is populated even on error — callers can report "created, but setup
failed" and offer cleanup.

## How a workroom is deleted (lifecycle)

`Service.Delete` → `deleteByName`:

1. **Guard + validate** the name against `^[a-zA-Z0-9]([a-zA-Z0-9_-]*[a-zA-Z0-9])?$`.
2. **Confirm** (interactively, or via a matching `--confirm <name>` value).
3. **Run teardown:** if `scripts/workroom_teardown` exists in the workroom, else in the root project,
   run it inside the workroom (streaming). A teardown that fails, or can't be started, stops the
   delete there (exit 5, `TeardownScriptFailed`), leaving the workroom and its config entry.
   `--skip-teardown` (`Service.SkipTeardown`, the app's Delete Anyway) skips the script and says so.
   Before it runs, the file is gated as setup is (#363): an unapproved one stops the delete with
   nothing removed (`ScriptNotTrusted`, exit 3) unless a terminal approves it. On a remote workroom
   the app reads the host's copy and asks the CLI to judge it (`trust status --stdin`) before
   `workroomd run-script`, for setup and teardown alike.
4. **Remove the workspace:** `git worktree remove <path> --force` (this also removes the directory).
   **The branch is intentionally left intact.**
5. **Update config:** remove the workroom entry. The project stays registered even with no
   workrooms left: the config is shared with the app, whose sidebar keeps empty projects.

## VCS abstraction

`internal/vcs` hides the VCS behind one interface (Git is the only implementation):

```go
type VCS interface {
    Type() Type                                  // "git"
    Label() string                               // human label
    WorkroomExists(dir, name string) (bool, error)
    Create(dir, vcsName, path string) (string, error)
    Delete(dir, vcsName, path string) (string, error)
    ListWorkrooms(dir string) ([]string, error)
}
```

All shell-outs go through a `CommandExecutor` (`RealExecutor` in production, a mock in tests), which
makes the orchestration fully unit-testable without touching a real repo. `vcs.Detect` is used when
creating/deleting (it touches the filesystem); `vcs.New(type)` reconstructs a VCS from the stored
config type string for listing, without requiring the project directory to exist.

## The config file

`~/.config/workroom/config.json` is the single source of truth, shared by the CLI and the app. Set
`$WORKROOM_CONFIG` to use another file instead. A Dev build of the app does this, so it keeps its own
config. Shape:

```json
{
  "workrooms_dir": "~/workrooms",
  "/Users/you/dev/myapp": {
    "vcs": "git",
    "workrooms": {
      "swift-meadow": { "path": "/Users/you/workrooms/swift-meadow" },
      "calm-harbor":  { "path": "/Users/you/workrooms/calm-harbor" }
    }
  }
}
```

- Top-level keys are **canonical, symlink-resolved absolute project paths** (so the same project via
  a symlink or trailing slash maps to one entry). `workrooms_dir` is a reserved key.
- A project or workroom entry can also carry a **`host`** object, which marks a workroom as living
  on another machine. The app owns its schema. The CLI only checks whether a workroom has one and
  whether its `state` is `"destroyed"` (`Workroom.IsRemote` and `Workroom.HostDestroyed` in
  `internal/config/config.go`), and every config write must keep it. ADR 0032 (no remote project)
  and ADR 0040 (deleting a remote workroom is app-only) record the rules the CLI enforces.
- Writes are **atomic** (write to a temp file, `fsync`, then `rename`) so a concurrent reader never
  sees a partial file.
- Read-modify-write cycles are guarded by a **best-effort cross-process advisory lock**
  (`config.json.lock`) so the standalone CLI and the app's bundled binary don't clobber each other;
  it is an OS advisory lock (`gofrs/flock`: `flock(2)` on Unix, `LockFileEx` on Windows) that the kernel releases when its holder dies, so nothing is
  stolen on a timer, and it degrades to running unlocked on any lock trouble or after a 30s backstop
  rather than failing.

The CLI's machine-readable `--json` envelope — the contract the app drives the engine over — is
documented in the docs' [JSON output page](../../docs-site/pages/reference/json-output.md).
