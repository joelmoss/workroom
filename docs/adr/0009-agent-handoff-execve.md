# Agent hand-off replaces the program in place with `execve`, after a check, and refuses rather than kills

A newer app asks a running `wr-agent` to `execve` the bundled binary in place, keeping its pid, every pty master, the listening socket and the instance lock. A pty master handed to a separate process would keep the shell alive but orphan it, because `waitpid` only works for a child's parent. The screen crosses as VT bytes, not a snapshot, since two agent revisions share no snapshot format but do share VT. The new binary first runs `handoff-check` on the session table, and any failure before the exec leaves the old program running. The cost is accepted: a binary that passes the check and then fails while restoring loses every shell.

Source: [`vcs/crates/wr-agent/src/handoff.rs`](../../vcs/crates/wr-agent/src/handoff.rs) (module comment), [`macapp/AGENTS.md`](../../macapp/AGENTS.md) ("Terminal sessions").
