# Railway Sandboxes as a remote host provider

Status: research, 2026-11-13. Sections 1–7 are from docs, CLI source and generated types, read-only. A live
spike the same day tested them: see [Spike results](#spike-results-2026-11-13), which supersedes this text
where they differ.

**Answer: feasible on paper through the SSH relay plus the GraphQL API, but it is a poor fit for Workroom's
host model, and a flat yes is not supported until a live spike answers the unknowns below.** A Railway sandbox is
a plain Linux VM that you can reach over ssh with a PTY, so `workroomd attach` can run in it the way it runs on an
SSH host. What does not fit is the lifecycle. A sandbox has no sleep state and no stop/start. An idle sandbox is
**destroyed**, with its disk, unless the user turned the idle timeout off (Hobby/Pro only) or Workroom keeps
sending heartbeats. [ADR 0017](../adr/0017-remote-workrooms-fresh-host-no-wakefulness.md) removed Workroom's
wakefulness obligation because boxd and exe.dev hosts sleep and wake on their own. A Railway driver would bring
that obligation back, or bill continuously.

Terms: sandbox = Railway's object; host = Workroom's. "Relay" = Railway's ssh gateway (`ssh.railway.com`).

## 1. What a Railway sandbox is

| Fact | Finding | Source |
|---|---|---|
| Isolation | "isolated Linux VMs", "fully isolated virtual machine". The hypervisor is **not documented**. | [S1] |
| Status | GA: "Railway Sandboxes are generally available", "available on every plan" (changelog 2026-09-18). The first CLI commit for `railway sandbox` is 2026-05-30, behind a `PROJECT_SANDBOXES` flag then. The docs' `vm-pricing-beta` anchor is an anchor name only; do not read it as a beta label. | [S9], [S6] commit `e474e43` |
| Base image | "Ubuntu base with git, Node, and common coding agents preinstalled" (Claude Code, Codex, OpenCode, Pi; mise toolchain, so use `bash -lc`). Customised by a template (ordered `apt-get`/`run` steps, cached about 7 days) or a checkpoint. `railway sandbox template build` takes `--base-image-digest`, so another base image is possible; what images are accepted is not documented. | [S1], [S2], [S4] |
| OS / arch | Ubuntu. **CPU architecture, kernel, systemd and disk size: not documented.** | [S1] |
| Resources | Default / max by plan: Trial and Free 2 vCPU / 2 GB (max the same); Hobby 4/4 default, 8/8 max; Pro 8/8 default, 32/32 max. Set with `resources` in the SDK or `sandboxCreate`. **The CLI has no resources or region flag** (`region: None` in source). | [S1], [S5] `sandbox.rs` L1053, L1529; [S7] `SandboxCreateInput` |
| Disk | Persists for the sandbox's life. Survives destruction only as a **checkpoint**, which restores to a new sandbox with files but no processes or memory. Disk quota: not documented. | [S1] |
| Limits | Sandboxes per environment (not per project): Trial/Free 10, Hobby 50, Pro 100, only `CREATING`/`RUNNING` count. Checkpoints per environment equal the same number. `exec` durable session keeps about the last 8 MiB of output. | [S1] |
| Regions | Four: `us-west2` (the default for a fresh sandbox, "regardless of your account's preferred region"), `us-east4-eqdc4a`, `europe-west4-drams3a`, `asia-southeast1-eqsg3a`. Chosen only through the SDK or API. | [S1], [S10] |
| Pricing | Per second, for CPU actually used, memory in use (including OS and page cache) and egress: $50/GB/month RAM, $50/vCPU/month CPU, $0.05/GB egress. Plans are $0 / $5 (Hobby) / $20 (Pro) a month, each including the same amount of usage. "Memory remains billable while a VM waits for work." Storage is not priced separately; **not documented**. | [S1], [S11] |
| Lifetime | The only documented end is the idle timeout. **No maximum lifetime is documented**, with the timeout off. | [S1] |

## 2. Access

| Path | Finding | Source |
|---|---|---|
| Interactive ssh | Yes. Railway uses the system `ssh` to a relay; "SSH keys are managed at Account Settings". CLI source: `ssh -p <none on production> sbx:<environmentId>:<sandboxId>@ssh.railway.com`, so the target is a **username on the relay**, not a hostname. The `sbx:` format is in CLI source ("per backboard"), **not in the docs**. PTY: ssh's own (`-t` when a command and both ends are ttys, `-T` otherwise). | [S3], [S5] `sandbox.rs` L1900-1960, `ssh/native.rs` L33-65, L326-430 |
| Durable ssh session | The relay can hold a session across disconnects: the client sends `SetEnv RAILWAY_DURABLE_SESSION_NAME=<name>` (and `RAILWAY_DURABLE_RESUME=lastread`), which "the relay intercepts ... not forwarded to the VM". The relay announces the name on connect: "Railway durable session: <name>" (CLI help text). **Whether that announcement or a scrollback replay is written into the byte stream is not documented**, and it matters because a Workroom attach needs a clean stream. | [S5] `native.rs` L308-315, L398-409; [S2] |
| `exec` | A WebSocket bridge, `wss://ssh.railway.com:2226/ws/exec`, authorised by a short-lived `shell`-scoped JWT minted by a GraphQL mutation (`generateShellToken`), sent in the `Sec-WebSocket-Protocol` header. Tagged binary frames for stdout (0x01), stdin (0x02) and stderr (0x03); text frames `init_exec`, `stdin_close`, `signal`, `durable_session`, `exit`. **No PTY**: the CLI never reads a tty stdin, and no resize frame exists. The protocol's source of truth is Railway's private repo. Documented in the SDK as `exec`/`execHttp` (HTTPS fallback, 16,000 bytes per stream, 10 s max). | [S5] `sandbox_exec.rs` L1-30, L96; [S1] |
| scp / sftp | Documented for **services**, not sandboxes. For sandboxes the documented file path is the SDK's `files` API (WebSocket). | [S3], [S1] |
| Port forward | `railway sandbox forward` is `ssh -N -L 127.0.0.1:L:127.0.0.1:R` against the relay, "pinned to loopback" in the target. | [S2], [S5] `native.rs` L480-540 |
| Long-running process | An `exec` command "runs on the sandbox independently of the client", can be detached and reattached by session name (`exec --detach`, `--session`). Whether a `nohup`/`setsid` daemon started from an ssh login survives that login ending: **not documented** (Workroom's own bootstrap warns about this for logind-managed hosts, `DaemonBootstrap.swift` L325). | [S1], [S2] |
| Inbound | Default `ISOLATED`: outbound only through NAT, nothing inbound. `PRIVATE` joins the environment's private network. Public HTTPS domains only at creation, for HTTP servers on ports 1-65535, up to 10, and only with `PRIVATE`. No raw TCP listener is documented, so Workroom would not dial the daemon directly and would use the relay as boxd and exe.dev do. | [S1] |
| Constraint on Workroom | [`HostDriver`](../../macapp/Packages/HostDrivers/Sources/HostDrivers/HostDriver.swift) says every driver "must authenticate its peer as strongly as a shell login". The ssh path can: BatchMode, a pinned host key (`SSHTransport.swift` L15-20, L403-428). **The relay's host key or fingerprint is not published in the docs.** The CLI itself falls back to `StrictHostKeyChecking=accept-new` for forwards. A driver would need to pin a key learned at setup (boxd precedent) and the docs give no way to verify it out of band. The WebSocket JWT bridge has no documented key pinning and no PTY, so it would be a Phase 4 style local bridge process, not a drop-in. | [S5] `native.rs` L521-524 |

**Driver shape this implies (inference):** closest to `SSHHostDriver` for transport (an ssh login, `startsDaemon`
true, because no systemd is documented) and to `BoxdHostDriver` for provisioning (`create`/`destroy`, a per-host
ssh stanza written by the driver, since the relay target is a username).

## 3. Lifecycle

| Operation | CLI | API / SDK | Notes |
|---|---|---|---|
| Create | `railway sandbox create [--idle-timeout-minutes N --variable K=V --env-file --template --checkpoint --private-network --domain --json]`; sets the CLI's "active sandbox" in `~/.railway/config.json` | `sandboxCreate(input: SandboxCreateInput)`; `Sandbox.create()` | Resolves when `RUNNING`. CLI needs a linked project and environment, or `--project`/`--environment`; non-interactive shell with neither is an error. |
| List | `sandbox list [--json --all]` | `sandboxes(environmentId, first, after)` | Destroyed sandboxes are hidden unless `--all`, so a destroyed one is still a row. |
| Read one | | `sandbox(environmentId, id) { id status }`, returns null if unknown | `SandboxStatus` is `CREATING`, `RUNNING`, `DESTROYING`, `DESTROYED`, `FAILED`. **There is no asleep or stopped value.** Types from the generated SDK file, not live introspection. |
| Delete | `sandbox destroy [ID]` | `sandboxDestroy(id, environmentId)`; `destroy()` | Destroying removes routes; no further compute billed. |
| Sessions | | `sandboxSessions(environmentId, id)`: shell and exec sessions, `running`, `attached`, `foregroundActive`; null when the sandbox cannot report them | Useful to tell a live attach from a dead one without opening a stream. |
| Keepalive | CLI sends `sandboxHeartbeat` every 60 s while `ssh`, `exec` or `forward` is connected | `sandboxHeartbeat(id, environmentId)`; `sandbox.heartbeat()` | A heartbeat "doesn't change the configured timeout". |
| Snapshot | `sandbox checkpoint create/list/rename/delete` | SDK `checkpoint()`, `Sandbox.checkpoints()` | Needs a running source; synchronous. Stored in the environment, so usable from any machine. |
| Template | `sandbox template build --name N -c '<cmd>' ... [--wait]` | `sandboxTemplateBuild` | Built from steps; "each must exit 0 within 10 minutes"; the CLI keeps template names locally. |
| Fork | `sandbox fork [ID]` | `source.fork()` | Needs a `RUNNING` source; does not inherit idle timeout, size, variables, domains or network mode. |

Idle behaviour, quoted from [S1]:

- "By default, Railway destroys a sandbox after its idle timeout expires." Default 30 min on Hobby/Pro (range 1-120); Trial/Free default 5 min, range 1-5, **cannot be disabled**.
- "A background process outside an active session doesn't keep the sandbox alive on its own." Teardown is deferred only while an `exec` command is running (a detached one too), an ssh shell has foreground work, a command finished inside the window, or a heartbeat arrives.
- `idleTimeoutMinutes: 0` (CLI `--idle-timeout-minutes 0`) disables destruction on Hobby/Pro; "The sandbox remains billable until you destroy it".

Consequences:

- **Wake: none.** There is nothing to wake. An idle host is gone, not asleep. A reconnect to a destroyed sandbox cannot succeed.
- **Presence without waking:** `sandbox(...) { status }` reads without opening a stream. Whether the query itself counts as activity: **not documented** (inference: no, a heartbeat is a separate mutation). It can give `awake` (`RUNNING`), `gone` (`DESTROYED`, `DESTROYING`, `FAILED`, or a null row), and **never `asleep`**.
- **Persistence across a destroy** needs a checkpoint, and restoring one is a new sandbox with a new id, so a workroom's `HostID` would change and its processes (the daemon, every attached terminal and run session) would be lost. Checkpointing "on idle" is not offered: Railway destroys on the timer with no hook documented, and capture needs a running sandbox.
- **Cost of keeping one alive:** memory in use is billed per second for as long as the sandbox runs, idle or not, at $50/GB/month. The resident memory of an idle Ubuntu VM with `workroomd` is **not documented**; the user pays plan fee plus usage beyond the included amount.
- **Rate limits:** the API allows 100 requests/hour on Free, 1,000 on Hobby (10/s), 10,000 on Pro (50/s) [S8]. A 60 s heartbeat is 60 requests/hour per sandbox, so a Free account cannot even keep one alive and Hobby is at its ceiling with about sixteen workrooms before any status read.

## 4. Git

**Railway documents no native GitHub integration for sandboxes**, nothing like exe.dev's per-repository integration or boxd's `credential.helper=boxd` ([ADR 0049](../adr/0049-provider-hosts-bring-their-own-git-credentials.md)). The only mention in the sandbox docs is a recipe:
"`railway sandbox create --variable GH_TOKEN=$(gh auth token)` ... passes your GitHub token into the sandbox, where `gh repo clone` can use it" [S2]. Railway's GitHub integration exists for service deploys ([GitHub autodeploys](https://docs.railway.com/deployments/github-autodeploys)), and the docs do not extend it to sandboxes. "Not documented", not "does not exist".

So a Railway driver needs its own credential path. The options, all inference from the precedents:

- **Variables at create:** `variables`/`--variable GH_TOKEN=...` bakes the token into every process's environment "for the sandbox's lifetime" and into the persisted disk state if checkpointed. It is the container precedent (Mac `gh` relay, [ADR 0039](../adr/0039-container-workrooms-ride-the-remote-path.md), cited in ADR 0049) but with a long-lived value in the VM, not a relay that dies with the Mac. **Checkpoints and forks do not inherit variables** [S1], so a checkpoint restore must pass the token again.
- **A relay over the existing daemon link,** as containers do: no secret on the VM, but pushes then need the Mac connected, which ADR 0017 and ADR 0049 chose to avoid for remotes.
- **Credentials from the user's `gh`:** the token reaches every repository that user can reach, the same blast radius ADR 0049 accepted for boxd.

Whichever is picked, ADR 0024 (broker) and ADR 0049 (provider defaults) both say a new provider arrives with a recorded answer. Egress to `github.com` is open in both network modes (outbound NAT) [S1].

## 5. Auth

| Method | Finding | Source |
|---|---|---|
| CLI login | `railway login` (browser, or `--browserless` pairing code); session kept in `~/.railway/config.json`. | [S12], [S5] |
| Tokens | Account token (all your workspaces), workspace token (one workspace, shareable), project token (one environment; header `Project-Access-Token`, not `Authorization`), OAuth. Endpoint `https://backboard.railway.com/graphql/v2`. | [S8] |
| CLI env vars | `RAILWAY_TOKEN` (project) and `RAILWAY_API_TOKEN` (account/workspace); setting both is an error. | [S12] |
| Sandbox API | The SDK reads `RAILWAY_API_TOKEN` + `RAILWAY_ENVIRONMENT_ID`; the quickstart says to create "an account or workspace API token". The SDK source resolves a project token's scope (`projectToken { projectId environmentId }`), so a project token is supported by the SDK. Whether it works for `sandboxCreate` and the shell-token mutation: **not documented**. | [S1], [S2], [S13] |
| ssh keys | A public key must be registered on the account (or the workspace, by an Admin). `railway ssh keys add` and the `sshPublicKeyCreate` mutation do it; **"SSH key management isn't supported with project tokens"**. So a token-only desktop app needs an account or workspace token to register its key. | [S3] |
| OAuth for an app | Login with Railway: scopes `workspace:viewer/member/admin`, `project:viewer/member`, `offline_access` (refresh token, only with `prompt=consent`); access tokens last one hour; PKCE `S256` is required for native apps; the docs' token examples use a client secret. Whether a **public client with no secret** is allowed, and whether a sandbox needs a scope beyond `project:member`: **not documented**. Workroom has no server to hold a secret. | [S14] |

For Workroom (inference): the cheapest path that matches boxd and exe.dev is to shell out to the user's own
`railway` CLI (installed, `railway login` done once, a linked project and environment), and have Workroom own
only its own key and its own ssh stanza. The CLI rewrites the "active sandbox" in the user's `~/.railway/config.json`
on `create`, `ssh` and `exec`, which is a side effect on the user's state; GraphQL plus the system `ssh` avoids it
but needs a token Workroom must obtain and keep. Neither is free of the **environment-scoping** question: a
sandbox belongs to one project's environment, so the user must name one, and the 10/50/100 cap is per environment.

## 6. Mapping to the HostDrivers capabilities

Protocols from [`HostCapabilities.swift`](../../macapp/Packages/HostDrivers/Sources/HostDrivers/HostCapabilities.swift) and
[`HostDriver.swift`](../../macapp/Packages/HostDrivers/Sources/HostDrivers/HostDriver.swift).

| Protocol | Needed? | Why |
|---|---|---|
| `HostDriver` (`openStream`, `exec`, `execIndependently`, `daemonSocket`, `startsDaemon`) | Required | `exec` and `openStream` as ssh logins to the relay. `startsDaemon` true (no systemd documented). `execIndependently` a second login; whether the relay allows one is a spike item. ControlMaster through the relay: not documented. |
| `ProvisioningHostDriver` (`create`, `destroy`) | Required | `sandboxCreate` / `sandboxDestroy`. Workroom owns the host, so a delete may destroy it. A create that fails after the sandbox exists must destroy it, as boxd's `undo` does. |
| `HostTerminalDriver` (`attachCommand`, `lastAttach`, `hostRefusedLastAttach`, `linkCrossesNetwork`) | Required | The pane's ssh with `-t` runs `workroomd attach` on the VM. `linkCrossesNetwork` true. `hostRefusedLastAttach`: a relay refusing the key, or a changed relay host key, is permanent. A destroyed sandbox is permanent too, a new failure class here. |
| `DaemonPlacingDriver` | No | The bootstrap's install script runs through `exec`. Placing a binary from outside would use the `files` API, which this driver need not use. |
| `HostPresenceReporting` | **Yes, but degenerate** | `status` read without a login gives `awake` or `gone`. It can never give `asleep`, so `RepositoryRoutingError.asleep` and the wake-on-activate path never fire for this driver. The one real benefit is `gone` for an idle-destroyed workroom, found without a failed ssh. |
| `StartableHostDriver` | No | There is no stopped state to start from. |
| `ReconnectingHostDriver` | Probably | If the driver shares an ssh connection; otherwise no. A relay behind a laptop wake needs the same invalidate as boxd. Unknown until ControlMaster is tried. |
| `OptionedProvisioningDriver` / `HostOptionsReading` | Yes, with a new facts case | Size (`resources`: vCPU/GB, up to the plan max), a checkpoint or template as the host image, region (SDK/API only), idle timeout. `HostOptionsFacts` would need a `.railway(...)` case: plan maxima come from the docs table, not an API read (not documented), checkpoints from `sandboxCheckpoints`. |
| `CheckoutClearingDriver` | Yes if a checkpoint can be a host image | A checkpoint captured from a used sandbox holds that sandbox's checkout, the boxd snapshot case (see #575). The default image is clean, so it is only needed once checkpoints are offered. |
| `RepositoryGranting` | No | Nothing like exe.dev's per-repository integration is documented (section 4). |
| `HostRecording` | Yes | Record the sandbox id, environment id, project id, relay target and the pinned relay host key, so a later launch reaches it again. |
| `FolderPlacingDriver` | No | Workroom makes the sandbox, so it is not a shared user host. |

Other consequences for the app (inference):

- **ADR 0017's wakefulness stance.** Needs an amendment or a new ADR: either the driver forces `idleTimeoutMinutes: 0` (refuse Trial/Free, bill continuously), or the app heartbeats every sandbox it holds (rate limit above), or workrooms last at most one idle timeout.
- **`workroom-identity`.** Forks and checkpoint restores boot from a copy of a disk. Whether they share `machine-id` and host keys as boxd snapshots do: **not documented** (boxd's case is in `remote-workrooms.md` Phase 0). The relay terminates ssh, so host keys matter less than the machine-id, as with boxd.
- **`maxLifetime` gate** ([remote-workrooms.md](remote-workrooms.md) premise 8): no maximum is documented with the timeout off, so the capability would be "none documented", not a number.
- **Daemon socket on the home disk survives a stop (#259).** There is no stop here; a destroy takes the home disk with it, so the layout blob ([ADR 0044](../adr/0044-remote-layout-on-host-blob-and-service.md)) and session records die with the sandbox. A checkpoint is the only way to keep them.

## 7. Blockers and open questions, ranked

1. **Idle means destroyed; there is no sleep.** Decide between `idleTimeoutMinutes: 0` (Hobby/Pro only, continuous memory billing, Trial/Free excluded), a Workroom heartbeat (60/h per sandbox against 100/1,000/10,000 requests an hour), or short-lived workrooms. This contradicts ADR 0017. Open: what does an idle sandbox with the daemon cost per month (memory in use is "not documented"), and is the timeout-off cost acceptable to the owner?
2. **A byte stream through the relay: unproven.** Does a non-PTY `ssh -T sbx:...@ssh.railway.com 'workroomd stdio'` stay binary-clean, with no durable-session announcement or replay injected? Does PTY resize reach the VM? Does a daemon started over an ssh login survive that login ending? Does the relay accept a second login (`execIndependently`) and ControlMaster? One live spike answers all of these, and it needs a throwaway Railway account.
3. **The relay's trust story.** The `sbx:` username format and the `ssh.railway.com` host are in CLI source only; no documented host key to pin; no stable contract. A change in Railway's CLI breaks the driver. The `HostDriver` doc requires a shell-login-strength peer check, and an unpinned `accept-new` does not meet it.
4. **Git credentials.** No provider integration (section 4). Which of variable, relay or user `gh` token is chosen is a decision ADR 0049 did not need for boxd and exe.dev.
5. **Auth for a desktop app.** Account/workspace token versus `railway login` through the CLI versus OAuth with PKCE. Open: does a public OAuth client with no secret exist, which scope does `sandboxCreate` need, and does a project token work for sandboxes at all. SSH key registration excludes project tokens.
6. **Environment scoping and quotas.** The user must name a project and environment; 10/50/100 sandboxes cap per environment and the same number of checkpoints. Does Workroom create its own project, or use one the user names?
7. **Daemon and arch.** CPU architecture, systemd and disk size are not documented. Workroom's bootstrap installs its own `workroomd`; `uname -m` at connect is the only way to know which binary.
8. **Checkpoints as a persistence story.** Restores are a new sandbox, a new id and no processes. Is "resume a workroom from its checkpoint" a feature, or a non-goal (in which case destroy-on-idle ends the workroom)? Cost and cap of checkpoints are per environment.
9. **Region.** CLI has no flag, so a CLI-driven driver always lands in `us-west2`.
10. **The CLI's `active sandbox` side effect** on `~/.railway/config.json` if the driver shells out to `railway`.

## Spike results (2026-11-13)

Two live runs on throwaway projects in a paid personal workspace (plan not read; the 8 vCPU / 8 GB a sandbox got
is the Pro default, so Hobby is untested), Railway CLI 5.71.0. Scripts and the full table:
`vcs/scripts/railway-spike/FINDINGS.md`
on branch `prototype/railway-sandbox-spike` (local only until pushed). Everything created was deleted.

**Confirmed**

- `sandboxCreate` with `idleTimeoutMinutes: 0` is accepted and echoed back. A sandbox with timeout 0 and no login ever made was still `RUNNING` 47 min after create.
- Host: `x86_64`, Ubuntu 26.04.1, kernel `6.18.60-railway`, root with `$HOME=/root`. pid 1 is `/rwinit/init`:
  **no systemd, no `loginctl`, no sshd** (the relay terminates ssh). `/etc/machine-id` is **empty**, on a fork too.
  VMs come pre-booted from a pool (`init` had 75 min uptime at create).
- Relay: target `sbx:<environmentId>:<sandboxId>@ssh.railway.com`; one host key, `ssh-ed25519
  AAAAC3NzaC1lZDI1NTE5AAAAIJ8X3z81/tuP7CvmK3ZqWgwEvHUR6b04oi2lQJGld2C1`, the same on every read. It runs each
  remote command as `bash -c 'if [ -f /etc/environment ]; then set -a; . /etc/environment; set +a; fi; <cmd>'`.
- `ssh -T` is byte-clean: 1 MiB random up, down and echoed, sha256 equal, nothing on stderr. Two concurrent logins
  and ControlMaster work. `ssh -L` works (5 MiB through a forward, sha256 equal).
- A `setsid nohup` daemon, and `workroomd serve --idle-timeout never`, outlive the login that started them.
  `workroomd` (x86_64 musl, protocol 10) serves, lists and attaches through the relay.
- PTY resize reaches the VM over `-t`. **`-T` has no size path**: `stty size` is `0 0` before and after a resize.
- Git, as [ADR 0072](../adr/0072-a-provider-without-git-integration-gets-the-users-gh-token.md) decides: the Mac's
  `gh auth token` written over stdin to a 0600 file, a system credential helper for `https://github.com` and
  `insteadOf` rewrites. A clone of a private repository by its `git@github.com:` URL and a push of a branch both
  worked, and GitHub's activity API records the pusher as the user.
- Fork copies the disk, not processes, with a new hostname.
- OAuth: dynamic client registration is **disabled** (`access_denied`). Discovery offers auth method `none`, the
  device-code grant, client ID metadata documents and an **`ssh_keys`** scope the docs don't list. Railway's own
  CLI refreshes with no secret and redirects to `http://127.0.0.1:<ephemeral>/callback`.
- The CLI's `ssh keys add --key <path>` ignores a key outside `~/.ssh` and the agent; `sshPublicKeyCreate` works.

**New: the relay's durable sessions**

Every ssh login, PTY or not, becomes a Railway durable session (`sandboxSessions`: `SHELL` with a PTY, `EXEC`
without), listed until the sandbox goes; no mutation deletes one.

- With a PTY the relay writes `\r\nRailway durable session <name>. Use CTRL + \ then D to detach and come back
  later\r\n` before any remote output, on every login and reattach. No `SetEnv` tried turns it off and the CLI has
  no flag. Without a PTY there is no banner.
- With a PTY, Ctrl+\ then `d` never reaches the VM: the relay resets the terminal (mouse modes off, `?1049l`,
  `ESC[2J`), prints `[detached] session still running.` and a reconnect command, and closes. Ctrl+\ then any other
  key passes through.
- A login whose ssh client dies keeps running on the VM indefinitely: a killed `workroomd attach`, over `-t` or
  `-T`, was still alive minutes later and `workroomd list` still said `attached`.
- `SetEnv RAILWAY_DURABLE_SESSION_NAME=<name>` reattaches it. With `RAILWAY_DURABLE_RESUME=lastread` the client gets
  only what it hadn't read; without, the whole scrollback is replayed. Over `-T` the reattach has no banner.
- Killing the process from a second login ends it: the relay marks it `running: false`, `exitCode: -1`, and a
  reattach then drains the buffered output and exits.

These need a design decision before the spec: how a pane attaches (today `ssh -t ... workroomd attach`), and who
ends a dead attach.

**Still to show**

- With Codaset's registered Native app: the localhost redirect, a refresh without a secret, and the scopes that
  can create a project, an environment, a sandbox and a key.
- Behaviour on a Hobby plan.

## Unverified

- Whether the Railway docs or Railway staff describe the relay protocol anywhere public beyond the CLI source. The `/ws/exec` frame description comes from a comment in the CLI that cites a private file.
- The OAuth public-client question (section 5) was searched for in the OAuth pages only, not in the Public API schema.
- The hypervisor, CPU architecture, systemd, disk size and machine-id behaviour: no primary source found.

## Sources

Fetched 2026-11-13 from `docs.railway.com` as markdown (`Accept: text/markdown`), not through a summariser, unless noted.

- [S1] Sandboxes: <https://docs.railway.com/sandboxes>
- [S2] `railway sandbox` CLI reference: <https://docs.railway.com/cli/sandbox>
- [S3] `railway ssh` CLI reference: <https://docs.railway.com/cli/ssh>
- [S4] Quickstart: <https://docs.railway.com/sandboxes/quickstart>; agents guide (default image, checkpoint loop, `GH_TOKEN`): <https://docs.railway.com/guides/agents-in-sandboxes>; code-execution guide: <https://docs.railway.com/guides/code-execution-sandboxes>
- [S5] Railway CLI, <https://github.com/railwayapp/cli> at commit `7da7f0d4dd6061656ed0b001c193945887ee645a` (tag `v5.74.0` is the latest tag at fetch): `src/commands/sandbox.rs`, `src/controllers/sandbox_exec.rs`, `src/commands/ssh/native.rs`, `src/config.rs` (`get_ssh_relay`), `src/gql/queries/strings/Sandbox.graphql`, `Sandboxes.graphql`, `src/gql/mutations/strings/SandboxCreate.graphql`, `SandboxDestroy.graphql`. First sandbox commit: `e474e43a92d2e97c8f71b3937b57714c8a1f2836`, 2026-05-30.
- [S6] CLI commit history for `src/commands/sandbox.rs`: <https://github.com/railwayapp/cli/commits/master/src/commands/sandbox.rs>
- [S7] Railway TypeScript SDK, <https://github.com/railwayapp/railway-ts-sdk> at `068bd894b1de05cfb3c935d83fede597cd12723d`: `src/generated/graphql.ts` (**generated types, not live introspection**: `Sandbox`, `SandboxStatus`, `SandboxCreateInput`, `SandboxSession`, `QuerySandboxSessionsArgs`, `ShellTokenInput`).
- [S8] Public API and tokens: <https://docs.railway.com/integrations/api> (endpoint, token types, rate limits).
- [S9] Changelog, "Railway Sandboxes are generally available", 2026-09-18: <https://railway.com/changelog/2026-09-18-railway-sandboxes>
- [S10] Regions: <https://docs.railway.com/deployments/regions>
- [S11] Plans and VM pricing: <https://docs.railway.com/pricing/plans>
- [S12] `railway login`: <https://docs.railway.com/cli/login>; CLI tokens: <https://docs.railway.com/cli>
- [S13] SDK `src/core/project-token.ts`, same commit as [S7].
- [S14] Login with Railway (OAuth): <https://docs.railway.com/integrations/oauth>, scopes <https://docs.railway.com/integrations/oauth/scopes-and-user-consent>, token flow <https://docs.railway.com/integrations/oauth/login-and-tokens>.
- Workroom side: [`remote-workrooms.md`](remote-workrooms.md), ADRs [0017](../adr/0017-remote-workrooms-fresh-host-no-wakefulness.md), [0024](../adr/0024-remote-git-credentials-via-codaset-broker.md), [0044](../adr/0044-remote-layout-on-host-blob-and-service.md), [0049](../adr/0049-provider-hosts-bring-their-own-git-credentials.md), [0067](../adr/0067-provider-behaviour-through-capabilities.md), [`remote-host-states.md`](../remote-host-states.md), [`remote-create-options.md`](remote-create-options.md), `macapp/Packages/HostDrivers/Sources/HostDrivers/` (`HostCapabilities.swift`, `HostDriver.swift`, `SSHTransport.swift`, `BoxdHostDriver.swift`, `DaemonBootstrap.swift`).
