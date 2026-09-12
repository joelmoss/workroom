//! `wr-agent serve | attach`, mirroring today's shipped `workroom-session daemon | attach`.
//!
//! That shape is deliberate rather than inherited: `applyPersistentSession` sets libghostty's
//! `config.command` to a command LINE, so libghostty forks a *process* — meaning there has to be
//! a forked relay executable as well as the in-process client. One binary in both roles keeps the
//! frame codec in one language instead of duplicating it forever.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use wr_agent::protocol::envelope::{
    negotiate, Envelope, EnvelopeDecoder, Hello, Service, MIN_SUPPORTED_VERSION, PROTOCOL_VERSION,
};
use wr_agent::protocol::frame::{Frame, FrameDecoder, FrameKind};
use wr_agent::serve::{self, Agent, BUILD, DEFAULT_IDLE_TIMEOUT};

fn usage() -> &'static str {
    "usage:
  wr-agent serve --socket <path> [--idle-timeout <secs>]
        own ptys and services (the daemon role)
  wr-agent serve --stdio
        serve one connection over stdin/stdout; what a driver opens remotely
  wr-agent attach --socket <path> [--session <uuid>]
        relay stdio to a session; what libghostty forks
  wr-agent list --socket <path>
        print the agent's live sessions
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
            println!("protocol {PROTOCOL_VERSION} (minimum supported {MIN_SUPPORTED_VERSION})");
            println!("build {BUILD}");
            ExitCode::SUCCESS
        }
        Some("serve") if args.iter().any(|a| a == "--stdio") => run_serve_stdio(),
        Some("serve") => match flag(&args, "--socket") {
            Some(socket) => run_serve(PathBuf::from(socket), flag(&args, "--idle-timeout")),
            None => {
                eprintln!("error: serve needs --socket <path> or --stdio");
                ExitCode::FAILURE
            }
        },
        Some("attach") => run_attach(&args),
        Some("list") => run_list(&args),
        _ => {
            eprint!("{}", usage());
            ExitCode::FAILURE
        }
    }
}

/// Serves exactly one connection over stdin/stdout, then exits.
///
/// This is the remote entry point: `ssh host wr-agent serve --stdio` is the first implementation
/// of the driver contract's `openStream`, and a provider SDK's exec call produces the same shape.
/// There is no socket, no listener and no single-instance lock, because the caller already decided
/// which machine and which process — the stream IS the session's address.
///
/// Note what this deliberately does NOT do: outlive the connection. A remote agent that must
/// survive a dropped link is a supervised process on the far side owning its own socket; this mode
/// is one client, one stream, which is what an ssh hop gives you.
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

fn run_serve(socket: PathBuf, idle: Option<String>) -> ExitCode {
    // The lock, not the bind, is what guarantees a single agent — see serve.rs. Losing the race is
    // a normal outcome (two clients spawning at once), not an error worth a non-zero exit: the
    // other agent is serving, which is all the caller wanted.
    let _lock = match serve::acquire_instance_lock(&socket) {
        Ok(lock) => lock,
        Err(serve::ServeError::AlreadyRunning(_)) => return ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    let timeout = idle
        .and_then(|s| s.parse::<u64>().ok())
        .map(Duration::from_secs)
        .unwrap_or(DEFAULT_IDLE_TIMEOUT);

    let agent = Agent::new();
    match agent.serve(&socket, timeout) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Exit code the app already knows: `SessionAttachClient.daemonUnavailable`.
const DAEMON_UNAVAILABLE: u8 = 92;

fn run_attach(args: &[String]) -> ExitCode {
    // Flags win, environment is the fallback — and the environment alone has to be enough, because
    // `PersistentSessionService.attachCommand()` builds the command line as `<binary> attach` with
    // no arguments at all. Everything the app wants to say, it says through the variables it
    // already exports.
    if let Some(text) = flag(args, "--session") {
        // Safety: set before any thread is spawned, and only so the shared parser can read it.
        unsafe { std::env::set_var("WORKROOM_SESSION_ID", text) };
    }
    let socket = flag(args, "--socket")
        .map(PathBuf::from)
        .or_else(serve::socket_from_env);
    let Some(socket) = socket else {
        eprintln!("error: attach needs --socket <path> or WORKROOM_SESSION_SOCKET");
        return ExitCode::FAILURE;
    };

    let mut request = serve::AttachRequest::from_env();
    let Some(session) = request.id else {
        eprintln!("error: attach needs --session <uuid> or WORKROOM_SESSION_ID");
        return ExitCode::FAILURE;
    };
    // The pty's initial size comes from the terminal this relay was forked into, so a session is
    // created at the size it will actually be shown at rather than at 80x24 and then resized —
    // which a full-screen program would see as a resize on its first frame.
    let (columns, rows) = terminal_size();
    request.columns = columns;
    request.rows = rows;

    // Spawn-on-connect-failure, exactly as the Swift attach client does: the agent is started by
    // whoever needs it first rather than by an installed service, so there is no install footprint.
    let mut stream = match serve::connect(&socket) {
        Some(stream) => stream,
        None => {
            let binary = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("wr-agent"));
            if serve::spawn_agent(&binary, &socket).is_err() {
                return ExitCode::from(DAEMON_UNAVAILABLE);
            }
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            loop {
                if let Some(stream) = serve::connect(&socket) {
                    break stream;
                }
                if std::time::Instant::now() >= deadline {
                    return ExitCode::from(DAEMON_UNAVAILABLE);
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        }
    };

    if handshake(&mut stream).is_err() {
        return ExitCode::from(DAEMON_UNAVAILABLE);
    }

    let attach = Frame::new(FrameKind::Attach, request.encode());
    let _ = session;
    if stream
        .write_all(&Envelope::new(Service::Terminal, 1, attach.encode()).encode())
        .is_err()
    {
        return ExitCode::from(DAEMON_UNAVAILABLE);
    }

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

    let mut decoder = EnvelopeDecoder::new();
    let mut buffer = [0u8; 8192];
    let mut stdout = std::io::stdout();
    loop {
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(n) => decoder.push(&buffer[..n]),
        }
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
                            FrameKind::Exited => return ExitCode::SUCCESS,
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
    }
    ExitCode::SUCCESS
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

/// Exchange greetings and agree a version before anything else crosses the stream.
fn handshake<S: Read + Write>(stream: &mut S) -> Result<(), ()> {
    let local = Hello::current(BUILD);
    stream.write_all(&local.encode()).map_err(|_| ())?;
    let _ = stream.flush();

    let mut greeting = Vec::new();
    let mut byte = [0u8; 1];
    let remote = loop {
        if let Ok(Some((hello, _))) = Hello::decode(&greeting) {
            break hello;
        }
        match stream.read(&mut byte) {
            Ok(0) | Err(_) => return Err(()),
            Ok(_) => greeting.push(byte[0]),
        }
    };
    negotiate(&local, &remote).map_err(|_| ())?;
    Ok(())
}
