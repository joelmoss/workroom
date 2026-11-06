//! Running a git child for a service: the exec service's commands and the File service's listing.
//! Path validation for the repository paths a request names, the bounded capture, and the timeout
//! that ends the whole tree (`wr_exec::end_tree`). Both services depend on this, not on each other.
use std::io::Write;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};
use wr_vcs_model::{self as model, VcsError};

/// Per-stream cap, matching `StatusCommandRunner.maxBytes`'s default on the Swift side.
pub(crate) const MAX_EXEC_STREAM: usize = 4 * 1024 * 1024;

/// How long a timed-out command's tree has between SIGTERM and SIGKILL, as native's
/// `ProcessTree.killTree` at `timeout + 2`.
const TERM_GRACE: Duration = Duration::from_secs(2);

pub(crate) fn io(error: impl std::fmt::Display) -> VcsError {
    VcsError::Io(error.to_string())
}

pub(crate) fn absolute(value: &str) -> model::Result<PathBuf> {
    if !value.starts_with('/')
        || value.contains('\0')
        || value.split('/').any(|s| s == "." || s == "..")
    {
        return Err(io("invalid absolute repository path"));
    }
    Ok(PathBuf::from(value))
}

pub(crate) fn relative(value: &str) -> model::Result<&str> {
    if value.is_empty()
        || value.starts_with('/')
        || value.contains('\0')
        || value.split('/').any(|s| s == "." || s == "..")
    {
        return Err(io("invalid relative file path"));
    }
    Ok(value)
}

pub(crate) struct Captured {
    pub(crate) stdout: Vec<u8>,
    /// `stdout` was cut at the stream cap: the child wrote more than was kept. A truncated capture
    /// can end mid-line, or mid-filename, so a consumer that parses it must not treat it as whole.
    pub(crate) stdout_truncated: bool,
    pub(crate) stderr: Vec<u8>,
    pub(crate) exit_code: i32,
    pub(crate) timed_out: bool,
    pub(crate) signaled: bool,
}

/// Run `executable` to completion, capturing everything a `StatusCommandRunning` conformer needs
/// to classify the outcome exactly as the native path would. Mirrors `StatusCommandRunner.run`'s
/// SIGTERM-then-grace-then-SIGKILL shape (`CLIVCSWriter.commitTimeout`'s doc: "Killing a commit is
/// categorically more dangerous than killing a fetch" — an immediate SIGKILL denies a `post-commit`
/// hook the chance to exit cleanly and can leave `index.lock` behind).
pub(crate) fn run_exec(
    dir: &Path,
    executable: &str,
    args: &[String],
    timeout: Duration,
    stdin: Option<&[u8]>,
    env: &[(&str, &str)],
) -> model::Result<Captured> {
    // `/usr/bin/env <executable>`, byte-for-byte what native does
    // (`StatusCommandRunner.run`: `proc.executableURL = /usr/bin/env`). Not a style choice — it is
    // what makes a MISSING tool exit 127 (`env` ran and searched PATH) instead of failing to spawn.
    // Spawning the program directly made that an Io error, which the client reported as
    // `launchFailed`, the value whose own doc reserves it for "nothing ran" and warns it would
    // "misdiagnose a deleted workroom as a missing git/gh". Mapping `ErrorKind::NotFound` to 127
    // by hand could not fix it either: `posix_spawn` returns ENOENT for a missing cwd AND a missing
    // executable, so the two stay indistinguishable. Letting `env` do the lookup makes 127/126 its
    // real exit codes, and narrows a spawn failure here to the cases that genuinely never ran — a
    // vanished cwd, or `/usr/bin/env` itself being absent.
    let mut command = Command::new("/usr/bin/env");
    command
        .arg(executable)
        .current_dir(dir)
        .args(args)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        // `env_clear` first, then adopt the request's map wholesale: the child must see EXACTLY the
        // environment `StatusCommandRunner.childEnvironment` built in the app, never this daemon's
        // own. workroomd is "negotiated with, never replaced", so its inherited environment is a
        // snapshot of whichever app launch first spawned it — a daemon-routed commit was picking up
        // that snapshot's `GIT_AUTHOR_*`/`GIT_CONFIG_GLOBAL`/`HOME` and authoring under a stale
        // identity. A key allowlist could not fix that: what git reads for identity, config,
        // signing and hooks is open-ended. That one function also applies this codebase's subprocess
        // baseline (`GIT_OPTIONAL_LOCKS`, `GIT_TERMINAL_PROMPT`, `LC_ALL=C`, and the removal of
        // `GIT_EXTERNAL_DIFF` and the `GIT_DIR` family) so both paths get it from one place.
        .env_clear()
        .envs(env.iter().copied());
    // Set last so no request environment can widen it: git must not discover an ANCESTOR
    // repository from `dir` (see `ceiling_directories`).
    if let Some(ceiling) = wr_vcs_git::diff::ceiling_directories(dir) {
        command.env("GIT_CEILING_DIRECTORIES", ceiling);
    }
    let mut child = command.spawn().map_err(io)?;

    if let Some(payload) = stdin {
        let mut handle = child.stdin.take().expect("piped stdin");
        let payload = payload.to_vec();
        // Off the waiting thread: a payload larger than the pipe buffer blocks until the child
        // drains it, and the child may not start reading until after argv parsing.
        std::thread::spawn(move || {
            let _ = handle.write_all(&payload);
            // `handle` drops here, closing the write end so the child sees EOF.
        });
    }

    let stdout_pipe = child.stdout.take().expect("piped stdout");
    let stderr_pipe = child.stderr.take().expect("piped stderr");
    let out_sink = Arc::new(Mutex::new(Vec::new()));
    let err_sink = Arc::new(Mutex::new(Vec::new()));
    let out_overflow = Arc::new(AtomicBool::new(false));
    let out = {
        let sink = Arc::clone(&out_sink);
        let overflow = Arc::clone(&out_overflow);
        std::thread::spawn(move || {
            wr_exec::drain_capped_flagged(stdout_pipe, MAX_EXEC_STREAM, &sink, &overflow)
        })
    };
    let err = {
        let sink = Arc::clone(&err_sink);
        std::thread::spawn(move || wr_exec::drain_capped(stderr_pipe, MAX_EXEC_STREAM, &sink))
    };

    let start = Instant::now();
    let mut timed_out = false;
    // `None` ⇒ we killed it and it never became reapable within `REAP_GRACE`. Reported rather than
    // waited on: this used to be `break 'wait child.wait()`, an UNBOUNDED wait, and a child that had
    // left the process group never received the SIGKILL sent to it, so that wait had nothing to
    // wait for. Codex reproduced 4.1s on a 100ms timeout with one `os.setpgid`.
    let status = loop {
        if let Ok(Some(status)) = child.try_wait() {
            break Some(status);
        }
        if start.elapsed() >= timeout {
            timed_out = true;
            // Timeout escalation: SIGTERM to the group, the whole `TERM_GRACE` even when the leader
            // exits promptly on SIGTERM while group members do not, then SIGKILL to the tree
            // recorded before the SIGTERM — which reaches one that `setsid`ed out of the group — and
            // to the group. See `wr_exec::end_tree`.
            break wr_exec::end_tree(&mut child, libc::SIGTERM, TERM_GRACE);
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    // Two independent jobs, deliberately not fused. Fusing them (escalate only while a reader is
    // still running) let a timed-out descendant survive: if it redirects stdout/stderr, both readers
    // finish, the drain loop exits, and the SIGKILL never fires — leaving it free to keep modifying
    // the repository after this result releases the caller's gate.
    //
    // 1. Timeout escalation, above, and only on a timeout. Never on a normal exit: killing the
    //    group because a reader thread has not been scheduled yet would kill a hook's legitimate
    //    background work, measured at ~1.5% of successful large-output runs.
    //
    // 2. Drain bound, mirroring `StatusCommandRunner`'s `_ = drain.wait(timeout: .now() + 2)` and
    //    for the reason its comment gives: a descendant that inherited the pipe can hold the write
    //    end open after the child is reaped, so joining unconditionally would block forever. Forever
    //    is not merely a hung request here — this thread is the one `dispatch` spawned, so its
    //    `Permit` never drops, one of the 32 `ACTIVE` slots shared with every read leaks, and
    //    `is_busy()` stays true so the daemon never idle-exits either. After the deadline we take
    //    what drained and DETACH the readers; each exits on its own when the descendant finally
    //    closes the pipe, writing into a sink nobody reads. That costs a thread and up to 4 MiB per
    //    occurrence, which is bounded per call and vastly better than leaking a permit.
    let drained_by = Instant::now() + Duration::from_secs(2);
    while !(out.is_finished() && err.is_finished()) && Instant::now() < drained_by {
        std::thread::sleep(Duration::from_millis(10));
    }
    let take = |sink: &Mutex<Vec<u8>>| std::mem::take(&mut *crate::util::lock_or_recover(sink));
    // Unreapable after SIGKILL: report what a killed process reports rather than blocking on it.
    // `timed_out` is already true on this path (nothing else reaches it), so the client classifies
    // this as `VCSRemoteFailure.timedOut` exactly as it would a child we did manage to reap — the
    // outcome is the same fact, and the ONLY difference is whether this thread waited forever to
    // state it. Deliberately not `outcomeUnknown`: we know what happened to this command.
    //
    // The handle is moved to a detached thread rather than dropped: Rust's `Child::drop` does not
    // wait, so dropping it here would leave a zombie nothing ever reaps. Mirrors the drain detach
    // above — one parked thread that ends whenever the process finally does.
    let Some(status) = status else {
        std::thread::spawn(move || {
            let _ = child.wait();
        });
        return Ok(Captured {
            stdout: take(&out_sink),
            stdout_truncated: out_overflow.load(Ordering::Acquire),
            stderr: take(&err_sink),
            exit_code: 137,
            timed_out: true,
            signaled: true,
        });
    };
    Ok(Captured {
        stdout: take(&out_sink),
        stdout_truncated: out_overflow.load(Ordering::Acquire),
        stderr: take(&err_sink),
        // Never -1: that value IS `CommandResult.launchFailed` in Swift ("nothing ran"), and a
        // process that got this far demonstrably ran. `code()` is None only when signaled, and a
        // signaled status always carries a signal number, so the fallback is unreachable — pinned
        // to 128+SIGKILL (the shell's own convention) rather than to a Swift sentinel.
        exit_code: status
            .code()
            .unwrap_or_else(|| status.signal().unwrap_or(137)),
        timed_out,
        signaled: status.signal().is_some(),
    })
}

#[cfg(test)]
mod tests;
