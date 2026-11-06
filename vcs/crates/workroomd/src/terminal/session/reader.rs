//! The reader each session's pty has for its whole life, and how a session ends with it.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
#[cfg(target_os = "linux")]
use std::time::Instant;

use super::attached::{apply_size, deliver, send_images, targets, terminal_envelope};
use super::terminate::{sweep_run_session, terminate};
use super::{Attached, Hooks, Session, SessionId, SessionStore, TERMINATING, exit_code};
use crate::terminal::images;
use crate::terminal::pty::Pty;
use crate::terminal::shadow::Shadow;
use crate::util::{lock_or_recover, recover};
use wr_protocol::frame::{Frame, FrameKind};

/// How often a run session's reader looks in on its supervisor while its pty is quiet.
/// Only a fallback for Linux kernels that cannot provide a pidfd.
#[cfg(target_os = "linux")]
const RUN_EXIT_POLL: Duration = Duration::from_millis(250);

/// Whether `pid` has exited, without reaping it: `child_gone` reaps it as the session is removed,
/// under `TERMINATING`, so a hand-off never carries a session whose shell is already reaped.
#[cfg(any(target_os = "linux", test))]
pub(super) fn child_exited(pid: i32) -> bool {
    if pid <= 0 {
        return true;
    }
    // SAFETY: an all-zero `siginfo_t` is a valid value; `waitid` writes only into it.
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    // SAFETY: `info` is live for the call; `pid` is this pty's own child.
    let rc = unsafe {
        libc::waitid(
            libc::P_PID,
            pid as libc::id_t,
            &mut info,
            libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
        )
    };
    // With nothing to report, `WNOHANG` leaves `si_pid` zero; an error means it is reaped already.
    // SAFETY: `info` was zeroed, then written only by `waitid`.
    rc != 0 || unsafe { info.si_pid() } != 0
}

/// Whether the pty's child has actually exited, reaping it if so.
///
/// `WNOHANG`, because the read can end a moment before the exit is reapable and telling the client
/// promptly matters more than the exact status. A negative return is `ECHILD` — already reaped by
/// someone else, which is equally gone.
pub(super) fn child_gone(pid: i32, status: &mut i32) -> bool {
    if pid <= 0 {
        return true;
    }
    // SAFETY: `status` is a live `&mut i32` for the call; `pid` is this pty's own child.
    let rc = unsafe { libc::waitpid(pid, status, libc::WNOHANG) };
    rc != 0
}

/// Reads a session's pty for the session's whole life — attached or not.
///
/// **Owned by the session, not by the connection, and that is the fix for a real bug.** While the
/// reader belonged to the connection, a detached session had NO reader: its output never reached
/// the shadow, so a reattaching client was repainted with a stale screen, and — worse — once the
/// pty's output queue filled, the shell BLOCKED on write. A background job in a pane you had
/// closed the app on would simply stop, and only start again when you came back. The Swift helper
/// polled every pty regardless of attachment; this restores that.
///
/// It also ends the session when the shell exits, whether or not anyone is watching. Previously a
/// shell that died while detached left a session in the list that nothing could ever be attached
/// to.
/// How much output travels in one frame.
///
/// The pty reader's buffer, and also the chunk size of a repaint: `attach`'s, and the one
/// `terminal::dispatch` sends a restored pane from a record. All of them must stay under the
/// protocol's 1 MiB frame cap, which `Frame::encode` enforces with a panic rather than a
/// truncation. Sharing one constant means those paths cannot drift apart.
pub const READ_CHUNK: usize = 8192;

/// Removes `id` from the store if it is still the session numbered `number`. A reader ending after
/// `kill` has already removed its session must not remove the next session created under the same
/// id: that session would be left running with nothing in the store to reach or end it.
/// Returns whether it removed one, which is whether nothing else had ended the session first.
fn remove_if_held(store: &mut HashMap<SessionId, Session>, id: SessionId, number: u64) -> bool {
    let held = store
        .get(&id)
        .is_some_and(|session| session.number == number);
    if held {
        store.remove(&id);
        crate::daemon::serve::wake_idle();
    }
    held
}

/// Writes a probe's answer to the pty, non-blocking: a program that is not reading its input (a
/// paste it has not taken yet) must not stall every client's output. What does not fit is dropped,
/// never retried out of order, so with the input queue nearly full a prefix of the answer can land
/// (logged); the queue is only that full when the program is not reading.
///
/// Accepted limit: an answer can land between two writes of a large paste, inside it.
fn answer_program(pty: &Pty, answer: &[u8], id: SessionId, hooks: &Hooks) {
    let written = pty.write(answer);
    if !matches!(written, Ok(n) if n == answer.len()) {
        hooks.reply_dropped();
        crate::note!(
            "session {}: a program status answer was dropped ({written:?})",
            id.to_hyphenated()
        );
    }
}

pub(super) fn read_session(
    id: SessionId,
    number: u64,
    pty: Arc<Pty>,
    shadow: Arc<Mutex<Shadow>>,
    attached: Arc<Mutex<Attached>>,
    sessions: SessionStore,
) {
    // The store's shared parts the reader uses: the map, and the hooks it calls at output and at
    // its end, here on this thread (see `Hooks`).
    let store = Arc::clone(&sessions.sessions);
    let hooks = Arc::clone(&sessions.hooks);
    let mut buffer = [0u8; READ_CHUNK];
    // A run session ends when its supervisor does, even while something it left behind holds the
    // pty open. On Linux a master reads EIO only once every holder of the slave has closed it, so
    // a server its launcher forked out of the run's process group, which `sweep_run_session` is
    // there to end, would otherwise keep the session, and so itself, alive (#522, R8). macOS
    // reports the end as soon as the supervisor exits, so its ordinary pty wait is sufficient.
    // Linux waits on a pidfd alongside the pty. If one cannot be opened, the timed fallback still
    // checks under chatty output so a leftover cannot hide its supervisor's end.
    #[cfg(target_os = "linux")]
    let run = lock_or_recover(&store).get(&id).is_some_and(|session| {
        session.number == number && crate::terminal::run::is_run(&session.metadata)
    });
    #[cfg(target_os = "linux")]
    let exit_fd = run.then(|| pty.child_exit_fd().ok()).flatten();
    #[cfg(target_os = "linux")]
    let mut looked_in = Instant::now();
    loop {
        // Wait OUTSIDE the lock, read under it. A blocked wait holding the attachment lock would
        // stall every attach and every hand-off freeze until the shell next spoke. A failed wait
        // is not acted on here: the read below sees the same condition and classifies it.
        #[cfg(target_os = "linux")]
        let supervisor_exited = if run {
            if let Some(exit_fd) = &exit_fd {
                pty.wait_readable_or_exit(exit_fd).unwrap_or(false)
            } else {
                let quiet = matches!(pty.wait_readable_within(RUN_EXIT_POLL), Ok(false));
                if quiet || looked_in.elapsed() >= RUN_EXIT_POLL {
                    looked_in = Instant::now();
                    child_exited(pty.child_pid())
                } else {
                    false
                }
            }
        } else {
            let _ = pty.wait_readable();
            false
        };
        #[cfg(not(target_os = "linux"))]
        let supervisor_exited = {
            let _ = pty.wait_readable();
            false
        };
        // Read UNDER the attachment lock, and write to the shadow before releasing it. A byte
        // then leaves the pty only while this lock is held and is in the shadow by the time it is
        // released, so whoever holds every session's lock (`SessionStore::frozen`) holds a shadow
        // with every byte ever read and a pty with every byte not. A hand-off depends on exactly
        // that: a byte read and not yet shadowed when the program is replaced is a byte no client
        // ever sees. The read is non-blocking, so holding the lock across it costs nothing.
        //
        // The shadow absorbs the bytes and the destination is chosen under the same lock, as one
        // step — otherwise an attach landing between the two either misses output or replays it
        // twice. The transport write itself then happens with the lock RELEASED, and that
        // matters: holding it across a write would let one client that has stopped reading stall
        // the pty drain for every byte, which is the very problem this reader exists to prevent.
        //
        // Releasing early is still correct because the destination was captured first. A client
        // that attaches after the capture is painted from the shadow, which already holds these
        // bytes; it cannot receive them twice, and the superseded client's writer is the one this
        // write goes to.
        //
        // The program status answer and event are taken under the same locks, as one step with
        // the bytes that produced them, and sent once they are released.
        let (read, clients, answer, published) = {
            let mut held = lock_or_recover(&attached);
            let read = pty.read(&mut buffer);
            let mut answer = Vec::new();
            let mut published = None;
            let clients = match read {
                Ok(n) if n > 0 => {
                    let disturbed = {
                        let mut shadow = lock_or_recover(&shadow);
                        shadow
                            .watch_for_transfers(held.clients.iter().any(|c| c.transfer.is_some()));
                        let (replies, changed) =
                            shadow.write_from_pty(&buffer[..n], || pty.foreground_pgid());
                        answer = replies;
                        published = changed.and_then(|blocked| {
                            let status = shadow.status()?;
                            Some((status.event(hooks.boot(), id), blocked))
                        });
                        shadow.take_disturbed()
                    };
                    held.changed = true;
                    hooks.screen_changed();
                    held.clients
                        .iter_mut()
                        .map(|client| {
                            let mut target = client.target();
                            if let Some(disturbed) = &disturbed {
                                let loading = client
                                    .transfer
                                    .as_ref()
                                    .is_some_and(|transfer| transfer.is_loading());
                                if loading || !disturbed.only_if_loading {
                                    client.transfer.take().map(|transfer| transfer.stop());
                                    target.abort_at = disturbed.abort_at.filter(|_| loading);
                                }
                            }
                            target
                        })
                        .collect::<Vec<_>>()
                }
                _ => Vec::new(),
            };
            (read, clients, answer, published)
        };
        // Before the output goes to any client: a program sends its probe followed by a `CSI c`
        // the client answers, and reads the two answers in that order (#358, Step 0).
        if !answer.is_empty() {
            answer_program(&pty, &answer, id, &hooks);
        }
        if let Some((event, blocked)) = published {
            hooks.status_changed(id, event, blocked);
        }

        // "The child is gone" looks different on each platform: reading a pty master whose child
        // has exited yields EOF on Darwin and **EIO** on Linux. Deciding it once, here, is what
        // stops the rest of this loop from having to know that — and matching only on EOF meant
        // the branch below never ran on Linux at all, while macOS exercised it and made the code
        // look correct. Found by running the suite in a Linux container.
        // A run's supervisor that has gone ends it too (see `run`), whatever is still to read: that
        // is what it left behind, which `sweep_run_session` is about to end.
        let ended = supervisor_exited
            || match &read {
                Ok(0) => true,
                Err(e) => matches!(e.raw_os_error(), Some(libc::EIO) | Some(libc::EBADF)),
                _ => false,
            };

        // A read saying "ended" is not proof, so confirm it against the CHILD before tearing a
        // session down. macOS returns a transient `read == 0` on a freshly forked master while the
        // shell is alive and merely has nothing to say — believing it ends the session moments
        // after creating it. The old pump never saw this because it only existed once a client had
        // attached, by which time the window had passed; a reader owned by the session starts
        // inside it.
        //
        // Reaped and removed as one step under `TERMINATING`: a hand-off freezing between the two
        // would carry a session whose shell is already reaped. The `Exited` frames go out after,
        // with the lock released, so a slow client does not hold a hand-off off.
        let mut status = 0;
        if ended {
            let terminating = recover(TERMINATING.read());
            if !child_gone(pty.child_pid(), &mut status) {
                drop(terminating);
                std::thread::sleep(Duration::from_millis(5));
                // A quiet master can read this way for as long as its shell says nothing, which
                // is when a transfer has the stream to itself.
                send_images(&pty, &shadow, &attached, &hooks);
                continue;
            }
            // The shell IS the session; with it gone there is nothing left to reattach to.
            // `replaced`: a later session already holds the id, and its subscribers' records.
            let (held, replaced, run) = {
                let mut store = lock_or_recover(&store);
                let run = store.get(&id).is_some_and(|session| {
                    session.number == number && crate::terminal::run::is_run(&session.metadata)
                });
                (
                    remove_if_held(&mut store, id, number),
                    store.contains_key(&id),
                    run,
                )
            };
            if held {
                hooks.ended(run);
            }
            if held && run {
                sweep_run_session(id, pty.child_pid());
            }
            // Under `TERMINATING`, so a hand-off cannot replace this program between the removal and
            // the line, which would carry neither the session nor any record of its end. Outside
            // the store lock, so a stderr that has stopped draining (a supervisor's pipe) stalls
            // nothing that `list`, `attach` or `kill` waits on, and a hand-off's freeze gives up on
            // it after `handoff::FREEZE_TIMEOUT` rather than hanging. Before the `Exited` frames, whose
            // delivery to a client that has stopped reading can take a `WRITE_TIMEOUT`.
            //
            // Not held: `kill` ended it, reaped the shell, and already said so. The status read here
            // would then be a zero that `waitpid` never wrote.
            if held {
                crate::note!(
                    "session {} ended: shell pid {} {}",
                    id.to_hyphenated(),
                    pty.child_pid(),
                    crate::daemon::log::describe_status(status)
                );
            }
            drop(terminating);
            if !replaced {
                hooks.program_ended(id, &shadow);
            }
            for target in targets(&attached) {
                let bytes = terminal_envelope(
                    target.stream,
                    // The code a shell would report, not the raw `waitpid` status: `exit 7` is 7
                    // here, not 1792. See `exit_code`.
                    Frame::new(FrameKind::Exited, exit_code(status).to_be_bytes().to_vec()),
                );
                deliver(&attached, &target, &bytes);
            }
            return;
        }

        match read {
            Ok(n) => {
                // Every attached client sees the same bytes — that is what makes two windows on
                // one session show the same terminal rather than half of it each.
                for target in &clients {
                    let mut output = buffer[..n].to_vec();
                    if let Some(at) = target.abort_at {
                        output.splice(at..at, images::ABORT.iter().copied());
                    }
                    let bytes =
                        terminal_envelope(target.stream, Frame::new(FrameKind::Output, output));
                    let size = deliver(&attached, target, &bytes);
                    apply_size(&pty, &shadow, &attached, size, &hooks);
                }
            }
            // `Interrupted` is not a failure — a signal arriving mid-read is ordinary, and the
            // daemon takes SIGWINCH and SIGCHLD. Treated as fatal it ended the reader on a read
            // that had not actually failed. Nothing to say yet: back to `wait_readable`.
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::Interrupted => {}
            // A genuinely fatal read. The session goes with the reader: this was the one exit that
            // did not remove it from the store, so the entry outlived the only thread that drains
            // it — `list` still advertised it, `attach` still succeeded, and nothing read the pty
            // again, so the shell blocked on a full output queue. It also kept `sessions` non-empty
            // forever, so the daemon never idled out.
            //
            // Torn down the same way the `ended` branch above does, because a client that is told
            // nothing keeps a pane that looks live over a session that no longer exists, and its
            // input then vanishes into a `parts(id)` that returns `None`. The child is terminated
            // too: closing the master alone hangs up the pty's foreground group and leaves exactly
            // the `setsid()` descendants `terminate`'s snapshot exists to reach.
            Err(e) => {
                crate::note!(
                    "session {} ended: its pty could not be read ({e}); hanging up shell pid {}",
                    id.to_hyphenated(),
                    pty.child_pid()
                );
                for target in targets(&attached) {
                    let framed = terminal_envelope(
                        target.stream,
                        Frame::new(
                            FrameKind::Failure,
                            b"the session's pty could not be read".to_vec(),
                        ),
                    );
                    deliver(&attached, &target, &framed);
                }
                let _terminating = recover(TERMINATING.read());
                terminate(&[&pty]);
                let replaced = {
                    let mut store = lock_or_recover(&store);
                    remove_if_held(&mut store, id, number);
                    store.contains_key(&id)
                };
                hooks.screen_changed();
                if !replaced {
                    hooks.program_ended(id, &shadow);
                }
                return;
            }
        }
        send_images(&pty, &shadow, &attached, &hooks);
    }
}
