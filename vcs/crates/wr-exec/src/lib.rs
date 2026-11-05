//! Child processes, supervised one way for the whole workspace.
//!
//! The pattern every caller needs is "spawn in its own group, capture with a bound, time out,
//! signal the tree, SIGKILL survivors, reap", and it used to be written four times in two crates,
//! with the copies drifting: wr-vcs-git's reads only killed the group, so a `setsid` escaper
//! outlived them. The pieces are here once:
//!
//! - the process tree, recorded before anything is signalled ([`descendants`], [`snapshot`],
//!   [`Descendant`]), and the identity-checked kill of what was recorded ([`kill_recorded`]);
//! - [`end_tree`], the group-then-recorded-tree ending for a child that leads its own group
//!   (workroomd's exec service and `run-script`, and wr-vcs-git's reads);
//! - two bounded drains, one blocking for a reader the caller may detach ([`drain_capped`]) and one
//!   non-blocking against a deadline for a reader the caller joins ([`drain_until`]);
//! - the descriptor flags ([`set_nonblocking`], [`set_cloexec`]).
//!
//! A session's termination (workroomd's `terminate`) uses the tree and the identity check but keeps
//! its own sequence: it hangs up each pid rather than signalling a group, has many roots, and reaps
//! with `waitpid`. What a git child's environment must hold is git's policy, kept in wr-vcs-git.
use std::io::Read;
use std::os::fd::{AsRawFd, RawFd};
use std::process::{Child, ExitStatus};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

mod tree;

pub use tree::{Descendant, descendants, session_members};

/// Every descendant of `pid`, snapshotted with its start time via [`descendants`] — the same walk
/// a session's termination uses to reach a `setsid` grandchild, and split from the killing for a
/// reason that path did not need to face: this must be SNAPSHOTTED WHILE THE PARENT IS STILL ALIVE.
///
/// A descendant that calls `setsid` leaves the process group, so `kill(-pid, …)` never reaches it —
/// but it keeps its real ppid until its parent dies, so the walk finds it right up to that moment.
/// Once the parent is reaped the orphan re-parents to init and both handles are gone: the group it
/// left, and a lineage that no longer leads back to us. Walking the tree at KILL time therefore
/// finds nothing, which is the hole native's `killTree` also has — it is called at `timeout + 2`,
/// by which point a `git` that exited on SIGTERM has long been reaped.
///
/// So the walk happens when the first signal is sent, and the recorded descendants are what gets
/// checked and SIGKILLed later. `pid <= 1` is refused outright: [`descendants`] does not
/// special-case init the way this call site must not — `pid` is always a freshly spawned child's
/// own pid, but a SIGKILL aimed at init's whole descendant tree is the worst outcome a bug here
/// could have.
pub fn snapshot(pid: i32) -> Vec<Descendant> {
    if pid <= 1 {
        return Vec::new();
    }
    descendants(&[pid])
}

/// SIGKILL whichever recorded descendants are still the SAME process, checked with
/// [`Descendant::is_running`] rather than by bare pid — the identity check a session's termination
/// already applies before its own SIGKILL sweep.
///
/// Without it this call carried a PID-reuse window strictly worse than native's: these pids were
/// read at SIGTERM time and this runs roughly two seconds later, long enough on a busy machine for
/// a descendant to exit and its number to be handed to something unrelated. `is_running` compares
/// the process's start time against the one recorded at the snapshot, so a pid whose occupant has
/// changed reads as not-running and is left alone — the small, unavoidable window native accepts is
/// only "the pid exited and nothing new has it yet", never "the pid now names someone else".
pub fn kill_recorded(descendants: &[Descendant]) {
    for descendant in descendants.iter().filter(|d| d.is_running()) {
        // SAFETY: `kill` takes no pointers; `is_running` is the pid-reuse guard described above.
        unsafe { libc::kill(descendant.pid, libc::SIGKILL) };
    }
}

/// How long to keep trying to reap a process we have SIGKILLed before giving up on it. SIGKILL
/// cannot be caught, so this is generous for the normal case; it exists for the abnormal one, where
/// the leader is unkillable (uninterruptible I/O) and the alternative is blocking the caller's
/// thread — for the exec service, one of the 32 shared `ACTIVE` permits — forever.
pub const REAP_GRACE: Duration = Duration::from_secs(2);

/// How often [`end_tree`] looks at whether the child has exited.
const POLL: Duration = Duration::from_millis(10);

/// Ends the process group `child` leads and every descendant recorded before the first signal:
/// `first_signal` to the group, the whole of `grace`, then SIGKILL to what was recorded and to the
/// group, and a reap bounded by [`REAP_GRACE`]. Returns the child's status, or `None` when it could
/// not be reaped in that time, which the caller reports rather than waits on.
///
/// `child` must lead its own process group (`process_group(0)`) and must not have been reaped yet:
/// its pid is then still ours, since a zombie's pid is not reused, so the snapshot cannot walk an
/// unrelated process's tree.
///
/// The whole grace, even once the leader has gone: its group may still be cleaning up. `git` can
/// exit on SIGTERM while a hook is still cleaning up, and cutting that short can leave hook-owned
/// locks behind (`CLIVCSWriter.commitTimeout`: "Killing a commit is categorically more dangerous
/// than killing a fetch").
///
/// The SIGKILL goes first to the descendants recorded before the first signal ([`kill_recorded`],
/// which skips any whose start time changed, so a reused pid is never signalled) — that is what
/// reaches one that `setsid`ed out of the group — and then to the group itself, which reaches one
/// that spawned after the snapshot. The group signal, like native's `ProcessTree.killTree` at
/// `timeout + 2`, still names a leader pid that may already have been reaped, the same small
/// PID-reuse window.
pub fn end_tree(
    child: &mut Child,
    first_signal: libc::c_int,
    grace: Duration,
) -> Option<ExitStatus> {
    let pid = child.id() as i32;
    // Snapshot BEFORE signalling: the first signal may reap the leader within microseconds, and an
    // orphaned `setsid` descendant is unreachable from that moment on.
    let recorded = snapshot(pid);
    // SAFETY: `kill` takes no pointers; `-pid` is the group the child leads.
    unsafe { libc::kill(-pid, first_signal) };
    let mut status = None;
    let kill_at = Instant::now() + grace;
    while Instant::now() < kill_at {
        if status.is_none()
            && let Ok(Some(exited)) = child.try_wait()
        {
            status = Some(exited);
        }
        std::thread::sleep(POLL);
    }
    // Recorded tree first, then group: the tree reaches a descendant that left the group, the group
    // reaches one that spawned after the snapshot.
    kill_recorded(&recorded);
    // SAFETY: as for the first signal.
    unsafe { libc::kill(-pid, libc::SIGKILL) };
    let killed_at = Instant::now();
    while status.is_none() && killed_at.elapsed() < REAP_GRACE {
        match child.try_wait() {
            Ok(Some(exited)) => status = Some(exited),
            _ => std::thread::sleep(POLL),
        }
    }
    status
}

/// Drain a pipe to EOF on its own thread (mirrors `StatusCommandRunner.readCapped`): a blocking
/// read is safe here because it runs off the thread that watches for timeout/exit, and keeps
/// draining past `cap` so the child can never block on a full pipe buffer.
///
/// Publishes into a shared sink rather than returning, so a caller can take what has drained so far
/// WITHOUT joining this thread. That matters because this thread can block forever: a descendant
/// that inherited the pipe (an ssh `ControlPersist` master, a daemonising credential helper,
/// gpg-daemon auto-launched by `commit -S`) holds the write end open after the child is reaped, and
/// `setsid` puts it outside the process group the caller signals.
pub fn drain_capped(source: impl Read, cap: usize, sink: &Mutex<Vec<u8>>) {
    drain_capped_flagged(source, cap, sink, &AtomicBool::new(false));
}

/// [`drain_capped`], also raising `overflowed` the moment a byte is dropped for lack of room. A
/// stream that ends EXACTLY at `cap` does not raise it, so the flag means "something was lost",
/// never "the buffer is full".
pub fn drain_capped_flagged(
    mut source: impl Read,
    cap: usize,
    sink: &Mutex<Vec<u8>>,
    overflowed: &AtomicBool,
) {
    let mut chunk = [0u8; 65536];
    loop {
        match source.read(&mut chunk) {
            Ok(0) => return,
            Ok(count) => {
                let mut collected = sink.lock().unwrap_or_else(|e| e.into_inner());
                let take = cap.saturating_sub(collected.len()).min(count);
                collected.extend_from_slice(&chunk[..take]);
                if take < count {
                    overflowed.store(true, Ordering::Release);
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        }
    }
}

/// Reads `source` to EOF, non-blocking, giving up at `deadline` or once `exceeded` is raised, by
/// this reader or by another sharing the flag. Raises `exceeded` when the output would pass `cap`,
/// and keeps nothing past it.
///
/// For a reader the caller JOINS: it cannot outlive `deadline`, however long a descendant holds the
/// pipe open, where [`drain_capped`]'s blocking read can, and must then be detached instead.
pub fn drain_until(
    mut source: impl Read + AsRawFd,
    cap: usize,
    exceeded: &AtomicBool,
    deadline: Instant,
) -> std::io::Result<Vec<u8>> {
    set_nonblocking(source.as_raw_fd())?;
    let mut result = Vec::new();
    let mut bytes = [0; 8192];
    loop {
        if Instant::now() >= deadline || exceeded.load(Ordering::Relaxed) {
            return Ok(result);
        }
        let count = match source.read(&mut bytes) {
            Ok(count) => count,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(5));
                continue;
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if count == 0 {
            return Ok(result);
        }
        if result.len() + count <= cap {
            result.extend_from_slice(&bytes[..count]);
        } else {
            exceeded.store(true, Ordering::Relaxed);
        }
    }
}

/// Makes reads on `fd` return `WouldBlock` instead of waiting, keeping its other status flags.
///
/// A blocking read on a pipe with no data and a live writer waits forever, which silently defeats
/// any deadline the caller thinks it has.
pub fn set_nonblocking(fd: RawFd) -> std::io::Result<()> {
    // SAFETY: F_GETFL takes and returns plain integers; a stale descriptor only fails.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: as above, for F_SETFL.
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

/// Sets or clears `fd`'s close-on-exec flag, keeping its other descriptor flags. A stale `fd` only
/// fails, and the failure is not reported.
pub fn set_cloexec(fd: RawFd, on: bool) {
    // SAFETY: F_GETFD and F_SETFD take and return plain integers; a stale `fd` only fails.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags >= 0 {
            let flags = if on {
                flags | libc::FD_CLOEXEC
            } else {
                flags & !libc::FD_CLOEXEC
            };
            libc::fcntl(fd, libc::F_SETFD, flags);
        }
    }
}

#[cfg(test)]
mod tests;
