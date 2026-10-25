# Remote host states

The states a remote workroom's host can be in, how the app reaches it in each, and what a
command's exit status means across ssh. Read it before writing or reviewing anything that does
something on a host: a connect, an exec, a script, a delete.

## Reaching a host

- **Something the user asked for** (a click, a create, a delete, a script):
  `RemoteHosts.activate(host)`, then `try await hosts.ensureConnected(host, wake: true)`. That
  starts a stopped container, wakes an asleep boxd box, joins a connect already under way, and
  bootstraps the daemon and the credential relay. `RemoteWorkrooms.runScript` is the worked example.
- **A background read** (a status sweep, a panel refresh): `ensureConnected(host)`. It leaves an
  asleep boxd box asleep, reports a gone one, and after a failure refuses the host for `retryAfter`
  (30 s). A host selected in any window, or one the user opened (`activate`), is connected as if
  the user had asked, so a box on screen doesn't keep reading as asleep after the Mac wakes.
- **After a wake or a network change** (`RemoteLinkMonitor`): each boxd, exe.dev or SSH host's daemon is
  pinged over its service connection (the VCS `capabilities` request, which no repaint holds up). One that doesn't answer within 2 s has the
  connection dropped and its remote panes attach again, rather than wait the minute ssh's keepalive
  takes to notice a dead link; a pane's attach reconnects the host. One that answers keeps its links.
  A container's link is loopback and is left alone.
- `RemoteHosts.connect(host, driver:)` is the bootstrap step inside `ensureConnected`. It starts no
  container or provider host itself; on SSH hosts its bootstrap starts the daemon when nothing
  listens. It fails while another connect to the host is under way:
  `HostConnectionManager.connectIfDisconnected` throws `.unavailable` for a `.connecting` host.

## States

| State | How it shows | What handles it |
|---|---|---|
| Up | `HostConnectionManager` snapshot `.connected` | `ensureConnected` returns at once (and retries a credential relay that didn't take, at most once a `retryAfter`) |
| Connecting | another caller's attempt in `RemoteHosts.connecting` | `ensureConnected` joins it; `connect` throws `.unavailable` |
| Stopped container | Docker `inspect` says not running; Apple says `stopped` | `ContainerHostDriver.startIfStopped`, run only for an activated host. Apple's runtime has no restart policy, so after a reboot **every** Apple container is stopped |
| Asleep boxd box | boxd status `standby` or `hibernated` (`BoxdHostDriver.Presence.asleep`), or boxd couldn't say | A background read throws `RepositoryRoutingError.asleep`; with `wake` or `activate` the connect's ssh login wakes it |
| Gone boxd machine | `Presence.gone`: deleted, or in another org or account | A background read throws `RepositoryRoutingError.gone`. With `wake` the presence check is skipped, so the connect is tried and fails as unreachable |
| Unreachable | the connect threw | `ensureConnected` logs the cause and throws `.unavailable`, whose text is "Repository service unavailable." Say what failed in your feature's own words (`runScript`: "couldn't reach the host") |
| Older or newer daemon | `DaemonBootstrap.Outcome.Daemon` | An older daemon is handed off to this build's (`.handedOff`) unless it refuses (`.keptOlder`); a newer one is never downgraded (`.keptNewer`). Either way a subcommand this build added may be missing on the host |
| Older Nightly's host | a host from before the daemon's rename, #525 (`DaemonBootstrap.Error.olderLayout`), or a container made before #308, whose record has an ssh host key (`HostDriverError.olderContainer`) | `ensureConnected` throws `RepositoryRoutingError.olderLayout`, also through the backoff, which says to delete the workroom and create it again. A pre-#308 container is adopted only so its delete can take it down; every other reach of it throws |
| Fresh host | first login on a new machine | No cached login environment, and a cold first login (nvm, conda) can be slow. `workroomd run-script` and the daemon's cached environment for remote git give the login-shell probe 10 s, then fall back to the daemon's own environment and log why |
| Mid-create or failed delete | `HostDescriptor.state` is `creating` or `failed` | The host may not be whole. `RemoteWorkrooms.delete` runs a teardown only when `state` is nil, and otherwise just finishes taking it down |
| Another build's host | its key and labels aren't this build's | `RemoteWorkrooms.checkDeletable` refuses (`Failure.anotherBuildsHost`) |
| Unknown SSH host key | strict ssh refuses a host absent from `known_hosts` | Create captures the key through the user's ssh into a scratch known_hosts, shows its fingerprint, then appends that exact key only after Trust. A jump host that also needs trust is handled in Terminal first |
| Changed SSH host key | ssh reports the existing key differs | Refuse and name the destination. Never replace the saved key automatically |
| SSH needs a password or passphrase | batch ssh cannot authenticate | Stop before reserve or folder creation; ask the user to add their key to ssh-agent or the Keychain |
| Unsupported SSH host | not Linux on aarch64/x86_64, no git, or an absolute socket path of 108 bytes or more | The host checks refuse before reserve or folder creation. Resolve the remote home and parent here |
| SSH daemon not running | missing socket, stale socket / hand-off 92, or install reports no listener | Bootstrap runs `start.sh` with `--idle-timeout never` and saved screens, then checks from a second ssh exec. If the login's end killed it, name logind's `KillUserProcesses` policy; change no server setting |
| SSH folder gone | successful host check says the recorded folder no longer exists | Skip teardown and count it as deleted. A transport failure never counts as a missing folder |
| SSH marker missing or different | the state-folder marker doesn't exactly name the recorded path | Keep the folder and stop the delete; Delete Anyway forgets the entry and names the folder left on the host |
| SSH host unreachable during delete | folder/marker check, teardown or removal can't reach the host | Keep the entry; Delete Anyway forgets it and names the folder left on the host |

## Exit statuses over ssh

SSH hosts reuse a private app-owned connection for bootstrap and service exchanges, reducing new
connections on servers that rate-limit SSH. After a failed wake/network ping the app invalidates
that transport before reconnecting, so new exchanges cannot inherit its dead TCP link. Terminal
panes and daemon startup use independent SSH logins; closing a workroom never stops the server's
daemon. An unused private SSH master expires after 60 seconds.

- `HostDriver.exec(...).communicate` returns ssh's exit status rather than throwing when the link
  drops. 255 is ssh's own failure and also a command's own exit 255, so a status alone can't tell
  the two apart.
- For a check, accept only the status that means the answer, and read every other non-zero as the
  host not answering. `test -e` exits 1 for a missing file; reading 255 as "missing" would skip a
  teardown and then destroy the host.
- A daemon subcommand's own codes (`run-script`'s 124 timeout, 126 not started) count as its
  report only when its stderr line says so (`workroomd run-script: ...`): a script can exit 124 or
  126 itself.
- `communicate`'s `timeout` bounds silence, not the exchange. A process the command left in the
  background holds its output open, and one that keeps printing is never silent. When the local
  equivalent has an overall timeout, bound the whole exchange too (`withTimeout`).
- Cancelling the task ends the exchange.

## Parity with local

A feature meant to behave the same on every kind of workroom lists, in its plan, each local
behaviour beside its remote equivalent: the time limit, exit codes and failure kinds, the
environment, who starts the host, and what the user sees when it fails. The review checks every
row. #498's review found two missing rows only in its third cycle: local scripts had an overall
600 s bound, and opening a workroom starts its container.

## SSH parity with other remote hosts

An SSH destination is keyed exactly as typed; one host id and connection serve its workrooms
across every project. Release and Nightly share the state folder, while Dev uses its own. A
creating entry already carries the host id, so it counts when deciding whether a delete is the
last workroom on that host.

| Behaviour | boxd / exe.dev | SSH host |
|---|---|---|
| Who creates the host | provider, on create | nobody; the user's server exists |
| Who starts the daemon | systemd, at boot and after exit | the app's connect whenever nothing listens |
| What ends the daemon | never idles out; supervised | never stopped by the app, even after the last workroom |
| App git environment | host login shell, cached bounded probe | same; scrub and request pins still win |
| GitHub access | provider integration | user's credentials on the host; origin's GitHub URL scheme retained |
| Host key | provider pin or HostKeyAlias | user's known_hosts; fingerprint and Trust for a new key |
| Port forwards | provider publishes ports | one list per workroom; loopback on the host |
| Teardown | host login environment, 600 s overall bound | same; check folder and marker before running it |
| Delete | teardown, destroy machine | teardown, end sessions tagged with this workroom id, marker-guarded folder removal with a 600 s bound |
| Unreachable delete | fails, entry kept | same; Delete Anyway forgets and names the folder left behind |
| Shared state after delete | one host per workroom | drop connection/status watch only after the last workroom; forwards go with their own workroom |
| Wake/network ping | 2 s rule | same |
