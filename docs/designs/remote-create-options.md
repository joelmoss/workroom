# Host options: image, size and extra arguments for boxd and exe.dev hosts

Status: decided by grilling on 2026-11-04, not built. Terms: **Host options** and **Host image**
in [`CONTEXT.md`](../../CONTEXT.md). Why the options are this Mac's settings and not the repository's:
[ADR 0065](../adr/0065-host-options-are-this-macs-not-the-repositorys.md).

Today a boxd or exe.dev host is created with the provider's defaults: `boxd machine new <name>`
(`BoxdHostDriver.create`) and `ssh exe.dev new --name <name> --no-email` (`ExeDevHostDriver.create`).
With this change, the user can choose the host's image, its size, and extra arguments for the
provider's create command. They can be set in Settings for every project, in Project Settings for
one project, or for a single create. Container workrooms are not affected: their image and size
belong to devcontainer.json (ADR 0060).

## 1. What each provider accepts

Measured from each CLI's help on 2026-11-04.

| Option | exe.dev `new` | boxd `machine new` |
|---|---|---|
| Host image | `--image <container image>` | `--from-snapshot <name>`: a snapshot of one of the account's machines, memory and disk |
| Size | `--cpu N`, `--memory 8GB`, `--disk 50GB` (root disk size), each within the plan | `--vcpu 1\|2\|4\|8`: one of four fixed sizes (1/4G, 2/8G, 4/16G, 8/32G). boxd refuses it with a snapshot: "--vcpu/--memory only apply to fresh machines; forks and snapshot restores keep their source's size" |
| Extra arguments | anything else `new` takes | anything else `machine new` takes |

boxd's `--team` (boot from a team's default snapshot) is left out, because a team's snapshot can be
named as a snapshot. boxd's `--disk` attaches an existing named disk rather than setting a size, so
it is left to extra arguments.

## 2. Which host images work

`Resources/host-setup/systemd.sh` makes a host a Workroom host. It needs systemd as PID 1, `sudo`,
`runuser`, `getent`, git and a POSIX `sh`.

**boxd snapshots** (spike, 2026-11-04). A snapshot holds memory as well as disk, so a host made from
one *resumes* instead of booting. The restore took about a second. The new host had a new hostname,
but the identity unit never ran, so it kept the source's `/etc/workroom-identity` marker and
`/etc/machine-id`. Running `systemd.sh` again exited 0 and changed nothing. `boxd machine reboot`
fixed it: on that boot the identity unit minted a new identity and machine-id. So after
`--from-snapshot` the driver reboots the host and waits for systemd before setup. The creation
checklist shows this as its own step, "Restarting host from snapshot". Setup on a restored host also
clears the daemon's screens and layouts, so a snapshot of a used Workroom host brings back none of
its terminals. A fresh boxd host logs in as `boxd` (uid 1000, in the sudo group), with systemd as
PID 1.

**exe.dev images** (spike, 2026-11-04). The default image, `boldsoftware/exeuntu`, boots systemd,
logs in as `exedev` (uid 1000, with sudo), has git, and passed setup first time. A stock
`ubuntu:24.04` does not work: PID 1 is exe.dev's own `exe-init`, there is no `systemctl`, `sudo` or
`git`, and ssh as `exedev@` logs in as root, so setup exits 127. Neither `new --json` nor
`ls --json` reports a VM's login user (`ls --json` does report its `image`), so the driver keeps
`exedev`. What an image contains is exe.dev's and the user's concern, not Workroom's: Workroom
passes `--image` through and doesn't check it first or explain image requirements in the field
(owner, 2026-11-04).

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

Each level keeps one set of options per provider:

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
  var extraArguments: HostOption<String>?  // replaces lower levels whole, never merged
}
```

When the resolved boxd image is a snapshot, size is resolved to nothing and its controls are
disabled with boxd's reason ("a snapshot keeps its own size").

**Extra arguments** are split into words using shell quoting rules but never run through a shell,
and are added after Workroom's own flags. The flags Workroom sets itself are refused with a message
naming them: `--name` and `--json` on both providers, `--fork` and `--from-snapshot` on boxd,
`--no-email` on exe.dev. Flags that duplicate a typed option (`--image`, `--cpu`, `--memory`,
`--disk` on exe.dev, `--vcpu`/`--memory` on boxd) are refused with a pointer to the typed field.
Everything else is the user's choice and is passed through. boxd's `--auto-destroy-timeout`, which
deletes the host under a live workroom, gets a warning but is not blocked. A refused flag is shown
as an inline error when saved, and checked again at create.

**Storage.** The app is the only reader (the CLI makes no remote workrooms), so these live in
`Defaults` beside run commands: `Defaults[.hostOptions]: [Provider: HostOptions]` for Settings, and
`Defaults[.projectHostOptions]: [ProjectPath: [Provider: HostOptions]]` for projects.

## 4. UI

**Settings ▸ Remote Hosts** is a new pane with one group each for boxd and exe.dev. Both always
show, because setting options needs no account. A group whose provider isn't set up says so in its
footer. Fields save live.

- boxd: *Host image* is a combo box filled from `boxd snapshots list --json` (which gives name,
  version, status, size and used space, but no id or date), and you can also type a name. If the
  saved name isn't in the loaded list, the field warns "No snapshot named X in this account". Saving
  is still allowed, because the list can fail to load. *Size* is a picker of the four sizes.
- exe.dev: *Host image* is a text field. *CPU* and *Memory* are pickers capped by
  `billing plan --json` (`max_cpus`, and memory to match). *Disk* is a number field whose
  placeholder is the plan's `default_disk_gb`. If the plan can't be read, these become free text.
- Both: *Extra arguments*, a text field.

**Project Settings ▸ Remote Hosts** has the same fields, saved with the rest of the sheet on Save.
Placeholders show what's inherited from Settings.

**At create time**, picking a place still creates straight away with the resolved options. Each
boxd and exe.dev row in the New Workroom dialog gets an "Options…" button, also reachable with ⌘⏎
on the highlighted row. The sidebar's New Workroom menu gets "boxd Options…" and
"exe.dev Options…". Both open a panel showing every resolved value and where it came from ("from
project", "from Settings"), with a **Remember for this project** checkbox that saves only the
fields you changed there.

**A failed create.** Try Again uses the options chosen at create time, and reads Settings and
Project Settings afresh for the rest. When non-default host options were used and the failure came
while making, booting or setting up the host, **Try With Provider Defaults** runs the same create
once with no host image, size or extra arguments. Saved settings are left unchanged.

**Details pane.** A remote workroom shows the host options it was made with: image, size, and the
extra arguments as they were passed.

## 5. Code reach

- `HostDrivers/HostDriver.swift`: `ProvisioningHostDriver.create()` becomes
  `create(options: ResolvedHostOptions)`.
- `BoxdHostDriver.create`: adds `--from-snapshot`/`--vcpu` and the extra arguments to `machine new`.
  After a snapshot it runs `machine reboot`, then the boot wait, then setup with the restored-host
  cleanup.
- `ExeDevHostDriver.create`: adds `--image`/`--cpu`/`--memory`/`--disk` and the extra arguments to
  `new`. The login user stays `exedev`. Both drivers name the host image in their boot and setup
  failure messages when one was set.
- `systemd.sh`, or a sibling step: on a restored host, clear the daemon's screens and layouts.
- `RemoteWorkrooms.Place` / `CreationKind` / `AppStore.createRemoteWorkroom` → `runRemoteCreate`:
  carry the create-time options, resolve them at create, and keep them for Try Again. Add Try With
  Provider Defaults to the creation run.
- `HostDescriptor`: `madeWith: ResolvedHostOptions?` for the Details pane. Older records decode
  with nil.
- Views: a new `SettingsPane.remoteHosts`, `ProjectSettingsSheet`, `NewWorkroomDialog`, the sidebar
  New Workroom menu, and the options panel.
- Tests: resolution (one table test covering inherit, Provider default, value, and snapshot
  disabling size); each driver's argument list (the existing runner fakes); refused extra
  arguments; Try Again keeping the options; `HostDescriptor` decoding without `madeWith`.

## 6. Delivery

One PR, one commit per step. exe.dev's part is built and unit-tested with the rest. The PR is
merged only after one live exe.dev create with `--image=boldsoftware/exeuntu` set explicitly
passes, which proves the flag reaches exe.dev.

Sizes over the plan are refused by exe.dev with its own clear error, shown as it comes, for
example "--cpu cannot exceed 2 — run `billing capacity` to upgrade to a larger plan with more
cpu/memory". `--cpu 1 --memory 2GB --disk 10GB` was accepted (spike, 2026-11-04).

Follow-up issue, not in this PR: **Save as Host Image**, which saves a boxd workroom's host as a
snapshot from the app.

## 7. Open

Nothing. Every question was settled by the 2026-11-04 grilling and its spikes.
