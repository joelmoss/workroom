# Host options: image and size for boxd and exe.dev hosts

Status: shipped in #580 (merged 2026-11-05; issue #575). Its Save as Host Image follow-up (#576)
is open. Decided by grilling on 2026-11-04 and amended by its eng review the same day (section 7).
Terms: **Host options** and **Host image** in [`CONTEXT.md`](../../CONTEXT.md). Why the
options are this Mac's settings and not the repository's:
[ADR 0065](../adr/0065-host-options-are-this-macs-not-the-repositorys.md).

Today a boxd or exe.dev host is created with the provider's defaults: `boxd machine new <name>`
(`BoxdHostDriver.create`) and `ssh exe.dev new --name <name> --no-email` (`ExeDevHostDriver.create`).
With this change, the user can choose the host's image and its size. They can be set in Settings
for every project, in Project Settings for one project, or for a single create. Container workrooms
are not affected: their image and size belong to devcontainer.json (ADR 0060).

## 1. What each provider accepts

Measured from each CLI's help on 2026-11-04.

| Option | exe.dev `new` | boxd `machine new` |
|---|---|---|
| Host image | `--image <container image>` | `--from-snapshot <name>`: a snapshot of one of the account's machines, memory and disk |
| Size | `--cpu N`, `--memory 8GB`, `--disk 50GB` (root disk size), each within the plan | `--vcpu 1\|2\|4\|8`: one of four fixed sizes (1/4G, 2/8G, 4/16G, 8/32G). boxd refuses it with a snapshot: "--vcpu/--memory only apply to fresh machines; forks and snapshot restores keep their source's size" |

The providers' other create flags (boxd's `--networks`, `--isolated`, `--team`, `--disk`; exe.dev's
`--tag`, `--egress`, `--env`, `--registry-auth` and others) are not reachable from Workroom. A typed
option is added when a real need shows up (section 7, D2b).

## 2. Which host images work

`Resources/host-setup/systemd.sh` makes a host a Workroom host. It needs systemd as PID 1, `sudo`,
`runuser`, `getent`, git and a POSIX `sh`.

**boxd snapshots** (spike, 2026-11-04). A snapshot holds memory as well as disk, so a host made from
one *resumes* instead of booting. The restore took about a second. The new host had a new hostname,
but the identity unit never ran, so it kept the source's `/etc/workroom-identity` marker and
`/etc/machine-id`. Running `systemd.sh` again exited 0 and changed nothing. `boxd machine reboot`
fixed it: on that boot the identity unit minted a new identity and machine-id.

So a snapshot create runs: `machine new --from-snapshot`, then setup (which writes the current
identity unit), then `boxd machine reboot`, then the existing identity wait, which polls through a
reboot. On that boot the identity unit mints a new identity and machine-id and empties the daemon's
screens and layouts (the layouts directory sits beside the screens directory, `layout.rs`), so a
snapshot of a used Workroom host brings back none of its terminals. Clearing both is the identity
unit's job for any new identity, a renamed machine's included; setup has no restored-host mode. The
creation checklist shows the restart as its own row, "Restarting host from snapshot", after "Set up
machine". A fresh boxd host logs in as `boxd` (uid 1000, in the sudo group), with systemd as PID 1.

A snapshot of a used workroom of the same project still holds that workroom's checkout at the clone
destination, `/home/boxd/<repo>`, and `git clone` refuses a folder that isn't empty. So on a host
made from a snapshot the app removes the old checkout right before the clone, and only that: a git
checkout at the destination whose `origin` is the repository being cloned. Anything else there (a
host folder a repository shares its name with, such as `.local`, which holds the daemon) stays, and
the create fails saying so (review, 2026-11-05). The new workroom starts from a fresh clone, with
none of the old workroom's branch, uncommitted work or `.env`; anything installed outside the
checkout (the toolchain) stays.

**exe.dev images** (spike, 2026-11-04). The default image, `ghcr.io/boldsoftware/exeuntu` (`ls
--json` names it `boldsoftware/exeuntu`, but `--image=boldsoftware/exeuntu` is looked up on Docker
Hub, which hasn't it: live gate, 2026-11-04), boots systemd,
logs in as `exedev` (uid 1000, with sudo), has git, and passed setup first time. A stock
`ubuntu:24.04` does not work: PID 1 is exe.dev's own `exe-init`, there is no `systemctl`, `sudo` or
`git`, and ssh as `exedev@` logs in as root, so setup exits 127. Neither `new --json` nor
`ls --json` reports a VM's login user (`ls --json` does report its `image`), so the driver keeps
`exedev`. What an image contains is exe.dev's and the user's concern, not Workroom's: Workroom
passes `--image` through and doesn't check it first or explain image requirements in the field
(owner, 2026-11-04).

exe.dev parses the words of `ssh exe.dev <command>` again on its side, and honours POSIX quotes
(probe, 2026-11-04). The driver quotes every argument it sends, so a value with a space, such as a
free-text memory of `8 GB`, arrives as one word.

When a host image fails, the failure is caught at the existing boot or setup step, and the
create's existing `undo` removes the host. Only the message changes: when a host image was set, it
names the image and what Workroom's setup needs, for example "Workroom's setup didn't run on
`ubuntu:24.04`: it needs systemd, sudo and the exedev user." The creation pane then offers
**Try With Provider Defaults** beside Try Again (§4).

## 3. Levels and resolution

Each key is resolved separately, and the most specific level wins:
**this create → project → Settings → the provider's own default.** Each field has three states:
*inherit* (the default; its placeholder shows the value it will get, as base branch does),
*Provider default* (explicitly none, so a project that names a snapshot can still make a fresh
host), or a value.

Each level keeps one set of options per provider. The types and the resolver live in
WorkroomDomain, beside `HostDescriptor`, which records the resolved options:

```swift
enum HostOption<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
  case providerDefault
  case value(Value)
}  // absent (nil) = inherit

struct HostOptions: Codable, Hashable, Sendable {
  var image: HostOption<String>?       // exe.dev --image; boxd --from-snapshot
  var cpu: HostOption<Int>?            // exe.dev --cpu; boxd --vcpu
  var memory: HostOption<String>?      // exe.dev only; boxd's size follows cpu
  var disk: HostOption<String>?        // exe.dev only (root disk size)
}
```

One resolver returns each resolved value with the level it came from. The create, the project
fields' placeholders and the Options panel's "from project" / "from Settings" labels all read it;
no view works out a value on its own. When the resolved boxd image is a snapshot, size is resolved
to nothing and its controls are disabled with boxd's reason ("a snapshot keeps its own size").

**Storage.** The app is the only reader (the CLI makes no remote workrooms), so these live in
`Defaults` beside run commands: `Defaults[.hostOptions]: [Provider: HostOptions]` for Settings, and
`Defaults[.projectHostOptions]: [ProjectPath: [Provider: HostOptions]]` for projects.

## 4. UI

**Settings ▸ Remote Hosts** is a new pane with one group each for boxd and exe.dev. Both always
show, because setting options needs no account. A group whose provider isn't set up says so in its
footer. Fields save live.

- boxd: *Snapshot* is a combo box filled from `boxd snapshots list --json` (which gives name,
  version, status, size and used space, but no id or date), and you can also type a name. If the
  saved name isn't in the loaded list, the field warns "No snapshot of that name in this boxd
  account - help". Saving is still allowed, because the list can fail to load. *Size* is a picker
  of the four sizes, faded and disabled while a snapshot is set.
- exe.dev: *Custom image* is a text field. *CPU* and *Memory* are pickers capped by
  `billing plan --json` (`max_cpus`, and memory to match). *Disk* is a picker of fixed sizes up to
  the plan's maximum, with its `default_disk_gb` among them. If the plan can't be read, these
  become free text.

In each list the provider's default is marked **(default)**, and in a project's a value from
Settings is marked **(app)**. The snapshot list and the plan are read off the main actor when a
section appears, per provider, each section keeping its height while it waits. A good read is
kept for two minutes and shared by every screen; the Settings window reads afresh as it opens. The
one-click create never waits on them: it resolves from `Defaults` alone.

**Settings ▸ Projects** (built in place of Project Settings ▸ Remote Hosts, 2026-11-05) lists the
projects; one's settings have the same fields, saved as they change.

**At create time**, picking a place still creates straight away with the resolved options. Each
boxd and exe.dev row in the New Workroom dialog gets a "Configure…" button, also reachable with ⌘⏎
on the highlighted row (on other rows ⌘⏎ still creates, and ⌥⌘⏎ keeps asking for a split). In the
sidebar's New Workroom menu, boxd and exe.dev are submenus with "Create" and "Configure…".
Configure… opens a panel showing every resolved value and where it came from, with a **Remember
for this project** checkbox that saves only the fields you changed there.

**A failed create.** Try Again uses the options chosen at create time, and reads Settings and
Project Settings afresh for the rest. When non-default host options were used, the failure came
while making, booting, restarting or setting up the host, and nothing was left running,
**Try With Provider Defaults** runs the same create with Provider default for image and size. It
sets those as the run's create-time options, so a Try Again after it repeats it, and it isn't
offered again on that run. When the machine was left behind, the pane offers Delete only, as today.
Saved settings are left unchanged.

**Details pane.** A remote workroom shows the host options it was made with: image and size.

## 5. Code reach

- `HostDriver.swift`, `ContainerHostDriver` and `RemoteProvisioning` are unchanged:
  `ProvisioningHostDriver.create()` keeps its shape.
- `BoxdHostDriver.create(options:)` and `ExeDevHostDriver.create(options:)` are the drivers' own
  methods, reached through `RemoteProvisioning.Environment.makeHost`, as a container's
  `create(spec:)` is.
- `BoxdHostDriver`: adds `--from-snapshot`/`--vcpu` to `machine new`. After a snapshot it runs
  setup without the identity wait, then `machine reboot`, then `awaitIdentity`.
- `ExeDevHostDriver`: adds `--image`/`--cpu`/`--memory`/`--disk` to `new`, and `run` quotes every
  argument for exe.dev's parser. The login user stays `exedev`. Both drivers name the host image in
  their boot and setup failure messages when one was set.
- `systemd.sh`: the identity unit also empties the layouts directory beside the screens when it
  mints.
- `ProvisioningProgress.Step`: a step for "Restarting host from snapshot", listed in
  `CreationKind.onDemand` so a plain boxd create doesn't show it.
- `CreationRun` carries the create-time options and `retryCreation` copies them, as it does
  `skipsSetup`. `RemoteWorkrooms.Place` and `CreationKind` are unchanged: `Place` keys the shared
  provider setup sheet. `runRemoteCreate` resolves the options, sets `makeHost`, and on a snapshot
  create removes the old checkout of the same repository before the clone. Try With Provider Defaults sits beside
  Try Again in `CreationPanePresentation`, only for `.remoteFailed(leftBehind: false)`.
- `HostDescriptor`: `madeWith: ResolvedHostOptions?` for the Details pane. Older records decode
  with nil. The CLI stores the descriptor verbatim (`internal/config`), so it needs no change.
- Views: a new `SettingsPane.remoteHosts`, `ProjectSettingsSheet`, `NewWorkroomDialog`, the sidebar
  New Workroom menu, and the options panel.
- Tests: resolution (one table test covering inherit, Provider default, value, and snapshot
  disabling size); each driver's argument list and the snapshot command order (the existing runner
  fakes); exe.dev quoting; Try Again keeping the options and Try With Provider Defaults (the
  creation flow's injected services); the clone destination removed only on a snapshot create;
  `HostDescriptor` decoding without `madeWith`.

## 6. Delivery

One PR, one commit per step. exe.dev's part is built and unit-tested with the rest. The PR is
merged only after two live creates pass: one exe.dev create with
`--image=ghcr.io/boldsoftware/exeuntu` set explicitly, which proves the flag reaches exe.dev
(passed 2026-11-04, `ExeDevIntegrationTests.testACreateWithAHostImageMakesTheVMFromIt`), and one
boxd create from a snapshot of a used workroom of the same project, which must finish with a new
identity and machine-id and none of the old screens, layouts or checkout (passed 2026-11-04,
`BoxdIntegrationTests.testAMachineFromASnapshotOfAUsedHostStartsClean`).

Sizes over the plan are refused by exe.dev with its own clear error, shown as it comes, for
example "--cpu cannot exceed 2 — run `billing capacity` to upgrade to a larger plan with more
cpu/memory". `--cpu 1 --memory 2GB --disk 10GB` was accepted (spike, 2026-11-04).

Follow-up issue, not in this PR: **Save as Host Image** (#576), which saves a boxd workroom's host as
a snapshot from the app.

## 7. Eng review (2026-11-04)

The owner's answers:

- D1: the drivers' create takes options as their own method, through `makeHost`; the protocol, the
  container driver and `Place` stay as they are.
- D2b: no extra-arguments field. It brought most of the review's risk: `--team` restores a team's
  default snapshot without the restart, exe.dev parses words again, `--registry-auth` and `--env`
  would put secrets in config.json and the Details pane, and the refused-flag list would have to
  follow two CLIs. Dropping it is the reversible choice.
- D3: the identity unit clears layouts as well as screens; a snapshot create sets up, then restarts.
- D4: Try Again after Try With Provider Defaults repeats it.
- D5 (found by the Codex outside voice): a snapshot create removes the old checkout before cloning.
- Also: exe.dev arguments are quoted, and Try With Provider Defaults is never offered when a machine
  was left behind (Codex).
