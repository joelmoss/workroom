# Setup and teardown scripts on every kind of workroom

Status: built (2026-10-17), on branch `workroom/mild-spire`; reviewed with `/plan-eng-review` (below).
PR #495 (#367, `.worktreeinclude`), which this needed first, merged the same day. "As built" records
where the build differs from the plan.

Today `scripts/workroom_setup` and `scripts/workroom_teardown` run only in a local workroom. A remote
workroom (boxd, exe.dev, a Docker or Apple container) runs neither: create runs no setup on the host,
and delete destroys the host without a teardown (`CONTEXT.md:34`, ADR 0040, `remote-workrooms.md`
"Not done"). This plan runs both on every kind of workroom.

## Owner decisions (2026-10-17)

- **D1. Same behaviour on every kind of workroom, wherever possible.** Every difference left is
  listed under "What can't match", with the reason it can't.
- **D2. On by default.** Every remote create runs the project's setup script; there is no
  per-project opt-in. On a host, `WORKROOM_ROOT_PATH` and `WORKROOM_PARENT_DIR` are unset, because
  there is no root checkout there. A new `WORKROOM_HOST` says where the script runs. A script that
  requires the root path (this repo's own does) fails loudly on a host until it is guarded, and the
  release note says so and shows the guard.
- **D3. A failed teardown stops the delete and offers Delete Anyway**, on every kind of workroom.
  The workroom and its host stay so you can retry; Delete Anyway removes it without running the
  script. A host that can't be reached to run the teardown counts as a failed teardown.
- **D4. Stacked on #495.** Setup runs after #495's "Copy local files", so a gitignored file or
  script that `.worktreeinclude` copies in is there first.

## Amendments from the eng review (2026-10-17)

These override the Design sections below where they differ; each links to its record under
"Decision ledger".

- **R1, R5.** Both remote scripts run on the connection `RemoteHosts.connect` makes: it bootstraps
  the agent (replacing one older than this app, so `run-script` exists) and, on a relayed
  (container) host, installs the git credential relay, which stays until the script ends.
- **R2, R3.** A teardown runs whenever a workroom itself is destroyed. Every project-delete scope
  destroys remote machines, so each runs its remote teardowns, with a log; config-only leaves local
  worktrees on disk and runs no local teardown.
- **R4.** The delete-project sheet says, in every scope, that remote workrooms' machines are
  destroyed (after their teardown).
- **R6.** A script that can't start is a script failure (`SetupScriptFailed` /
  `TeardownScriptFailed`, exit 5), in Go and in `run-script`. Delete Anyway appears for a teardown
  failure, a timed-out delete, and a remote `Failure.teardownScriptFailed`; other delete failures
  show their sheet without it.
- **C2.** Remote setup runs before `releaseCreatingWorkroom` and before the create's connection
  closes.
- **C3.** An uploaded root script keeps its own mode.
- **C4.** Delete Anyway re-reads the project from current state, so it deletes only what is left.

## Behaviour, kind by kind

| | Local | Remote (boxd, exe.dev, containers) |
| --- | --- | --- |
| Which script | Workroom's copy, else the root's (`findScript`) | The clone's copy, else the Mac root's copy, uploaded (new) |
| Working directory | The workroom | The clone on the host |
| `WORKROOM_NAME`, `WORKROOM_PATH` | Set | Set (`WORKROOM_PATH` is the clone's path on the host) |
| `WORKROOM_ROOT_PATH`, `WORKROOM_PARENT_DIR` | Set | Unset (D2) |
| `WORKROOM_HOST` (new) | `local` | `boxd`, `exedev`, `docker`, `apple` |
| Environment | The Mac user's login shell, read by `$SHELL -ilc` with `WORKROOM_SHELL_PROBE=1`, falling back to `/etc/paths` | The host user's login shell, read the same way on the host, falling back to the agent's own environment (new) |
| Time limit | 600 s wall clock, then the whole process tree is killed | The same, on the host (new) |
| Live output | Into the "Run setup script" row | The same row (new) |
| Setup fails | The workroom stays; Open Anyway or Delete | The same; the host stays up until you choose (new) |
| Teardown fails | Delete stops; the sheet shows the reason and output; Delete Anyway (new) | The same (new) |
| Teardown's output | Error sheet, reason above a scrolling log (1f6dcbbf) | The same (new) |

### What can't match

- **No root checkout on a host**, so no `WORKROOM_ROOT_PATH` (D2). `.worktreeinclude` (#367) is how
  root-only files reach a host.
- **The host's environment, never the Mac's.** Sending the Mac's environment would put the user's
  Mac credentials on the host, which #229 rules out (`host_environment` in `vcs.rs`).
- **Two engines.** Local scripts are run by the Go CLI (`internal/script`); remote ones by the app
  through the host's agent, since the CLI can't reach a host (the drivers are Swift; ADR 0040). One
  contract fixture pins both to the same behaviour (see Tests).

## Design

### 1. `wr-agent run-script` (Rust, new)

A subcommand of the agent that is already on every host, run over the driver's one-off exchange
(`HostDriver.exec`, the channel #495's tar copy uses):

    wr-agent run-script --dir <clone> --timeout 600 -- <script>

It:

- reads the host user's login-shell environment the way `ShellEnvironment.refresh` does on the Mac:
  one `<shell> -ilc` (the shell from `shell.rs`) with `WORKROOM_SHELL_PROBE=1`, bounded, falling
  back to its own environment on any failure (timeout, `exec tmux`, a prompt, an unknown shell);
- runs the script with that environment plus the `WORKROOM_*` variables it is passed, in `--dir`, in
  a process group of its own;
- streams the script's stdout and stderr to its own, as they arrive;
- on the wall-clock limit, or on SIGTERM, SIGHUP or SIGINT, kills the whole tree: the group and the
  descendants snapshotted at SIGTERM (`vcs.rs`'s `descendants`, which also catches a `setsid`
  escaper), SIGKILL two seconds later;
- exits with the script's status, or 124 on a timeout, saying which on stderr.

Why the agent, not a shell one-liner: it already knows the host's login shell, already kills a tree
correctly, and has tests for both. A POSIX wrapper would re-implement those, worse, in a string.

Why not the agent's `exec` request: it returns output only at the end (`AgentExecResult`), and its
environment is built for git (`host_environment` scrubs it and pins `BatchMode`).

The app reads the output with `HostStream.communicate(_:timeout:onOutput:)`, which already streams.
Its `timeout` bounds silence; the 600 s wall clock is the agent's, so the app passes a silence bound
just above it (610 s), and a run that ends by timeout is the agent's 124.

### 2. Remote setup (app)

In `runRemoteCreate` (`AppStore+WorkroomCreation.swift`), after `copyIncluded` and before
`completeCreationRun`:

1. `run.begin("script")`. The step's id is `script`, the local row's id, so both kinds share "Run
   setup script". A new `ProvisioningProgress.Step.script`; not `setup`, which is the host's setup.
2. Find the script: `stat` the clone's `scripts/workroom_setup` through the agent's `stat` request.
   If it is missing and the Mac root has one, upload the root's copy over `HostDriver.exec` with
   `communicate(contentsOf:)` to a temp path on the host, executable.
3. Run it with `wr-agent run-script`, streaming lines into the row.
4. Exit 0: the row is done, and the create completes as now. Non-zero or 124: the row fails and the
   run ends `.setupScriptFailed`, the local outcome, so the footer is Open Anyway or Delete. The host
   is not destroyed.

`CreationRun`'s `hasSetupScript` drops its `kind == .local` check: the row shows when the Mac root
has a script, and a clone-only script brings it back when it starts (`restore`), as one only the new
worktree has does locally.

### 3. Remote teardown (app)

In `RemoteWorkrooms.delete`, after the connection is released and before `tearDown`, when the host
is live and its state is ready (not `failed` or `creating`):

1. Find and run `scripts/workroom_teardown` the same way as setup, streaming into the delete's
   `ScriptLogSession` (a new `onLog` parameter, as `cli.delete` has).
2. Exit 0, or no script: carry on to `tearDown`.
3. Non-zero, 124, or the host can't be reached: throw a new `Failure.teardownScriptFailed(message:)`.
   Nothing is torn down and the record is unchanged, so deleting again retries.

A `failed` or `creating` record skips the script: its host may not be whole, and that delete exists
to finish taking it down.

### 4. Delete Anyway (CLI and app)

- CLI: `--skip-teardown` on `workroom delete`, and on `delete-project` for its two modes that run
  teardowns (`--with-workrooms`, `--from-disk`). It skips only the script, never the VCS removal.
  Added to the `--json` contract and its fixtures.
- App: the error sheet gets an optional action (label and handler) in `ModalState`. A teardown
  failure sets "Delete Anyway", which runs the same delete again with the script skipped: the CLI
  flag for a local workroom, `RemoteWorkrooms.delete(skipTeardown: true)` for a remote one. Project
  deletes the same.

### 5. Local changes

- `script.Run` sets `WORKROOM_HOST=local`.
- `--skip-teardown` (above).
- Nothing else: local behaviour is the reference.

## Tests

- **Contract fixture** (`testdata/contracts/script-env/`): a script that prints its working
  directory, its `WORKROOM_*` variables, whether `WORKROOM_SHELL_PROBE` leaked into it, and exits
  with a given status. Go (`internal/script`) and Rust (`run-script`) tests run it and compare with
  one expected file per kind; a difference in either is a red test.
- **Rust:** `run-script` kills a tree that includes a `setsid` grandchild on timeout and on SIGTERM;
  falls back when the probe hangs or the shell `exec`s; streams before exit.
- **Swift** (`RemoteProvisioningTests`, #495's fake-driver pattern): the clone's script runs; the
  root's is uploaded when the clone has none; no script skips the row; a failure keeps the host and
  ends `.setupScriptFailed`; teardown runs before `tearDown`; a failed or unreachable teardown leaves
  the record and throws; `skipTeardown` destroys without running it; a `failed` record skips it.
- **Go:** `--skip-teardown` on both commands; `WORKROOM_HOST=local`.
- Each new test proven red with `make red-proof` or by breaking its line.

## Probes before building on them

None of these has been run. Each is a live check on a real host, and the plan changes if one fails:

- `wr-agent run-script`'s login-shell read on boxd and exe.dev (their user, `$SHELL`, rc files).
- Whether ending the Mac's carrier (`HostStream.end`) delivers SIGHUP or SIGTERM to `run-script` on
  each provider. If not, the agent's own wall clock still bounds the script, but a cancelled create
  leaves it running until then.
- An agent on a host made before this ships: is it replaced by the app's current one on connect, so
  `run-script` exists for that host's teardown? If not, teardown on an old host fails with "unknown
  subcommand" and needs a fallback (Delete Anyway covers it, at the cost of the script).

## Docs and release note

- README "Setup and teardown scripts": every kind of workroom; `WORKROOM_HOST`; the root-path
  guard; Delete Anyway.
- `CONTEXT.md:34`, `remote-workrooms.md`'s "Not done" line, and a new ADR replacing ADR 0040's
  "No teardown script runs on the host".
- Release note: remote workrooms now run both scripts; scripts that need `WORKROOM_ROOT_PATH` must
  guard it; Delete Anyway exists.

## Out of scope

- Opening a failed setup row's log by itself (design D7 of #483 keeps it closed).
- The generic ssh driver (#378): it inherits this through `HostDriver.exec`.

## Commits (one PR)

1. `feat(cli): skip the teardown script on request, and say where a script runs`
2. `feat(agent): run a workroom script with the host's login environment, killing its tree on timeout`
3. `feat(macapp): run the setup script on a remote workroom's host`
4. `feat(macapp): run the teardown script before a remote workroom's host goes`
5. `feat(macapp): Delete Anyway on a failed teardown`
6. `docs: scripts on every kind of workroom`

## As built (2026-10-17)

- **No `ProvisioningProgress.Step.script`.** A remote plan ends with a plain `CreationStep` whose id
  is `script`, the local row's own; no driver reports it, so it needs no `Step`.
- **C2, refined.** The setup runs after the create's reload, not before it: the reload adopts the
  host, which is what marks a container as relayed, so `RemoteHosts.connect` puts its credential relay
  up for the script (R5). It still runs before `releaseCreatingWorkroom`, which is C2's point: the
  workroom can't be deleted while its script runs. The create's own connection is closed first; the
  script finds itself with `test -e` over `HostDriver.exec`, not the agent's `stat`.
- **Where the root's copy goes.** `<clone>/.git/workroom/workroom_<script>`, inside the clone and
  never tracked, so it goes with the host. A script that finds its checkout from `$0`
  (`cd "$(dirname "$0")/.."`) lands in `.git` when it is the root's copy. Locally the root's copy
  lands in the root project instead, so neither place is the workroom. The script's working
  directory is the workroom either way, which is what `WORKROOM_PATH` and the README point scripts at.
- **Connecting first.** A script's host is treated as opened (`RemoteHosts.activate`) before its
  connect: a stopped container (every Apple one after a reboot) is started, as opening its
  workroom starts it, so a delete from the context menu still runs its teardown. A host the app
  can't reach reads "couldn't reach the host"; the connect's own error is in the log.
- **Bounds.** The agent's wall clock (600 s) ends the script. The Mac bounds the exchange's silence
  and its whole length at 630 s, as the local CLI call's own 600 s timeout bounds a local script:
  a process the script left in the background holds the output open, and one that keeps printing is
  never silent. The agent's login-shell probe gets 10 s, not the Mac's 3 s, because a host has no
  cached environment to fall back on.
- **R4 was a false finding.** The delete-project sheet already warns in every scope that remote
  workrooms' machines are destroyed (`DeleteProjectSheetModel.remoteWarning`, shown at
  `DeleteProjectSheet.swift:154`, pinned by `testTheProjectSheetWarnsOfTheRemoteHostsItDestroys`).
  The review read only the footer copy. Nothing changed; T8 was dropped.
- **This repo's own `scripts/workroom_setup`** required `WORKROOM_ROOT_PATH` and would have failed
  every remote create of this repo (D2). It now copies nothing on a host and says so, as the README's
  guard shows.
- **Probes, in part.** On the Linux ssh fixture (Debian, bash, real sshd and this build's musl
  agent; `RemoteProvisioningIntegrationTests.testAWorkroomScriptRunsOnALinuxHostAsTheContractSays`):
  `bash -lic` reads `~/.profile` into the script's environment, the script sees `remote.txt`'s
  contract, a script without `+x` fails as not started, and the wall clock ends a tree with a
  `setsid` escaper (exit 124). Still unrun, and needing paid machines: boxd's and exe.dev's own users
  and rc files, and whether a hangup reaches `run-script` when the Mac side ends.
- **A descriptor from before the `driver` field** (Docker's) finds its key with `deletionKey`, as
  its host's delete does; `DriverKey(_:)` alone returned nil and would have failed its teardown.
- **Tests that stand in for a live host.** The Swift runner tests drive this build's real `wr-agent
  run-script` through a fake host that is this Mac's `/bin/sh`; the flow and delete tests fake the
  script service. None replaces the provider probes below, which are still to run.

## Review (plan-eng-review, 2026-10-17)

Target: this document, `docs/designs/scripts-on-every-workroom.md` at 33409cfe9. The report lives
in this file (the selected plan).

### Scope record

feature answers: no cuts proposed; structure: A, Original arrangement (D1, 2026-10-17); accepted
scope: the plan as written above; pending remedies: R1.

### Factual corrections (no behaviour change)

- C1. "`CreationRun`'s `hasSetupScript`" in Design §2 is `AppStore.hasSetupScript`
  (`AppStore+WorkroomCreation.swift:119`), which `CreationRun.init` receives as a parameter.

## Decision ledger

### R1: teardown on a remote host bootstraps the agent first
Finding: F1, P1, confidence 8/10, Design §3, reviewer: Claude (plan-eng-review)
Plan baseline: original proposal, Design §3: "after the connection is released and before
`tearDown` ... Find and run `scripts/workroom_teardown` the same way as setup", over
`HostDriver.exec` against whatever agent the host has.
Runtime evidence: `RemoteWorkrooms.delete` only disconnects the lease and destroys
(`RemoteWorkrooms.swift:487-491`); it never bootstraps. The agent is replaced only on connect:
"Puts the Linux agent this app bundles on a remote host, and replaces the one running there"
(`AgentBootstrap.swift:9`). So every host made before this ships runs an agent with no
`run-script`, and its teardown would fail every time. Unknown: how often a host cannot hash its
agent (`AgentBootstrap.swift:188`, connects to whatever runs).
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R1 agent before teardown | plan: no bootstrap, `HostDriver.exec` against the installed agent | `environment.connect(host)` first (`AgentBootstrap.connect`), which replaces an older agent; then `run-script`; then close | unchanged from plan |
| D3 failure policy | approved (D3) | unchanged: bootstrap or script failure stops the delete, Delete Anyway | unchanged |
| Setup's agent | plan: fresh host, bootstrapped by `provision` | unchanged | unchanged |
Question D2:
D2 — Bootstrap the agent before a remote teardown? <gstack-qid:plan-eng-review-r1-teardown-bootstrap>
Project/branch/task: workroom/mild-spire, the plan to run setup and teardown scripts on every kind of workroom.
ELI10: The teardown runs through a new `wr-agent run-script` command on the host. Remote workrooms made before this ships have an older agent with no such command. The app only swaps in its own agent when it connects to a host, and delete doesn't connect today. So deleting any existing remote workroom would hit "unknown command", fail the teardown and need Delete Anyway, every time.
Stakes if we pick wrong: every remote workroom you have today shows a teardown failure on delete, and its teardown script never runs.
Recommendation: A because one connect fixes every older host, and an unreachable host already fails into Delete Anyway (D3).
Completeness: A=10/10, B=6/10
Pros / cons:
A) Bootstrap first (recommended)
  ✅ Every existing remote workroom runs its teardown on delete, the same as a new one
  ✅ Reuses AgentBootstrap.connect, which already replaces an older agent and keeps sessions
  ❌ A delete now connects first, adding the connect's time (seconds) before the host goes
B) Keep as written
  ✅ Delete stays as fast as today, with no connect before the teardown
  ✅ A host made after this ships still runs its teardown normally
  ❌ Every host made before this ships fails its teardown and needs Delete Anyway each time
Net: a few seconds per delete buys teardown parity for every remote workroom that already exists.
Header: Bootstrap
Options:
A) Bootstrap first (recommended)
Before the teardown, connect to the host through AgentBootstrap.connect, which replaces an older agent with this app's; run `run-script`; close. A failed connect is a failed teardown (D3: the delete stops, Delete Anyway). Tests: an older-agent host is bootstrapped before the script; a failed bootstrap leaves the record and throws. Effort: human ~2 h / CC ~15 min.
B) Keep as written
Run `run-script` over HostDriver.exec against whatever agent is installed. A host whose agent predates `run-script` fails its teardown, which D3 turns into Delete Anyway. Effort: none beyond the plan.

State: approved
Actual answer: A) Bootstrap first (D2, 2026-10-17)
Accepted scope: before a remote teardown, connect through `AgentBootstrap.connect` (replacing an older agent), run `run-script`, close; a failed connect is a failed teardown under D3. Tests: an older-agent host is bootstrapped before the script; a failed bootstrap leaves the record and throws.
History: none

### R2: which project-delete scopes run a remote workroom's teardown
Finding: F2, P2, confidence 8/10, Design §4 ("Project deletes the same"), reviewer: Claude (plan-eng-review)
Plan baseline: original proposal, Design §4: project deletes get Delete Anyway; which scopes run a remote teardown is unstated.
Runtime evidence: a project delete destroys its remote workrooms' hosts in every scope, config-only included ("for workroom in remoteWorkrooms ... RemoteWorkrooms.delete", `AppStore.swift:2596-2605`), and config-only makes no log (`scope == .configOnly ? nil : ScriptLogSession(...)`, `AppStore.swift:2591-2593`). Locally, config-only runs no teardown because it leaves the workroom on disk.
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R2 remote teardown in a config-only project delete | unstated | runs, since the host is destroyed; the delete gets a log whenever it has a remote workroom | skipped in config-only; runs in the two disk scopes |
| R1 bootstrap first | approved (D2) | unchanged | unchanged |
| D3 failure policy | approved | unchanged | unchanged |
Question D3:
D3 — Run a remote workroom's teardown when its project is removed from Workroom only? <gstack-qid:plan-eng-review-r2-project-delete-scope>
Project/branch/task: workroom/mild-spire, the plan to run setup and teardown scripts on every kind of workroom.
ELI10: Deleting a project has three choices. "Remove from Workroom only" leaves local workrooms on disk, so it runs no teardown today. But it still destroys every remote workroom's machine. The rule we agreed is that a teardown runs before a workroom goes. Locally that never happens in this scope, but remotely it does, and the plan doesn't say which wins.
Stakes if we pick wrong: a database or other resource a remote setup made outside the box is never cleaned up when the project is removed, and nothing says so.
Recommendation: A because the machine really is destroyed, so the teardown's reason to exist holds, and D1 says the same event gets the same script.
Completeness: A=10/10, B=7/10
Pros / cons:
A) Run it (recommended)
  ✅ Every destroyed remote machine runs its teardown first, whichever delete scope removed it
  ✅ Its output gets a log, so a failure shows the same sheet and Delete Anyway as anywhere else
  ❌ A config-only delete of a project with remote workrooms can now stop on a teardown failure
B) Skip in config-only
  ✅ Config-only stays a quick bookkeeping delete that never runs project code
  ✅ Matches the local rule word for word: config-only never runs a teardown
  ❌ A remote machine is destroyed with no teardown, leaving outside resources behind silently
Net: run the script whenever a machine is actually destroyed, at the cost of config-only deletes sometimes stopping.
Header: Config-only
Options:
A) Run it (recommended)
In every project-delete scope, each remote workroom runs its teardown (after R1's bootstrap) before its host is destroyed. Any project delete with a remote workroom creates a ScriptLogSession, so output and failures reach the error sheet with Delete Anyway. Tests: a config-only delete with a remote workroom runs its teardown; its failure stops the delete and shows the output. Effort: human ~1 h / CC ~10 min.
B) Skip in config-only
A config-only project delete destroys remote hosts without running their teardowns; the two disk scopes run them. Tests: a config-only delete runs no remote teardown. Effort: human ~30 min / CC ~5 min.

State: approved
Actual answer: A) Run it, with the note "Local and remote should behave the same" (D3, 2026-10-17)
Accepted scope: in every project-delete scope, each remote workroom runs its teardown (after R1's bootstrap) before its host is destroyed; any project delete with a remote workroom creates a ScriptLogSession, so output and failures reach the error sheet with Delete Anyway. Tests: a config-only delete with a remote workroom runs its teardown; its failure stops the delete and shows the output. The note's meaning for LOCAL config-only deletes is not settled by this answer: see R3.
History: none

### R3: does a config-only project delete run its local workrooms' teardowns?
Finding: F2 follow-up, from the owner's D3 note "Local and remote should behave the same", reviewer: Claude (plan-eng-review)
Plan baseline: current behaviour, kept by the plan: config-only runs no teardown and touches nothing on disk ("plain config-only removal touches nothing on disk", `WorkroomCLI.swift:341-343`; `deleteProjectRunsScripts` returns `withWorkrooms || fromDisk`).
Runtime evidence: after R2, a config-only delete runs a remote workroom's teardown (its host is destroyed) but not a local one's (its worktree stays on disk).
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R3 local teardown in config-only | none runs | none runs: the rule is "a teardown runs when the workroom itself is destroyed", which config-only does to remote workrooms and not to local ones | each local workroom's teardown runs too, though its worktree stays on disk |
| R2 remote teardown in config-only | approved (D3): runs | unchanged | unchanged |
Question D4:
D4 — "Behave the same" in a config-only project delete: which rule? <gstack-qid:plan-eng-review-r3-local-config-only>
Project/branch/task: workroom/mild-spire, the plan to run setup and teardown scripts on every kind of workroom.
ELI10: Your note on D3 can mean two things. One rule is "a teardown runs whenever a workroom is destroyed". Config-only destroys remote machines but leaves local worktrees on disk, so only the remote ones run their teardown. The other rule is "config-only runs every workroom's teardown". Then a local worktree you keep on disk loses whatever its setup made, such as its database, while its code stays.
Stakes if we pick wrong: either a kept local worktree silently loses its database, or the two kinds follow a rule you didn't mean.
Recommendation: A because a teardown undoes what setup made for a workroom that is going away, and a kept worktree isn't going away.
Note: options differ in kind, not coverage — no completeness score.
Pros / cons:
A) Run when destroyed (recommended)
  ✅ One rule for both kinds: the teardown runs exactly when the workroom itself is destroyed
  ✅ A local worktree kept on disk keeps its database and anything else its setup made
  ❌ In a config-only delete, remote workrooms run a script and local ones don't, which reads unequal
B) Run for every workroom
  ✅ Config-only runs every workroom's teardown, the same list on both kinds
  ✅ Nothing a setup made outside a workroom outlives the project's removal from Workroom
  ❌ A local worktree left on disk loses its database while its code stays, half torn down
Net: tie the teardown to the workroom actually going, or to the delete, whichever matters more to you.
Header: Config-only
Options:
A) Run when destroyed (recommended)
The teardown runs whenever a workroom itself is destroyed, on every kind. A config-only project delete leaves local worktrees on disk, so it runs no local teardown (as today), and destroys remote machines, so it runs their teardowns (R2). Docs state this rule. Tests: a config-only delete runs no local teardown. Effort: human ~15 min / CC ~5 min.
B) Run for every workroom
A config-only project delete also runs each local workroom's teardown, leaving its worktree on disk; a teardown failure stops it with Delete Anyway. `deleteProjectRunsScripts` becomes true for config-only, with the shell probe and 600 s timeout. Tests: a config-only delete runs each local teardown; a failure stops it. Effort: human ~2 h / CC ~20 min.

State: approved
Actual answer: A) Run when destroyed ("Go with A for D4", owner message after the D4 clarification, 2026-10-17)
Accepted scope: the teardown runs whenever a workroom itself is destroyed, on every kind. A config-only project delete runs no local teardown (as today) and runs each remote workroom's teardown before its machine is destroyed (R2). Docs state this rule. Tests: a config-only delete runs no local teardown.
History: the first D4 send was rejected for clarification ("why do we have a config-only delete?"); answered from issue #108 and `DeleteProjectSheet.swift`, then answered A.

### R4: the delete-project sheet says remote machines are destroyed in every scope
Finding: F3, P2, confidence 9/10, found while answering the D4 clarification, reviewer: Claude (plan-eng-review)
Plan baseline: not in the original plan.
Runtime evidence: config-only's footer is "Removes the project from Workroom only. Files on disk are kept." (`DeleteProjectSheet.swift:37`), but every scope destroys each remote workroom's machine (`AppStore.swift:2596-2605`), and no scope's copy says so.
State: approved
Actual answer: "fold the delete-project sheet copy fix (remote machines are destroyed in every scope) into this PR" (owner, 2026-10-17)
Accepted scope: when the project has remote workrooms, the sheet says in every scope that their machines are destroyed (and, per R2, run their teardown first); `DeleteProjectSheet`'s presentation tests cover the remote and no-remote copy. Within the no-layout-shift rule: the text sits in the footer's existing slot.
History: none

### More factual corrections (required by approved decisions, no new behaviour)

- C2. Remote setup runs before `releaseCreatingWorkroom` and before `created.instance.connection.close()`
  in `runRemoteCreate` (`AppStore+WorkroomCreation.swift:438-441`), not merely "before
  `completeCreationRun`". A local workroom stays undeletable until its create's process ends
  (`releaseCreatingWorkroom`, "its workroom can be deleted and probed again (issue #116)"); D1 says
  remote matches, so a delete can't start a teardown and destroy the host under a running setup.
  The `stat` in Design §2 also needs that connection open.
- C3. An uploaded root script keeps its own mode; Design §2's "to a temp path on the host,
  executable" forces `+x`. Locally a root script without `+x` fails (`exec.Command(scriptPath)`,
  `internal/script/script.go`), so D1 says the remote copy fails the same way.

### Section 1: Architecture

- [P1] (confidence: 8/10) Design §3: a remote teardown runs against an agent that may predate
  `run-script`. R1, approved A (D2).
- [P2] (confidence: 8/10) Design §4: which project-delete scopes run a remote teardown. R2,
  approved A (D3); R3, approved A (D4).
- [P2] (confidence: 9/10) `DeleteProjectSheet.swift:37`: config-only copy says files are kept while
  remote machines are destroyed. R4, approved (owner).
- [P2] (confidence: 9/10) Design §2 placement. C2, a correction under D1.

Dispositions: F1 accepted (D2), F2 accepted (D3, D4), F3 accepted (owner), C2 recorded.

Flow, as approved:

    create (remote)                                delete (remote)
    provision ── clone ── checkout                 checkDeletable
        │                                              │
    copyIncluded (#495)                            live and ready? ── no ──> tearDown
        │                                              │ yes
    script row: stat clone's script                AgentBootstrap.connect (R1) ── fail ──┐
        │ missing? root's copy uploaded (C3)           │                                 │
        │ none at all? row skipped                 run-script workroom_teardown          │
    wr-agent run-script workroom_setup                 │ non-zero / 124 ─────────────────┤
        │ lines ──> "Run setup script" row             │ 0 or no script                  v
        │ non-zero / 124 ──> .setupScriptFailed        v                 Failure.teardownScriptFailed
        │       (host kept; Open Anyway / Delete)  tearDown ── forget    (record kept; sheet with
    close connection, reload,                                            reason + log; Delete Anyway
    releaseCreatingWorkroom (C2), complete                               = skipTeardown: true)

### Section 2: Code quality

- [P3] (confidence: 8/10) Design §2: forced `+x` on the uploaded copy. C3.
- Setup and teardown share one find, upload and run sequence: one `RemoteProvisioning` helper with
  two callers (Design §2 and §3). Rubric: two proposed callers, same inputs and outputs; accepted as
  part of the approved design, no separate extraction choice.

Dispositions: F5 recorded as C3.

### Section 3: Tests

    CODE PATHS                                              USER FLOWS
    [+] wr-agent run-script (new)                           [+] Remote create
      ├── [GAP] exit status passed through                    ├── [GAP] script row streams, done
      ├── [GAP] 600 s wall clock kills tree incl. setsid      ├── [GAP] failure: Open Anyway / Delete, host kept
      ├── [GAP] SIGTERM/SIGHUP kills tree                     ├── [GAP] no script anywhere: no row
      ├── [GAP] login-env probe; fallback on hang/exec        └── [GAP] can't delete while setup runs (C2)
      └── [GAP] streams before exit                         [+] Remote delete
    [+] RemoteProvisioning script helper (new)                ├── [GAP] teardown runs, then host goes
      ├── [GAP] clone's script runs                           ├── [GAP] older agent bootstrapped first (R1)
      ├── [GAP] root's copy uploaded, mode kept (C3)          ├── [GAP] failure: sheet + Delete Anyway, record kept
      └── [GAP] neither: skipped                              ├── [GAP] unreachable host = failure (D3)
    [+] RemoteWorkrooms.delete                                └── [GAP] failed/creating record skips the script
      └── [GAP] skipTeardown destroys without the script   [+] Project delete
    [+] Go CLI                                                ├── [GAP] config-only runs remote teardowns (R2)
      ├── [★★★ TESTED] teardown runs / fails / streams          ├── [★★ TESTED] config-only runs no local teardown
      │     workroom_test.go:824, :857, :891                  │     WorkroomCLITests.swift:11 (R3)
      ├── [★★ TESTED] script env vars script_test.go:134      ├── [GAP] Delete Anyway skips every teardown
      ├── [GAP] WORKROOM_HOST=local                           └── [GAP] sheet copy names destroyed machines (R4)
      └── [GAP] --skip-teardown on delete and delete-project
    [+] Contract fixture: [GAP] Go and Rust print the same env, cwd and exit for the same script
    [+] Local create row: [★★ TESTED] CreationFlowTests.swift:140, CreationRunTests.swift:56 (regression guard
        for dropping `kind == .local` from hasSetupScript)

    COVERAGE: 4/28 paths tested (14%), all new paths planned. QUALITY: ★★★:1 ★★:3. GAPS: 24 (0 E2E, 0 eval)

Regression rule: the at-risk local behaviour (default delete runs the teardown; script env; local
create row) already has tests at the lines above, and those tests stay. No new regression contract
is needed. Every gap above is a planned test in Design "Tests" or an approved R1 to R4 scope; each is
proven red before it counts. A live check on boxd and exe.dev (Design "Probes") is not replaced by
any of these: the Swift tests use a fake driver.

Dispositions: no new choices; the gaps are the approved test scope.

### Section 4: Performance

No issues found. The new costs are a bootstrap connect before each remote teardown (R1, accepted:
seconds per delete, [estimated]), one `stat` and at most one small upload per script run, and
streamed log lines on the same main-queue path local creates already use. Volume is unknown and
equal to the script's own output, as locally.

### Outside voice (Codex, gpt-6-astra, completed)

    - High — Container scripts lack Git credentials. RemoteProvisioning.swift:143. Provisioning
      authenticates the clone with a temporary header; the credential relay is installed separately
      by RemoteHosts.connect. The proposed setup runs before that, and teardown disconnects the relay
      before calling bare AgentBootstrap.connect. Ordinary scripts fetching private dependencies or
      pushing cleanup changes therefore fail despite cloning successfully. Establish and retain the
      relay for both script lifetimes.
    - Medium — Project Delete Anyway needs fresh state, not a replay of the original project.
      AppStore.swift:2600. Project deletion destroys and forgets remote workrooms sequentially. If A
      succeeds and B's teardown fails, retrying the captured project with skipTeardown revisits A.
      Its recorder calls setHost on an entry already removed, which returns WorkroomNotFound; the
      retry stops before reaching B. The plan must explicitly resolve the remaining workrooms from
      current config and test partial success followed by Delete Anyway.
    - Medium — "Nothing else" locally leaves teardown failures outside the promised recovery path.
      internal/script/script.go:60. A non-executable teardown or missing interpreter returns an
      unwrapped start error, classified as InternalError, rather than TeardownScriptFailed. A hung
      teardown becomes WorkroomCLIError.timedOut instead. These ordinary failures will miss an
      action keyed to teardown failure. Specify how those cases qualify for Delete Anyway and cover
      them; adding the flag and testing non-zero exits is insufficient.
    Recommendation: revise the plan before implementation because script authentication,
    partial-delete retries, and local failure classification remain unresolved.

Verification: O1 confirmed for relayed (container) workrooms only: `RemoteHosts.connect` installs
the relay after bootstrapping (`RemoteWorkrooms.swift:1001-1013`); boxd and exe.dev use their
provider's git credentials (ADR 0049) and are unaffected. O2 confirmed: `remoteWorkrooms =
project.workrooms.filter(\.isRemote)` is captured from the passed project (`AppStore.swift:2560`).
O3 confirmed: `if err := cmd.Start(); err != nil { return "", err }` (`internal/script/script.go`).

- C4 (from O2, required by D3). Delete Anyway re-reads the project from current state after the
  failed delete's reload, so it deletes only what is left. Test: two remote workrooms, the second's
  teardown fails, Delete Anyway removes only the second and the project.

### R5: scripts on a relayed (container) host get git credentials
Finding: O1, High (Codex), confirmed for relayed hosts, `RemoteWorkrooms.swift:1001-1013`
Plan baseline: Design §2 runs setup on the create's own connection; R1 (approved) bootstraps with `AgentBootstrap.connect` before teardown. Neither installs the relay.
Runtime evidence: `RemoteHosts.connect` bootstraps the agent, then `installRelay` for a relayed host ("A relayed workroom's git asks this Mac for credentials (#309): its listener goes with the connection"). The create closes its connection without one (`AppStore+WorkroomCreation.swift:439`). Locally, scripts have the Mac's own git credentials.
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R5 relay during scripts | none: setup on the create's connection, teardown on a bare bootstrap | both scripts run on `RemoteHosts.connect`'s connection, which bootstraps (keeps R1) and installs the relay; held until the script ends | unchanged: container scripts have no git credentials |
| R1 bootstrap before teardown | approved (D2) | kept: `RemoteHosts.connect` runs `AgentBootstrap.connect` first | kept |
| boxd, exe.dev | provider credentials | unchanged | unchanged |
Question D5:
D5 — Give container scripts the same git credentials the workroom's terminals get? <gstack-qid:plan-eng-review-r5-relay-for-scripts>
Project/branch/task: workroom/mild-spire, the plan to run setup and teardown scripts on every kind of workroom.
ELI10: A Docker or Apple container workroom has no GitHub access of its own; its git borrows your Mac's through a small relay the app sets up whenever it connects. The plan runs the setup and teardown scripts before that relay exists. So a script that fetches a private dependency, like npm or bundler pulling from a private repo, fails, even though the clone worked. boxd and exe.dev aren't affected: they bring their own GitHub access.
Stakes if we pick wrong: setup fails on container workrooms for any project with private git dependencies, which locally just works.
Recommendation: A because the app's normal connect already does both jobs (bootstrap and relay), and local scripts have your git credentials.
Completeness: A=10/10, B=6/10
Pros / cons:
A) Connect with the relay (recommended)
  ✅ Container scripts reach private repos exactly as local scripts and the workroom's terminals do
  ✅ Uses RemoteHosts.connect, which already bootstraps the agent first, so R1 still holds
  ❌ The relay is set up a little earlier in a create, adding its setup time (seconds) before the script
B) Leave as written
  ✅ No change to when the relay is set up during a create or a delete
  ✅ Public dependencies and boxd or exe.dev workrooms work as planned
  ❌ A container script needing a private repo fails, unlike the same script on this Mac
Net: one connect call buys git-credential parity for container scripts.
Header: Relay
Options:
A) Connect with the relay (recommended)
Setup and teardown run on the connection `RemoteHosts.connect` makes, which bootstraps the agent (R1) and, for a relayed host, installs the credential relay; it stays until the script ends. A failed connect before teardown is a failed teardown (D3); before setup, a failed setup row. Tests: a relayed host's script runs after the relay is installed; a non-relayed host installs none. Effort: human ~2 h / CC ~15 min.
B) Leave as written
Setup runs on the create's connection and teardown on a bare `AgentBootstrap.connect`, with no relay; a container script's git has no credentials. Effort: none beyond the plan.

State: approved
Actual answer: A) Connect with the relay (D5, 2026-10-17)
Accepted scope: setup and teardown run on the connection `RemoteHosts.connect` makes, which bootstraps the agent (R1) and, for a relayed host, installs the credential relay; it stays until the script ends. A failed connect before teardown is a failed teardown (D3); before setup, a failed setup row. Tests: a relayed host's script runs after the relay is installed; a non-relayed host installs none.
History: R1's mechanism narrows from bare `AgentBootstrap.connect` to `RemoteHosts.connect`, which calls it; R1's behaviour is unchanged.

### R6: which delete failures count as a teardown failure (and offer Delete Anyway)
Finding: O3, Medium (Codex), confirmed, `internal/script/script.go:60-61`
Plan baseline: Design §4: "A teardown failure sets Delete Anyway"; how a failure is recognised is unstated. Today the app shows the teardown sheet for any error from `cli.delete` (`presentTeardownFailure` in `startWorkroomTeardown`'s catch).
Runtime evidence: a script that can't start (not executable, missing interpreter) returns the bare `cmd.Start()` error, which the CLI reports as `InternalError`, exit 1, not `TeardownScriptFailed`, exit 5 (README: "`5` | Setup / teardown script failed"). A teardown that hangs past 600 s ends as `WorkroomCLIError.timedOut`. A setup script that can't start has the same misclassification today.
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R6 failure classification | start error = `InternalError`; any delete error shows the teardown sheet | `script.Run` wraps a start failure as `ErrSetup`/`ErrTeardown` (exit 5); `run-script` reports a script it can't start as a script failure; Delete Anyway shows for `TeardownScriptFailed`, a timed-out delete, and remote `Failure.teardownScriptFailed`; other delete failures show their own sheet without it | classification unchanged; Delete Anyway on every failed delete |
| D3 policy | approved | unchanged | unchanged |
| C4 fresh state on retry | recorded | unchanged | unchanged |
Question D6:
D6 — Which failed deletes offer Delete Anyway? <gstack-qid:plan-eng-review-r6-teardown-failure-classification>
Project/branch/task: workroom/mild-spire, the plan to run setup and teardown scripts on every kind of workroom.
ELI10: Delete Anyway retries the delete without the teardown script, so it only helps when the script was the problem. Today a script that can't even start, for example one missing `chmod +x` (the README warns about this), is reported as an internal error, not a script failure. A teardown that hangs past the 10-minute limit is reported as a timeout. If the button keys on "script failed", those two common cases miss it. If it shows on every failure, it also appears when git itself failed, and pressing it fails the same way again.
Stakes if we pick wrong: either a stuck delete with no way out for the most common script mistake, or a button that promises a fix it can't deliver.
Recommendation: A because it fixes the misreport at its source, which also corrects the setup side, and the exit code then matches the README's 5.
Completeness: A=10/10, B=7/10
Pros / cons:
A) Classify at the source (recommended)
  ✅ A script that can't start reports as a script failure, exit 5, matching the README for setup and teardown alike
  ✅ Delete Anyway appears only when skipping the script can actually get the delete through
  ❌ Changes `--json` output for a script that can't start: kind InternalError becomes Setup/TeardownScriptFailed
B) Offer it on every failure
  ✅ No change to how the CLI classifies errors, so the `--json` contract stays as it is
  ✅ Simplest rule for the app: any failed delete shows the button
  ❌ On a git or config failure the button skips the script and fails again with the same error
Net: fix the misclassification once, or show a button that is sometimes useless.
Header: Delete Anyway
Options:
A) Classify at the source (recommended)
`script.Run` wraps a failure to start a script as `ErrSetup` or `ErrTeardown`, so the CLI reports `SetupScriptFailed`/`TeardownScriptFailed`, exit 5; `run-script` treats a script it can't start the same way. The app offers Delete Anyway for `TeardownScriptFailed`, for a delete that timed out, and for a remote `Failure.teardownScriptFailed`; any other delete failure shows the sheet without it. Contract goldens updated; release note mentions the kind change. Tests: a non-executable setup and teardown each give exit 5 and the right kind; a timed-out delete offers Delete Anyway; a VCS failure does not. Effort: human ~3 h / CC ~20 min.
B) Offer it on every failure
Classification unchanged. Every failed delete, local or remote, offers Delete Anyway, which retries with the script skipped. Tests: any failed delete shows the button. Effort: human ~1 h / CC ~10 min.

State: approved
Actual answer: A) Classify at the source (D6, 2026-10-17)
Accepted scope: `script.Run` wraps a failure to start a script as `ErrSetup` or `ErrTeardown` (CLI kind `SetupScriptFailed`/`TeardownScriptFailed`, exit 5); `run-script` treats a script it can't start the same way. The app offers Delete Anyway for `TeardownScriptFailed`, a timed-out delete, and a remote `Failure.teardownScriptFailed`; any other delete failure shows the sheet without it. Contract goldens updated; release note mentions the kind change. Tests: a non-executable setup and teardown each give exit 5 and the right kind; a timed-out delete offers Delete Anyway; a VCS failure does not.
History: none

Approval readiness: PASS. Checked R1 (D2, A), R2 (D3, A), R3 (D4, A), R4 (owner message), R5 (D5,
A), R6 (D6, A); C1 to C4 are corrections under approved decisions. No deferrals.

### TODOS.md

No items proposed: nothing was deferred. The pre-build probes (Design "Probes") are build-time
checks in this PR, not TODOs.

### NOT in scope

- Opening a failed setup row's log by itself: #483's design D7 keeps logs closed until opened.
- The generic ssh driver (#378): it gets this through `HostDriver.exec` when it lands.
- Ending a remote script when the Mac side is cancelled (app quit mid-create): the host's own 600 s
  wall clock bounds it; whether the provider forwards a hangup is a probe, not a feature.

### What already exists

- Tree kill with `setsid` escapers: `vcs.rs` `descendants` and its SIGKILL sweep. Reused by
  `run-script`.
- The host user's login shell: `shell.rs` (`invocation`, leading-dash login). Reused.
- The Mac's login-environment probe and its `WORKROOM_SHELL_PROBE` contract:
  `ShellEnvironment.swift`. Mirrored in Rust, not shared (different language and host).
- Streaming one-off exchange: `HostStream.communicate(_:timeout:onOutput:)`, silence-bounded.
  Reused as is.
- Agent bootstrap and the credential relay: `RemoteHosts.connect` (R1, R5). Reused.
- File upload to a host: `communicate(contentsOf:)` (#495). Reused for the root script.
- The creation row and its restore-on-begin: `CreationRun.begin`/`restore`. Reused.
- The teardown failure sheet with reason above a scrolling log: commit 1f6dcbbf. Gains an action.

### Failure modes

| Path | Realistic failure | Handling | User sees |
| --- | --- | --- | --- |
| Remote setup | Host drops mid-script | `communicate` throws; row fails; host kept | Footer: Open Anyway / Delete |
| Remote setup | Script needs a private git dep on a container | Relay up first (R5) | Normal success |
| Remote setup | Root path required by script (D2) | Script exits non-zero | Footer with the script's own error; release note shows the guard |
| Remote teardown | Host unreachable or agent older | Bootstrap via connect (R1); failure = teardown failure | Sheet with reason; Delete Anyway |
| Remote teardown | Script hangs | Agent kills tree at 600 s, exits 124 | Sheet: timed out; Delete Anyway |
| Local teardown | Script not executable | Start error wrapped (R6), exit 5 | Sheet; Delete Anyway |
| Project Delete Anyway | First remote workroom already gone | Re-read state (C4) | Only what is left is deleted |
| Any delete | git worktree removal fails | Not a teardown failure (R6) | Sheet without Delete Anyway |

No critical gaps: every row has handling, a planned test and a visible message.

### Worktree parallelization strategy

| Step | Modules touched | Depends on |
| --- | --- | --- |
| Go: start-error wrap, `WORKROOM_HOST`, `--skip-teardown` | `internal/`, `cmd/`, `testdata/` | none |
| Rust: `run-script` | `vcs/crates/wr-agent/` | none |
| Contract fixture | `testdata/contracts/` | Go, Rust |
| Swift: runner helper, setup, teardown, relay, Delete Anyway, sheet copy | `macapp/` | Rust (calls it), Go (`--skip-teardown`) |
| Docs, ADR, release-note memory | `docs/`, `README.md`, `CONTEXT.md` | all |

Lane A: Go. Lane B: Rust. Launch A and B together; merge both; then the fixture, then Swift, then
docs. Conflict flags: `testdata/contracts/` is touched by A and by the fixture step, so the fixture
goes after A.

## Implementation Tasks
Synthesized from this review's findings. Each task derives from a specific finding above. Run with
Claude Code or Codex; checkbox as you ship. Effort ratios assumed: features ~30x, tests ~50x.

- [ ] **T1 (P1, human: ~3 h / CC: ~20 min)** — Go CLI — classify a script that can't start as a script failure
  - Surfaced by: Outside voice O3 — R6, `internal/script/script.go:60-61`
  - Files: `internal/script/script.go`, `internal/script/script_test.go`, contract goldens
  - Verify: `make cli-test`; a non-executable setup and teardown each exit 5 with the right kind
- [ ] **T2 (P1, human: ~2 h / CC: ~15 min)** — Go CLI — `--skip-teardown` on `delete` and `delete-project`; `WORKROOM_HOST=local`
  - Surfaced by: Design §4, §5 (D3)
  - Files: `cmd/delete.go`, `cmd/delete_project.go`, `internal/workroom/`, `internal/script/script.go`, contract fixtures
  - Verify: `make cli-test`
- [ ] **T3 (P1, human: ~1 day / CC: ~1 h)** — wr-agent — `run-script` subcommand
  - Surfaced by: Design §1; R6 (can't-start is a script failure)
  - Files: `vcs/crates/wr-agent/src/cli/run_script.rs`, `cli/mod.rs`, `main.rs`
  - Verify: `cargo test -p wr-agent`; tree kill incl. `setsid`, probe fallback, streaming, exit pass-through
- [ ] **T4 (P1, human: ~2 h / CC: ~15 min)** — Contract — Go and Rust print the same env, cwd and exit
  - Surfaced by: Design "Tests" (D1)
  - Files: `testdata/contracts/script-env/`, Go and Rust tests
  - Verify: both suites; break one engine's env and see red
- [ ] **T5 (P1, human: ~1 day / CC: ~1 h)** — macapp — remote setup row
  - Surfaced by: Design §2; C2, C3, R5
  - Files: `RemoteProvisioning.swift`, `AppStore+WorkroomCreation.swift`, `ProvisioningProgress.swift`, tests
  - Verify: `make app-test`; `RemoteProvisioningTests`, `CreationFlowTests`
- [ ] **T6 (P1, human: ~1 day / CC: ~1 h)** — macapp — remote teardown with bootstrap and relay
  - Surfaced by: Design §3; R1, R2, R5
  - Files: `RemoteWorkrooms.swift`, `AppStore.swift`, tests
  - Verify: `make app-test`; older-agent bootstrap, failure keeps the record, config-only runs remote teardowns
- [ ] **T7 (P1, human: ~3 h / CC: ~20 min)** — macapp — Delete Anyway
  - Surfaced by: D3; R6; C4
  - Files: `ModalState.swift`, `ErrorSheet.swift`, `AppStore.swift`, `WorkroomCLI.swift`, tests
  - Verify: `make app-test`; partial project delete then Delete Anyway; VCS failure shows no button
- [ ] **T8 (P2, human: ~1 h / CC: ~10 min)** — macapp — delete-project sheet names destroyed machines
  - Surfaced by: R4, `DeleteProjectSheet.swift:37`
  - Files: `DeleteProjectSheet.swift`, its presentation tests
  - Verify: `make app-test`
- [ ] **T9 (P1, human: ~2 h / CC: ~30 min)** — Probes — login shell, hangup delivery, agent replacement on boxd and exe.dev
  - Surfaced by: Design "Probes"
  - Files: none (live checks; results into this doc)
  - Verify: each probe's result recorded before T3/T5 rely on it
- [ ] **T10 (P2, human: ~2 h / CC: ~15 min)** — Docs — README, CONTEXT.md, remote-workrooms.md, new ADR, release-note memory
  - Surfaced by: Design "Docs and release note"; R4, R6 kind change
  - Files: `README.md`, `CONTEXT.md`, `docs/designs/remote-workrooms.md`, `docs/adr/0053-*.md`
  - Verify: docs read against the built behaviour

### Unresolved decisions

None.

### Completion summary

- Step 0: Scope Challenge — scope accepted as-is
- Reality rows: 7/7 applicable rows emitted, 0 unverified premises (the three provider probes are named as unknowns, not premises)
- Architecture Review: 4 issues found (F1, F2, F3, C2)
- Code Quality Review: 1 issue found (C3)
- Test Review: diagram produced, 0 unplanned gaps (24 planned tests)
- Performance Review: 0 issues found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 0 items proposed to user
- Failure modes: 0 critical gaps flagged
- Unresolved decisions: 0 in this review
- Outside voice: Codex (gpt-6-astra), completed, 3 findings, all confirmed (R5, R6, C4)
- Parallelization: 2 lanes, 2 parallel / 3 sequential
- Lake Score: 5/5

REALITY: premise-table pass 0 unverified; receipts in each ledger record docs/designs/scripts-on-every-workroom.md:220
REALITY: already-done pass no master commit since 2026-10-10 runs remote scripts, checked at 7aa01ecfa
REALITY: surface-check pass existing flags (`--with-workrooms`, `--from-disk`) and APIs (`communicate`, agent `stat`) read in source `cmd/delete_project.go:85`
REALITY: binding-decisions pass D1 to D4 and R1 to R6 honoured docs/designs/scripts-on-every-workroom.md:11
REALITY: numbers pass only [estimated] efforts; the 610 s cap is from vcs/crates/wr-agent/src/vcs.rs:32
REALITY: deferred-asks pass every owner ask (remote scripts, parity, local Delete Anyway, sheet copy) is in the plan docs/designs/scripts-on-every-workroom.md:26
REALITY: pr-count pass one PR (minimise-PRs rule), stacked on #495 docs/designs/scripts-on-every-workroom.md:196

### Suppressed findings (appendix)

- (confidence 4/10) A script that exits 124 on its own reads as a timeout if the app keys on the
  status alone. Design §1 already says `run-script` names the cause on stderr; low cost (a message
  label), so no decision.
- (confidence 4/10) Silence bound 610 s against probe time plus a silent 600 s script: both end as
  failures either way; only the label could differ.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Outside Review | Codex via `/plan-eng-review` | Independent 2nd opinion | 1 | completed | 3 findings, all confirmed and resolved (R5, R6, C4) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | ISSUES OPEN | 5 issues, 0 critical gaps; all resolved in the ledger |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **OUTSIDE COVERAGE:** Codex (gpt-6-astra), plan-review phase, completed, 3 findings (1 High, 2 Medium).
- **CROSS-MODEL:** Codex found the relay gap, the stale-state retry and the start-error misclassification, none of which the native pass raised; the native pass found the agent-version, config-only and sheet-copy issues, which Codex did not repeat. No disagreements.
- **VERDICT:** no review CLEAR (Eng Review found issues, all approved into the plan); eng review required: ISSUES OPEN means mapped work, not open decisions.

NO UNRESOLVED DECISIONS
