//! `workroomd attach`: the relay libghostty forks as a pane's `config.command`.
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use super::{DAEMON_UNAVAILABLE, flag, handshake};
use crate::serve;
use wr_protocol::envelope::{Envelope, EnvelopeDecoder, Service};
use wr_protocol::frame::{Frame, FrameDecoder, FrameKind};

/// What a restored pane (`--no-create`) shows when its session has ended and the daemon kept no
/// record of it (`crate::screens`), if it cannot be given a new session instead.
///
/// On this Mac, a new shell in its place. Reached only when the session exits between the daemon's
/// check and its attach; a plain refusal gets a new session (`run_attach`). On a remote host
/// (`--no-spawn`), never a shell (#255, D7): one started here would be this process's child, not a
/// daemon session; no other Mac could see it and it would die with the ssh link. The pane is told
/// the terminal ended, then holds with input going nowhere until its user closes it, as a pane
/// shown a record does.
///
/// A run session's pane is never given a shell, here or remotely: it would run the run command,
/// starting a dev server nobody asked for (#522, D2). It says the run ended and holds, and the app,
/// which knows the run, offers to start it again.
fn ended(request: &serve::AttachRequest, no_spawn: bool) -> ExitCode {
    let run = crate::run::is_requested(&request.env);
    if !no_spawn && !run {
        return fall_back_to_shell(
            request,
            "the terminal that was running here has ended, so this is a new shell",
        );
    }
    let notice = if run { RUN_ENDED_NOTICE } else { ENDED_NOTICE };
    let mut stdout = std::io::stdout();
    let _ = write!(stdout, "\r\nworkroom: {notice}\r\n");
    let _ = stdout.flush();
    let _raw = RawMode::enter();
    let _ = std::io::copy(&mut std::io::stdin(), &mut std::io::sink());
    ExitCode::SUCCESS
}

/// What a remote pane says when its session has ended and no record of it was kept.
const ENDED_NOTICE: &str = "This terminal has ended. Close it to start again.";
/// What a run session's pane says when its session has ended.
const RUN_ENDED_NOTICE: &str = "The run command that was running here has ended.";

/// Become an ordinary shell, because this relay could not deliver a persistent session.
///
/// **Why the relay and not the app.** The app decides whether a pane gets a session before it
/// forks anything: `applyPersistentSession` either hands libghostty `workroomd attach` as its
/// `config.command` or lets it open a plain shell, and by the time this process exists that choice
/// is spent. `config.wait_after_command` is false, so a relay that exits leaves a dead pane — no
/// shell, no prompt, nothing the user can type into. The only place left that can still turn a
/// failed attach into a working terminal is this process, by replacing itself with the shell the
/// pane would have run anyway.
///
/// The app's own health check cannot prevent this. `SessionBackendProbe` runs `workroomd protocol`
/// and parses a version; a daemon that answers that and then fails to serve — a stale socket it
/// cannot bind, a version it cannot negotiate, a crash between the two — passes the probe and dies
/// here. "A broken daemon still leaves you a working terminal" is only true if this function exists.
///
/// **Persistence is lost, and that is said out loud.** The notice goes to stderr, which is the pane,
/// because a terminal that silently stopped surviving quit is worse than one that says so: the user
/// would find out by losing work. It is one line, printed once.
///
/// Never returns on success — `exec` replaces this process, so the shell inherits the pty, the
/// window title, the exit status, everything. Returns only when `exec` itself fails.
fn fall_back_to_shell(request: &serve::AttachRequest, reason: &str) -> ExitCode {
    use std::os::unix::process::CommandExt;

    // A run command runs only in a daemon session, whose supervisor the app can stop, restart and
    // reattach to (#522, D5). Run here it would be none of those, and on a remote host it would
    // run on the wrong machine's terms. So it is not run at all, and the pane says why.
    if crate::run::is_requested(&request.env) {
        eprintln!("workroomd: could not start the run command: {reason}\r");
        return ExitCode::from(DAEMON_UNAVAILABLE);
    }

    let text = |value: &Option<std::ffi::OsString>| {
        value
            .as_ref()
            .map(|v| v.to_string_lossy().into_owned())
            .unwrap_or_default()
    };

    // The SAME invocation the daemon would have exec'd in the pty, not a hand-rolled one.
    //
    // The first version of this ran `$SHELL -l`, which is wrong twice over. `-l` is not what makes
    // a login shell — `argv[0]` prefixed with `-` is, and there is no flag for it (see shell.rs) —
    // and it skipped ghostty's shell integration, so the pane lost OSC 133 and OSC 7: a title the
    // user's prompt sets would latch and never clear, and the footer would never learn the working
    // directory. `shell::invocation` knows all of that, per shell, and routes a run command through
    // `/bin/sh -c "exec …"` rather than through a `$SHELL` that may not be POSIX at all.
    let mut environment: Vec<(std::ffi::OsString, std::ffi::OsString)> = request
        .env
        .iter()
        // Nothing downstream should believe it is inside a session that does not exist.
        .filter(|(key, _)| !key.to_string_lossy().starts_with("WORKROOM_SESSION_"))
        .cloned()
        .collect();
    // A marker the app, a shell prompt, or a bug report can see. The notice below is one line into
    // a login shell whose own startup may clear the screen (instant prompts, a `clear` in
    // `.zprofile`), so it cannot be the only signal that persistence was lost.
    environment.push((
        std::ffi::OsString::from("WORKROOM_SESSION_FALLBACK"),
        std::ffi::OsString::from("1"),
    ));

    // A shell with no slash would be PATH-searched by `exec` (which ends in `execvp`), while the
    // daemon's own pty spawn uses `execve` and does not search (`pty.rs`). Two paths documented as
    // running "the SAME invocation" must not disagree about what a shell path means, so a
    // slash-less value is treated as unusable rather than resolved differently here.
    let requested_shell = text(&request.shell);
    let shell = if requested_shell.contains('/') {
        requested_shell
    } else {
        crate::shell::DEFAULT_SHELL.to_string()
    };

    let invocation = crate::shell::invocation(
        &text(&request.command),
        &shell,
        &text(&request.resources),
        &environment,
    );

    eprintln!("workroomd: {reason}; this terminal will not survive quitting Workroom\r");

    let mut command = std::process::Command::new(&invocation.program);
    if let Some((argv0, rest)) = invocation.arguments.split_first() {
        command.arg0(argv0);
        command.args(rest);
    }
    command.env_clear();
    command.envs(invocation.environment.iter().map(|(k, v)| (k, v)));
    // `chdir` happens INSIDE the exec, so a directory it cannot enter aborts the whole thing —
    // producing the dead pane this function exists to prevent, and blaming the shell for it. A
    // workroom's directory being deleted while a tab is open is a supported operation (`reap`), so
    // this is reachable.
    //
    // **Tried in turn rather than pre-checked**, because the two are not the same test. An earlier
    // version picked the first entry passing `is_dir()` and committed to it — but a directory can
    // exist, pass `is_dir()`, and still refuse `chdir` for want of the execute bit, and then the
    // exec fails with no second chance. `exec` only returns on failure, so the loop below IS the
    // fallback chain the daemon's own child uses (`pty.rs`: requested, then `$HOME`, then `/`).
    for directory in candidate_directories(request.cwd.as_ref()) {
        command.current_dir(&directory);
        let error = command.exec();
        // Reached only when exec failed. If the working directory is why, the next candidate may
        // work; if it is the shell itself, every candidate fails the same way and the loop ends.
        if error.kind() != std::io::ErrorKind::NotFound
            && error.kind() != std::io::ErrorKind::PermissionDenied
        {
            eprintln!(
                "workroomd: could not start {}: {error}\r",
                invocation.program.to_string_lossy()
            );
            return ExitCode::from(DAEMON_UNAVAILABLE);
        }
    }
    eprintln!(
        "workroomd: could not start {} in any working directory\r",
        invocation.program.to_string_lossy()
    );
    ExitCode::from(DAEMON_UNAVAILABLE)
}

/// The pane's directory, then the fallbacks, in the order they should be attempted.
///
/// Empty entries are dropped; existence is NOT checked here, because `chdir` is the only authority
/// on whether a directory can be entered and it runs inside `exec`.
fn candidate_directories(requested: Option<&std::ffi::OsString>) -> Vec<PathBuf> {
    [
        requested.cloned().map(PathBuf::from),
        std::env::var_os("HOME").map(PathBuf::from),
        Some(PathBuf::from("/")),
    ]
    .into_iter()
    .flatten()
    .filter(|path| !path.as_os_str().is_empty())
    .collect()
}

pub fn run_attach(args: &[String]) -> ExitCode {
    // **Only a relay falls back**, and this is read BEFORE anything can write to it. `attach` is
    // also a documented subcommand someone can type, and answering a typo by silently opening a
    // nested login shell inside their current one is absurd — the same reasoning `run_list` uses.
    // The app always exports the session variables, so their total absence is the tell.
    //
    // Order is the whole correctness argument here. The `--session` flag below writes
    // `WORKROOM_SESSION_ID` into this process's own environment, so reading the flag first let a
    // hand-typed `attach --session <uuid>` forge the very evidence that classifies it as
    // app-invoked — and the only regression test ran bare `attach` with no flags, so it could not
    // see that. `WORKROOM_SESSION_CWD` is included because it is exported by
    // `PersistentSessionService.launchEnvironment` and has no flag that can fake it.
    let invoked_by_the_app = std::env::var_os("WORKROOM_SESSION_SOCKET").is_some()
        || std::env::var_os("WORKROOM_SESSION_ID").is_some()
        || std::env::var_os("WORKROOM_SESSION_CWD").is_some();

    // Flags win, environment is the fallback — and the environment alone has to be enough, because
    // `PersistentSessionService.attachCommand()` builds the command line as `<binary> attach` with
    // no arguments at all. Everything the app wants to say, it says through the variables it
    // already exports.
    if let Some(text) = flag(args, "--session") {
        // Safety: set before any thread is spawned, and only so the shared parser can read it.
        unsafe { std::env::set_var("WORKROOM_SESSION_ID", text) };
    }
    // Parsed BEFORE the socket is resolved, so a misconfigured invocation can still fall back to a
    // shell: `fall_back_to_shell` reads the shell, cwd and resources the app exported, and those
    // arrive in the same environment.
    let mut request = serve::AttachRequest::from_env();
    // `--no-create`: attach only if the session exists (see `AttachRequest::existing_only`).
    request.existing_only = args.iter().any(|arg| arg == "--no-create");
    // `--no-spawn`: never start a daemon. On a remote host that is the supervisor's job, and a
    // daemon started here would be the idle-exit kind a remote host must not have, racing the
    // supervised one for the socket (#228). It also changes what a lost daemon connection means:
    // see the main loop's `Ok(0) | Err(_)` arm.
    let no_spawn = args.iter().any(|arg| arg == "--no-spawn");

    let give_up = |reason: &str| -> ExitCode {
        if invoked_by_the_app {
            fall_back_to_shell(&request, reason)
        } else {
            eprintln!("error: attach needs --socket <path> and --session <uuid>, or the");
            eprintln!("       WORKROOM_SESSION_* environment the app exports ({reason})");
            ExitCode::FAILURE
        }
    };

    let socket = flag(args, "--socket")
        .map(PathBuf::from)
        .or_else(serve::socket_from_env);
    let Some(socket) = socket else {
        return give_up("no session socket was given");
    };

    let Some(session) = request.id else {
        return give_up("no session id was given");
    };
    // The pty's initial size comes from the terminal this relay was forked into, so a session is
    // created at the size it will actually be shown at rather than at 80x24 and then resized —
    // which a full-screen program would see as a resize on its first frame.
    let (columns, rows) = terminal_size();
    request.columns = columns;
    request.rows = rows;

    // Spawn-on-connect-failure: the daemon is started by whoever needs it first rather than by an
    // installed service, so there is no install footprint. (The Swift attach client used to do the
    // same; it no longer can — its `daemon` subcommand went with the daemon.)
    //
    // Every failure from here to the attach reply becomes a plain shell rather than a dead pane —
    // see `fall_back_to_shell`. These are precisely the states a daemon that PASSED the app's
    // `workroomd protocol` probe can still reach. The exception is a restored pane on a remote host,
    // which exits 255 for the app to attach again instead (`unreachable`, below).
    // None of these is retried here: a daemon greets the moment it accepts, and stops accepting
    // while it hands off, so a failed greeting is a peer that is not a working daemon.
    // `Err`'s flag: nothing is listening yet, the one failure a supervisor starting the daemon heals
    // (see `unreachable`). A peer that answers and fails the handshake is not a daemon that will
    // work if asked again.
    let run = crate::run::is_requested(&request.env);
    let open = || -> Result<std::os::unix::net::UnixStream, (&str, bool)> {
        let mut stream = match serve::connect(&socket) {
            Some(stream) => stream,
            None if no_spawn => {
                return Err((
                    "no session daemon is listening, and on a remote host only its supervisor starts one",
                    true,
                ));
            }
            None => {
                let binary = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("workroomd"));
                if serve::spawn_daemon(&binary, &socket).is_err() {
                    return Err(("could not start the session daemon", false));
                }
                let deadline = std::time::Instant::now() + Duration::from_secs(5);
                loop {
                    if let Some(stream) = serve::connect(&socket) {
                        break stream;
                    }
                    if std::time::Instant::now() >= deadline {
                        return Err(("the session daemon did not start within 5s", false));
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
        };
        let Ok(version) = handshake(&mut stream) else {
            return Err(("could not agree a protocol with the session daemon", false));
        };
        // An older daemon knows no run sessions and would run the command bare, with no supervisor
        // to stop or restart it (D4).
        if run && version < wr_protocol::envelope::MIN_RUN_VERSION {
            return Err((
                "the session daemon is older than this Workroom and can't run it",
                false,
            ));
        }
        Ok(stream)
    };
    let _ = session;
    // A restored pane on a remote host whose daemon is not answering exits 255, which the app
    // answers by attaching again with a backoff. After a reboot sshd can accept before the
    // supervisor's daemon has bound its socket, and a shell here would be a live one in a pane whose
    // session is gone, so its last screen would never be shown (#232). A new remote pane still gets
    // the shell (#229): it has no session to wait for.
    let unreachable = |reason: &str| -> ExitCode {
        if no_spawn && request.existing_only {
            eprintln!("workroomd: {reason}\r");
            ExitCode::from(255)
        } else {
            fall_back_to_shell(&request, reason)
        }
    };
    let encode = |request: &serve::AttachRequest| {
        let attach = Frame::new(FrameKind::Attach, request.encode());
        Envelope::new(Service::Terminal, 1, attach.encode()).encode()
    };
    let mut attach = encode(&request);
    // Whether a restored pane's ended session was replaced by a new one (#459).
    let mut replaced = false;

    let mut buffer = [0u8; 8192];

    // The attach is answered before raw mode and the relay threads. A restored pane's
    // (`--no-create`) session that ended is attached again to create it locally, or becomes the
    // notice a remote pane holds on, which has to start from a cooked terminal with nothing else
    // running. When the daemon kept a record of the session (`crate::screens`), it answers
    // `Attached` and the record instead.
    //
    // A daemon that closes before answering at all is most likely handing off to a new program
    // (`crate::handoff`). Its listener stays open across the exec, so the attach is sent again,
    // and the program that answers next attaches it, or creates it if it never existed. Only a
    // close with no answer is retried, for up to 10s; a peer that stays open and silent is waited
    // on, as an attach always has been. Whatever follows `Attached` stays in `decoder`.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let (mut stream, mut decoder) = loop {
        let mut stream = match open() {
            Ok(stream) => stream,
            Err((reason, true)) => return unreachable(reason),
            Err((reason, false)) => return fall_back_to_shell(&request, reason),
        };
        let mut decoder = EnvelopeDecoder::new();
        let answer = match stream.write_all(&attach) {
            Ok(()) => await_attached(&mut stream, &mut decoder, &mut buffer),
            Err(_) => Answer::Closed,
        };
        match answer {
            Answer::Attached => break (stream, decoder),
            // A restored pane on this Mac whose session has ended gets a new session under the
            // same id, said out loud. A shell that was no session would leave the pane saving the
            // dead id, so it would say "ended" again on every launch and never survive a quit
            // (#459). The app says so in a toast over the pane
            // (`PersistentSessionService.willReplaceRestoredSession`), so the new session does not
            // pass as the old one.
            // Only for the app's own panes: an `attach --no-create` someone typed asked to be
            // refused, and gets no toast to say a session was made. Never for a run session, whose
            // new session would start the run command unasked (#522, D2): it is `ended`.
            Answer::Refused(_)
                if request.existing_only
                    && !no_spawn
                    && !replaced
                    && invoked_by_the_app
                    && !crate::run::is_requested(&request.env) =>
            {
                replaced = true;
                attach = encode(&serve::AttachRequest {
                    existing_only: false,
                    ..request.clone()
                });
            }
            Answer::Refused(reason) if request.existing_only => {
                // After a refused create, why: the fallback's notice says only that it ended.
                if replaced {
                    eprintln!("workroomd: {}\r", String::from_utf8_lossy(&reason));
                }
                return ended(&request, no_spawn);
            }
            // A session that could not be created or attached. See the main loop's `Failure` arm
            // for why this is an error and not a shell.
            Answer::Refused(reason) => {
                eprintln!("workroomd: {}", String::from_utf8_lossy(&reason));
                return ExitCode::FAILURE;
            }
            Answer::Closed if std::time::Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(100));
            }
            Answer::Closed => {
                return unreachable("the session daemon closed before accepting the attach");
            }
        }
    };

    // Before anything reads stdin: a relay that leaves its own tty cooked is not a relay. Held to
    // the end of this function so every `return` below restores the terminal.
    let _raw = RawMode::enter();

    // stdin -> daemon on its own thread; daemon -> stdout on this one.
    let input_stream = match stream.try_clone() {
        Ok(clone) => clone,
        Err(_) => return ExitCode::from(DAEMON_UNAVAILABLE),
    };
    std::thread::spawn(move || relay_stdin(input_stream));

    // And a third watching the terminal's size. Without this the session is stuck at whatever
    // size it was created with: the daemon accepts Resize frames but nothing ever sent one, so
    // resizing a pane left the shell — and any full-screen program in it — rendering at the old
    // geometry forever.
    if let Ok(resize_stream) = stream.try_clone() {
        std::thread::spawn(move || relay_resizes(resize_stream, columns, rows));
    }

    let mut stdout = std::io::stdout();
    loop {
        // What is already decoded first: `await_attached` may have left the repaint in `decoder`.
        loop {
            match decoder.next_envelope() {
                Ok(Some(envelope)) => {
                    let mut frames = FrameDecoder::new();
                    frames.push(&envelope.payload);
                    while let Ok(Some(frame)) = frames.next_frame() {
                        match frame.kind {
                            FrameKind::Output => {
                                if stdout.write_all(&frame.payload).is_err() {
                                    return ExitCode::SUCCESS;
                                }
                                let _ = stdout.flush();
                            }
                            // The shell's own exit code becomes this process's, so a command run
                            // through an attach is indistinguishable from running it directly —
                            // which is what `workroom-session attach` did, and what any caller
                            // testing `$?` depends on.
                            FrameKind::Exited => {
                                let code = frame
                                    .payload
                                    .get(..4)
                                    .map(|b| i32::from_be_bytes(b.try_into().unwrap()))
                                    .unwrap_or(0);
                                // `ExitCode` is a byte; a shell status is already 0-255.
                                let code = code.clamp(0, 255) as u8;
                                // On a remote host (`--no-spawn`) this status is ssh's, and 255 is
                                // what ssh reports for its OWN failure, which the app answers by
                                // reconnecting. A session that ended with 255 must not read as a
                                // dropped link, so it becomes 254.
                                return ExitCode::from(if no_spawn && code == 255 {
                                    254
                                } else {
                                    code
                                });
                            }
                            // **Deliberately NOT a fallback**, and an earlier version of this made
                            // it one. That was wrong in the worst available direction.
                            //
                            // A `Failure` here does not mean the daemon is broken — it is talking,
                            // and the session it is talking about is usually ALIVE. `RepaintFailed`
                            // (session.rs) says so outright: "the client could not take its repaint
                            // whole, so it was not attached at all… can retry from a clean
                            // terminal", and it only fires on reattach to a session that already
                            // has scrollback — precisely the pane with the user's work in it. A
                            // fatal pty read reports the same kind for an already-attached client.
                            //
                            // Exec'ing a shell on either is unrecoverable (exec is one-way, so the
                            // retry the daemon is inviting can never happen) and, worse, it hands
                            // back a healthy-looking prompt for a session that is still running.
                            // That is the exact failure `--no-create` exists to prevent: the one
                            // that looks like success. A visible error and a
                            // non-zero exit is the honest answer, and it leaves the session where
                            // the user can still reach it from the detached-sessions list.
                            // The one exception: a `--no-create` attach whose session exited
                            // between the daemon's check and its attach. That is "ended", not a
                            // failure on a live session, so it gets a shell that says so. Not a new
                            // session, as a refusal gets: the relay is already running, and this
                            // race is rare enough to leave that pane not surviving a quit.
                            FrameKind::Failure
                                if request.existing_only
                                    && frame.payload.starts_with(b"no session ") =>
                            {
                                drop(_raw);
                                return ended(&request, no_spawn);
                            }
                            FrameKind::Failure => {
                                eprintln!("workroomd: {}", String::from_utf8_lossy(&frame.payload));
                                return ExitCode::FAILURE;
                            }
                            _ => {}
                        }
                    }
                }
                Ok(None) => break,
                Err(_) => return ExitCode::FAILURE,
            }
        }
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(n) => decoder.push(&buffer[..n]),
        }
    }
    // The daemon went away without saying the shell had ended: it handed off to a new program
    // (#230; the exec closes every connection and the session carries on) or it died. On a remote
    // host this status is ssh's, and 255 is what the app reads as a dropped link, which it answers
    // by attaching the pane again as a restored one (`--no-create`, #231): the new program repaints
    // it, the daemon shows the record it kept of a session that ended with its host (#232), or the
    // notice-and-shell says the session has ended. The `Exited` arm above keeps 255 meaning only
    // this, by reporting a shell that itself exited 255 as 254.
    //
    // Locally the app has no such path, and a pane is attached only after the launch's hand-off
    // has been asked for, so this is left as it was: the pane ends as if the shell had.
    if no_spawn {
        ExitCode::from(255)
    } else {
        ExitCode::SUCCESS
    }
}

/// How the daemon answered an attach.
enum Answer {
    Attached,
    /// A `Failure` before `Attached`, with its reason. For a `--no-create` attach the only one is
    /// "session ended".
    Refused(Vec<u8>),
    /// The stream ended before any answer.
    Closed,
}

/// Reads until the daemon answers an attach. Envelopes after `Attached` stay in `decoder`.
fn await_attached(
    stream: &mut std::os::unix::net::UnixStream,
    decoder: &mut EnvelopeDecoder,
    buffer: &mut [u8],
) -> Answer {
    loop {
        while let Ok(Some(envelope)) = decoder.next_envelope() {
            let mut frames = FrameDecoder::new();
            frames.push(&envelope.payload);
            while let Ok(Some(frame)) = frames.next_frame() {
                match frame.kind {
                    FrameKind::Attached => return Answer::Attached,
                    FrameKind::Failure => return Answer::Refused(frame.payload),
                    _ => {}
                }
            }
        }
        match stream.read(buffer) {
            Ok(0) | Err(_) => return Answer::Closed,
            Ok(n) => decoder.push(&buffer[..n]),
        }
    }
}

/// The size of the terminal this process was forked into, or zero when there is none (a pipe, a
/// test harness) so the daemon applies its own default rather than creating a 0x0 pty.
fn terminal_size() -> (u16, u16) {
    // SAFETY: `winsize` is plain old data, for which all zeroes is a valid value.
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    // SAFETY: TIOCGWINSZ writes one `winsize` through the pointer, which is a live local.
    let rc = unsafe { libc::ioctl(libc::STDIN_FILENO, libc::TIOCGWINSZ, &mut size) };
    if rc != 0 {
        return (0, 0);
    }
    (size.ws_col, size.ws_row)
}

/// Watches this relay's terminal for size changes and forwards them.
///
/// Polling rather than a SIGWINCH handler, deliberately. A signal handler may only call
/// async-signal-safe functions, so it could do no more than set a flag that something else polls
/// anyway — and polling `TIOCGWINSZ` is also correct when a signal is missed or coalesced, which
/// happens when several resizes land while the process is busy. A tenth of a second is far below
/// the point a person notices a reflow lagging.
fn relay_resizes(
    mut stream: std::os::unix::net::UnixStream,
    initial_columns: u16,
    initial_rows: u16,
) {
    let (mut columns, mut rows) = (initial_columns, initial_rows);
    loop {
        std::thread::sleep(Duration::from_millis(100));
        let (next_columns, next_rows) = terminal_size();
        // Zero means there is no terminal — a pipe, a test harness. Sending it would reset the
        // session to the daemon's default and reflow everything for no reason.
        if next_columns == 0 || next_rows == 0 {
            continue;
        }
        if (next_columns, next_rows) == (columns, rows) {
            continue;
        }
        columns = next_columns;
        rows = next_rows;

        let mut payload = Vec::with_capacity(4);
        payload.extend_from_slice(&columns.to_be_bytes());
        payload.extend_from_slice(&rows.to_be_bytes());
        let frame = Frame::new(FrameKind::Resize, payload);
        if stream
            .write_all(&Envelope::new(Service::Terminal, 1, frame.encode()).encode())
            .is_err()
        {
            return;
        }
        let _ = stream.flush();
    }
}

/// The attach client's own terminal, in raw mode for the life of the relay.
///
/// A relay has to be transparent in both directions, and the kernel's default line discipline is
/// the opposite of transparent. Without this the client's tty keeps `ECHO`, `ICANON` and `ISIG`,
/// and all three break the pane in ways that look like unrelated bugs:
///
/// - `ECHO` paints every byte the emulator sends back onto the screen as literal text. Those bytes
///   are not typing: they are focus reports (`ESC [ I`), mouse reports, the replies to the DA1 and
///   DECRQM probes a TUI makes at startup, and bracketed-paste markers. The pane fills with
///   `^[[I^[[<35;84;25M…` and the TUI's own probes answer into its input box.
/// - `ICANON` holds input until Return, so a paste never reaches the far side as a paste, and no
///   escape sequence arrives in time to be part of a handshake.
/// - `ISIG` turns `^C` into a `SIGINT` for THIS process instead of a byte for the program on the
///   far end — so Ctrl-C appears to do nothing, having killed the wrong thing.
///
/// `SessionAttachClient.enterRawMode` has done this since the Swift helper shipped; the daemon
/// arrived without it and reached one nightly that way.
///
/// `tcgetattr` failing is the not-a-tty case — a pipe, a test harness — and is deliberately not an
/// error: there is no line discipline in the way, so there is nothing to get out of the way of.
struct RawMode(Option<libc::termios>);

impl RawMode {
    fn enter() -> RawMode {
        // SAFETY: `termios` is plain old data, for which all zeroes is a valid value.
        let mut original: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: tcgetattr fills the live `termios` it is pointed at, or fails without writing.
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
            return RawMode(None);
        }
        let mut raw = original;
        // SAFETY: `raw` is a live `termios`, filled in by tcgetattr above.
        unsafe { libc::cfmakeraw(&mut raw) };
        // SAFETY: tcsetattr only reads the `termios` it is given, which is live.
        if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) } != 0 {
            return RawMode(None);
        }
        RawMode(Some(original))
    }
}

impl Drop for RawMode {
    /// Was briefly split into a separate `restore()` so an `exec` could call it without a
    /// destructor. Nothing execs from inside the relay loop any more — see the `FrameKind::Failure`
    /// arm — so the split was generality for an unreachable state and the two lines live here again.
    fn drop(&mut self) {
        if let Some(original) = self.0.as_ref() {
            // SAFETY: tcsetattr only reads `original`, the settings tcgetattr returned in `enter`.
            unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, original) };
        }
    }
}

fn relay_stdin(mut stream: std::os::unix::net::UnixStream) {
    let mut stdin = std::io::stdin();
    let mut buffer = [0u8; 4096];
    loop {
        match stdin.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let frame = Frame::new(FrameKind::Input, buffer[..n].to_vec());
                if stream
                    .write_all(&Envelope::new(Service::Terminal, 1, frame.encode()).encode())
                    .is_err()
                {
                    break;
                }
                let _ = stream.flush();
            }
        }
    }
}
