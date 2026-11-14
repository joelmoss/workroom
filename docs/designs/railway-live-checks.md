# Railway hosts: live checks

Status: open. These checks are run by hand by the owner. ADRs [0074](../adr/0074-remote-panes-attach-from-the-mac-through-relay.md) and [0075](../adr/0075-the-daemon-closes-stale-remote-connections.md) stay proposed until both parts pass:

1. The live Railway suite, `RailwayHostDriverLiveTests` (#634).
2. The exe.dev, boxd and SSH host checks for the new attach path (#628).

Afterwards, change the two ADRs' status lines as [After a pass](#after-a-pass) says, then delete this file or mark it done.

No agent runs any of this. The suite calls the real Railway API, makes a sandbox that bills by the second, and pushes a branch as you.

## 1. The live Railway suite

`macapp/Packages/HostDrivers/Tests/HostDriversTests/RailwayHostDriverLiveTests.swift` runs a Railway host end to end through the real driver, the real relay and the Dev app's own daemons. It takes about 15 to 25 minutes, most of it the stale-connection wait and the short logins. It is skipped unless you enable it, so `make app-package-test` and CI never run it.

### Before you run it

- **A Hobby or Pro workspace.** Trial and Free destroy a sandbox after 5 idle minutes, and the suite refuses them. You need the workspace's id: open the workspace in Railway's dashboard; its settings page shows the id. You can also query `me { workspaces { id name } }`.
- **Railway credentials, one of:**
  - An account token. Make one at railway.com under Account Settings ▸ Tokens, with **No workspace** selected so it is an account token, not a workspace token. Delete it when you are done.
  - `WR_RAILWAY_SIGN_IN=1`. This opens Railway's consent page in your browser, exactly as the app's **Login with Railway** does. Tick the workspace and approve. It uses Codaset's OAuth client ID from `macapp/WorkroomApp/Info.plist`, and the sign-in is held in memory only. This checks the app's real scopes (`workspace:member project:member ssh_keys`) can do everything the suite does. A token can't check that.
- **`gh` signed in on this Mac** (`gh auth status`), with push access to a repository you name. Use a throwaway repository you own, ideally private. The suite clones it by its `git@github.com:` URL, pushes one empty commit on a branch `workroom-live-<run>`, and deletes the branch afterwards.
- **A built Dev app**: `make app-build` from this checkout. The suite takes three things from `macapp/DerivedData/Build/Products/Debug/Workroom Dev.app`, so all three come from one build:
  - the Mac's `workroomd`, which every pane runs;
  - `workroomd-linux-x86_64`, which it pushes to the sandbox;
  - the Ghostty terminfo.

  The Linux daemons need cargo-zigbuild and zig (see `macapp/scripts/build-daemon.sh`). To use another build, set `WR_WORKROOM_APP=<path to the .app>`.
- `/usr/bin/python3`. The Command Line Tools have it. It drives the test's terminal.

### Run it

From the checkout's root, with the command sandbox off:

```sh
WR_RAILWAY_LIVE_TESTS=1 \
WR_RAILWAY_TOKEN=<account token> \
WR_RAILWAY_WORKSPACE=<workspace id> \
WR_RAILWAY_PUSH_REPO=<owner>/<repo> \
  swift test --package-path macapp/Packages/HostDrivers --filter RailwayHostDriverLiveTests
```

To keep the token out of your shell history, put a space before the command (zsh `HIST_IGNORE_SPACE`), or read it first with `read -s WR_RAILWAY_TOKEN; export WR_RAILWAY_TOKEN`.

| Variable | Meaning |
|---|---|
| `WR_RAILWAY_LIVE_TESTS=1` | Required. Nothing runs without it, even with a token in the environment. |
| `WR_RAILWAY_TOKEN` | A Railway account token. The suite unsets it before it starts any process. |
| `WR_RAILWAY_SIGN_IN=1` | Sign in with the browser instead of a token. |
| `WR_RAILWAY_OAUTH_CLIENT_ID` | Optional. Overrides the client ID read from `Info.plist`. |
| `WR_RAILWAY_WORKSPACE` | Required. The workspace's id. |
| `WR_RAILWAY_PUSH_REPO` | Required. `<owner>/<repo>`, the repository the push check uses. |
| `WR_WORKROOM_APP` | Optional. A built `Workroom Dev.app` other than this checkout's. |
| `WR_RAILWAY_LOGINS` | Optional. How many short logins the login check makes (default 300). |
| `WR_RAILWAY_REGION` | Optional. The sandbox's region (Railway's default is `us-west2`). |

The suite never reads or writes `~/.railway`, `~/.ssh` or your Workroom config. It never uses an existing project either: a `Workroom` project you already have is left alone. Everything it makes is its own:

- a project `workroom-live-<run>` and an environment `live-<run>` in it;
- a new ssh key, registered on your account as `Workroom live suite <run>`;
- a new pin of the relay's host key.

The key, the pin, the ssh configs, the pane logs and the terminal's `HOME` are all in `$TMPDIR/wr-railway-live-<id>`. The only outside things it reads are `gh auth token`, for the push, and `/usr/bin/ssh`. No token is printed, put on a command line or in a remote command, or passed to anything it starts. The `gh` token reaches the sandbox only over ssh's stdin, as the driver writes it.

### What each step proves

The steps share one sandbox and run in order. A failed step is recorded, and the next one still runs, so one run reports everything. Steps after a failed create are skipped.

| Step | What it does | What it proves |
|---|---|---|
| lifecycle: create with idle timeout 0 | `driver.create`: key made and registered, relay key pinned, `sandboxCreate`, wait for RUNNING, `railway.sh` and `railway-github.sh` over the relay | Presence reads awake. Railway reports `idleTimeoutMinutes: 0` (ADR 0071). The Mac's key is mode 600. The log says whether the pinned relay key is the one the spike saw. |
| daemon bootstrap | `DaemonBootstrap.ensure` with the Dev app's Linux daemon, then a service connection and `refreshGitHubToken` | `startsDaemon`: start.sh with no systemd, and the daemon outliving its login, through the relay's `bash -c` wrapper. A connect's token refresh works. |
| attach, resize, no banner, Ctrl+\ then d | A pane runs the Mac's `workroomd attach --dial ssh -T … relay` in a real pty | The pane runs commands. `TERM` is `xterm-ghostty`, and `SSH_TTY` is unset. `stty size` follows a resize at once (30×100 to 40×120). Ctrl+\ then d reaches `od` as `034 d`, and the pane lives on. No "Railway durable session" banner or `[detached]` (ADR 0074). |
| reattach with no banner | A new pane with `--no-create` on the same session | The daemon restores the screen (the earlier `MARK-42` is back without being typed). The pane takes input. No banner. |
| a lost link retries | Kills the pane's ssh | The client exits 255, `lastAttach` is `lostLink`, it isn't read as refused, and the retry notice shows (ADR 0074, "a lost link"). |
| a changed relay key is refused | An attach whose pin is a different real key | ssh's "Host key verification failed" shows in the pane, `hostRefusedLastAttach` is true, and there is no retry notice (ADR 0074, "a refused link"). The real pin is then written back. |
| clone and push in the user's name | On the host: clone `git@github.com:<repo>`, commit, push a branch | The token file is mode 600. The `insteadOf` rewrite and credential helper work. GitHub's activity API names your `gh` login as the branch's pusher (ADR 0072, #631). |
| stale pane and service stream closed | Opens a pane and a service connection that announces it pings, then cuts both: stops answering the keepalive probe and `SIGSTOP`s both ssh processes | Within about a minute (failed if over 100 s), the daemon closes both, both `relay` processes exit on the host, and Railway lists both durable sessions as no longer running. The session survives unattached and reattaches with its screen (ADR 0075). |
| N short logins | `WR_RAILWAY_LOGINS` (300) logins running `true`, four at a time | Every login succeeds, and afterwards a new login and a new attach still work. It prints Railway's session-list count before and after, and how many still run (ADR 0074's accepted risk). |
| lifecycle: destroy | `driver.destroy` | The sandbox reads DESTROYED (or gone) within a minute. |
| cleanup (teardown) | Runs even when the test fails or throws | Destroys every sandbox in the run's environment, waits for them to go, then deletes the project, the ssh key and the branch. |

The cut is a stand-in. A stopped ssh sends nothing, as a sleeping Mac's doesn't, but its TCP connection stays up. A Mac that really goes offline is checked by hand ([A real cut-off](#a-real-cut-off)).

Four Railway GraphQL shapes come from Railway's TypeScript SDK types, not a live call: `sandboxSessions`, `projectDelete`, `sshPublicKeyDelete` and `sandbox { idleTimeoutMinutes }`. A wrong one fails loudly with Railway's message. That is a bug in the suite, not in the driver. Fix the query in the suite and run again.

### Reading the results

Each step prints a line starting `railway live: — <step>`. Each finding prints `railway live: FAILED: …`. The XCTest summary at the end has one failure per finding. A clean run looks like this:

```
railway live: run 1a2b3c, files in /var/folders/…/wr-railway-live-…
railway live: project <id>: delete it by hand if this run is killed
railway live: sandbox <id> in environment <id>
railway live: relay key pinned, the one the spike saw
…
railway live: relays closed 52 s after the cut
railway live: 300 logins in 410 s, 0 failed
railway live: Railway's session list: 14 before, 314 after (2 running)
railway live: deleted project <id>
railway live: cleaned up: nothing left behind
Executed 1 test, with 0 failures
```

Record these numbers for the ADR lines:

- the date;
- the seconds in `relays closed … after the cut`;
- the login count and failures;
- the session list counts before and after.

How to read a failure:

- **Test skipped**: a variable is missing or the Dev app isn't built. The skip message says which.
- **A failed login, or a refused new login after the many logins**: this is ADR 0074's open risk. Run once more to rule out a passing network fault. If Railway really stops taking logins once it lists a few hundred sessions, ADR 0074 goes back to design (#634). Don't accept it.
- **`relays … still run`, or `Railway still runs durable sessions`**: ADR 0075 doesn't hold on Railway. Keep the run's output: it names the relay processes it watched and how long it waited.
- **`the relay wrote "…" into the pane`, or Ctrl+\ then d not reaching `od`**: the pane went through a host terminal. ADR 0074's premise is broken.
- **`left behind: …`**: cleanup couldn't remove something. Remove it by hand (next section).
- To see what a pane printed, look in the run's directory. A failed run keeps it (`kept … for its pane output`), without its key. `panes/` has each pane's output, and `hosts/<id>/attach-<session>.log` has ssh's messages. Each failure message also quotes the last 600 characters of the pane. Delete the directory when you are done.

### If a run is killed

A killed run (Ctrl+C, a crash, a closed terminal) gets no teardown. Its first lines name the run and the project id. Remove these, in this order:

1. **Stray processes on this Mac.** Some may be stopped by the stale step.
   ```sh
   pkill -KILL -f 'wr-railway-live-'
   ```
2. **The sandboxes and the project.** In Railway's dashboard, open the project `workroom-live-<run>` and delete it from its settings. Check first that no sandbox of it still runs. If one does, destroy it before deleting the project, as the suite does.
3. **The ssh key.** In your Railway account settings, delete the SSH key named `Workroom live suite <run>`.
4. **The branch.**
   ```sh
   gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/workroom-live-<run>
   ```
5. **The local files.**
   ```sh
   rm -rf "$TMPDIR"/wr-railway-live-*
   ```
6. **The token.** If you made an account token only for this, delete it in Account Settings ▸ Tokens.

Every name carries the run's suffix, so nothing of yours matches it. Delete only what carries a run's suffix.

### A real cut-off

This complements the suite's `SIGSTOP`. Use the Dev app (`make app-run`) and a throwaway Railway workroom:

1. Open a terminal tab and run `top`. Note the relays on the host from a second tab: `pgrep -af '[w]orkroomd relay'`.
2. Turn Wi-Fi off, or sleep the Mac, for at least two minutes.
3. If you have a second machine that can reach the host, for example your own `railway ssh` into the sandbox, run the same `pgrep` there before this Mac comes back. The relays from step 1 should be gone.
4. Turn Wi-Fi back on. The pane shows the retry notice, then reattaches with `top` still running. Once it is back, `pgrep` shows new relays only: none of step 1's pids are left.

## 2. exe.dev, boxd and SSH host checks (#628)

ADR 0074 changed the attach path for every ssh host, not only Railway. Every pane now runs the Mac's own `workroomd attach`, which starts `ssh -T … relay` itself. Run these on the `railway-hosts` build, on throwaway workrooms only, never a real project's workroom you care about.

### Setup

1. `make app-build && make app-run` from the checkout. The Dev app pushes its new daemon (protocol 11) to each host before panes attach (ADR 0037). A host still on protocol 10 makes panes retry until it is updated.
2. Have one throwaway workroom on each of: an exe.dev VM, a boxd machine, an SSH host.

Do all of the following on each of the three hosts.

### A. Attach

1. Open a terminal tab in the workroom.
   - Expect: "workroom: waiting for this terminal's host..." appears briefly, then is erased. The host's login shell prompt shows, with nothing left of the waiting line.
2. Find the attach in a Mac terminal: `ps -axo pid,command | grep 'workroomd attach --dial'`.
   - Expect: `…/Workroom Dev.app/Contents/MacOS/workroomd attach --dial /usr/bin/ssh … -T <host> sh -c '…relay --socket …'`. No `ssh -t` and no `LocalCommand` in it.
3. In the pane: `tty; echo $TERM $SSH_CONNECTION; echo ${SSH_TTY:-no-ssh-tty}; echo $PATH; echo $HOME $SHELL`.
   - Expect:
     - a `/dev/pts/N` from the daemon;
     - `xterm-ghostty` (or `xterm-256color` if the host lacks the bootstrap's terminfo);
     - `SSH_CONNECTION` set;
     - `no-ssh-tty`;
     - the host's PATH, HOME and SHELL, not the Mac's.
4. On the host (`ssh <host>` separately): `ps -ef | grep -E 'workroomd (attach|relay)'`.
   - Expect: a `workroomd relay --socket …` per pane, and no `workroomd attach` process.
5. In the pane: `env | grep WORKROOM_SESSION_`.
   - Expect: `WORKROOM_SESSION_WORKROOM` and `WORKROOM_SESSION_TITLE` from the tab (metadata), and no `WORKROOM_SESSION_PROJECT` (the Mac path stays on the Mac).

### B. Resize

1. Run `vim` (or `htop`) in the pane, then resize the window and split the pane.
   - Expect: the program redraws at the new size each time. `stty size` afterwards matches the pane.

### C. Reattach

1. Quit Workroom Dev with the pane open (leave `top` running), then relaunch.
   - Expect: the pane reattaches to the same session, with its screen restored and `top` still running.
2. With one remote pane attached, kill its ssh (the client's child) on the Mac: `pkill -x -P "$(pgrep -f 'workroomd attach' | paste -sd, -)" ssh`.
   - Expect: the client exits 255 and the pane shows the retry notice. Then it reattaches by itself (`--no-create`) to the same session, with its screen restored.

### D. Run command

1. On a project with a run command, start the run tab on the remote workroom.
   - Expect: the run command runs on the host under the run supervisor. Stop and Restart work.

### E. Refused link

1. Make ssh refuse, one way per host type:
   - SSH host and exe.dev: on the host, run `cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak && : > ~/.ssh/authorized_keys`. For exe.dev, do it from a shell already open on the VM. Expect `Permission denied (publickey)`.
   - boxd: go to the host directory from A.2, beside the attach log. Back up `known_hosts`, then replace the key in it with another host's, keeping the first field: `cp known_hosts known_hosts.bak; ssh-keyscan -t ed25519 github.com | sed 's/^[^ ]*/<same host field>/' > known_hosts`. Expect `Host key verification failed.`
2. Open a new tab in that workroom.
   - Expect: ssh's own reason ("Host key verification failed." or "Permission denied (publickey)") shows in the pane, not the "Can't reach this terminal's host right now…" notice. The pane stops retrying after a few tries.
3. Restore with `mv ~/.ssh/authorized_keys.bak ~/.ssh/authorized_keys` or `mv known_hosts.bak known_hosts`. Close the tab and open a new one. It attaches.

### F. Lost link

1. With a pane attached and `top` running, cut the network (turn Wi-Fi off) for about 90 s, or sleep the Mac for a couple of minutes.
   - Expect: the pane shows "Can't reach this terminal's host right now. Workroom will keep trying…" and retries with backoff.
2. Restore the network, or wake the Mac.
   - Expect: the pane reattaches by itself, with its screen restored and `top` still running.
3. On the host, run `sudo pkill -f 'workroomd relay'` while a pane is attached.
   - Expect: the same retry notice, then a reattach.
4. ADR 0075, on this host: after step 1, look on the host before the Mac comes back, using another machine or the provider's console. The pane's `workroomd relay` is gone within about a minute of the cut, and its session is listed unattached.

### G. Host with no daemon yet, or the former layout (optional)

1. On a throwaway host, move the installed daemon aside (`mv ~/.local/state/workroom/daemon/workroomd{,.bak}`) and open a tab.
   - Expect: "workroom: no daemon is installed at … yet", then the retry notice. The app's bootstrap reinstalls the daemon and the pane attaches.

Report anything that differs, with the pane's attach log and status. The log's path is the argument after `-E` in the `ps` line from A.2 (`…/hosts/<host id>/attach-<session>.log`). The `.status` file is beside it.

## After a pass

Once part 1 passes and A to F pass on all three hosts in part 2, change the status lines, line 3 of each ADR. They follow the repo's "Decided …, accepted once …" form (see ADR 0071). Fill in the run's date and numbers. Each line below is one line in the file.

**ADR 0074** (`docs/adr/0074-remote-panes-attach-from-the-mac-through-relay.md`). Change:

> Proposed 2026-11-13, from the Railway pane-attach design interview. It is accepted once the new path attaches, resizes, reattaches and reports a refused or lost link live on a Railway host, an exe.dev host, a boxd host and an SSH host, and once a Railway sandbox that has taken a few hundred short ssh logins still accepts new ones (see the last paragraph).

to:

> Decided 2026-11-13 (Railway pane-attach design interview), accepted once the live checks of <date> ([`docs/designs/railway-live-checks.md`](../designs/railway-live-checks.md): `RailwayHostDriverLiveTests` and the exe.dev, boxd and SSH host checks) showed the new path attaching, resizing, reattaching and reporting a refused and a lost link on a Railway host, an exe.dev host, a boxd host and an SSH host, with no banner and Ctrl+\ then d reaching the program on Railway, and a Railway sandbox that had taken <N> short ssh logins still accepting new ones (Railway listed <before> sessions before them and <after> after).

Also replace the paragraph's lead-in "Accepted risk, to be measured before acceptance:" with "Accepted risk, measured <date>:". Then add a sentence at the paragraph's end saying what was found, for example "<N> logins later Railway listed <after> sessions, none were removed, and logins and attaches still worked."

**ADR 0075** (`docs/adr/0075-the-daemon-closes-stale-remote-connections.md`). Change:

> Proposed 2026-11-13, from the Railway pane-attach design interview; amends [ADR 0070](0070-remote-attaches-are-kept-alive-by-the-panes-terminal.md). It is accepted once a Railway host shows both kinds of connection closed, and their `relay` and durable session ended, about a minute after the Mac holding them is cut off.

to:

> Decided 2026-11-13 (Railway pane-attach design interview); amends [ADR 0070](0070-remote-attaches-are-kept-alive-by-the-panes-terminal.md). Accepted once the live check of <date> (`RailwayHostDriverLiveTests`, [`docs/designs/railway-live-checks.md`](../designs/railway-live-checks.md)) showed a pane and a service stream on a Railway host closed <S> s after the Mac holding them was cut off, their `relay` exited and Railway's durable sessions for them no longer running, and the session still there to reattach.

Then:

- Tick #634's last acceptance criterion and cite the run (the date, and the build's commit).
- Mark this file done, or delete it.

If the logins check found that Railway refuses logins, don't change ADR 0074's status. Send it back to design, as its last paragraph says. ADR 0075 can still be accepted on its own check.
