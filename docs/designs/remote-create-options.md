# Remote create options: image and size for boxd and exe.dev workrooms

Status: proposal, 2026-11-04. Nothing built. Owner decisions are marked **Decide**.

A boxd or exe.dev workroom is made today with the provider's defaults: `boxd machine new <name>`
(`BoxdHostDriver.create`) and `ssh exe.dev new --name <name> --no-email` (`ExeDevHostDriver.create`).
This proposal lets the user choose what the machine is made from and how big it is. They can set it
in Settings for every project, in Project Settings for one project, or for a single create.

Background: [`remote-workrooms.md`](remote-workrooms.md), ADR 0060 (container images come from
devcontainer.json), ADR 0054 (script approval), ADR 0014 (config.json is an untyped map).

## 1. What each provider accepts

Measured from each CLI's help on 2026-11-04 (boxd 0.2.x `machine new --help`, `ssh exe.dev help new`).

| Option | exe.dev `new` | boxd `machine new` |
|---|---|---|
| Image | `--image <container image>` | none. The closest equivalent is `--from-snapshot <name\|id>`, or `--team <team>`, which boots from that team's default snapshot |
| CPU / memory | `--cpu N`, `--memory 8GB` (each set on its own, within the plan's limits) | `--vcpu 1\|2\|4\|8` or `--memory 4G\|8G\|16G\|32G`, which pick the same fixed size (1/4G, 2/8G, 4/16G, 8/32G). Fresh machines only: a snapshot keeps the snapshot's size |
| Disk | `--disk 50GB` (size of the root disk) | `--disk <disk>[:mount][:ro]` attaches an *existing* named disk. It is not a size. Fresh machines only |

Left out of this proposal: `--env`, `--setup-script`, `--integration`, `--tag`, `--egress`, `--pool`,
`--standalone`, `--registry-auth` (exe.dev), and `--networks`, `--isolated`, `--shared`,
`--auto-*-timeout` (boxd). Workroom already covers env and setup through `scripts/workroom_setup`.
Registry auth is a secret and would need the Keychain. The rest can be added later as rows in the
same model if someone asks for them.

## 2. Which images work

`Resources/host-setup/systemd.sh` makes the machine a Workroom host. It needs systemd as PID 1,
`sudo`, `runuser`, `getent`, git and a POSIX `sh`. `ExeDevHostDriver.user` is fixed to `exedev`.
`awaitBoot` polls `systemctl is-system-running`.

- **exe.dev.** exe.dev's default image, exeuntu, installs `systemd systemd-sysv`, `sudo` and
  `openssh-server` itself (its [Dockerfile](https://github.com/boldsoftware/exeuntu/blob/main/Dockerfile)).
  So a stock `ubuntu:24.04` most likely boots without systemd and fails setup. exe.dev's docs don't say
  which init a custom image gets or which user it logs in as. An image's `exe.dev/login-user` label can
  change the ssh user, which breaks the fixed `exedev`. **Spike 1** (before building): create one VM
  each from `ubuntu:24.04`, an image `FROM exeuntu`, and an image with a `login-user` label. Record
  PID 1, the login user, sudo, and whether `new --json` reports the user. The docs should then say:
  "an exe.dev image must run systemd and have passwordless sudo; build it `FROM` exeuntu". If
  `new --json` reports the login user, the driver reads it instead of assuming `exedev`. Otherwise the
  image must keep `exedev`. **Decide:** support other login users, or require `exedev`?
- **boxd.** A snapshot is a copy of a boxd machine, so it has boxd's systemd image. Snapshots share
  one machine-id and one set of ssh host keys, which the `workroom-identity` unit already handles
  (it was built for exactly that). A snapshot may already hold an old `workroom-daemon` unit or daemon
  binary. Setup is safe to run again and rewrites the units, so that is fine. **Spike 2:** confirm
  with one snapshot taken from a machine that was a Workroom host.
  **Decide:** should boxd's "image" be a snapshot (and/or a team), or should boxd get size only?

An image that fails is caught at the boot or setup step, and the create's existing `undo` removes
the machine. Today, after about 60 s of polling, it says "never finished booting". For a non-default
image the message should name the image and what it is missing, for example:
"`ubuntu:24.04` didn't start systemd. exe.dev images for Workroom need systemd and sudo; build yours
FROM exeuntu."

## 3. The three levels

Each key is resolved separately, and the most specific level wins:
**this create → project → app (Settings) → the provider's own default.** An empty value at any
level means "use the level below". The field's placeholder shows that value, the same way Project
Settings' base branch does ("App default: develop"), so the user can always see what a create will
use without opening another window.

Options belong to a provider. An exe.dev image means nothing to boxd, so each level keeps one set of
options per provider:

```swift
/// What a provider host is made from. nil = inherit.
struct RemoteCreateOptions: Codable, Hashable, Sendable {
  var image: String?    // exe.dev --image; boxd --from-snapshot
  var cpu: Int?         // exe.dev --cpu; boxd --vcpu (1, 2, 4, 8)
  var memory: String?   // exe.dev --memory; boxd derives it from cpu, so no field
  var disk: String?     // exe.dev --disk size; boxd: not offered (an attached disk is another feature)
}
```

`resolved = create.merging(project).merging(app)`, with each key taking the first non-nil value.

### Storage

The app is the only thing that reads these. The CLI makes no remote workrooms, so they don't go in
config.json. They live in `Defaults`, like run commands (`Defaults[.runCommands]`, keyed by project
path):

- `Defaults[.remoteCreateOptions]: [Provider: RemoteCreateOptions]`: the app level.
- `Defaults[.projectRemoteCreateOptions]: [ProjectPath: [Provider: RemoteCreateOptions]]`.

They don't go in the repository. A repository file naming an image or snapshot decides what runs
with this Mac's credentials. Under ADR 0054 that makes it a script, which brings Approve and Continue
Without. ADR 0060 made the container image the repository's choice because devcontainer.json already
names it. A boxd or exe.dev VM has no equivalent repository file, and a snapshot name only means
something in one account. So this belongs to the user, not the repository. A repository-level file
could be added later, behind ADR 0054's approval, if teams ask for one.

## 4. UI

**Settings ▸ Remote** (app level): one group per provider that is set up, with Image (exe.dev) or
Snapshot (boxd), Size, and Disk (exe.dev). They save live, as the base branch does. Size is a picker:
boxd's four sizes, and exe.dev's CPU/memory values within the plan limit `billing plan` reports.
Image and Snapshot are text fields. A snapshot picker filled from `boxd snapshots list --json` would
be nicer, and can come later.

**Project Settings ▸ Remote Workrooms**: the same fields, saved with the rest of the sheet's draft
on Save. Placeholders show the app value.

**At create time**: the dialog goes project → place, and one click or Return must still create with
the resolved defaults. Each boxd/exe.dev place row gets a trailing "Options…" button, also reachable
with ⌘⏎ on the highlighted row (⌥ is already used for split). It opens a small panel with the
resolved values, each labelled where it came from ("from project", "from Settings"), and a
"Remember for this project" checkbox. Create uses those values. The sidebar's New Workroom menu gets
"boxd Options…" and "exe.dev Options…" items, which open the same panel.

When a boxd snapshot is set, the size controls are disabled with the reason ("a snapshot keeps its
own size"), rather than being dropped without a word.

**Details pane**: a remote workroom shows what it was made from (image or snapshot, size), read from
the host record, the same way a container shows its devcontainer digest.

## 5. Code reach

- `HostDrivers/HostDriver.swift`: `ProvisioningHostDriver.create()` becomes
  `create(options: RemoteCreateOptions)`. The container and SSH drivers ignore it, or have none:
  SSH hosts don't conform, and containers keep their devcontainer.json.
- `BoxdHostDriver.create` adds `--from-snapshot`/`--vcpu` to `machine new`. `ExeDevHostDriver.create`
  adds `--image`/`--cpu`/`--memory`/`--disk` to `new`. A value starting with `-` is refused, since
  these are user strings passed as arguments and must not read as flags.
- `RemoteWorkrooms.Place` / `CreationKind` / `AppStore.createRemoteWorkroom(in:place:splitAnchor:)`
  → `runRemoteCreate`: carry the create-time options, and resolve them against the project and app
  levels at create time (as the project is re-read today for its base branch).
- `HostDescriptor` (the app owns its schema; ADR 0014 keeps the CLI from dropping it): add
  `madeFrom: RemoteCreateOptions?` for the Details pane. Older records decode with nil.
- Views: `SettingsView`, `ProjectSettingsSheet`, `NewWorkroomDialog`, and the sidebar New Workroom
  menu, plus the new options panel.
- Failure copy in both drivers' boot and setup steps (§2).
- Tests: the resolution order (one table test). Each driver's argument list for set and unset
  options (the existing `BoxdHostDriverTests` / `ExeDevHostDriverTests` runner fakes). Rejection of
  values that start with `-`. Decoding a `HostDescriptor` without `madeFrom`.

## 6. Phasing

1. Spikes 1 and 2 (§2). Real VMs, a few cents.
2. One PR, one commit per step: the model and resolution, drivers, Settings, Project Settings, the
   create-time panel, Details pane.

Open: **Decide** whether size and disk are in scope or this is image-only. Including them costs
little, because the plumbing is the same. On exe.dev's Small plan every VM shares 2 vCPU / 8 GB, so
asking for more fails with the plan's error. That error is shown as exe.dev sends it.
