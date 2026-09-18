//! What the agent is served over.
//!
//! The driver contract in the design doc is deliberately **a bidirectional byte stream**, not an
//! ssh endpoint: `ssh host wr-agent serve --stdio` satisfies it, and so does a provider SDK's exec
//! or attach call, or a WebSocket. Without a stream-shaped contract the SDK-only sandbox platforms
//! cannot be drivers at all.
//!
//! So the agent must not know what it is talking over. The requirement is exactly this: something
//! that yields a reader and a writer usable from different threads, because the pty pump writes
//! while the command loop blocks on read.
//!
//! **This is what makes the remote path testable without a remote.** A pair of pipes satisfies it,
//! so the whole protocol — handshake, multiplexing, session lifecycle, repaint — can be exercised
//! over a non-socket transport in-process, with no container, no ssh and no provider. What a
//! container is still needed for is the genuinely remote part: another machine, its own process
//! space, a real ssh hop.

use std::io::{self, Read, Write};
use std::os::unix::io::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;

/// Ends a connection from a thread that is not the one reading it.
///
/// `handle_connection` learns the peer is gone by its read returning, so a thread that only WRITES
/// (a watch subscription pushing events) cannot end the connection by itself: a failed write would
/// otherwise leave the reader parked on a stream nobody is listening to. Calling this makes that
/// read return, which runs the connection's normal teardown — and the client, seeing its transport
/// drop, reconnects into a fresh generation instead of showing a panel that silently stopped updating.
pub type Closer = std::sync::Arc<dyn Fn() + Send + Sync>;

/// A bidirectional stream the agent can serve one connection over.
pub trait Transport {
    type Reader: Read + Send + 'static;
    type Writer: Write + Send + 'static;

    /// Split into halves usable from different threads.
    fn split(self) -> io::Result<(Self::Reader, Self::Writer)>;

    /// A handle that ends this connection from any thread. Taken BEFORE `split`, which consumes
    /// the transport.
    ///
    /// The default does nothing, which is honest for a transport that cannot be closed from the
    /// outside (stdio, a pipe pair): there the evicting thread still drops its own subscription, and
    /// the peer finds out when its next write fails.
    fn closer(&self) -> Closer {
        std::sync::Arc::new(|| {})
    }
}

impl Transport for UnixStream {
    type Reader = UnixStream;
    type Writer = UnixStream;

    fn split(self) -> io::Result<(UnixStream, UnixStream)> {
        let writer = self.try_clone()?;
        // Same reason as `FdStream::writer`: a client that stops reading must not wedge the agent.
        let _ = writer.set_write_timeout(Some(WRITE_TIMEOUT));
        Ok((self, writer))
    }

    fn closer(&self) -> Closer {
        // A clone shares the socket, so shutting it down wakes the reader on the original.
        let handle = self.try_clone().ok();
        std::sync::Arc::new(move || {
            if let Some(handle) = &handle {
                let _ = handle.shutdown(std::net::Shutdown::Both);
            }
        })
    }
}

/// stdin and stdout — the shape `ssh host wr-agent serve --stdio` produces, and the one a
/// provider's exec channel produces too.
///
/// Takes the descriptors rather than `io::stdin()`/`io::stdout()` because those are globally
/// locked and line-buffered: the buffering would hold terminal output until a newline appeared,
/// which for a full-screen program is never.
pub struct StdioTransport;

impl Transport for StdioTransport {
    type Reader = FdStream;
    type Writer = FdStream;

    fn split(self) -> io::Result<(FdStream, FdStream)> {
        Ok((
            FdStream::new(libc::STDIN_FILENO),
            FdStream::writer(libc::STDOUT_FILENO),
        ))
    }
}

/// How long a write may keep retrying before the peer is treated as gone.
///
/// A remote client that stops reading must not be able to wedge the agent. Without a bound the
/// pipe or socket buffer fills, the write blocks forever, and the connection thread never notices
/// the stop flag — the agent hangs holding a session nobody can reach. Ten seconds is far longer
/// than any transient stall and far shorter than forever.
pub const WRITE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// Unbuffered I/O on a borrowed descriptor.
///
/// Borrowed, not owned: closing stdin or stdout out from under the process on drop would break
/// whatever else is using them, and the descriptors outlive this anyway.
pub struct FdStream {
    fd: RawFd,
    /// Set on writers so a stalled peer cannot block the agent indefinitely. Readers stay
    /// blocking: waiting for a client that has nothing to say is exactly what they should do.
    bounded_writes: bool,
}

impl FdStream {
    pub fn new(fd: RawFd) -> FdStream {
        FdStream {
            fd,
            bounded_writes: false,
        }
    }

    /// A writer that gives up rather than blocking forever on a peer that stopped reading.
    fn writer(fd: RawFd) -> FdStream {
        let stream = FdStream {
            fd,
            bounded_writes: true,
        };
        // Best effort: if this fails the write simply blocks as before, which is no worse than
        // the behaviour this replaces.
        let _ = set_nonblocking(&stream);
        stream
    }
}

impl Read for FdStream {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let n = unsafe {
            libc::read(
                self.fd,
                buffer.as_mut_ptr() as *mut libc::c_void,
                buffer.len(),
            )
        };
        if n < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(n as usize)
    }
}

impl Write for FdStream {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let deadline = std::time::Instant::now() + WRITE_TIMEOUT;
        loop {
            let n =
                unsafe { libc::write(self.fd, bytes.as_ptr() as *const libc::c_void, bytes.len()) };
            if n >= 0 {
                return Ok(n as usize);
            }
            let error = io::Error::last_os_error();
            let retryable = matches!(
                error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
            );
            if !self.bounded_writes || !retryable {
                return Err(error);
            }
            if std::time::Instant::now() >= deadline {
                // The peer has not read anything for WRITE_TIMEOUT. Report it gone rather than
                // waiting longer: the caller ends the connection, and the session survives for
                // whoever reconnects.
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "peer stopped reading",
                ));
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// A transport built from two pipes, for testing the agent over something that is not a socket.
///
/// A pipe is the honest stand-in for a remote stream: it has no message boundaries, no `SO_*`
/// options, and it can be chunked anywhere — the same properties an ssh hop or an exec channel
/// has, and the ones a unix socket quietly hides.
pub struct PipeTransport {
    reader: FdStream,
    writer: FdStream,
}

/// Both ends of a pipe pair: what the agent serves over, and what a test drives it with.
pub struct PipePair {
    pub agent: PipeTransport,
    pub client_reader: FdStream,
    pub client_writer: FdStream,
}

impl PipeTransport {
    /// Two pipes wired as a duplex: the client writes what the agent reads, and vice versa.
    pub fn pair() -> io::Result<PipePair> {
        let (to_agent_read, to_agent_write) = pipe()?;
        let (to_client_read, to_client_write) = pipe()?;
        Ok(PipePair {
            agent: PipeTransport {
                reader: FdStream::new(to_agent_read),
                writer: FdStream::writer(to_client_write),
            },
            client_reader: FdStream::new(to_client_read),
            client_writer: FdStream::new(to_agent_write),
        })
    }
}

impl Transport for PipeTransport {
    type Reader = FdStream;
    type Writer = FdStream;

    fn split(self) -> io::Result<(FdStream, FdStream)> {
        Ok((self.reader, self.writer))
    }
}

/// A pipe whose ends are close-on-exec.
///
/// CLOEXEC is load-bearing, not hygiene. The agent forks a pty child for every session, and a
/// descriptor without it is inherited by that child — so the shell ends up holding a duplicate of
/// the transport's write end, and the agent's read NEVER sees EOF when the client disconnects. The
/// connection thread then waits forever on a link the client has already dropped, which is the one
/// thing a remote agent must not do.
///
/// `pipe2(O_CLOEXEC)` would be atomic but does not exist on macOS, so this sets the flag after the
/// fact. The window between the two is harmless here: the agent forks pty children only in
/// response to a client request, which cannot arrive before this function has returned.
fn pipe() -> io::Result<(RawFd, RawFd)> {
    let mut fds = [0 as libc::c_int; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    for fd in fds {
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
            let error = io::Error::last_os_error();
            unsafe {
                libc::close(fds[0]);
                libc::close(fds[1]);
            }
            return Err(error);
        }
    }
    Ok((fds[0], fds[1]))
}

/// Makes reads on this descriptor return `WouldBlock` instead of waiting.
///
/// A blocking read on a pipe with no data and a live writer waits forever, which silently defeats
/// any deadline the caller thinks it has — a test that reads with a timeout will hang instead of
/// failing. The agent's own pty reads are non-blocking for the same reason.
pub fn set_nonblocking(stream: &FdStream) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(stream.fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(stream.fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Closes a descriptor, to end a test's side of a transport.
pub fn close(stream: &FdStream) {
    unsafe { libc::close(stream.fd) };
}

impl AsRawFd for FdStream {
    fn as_raw_fd(&self) -> RawFd {
        self.fd
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pipe_pair_carries_bytes_both_ways() {
        let pair = PipeTransport::pair().expect("pair");
        let (mut agent_reader, mut agent_writer) = pair.agent.split().expect("split");
        let mut client_reader = pair.client_reader;
        let mut client_writer = pair.client_writer;

        client_writer.write_all(b"to the agent").expect("write");
        let mut buffer = [0u8; 32];
        let n = agent_reader.read(&mut buffer).expect("read");
        assert_eq!(&buffer[..n], b"to the agent");

        agent_writer.write_all(b"to the client").expect("write");
        let n = client_reader.read(&mut buffer).expect("read");
        assert_eq!(&buffer[..n], b"to the client");
    }

    /// A pipe has no message boundaries: a write can arrive split, which is the property that
    /// makes it a fair stand-in for a remote stream rather than a convenience.
    #[test]
    fn reads_can_be_shorter_than_writes() {
        let pair = PipeTransport::pair().expect("pair");
        let (mut agent_reader, _writer) = pair.agent.split().expect("split");
        let mut client_writer = pair.client_writer;

        client_writer.write_all(b"0123456789").expect("write");
        let mut small = [0u8; 4];
        let n = agent_reader.read(&mut small).expect("read");
        assert_eq!(n, 4, "a small buffer takes a prefix, not the whole write");
        assert_eq!(&small, b"0123");
    }

    #[test]
    fn closing_the_far_end_reports_eof() {
        let pair = PipeTransport::pair().expect("pair");
        let (mut agent_reader, _writer) = pair.agent.split().expect("split");
        close(&pair.client_writer);
        let mut buffer = [0u8; 8];
        assert_eq!(agent_reader.read(&mut buffer).expect("read"), 0);
    }
}
