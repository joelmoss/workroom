# Remote host states

The states a remote workroom's host can be in, how the app reaches it in each, and what a
command's exit status means across ssh. Read it before writing or reviewing anything that does
something on a host: a connect, an exec, a script, a delete.

## Reaching a host

- **Something the user asked for** (a click, a create, a delete, a script):
  `RemoteHosts.activate(host)`, then `try await hosts.ensureConnected(host, wake: true)`. That
  starts a stopped container, wakes an asleep boxd box, joins a connect already under way, and
  bootstraps the agent and the credential relay. `RemoteWorkrooms.runScript` is the worked example.
- **A background read** (a status sweep, a panel refresh): `ensureConnected(host)`. It leaves an
  asleep boxd box asleep, reports a gone one, and after a failure refuses the host for `retryAfter`
  (30 s). A host selected in any window, or one the user opened (`activate`), is connected as if
  the user had asked, so a box on screen doesn't keep reading as asleep after the Mac wakes.
- `RemoteHosts.connect(host, driver:)` is the bootstrap step inside `ensureConnected`. Called on its
  own it starts nothing, and it fails while another connect to the host is under way:
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
| Older or newer agent | `AgentBootstrap.Outcome.Agent` | An older agent is handed off to this build's (`.handedOff`) unless it refuses (`.keptOlder`); a newer one is never downgraded (`.keptNewer`). Either way a subcommand this build added may be missing on the host |
| Fresh host | first login on a new machine | No cached login environment, and a cold first login (nvm, conda) can be slow. `wr-agent run-script` gives its login-shell probe 10 s, then falls back to its own environment and says so |
| Mid-create or failed delete | `HostDescriptor.state` is `creating` or `failed` | The host may not be whole. `RemoteWorkrooms.delete` runs a teardown only when `state` is nil, and otherwise just finishes taking it down |
| Another build's host | its key and labels aren't this build's | `RemoteWorkrooms.checkDeletable` refuses (`Failure.anotherBuildsHost`) |

## Exit statuses over ssh

- `HostDriver.exec(...).communicate` returns ssh's exit status rather than throwing when the link
  drops. 255 is ssh's own failure and also a command's own exit 255, so a status alone can't tell
  the two apart.
- For a check, accept only the status that means the answer, and read every other non-zero as the
  host not answering. `test -e` exits 1 for a missing file; reading 255 as "missing" would skip a
  teardown and then destroy the host.
- An agent subcommand's own codes (`run-script`'s 124 timeout, 126 not started) count as its
  report only when its stderr line says so (`wr-agent run-script: ...`): a script can exit 124 or
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
