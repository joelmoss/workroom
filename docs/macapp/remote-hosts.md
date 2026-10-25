# Workroom creation and remote-host architecture

Paths beginning `Core/`, `Packages/`, `Resources/` and `Scripts/` are relative to `macapp/`.
Read [host states](../remote-host-states.md) before performing an action on a host.

## Creating a workroom (#483)

Every create, local, container or remote, and from any door (sidebar, context menu, File ▸ New
Workroom…), is a `CreationRun` (`Core/CreationRun.swift`) in `ProjectStore.creationRuns`, shared by
every window. Its pane opens on the click, before any work: beside the split anchor, or as the
selection, as a `.creation(project:id:)` target that becomes the workroom's
`.workroom(project:name:)` in place once it has a name (`creationRunForTarget` records it before
the reload that publishes it, so no window mounts a terminal there early). While a run lasts, its
pane draws `Views/CreationPane.swift` bare (no title bar, so no ✕ or menu) and
`removeWorkroomSplitMember` refuses a running one. The pane lists the kind's plan of steps
(`CreationKind.plan`; a local create leaves out the setup script's row when the project has no
`scripts/workroom_setup`, and `CreationRun.begin` puts it back if a script runs anyway), fed by
the CLI's NDJSON `step` and `log` events for a local create and by
`ProvisioningProgress.$reportStep` and `$log` for the others; what it says lives in
`CreationPanePresentation`, which is unit-tested. On success the checklist stays with Done until
it is clicked, or with `closeCreationPaneWhenDone` on, for `creationSuccessHold` (3 s); then the
run is dropped and the terminal mounts. An armed auto-run starts at success, not then: backgrounded
beside the shell the terminal opens on. On failure the run stays for its footer (Try Again, Close, Open Anyway or Delete Workroom). `creatingWorkrooms`, the
delete guard, is released when the create's process ends, not when the run goes. Creates in one
project may overlap; only a project being deleted blocks one. A provider's setup sheet holds the run
on its `account` step and Create Workroom carries the same run on (`RemoteSetupWait`). VoiceOver
hears three moments only, from the store: the sheet, a failure and a success
(`AppStore.announceCreation`). `-WorkroomUITestScriptedCreate 1` plays a local create in fixture
mode (`ScriptedCreateCLI`), for UI tests.

## Git credentials on a host

Workroom gives a remote provider's host no git credential (ADR 0049): a boxd machine uses the
user's boxd `git` integration, and an exe.dev VM an exe.dev GitHub integration per repository, which
`ExeDevHostDriver.grantGitHub` adds before the VM when none names the repository. The integration
answers only at `github.int.exe.xyz`, so `ExeDevHostDriver.create` runs
`Resources/host-setup/exedev-github.sh` to rewrite GitHub remotes there and set `GH_HOST`. A clone
that fails says the provider's fix (`RemoteWorkrooms.Place.credentialHint`). A local container's git
asks the Mac's own `gh` through `CredentialRelay` (#309), whose daemon side is `workroomd credential`
(`vcs/crates/workroomd/src/credential.rs`). A new user's first exe.dev create walks them through
exe.dev's own setup first (`ExeDevSetupSheet`); try it as a user exe.dev has never seen with
`make app-run-exedev-fresh`.

## boxd driver (#256)

`HostDrivers/ExeDevHostDriver.swift` is the second (#259): exe.dev VMs driven through exe.dev's ssh API
(`ssh exe.dev <cmd> --json`) and reached over the user's own ssh: their `~/.ssh/config`, keys, agent
and Keychain, as `ssh exe.dev` in Terminal, with only `ExeDevHostDriver.sshOptions` set over them
(nothing registered on the account). An app opened from Finder gives every ssh it runs, account
commands and VMs alike, the login shell's `SSH_AUTH_SOCK`; a VM's spawned ssh also gets the login
shell's `PATH`, for a `ProxyCommand` helper. A VM's host key is checked as `exe.dev`'s
(`HostKeyAlias`). A host is `new` plus `systemd.sh`, with no base to copy; `rm` exits 0
whatever happened, so a delete reads what it printed. Both drivers' shared live cases are in
`WorkroomAppTests/ProviderParityTestCase.swift`.

`HostDrivers/BoxdHostDriver.swift` is the first real provider: boxd machines driven through the `boxd`
CLI (`--json`) and reached over `SSHTransport` (its `exec`,
`attachCommand` and `writeConfiguration` statics). Its ssh details come only from the blocks the
CLI manages in `~/.ssh/config` and `~/.ssh/known_hosts` (`SSHDetails`). A host is set up by
`Resources/host-setup/systemd.sh` (an identity unit and the daemon's supervisor, both systemd; shared
with every provider driver whose machines run systemd, #259). Every remote workroom is a fresh
machine of its own: `RemoteProvisioning.provision` has the driver `create()` it, then
clones and checks out the branch, and no driver derives a host from another. The identity unit
stays: every fresh boxd machine boots with the image's machine-id and ssh host key (measured,
2026-10-10). The CLI acts in boxd's active org, so the driver
is told its org and account (`Configuration.org`, `Configuration.account`; every personal
account's org is nil, so the org alone cannot tell two accounts apart) and refuses to act while
another is active (#356). Machines are named
`<prefix>-<host id>`, so cleanup and a relaunched app find them by ID; a delete also removes the
snapshot an older build's derive may have left under that name. Bases older builds recorded stay
until a follow-up retires them (`TODOS.md`); Delete Project still takes them down. `BoxdIntegrationTests`
make real machines: they run only with `TEST_RUNNER_WR_BOXD_TESTS=1`
and the sandbox off. The app reaches it from New Workroom › Remote › boxd (#356): `RemoteHosts`
holds any driver by `DriverKey` (a container runtime or a boxd org and account), a background read
of a boxd host asks boxd first and leaves an asleep box asleep, and nothing lets go of an idle
connection: a box an open app holds awake is the user's to free, by deleting its workroom (#380).
Signed out, every boxd command that needs an account opens boxd's browser sign-in and waits
there, so the driver runs boxd only with a sign-in it can read (`BoxdHostDriver.cli`). Never hand
boxd that token as `BOXD_TOKEN`: it takes it for an API key and then writes no ssh stanza for the
machines it makes, so every create fails. A new user's first boxd create walks them through `BoxdSetupSheet`
(install, sign in, GitHub), on the same shell as exe.dev's (`RemoteSetupSheet`); try it as a user
boxd has never seen with `make app-run-boxd-fresh`. See `docs/designs/boxd-first-time-setup.md`.
The decisions behind it are ADR 0017 (a fresh host per workroom, no wakefulness obligation),
ADR 0036 (Release and Nightly share provider hosts), ADR 0038 (pending-only cleanup sweeps) and
ADR 0049 (hosts bring their own git credentials).

## Remote workrooms in config (#249)

A workroom or project entry in `config.json` can carry a `"host"` object, which `list --json`
passes through as `host`. The app owns its schema (`HostDescriptor` in
`Packages/WorkroomDomain/Sources/WorkroomDomain/Model.swift`); the CLI reads only whether a
workroom has one (remote) and `state == "destroyed"`. `workroom host set|clear` (#252) writes one
verbatim on an existing entry, and the app calls it through `WorkroomCLI.setHost`.
Every CLI config write preserves an existing one, so a change to a config writer must keep `host`,
or a remote workroom silently turns local. What the app relies on:

- `TerminalTarget.unavailability` is `.directoryMissing`, `.remote` or `.hostDestroyed`, and
  `isMissing` is derived from it. A new local action should guard on `isMissing`, as the existing
  ones do. Only rendering sites should tell the three cases apart.
- A remote workroom's `path` is not a path on this Mac. Code that probes, watches or registers
  paths must skip `Workroom.isRemote`, as `RepositoryRouter.prepare`, `statusWorkItems` and
  `selectedStatusWorkItem` do.
- Deleting a live remote workroom is app-only: the app destroys the host, then has the CLI drop
  the entry. The CLI deletes only a workroom whose host is already `destroyed`, and refuses the
  rest with `RemoteWorkroomUnsupported` (ADR 0040).
- Session restore is gated on availability (#253): `PersistentSessionRecovery` reattaches only
  targets `AppStore.reattachesLocally` accepts, and an unreachable remote workroom's saved session
  is held in `deferredTargetSessions` until its first pane opens.
- Doing something on a host (a connect, an exec, a script, a delete): read
  `docs/remote-host-states.md` first. It lists the states a host can be in (stopped, asleep, gone,
  connecting, an older daemon), the call that reaches it in each (`activate`, then
  `ensureConnected(wake: true)` for what the user asked for), and what an exit status means over ssh.
