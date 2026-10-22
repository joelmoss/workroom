//! `workroomd relay`: bytes between stdin/stdout and a running daemon's socket.
use std::io::{Read, Write};
use std::os::unix::io::AsRawFd;
use std::path::PathBuf;
use std::process::ExitCode;

use super::{DAEMON_UNAVAILABLE, flag};
use crate::serve;

/// Copies bytes between stdin/stdout and a running daemon's socket, and does nothing else.
///
/// This is the far side of a persistent remote stream: `ssh host workroomd relay --socket <path>`
/// is the ssh implementation of the driver contract's byte stream, and the daemon behind the socket
/// is a supervised `serve --idle-timeout never` that owns the ptys. A dropped link ends this
/// process and only this process, so the sessions survive and the next relay reaches the same
/// owner. `serve --stdio` cannot do that: its session store dies with its stream.
///
/// **It never starts a daemon**, unlike `attach`. On the far side, starting the daemon is the
/// supervisor's job, and a relay that spawned one would bring back the idle-exit daemon a remote
/// host must not have. So no daemon means a fast failure the driver can report.
///
/// **It never writes a byte of its own to stdout.** The client handshakes with the daemon THROUGH
/// this process, and anything else on the stream is a banner the handshake rejects.
pub fn run_relay(args: &[String]) -> ExitCode {
    let Some(socket) = flag(args, "--socket").map(PathBuf::from) else {
        eprintln!("error: relay needs --socket <path>");
        return ExitCode::FAILURE;
    };
    let Some(stream) = serve::connect(&socket) else {
        eprintln!(
            "error: no daemon listening on {}; on a remote host, its supervisor starts it",
            socket.display()
        );
        return ExitCode::from(DAEMON_UNAVAILABLE);
    };

    // stdin -> daemon. EOF is a half-close: the client has nothing more to send, and it is also how
    // sshd reports a dead link. Shutting down the write half tells the daemon, which detaches this
    // client's sessions, and still lets its last replies through below.
    let mut to_daemon = match stream.try_clone() {
        Ok(clone) => clone,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    std::thread::spawn(move || {
        let _ = std::io::copy(&mut crate::transport::FdStream::stdin(), &mut to_daemon);
        let _ = to_daemon.shutdown(std::net::Shutdown::Write);
    });

    // daemon -> stdout, unbuffered: `Stdout` is line-buffered, and would hold a frame with no newline
    // in it until the next one pushed it out. Bounded like `serve --stdio`'s writer to the same
    // stdout, so a dead link with output queued for it ends this process `WRITE_TIMEOUT` after its
    // buffers fill. A dead link with nothing to send is not noticed here at all: no process on this
    // end can tell it from a quiet one. The relay then lives until sshd closes the channel (its
    // keepalives, or TCP's), which costs an idle process and a daemon connection, never a
    // session: sessions take more than one client, so the next relay attaches as usual.
    //
    // A poll loop rather than `io::copy`, because the copy can only notice a dead link by WRITING to
    // it. A daemon that has gone quiet (and stopped reading, so the thread above is stuck mid-write
    // and never sees stdin's EOF either) would leave this process blocked on the socket forever.
    // Watching stdout for a hang-up ends it the moment sshd closes the channel. That is Linux, where
    // a pipe whose readers are gone reports POLLERR; macOS's poll does not report it for a pipe,
    // and there the relay falls back to noticing on its next write.
    let mut to_client = crate::transport::FdStream::writer(libc::STDOUT_FILENO);
    let mut from_daemon = &stream;
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
        // SAFETY: `watched` holds exactly the 2 pollfds passed, for `stream` (open for the whole
        // loop) and stdout.
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
        match from_daemon.read(&mut buffer) {
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
