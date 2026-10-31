# App VCS and terminal-session architecture

Paths beginning `Core/`, `Packages/`, `Resources/` and `Scripts/` are relative to `macapp/`.
Read the [session/VCS working rules](../../macapp/AGENTS.md#session-and-vcs-changes) when changing
or reviewing these layers.

## VCS core (SwiftGitX git + workroomd)

Workroom is git-only. VCS data reaches the app two ways, behind
one Swift layer (the app is growing into a VCS-first IDE — issue #59 is the first brick):

- **Local reads → SwiftGitX (libgit2), pure Swift.** `GitProvider` wraps SwiftGitX and implements
  `LocalVCSProviding`. No Rust bridge or xcframework. (An all-Rust core with gix was tried and
  dropped: gix bought no real unification and libgit2 is the more complete git engine.)
- **Daemon-routed reads and writes → `workroomd`.** The `vcs/` Rust workspace holds the `workroomd`
  daemon (terminal sessions, VCS and File services) and its git read crates (`wr-vcs-git`,
  `wr-vcs-model`); see "Terminal sessions" below. The app talks to it through `DaemonVCSReader` /
  `DaemonVCSConnection`.

**Three reads reach past SwiftGitX**, all linking the `libgit2` C API **directly** (its own SPM package
in `project.yml`, URL + version identical to SwiftGitX's own dependency so SwiftPM sees one package
identity). `Core/LibGit2.swift` owns the single `git_libgit2_init` and hands out raw `git_repository`
handles (SwiftGitX inits inside `Repository.open`, which a direct C caller can't rely on); these four
files are the only ones in the app touching raw libgit2:

- **Push state — `Core/GitGraph.swift`.** SwiftGitX cannot express a commit *range*: its
  `CommitSequence` only calls `git_revwalk_push`, never `git_revwalk_hide`, it exposes no
  merge-base/graph helper, and its repository pointer is `internal` — so "which commits aren't on
  `origin` yet" (`HEAD --not refs/remotes/origin/*`) needs the C API. Push state is
  **origin-scoped** and any unreadable ref degrades the WHOLE page to "unknown" (no badge) rather than
  a partial answer.
- **Commit diffs — `Core/GitCommitDiff.swift`.** Rename detection is `git_diff_find_similar` run over a
  live `git_diff`, and a SwiftGitX `Diff` materializes its deltas/patches in an `internal` init and
  frees the `git_diff` before returning, so there's nothing left to detect on. Without it a committed
  rename read as delete + add while `git show` showed one rename row (git defaults to
  `diff.renames=true`), and a root commit's diff came back empty (SwiftGitX diffs it against itself).
  Detection options are NULL, which is what makes libgit2 read the repo's own `diff.renames` /
  `diff.renamelimit` — naming a flag explicitly suppresses that config read, so a repo set to
  `diff.renames=false` or `=copies` would silently disagree with its own CLI. Typechanges are included
  (`GIT_DIFF_INCLUDE_TYPECHANGE`); without it libgit2 splits a file↔symlink change into delete + add
  on the SAME path, giving the file list two rows with one `id`. `GitProvider.changeset`/`.fileDiff`
  both read through it, so the History file list and the patch text can't disagree.
- **Working-tree ± line counts — `Core/GitDiffStats.swift`**, via `git_diff_get_stats`. SwiftGitX
  surfaces no diffstat, and its `Diff` is **eager**: `Diff.init` builds a `Patch` per delta and
  materializes every hunk line into a Swift `String` before the caller sees it. Summing those for the
  badge cost one `String` per changed line of the whole worktree on **every** status refresh, so the
  counts moved to libgit2, which counts in C and allocates nothing Swift-side. The diff itself is
  irreducible — that's what `git diff --shortstat` costs too. With `changeset` now counting through
  `GitCommitDiff`, **no** `+N −M` in the app is summed off SwiftGitX hunk lines any more, which also
  ends a real bug: that sum counted the EOFNL markers (`\ No newline at end of file`) as lines, so
  changing only a file's trailing newline reported two deletions where git reports `1 insertion(+),
  1 deletion(-)`. libgit2 skips them, as `git diff --shortstat`/`--numstat` do. It runs
  `git_diff_find_similar` too, for the same reason `GitCommitDiff` does: the file list beside these
  counts already pairs renames (libgit2 status' `.renamesIndex`/`.renamesWorkingTree`), so without it
  a staged rename rendered as one "renamed" row badged `+N −N` while `git diff HEAD --shortstat`
  reported `0 insertions(+), 0 deletions(-)`.

**Read surface & routing.** `Core/RepositoryServices.swift` defines the context-bound `VCSProviding`
protocol. `RepositoryRouter` captures the shared ownership for a validated host/path identity;
native engines implement `LocalVCSProviding` behind its local adapter, and `GitProvider` wraps
SwiftGitX. `WorkroomStatusResolver` and `BranchResolver` read through this layer — no CLI text
parsing. Reads never take a repository lock and are not gated.

**Writes are serialized per project.** git worktrees of one project share the backing `.git`, so a
commit in one workroom and a fetch or pull in another contend for the same `index.lock` /
`packed-refs.lock`. `RepositoryWriteGate` (`Core/RepositoryWriteGate.swift`) is a per-project
serializer that every commit, fetch, push and pull goes through (`CLIVCSWriter.gated`); callers pass
the raw, untimed call as the operation and wrap the gate in `withTimeout`, never the reverse (see the
type's doc comment). Swift coverage: `RepositoryWriteGateTests`.

## Terminal sessions: `workroomd` (Rust) and the Swift helper it replaces

A pane's shell outlives the pane, so the app does not own the pty — a **session helper** does, and
the app attaches to it. New sessions all go to `workroomd`, the Workroom daemon; the Swift `workroom-session` in this build only
attaches to older Swift helpers that are still running (issue #154):

- **`workroomd`** (`vcs/crates/workroomd`, Rust) — where every NEW session goes. One binary,
  `serve | attach`, multiplexing services over one stream with a versioned envelope
  (`service:u8 | stream:u32 | length:u32 | payload`). It keeps a **shadow terminal** (libghostty-vt,
  behind the `terminal-state` cargo feature) so a reattaching pane is repainted from emulator state
  rather than a byte replay, with the images on its active screen following in the background (ADR
  0062). A newer app does not kill a running daemon: it asks it to replace its
  own program with the bundled binary in place, keeping its pid and every session
  (`DaemonHandOff.start()`, protocol 6, `workroomd hand-off`, #230), in every build; see
  the module comment in `vcs/crates/workroomd/src/handoff.rs` for the mechanics, and ADR 0009 for
  why.
- **`workroom-session`** (`macapp/WorkroomSession/`, Swift) — attach-only now. The `daemon`
  subcommand is gone, so this build cannot start one; the tool only attaches to Swift helpers an app at or
  before v2.0.0 left running, which keep their sessions until the user closes them and cannot hand a
  live pty over.

**A restored remote pane can show its last screen instead of a fresh shell (#232).** When a host's
supervisor opts in (`workroomd serve --screens <dir>`), the daemon keeps each session's last screen on
disk and, after a reboot kills the shells, answers a reattach for a session it no longer holds with
that screen plus a bottom-row notice rather than the usual fresh shell. The app needs no code for
this: the notice arrives as ordinary VT bytes over the same reattach path `terminal-state` already
repaints from. See the module comment in `vcs/crates/workroomd/src/screens.rs` for the
write/prune/restore mechanics, and ADR 0031 for why. The supervisor boxd and exe.dev hosts run
(`Resources/host-setup/systemd.sh`) passes `--screens`, as does the ssh fixture's.

**The migration is a drain, not a switch.** `SessionBackend.preferred()` returns `.daemon`, or nil
when the daemon fails its probe (there is no fallback to the Swift helper, which this build cannot start); `PersistentSessionService.backend(forSession:)` resolves each EXISTING
session to whichever helper owns it. Two rules there are load-bearing and were both got wrong once:
the answer is resolved **once per session and cached** (a pane asks twice — `attachCommand` for the
binary, `launchEnvironment` for the socket — and the two must agree, or the Swift helper binds the daemon's
socket), and an **unanswered** ownership probe resolves to *neither* — `backend(forSession:)` returns
nil and the pane opens a plain shell until a later probe succeeds. There is no safe guess, because
**both** helpers create-on-attach: the retired `SessionDaemon.handleAttach` (code deleted, but the
v2.0.0 Swift helpers still run it) ends in `create(request:connection:)` for an id it does not hold, exactly
as the daemon does, so either guess forks a second pty under the
same id and orphans the user's shell. A failed `connect` is NOT an unanswered probe — it means
nothing is listening, which is a definitive "not owned" (the Swift helper leaves a stale `session.sock`
behind on any `pkill`, so this case is common, not exotic).

**Building it.** `macapp/Scripts/build-daemon.sh` is a build phase, mirroring `build-helper.sh` (the
Go CLI): it iterates `ARCHS` and `lipo`s the slices, though the app itself is arm64 only (ADR 0061). The
built binary is staged beside `$DEST` and **renamed into place, never written over it** — a running
daemon executes that file, and macOS SIGKILLs a process whose signed binary changes under it ("Code
Signature Invalid"); writing in place used to kill every Dev session, and any hand-off (#230), on
each rebuild. `build-daemon_test.sh` guards both that loop — the same regression once shipped an
arm64-only CLI inside 23 universal betas — and the rename (a hard link stands in for the running
binary, and a rebuild must leave it unwritten); the cross cases need `rustup target add
x86_64-apple-darwin aarch64-apple-darwin`, which CI installs. `terminal-state` is **not optional for
the app**: without it a reattaching pane repaints blank, which only shows up after a
quit-and-relaunch. `workroomd protocol` reports `terminal-state yes|no`, and the build test asserts it
against the shipped binary.

**Linux daemons (issue #227).** Every build also puts a static musl `workroomd` per
Linux arch in `Contents/Resources/workroomd-linux-{aarch64,x86_64}`, for pushing to remote hosts.
Both arches ship always, whatever `ARCHS` says, because a remote box's arch has nothing to do with
the Mac's. They are not codesigned; the app's signature seals them as resources. Debug builds them
too, since every build offers remote workrooms. Building them needs `cargo install
cargo-zigbuild --locked` and `rustup target add aarch64-unknown-linux-musl
x86_64-unknown-linux-musl`, which the CI and release workflows install. `release.sh` asserts both ELFs are
present and static, and the `daemon-linux` CI job runs `protocol` on each under Linux.
`DaemonBootstrap.connect` (#231) pushes the matching one to a remote host on first connect, beside
the daemon's socket, and hands the running daemon off to it; the far side is
`Resources/daemon-bootstrap/{probe,install,resources}.sh`, run through `HostDriver.exec` (plus
`start.sh` for an SSH host with no listener). The same
connect pushes Ghostty's terminfo and shell integration beside the daemon (#239), so a remote pane
runs as `xterm-ghostty` with the integration. See the "As built
(#231)" section of the design doc, and `vcs/scripts/ssh-fixture/run.sh` for running its tests.

The Zig toolchain and the pinned Ghostty engine come from `vcs/scripts/build-ghostty-vt.sh`
(cached per `(engine sha, Zig version, target)` outside the repo). The same script builds the
GhosttyKit the app links, so a remote pane's shadow and the local engine are one stock revision with
no patches on either side (ADR 0061).
