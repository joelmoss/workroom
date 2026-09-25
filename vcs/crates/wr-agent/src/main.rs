//! `wr-agent serve | attach`, mirroring today's shipped `workroom-session daemon | attach`.
//!
//! That shape is deliberate rather than inherited: `applyPersistentSession` sets libghostty's
//! `config.command` to a command LINE, so libghostty forks a *process* — meaning there has to be
//! a forked relay executable as well as the in-process client. One binary in both roles keeps the
//! frame codec in one language instead of duplicating it forever.

use std::io::{Read, Write};
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use wr_agent::handoff;
use wr_agent::protocol::envelope::{
    negotiate, Envelope, EnvelopeDecoder, Hello, Service, MIN_FILE_VERSION, MIN_FORWARD_VERSION,
    MIN_HANDOFF_VERSION, MIN_STATUS_VERSION, MIN_SUPPORTED_VERSION, MIN_VCS_VERSION,
    PROTOCOL_VERSION,
};
use wr_agent::protocol::frame::{Frame, FrameDecoder, FrameKind};
use wr_agent::serve::{self, Agent, BUILD, DEFAULT_IDLE_TIMEOUT};
use wr_agent::wakefulness::Settings;

fn usage() -> &'static str {
    "usage:
  wr-agent serve --socket <path> [--idle-timeout <secs>|never] [--screens <dir>]
        [--awake-ceiling <secs>] [--awake-prompt-timeout <secs>] [--ask-at-awake-ceiling]
        own ptys and services (the daemon role). On Linux it also decides BUSY/IDLE for the
        provider's lifecycle shim and writes it beside the socket as <socket>.wake.
        The awake ceiling is advisory by default: past it a BUSY box is reported, never slept.
        --ask-at-awake-ceiling prompts the app instead, and lets the box sleep if nobody answers.
        Each flag falls back to WORKROOM_SESSION_AWAKE_CEILING,
        WORKROOM_SESSION_AWAKE_PROMPT_TIMEOUT and WORKROOM_SESSION_ASK_AT_AWAKE_CEILING=1, which
        is how the serve that attach spawns gets them. The WORKROOM_SESSION_ prefix is what keeps
        them out of every session's shell, with the rest of the app's launch variables.
        --idle-timeout never is for a supervised remote agent, which must keep running (and keep
        reporting BUSY/IDLE) with no client attached.
        --screens <dir> keeps each session's screen in <dir>, so a pane reattaching after the
        host reboots is shown its last one. <dir> must survive a reboot: not the socket's.
  wr-agent serve --stdio
        serve one connection over stdin/stdout, whose sessions die with it; a transport test
        entry point, not a persistent remote agent (that is serve --idle-timeout never + relay)
  wr-agent attach --socket <path> [--session <uuid>]
        relay stdio to a session; what libghostty forks
  wr-agent relay --socket <path>
        copy bytes between stdio and a running agent's socket, and nothing else;
        what a driver runs on the far side (`ssh host wr-agent relay --socket <path>`)
  wr-agent list --socket <path>
        print the agent's live sessions
  wr-agent hand-off --socket <path> --binary <path> [--force]
        replace the running agent's program with <binary>, keeping every session and its pid.
        Prints `current` when the agent is running that binary already, `handed off` when it was
        replaced. Refused, with the agent left running, when <binary> cannot restore its sessions
        (exit 1) or the agent predates hand-off (exit 3). --force hands off to the same binary.
  wr-agent handoff-check <table>
        whether this build can restore the sessions a hand-off table describes; run by the agent
        handing off, before it replaces itself
  wr-agent protocol
        print the protocol version this build speaks
"
}

fn flag(args: &[String], name: &str) -> Option<String> {
    let index = args.iter().position(|a| a == name)?;
    args.get(index + 1).cloned()
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("protocol") => {
            // The per-service minimums appended at the end, in the order they were introduced —
            // `SessionBackendProbe.parseProtocolVersion` (Swift) is explicitly "tolerant of trailing
            // detail by design", reading only the leading `protocol <n>` token, so this is safe to
            // grow without a matching app release. `AgentVCSProtocolTests` checks every number but
            // `min-handoff` (which only `hand-off` reads) against the shipped binary; keep this
            // line's tokens in this order if it grows again.
            println!(
                "protocol {PROTOCOL_VERSION} (minimum supported {MIN_SUPPORTED_VERSION}) \
                 min-vcs {MIN_VCS_VERSION} min-file {MIN_FILE_VERSION} \
                 min-status {MIN_STATUS_VERSION} min-forward {MIN_FORWARD_VERSION} \
                 min-handoff {MIN_HANDOFF_VERSION}"
            );
            println!("build {BUILD}");
            // Whether this build can repaint a reattaching client. A build without it serves
            // sessions perfectly well and then hands a reconnecting pane a blank screen, which is
            // invisible until someone quits the app and comes back — so it is stated here and
            // asserted against the shipped binary by macapp/Scripts/build-agent_test.sh.
            println!(
                "terminal-state {}",
                if cfg!(feature = "terminal-state") {
                    "yes"
                } else {
                    "no"
                }
            );
            ExitCode::SUCCESS
        }
        Some("serve") if args.iter().any(|a| a == "--stdio") => run_serve_stdio(),
        Some("serve") => match flag(&args, "--socket") {
            Some(socket) => run_serve(
                PathBuf::from(socket),
                flag(&args, "--idle-timeout"),
                wakefulness_settings(&args),
                flag(&args, "--handoff").map(PathBuf::from),
                flag(&args, "--screens").map(PathBuf::from),
            ),
            None => {
                eprintln!("error: serve needs --socket <path> or --stdio");
                ExitCode::FAILURE
            }
        },
        Some("attach") => run_attach(&args),
        Some("relay") => run_relay(&args),
        Some("list") => run_list(&args),
        Some("hand-off") => run_hand_off(&args),
        Some("handoff-check") => match args.get(1) {
            Some(table) => match wr_agent::handoff::check_table(std::path::Path::new(table)) {
                Ok(count) => {
                    println!("ok {count}");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    ExitCode::FAILURE
                }
            },
            None => {
                eprintln!("error: handoff-check needs <table>");
                ExitCode::FAILURE
            }
        },
        _ => {
            eprint!("{}", usage());
            ExitCode::FAILURE
        }
    }
}

/// Serves exactly one connection over stdin/stdout, then exits.
///
/// A transport test entry point: `ssh host wr-agent serve --stdio` has the shape of the driver
/// contract's `openStream`, and so does a provider SDK's exec call. There is no socket, no listener
/// and no single-instance lock, because the caller already decided which machine and which
/// process — the stream IS the session's address.
///
/// Note what this deliberately does NOT do: outlive the connection. Production reaches a supervised
/// `serve --idle-timeout never` through `relay` instead (see `run_relay`), because a remote session
/// must survive a dropped link and these die with it.
fn run_serve_stdio() -> ExitCode {
    let sessions = wr_agent::session::SessionStore::new();
    match wr_agent::serve::handle_connection(wr_agent::transport::StdioTransport, sessions.clone())
    {
        Ok(()) => {
            // Nothing else can reach these sessions: the stream was their only route in.
            sessions.kill_all();
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("error: {e}");
            sessions.kill_all();
            ExitCode::FAILURE
        }
    }
}

/// The awake ceiling's settings (OQ22). Flags first; then the environment, because `attach`
/// self-spawns `serve` with no flags (`serve::spawn_agent`) and the app controls that path only
/// through the environment it launches `attach` with.
fn wakefulness_settings(args: &[String]) -> Settings {
    wakefulness_settings_from(args, |name| std::env::var(name).ok())
}

/// Under `WORKROOM_SESSION_` on purpose: `spawn_session` scrubs that prefix from the child's
/// environment, so the settings reach the self-spawned `serve` and never the user's shell.
const ENV_AWAKE_CEILING: &str = "WORKROOM_SESSION_AWAKE_CEILING";
const ENV_AWAKE_PROMPT_TIMEOUT: &str = "WORKROOM_SESSION_AWAKE_PROMPT_TIMEOUT";
const ENV_ASK_AT_AWAKE_CEILING: &str = "WORKROOM_SESSION_ASK_AT_AWAKE_CEILING";

fn wakefulness_settings_from(args: &[String], env: impl Fn(&str) -> Option<String>) -> Settings {
    // Finite and positive, or the default. `f64::parse` accepts "nan", "inf" and "-1", and each
    // one breaks the ceiling a different way: NaN trips it on the first BUSY tick (every comparison
    // is false), infinity never trips it, and a non-positive prompt timeout expires the prompt on
    // the next tick and lets the box sleep with no grace at all.
    let seconds = |name: &str, var: &str| {
        flag(args, name)
            .or_else(|| env(var))
            .and_then(|s| s.parse::<f64>().ok())
            .filter(|v| v.is_finite() && *v > 0.0)
    };
    let defaults = Settings::default();
    Settings {
        ceiling: seconds("--awake-ceiling", ENV_AWAKE_CEILING).unwrap_or(defaults.ceiling),
        prompt_timeout: seconds("--awake-prompt-timeout", ENV_AWAKE_PROMPT_TIMEOUT)
            .unwrap_or(defaults.prompt_timeout),
        ask: args.iter().any(|a| a == "--ask-at-awake-ceiling")
            || env(ENV_ASK_AT_AWAKE_CEILING).is_some_and(|v| v == "1" || v == "true"),
    }
}

fn run_serve(
    socket: PathBuf,
    idle: Option<String>,
    wakefulness: Settings,
    handoff: Option<PathBuf>,
    screens: Option<PathBuf>,
) -> ExitCode {
    let timeout = match idle_timeout(idle.as_deref()) {
        Ok(timeout) => timeout,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    // First, before an update can replace the file at this path: see `handoff::Context::digest`.
    let digest = handoff::own_binary()
        .and_then(|path| handoff::digest(&path))
        .ok();
    let agent = Agent::new();
    let (lock, listener) = match handoff {
        Some(table) => match adopt(&agent, &table) {
            Ok(carried) => carried,
            Err(e) => {
                eprintln!("error: {e}");
                return ExitCode::FAILURE;
            }
        },
        None => {
            // The lock, not the bind, is what guarantees a single agent — see serve.rs. Losing the
            // race is a normal outcome (two clients spawning at once), not an error worth a
            // non-zero exit: the other agent is serving, which is all the caller wanted.
            let lock = match serve::acquire_instance_lock(&socket) {
                Ok(lock) => lock,
                Err(serve::ServeError::AlreadyRunning(_)) => return ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("error: {e}");
                    return ExitCode::FAILURE;
                }
            };
            // A table left by a program that died before it could read one (see `handoff`)
            // holds the screens of sessions that are gone.
            let _ = std::fs::remove_file(handoff::table_path(&socket));
            match serve::bind(&socket) {
                Ok(listener) => (lock, listener),
                Err(e) => {
                    eprintln!("error: {e}");
                    return ExitCode::FAILURE;
                }
            }
        }
    };
    // A directory that cannot be used costs the records, never the agent: a supervisor with a bad
    // path must still get terminals. The flag is in `arguments` below, so a hand-off keeps it.
    if let Some(dir) = screens {
        match wr_agent::screens::Screens::open(&dir) {
            Ok(screens) => {
                agent.sessions.keep_screens(screens);
                wr_agent::screens::spawn(agent.sessions.clone());
            }
            Err(e) => eprintln!(
                "wr-agent: not keeping screens in {}: {e}",
                dir.to_string_lossy()
            ),
        }
    }
    handoff::install(handoff::Context {
        socket: socket.clone(),
        listener: listener.as_raw_fd(),
        lock: lock.fd(),
        digest,
        arguments: std::env::args_os().skip(1).collect(),
    });
    match agent.run(listener, &socket, timeout, wakefulness) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Takes over what the program a hand-off replaced was holding: its lock, its listening socket
/// and its sessions (`wr_agent::handoff`). A session that cannot be adopted is reported and
/// dropped, which closes its pty and hangs up its shell; the rest carry on.
fn adopt(
    agent: &Agent,
    table: &std::path::Path,
) -> Result<(serve::InstanceLock, UnixListener), String> {
    let table = handoff::take_table(table)?;
    // SAFETY: the table names descriptors the outgoing program carried across the exec for this
    // and nothing else, and nothing in this process has touched them.
    let lock = unsafe { serve::InstanceLock::adopt(table.lock) };
    let listener = unsafe { UnixListener::from_raw_fd(table.listener) };
    handoff::set_cloexec(table.listener, true);
    for session in table.sessions {
        let pty = wr_agent::pty::Pty::adopt(session.master, session.pid);
        if let Err(e) = agent.sessions.adopt(
            session.id,
            pty,
            session.columns,
            session.rows,
            &session.screen,
        ) {
            eprintln!("error: session {}: {e}", session.id.to_hyphenated());
        }
    }
    Ok((lock, listener))
}

/// `--idle-timeout`: seconds, or `never` for a supervised remote agent (issue #228).
///
/// A value that does not parse is an error, not the default. A supervisor that asked for `never`
/// and got 30 seconds would see its agent exit 30 seconds after the last client left, which looks
/// like a crash and takes the no-client busy/idle reports with it.
fn idle_timeout(value: Option<&str>) -> Result<Duration, String> {
    match value {
        None => Ok(DEFAULT_IDLE_TIMEOUT),
        // `serve` compares elapsed idle time with `>=`, and no elapsed time reaches this.
        Some("never") => Ok(Duration::MAX),
        Some(text) => text
            .parse::<u64>()
            .map(Duration::from_secs)
            .map_err(|_| format!("--idle-timeout takes seconds or `never`, not {text:?}")),
    }
}

/// Copies bytes between stdin/stdout and a running agent's socket, and does nothing else.
///
/// This is the far side of a persistent remote stream: `ssh host wr-agent relay --socket <path>`
/// is the ssh implementation of the driver contract's byte stream, and the agent behind the socket
/// is a supervised `serve --idle-timeout never` that owns the ptys. A dropped link ends this
/// process and only this process, so the sessions survive and the next relay reaches the same
/// owner. `serve --stdio` cannot do that: its session store dies with its stream.
///
/// **It never starts an agent**, unlike `attach`. On the far side, starting the agent is the
/// supervisor's job, and a relay that spawned one would bring back the idle-exit agent a remote
/// host must not have. So no agent means a fast failure the driver can report.
///
/// **It never writes a byte of its own to stdout.** The client handshakes with the agent THROUGH
/// this process, and anything else on the stream is a banner the handshake rejects.
fn run_relay(args: &[String]) -> ExitCode {
    let Some(socket) = flag(args, "--socket").map(PathBuf::from) else {
        eprintln!("error: relay needs --socket <path>");
        return ExitCode::FAILURE;
    };
    let Some(stream) = serve::connect(&socket) else {
        eprintln!(
            "error: no agent listening on {}; on a remote host, its supervisor starts it",
            socket.display()
        );
        return ExitCode::from(DAEMON_UNAVAILABLE);
    };

    // stdin -> agent. EOF is a half-close: the client has nothing more to send, and it is also how
    // sshd reports a dead link. Shutting down the write half tells the agent, which detaches this
    // client's sessions, and still lets its last replies through below.
    let mut to_agent = match stream.try_clone() {
        Ok(clone) => clone,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    std::thread::spawn(move || {
        let _ = std::io::copy(&mut wr_agent::transport::FdStream::stdin(), &mut to_agent);
        let _ = to_agent.shutdown(std::net::Shutdown::Write);
    });

    // agent -> stdout, unbuffered: `Stdout` is line-buffered, and would hold a frame with no newline
    // in it until the next one pushed it out. Bounded like `serve --stdio`'s writer to the same
    // stdout, so a dead link with output queued for it ends this process `WRITE_TIMEOUT` after its
    // buffers fill. A dead link with nothing to send is not noticed here at all: no process on this
    // end can tell it from a quiet one. The relay then lives until sshd closes the channel (its
    // keepalives, or TCP's), which costs an idle process and an agent connection, never a
    // session: sessions take more than one client, so the next relay attaches as usual.
    //
    // A poll loop rather than `io::copy`, because the copy can only notice a dead link by WRITING to
    // it. An agent that has gone quiet (and stopped reading, so the thread above is stuck mid-write
    // and never sees stdin's EOF either) would leave this process blocked on the socket forever.
    // Watching stdout for a hang-up ends it the moment sshd closes the channel. That is Linux, where
    // a pipe whose readers are gone reports POLLERR; macOS's poll does not report it for a pipe,
    // and there the relay falls back to noticing on its next write.
    let mut to_client = wr_agent::transport::FdStream::writer(libc::STDOUT_FILENO);
    let mut from_agent = &stream;
    let mut buffer = vec![0u8; 65536];
    let mut watched = [
        libc::pollfd {
            fd: stream.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        },
        // No events requested: POLLERR and POLLHUP are always reported, and they are the only
        // thing this entry is for.
        libc::pollfd {
            fd: libc::STDOUT_FILENO,
            events: 0,
            revents: 0,
        },
    ];
    loop {
        if unsafe { libc::poll(watched.as_mut_ptr(), 2, -1) } < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
        // POLLNVAL too: a stdout that was never open would otherwise make every poll return at
        // once with nothing to read, and this loop would spin.
        if watched[1].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            break;
        }
        if watched[0].revents == 0 {
            continue;
        }
        match from_agent.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            // Rust ignores SIGPIPE, so a closed link arrives here as an error too.
            Ok(n) => {
                if to_client.write_all(&buffer[..n]).is_err() {
                    break;
                }
            }
        }
    }
    ExitCode::SUCCESS
}

/// Exit code the app already knows: `SessionAttachClient.daemonUnavailable`.
const DAEMON_UNAVAILABLE: u8 = 92;

/// Become an ordinary shell, because this relay could not deliver a persistent session.
///
/// **Why the relay and not the app.** The app decides whether a pane gets a session before it
/// forks anything: `applyPersistentSession` either hands libghostty `wr-agent attach` as its
/// `config.command` or lets it open a plain shell, and by the time this process exists that choice
/// is spent. `config.wait_after_command` is false, so a relay that exits leaves a dead pane — no
/// shell, no prompt, nothing the user can type into. The only place left that can still turn a
/// failed attach into a working terminal is this process, by replacing itself with the shell the
/// pane would have run anyway.
///
/// The app's own health check cannot prevent this. `SessionBackendProbe` runs `wr-agent protocol`
/// and parses a version; an agent that answers that and then fails to serve — a stale socket it
/// cannot bind, a version it cannot negotiate, a crash between the two — passes the probe and dies
/// here. "A broken agent still leaves you a working terminal" is only true if this function exists.
///
/// **Persistence is lost, and that is said out loud.** The notice goes to stderr, which is the pane,
/// because a terminal that silently stopped surviving quit is worse than one that says so: the user
/// would find out by losing work. It is one line, printed once.
///
/// Never returns on success — `exec` replaces this process, so the shell inherits the pty, the
/// window title, the exit status, everything. Returns only when `exec` itself fails.
fn fall_back_to_shell(request: &serve::AttachRequest, reason: &str) -> ExitCode {
    use std::os::unix::process::CommandExt;

    let text = |value: &Option<std::ffi::OsString>| {
        value
            .as_ref()
            .map(|v| v.to_string_lossy().into_owned())
            .unwrap_or_default()
    };

    // The SAME invocation the agent would have exec'd in the pty, not a hand-rolled one.
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
    // agent's own pty spawn uses `execve` and does not search (`pty.rs`). Two paths documented as
    // running "the SAME invocation" must not disagree about what a shell path means, so a
    // slash-less value is treated as unusable rather than resolved differently here.
    let requested_shell = text(&request.shell);
    let shell = if requested_shell.contains('/') {
        requested_shell
    } else {
        wr_agent::shell::DEFAULT_SHELL.to_string()
    };

    let invocation = wr_agent::shell::invocation(
        &text(&request.command),
        &shell,
        &text(&request.resources),
        &environment,
    );

    eprintln!("wr-agent: {reason}; this terminal will not survive quitting Workroom\r");

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
    // fallback chain the agent's own child uses (`pty.rs`: requested, then `$HOME`, then `/`).
    for directory in candidate_directories(request.cwd.as_ref()) {
        command.current_dir(&directory);
        let error = command.exec();
        // Reached only when exec failed. If the working directory is why, the next candidate may
        // work; if it is the shell itself, every candidate fails the same way and the loop ends.
        if error.kind() != std::io::ErrorKind::NotFound
            && error.kind() != std::io::ErrorKind::PermissionDenied
        {
            eprintln!(
                "wr-agent: could not start {}: {error}\r",
                invocation.program.to_string_lossy()
            );
            return ExitCode::from(DAEMON_UNAVAILABLE);
        }
    }
    eprintln!(
        "wr-agent: could not start {} in any working directory\r",
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

fn run_attach(args: &[String]) -> ExitCode {
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
    // `--no-spawn`: never start an agent. On a remote host that is the supervisor's job, and an
    // agent started here would be the idle-exit kind a remote host must not have, racing the
    // supervised one for the socket (#228). It also changes what a lost agent connection means:
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

    // Spawn-on-connect-failure: the agent is started by whoever needs it first rather than by an
    // installed service, so there is no install footprint. (The Swift attach client used to do the
    // same; it no longer can — its `daemon` subcommand went with the daemon.)
    //
    // Every failure from here to the attach reply becomes a plain shell rather than a dead pane —
    // see `fall_back_to_shell`. These are precisely the states an agent that PASSED the app's
    // `wr-agent protocol` probe can still reach. The exception is a restored pane on a remote host,
    // which exits 255 for the app to attach again instead (`unreachable`, below).
    // None of these is retried here: an agent greets the moment it accepts, and stops accepting
    // while it hands off, so a failed greeting is a peer that is not a working agent.
    let open = || -> Result<std::os::unix::net::UnixStream, &str> {
        let mut stream = match serve::connect(&socket) {
            Some(stream) => stream,
            None if no_spawn => {
                return Err(
                    "no session agent is listening, and on a remote host only its supervisor starts one",
                );
            }
            None => {
                let binary = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("wr-agent"));
                if serve::spawn_agent(&binary, &socket).is_err() {
                    return Err("could not start the session agent");
                }
                let deadline = std::time::Instant::now() + Duration::from_secs(5);
                loop {
                    if let Some(stream) = serve::connect(&socket) {
                        break stream;
                    }
                    if std::time::Instant::now() >= deadline {
                        return Err("the session agent did not start within 5s");
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
        };
        if handshake(&mut stream).is_err() {
            return Err("could not agree a protocol with the session agent");
        }
        Ok(stream)
    };
    let _ = session;
    // A restored pane on a remote host whose agent is not answering exits 255, which the app
    // answers by attaching again with a backoff. After a reboot sshd can accept before the
    // supervisor's agent has bound its socket, and a shell here would be a live one in a pane whose
    // session is gone, so its last screen would never be shown (#232). A new remote pane still gets
    // the shell (#229): it has no session to wait for.
    let unreachable = |reason: &str| -> ExitCode {
        if no_spawn && request.existing_only {
            eprintln!("wr-agent: {reason}\r");
            ExitCode::from(255)
        } else {
            fall_back_to_shell(&request, reason)
        }
    };
    let attach = Frame::new(FrameKind::Attach, request.encode());
    let attach = Envelope::new(Service::Terminal, 1, attach.encode()).encode();

    let mut buffer = [0u8; 8192];

    // The attach is answered before raw mode and the relay threads. A restored pane's
    // (`--no-create`) session that ended becomes the notice-and-shell the app shows locally, and
    // that has to start from a cooked terminal with nothing else running.
    //
    // An agent that closes before answering at all is most likely handing off to a new program
    // (`wr_agent::handoff`). Its listener stays open across the exec, so the attach is sent again,
    // and the program that answers next attaches it, or creates it if it never existed. Only a
    // close with no answer is retried, for up to 10s; a peer that stays open and silent is waited
    // on, as an attach always has been. Whatever follows `Attached` stays in `decoder`.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let (mut stream, mut decoder) = loop {
        let mut stream = match open() {
            Ok(stream) => stream,
            Err(reason) => return unreachable(reason),
        };
        let mut decoder = EnvelopeDecoder::new();
        let answer = match stream.write_all(&attach) {
            Ok(()) => await_attached(&mut stream, &mut decoder, &mut buffer),
            Err(_) => Answer::Closed,
        };
        match answer {
            Answer::Attached => break (stream, decoder),
            Answer::Refused(_) if request.existing_only => {
                return fall_back_to_shell(
                    &request,
                    "the terminal that was running here has ended, so this is a new shell",
                );
            }
            // A session that could not be created or attached. See the main loop's `Failure` arm
            // for why this is an error and not a shell.
            Answer::Refused(reason) => {
                eprintln!("wr-agent: {}", String::from_utf8_lossy(&reason));
                return ExitCode::FAILURE;
            }
            Answer::Closed if std::time::Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(100));
            }
            Answer::Closed => {
                return unreachable("the session agent closed before accepting the attach");
            }
        }
    };

    // Before anything reads stdin: a relay that leaves its own tty cooked is not a relay. Held to
    // the end of this function so every `return` below restores the terminal.
    let _raw = RawMode::enter();

    // stdin -> agent on its own thread; agent -> stdout on this one.
    let input_stream = match stream.try_clone() {
        Ok(clone) => clone,
        Err(_) => return ExitCode::from(DAEMON_UNAVAILABLE),
    };
    std::thread::spawn(move || relay_stdin(input_stream));

    // And a third watching the terminal's size. Without this the session is stuck at whatever
    // size it was created with: the agent accepts Resize frames but nothing ever sent one, so
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
                            // A `Failure` here does not mean the agent is broken — it is talking,
                            // and the session it is talking about is usually ALIVE. `RepaintFailed`
                            // (session.rs) says so outright: "the client could not take its repaint
                            // whole, so it was not attached at all… can retry from a clean
                            // terminal", and it only fires on reattach to a session that already
                            // has scrollback — precisely the pane with the user's work in it. A
                            // fatal pty read reports the same kind for an already-attached client.
                            //
                            // Exec'ing a shell on either is unrecoverable (exec is one-way, so the
                            // retry the agent is inviting can never happen) and, worse, it hands
                            // back a healthy-looking prompt for a session that is still running.
                            // That is the exact failure `confirmBeforeAttach` exists to prevent on
                            // the app side: the one that looks like success. A visible error and a
                            // non-zero exit is the honest answer, and it leaves the session where
                            // the user can still reach it from the detached-sessions list.
                            // The one exception: a `--no-create` attach whose session exited
                            // between the agent's check and its attach. That is "ended", not a
                            // failure on a live session, so it gets the same shell as a check that
                            // came back negative.
                            FrameKind::Failure
                                if request.existing_only
                                    && frame.payload.starts_with(b"no session ") =>
                            {
                                drop(_raw);
                                return fall_back_to_shell(
                                    &request,
                                    "the terminal that was running here has ended, so this is a new shell",
                                );
                            }
                            FrameKind::Failure => {
                                eprintln!("wr-agent: {}", String::from_utf8_lossy(&frame.payload));
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
    // The agent went away without saying the shell had ended: it handed off to a new program
    // (#230; the exec closes every connection and the session carries on) or it died. On a remote
    // host this status is ssh's, and 255 is what the app reads as a dropped link, which it answers
    // by attaching the pane again as a restored one (`--no-create`, #231): the new program repaints
    // it, or the notice-and-shell says the session has ended. The `Exited` arm above keeps 255
    // meaning only this, by reporting a shell that itself exited 255 as 254.
    //
    // Locally the app has no such path, and a pane is attached only after the launch's hand-off
    // has been asked for, so this is left as it was: the pane ends as if the shell had.
    if no_spawn {
        ExitCode::from(255)
    } else {
        ExitCode::SUCCESS
    }
}

/// How the agent answered an attach.
enum Answer {
    Attached,
    /// A `Failure` before `Attached`, with its reason. For a `--no-create` attach the only one is
    /// "session ended".
    Refused(Vec<u8>),
    /// The stream ended before any answer.
    Closed,
}

/// Reads until the agent answers an attach. Envelopes after `Attached` stay in `decoder`.
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
/// test harness) so the agent applies its own default rather than creating a 0x0 pty.
fn terminal_size() -> (u16, u16) {
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
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
        // session to the agent's default and reflow everything for no reason.
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
/// `SessionAttachClient.enterRawMode` has done this since the Swift daemon shipped; the agent
/// arrived without it and reached one nightly that way.
///
/// `tcgetattr` failing is the not-a-tty case — a pipe, a test harness — and is deliberately not an
/// error: there is no line discipline in the way, so there is nothing to get out of the way of.
struct RawMode(Option<libc::termios>);

impl RawMode {
    fn enter() -> RawMode {
        let mut original: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
            return RawMode(None);
        }
        let mut raw = original;
        unsafe { libc::cfmakeraw(&mut raw) };
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

fn run_list(args: &[String]) -> ExitCode {
    let Some(socket) = flag(args, "--socket").map(PathBuf::from) else {
        eprintln!("error: list needs --socket <path>");
        return ExitCode::FAILURE;
    };
    let Some(mut stream) = serve::connect(&socket) else {
        eprintln!("error: no agent listening on {}", socket.display());
        return ExitCode::from(DAEMON_UNAVAILABLE);
    };
    // No fallback here, deliberately: `list` is a diagnostic command run by a person at a prompt,
    // not a relay libghostty forked into a pane. Exec'ing a shell would be absurd; an exit code is
    // exactly what the caller wants.
    if handshake(&mut stream).is_err() {
        return ExitCode::from(DAEMON_UNAVAILABLE);
    }
    let request = Frame::control(FrameKind::List);
    if stream
        .write_all(&Envelope::new(Service::Control, 0, request.encode()).encode())
        .is_err()
    {
        return ExitCode::FAILURE;
    }

    let mut decoder = EnvelopeDecoder::new();
    let mut buffer = [0u8; 8192];
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while std::time::Instant::now() < deadline {
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(n) => decoder.push(&buffer[..n]),
        }
        while let Ok(Some(envelope)) = decoder.next_envelope() {
            let mut frames = FrameDecoder::new();
            frames.push(&envelope.payload);
            while let Ok(Some(frame)) = frames.next_frame() {
                if frame.kind == FrameKind::Sessions {
                    for (id, attached, command) in serve::decode_descriptor_list(&frame.payload) {
                        println!(
                            "{id} {} {command}",
                            if attached { "attached" } else { "detached" }
                        );
                    }
                    return ExitCode::SUCCESS;
                }
            }
        }
    }
    ExitCode::SUCCESS
}

/// `hand-off`'s exit status when the agent was never asked, because it predates the request. It
/// keeps running, and a client talks to it over the versioned envelope.
const PREDATES_HAND_OFF: u8 = 3;

fn run_hand_off(args: &[String]) -> ExitCode {
    let (Some(socket), Some(binary)) = (
        flag(args, "--socket").map(PathBuf::from),
        flag(args, "--binary").map(PathBuf::from),
    ) else {
        eprintln!("error: hand-off needs --socket <path> and --binary <path>");
        return ExitCode::FAILURE;
    };
    let Some(mut stream) = serve::connect(&socket) else {
        eprintln!("error: no agent listening on {}", socket.display());
        return ExitCode::from(DAEMON_UNAVAILABLE);
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let Ok(version) = handshake(&mut stream) else {
        return ExitCode::from(DAEMON_UNAVAILABLE);
    };
    if version < MIN_HANDOFF_VERSION {
        eprintln!("the agent predates hand-off (protocol {version}), so it keeps running");
        return ExitCode::from(PREDATES_HAND_OFF);
    }
    let mut payload = vec![u8::from(args.iter().any(|a| a == "--force"))];
    payload.extend_from_slice(std::os::unix::ffi::OsStrExt::as_bytes(binary.as_os_str()));
    let request = Frame::new(FrameKind::HandOff, payload);
    if stream
        .write_all(&Envelope::new(Service::Control, 0, request.encode()).encode())
        .is_err()
    {
        return ExitCode::FAILURE;
    }
    // Longer than `list`: the agent answers once the new binary has checked every session, and it
    // may first wait out a running repository command (`handoff::QUIET_TIMEOUT`).
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let mut decoder = EnvelopeDecoder::new();
    let mut buffer = [0u8; 8192];
    let mut handing_off = false;
    loop {
        while let Ok(Some(envelope)) = decoder.next_envelope() {
            let mut frames = FrameDecoder::new();
            frames.push(&envelope.payload);
            while let Ok(Some(frame)) = frames.next_frame() {
                match frame.kind {
                    FrameKind::Acknowledged if frame.payload == b"current" => {
                        println!("current");
                        return ExitCode::SUCCESS;
                    }
                    FrameKind::Acknowledged => handing_off = true,
                    FrameKind::Failure => {
                        eprintln!("error: {}", String::from_utf8_lossy(&frame.payload));
                        return ExitCode::FAILURE;
                    }
                    _ => {}
                }
            }
        }
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(n) => decoder.push(&buffer[..n]),
        }
    }
    if !handing_off {
        eprintln!("error: the agent closed without answering");
        return ExitCode::FAILURE;
    }
    // The exec closed that connection. The socket was never unbound, so this connects at once and
    // the new program greets it as soon as it has adopted every session.
    let answered = serve::connect(&socket).is_some_and(|mut stream| {
        let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
        handshake(&mut stream).is_ok()
    });
    if !answered {
        eprintln!("error: the new agent did not answer, so its sessions may be lost");
        return ExitCode::FAILURE;
    }
    println!("handed off");
    ExitCode::SUCCESS
}

/// Exchange greetings and agree a version before anything else crosses the stream. Returns the
/// peer's own version, which a version-gated request is checked against (never the negotiated one).
fn handshake<S: Read + Write>(stream: &mut S) -> Result<u16, ()> {
    let local = Hello::current(BUILD);
    stream.write_all(&local.encode()).map_err(|_| ())?;
    let _ = stream.flush();

    let mut greeting = Vec::new();
    let mut byte = [0u8; 1];
    let remote = loop {
        // `Err` is a DECISION, not a "keep reading". `Hello::decode` reports `NotAnAgent` on the
        // first byte that cannot be the magic — that early rejection is the whole reason the magic
        // exists, and its own doc says so: "otherwise an ssh banner stalls the connection instead
        // of reporting it".
        //
        // Swallowing it with `if let Ok(Some(..))` did exactly what the magic was added to prevent:
        // a peer that is not an agent looped forever, one byte per iteration, appending each to
        // `greeting` without bound. An MOTD or an ssh warning on the stream hung the relay instead
        // of failing to `DAEMON_UNAVAILABLE` — and `serve --stdio` over ssh is the stated remote
        // path, so a banner is expected input rather than a hostile one. `serve.rs` propagates the
        // same error with `?`; this side now agrees with it.
        match Hello::decode(&greeting) {
            Ok(Some((hello, _))) => break hello,
            Err(_) => return Err(()),
            Ok(None) => {}
        }
        match stream.read(&mut byte) {
            Ok(0) | Err(_) => return Err(()),
            Ok(_) => greeting.push(byte[0]),
        }
    };
    negotiate(&local, &remote).map_err(|_| ())?;
    Ok(remote.protocol_version)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A flag wins over the environment; the environment wins over the default; the self-spawned
    /// `serve` (no flags) still gets the app's settings.
    #[test]
    fn wakefulness_settings_fall_back_to_the_environment() {
        let env = |name: &str| match name {
            ENV_AWAKE_CEILING => Some("7200".to_string()),
            ENV_AWAKE_PROMPT_TIMEOUT => Some("bogus".to_string()),
            ENV_ASK_AT_AWAKE_CEILING => Some("1".to_string()),
            _ => None,
        };
        let none = |_: &str| None;
        let defaults = Settings::default();

        let from_env = wakefulness_settings_from(&[], env);
        assert_eq!(from_env.ceiling, 7200.0);
        assert_eq!(
            from_env.prompt_timeout, defaults.prompt_timeout,
            "unparsable env = default"
        );
        assert!(from_env.ask);

        let args: Vec<String> = ["--awake-ceiling", "60"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let flag_wins = wakefulness_settings_from(&args, env);
        assert_eq!(flag_wins.ceiling, 60.0);
        assert!(
            flag_wins.ask,
            "ask has no negative flag; the environment still enables it"
        );

        let bare = wakefulness_settings_from(&[], none);
        assert_eq!(bare.ceiling, defaults.ceiling);
        assert!(!bare.ask);
    }

    /// Values that parse but cannot run a ceiling fall back to the default rather than trip it on
    /// the first tick (NaN, zero, negative), never trip it (infinity), or void the prompt's grace.
    #[test]
    fn wakefulness_settings_reject_values_that_parse_but_cannot_work() {
        let defaults = Settings::default();
        for bad in ["nan", "inf", "-inf", "0", "-5", "1e400"] {
            let args: Vec<String> = ["--awake-ceiling", bad, "--awake-prompt-timeout", bad]
                .iter()
                .map(|s| s.to_string())
                .collect();
            let settings = wakefulness_settings_from(&args, |_| None);
            assert_eq!(settings.ceiling, defaults.ceiling, "ceiling {bad:?}");
            assert_eq!(
                settings.prompt_timeout, defaults.prompt_timeout,
                "prompt timeout {bad:?}"
            );
        }
        let args: Vec<String> = ["--awake-ceiling", "0.5"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(wakefulness_settings_from(&args, |_| None).ceiling, 0.5);
    }

    #[test]
    fn idle_timeout_takes_seconds_or_never_and_rejects_anything_else() {
        assert_eq!(idle_timeout(None), Ok(DEFAULT_IDLE_TIMEOUT));
        assert_eq!(idle_timeout(Some("60")), Ok(Duration::from_secs(60)));
        assert_eq!(idle_timeout(Some("never")), Ok(Duration::MAX));
        for bad in ["", "-1", "1.5", "Never", "forever"] {
            assert!(idle_timeout(Some(bad)).is_err(), "{bad:?}");
        }
    }

    /// A stream that serves an endless login banner, counting how much of it is consumed.
    ///
    /// The byte cap is what keeps a regression a FAILURE rather than a hung suite: without it a
    /// handshake that never gives up would read forever. With it, both the fixed and the broken
    /// version end in `Err` — so the discriminating assertion is the COUNT, not the result.
    struct Banner {
        served: usize,
        cap: usize,
    }

    impl Read for Banner {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            if self.served >= self.cap {
                return Ok(0);
            }
            const TEXT: &[u8] = b"Welcome to Ubuntu 24.04.1 LTS (GNU/Linux)\r\n";
            buffer[0] = TEXT[self.served % TEXT.len()];
            self.served += 1;
            Ok(1)
        }
    }

    impl Write for Banner {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// A peer that is not an agent must be rejected on the first byte that cannot be the magic.
    ///
    /// `serve --stdio` over ssh is the stated remote path, so an MOTD or an ssh warning on the
    /// stream is expected input, not a hostile one. `Hello::decode` reports `NotAnAgent`
    /// immediately for exactly this reason; the relay used to discard that error and loop one byte
    /// at a time, appending each to an unbounded buffer, so the banner hung the client instead of
    /// failing it.
    #[test]
    fn a_login_banner_is_rejected_without_reading_it_all() {
        let mut banner = Banner {
            served: 0,
            cap: 64 * 1024,
        };

        assert!(handshake(&mut banner).is_err(), "a banner is not an agent");
        assert!(
            banner.served <= 8,
            "consumed {} bytes of the banner before giving up — the decode error is being \
             swallowed and the loop is reading to EOF",
            banner.served
        );
    }

    /// The control: a real agent greeting still completes, so the rejection above is not simply
    /// "this handshake never succeeds".
    #[test]
    fn a_real_agent_greeting_still_handshakes() {
        struct Peer {
            greeting: Vec<u8>,
            offset: usize,
        }
        impl Read for Peer {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                if self.offset >= self.greeting.len() {
                    return Ok(0);
                }
                buffer[0] = self.greeting[self.offset];
                self.offset += 1;
                Ok(1)
            }
        }
        impl Write for Peer {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }

        let mut peer = Peer {
            greeting: Hello::current("test").encode(),
            offset: 0,
        };
        assert!(handshake(&mut peer).is_ok());
    }
}
